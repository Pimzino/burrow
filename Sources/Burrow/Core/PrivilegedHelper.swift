import Darwin
import Foundation

/// The app re-executes itself in "helper" mode to run Mole in two situations:
///
/// **Admin runs.** Mole only accepts administrator access through a sudo credential cached for a
/// controlling terminal (sudoers' default `timestamp_type=tty`), and it never prompts without one.
/// The helper makes a pseudo-terminal its controlling terminal, runs `sudo -v` (the password prompt
/// appears on the pty, where the app answers it from a secure field — the password never touches
/// argv, env or disk), then spawns Mole in the same session so every `sudo -n` Mole issues shares that
/// ticket. Output still flows through plain pipes, so Mole stays non-interactive and colour-free.
/// When Mole exits the helper revokes the ticket with `sudo -k`.
///
/// **Supervised runs** (prompts answered over stdin). Several Mole prompts treat EOF on stdin as
/// "confirm". If the app crashed or was force-quit while Mole waited at one, the pipe would close and
/// Mole would go ahead. So the helper owns Mole's stdin: it relays bytes from the app, and when the
/// app's side reaches EOF (the app died, or cancelled deliberately) it kills Mole *before* Mole can
/// ever read an EOF.
///
/// **Every run** is also parent-watched (`--watch-parent`): Mole's processes live in their own session,
/// so if the app crashes or is killed they would otherwise keep running (a `~/Library` scan can take
/// an hour). The helper watches the app's process and stops Mole the moment the app disappears.
///
///     Burrow --mole-helper [--watch-parent] [--tty <pty-slave>] [--auth] [--supervise] -- /opt/homebrew/bin/mo clean
enum PrivilegedHelper {
    static let flag = "--mole-helper"
    static let sudoPrompt = "__MOLE_GUI_SUDO_PROMPT__:"
    static let authOK = "__MOLE_GUI_AUTH_OK__"
    static let authFailed = "__MOLE_GUI_AUTH_FAILED__"
    static let authFailedExitCode: Int32 = 77

    static func isHelperInvocation(_ args: [String]) -> Bool {
        args.count > 1 && args[1] == flag
    }

