import AppKit
import Darwin
import Foundation
import Observation
import SwiftUI

/// A single invocation of the Mole CLI, observable by the UI.
@MainActor
@Observable
final class CommandRun: Identifiable {
    enum State: Equatable {
        case running
        case finished(Int32)
        case failedToStart(String)
        case cancelled

        var isRunning: Bool { self == .running }
    }

    let id = UUID()
    let title: String
    let arguments: [String]
    let admin: Bool
    /// Stdin is relayed through the supervising helper so prompts can be answered.
    let interactive: Bool
    let startedAt = Date()
    private(set) var endedAt: Date?
    /// Stays `.running` until the process has really exited, even after `cancel()`.
    private(set) var state: State = .running
    private(set) var cancelRequested = false
    private(set) var lines: [OutputLine] = []
    /// Unterminated text at the end of stdout/stderr — typically a prompt awaiting an answer.
    private(set) var pendingPrompt: String = ""
    @ObservationIgnored private var pendingPromptStream: OutputLine.Stream?
    /// True once authentication succeeded (admin runs only).
    private(set) var authenticated = false
    private(set) var authFailed = false

    @ObservationIgnored fileprivate var process: Subprocess?
    @ObservationIgnored var onLine: ((OutputLine) -> Void)?
    @ObservationIgnored var onPrompt: ((String) -> Void)?
    @ObservationIgnored private var completionHandlers: [(CommandRun) -> Void] = []
    @ObservationIgnored private var waiters: [CheckedContinuation<Int32, Never>] = []

    init(title: String, arguments: [String], admin: Bool, interactive: Bool = false) {
        self.title = title
        self.arguments = arguments
        self.admin = admin
        self.interactive = interactive
    }

    var commandLine: String { "mo " + arguments.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ") }
    var exitCode: Int32? { if case .finished(let c) = state { c } else { nil } }
    var succeeded: Bool { exitCode == 0 }
    var stdoutText: String { lines.filter { $0.stream == .stdout }.map(\.text).joined(separator: "\n") }
    var duration: TimeInterval { (endedAt ?? Date()).timeIntervalSince(startedAt) }

    /// Answers a prompt on stdin.
    func send(_ text: String) { process?.write(text) }

    /// Closes stdin. For interactive (supervised) runs this *stops* Mole rather than sending it an
    /// EOF, because several Mole prompts treat EOF as "confirm".
    func closeInput() { process?.closeStdin() }

    /// Asks the process to stop (Ctrl-C, escalating to SIGTERM/SIGKILL). The state becomes
    /// `.cancelled` only once the process has actually exited.
    func cancel() {
        guard state.isRunning, !cancelRequested else { return }
        cancelRequested = true
        process?.cancel()
    }

    /// Immediate hard stop, used when the app is quitting.
    func kill() {
        guard state.isRunning else { return }
        cancelRequested = true
        process?.signal(SIGKILL)
    }

    var isProcessAlive: Bool { process?.isRunning ?? false }

    func onCompletion(_ handler: @escaping (CommandRun) -> Void) {
        if !state.isRunning { handler(self) } else { completionHandlers.append(handler) }
    }

    /// Suspends until the process exits and returns its exit code (-1 if it never ran or was cancelled).
    func waitUntilExit() async -> Int32 {
        if !state.isRunning { return exitCode ?? -1 }
        return await withCheckedContinuation { waiters.append($0) }
    }

    fileprivate func append(_ line: OutputLine) {
        if line.text == PrivilegedHelper.authOK { authenticated = true; return }
        if line.text == PrivilegedHelper.authFailed { authFailed = true; return }
        lines.append(line)
        // A completed line on the same stream supersedes the prompt; the other stream can't.
        if line.stream == pendingPromptStream {
            pendingPrompt = ""
            pendingPromptStream = nil
        }
        onLine?(line)
    }

    fileprivate func setPartial(_ text: String, stream: OutputLine.Stream) {
        pendingPrompt = text
        pendingPromptStream = stream
        onPrompt?(text)
    }

    fileprivate func fail(_ message: String) {
        state = .failedToStart(message)
        endedAt = Date()
        finish()
    }

    fileprivate func exited(_ code: Int32) {
        state = cancelRequested ? .cancelled : .finished(code)
        if code == PrivilegedHelper.authFailedExitCode && admin { authFailed = true }
        endedAt = Date()
        process = nil
        finish()
    }

    private func finish() {
        let handlers = completionHandlers
        completionHandlers.removeAll()
        handlers.forEach { $0(self) }
        let code = exitCode ?? -1
        waiters.forEach { $0.resume(returning: code) }
        waiters.removeAll()
    }
}

/// Asks the user for their administrator password when sudo prompts on the helper's terminal.
/// Requests are queued (one visible at a time), tied to their run, and shown in a floating panel
/// that works even when the main window is closed (the app lives on in the menu bar).
@MainActor
@Observable
final class AuthCoordinator {
    struct Request: Identifiable {
        let id = UUID()
        let runID: UUID
        let reason: String
        let retry: Bool
        fileprivate let continuation: CheckedContinuation<String?, Never>
    }

