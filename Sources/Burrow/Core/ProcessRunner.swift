import Darwin
import Foundation

/// One line of output from a running subprocess.
struct OutputLine: Sendable, Identifiable, Hashable {
    enum Stream: Sendable { case stdout, stderr, tty }
    let id: Int
    let stream: Stream
    let raw: String
    let text: String

    init(id: Int, stream: Stream, raw: String) {
        self.id = id
        self.stream = stream
        self.raw = raw
        self.text = ANSI.strip(raw)
    }
}

enum ProcessEvent: Sendable {
    case line(OutputLine)
    /// Unterminated text currently sitting at the end of a stream (a prompt waiting for input).
    case partial(OutputLine.Stream, String)
    case exited(Int32)
}

struct ProcessResult: Sendable {
    let exitCode: Int32
    let stdout: Data
    let stderr: Data
    var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    var stderrString: String { String(decoding: stderr, as: UTF8.self) }
    var succeeded: Bool { exitCode == 0 }
}

enum SpawnError: LocalizedError {
    case spawnFailed(String, Int32)
    case pipeFailed

    var errorDescription: String? {
        switch self {
        case .spawnFailed(let path, let code): "Could not launch \(path) (\(String(cString: strerror(code))))."
        case .pipeFailed: "Could not create a pipe for the subprocess."
        }
    }
}

/// A subprocess launched with `posix_spawn` in its own session (so no inherited controlling terminal
/// can capture a sudo prompt, and the whole process group can be signalled on cancel).
/// Output is delivered line-by-line; stdin stays open for answering prompts.
final class Subprocess: @unchecked Sendable {
    let events: AsyncStream<ProcessEvent>
    private let continuation: AsyncStream<ProcessEvent>.Continuation
    private let lock = NSLock()
    private var stdinFD: Int32 = -1
    private var ttyMasterFD: Int32 = -1
    private(set) var pid: pid_t = 0
    private var exited = false
    private var exitSource: DispatchSourceProcess?
    private var readers: [DispatchSourceRead] = []
    private let drainGroup = DispatchGroup()
    private let counter = LineCounter()
    /// Keeps the object alive until the child has been reaped, even if every caller drops it,
    /// so no zombie is left behind and cancel escalation still happens.
    private var retainUntilExit: Subprocess?
    private var pty: PseudoTerminal?

    /// - Parameters:
    ///   - pty: a pseudo-terminal whose master is read (and written) alongside the pipes. The subprocess
    ///     takes ownership and closes both ends once the child has exited.
    /// The app's own executable, used to wrap every child in the parent-watching helper so nothing
    /// outlives the app. Set once at launch (never in helper mode).
    nonisolated(unsafe) static var orphanGuardExecutable: String?

    init(executable: String, arguments: [String], environment: [String: String],
         stdinOpen: Bool = true, pty: PseudoTerminal? = nil, currentDirectory: String? = nil) throws {
        (events, continuation) = AsyncStream.makeStream(of: ProcessEvent.self, bufferingPolicy: .unbounded)
        var executable = executable
        var arguments = arguments
        if let guardian = Self.orphanGuardExecutable, executable != guardian {
            arguments = [PrivilegedHelper.flag, "--watch-parent", "--", executable] + arguments
            executable = guardian
        }

        var inPipe: [Int32] = [-1, -1], outPipe: [Int32] = [-1, -1], errPipe: [Int32] = [-1, -1]
        guard pipe(&inPipe) == 0, pipe(&outPipe) == 0, pipe(&errPipe) == 0 else { throw SpawnError.pipeFailed }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if stdinOpen {
            posix_spawn_file_actions_adddup2(&actions, inPipe[0], 0)
        } else {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        if let currentDirectory {
            posix_spawn_file_actions_addchdir(&actions, currentDirectory)
        }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        posix_spawnattr_setsigdefault(&attr, &defaultSignals)
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attr, &emptyMask)

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var childPID: pid_t = 0
        let rc = posix_spawn(&childPID, executable, &actions, &attr, argv, envp)
        close(inPipe[0]); close(outPipe[1]); close(errPipe[1])
        guard rc == 0 else {
            close(inPipe[1]); close(outPipe[0]); close(errPipe[0])
            pty?.close()
            throw SpawnError.spawnFailed(executable, rc)
        }
        retainUntilExit = self
        pid = childPID
        stdinFD = inPipe[1]
        if !stdinOpen { close(inPipe[1]); stdinFD = -1 }
        // Writing to a closed pipe must not kill the GUI.
        Darwin.signal(SIGPIPE, SIG_IGN)

        attachReader(fd: outPipe[0], stream: .stdout)
        attachReader(fd: errPipe[0], stream: .stderr)
        if let pty {
            self.pty = pty
            ttyMasterFD = pty.master
            attachReader(fd: pty.master, stream: .tty, closeOnEOF: false)
        }

        let source = DispatchSource.makeProcessSource(identifier: childPID, eventMask: .exit, queue: .global())
        source.setEventHandler { [weak self] in self?.reap() }
        exitSource = source
        source.resume()
    }