    /// Entry point for helper mode. Never returns.
    static func run(_ args: [String]) -> Never {
        guard let sep = args.firstIndex(of: "--"), sep + 1 < args.count, sep >= 2 else {
            fputs("mole-helper: bad arguments\n", stderr)
            exit(64)
        }
        let options = Array(args[2..<sep])
        let command = Array(args[(sep + 1)...])
        let wantsAuth = options.contains("--auth")
        let supervise = options.contains("--supervise")
        let watchParent = options.contains("--watch-parent")
        let parent = getppid()
        var slavePath: String?
        if let i = options.firstIndex(of: "--tty"), i + 1 < options.count { slavePath = options[i + 1] }

        // The app spawned us with POSIX_SPAWN_SETSID, so we lead a fresh session.
        if getsid(0) != getpid() { _ = setsid() }
        var ttyFD: Int32 = -1
        if let slavePath {
            ttyFD = open(slavePath, O_RDWR)
            guard ttyFD >= 0, ioctl(ttyFD, UInt(TIOCSCTTY), 0) == 0 else {
                fputs("mole-helper: could not acquire terminal \(slavePath): \(String(cString: strerror(errno)))\n", stderr)
                exit(70)
            }
        }

        // The helper must survive Ctrl-C / cancel so it can clean up afterwards.
        signal(SIGINT, SIG_IGN)
        signal(SIGHUP, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        signal(SIGPIPE, SIG_IGN)
        let null = open("/dev/null", O_RDWR)

        var authenticated = false
        if wantsAuth {
            guard ttyFD >= 0 else {
                fputs("mole-helper: --auth needs --tty\n", stderr)
                exit(64)
            }
            let status = wait(spawn("/usr/bin/sudo", ["-v", "-p", sudoPrompt], stdio: (ttyFD, ttyFD, ttyFD)))
            if status == 0 {
                authenticated = true
                fputs(authOK + "\n", stderr)
            } else {
                fputs(authFailed + "\n", stderr)
                exit(authFailedExitCode)
            }
        }

        // Keep the ticket fresh for long runs (Mole also does this once it adopts the session).
        var keepAlive: DispatchSourceTimer?
        if authenticated {
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + 45, repeating: 45)
            timer.setEventHandler { _ = wait(spawn("/usr/bin/sudo", ["-n", "-v"], stdio: (null, null, null))) }
            timer.resume()
            keepAlive = timer
        }

        var childStdin: Int32 = 0
        var relayWrite: Int32 = -1
        if supervise {
            var fds: [Int32] = [-1, -1]
            guard pipe(&fds) == 0 else { exit(71) }
            childStdin = fds[0]
            relayWrite = fds[1]
            _ = fcntl(relayWrite, F_SETFD, FD_CLOEXEC)
        }

        let child = spawn(command[0], Array(command.dropFirst()), stdio: (childStdin, 1, 2))
        if supervise { close(childStdin) }

        // Stop Mole if the app goes away (crash, force quit, kill) instead of leaving it orphaned.
        var parentWatch: DispatchSourceProcess?
        if watchParent, child > 0 {
            let stopChild: @Sendable () -> Void = {
                kill(child, SIGTERM)
                killpg(getpgrp(), SIGTERM)
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                    kill(child, SIGKILL)
                    killpg(getpgrp(), SIGKILL)
                }
            }
            if parent <= 1 || kill(parent, 0) != 0 {
                stopChild()
            } else {
                let source = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .global())
                source.setEventHandler { stopChild() }
                source.resume()
                parentWatch = source
            }
        }

        if supervise, child > 0 {
            let writeEnd = relayWrite
            Thread.detachNewThread {
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let n = read(0, &buffer, buffer.count)
                    if n > 0 {
                        var offset = 0
                        while offset < n {
                            let w = buffer[offset..<n].withUnsafeBufferPointer { Darwin.write(writeEnd, $0.baseAddress, $0.count) }
                            if w > 0 { offset += w } else if errno != EINTR { break }
                        }
                    } else if n == 0 || errno != EINTR {
                        // The app closed its end or died. Kill Mole before it can see EOF, which several
                        // of its prompts would take as "confirm"; then stop the rest of its process group.
                        kill(child, SIGKILL)
                        killpg(getpgrp(), SIGTERM)
                        return
                    }
                }
            }
        }

        let status = wait(child)
        parentWatch?.cancel()
        keepAlive?.cancel()
        if authenticated {
            _ = wait(spawn("/usr/bin/sudo", ["-k"], stdio: (null, null, null)))
        }
        exit(status)
    }

    private static func wait(_ pid: pid_t) -> Int32 {
        guard pid > 0 else { return 127 }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        if (status & 0x7f) == 0 { return (status >> 8) & 0xff }
        return 128 + (status & 0x7f)
    }

    /// Spawns a process in the helper's session and process group (the terminal's foreground group,
    /// so reading /dev/tty never raises SIGTTIN) with default signal dispositions.
    private static func spawn(_ path: String, _ arguments: [String], stdio: (Int32, Int32, Int32)) -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, stdio.0, 0)
        posix_spawn_file_actions_adddup2(&actions, stdio.1, 1)
        posix_spawn_file_actions_adddup2(&actions, stdio.2, 2)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var defaults = sigset_t()
        sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&attr, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attr, &mask)

        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, &actions, &attr, argv, environ)
        guard rc == 0 else {
            fputs("mole-helper: could not launch \(path): \(String(cString: strerror(rc)))\n", stderr)
            return -1
        }
        return pid
    }
}

/// Opens a pseudo-terminal pair for a privileged run.
struct PseudoTerminal {
    let master: Int32
    let slave: Int32
    let slavePath: String

    static func open() throws -> PseudoTerminal {
        var master: Int32 = -1, slave: Int32 = -1
        var name = [CChar](repeating: 0, count: 256)
        var size = winsize(ws_row: 50, ws_col: 200, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, &name, nil, &size) == 0 else { throw SpawnError.pipeFailed }
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        _ = fcntl(slave, F_SETFD, FD_CLOEXEC)
        return PseudoTerminal(master: master, slave: slave, slavePath: String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }

    func close() {
        Darwin.close(slave)
        Darwin.close(master)
    }
}