    private(set) var request: Request?
    @ObservationIgnored private var queue: [Request] = []
    @ObservationIgnored private var panel: NSPanel?

    func requestPassword(for runID: UUID, reason: String, retry: Bool) async -> String? {
        await withCheckedContinuation { continuation in
            queue.append(Request(runID: runID, reason: reason, retry: retry, continuation: continuation))
            advance()
        }
    }

    func submit(_ password: String?) {
        guard let request else { return }
        self.request = nil
        closePanel()
        request.continuation.resume(returning: password)
        advance()
    }

    /// Resolves any request belonging to a run that has ended.
    func withdraw(runID: UUID) {
        if request?.runID == runID { submit(nil) }
        let stale = queue.filter { $0.runID == runID }
        queue.removeAll { $0.runID == runID }
        stale.forEach { $0.continuation.resume(returning: nil) }
    }

    private func advance() {
        guard request == nil, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        request = next
        showPanel(for: next)
    }

    private func showPanel(for request: Request) {
        let host = NSHostingController(rootView: AuthSheet(request: request) { [weak self] in self?.submit($0) })
        let panel = NSPanel(contentViewController: host)
        panel.styleMask = [.titled, .fullSizeContentView]
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.level = .modalPanel
        panel.isReleasedWhenClosed = false
        panel.center()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    private func closePanel() {
        panel?.orderOut(nil)
        panel = nil
    }
}

@MainActor
@Observable
final class MoleService {
    private(set) var installation: MoleInstallation?
    private(set) var isLocating = true
    /// Every run in this app session, newest last (the Activity console).
    private(set) var runs: [CommandRun] = []
    var debugLogging = false

    let auth = AuthCoordinator()

    var isAvailable: Bool { installation != nil }
    var runningCount: Int { runs.filter { $0.state.isRunning }.count }

    func locate(preferred: String? = nil) async {
        isLocating = true
        installation = await MoleLocator.locate(preferred: preferred)
        isLocating = false
    }

    // MARK: Streaming runs

    /// Starts `mo <arguments>`.
    /// - Parameters:
    ///   - admin: run inside the privileged helper session and authenticate first (for system-level work).
    ///   - keepInputOpen: keep stdin open so prompts can be answered with `send`. Such runs are supervised
    ///     by the helper, which kills Mole if the app goes away instead of letting Mole read an EOF.
    ///     Otherwise stdin is at EOF from the start — only for commands that never treat EOF as "confirm".
    @discardableResult
    func start(_ title: String, _ arguments: [String], admin: Bool = false, keepInputOpen: Bool = false,
               environment extra: [String: String] = [:],
               onLine: ((OutputLine) -> Void)? = nil,
               onPrompt: ((String) -> Void)? = nil) -> CommandRun {
        let run = CommandRun(title: title, arguments: arguments, admin: admin, interactive: keepInputOpen)
        run.onLine = onLine
        run.onPrompt = onPrompt
        runs.append(run)
        // Evict only finished runs so running ones stay reachable (Stop, quit cleanup).
        while runs.count > 200, let index = runs.firstIndex(where: { !$0.state.isRunning }) {
            runs.remove(at: index)
        }

        guard let installation else {
            run.fail("Mole is not installed. Install it with: brew install mole")
            return run
        }
        var args = arguments
        if debugLogging && !args.contains("--debug") { args.append("--debug") }
        let env = MoleLocator.environment(extra: extra)

        do {
            let process: Subprocess
            if admin || keepInputOpen {
                var pty: PseudoTerminal?
                var helperOptions: [String] = ["--watch-parent"]
                if admin {
                    let terminal = try PseudoTerminal.open()
                    pty = terminal
                    helperOptions += ["--tty", terminal.slavePath, "--auth"]
                }
                if keepInputOpen { helperOptions.append("--supervise") }
                let me = Bundle.main.executablePath ?? CommandLine.arguments[0]
                process = try Subprocess(
                    executable: me,
                    arguments: [PrivilegedHelper.flag] + helperOptions + ["--", installation.launcher] + args,
                    environment: env, stdinOpen: keepInputOpen, pty: pty)
            } else {
                process = try Subprocess(executable: installation.launcher, arguments: args,
                                         environment: env, stdinOpen: false)
            }
            run.process = process
            consume(process, into: run)
        } catch {
            run.fail(error.localizedDescription)
        }
        return run
    }

