import Foundation
import Observation

/// Streams `mo status --watch` (NDJSON) and keeps short histories for charts.
/// Shared by the Status dashboard and the menu bar.
@MainActor
@Observable
final class StatusMonitor {
    struct Sample: Identifiable, Equatable {
        let id: Int
        let date: Date
        let cpu: Double
        let memory: Double
        let netRx: Double
        let netTx: Double
        let diskRead: Double
        let diskWrite: Double
    }

    private(set) var snapshot: StatusSnapshot?
    private(set) var samples: [Sample] = []
    private(set) var lastError: String?
    private(set) var isRunning = false
    /// Most recent snapshot that had full hardware enrichment (the first watch line has none).
    private(set) var enriched: StatusSnapshot?

    var interval: Double = UserDefaults.standard.object(forKey: "statusInterval") as? Double ?? 2 {
        didSet {
            UserDefaults.standard.set(interval, forKey: "statusInterval")
            scheduleRestart()
        }
    }
    var cpuAlertThreshold: Double = UserDefaults.standard.object(forKey: "cpuAlertThreshold") as? Double ?? 100 {
        didSet {
            UserDefaults.standard.set(cpuAlertThreshold, forKey: "cpuAlertThreshold")
            scheduleRestart()
        }
    }
    var cpuAlertWindowMinutes: Double = UserDefaults.standard.object(forKey: "cpuAlertWindow") as? Double ?? 5 {
        didSet {
            UserDefaults.standard.set(cpuAlertWindowMinutes, forKey: "cpuAlertWindow")
            scheduleRestart()
        }
    }

    static let historyLength = 90

    @ObservationIgnored private var process: Subprocess?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var installation: MoleInstallation?
    @ObservationIgnored private var sampleCounter = 0
    @ObservationIgnored private var generation = 0

    func start(installation: MoleInstallation) {
        self.installation = installation
        restart()
    }

    func stop() {
        generation += 1
        task?.cancel()
        process?.signal(SIGTERM)
        process = nil
        isRunning = false
    }

    @ObservationIgnored private var pendingRestart: Task<Void, Never>?

    /// Debounced restart so dragging a slider doesn't respawn the stream on every tick.
    private func scheduleRestart() {
        pendingRestart?.cancel()
        pendingRestart = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.restart()
        }
    }

    func restart() {
        stop()
        guard let installation else { return }
        generation += 1
        let myGeneration = generation
        let args = ["status", "--watch", "--interval", "\(Int(interval * 1000))ms",
                    "--proc-cpu-threshold", "\(Int(cpuAlertThreshold))",
                    "--proc-cpu-window", "\(Int(cpuAlertWindowMinutes * 60))s"]
        task = Task { [weak self] in
            var backoff: UInt64 = 2
            while !Task.isCancelled {
                guard let self, self.generation == myGeneration else { return }
                do {
                    let process = try Subprocess(executable: installation.launcher, arguments: args,
                                                 environment: MoleLocator.environment(), stdinOpen: false)
                    self.process = process
                    self.isRunning = true
                    for await event in process.events {
                        if case .line(let line) = event, line.stream == .stdout {
                            self.ingest(line.raw)
                            backoff = 2
                        } else if case .line(let line) = event, line.stream == .stderr, !line.text.isEmpty {
                            self.lastError = line.text
                        }
                    }
                } catch {
                    self.lastError = error.localizedDescription
                }
                self.isRunning = false
                guard self.generation == myGeneration else { return }
                try? await Task.sleep(for: .seconds(Double(backoff)))
                backoff = min(backoff * 2, 60)
            }
        }
    }

    /// One-off snapshot without the stream (used by tests/E2E and as a fallback).
    func refreshOnce() async {
        guard let installation else { return }
        if let result = try? await Subprocess.run(installation.launcher, ["status", "--json"],
                                                  environment: MoleLocator.environment(), timeout: 30),
           let snap = try? StatusSnapshot.decoder.decode(StatusSnapshot.self, from: MoleService.extractJSON(result.stdout)) {
            apply(snap)
        }
    }

    private func ingest(_ raw: String) {
        guard raw.hasPrefix("{"), let data = raw.data(using: .utf8) else { return }
        do {
            let snap = try StatusSnapshot.decoder.decode(StatusSnapshot.self, from: data)
            apply(snap)
            lastError = nil
        } catch {
            lastError = "Could not read status: \(error.localizedDescription)"
        }
    }

    /// Screenshot privacy mode (`-BurrowPrivacyMode YES`): hides the host name and network addresses so
    /// captures can be published.
    private static let privacyMode = UserDefaults.standard.bool(forKey: "BurrowPrivacyMode")

    private func apply(_ incoming: StatusSnapshot) {
        var snap = incoming
        if Self.privacyMode {
            snap.host = "My Mac"
            snap.network = snap.network?.map { iface in
                var iface = iface
                if !(iface.ip ?? "").isEmpty { iface.ip = "192.168.1.20" }
                return iface
            }
            snap.proxy?.host = nil
        }
        snapshot = snap
        if snap.isEnriched { enriched = snap }
        sampleCounter += 1
        let rx = snap.network?.reduce(0) { $0 + ($1.rxRateMbs ?? 0) } ?? 0
        let tx = snap.network?.reduce(0) { $0 + ($1.txRateMbs ?? 0) } ?? 0
        samples.append(Sample(id: sampleCounter, date: Date(), cpu: snap.cpu?.usage ?? 0,
                              memory: snap.memory?.usedPercent ?? 0, netRx: rx, netTx: tx,
                              diskRead: snap.diskIo?.readRate ?? 0, diskWrite: snap.diskIo?.writeRate ?? 0))
        if samples.count > Self.historyLength { samples.removeFirst(samples.count - Self.historyLength) }
    }

    /// Best available value for fields that only full collects fill in.
    var hardware: StatusSnapshot.Hardware? { enriched?.hardware ?? snapshot?.hardware }
    var batteries: [StatusSnapshot.Battery]? { snapshot?.batteries ?? enriched?.batteries }
}
