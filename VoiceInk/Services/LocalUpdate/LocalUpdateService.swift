#if LOCAL_BUILD

import Combine
import Foundation

/// Fork-local replacement for Sparkle's download-and-install step.
///
/// Upstream's appcast advertises *signed release* builds; installing one would
/// overwrite this machine's ad-hoc local build and discard fork changes. Instead
/// we rebuild from source: fetch, merge `upstream/main`, build, install, relaunch.
///
/// The build runs as a launchd job rather than a child `Process` on purpose.
/// `scripts/auto-update-local.sh` calls `pkill -x VoiceInk` before swapping the
/// bundle, which would kill any process parented to the app mid-build.
@MainActor
final class LocalUpdateService: ObservableObject {
    static let shared = LocalUpdateService()

    enum Phase: String {
        case idle
        case starting
        case fetching
        case merging
        case preparing
        case building
        case installing
        case relaunching
        case done
        case uptodate
        case failed

        var isTerminal: Bool {
            switch self {
            case .done, .uptodate, .failed: return true
            default: return false
            }
        }

        var describes: String {
            switch self {
            case .idle: return "Idle"
            case .starting: return "Starting build job…"
            case .fetching: return "Fetching upstream…"
            case .merging: return "Merging upstream changes…"
            case .preparing: return "Preparing dependencies…"
            case .building: return "Building VoiceInk (this takes a while)…"
            case .installing: return "Installing to /Applications…"
            case .relaunching: return "Relaunching VoiceInk…"
            case .done: return "Update complete"
            case .uptodate: return "Already up to date with upstream"
            case .failed: return "Update failed"
            }
        }
    }

    private enum DefaultsKey {
        static let repositoryPath = "LocalUpdateRepositoryPath"
        static let automaticallyBuild = "LocalUpdateAutomaticallyBuildUpstreamReleases"
    }

    private static let jobLabel = "com.prakashjoshipax.VoiceInk.localupdate"

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var logTail: String = ""
    @Published private(set) var startedAt: Date?
    @Published private(set) var lastError: String?

    /// Opt-in: run the whole build automatically when upstream publishes a
    /// release, with no click. Off by default — a build quits the app for
    /// several minutes, which is hostile to do unannounced.
    var automaticallyBuildUpstreamReleases: Bool {
        get { defaults.bool(forKey: DefaultsKey.automaticallyBuild) }
        set { defaults.set(newValue, forKey: DefaultsKey.automaticallyBuild) }
    }

    var isRunning: Bool { startedAt != nil && !phase.isTerminal }

    private let defaults = UserDefaults.standard
    private let fileManager = FileManager.default
    private var pollTimer: Timer?
    private var logOffset: UInt64 = 0
    private var lineBuffer = ""

    private lazy var logURL: URL = {
        let dir = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/VoiceInk", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("local-update.log")
    }()

