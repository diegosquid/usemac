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

    /// Receive pre-release builds from the appcast's "beta" channel. Defaults to on for beta builds (so a beta
    /// tester gets the next beta) and off for stable builds.
    @Published public private(set) var receivesBetaUpdates: Bool

    private let updaterController: SPUStandardUpdaterController
    private let channelDelegate: UpdaterChannelDelegate
    private var canCheckObservation: NSKeyValueObservation?

    private static let betaDefaultsKey = "usemac.updates.receiveBeta"

    /// True for versions with a pre-release suffix, such as 0.6.0-beta.1.
    public static func isPrerelease(_ version: String) -> Bool {
        version.contains("-")
    }

    public init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let pubKey = (info["SUPublicEDKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedFeed = (info["SUFeedURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let configured = !pubKey.isEmpty

        self.isConfiguredForRelease = configured
        self.feedURL = (resolvedFeed?.isEmpty == false) ? resolvedFeed! : UseMacDefaults.defaultAppcastURL
        let version = (info["CFBundleShortVersionString"] as? String) ?? UseMacDefaults.version
        self.currentVersion = version
        self.buildNumber = (info["CFBundleVersion"] as? String) ?? UseMacDefaults.buildNumber

        let storedBeta = UserDefaults.standard.object(forKey: Self.betaDefaultsKey) as? Bool
        let receivesBeta = storedBeta ?? Self.isPrerelease(version)
        self.receivesBetaUpdates = receivesBeta
        self.channelDelegate = UpdaterChannelDelegate(receivesBeta: receivesBeta)

        // Only auto-start Sparkle when signed with a release EdDSA key; prevents noisy dev alerts
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: configured,
            updaterDelegate: channelDelegate,
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

    public func setReceivesBetaUpdates(_ enabled: Bool) {
        receivesBetaUpdates = enabled
        channelDelegate.receivesBeta = enabled
        UserDefaults.standard.set(enabled, forKey: Self.betaDefaultsKey)
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

/// Tells Sparkle which appcast channels to consider. Items without a channel are stable and always offered;
/// items in the "beta" channel only when the user receives beta updates.
private final class UpdaterChannelDelegate: NSObject, SPUUpdaterDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _receivesBeta: Bool

    init(receivesBeta: Bool) {
        _receivesBeta = receivesBeta
    }

    var receivesBeta: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _receivesBeta
        }
        set {
            lock.lock()
            _receivesBeta = newValue
            lock.unlock()
        }
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        receivesBeta ? ["beta"] : []
    }
}