    private func consume(_ process: Subprocess, into run: CommandRun) {
        Task { @MainActor [weak self] in
            var sawRejection = false
            for await event in process.events {
                switch event {
                case .line(let line):
                    if line.stream == .tty {
                        if line.text.contains("Sorry, try again") || line.text.contains("incorrect password") {
                            sawRejection = true
                        }
                        // Keep terminal chatter out of the transcript except meaningful messages.
                        let t = line.text.trimmingCharacters(in: .whitespaces)
                        if t.isEmpty || t.hasPrefix(PrivilegedHelper.sudoPrompt) || t.hasPrefix("Password:") { continue }
                    }
                    run.append(line)
                case .partial(let stream, let text):
                    if stream == .tty {
                        if Self.isPasswordPrompt(text) {
                            // Answer on a separate task so exit and output keep flowing meanwhile.
                            let retry = sawRejection
                            sawRejection = false
                            Task { @MainActor [weak self] in
                                await self?.answerPasswordPrompt(for: run, process: process, retry: retry)
                            }
                        }
                    } else {
                        run.setPartial(text, stream: stream)
                    }
                case .exited(let code):
                    self?.auth.withdraw(runID: run.id)
                    run.exited(code)
                }
            }
        }
    }

    static func isPasswordPrompt(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        return t.hasSuffix(PrivilegedHelper.sudoPrompt) || t.hasSuffix("Password:") || t.hasSuffix("password:")
    }

    private func answerPasswordPrompt(for run: CommandRun, process: Subprocess, retry: Bool) async {
        let reason = "Burrow needs administrator access so Mole can finish “\(run.title)”."
        let password = await auth.requestPassword(for: run.id, reason: reason, retry: retry)
        guard process.isRunning else { return }
        if let password {
            process.writeTTY(password + "\n")
        } else {
            // Ctrl-C on the terminal aborts sudo; the helper then reports failure.
            process.writeTTY(bytes: [0x03])
        }
    }

    // MARK: Collected runs

    /// Runs `mo <arguments>` to completion with stdin at EOF (read-only commands only).
    func collect(_ arguments: [String], timeout: TimeInterval? = 600, environment extra: [String: String] = [:]) async throws -> ProcessResult {
        guard let installation else { throw MoleError.notInstalled }
        return try await Subprocess.run(installation.launcher, arguments,
                                        environment: MoleLocator.environment(extra: extra), timeout: timeout)
    }

    /// Runs `mo <arguments>` and decodes its stdout as JSON.
    /// Mole's JSON uses snake_case keys, so the default decoder converts them.
    func json<T: Decodable & Sendable>(_ type: T.Type, _ arguments: [String], timeout: TimeInterval? = 900,
                                       decoder: JSONDecoder = MoleService.snakeCaseDecoder()) async throws -> T {
        let result = try await collect(arguments, timeout: timeout)
        guard result.succeeded || !result.stdout.isEmpty else {
            throw MoleError.commandFailed(result.stderrString.isEmpty ? "Exit code \(result.exitCode)" : result.stderrString)
        }
        do {
            return try decoder.decode(T.self, from: Self.extractJSON(result.stdout))
        } catch {
            throw MoleError.decodeFailed("\(error)")
        }
    }

    /// Runs a bash snippet with Mole's libraries sourced (used to read Mole's built-in inventories).
    func bash(_ script: String, timeout: TimeInterval = 30) async throws -> ProcessResult {
        guard let installation else { throw MoleError.notInstalled }
        let prelude = "source \"\(installation.libexec)/lib/core/common.sh\" >/dev/null 2>&1; "
        return try await Subprocess.run("/bin/bash", ["-c", prelude + script],
                                        environment: MoleLocator.environment(), timeout: timeout)
    }

    nonisolated static func snakeCaseDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    /// Mole prints the JSON document alone, but tolerate stray leading text.
    nonisolated static func extractJSON(_ data: Data) -> Data {
        guard let first = data.firstIndex(where: { $0 == UInt8(ascii: "{") || $0 == UInt8(ascii: "[") }) else { return data }
        return Data(data[first...])
    }

    /// Stops every running command (their processes live in their own sessions, so they would
    /// otherwise outlive the app).
    func cancelAllRuns() {
        for run in runs where run.state.isRunning { run.cancel() }
    }

    /// Stops everything immediately (app termination: there is no time for graceful escalation).
    func killAllRuns() {
        for run in runs where run.state.isRunning { run.kill() }
    }

    func clearFinishedRuns() {
        runs.removeAll { !$0.state.isRunning }
    }
}

enum MoleError: LocalizedError {
    case notInstalled
    case commandFailed(String)
    case decodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled: "The Mole CLI was not found. Install it with “brew install mole”."
        case .commandFailed(let message): message.trimmingCharacters(in: .whitespacesAndNewlines)
        case .decodeFailed(let message): "Mole returned output Burrow could not read: \(message)"
        }
    }
}