    private var launchAgentURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(Self.jobLabel).plist")
    }

    // MARK: - Repository discovery

    /// Explicit override wins; otherwise probe the usual checkout locations.
    /// A directory only counts if it actually carries the update script.
    var repositoryURL: URL? {
        if let path = defaults.string(forKey: DefaultsKey.repositoryPath),
           !path.isEmpty {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            return isUsableRepository(url) ? url : nil
        }

        let home = fileManager.homeDirectoryForCurrentUser

        // Order matters. A launchd agent cannot read or execute files under
        // TCC-protected folders (~/Documents, ~/Desktop, ~/Downloads) without
        // Full Disk Access, so prefer checkouts that live outside them. The
        // runner's own clone is already proven to build on this machine.
        let candidates = [
            "actions-runners/voiceink/_work/VoiceInk/VoiceInk",
            "Library/Application Support/VoiceInk/src",
            "Developer/VoiceInk",
            "src/VoiceInk",
            "Documents/GitHub.nosync/VoiceInk",
            "Documents/Github/VoiceInk",
            "Documents/GitHub/VoiceInk",
        ].map { home.appendingPathComponent($0, isDirectory: true) }

        return candidates.first(where: isUsableRepository)
    }

    func setRepositoryPath(_ path: String?) {
        if let path, !path.isEmpty {
            defaults.set(path, forKey: DefaultsKey.repositoryPath)
        } else {
            defaults.removeObject(forKey: DefaultsKey.repositoryPath)
        }
    }

    /// macOS denies a launchd agent read/execute on these, even though `stat`
    /// still succeeds — so an unguarded run fails with a bare
    /// "Operation not permitted" from bash.
    func isTCCProtected(_ url: URL) -> Bool {
        let home = fileManager.homeDirectoryForCurrentUser.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return ["Documents", "Desktop", "Downloads"].contains { folder in
            path == "\(home)/\(folder)" || path.hasPrefix("\(home)/\(folder)/")
        }
    }

    private func isUsableRepository(_ url: URL) -> Bool {
        fileManager.isReadableFile(atPath: url.appendingPathComponent("scripts/auto-update-local.sh").path)
    }

    // MARK: - Lifecycle

    private init() {
        restoreResultFromPreviousRun()
    }

    /// The app is replaced and relaunched mid-run, so a completed build always
    /// finishes in a *different* process than the one that started it. Recover
    /// the outcome from the log so the result is not silently lost.
    private func restoreResultFromPreviousRun() {
        guard let attributes = try? fileManager.attributesOfItem(atPath: logURL.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let modified = attributes[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < 900
        else { return }

        // Read only the tail: a full build log runs to several megabytes and
        // this happens during app launch.
        guard let handle = try? FileHandle(forReadingFrom: logURL) else { return }
        defer { try? handle.close() }
        let window: UInt64 = 64 * 1024
        try? handle.seek(toOffset: size > window ? size - window : 0)
        guard let data = try? handle.readToEnd() else { return }

        logOffset = size
        let contents = String(decoding: data, as: UTF8.self)
        logTail = Self.trimTail(of: contents)

        var restored: Phase?
        for line in contents.components(separatedBy: "\n").reversed() {
            if let parsed = Self.parsePhase(from: line) {
                restored = parsed
                break
            }
        }
        guard let restored else { return }

        // The build outlives this process: the app is killed and replaced during
        // install, so a run started earlier finishes in a *different* process.
        // If the log stops on a non-terminal phase and launchd no longer has the
        // job, the run is over — resolve it, otherwise `isRunning` would latch
        // on forever and block every future update.
        if restored.isTerminal || isJobLoaded {
            phase = restored
            startedAt = modified
        } else {
            // Reaching install/relaunch means the bundle swap happened — which
            // is exactly why this process is running the new build.
            phase = (restored == .installing || restored == .relaunching) ? .done : .failed
            startedAt = nil
        }
    }

    private var isJobLoaded: Bool {
        Self.runLaunchctl(["print", "gui/\(getuid())/\(Self.jobLabel)"]).status == 0
    }

    /// Reopen the progress window after the rebuild relaunched the app, so a
    /// completed or failed run is not silently swallowed by the restart.
    func presentResultIfRecent() {
        guard phase == .done || phase == .failed, startedAt == nil || !isRunning else { return }
        guard let attributes = try? fileManager.attributesOfItem(atPath: logURL.path),
              let modified = attributes[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < 300
        else { return }
        LocalUpdateWindowController.shared.show()
    }

    // MARK: - Running

    /// Non-throwing entry point for UI call sites: surfaces failures through
    /// `lastError` so the progress window can render them.
    func start(force: Bool = false) {
        do {
            try startUpdate(force: force)
        } catch {
            lastError = error.localizedDescription
            phase = .failed
        }
    }

    func startUpdate(force: Bool = false) throws {
        guard !isRunning else { return }
        guard let repository = repositoryURL else {
            throw LocalUpdateError.repositoryNotFound
        }
        guard !isTCCProtected(repository) else {
            throw LocalUpdateError.repositoryTCCProtected(repository.path)
        }

        phase = .starting
        startedAt = Date()
        lastError = nil
        logTail = ""
        lineBuffer = ""
        logOffset = 0

        fileManager.createFile(atPath: logURL.path, contents: nil)
        try writeLaunchAgent(repository: repository, force: force)

        // Clear any previous job before bootstrapping; bootout fails harmlessly
        // when nothing is loaded.
        _ = Self.runLaunchctl(["bootout", "gui/\(getuid())/\(Self.jobLabel)"])
        let bootstrap = Self.runLaunchctl(["bootstrap", "gui/\(getuid())", launchAgentURL.path])
        guard bootstrap.status == 0 else {
            phase = .failed
            throw LocalUpdateError.launchFailed(bootstrap.output)
        }

        startPolling()
    }

    private func writeLaunchAgent(repository: URL, force: Bool) throws {
        let script = repository.appendingPathComponent("scripts/auto-update-local.sh").path

        // launchd gives a job a bare PATH; the script needs git, make, cmake and
        // xcodebuild. Prepend both Homebrew prefixes plus the standard locations.
        let path = [
            "/opt/homebrew/bin", "/usr/local/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ].joined(separator: ":")

        let job: [String: Any] = [
            "Label": Self.jobLabel,
            "ProgramArguments": ["/bin/bash", script],
            // Deliberately no WorkingDirectory: pointing it at the checkout made
            // launchd start bash with an unusable cwd ("error retrieving current
            // directory"). The script cd's to its own ROOT_DIR anyway.
            "EnvironmentVariables": [
                "PATH": path,
                "FORCE_BUILD": force ? "1" : "0",
                "SKIP_SYNC": "0",
                "PUSH_ORIGIN": "1",
                "RELAUNCH": "1",
                "RESET_TCC": "1",
            ],
            "StandardOutPath": logURL.path,
            "StandardErrorPath": logURL.path,
            "RunAtLoad": true,
            "AbandonProcessGroup": true,
        ]

        let data = try PropertyListSerialization.data(
            fromPropertyList: job, format: .xml, options: 0
        )
        try fileManager.createDirectory(
            at: launchAgentURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: launchAgentURL, options: .atomic)
    }

    func cancelPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func startPolling() {
        cancelPolling()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.drainLog() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func drainLog() {
        guard let handle = try? FileHandle(forReadingFrom: logURL) else { return }
        defer { try? handle.close() }

        try? handle.seek(toOffset: logOffset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }
        logOffset += UInt64(data.count)

        lineBuffer += String(decoding: data, as: UTF8.self)
        var lines = lineBuffer.components(separatedBy: "\n")
        lineBuffer = lines.removeLast()  // keep any partial trailing line

        for line in lines {
            if let parsed = Self.parsePhase(from: line) {
                phase = parsed
            }
        }

        logTail = Self.trimTail(of: logTail + lines.joined(separator: "\n") + "\n")

        if phase.isTerminal {
            cancelPolling()
        }
    }

    // MARK: - Parsing helpers

    private static let phaseMarker = "[auto-update][phase] "

    static func parsePhase(from line: String) -> Phase? {
        guard let range = line.range(of: phaseMarker) else { return nil }
        let raw = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return Phase(rawValue: raw)
    }

    /// Keep the window's log view bounded; a full build log is megabytes.
    private static func trimTail(of text: String, maxLines: Int = 400) -> String {
        let lines = text.components(separatedBy: "\n")
        guard lines.count > maxLines else { return text }
        return lines.suffix(maxLines).joined(separator: "\n")
    }

    private static func runLaunchctl(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

enum LocalUpdateError: LocalizedError {
    case repositoryNotFound
    case repositoryTCCProtected(String)
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .repositoryNotFound:
            return "Could not find your VoiceInk checkout. Set its path in Settings → Updates."
        case .repositoryTCCProtected(let path):
            return """
            The checkout at \(path) is inside a protected folder             (Documents, Desktop or Downloads). macOS blocks the background build             job from reading it. Either point the updater at a checkout outside             those folders, or grant Full Disk Access to /bin/bash.
            """
        case .launchFailed(let output):
            return "Could not start the build job.\n\(output)"
        }
    }
}

#endif