    private func attachReader(fd: Int32, stream: OutputLine.Stream, closeOnEOF: Bool = true) {
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let splitter = LineSplitter { [continuation, counter] raw, complete in
            if complete {
                continuation.yield(.line(OutputLine(id: counter.next(), stream: stream, raw: raw)))
            } else {
                continuation.yield(.partial(stream, ANSI.strip(raw)))
            }
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        let isTTY = stream == .tty
        if !isTTY { drainGroup.enter() }
        var finished = false
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(fd, &buffer, buffer.count)
                if n > 0 {
                    splitter.feed(Data(buffer[0..<n]))
                } else if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) {
                    // EOF (or EIO on a pty whose slave closed).
                    if !finished {
                        finished = true
                        splitter.flush()
                        source.cancel()
                    }
                    return
                } else {
                    splitter.emitPartial()
                    return
                }
            }
        }
        source.setCancelHandler { [weak self] in
            if closeOnEOF { close(fd) }
            if isTTY {
                // Only close the pty once its read source is fully torn down (libdispatch requirement).
                self?.lock.lock()
                self?.ttyMasterFD = -1
                let pty = self?.pty
                self?.pty = nil
                self?.lock.unlock()
                pty?.close()
            } else {
                self?.drainGroup.leave()
            }
        }
        readers.append(source)
        source.resume()
    }

    private func reap() {
        // NOTE_EXIT can arrive a moment before the child is reapable, and it fires only once,
        // so wait (blocking) rather than polling with WNOHANG.
        var status: Int32 = 0
        var result: pid_t
        repeat { result = waitpid(pid, &status, 0) } while result == -1 && errno == EINTR
        guard result == pid else { return }
        exitSource?.cancel()
        let code: Int32
        if (status & 0x7f) == 0 {
            code = (status >> 8) & 0xff
        } else {
            code = 128 + (status & 0x7f)
        }
        // Report exit only after stdout/stderr have drained so no output is lost.
        drainGroup.notify(queue: .global()) { [self] in
            self.lock.lock()
            self.exited = true
            if self.stdinFD >= 0 { close(self.stdinFD); self.stdinFD = -1 }
            self.lock.unlock()
            for reader in self.readers where !reader.isCancelled { reader.cancel() }
            self.continuation.yield(.exited(code))
            self.continuation.finish()
            self.lock.lock()
            self.retainUntilExit = nil
            self.lock.unlock()
        }
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return !exited
    }

    /// Writes to the process's stdin pipe.
    func write(_ text: String) {
        lock.lock(); let fd = stdinFD; lock.unlock()
        guard fd >= 0 else { return }
        Self.writeAll(fd, Array(text.utf8))
    }

    /// Writes to the pseudo-terminal master (what the process would read from /dev/tty).
    func writeTTY(_ text: String) {
        lock.lock(); let fd = ttyMasterFD; lock.unlock()
        guard fd >= 0 else { return }
        Self.writeAll(fd, Array(text.utf8))
    }

    func writeTTY(bytes: [UInt8]) {
        lock.lock(); let fd = ttyMasterFD; lock.unlock()
        guard fd >= 0 else { return }
        Self.writeAll(fd, bytes)
    }

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) {
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n > 0 { offset += n } else if errno == EAGAIN || errno == EINTR { usleep(1000) } else { return }
        }
    }

    func closeStdin() {
        lock.lock(); defer { lock.unlock() }
        if stdinFD >= 0 { close(stdinFD); stdinFD = -1 }
    }

    /// Sends a signal to the whole process group (the child is a session leader).
    func signal(_ sig: Int32) {
        guard pid > 0, isRunning else { return }
        killpg(pid, sig)
    }

    /// Interrupts like Ctrl-C, escalating to SIGTERM and then SIGKILL.
    func cancel() {
        signal(SIGINT)
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in self?.signal(SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 8) { [weak self] in self?.signal(SIGKILL) }
    }

    /// Runs to completion and returns all output.
    static func run(_ executable: String, _ arguments: [String], environment: [String: String],
                    stdin: String? = nil, timeout: TimeInterval? = nil) async throws -> ProcessResult {
        let process = try Subprocess(executable: executable, arguments: arguments, environment: environment,
                                     stdinOpen: stdin != nil)
        if let stdin {
            process.write(stdin)
            process.closeStdin()
        }
        if let timeout {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak process] in process?.cancel() }
        }
        var out = Data(), err = Data()
        var code: Int32 = -1
        for await event in process.events {
            switch event {
            case .line(let line):
                let data = Data((line.raw + "\n").utf8)
                if line.stream == .stderr { err.append(data) } else { out.append(data) }
            case .partial: break
            case .exited(let c): code = c
            }
        }
        return ProcessResult(exitCode: code, stdout: out, stderr: err)
    }
}

