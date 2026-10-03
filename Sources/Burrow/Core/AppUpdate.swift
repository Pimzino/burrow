import CryptoKit
import Darwin
import Foundation
import Security

// Burrow's own updates, from the GitHub Releases of Pimzino/burrow.
//
// Trust model. Releases are not notarized and are often signed ad-hoc, so neither Gatekeeper nor the code
// signature can tell a genuine build from a forged one. The anchor is an Ed25519 key: the release workflow
// signs every DMG with a private key kept in a repository secret (`BURROW_UPDATE_SIGNING_KEY`), and the app
// only installs a DMG whose `.sig` asset verifies against the public key built into its Info.plist
// (`BurrowUpdatePublicKey`). On top of that, the app inside the DMG must have a valid code signature, the
// same bundle identifier, exactly the release's version (newer than the running one), and the same team
// identifier when the running app has one. A build without a public key never installs updates in place;
// it only offers the release page.
//
// Installation swaps the new bundle in next to the running one (an atomic `RENAME_SWAP` on the same
// volume), then a detached shell waits for this process to exit and reopens the app.

enum UpdateConfig {
    static let repository = "Pimzino/burrow"
    static let releasesPage = URL(string: "https://github.com/\(repository)/releases")!

    /// `https://api.github.com/repos/Pimzino/burrow/releases`. E2E runs point this at a local server with
    /// `-BurrowUpdateAPIURL`; that is harmless, since nothing installs without a signature from the key.
    static var releasesAPI: URL {
        if let override = UserDefaults.standard.string(forKey: "BurrowUpdateAPIURL"),
           let url = URL(string: override), ["http", "https"].contains(url.scheme ?? "") {
            return url
        }
        return URL(string: "https://api.github.com/repos/\(repository)/releases")!
    }

    /// The Ed25519 public key that release DMGs are signed with, or nil for builds without one.
    static var publicKey: Curve25519.Signing.PublicKey? {
        guard let text = Bundle.main.object(forInfoDictionaryKey: "BurrowUpdatePublicKey") as? String,
              let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: data)
    }

    static var currentVersion: SemanticVersion? {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(SemanticVersion.init)
    }
}

// MARK: - Versions

/// A semantic version ("1.2.3", "v1.2", "1.3.0-beta.2"). Pre-releases sort before their release, and
/// their identifiers compare numerically when both are numbers, as in semver.org §11.
struct SemanticVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    let core: [Int]
    let prerelease: [String]

    init?(_ text: String) {
        var text = text.trimmingCharacters(in: .whitespaces)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        text = String(text.prefix { $0 != "+" })   // build metadata never affects precedence
        let parts = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard (1...4).contains(numbers.count), numbers.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        var core = numbers.compactMap { $0 }
        while core.count < 3 { core.append(0) }
        self.core = core
        if parts.count == 2 {
            let ids = parts[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !ids.isEmpty, ids.allSatisfy({ !$0.isEmpty }) else { return nil }
            prerelease = ids
        } else {
            prerelease = []
        }
    }

    var isPrerelease: Bool { !prerelease.isEmpty }

    var description: String {
        var core = core
        while core.count > 3, core.last == 0 { core.removeLast() }
        let base = core.map(String.init).joined(separator: ".")
        return prerelease.isEmpty ? base : base + "-" + prerelease.joined(separator: ".")
    }

    static func < (a: SemanticVersion, b: SemanticVersion) -> Bool {
        for i in 0..<max(a.core.count, b.core.count) {
            let x = i < a.core.count ? a.core[i] : 0, y = i < b.core.count ? b.core[i] : 0
            if x != y { return x < y }
        }
        switch (a.prerelease.isEmpty, b.prerelease.isEmpty) {
        case (true, true), (true, false): return false
        case (false, true): return true
        case (false, false): break
        }
        for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
            switch (Int(x), Int(y)) {
            case let (m?, n?): return m < n
            case (.some, nil): return true    // numeric identifiers sort before alphanumeric ones
            case (nil, .some): return false
            case (nil, nil): return x < y
            }
        }
        return a.prerelease.count < b.prerelease.count
    }

    static func == (a: SemanticVersion, b: SemanticVersion) -> Bool { !(a < b) && !(b < a) }
    func hash(into hasher: inout Hasher) { hasher.combine(description) }
}

