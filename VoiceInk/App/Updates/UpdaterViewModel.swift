import Combine
import Foundation
import Sparkle
import SwiftUI

@MainActor
final class UpdaterViewModel: NSObject, ObservableObject, SPUUpdaterDelegate {
    struct AvailableUpdate: Equatable {
        let versionIdentifier: String
        let displayVersion: String
    }

    private enum DefaultsKey {
        // Keep the existing persisted key strings so current user preferences migrate automatically.
        static let automaticUpdateChecks = "VoiceInkChecksForUpdatesOnLaunch"
        static let interactedUpdateVersions = "VoiceInkInteractedUpdateVersions"
        static let sparkleAutomaticChecks = "SUEnableAutomaticChecks"
    }

    private let defaults: UserDefaults
    private var isUserInitiatedUpdateCheck = false
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: nil
    )

    @Published var canCheckForUpdates = false
    @Published private(set) var checksForUpdatesWhenDashboardAppears = false
    @Published private(set) var availableUpdate: AvailableUpdate?

    override init() {
        let defaults = UserDefaults.standard
        self.defaults = defaults
        checksForUpdatesWhenDashboardAppears = Self.initialAutomaticCheckPreference(in: defaults)
        super.init()

        let updater = updaterController.updater

        // VoiceInk owns automatic discovery through Sparkle's non-presenting probe.
        // Keeping Sparkle's scheduler disabled prevents it from showing an update
        // window independently of the Dashboard button.
        updater.automaticallyChecksForUpdates = false
        updaterController.startUpdater()

        #if LOCAL_BUILD
        // The local route rebuilds from source and never drives Sparkle's
        // installer, so the action stays available regardless of Sparkle state.
        canCheckForUpdates = true
        // A rebuild restarts the app, so the run that just finished belongs to
        // the previous process. Surface its outcome here.
        LocalUpdateService.shared.presentResultIfRecent()
        #else
        canCheckForUpdates = updater.canCheckForUpdates
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
        #endif
    }

    func setChecksForUpdatesWhenDashboardAppears(_ value: Bool) {
        guard checksForUpdatesWhenDashboardAppears != value else { return }

        checksForUpdatesWhenDashboardAppears = value
        defaults.set(value, forKey: DefaultsKey.automaticUpdateChecks)

        if value {
            checkForUpdateInformationIfPossible()
        } else {
            availableUpdate = nil
        }
    }

    func checkForUpdatesIfDue() {
        guard checksForUpdatesWhenDashboardAppears else { return }

        let updater = updaterController.updater
        guard !updater.sessionInProgress else { return }

        if let lastCheckDate = updater.lastUpdateCheckDate {
            let elapsed = Date().timeIntervalSince(lastCheckDate)
            guard elapsed < 0 || elapsed >= updater.updateCheckInterval else { return }
        }

        checkForUpdateInformationIfPossible()
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }

        // Any explicit check is interaction with the currently advertised update.
        // Persist it before presenting Sparkle so dismissing or closing the native
        // window cannot make the Dashboard button reappear for the same build.
        if let availableUpdate {
            rememberInteraction(with: availableUpdate.versionIdentifier)
            self.availableUpdate = nil
        }

        #if LOCAL_BUILD
        startLocalRebuild()
        #else
        if !updaterController.updater.sessionInProgress {
            isUserInitiatedUpdateCheck = true
        }
        updaterController.checkForUpdates(nil)
        #endif
    }

    #if LOCAL_BUILD
    /// Upstream's appcast is used only as a *signal*. Its payload is a signed
    /// upstream release, which would overwrite this machine's ad-hoc local
    /// build and drop fork changes — so the action rebuilds this fork instead.
    private func startLocalRebuild(force: Bool = false) {
        LocalUpdateWindowController.shared.show()
        LocalUpdateService.shared.start(force: force)
    }
    #endif

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let update = AvailableUpdate(
            versionIdentifier: item.versionString,
            displayVersion: item.displayVersionString
        )

        #if LOCAL_BUILD
        if LocalUpdateService.shared.automaticallyBuildUpstreamReleases,
           !hasInteracted(with: update.versionIdentifier) {
            rememberInteraction(with: update.versionIdentifier)
            availableUpdate = nil
            startLocalRebuild()
            return
        }
        #endif

        if isUserInitiatedUpdateCheck {
            rememberInteraction(with: update.versionIdentifier)
            availableUpdate = nil
        } else if checksForUpdatesWhenDashboardAppears && !hasInteracted(with: update.versionIdentifier) {
            availableUpdate = update
        } else {
            availableUpdate = nil
        }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        availableUpdate = nil
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        isUserInitiatedUpdateCheck = false
    }

    private func checkForUpdateInformationIfPossible() {
        let updater = updaterController.updater
        guard !updater.sessionInProgress else { return }
        updater.checkForUpdateInformation()
    }

    private func hasInteracted(with versionIdentifier: String) -> Bool {
        defaults.stringArray(forKey: DefaultsKey.interactedUpdateVersions)?
            .contains(versionIdentifier) == true
    }

    private func rememberInteraction(with versionIdentifier: String) {
        var versions = defaults.stringArray(forKey: DefaultsKey.interactedUpdateVersions) ?? []
        guard !versions.contains(versionIdentifier) else { return }
        versions.append(versionIdentifier)
        defaults.set(versions, forKey: DefaultsKey.interactedUpdateVersions)
    }

    private static func initialAutomaticCheckPreference(in defaults: UserDefaults) -> Bool {
        if let preference = defaults.object(forKey: DefaultsKey.automaticUpdateChecks) as? Bool {
            return preference
        }

        // Preserve an explicit choice made through VoiceInk's previous Sparkle-backed
        // setting. With no saved choice, keep VoiceInk's existing opt-in default.
        let preference = (defaults.object(forKey: DefaultsKey.sparkleAutomaticChecks) as? Bool) ?? true

        defaults.set(preference, forKey: DefaultsKey.automaticUpdateChecks)
        return preference
    }
}

struct CheckForUpdatesView: View {
    @ObservedObject var updaterViewModel: UpdaterViewModel

    var body: some View {
        Button("Check for Updates…", action: updaterViewModel.checkForUpdates)
            .disabled(!updaterViewModel.canCheckForUpdates)
    }
}