private final class LineCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}

/// Splits a byte stream into lines. Carriage returns (used by spinners and in-place redraws)
/// are treated as line breaks so progress surfaces immediately.
private final class LineSplitter: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()
    private let emit: (String, Bool) -> Void

    init(emit: @escaping (String, Bool) -> Void) { self.emit = emit }

    func feed(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        // Scan with a moving start index and compact once, so a chunk of many lines stays linear.
        var start = buffer.startIndex
        var i = start
        let end = buffer.endIndex
        while i < end {
            let byte = buffer[i]
            if byte == 0x0A || byte == 0x0D {
                emit(String(decoding: buffer[start..<i], as: UTF8.self), true)
                var next = i + 1
                if byte == 0x0D, next < end, buffer[next] == 0x0A { next += 1 }
                start = next
                i = next
            } else {
                i += 1
            }
        }
        if start > buffer.startIndex { buffer = Data(buffer[start...]) }
    }

    /// Emits the unterminated tail (e.g. "Proceed? [y/N] ") without consuming it.
    func emitPartial() {
        lock.lock(); defer { lock.unlock() }
        if !buffer.isEmpty { emit(String(decoding: buffer, as: UTF8.self), false) }
    }

    func flush() {
        lock.lock(); defer { lock.unlock() }
        if !buffer.isEmpty {
            emit(String(decoding: buffer, as: UTF8.self), true)
            buffer.removeAll()
        }
    }
}

enum ANSI {
    // CSI sequences, OSC sequences (e.g. hyperlinks), and two-byte ESC sequences.
    private static let pattern = try! NSRegularExpression(
        pattern: "\u{1B}\\[[0-?]*[ -/]*[@-~]|\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)|\u{1B}[@-Z\\\\-_]|\u{1B}[()][0-9A-Za-z]")

    static func strip(_ s: String) -> String {
        guard s.contains("\u{1B}") else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return pattern.stringByReplacingMatches(in: s, range: range, withTemplate: "")
    }
}