// MARK: - Releases

struct AppRelease: Equatable, Sendable, Identifiable {
    struct Asset: Equatable, Sendable {
        let name: String
        let url: URL
        let size: Int
        /// Lowercase hex SHA-256 from the asset's `digest` ("sha256:…"), when GitHub provides one.
        let sha256: String?
    }

    let version: SemanticVersion
    let tag: String
    let title: String
    let notes: String
    let page: URL
    let publishedAt: Date?
    let isPrerelease: Bool
    let dmg: Asset?
    let signature: Asset?

    var id: String { tag }
}

enum ReleaseFeed {
    enum FeedError: LocalizedError {
        case http(Int, rateLimited: Bool)
        case malformed

        var errorDescription: String? {
            switch self {
            case .http(_, rateLimited: true): "GitHub's limit for anonymous requests was reached. Try again in an hour."
            case .http(404, _): "No published releases were found."
            case .http(let code, _): "GitHub answered with HTTP \(code)."
            case .malformed: "GitHub's answer could not be read."
            }
        }
    }

    private struct Payload: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
            let size: Int
            let digest: String?
            let state: String?
        }
        let tag_name: String
        let name: String?
        let body: String?
        let html_url: URL
        let draft: Bool
        let prerelease: Bool
        let published_at: Date?
        let assets: [Asset]
    }

    /// The newest release, or nil when the repository has none that parse. Without pre-releases this is
    /// GitHub's "latest" release (which already excludes drafts and pre-releases).
    static func newest(includePrereleases: Bool, session: URLSession = .shared) async throws -> AppRelease? {
        let base = UpdateConfig.releasesAPI
        let url = includePrereleases
            ? URL(string: base.absoluteString + "?per_page=30")!
            : base.appendingPathComponent("latest")
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Burrow/\(UpdateConfig.currentVersion?.description ?? "dev")", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        guard let status = http?.statusCode, status == 200 else {
            let code = http?.statusCode ?? 0
            if code == 404, !includePrereleases { return nil }   // no non-prerelease release yet
            throw FeedError.http(code, rateLimited: (code == 403 || code == 429) && http?.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payloads: [Payload]
        do {
            payloads = includePrereleases ? try decoder.decode([Payload].self, from: data) : [try decoder.decode(Payload.self, from: data)]
        } catch {
            throw FeedError.malformed
        }
        return payloads.filter { !$0.draft }.compactMap(release).max { $0.version < $1.version }
    }

    private static func release(_ p: Payload) -> AppRelease? {
        guard let version = SemanticVersion(p.tag_name) else { return nil }
        let assets = p.assets.filter { ($0.state ?? "uploaded") == "uploaded" }.map { a in
            AppRelease.Asset(name: a.name, url: a.browser_download_url, size: a.size,
                             sha256: a.digest.flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)).lowercased() : nil })
        }
        // The release workflow names the image Burrow-<version>.dmg; fall back to the only DMG there is.
        let dmgs = assets.filter { $0.name.lowercased().hasSuffix(".dmg") }
        let dmg = dmgs.first { $0.name == "Burrow-\(version).dmg" } ?? (dmgs.count == 1 ? dmgs[0] : nil)
        let signature = dmg.flatMap { dmg in assets.first { $0.name == dmg.name + ".sig" } }
        return AppRelease(version: version, tag: p.tag_name,
                          title: p.name.flatMap { $0.isEmpty ? nil : $0 } ?? "Burrow \(version)",
                          notes: p.body ?? "", page: p.html_url, publishedAt: p.published_at,
                          isPrerelease: p.prerelease || version.isPrerelease, dmg: dmg, signature: signature)
    }
}

// MARK: - Installing

enum UpdateError: LocalizedError {
    case notInstallable(String)
    case download(String)
    case verification(String)
    case install(String)

