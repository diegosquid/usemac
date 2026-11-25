import AppKit
import Combine
import Foundation
import UseMacProtocol
import Sparkle

@MainActor
public final class UpdateController: ObservableObject {
    @Published public private(set) var canCheckForUpdates: Bool = false
    @Published public var automaticallyChecksForUpdates: Bool = true

    public let isConfiguredForRelease: Bool
    public let feedURL: String
    public let currentVersion: String
    public let buildNumber: String

    private let updaterController: SPUStandardUpdaterController
    private var canCheckObservation: NSKeyValueObservation?

    public init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let pubKey = (info["SUPublicEDKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedFeed = (info["SUFeedURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let configured = !pubKey.isEmpty

        self.isConfiguredForRelease = configured
        self.feedURL = (resolvedFeed?.isEmpty == false) ? resolvedFeed! : UseMacDefaults.defaultAppcastURL
        self.currentVersion = (info["CFBundleShortVersionString"] as? String) ?? UseMacDefaults.version
        self.buildNumber = (info["CFBundleVersion"] as? String) ?? UseMacDefaults.buildNumber

        // Only auto-start Sparkle when signed with a release EdDSA key; prevents noisy dev alerts
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: configured,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        self.automaticallyChecksForUpdates = updaterController.updater.automaticallyChecksForUpdates
        self.canCheckForUpdates = configured ? updaterController.updater.canCheckForUpdates : false

        if configured {
            self.canCheckObservation = updaterController.updater.observe(
                \.canCheckForUpdates,
                options: [.initial, .new]
            ) { [weak self] updater, _ in
                Task { @MainActor [weak self] in
                    self?.canCheckForUpdates = updater.canCheckForUpdates
                }
            }
        }
    }

    public func setAutomaticallyChecks(_ enabled: Bool) {
        automaticallyChecksForUpdates = enabled
        updaterController.updater.automaticallyChecksForUpdates = enabled
    }

    public func checkForUpdates() {
        guard isConfiguredForRelease else { return }
        NSApp.activate(ignoringOtherApps: true)
        updaterController.checkForUpdates(nil)
    }
}