    var errorDescription: String? {
        switch self {
        case .notInstallable(let s), .download(let s), .verification(let s), .install(let s): s
        }
    }
}

enum UpdateInstaller {
    /// Why this copy of Burrow can't replace itself, or nil when it can.
    static func blocker(for release: AppRelease) -> String? {
        let app = Bundle.main.bundleURL
        guard app.pathExtension == "app", Bundle.main.bundleIdentifier != nil else {
            return "This is a development build that isn't running from an app bundle."
        }
        if app.path.contains("/AppTranslocation/") {
            return "macOS is running Burrow from a temporary, read-only location. Move Burrow to your Applications folder, open it from there, and try again."
        }
        if let values = try? app.resourceValues(forKeys: [.volumeIsReadOnlyKey]), values.volumeIsReadOnly == true {
            return "Burrow is running from a read-only disk (probably its disk image). Drag it to your Applications folder, open it from there, and try again."
        }
        guard UpdateConfig.publicKey != nil else {
            return "This build has no update signing key, so it can't verify downloads. Download the new version from GitHub instead."
        }
        guard release.dmg != nil, release.signature != nil else {
            return "This release has no signed disk image, so it can't be installed automatically. Download it from GitHub instead."
        }
        return nil
    }

    /// Where updates are downloaded and unpacked; emptied at launch and after each attempt.
    static var workDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "io.github.pimzino.burrow")
            .appendingPathComponent("Updates")
    }

    static func cleanUp() {
        try? FileManager.default.removeItem(at: workDirectory)
    }

    // 1. Download

    /// Downloads the release's DMG and signature into a fresh work directory.
    static func download(_ release: AppRelease, progress: @escaping @Sendable (Double) -> Void) async throws -> (dmg: URL, signature: Data) {
        guard let dmgAsset = release.dmg, let sigAsset = release.signature else {
            throw UpdateError.notInstallable("The release has no signed disk image.")
        }
        // A DMG of Burrow is a few MB; refuse anything absurd before spending the bandwidth.
        guard dmgAsset.size > 0, dmgAsset.size < 512 * 1024 * 1024, sigAsset.size < 4096 else {
            throw UpdateError.download("The release's files have unexpected sizes.")
        }
        cleanUp()
        let dir = workDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let (sigData, sigResponse) = try await URLSession.shared.data(from: sigAsset.url)
        try checkHTTP(sigResponse, what: sigAsset.name)

        let delegate = DownloadProgress(progress)
        var request = URLRequest(url: dmgAsset.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let (temp, response) = try await URLSession.shared.download(for: request, delegate: delegate)
        try checkHTTP(response, what: dmgAsset.name)
        let dmg = dir.appendingPathComponent(dmgAsset.name)
        try FileManager.default.moveItem(at: temp, to: dmg)
        progress(1)
        return (dmg, sigData)
    }

    private static func checkHTTP(_ response: URLResponse, what: String) throws {
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError.download("Downloading \(what) failed (HTTP \(http.statusCode)).")
        }
    }

    // 2. Verify the download

    /// Checks size, GitHub's digest and, above all, the Ed25519 signature over the whole DMG.
    static func verify(dmg: URL, signature: Data, release: AppRelease,
                       publicKey: Curve25519.Signing.PublicKey? = UpdateConfig.publicKey) throws {
        guard let publicKey else { throw UpdateError.verification("This build has no update signing key.") }
        guard let asset = release.dmg else { throw UpdateError.verification("The release has no disk image.") }
        let data = try Data(contentsOf: dmg, options: .mappedIfSafe)
        guard data.count == asset.size else {
            throw UpdateError.verification("The download is \(data.count) bytes, but GitHub lists \(asset.size).")
        }
        if let expected = asset.sha256 {
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual == expected else { throw UpdateError.verification("The download doesn't match GitHub's checksum.") }
        }
        let text = String(decoding: signature, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw = Data(base64Encoded: text), raw.count == 64 else {
            throw UpdateError.verification("The release's signature file is malformed.")
        }
        guard publicKey.isValidSignature(raw, for: data) else {
            throw UpdateError.verification("The disk image's signature is not valid. It was not signed by Burrow's release key, so it was not installed.")
        }
    }

    // 3. Unpack and check the new app

    /// Mounts the DMG, copies Burrow.app next to the running app (same volume, so the swap is a rename),
    /// detaches, and checks the copy. Returns the staged bundle.
    static func stage(dmg: URL, release: AppRelease) async throws -> URL {
        let mount = dmg.deletingLastPathComponent().appendingPathComponent("mount")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        let attach = try await tool("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen",
                                                         "-mountpoint", mount.path])
        guard attach.succeeded else { throw UpdateError.install("The disk image couldn't be opened: \(attach.stderrString.trimmed)") }
        let staged: Result<URL, Error>
        do {
            staged = .success(try await copyApp(from: mount, release: release))
        } catch {
            staged = .failure(error)
        }
        // Detaching can race Spotlight or the copy's last file handles, so it's retried with -force.
        for force in [false, true] {
            let r = try? await tool("/usr/bin/hdiutil", ["detach", mount.path] + (force ? ["-force"] : []))
            if r?.succeeded == true { break }
        }
        return try staged.get()
    }

    private static func copyApp(from mount: URL, release: AppRelease) async throws -> URL {
        let contents = (try? FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)) ?? []
        let apps = contents.filter { $0.pathExtension == "app" }
        guard let source = apps.first(where: { $0.lastPathComponent == Bundle.main.bundleURL.lastPathComponent })
                ?? apps.first(where: { $0.lastPathComponent == "Burrow.app" }) ?? (apps.count == 1 ? apps[0] : nil) else {
            throw UpdateError.install("The disk image doesn't contain Burrow.app.")
        }

        let running = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let staging = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                  appropriateFor: running, create: true)
        let staged = staging.appendingPathComponent(running.lastPathComponent)
        let copy = try await tool("/usr/bin/ditto", [source.path, staged.path])
        guard copy.succeeded else {
            try? FileManager.default.removeItem(at: staging)
            throw UpdateError.install("Copying the new version failed: \(copy.stderrString.trimmed)")
        }
        do {
            try validate(app: staged, release: release)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        return staged
    }

    /// The new bundle must be the same app, exactly the advertised (newer) version, validly signed, and
    /// signed by the same team when the running app is.
    static func validate(app: URL, release: AppRelease) throws {
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw UpdateError.verification("The new version's Info.plist can't be read.")
        }
        guard let id = info["CFBundleIdentifier"] as? String, id == Bundle.main.bundleIdentifier else {
            throw UpdateError.verification("The disk image contains a different app (\(info["CFBundleIdentifier"] as? String ?? "unknown")).")
        }
        guard let version = (info["CFBundleShortVersionString"] as? String).flatMap(SemanticVersion.init), version == release.version else {
            throw UpdateError.verification("The app inside the disk image is not version \(release.version).")
        }
        if let current = UpdateConfig.currentVersion, version <= current {
            throw UpdateError.verification("The disk image contains version \(version), which is not newer than \(current).")
        }

        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
            throw UpdateError.verification("The new version's code signature can't be read.")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        var cfError: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(staticCode, flags, nil, &cfError)
        guard status == errSecSuccess else {
            let reason = cfError.map { ($0.takeRetainedValue() as Error).localizedDescription } ?? "OSStatus \(status)"
            throw UpdateError.verification("The new version's code signature is invalid (\(reason)).")
        }
        if let team = runningTeamIdentifier, teamIdentifier(of: staticCode) != team {
            throw UpdateError.verification("The new version is not signed by the same developer (team \(team)) as this copy of Burrow.")
        }
    }

    private static var runningTeamIdentifier: String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        return teamIdentifier(of: staticCode)
    }

    private static func teamIdentifier(of code: SecStaticCode) -> String? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    // 4. Swap and relaunch

    /// Puts the staged bundle where the running app is. Returns the installed app's URL.
    static func swapIn(staged: URL) async throws -> URL {
        let target = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let folder = target.deletingLastPathComponent()
        let fm = FileManager.default
        if fm.isWritableFile(atPath: folder.path), fm.isWritableFile(atPath: target.path) {
            // Atomic on APFS: the old bundle ends up at the staged path, then it is removed.
            if renamex_np(staged.path, target.path, UInt32(RENAME_SWAP)) == 0 {
                try? fm.removeItem(at: staged.deletingLastPathComponent())
                return target
            }
            let swapErrno = errno
            if swapErrno == EPERM || swapErrno == EACCES {
                throw UpdateError.install(permissionMessage(swapErrno))
            }
            // Volumes without RENAME_SWAP: move the old bundle aside, then the new one in, restoring on failure.
            let backup = staged.deletingLastPathComponent().appendingPathComponent("previous-" + target.lastPathComponent)
            guard rename(target.path, backup.path) == 0 else { throw UpdateError.install(permissionMessage(errno)) }
            guard rename(staged.path, target.path) == 0 else {
                let e = errno
                _ = rename(backup.path, target.path)
                throw UpdateError.install(permissionMessage(e))
            }
            try? fm.removeItem(at: staged.deletingLastPathComponent())
            return target
        }
        // A folder only an administrator can change (e.g. /Applications for a standard user): ask macOS for
        // an administrator's approval for the two moves. Paths travel as arguments, never inside the script.
        let backup = staged.deletingLastPathComponent().appendingPathComponent("previous-" + target.lastPathComponent)
        let script = """
        on run argv
            do shell script "/bin/mv -f " & quoted form of item 1 of argv & " " & quoted form of item 3 of argv & " && /bin/mv -f " & quoted form of item 2 of argv & " " & quoted form of item 1 of argv & " || { /bin/mv -f " & quoted form of item 3 of argv & " " & quoted form of item 1 of argv & "; exit 1; }" with prompt "Burrow wants to install an update." with administrator privileges
        end run
        """
        let result = try await tool("/usr/bin/osascript", ["-e", script, target.path, staged.path, backup.path])
        guard result.succeeded else {
            let cancelled = result.stderrString.contains("-128")
            throw UpdateError.install(cancelled ? "Installing the update was cancelled." : "The update couldn't be installed: \(result.stderrString.trimmed)")
        }
        try? fm.removeItem(at: staged.deletingLastPathComponent())   // the old bundle is root-owned now: best effort
        return target
    }

    private static func permissionMessage(_ code: Int32) -> String {
        if code == EPERM || code == EACCES {
            return "macOS didn't allow Burrow to replace itself (\(String(cString: strerror(code)))). If System Settings › Privacy & Security › App Management lists Burrow, turn it on, or install the new version from the disk image."
        }
        return "Replacing Burrow failed: \(String(cString: strerror(code)))."
    }

    /// Starts a detached shell (its own session, outside the orphan guard) that waits for this process to
    /// exit and then opens the installed app. The caller quits right after.
    static func scheduleRelaunch(of app: URL) throws {
        let script = #"pid="$1"; app="$2"; i=0; while /bin/kill -0 "$pid" 2>/dev/null && [ "$i" -lt 600 ]; do /bin/sleep 0.1; i=$((i+1)); done; exec /usr/bin/open "$app""#
        let args = ["/bin/sh", "-c", script, "sh", String(getpid()), app.path]
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd: Int32 in [0, 1, 2] { posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0) }
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        let argv = args.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, "/bin/sh", &actions, &attr, argv, environ)
        guard rc == 0 else { throw UpdateError.install("Couldn't schedule the relaunch (\(String(cString: strerror(rc)))).") }
    }

    private static func tool(_ path: String, _ args: [String]) async throws -> ProcessResult {
        try await Subprocess.run(path, args, environment: ProcessInfo.processInfo.environment, timeout: 300)
    }
}

/// Reports a download task's progress (`fractionCompleted`) as it runs.
private final class DownloadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: @Sendable (Double) -> Void
    private var observation: NSKeyValueObservation?

    init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        observation = task.progress.observe(\.fractionCompleted, options: [.new]) { [report] progress, _ in
            report(progress.fractionCompleted)
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
