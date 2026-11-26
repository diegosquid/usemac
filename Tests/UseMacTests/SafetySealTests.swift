import Foundation
import XCTest
@testable import UseMacEngine
@testable import UseMacProtocol

/// The seal over the saved safety settings. Agents can only make safety stricter, so values written outside UseMac
/// (`defaults write app.usemac …`, then a relaunch) must never loosen anything: they start UseMac paused, with Debug
/// capture off. These use an in-memory key store and scratch UserDefaults suites, never the real Keychain or
/// UseMac's own defaults.
final class SafetySealTests: XCTestCase {
    private typealias Key = StartupSafetyState.DefaultsKey
    private var suiteNames: [String] = []

    override func tearDown() {
        for name in suiteNames {
            UserDefaults().removePersistentDomain(forName: name)
        }
        suiteNames = []
        super.tearDown()
    }

    private func makeDefaults() -> UserDefaults {
        let name = "usemac-safety-seal-tests-\(UUID().uuidString)"
        suiteNames.append(name)
        return UserDefaults(suiteName: name)!
    }

    private func makeService() -> UseMacEngineService {
        UseMacEngineService(socketPath: "/tmp/usemac-seal-\(UUID().uuidString.prefix(8)).sock", extensionPort: 0)
    }

    /// The Keychain item, in memory.
    private final class MemoryKeychain: SafetySealSecretStore {
        struct Failure: Error {}
        var data: Data?
        var failsReading = false
        var failsWriting = false
        private(set) var writes = 0

        func readSecret() throws -> Data? {
            if failsReading { throw Failure() }
            return data
        }

        func writeSecret(_ data: Data) throws {
            if failsWriting { throw Failure() }
            self.data = data
            writes += 1
        }

        var secret: SafetySealSecret? { data.flatMap(SafetySealSecret.init(encoded:)) }
    }

    /// A Mac where UseMac already sealed `state`, as if it had been running and saving.
    private func sealedMac(_ state: StartupSafetyState) -> (UserDefaults, MemoryKeychain) {
        let defaults = makeDefaults()
        let keychain = MemoryKeychain()
        let store = SafetySettingsStore(defaults: defaults, secretStore: keychain)
        _ = store.load()
        store.savePolicy(state.policy, previous: .autonomous)
        if let beforePause = state.policyBeforePause, state.policy == .paused {
            // Paused from `beforePause`, the way the app saves a pause.
            store.savePolicy(beforePause, previous: .autonomous)
            store.savePolicy(.paused, previous: beforePause)
        }
        store.saveKillSwitch(state.killSwitchTripped)
        store.saveDebugCapture(state.debugCaptureEnabled)
        XCTAssertEqual(SafetySettingsStore(defaults: defaults, secretStore: keychain).load().check, .verified)
        return (defaults, keychain)
    }

    private func relaunch(_ defaults: UserDefaults, _ keychain: MemoryKeychain) -> SafetySettingsStore.Launch {
        SafetySettingsStore(defaults: defaults, secretStore: keychain).load()
    }

    private let loosened = StartupSafetyState(policy: .readOnly, policyBeforePause: .readOnly, killSwitchTripped: true, debugCaptureEnabled: false)

    // MARK: - Encoding

    /// Changing the encoding changes every seal, so every Mac would start paused after the update.
    func testTheEncodingAndTheSealDontChange() throws {
        let saved = SavedSafetySettings(policy: "readOnly", policyBeforePause: nil, killSwitchTripped: true, debugCaptureEnabled: false)
        let encoding = String(decoding: SafetySeal.canonicalEncoding(of: saved, generation: 7), as: UTF8.self)
        XCTAssertEqual(
            encoding,
            "UseMac safety seal v1\npolicy=8:readOnly\npolicyBeforePause~\nkillSwitchTripped=1\ndebugCaptureEnabled=0\ngeneration=7\n"
        )

        let secret = SafetySealSecret(key: Data((0..<32).map { UInt8($0) }), generation: 7)
        XCTAssertEqual(SafetySeal.seal(saved, with: secret), "5HaCtNiGBK4S5FUauFIfoKicjE2dm+lCRCbbkxlXKOo=")
        XCTAssertEqual(SafetySeal.version, 1)
    }

    func testNoTwoSetsOfValuesEncodeTheSame() {
        let variants = [
            SavedSafetySettings(policy: nil, policyBeforePause: nil, killSwitchTripped: false, debugCaptureEnabled: false),
            SavedSafetySettings(policy: "", policyBeforePause: nil, killSwitchTripped: false, debugCaptureEnabled: false),
            SavedSafetySettings(policy: nil, policyBeforePause: "", killSwitchTripped: false, debugCaptureEnabled: false),
            SavedSafetySettings(policy: "paused", policyBeforePause: nil, killSwitchTripped: false, debugCaptureEnabled: false),
            SavedSafetySettings(policy: nil, policyBeforePause: "paused", killSwitchTripped: false, debugCaptureEnabled: false),
            SavedSafetySettings(policy: "paused\npolicyBeforePause~", policyBeforePause: nil, killSwitchTripped: false, debugCaptureEnabled: false),
            SavedSafetySettings(policy: nil, policyBeforePause: nil, killSwitchTripped: true, debugCaptureEnabled: false),
            SavedSafetySettings(policy: nil, policyBeforePause: nil, killSwitchTripped: false, debugCaptureEnabled: true)
        ]
        let encodings = variants.map { SafetySeal.canonicalEncoding(of: $0, generation: 1) }
        XCTAssertEqual(Set(encodings).count, variants.count)
        XCTAssertNotEqual(
            SafetySeal.canonicalEncoding(of: variants[0], generation: 1),
            SafetySeal.canonicalEncoding(of: variants[0], generation: 2)
        )
    }

    func testTheKeychainItemRoundTrips() throws {
        let secret = SafetySealSecret.generate()
        XCTAssertEqual(secret.key.count, 32)
        XCTAssertEqual(secret.generation, 0)
        XCTAssertNotEqual(secret.key, SafetySealSecret.generate().key)

        var counted = secret
        counted.generation = 0x0102_0304_0506_0708
        XCTAssertEqual(counted.encoded.count, 41)
        XCTAssertEqual(SafetySealSecret(encoded: counted.encoded), counted)

        XCTAssertNil(SafetySealSecret(encoded: Data()))
        XCTAssertNil(SafetySealSecret(encoded: Data(counted.encoded.dropLast())))
        var wrongVersion = counted.encoded
        wrongVersion[0] = 2
        XCTAssertNil(SafetySealSecret(encoded: wrongVersion))
    }

    func testASealMatchesOnlyItsValuesKeyAndCount() {
        let saved = SavedSafetySettings(loosened)
        let secret = SafetySealSecret(key: Data(repeating: 1, count: 32), generation: 3)
        let seal = SafetySeal.seal(saved, with: secret)
        XCTAssertTrue(SafetySeal.isValid(seal, for: saved, with: secret))

        var otherValues = saved
        otherValues.debugCaptureEnabled = true
        XCTAssertFalse(SafetySeal.isValid(seal, for: otherValues, with: secret))
        XCTAssertFalse(SafetySeal.isValid(seal, for: saved, with: SafetySealSecret(key: Data(repeating: 2, count: 32), generation: 3)))
        XCTAssertFalse(SafetySeal.isValid(seal, for: saved, with: SafetySealSecret(key: secret.key, generation: 4)))
        XCTAssertFalse(SafetySeal.isValid(nil, for: saved, with: secret))
        XCTAssertFalse(SafetySeal.isValid("", for: saved, with: secret))
        XCTAssertFalse(SafetySeal.isValid("not base64", for: saved, with: secret))
        XCTAssertFalse(SafetySeal.isValid(Data(repeating: 0, count: 16).base64EncodedString(), for: saved, with: secret))
    }

    // MARK: - A valid seal

    func testAValidSealKeepsTheSavedValues() {
        let saved = StartupSafetyState(policy: .confirmSensitive, policyBeforePause: .confirmSensitive, killSwitchTripped: false, debugCaptureEnabled: true)
        let (defaults, keychain) = sealedMac(saved)

        let launch = relaunch(defaults, keychain)
        XCTAssertEqual(launch.check, .verified)
        XCTAssertTrue(launch.sealed)
        XCTAssertEqual(launch.state, saved)
        XCTAssertNil(SafetySealNotice(launch.check))

        let service = makeService()
        service.recordSafetySealCheck(launch)
        XCTAssertTrue(service.recentAuditEntries(limit: 10).isEmpty, "a seal that matches adds nothing to History")
    }

    // MARK: - Changed outside UseMac

    /// The bypass this closes: `defaults write app.usemac usemac.safety.debugCaptureEnabled -bool true`, relaunch.
    func testEachLoosenedValueStartsPausedWithDebugCaptureOff() {
        let loosenings: [(String, (UserDefaults) -> Void)] = [
            ("Debug capture on", { $0.set(true, forKey: Key.debugCaptureEnabled) }),
            ("Autonomous", { $0.set("autonomous", forKey: Key.policy) }),
            ("resume to Autonomous", { $0.set("autonomous", forKey: Key.policyBeforePause) }),
            ("Emergency stop cleared", { $0.set(false, forKey: Key.killSwitchTripped) }),
            ("policy removed", { $0.removeObject(forKey: Key.policy) }),
            ("policy written as a number", { $0.set(0, forKey: Key.policy) })
        ]
        for (name, loosen) in loosenings {
            let (defaults, keychain) = sealedMac(loosened)
            loosen(defaults)

            let launch = relaunch(defaults, keychain)
            XCTAssertEqual(launch.check, .tampered(.sealMismatch), name)
            XCTAssertEqual(launch.state.policy, .paused, name)
            XCTAssertFalse(launch.state.debugCaptureEnabled, name)
            XCTAssertNotNil(SafetySealNotice(launch.check), name)
        }
    }

    func testTheFallbackKeepsTheEmergencyStopAndTheModeToResumeTo() {
        let (defaults, keychain) = sealedMac(loosened)
        defaults.set(true, forKey: Key.debugCaptureEnabled)

        let launch = relaunch(defaults, keychain)
        XCTAssertEqual(launch.state, StartupSafetyState(policy: .paused, policyBeforePause: .readOnly, killSwitchTripped: true, debugCaptureEnabled: false))
        XCTAssertEqual(GovernanceResume.policyAfterResume(current: launch.state.policy, beforePause: launch.state.policyBeforePause), .readOnly)

        let stopOff = StartupSafetyState(policy: .ask, policyBeforePause: .ask, killSwitchTripped: false, debugCaptureEnabled: true).tamperFallback
        XCTAssertEqual(stopOff, StartupSafetyState(policy: .paused, policyBeforePause: .ask, killSwitchTripped: false, debugCaptureEnabled: false))
    }

    func testAgentsCantLeaveTheFallback() async {
        let (defaults, keychain) = sealedMac(loosened)
        defaults.set("autonomous", forKey: Key.policy)
        let launch = relaunch(defaults, keychain)

        let service = makeService()
        launch.state.apply(to: service)
        XCTAssertEqual(service.getGovernancePolicy(), .paused)
        XCTAssertFalse(service.isDebugCaptureEnabled)

        for policy in GovernancePolicy.allCases where policy != .paused {
            let relax = await service.handle(RPCRequest(method: .setPolicy, policy: policy))
            XCTAssertFalse(relax.ok, "\(policy)")
            XCTAssertTrue(["POLICY_LOCKED", "POLICY_BLOCKED"].contains(relax.error?.code ?? ""), "\(policy)")
            XCTAssertEqual(service.getGovernancePolicy(), .paused, "\(policy)")
        }
    }

    func testTheFallbackIsSealedSoTheNextLaunchIsClean() {
        let (defaults, keychain) = sealedMac(loosened)
        defaults.set(true, forKey: Key.debugCaptureEnabled)
        let tampered = relaunch(defaults, keychain)
        XCTAssertNotNil(tampered.check.problem)
        XCTAssertTrue(tampered.sealed)

        let next = relaunch(defaults, keychain)
        XCTAssertEqual(next.check, .verified)
        XCTAssertEqual(next.state, tampered.state, "still paused, without a second notice")
    }

    func testAMissingSealWithTheMarkerIsTampered() {
        let (defaults, keychain) = sealedMac(loosened)
        defaults.removeObject(forKey: Key.seal)
        XCTAssertEqual(relaunch(defaults, keychain).check, .tampered(.sealMissing))
    }

    func testAMarkerWithoutAKeyIsTampered() {
        let (defaults, keychain) = sealedMac(loosened)
        keychain.data = nil
        defaults.set(true, forKey: Key.debugCaptureEnabled)

        let launch = relaunch(defaults, keychain)
        XCTAssertEqual(launch.check, .tampered(.keyMissing))
        XCTAssertEqual(launch.state.policy, .paused)
        XCTAssertFalse(launch.state.debugCaptureEnabled)
        XCTAssertNotNil(keychain.secret, "a new key, so the fallback is sealed")
        XCTAssertEqual(relaunch(defaults, keychain).check, .verified)
    }

    func testAKeyWithoutTheMarkerIsTampered() {
        let (defaults, keychain) = sealedMac(loosened)
        defaults.removeObject(forKey: Key.sealVersion)
        defaults.removeObject(forKey: Key.seal)
        defaults.set(true, forKey: Key.debugCaptureEnabled)

        let launch = relaunch(defaults, keychain)
        XCTAssertEqual(launch.check, .tampered(.markerMissing))
        XCTAssertEqual(launch.state.policy, .paused)
        XCTAssertFalse(launch.state.debugCaptureEnabled)
    }

    func testAnUnknownMarkerIsTampered() {
        for marker in [0, 2, 99] as [Any] + ["v1"] {
            let (defaults, keychain) = sealedMac(loosened)
            defaults.set(marker, forKey: Key.sealVersion)
            XCTAssertEqual(relaunch(defaults, keychain).check, .tampered(.unknownVersion), "\(marker)")
        }
    }

    func testAKeychainItemThatIsntAKeyIsTampered() {
        let (defaults, keychain) = sealedMac(loosened)
        keychain.data = Data("hello".utf8)
        let launch = relaunch(defaults, keychain)
        XCTAssertEqual(launch.check, .tampered(.keyInvalid))
        XCTAssertEqual(launch.state.policy, .paused)
        XCTAssertNotNil(keychain.secret, "replaced with a real key")
    }

    /// Denied, locked, or another Keychain error: UseMac can't check, so it doesn't trust the values.
    func testAnUnreadableKeyFailsClosed() {
        let (defaults, keychain) = sealedMac(loosened)
        defaults.set(true, forKey: Key.debugCaptureEnabled)
        keychain.failsReading = true

        let launch = relaunch(defaults, keychain)
        XCTAssertEqual(launch.check, .tampered(.keyUnreadable))
        XCTAssertEqual(launch.state.policy, .paused)
        XCTAssertFalse(launch.state.debugCaptureEnabled)
        XCTAssertEqual(SafetySealNotice(launch.check)?.title, "UseMac couldn't check its safety settings")

        // Without a marker too: a key UseMac can't read may still be there.
        let fresh = makeDefaults()
        let locked = MemoryKeychain()
        locked.failsReading = true
        XCTAssertEqual(SafetySettingsStore(defaults: fresh, secretStore: locked).load().check, .tampered(.keyUnreadable))
    }

    /// An older copy of the settings and its seal (an earlier `defaults read`, a backup) doesn't match once UseMac
    /// has saved again: the count in the Keychain moved on.
    func testAnOlderSealDoesntMatchAfterANewerSave() {
        let defaults = makeDefaults()
        let keychain = MemoryKeychain()
        let store = SafetySettingsStore(defaults: defaults, secretStore: keychain)
        _ = store.load()
        store.saveKillSwitch(false)
        let oldSeal = defaults.string(forKey: Key.seal)

        store.saveKillSwitch(true)
        defaults.set(false, forKey: Key.killSwitchTripped)
        defaults.set(oldSeal, forKey: Key.seal)

        let launch = relaunch(defaults, keychain)
        XCTAssertEqual(launch.check, .tampered(.sealMismatch))
        XCTAssertEqual(launch.state.policy, .paused)
    }

    // MARK: - The first seal

    func testTheFirstLaunchSealsTheSavedValues() {
        let defaults = makeDefaults()
        defaults.set("readOnly", forKey: Key.policy)
        defaults.set(true, forKey: Key.killSwitchTripped)
        let keychain = MemoryKeychain()

        let launch = relaunch(defaults, keychain)
        XCTAssertEqual(launch.check, .firstSeal)
        XCTAssertTrue(launch.sealed)
        XCTAssertEqual(launch.state, StartupSafetyState(policy: .readOnly, policyBeforePause: .readOnly, killSwitchTripped: true))
        XCTAssertNil(SafetySealNotice(launch.check), "updating UseMac isn't a change made outside it")
        XCTAssertEqual(defaults.integer(forKey: Key.sealVersion), SafetySeal.version)
        XCTAssertNotNil(defaults.string(forKey: Key.seal))
        XCTAssertNotNil(keychain.secret)

        let next = relaunch(defaults, keychain)
        XCTAssertEqual(next.check, .verified)
        XCTAssertEqual(next.state, launch.state)
    }

    func testANewInstallIsSealedAsFactoryDefault() {
        let defaults = makeDefaults()
        let keychain = MemoryKeychain()
        let launch = relaunch(defaults, keychain)
        XCTAssertEqual(launch.check, .firstSeal)
        XCTAssertEqual(launch.state, .factoryDefault)
        XCTAssertEqual(relaunch(defaults, keychain).check, .verified)
    }

    /// The first seal also runs when someone deleted both the marker and the Keychain item, so it never keeps
    /// Debug capture on. The user turns it on again in Settings.
    func testTheFirstSealTurnsDebugCaptureOff() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: Key.debugCaptureEnabled)
        let launch = relaunch(defaults, MemoryKeychain())
        XCTAssertEqual(launch.check, .firstSeal)
        XCTAssertFalse(launch.state.debugCaptureEnabled)
        XCTAssertFalse(defaults.bool(forKey: Key.debugCaptureEnabled))
    }

    func testAFirstSealTheKeychainRefusesIsTriedAgainNextLaunch() {
        let defaults = makeDefaults()
        defaults.set("ask", forKey: Key.policy)
        let keychain = MemoryKeychain()
        keychain.failsWriting = true

        let launch = relaunch(defaults, keychain)
        XCTAssertEqual(launch.check, .firstSeal)
        XCTAssertFalse(launch.sealed)
        XCTAssertEqual(launch.state.policy, .ask)
        XCTAssertNil(defaults.object(forKey: Key.sealVersion), "no marker, so the next launch seals instead of pausing")

        keychain.failsWriting = false
        let next = relaunch(defaults, keychain)
        XCTAssertEqual(next.check, .firstSeal)
        XCTAssertTrue(next.sealed)
        XCTAssertEqual(relaunch(defaults, keychain).check, .verified)
    }

    // MARK: - Every write re-seals

    func testEverySaveReseals() {
        let defaults = makeDefaults()
        let keychain = MemoryKeychain()
        let store = SafetySettingsStore(defaults: defaults, secretStore: keychain)
        _ = store.load()

        let saves: [(String, () -> Void, StartupSafetyState)] = [
            ("execution mode", { store.savePolicy(.ask, previous: .autonomous) },
             StartupSafetyState(policy: .ask, policyBeforePause: .ask, killSwitchTripped: false)),
            ("pause", { store.savePolicy(.paused, previous: .ask) },
             StartupSafetyState(policy: .paused, policyBeforePause: .ask, killSwitchTripped: false)),
            ("Emergency stop on", { store.saveKillSwitch(true) },
             StartupSafetyState(policy: .paused, policyBeforePause: .ask, killSwitchTripped: true)),
            ("Emergency stop off", { store.saveKillSwitch(false) },
             StartupSafetyState(policy: .paused, policyBeforePause: .ask, killSwitchTripped: false)),
            ("resume", { store.savePolicy(.ask, previous: .paused) },
             StartupSafetyState(policy: .ask, policyBeforePause: .ask, killSwitchTripped: false)),
            ("Debug capture on", { store.saveDebugCapture(true) },
             StartupSafetyState(policy: .ask, policyBeforePause: .ask, killSwitchTripped: false, debugCaptureEnabled: true)),
            ("Debug capture off", { store.saveDebugCapture(false) },
             StartupSafetyState(policy: .ask, policyBeforePause: .ask, killSwitchTripped: false, debugCaptureEnabled: false)),
            ("an agent tightening", { store.savePolicy(.readOnly, previous: .ask) },
             StartupSafetyState(policy: .readOnly, policyBeforePause: .readOnly, killSwitchTripped: false))
        ]
        for (name, save, expected) in saves {
            let generation = keychain.secret?.generation
            let seal = defaults.string(forKey: Key.seal)
            save()
            XCTAssertEqual(keychain.secret?.generation, generation.map { $0 + 1 }, name)
            XCTAssertNotEqual(defaults.string(forKey: Key.seal), seal, name)

            let launch = relaunch(defaults, keychain)
            XCTAssertEqual(launch.check, .verified, name)
            XCTAssertEqual(launch.state, expected, name)
        }
    }

    /// The same rule the app used before the seal: the mode Resume goes back to is the last mode that wasn't Paused.
    func testSavingAModeReturnsTheModeToResumeTo() {
        let store = SafetySettingsStore(defaults: makeDefaults(), secretStore: MemoryKeychain())
        _ = store.load()
        XCTAssertEqual(store.savePolicy(.readOnly, previous: .autonomous), .readOnly)
        XCTAssertEqual(store.savePolicy(.paused, previous: .readOnly), .readOnly)
        XCTAssertEqual(store.savePolicy(.paused, previous: .paused), .readOnly)
        XCTAssertEqual(store.savePolicy(.ask, previous: .paused), .ask)
    }

    /// When the Keychain doesn't take the new count, the old seal must not stay: it would match an older copy.
    func testASaveTheKeychainRefusesFailsClosed() {
        let (defaults, keychain) = sealedMac(loosened)
        let store = SafetySettingsStore(defaults: defaults, secretStore: keychain)
        XCTAssertEqual(store.load().check, .verified)

        keychain.failsWriting = true
        store.saveKillSwitch(false)
        XCTAssertNil(defaults.string(forKey: Key.seal))

        keychain.failsWriting = false
        let launch = relaunch(defaults, keychain)
        XCTAssertEqual(launch.check, .tampered(.sealMissing))
        XCTAssertEqual(launch.state.policy, .paused)
    }

    /// Every write of a `usemac.safety.*` key goes through SafetySettingsStore, so none can skip the seal. Only
    /// StartupSafetyState.swift (where the keys are named) and the store may name them; the approval timeout is a
    /// different setting that isn't sealed.
    func testOnlyTheStoreWritesTheSafetySettings() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        let namesKeys = "Sources/UseMacEngine/StartupSafetyState.swift"
        let writer = "Sources/UseMacEngine/SafetySettingsStore.swift"
        let keyNames = ["policy", "policyBeforePause", "killSwitchTripped", "debugCaptureEnabled", "seal", "sealVersion"]
        let mentions = ["usemac.safety.", "StartupSafetyState.DefaultsKey"] + keyNames.map { "DefaultsKey.\($0)" }
        let writes = [".set(", "setValue(", "removeObject(", "PersistentDomain(", "CFPreferencesSet", "@AppStorage("]

        let enumerator = try XCTUnwrap(FileManager.default.enumerator(atPath: sources.path))
        var offenders: [String] = []
        var scanned = 0
        while let relative = enumerator.nextObject() as? String {
            guard relative.hasSuffix(".swift") else { continue }
            let path = "Sources/\(relative)"
            let text = try String(contentsOf: sources.appendingPathComponent(relative), encoding: .utf8)
            scanned += 1
            for (number, rawLine) in text.components(separatedBy: .newlines).enumerated() {
                let line = rawLine
                    .replacingOccurrences(of: "usemac.safety.approvalTimeoutSeconds", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("//") { continue }
                let names = mentions.contains { line.contains($0) }
                let isWrite = writes.contains { line.contains($0) }
                switch path {
                case writer:
                    continue
                case namesKeys where isWrite:
                    offenders.append("\(path):\(number + 1)")
                case namesKeys:
                    continue
                default:
                    if names { offenders.append("\(path):\(number + 1)") }
                }
            }
        }
        XCTAssertGreaterThan(scanned, 50)
        XCTAssertEqual(offenders, [], "save safety settings through SafetySettingsStore so they stay sealed")
    }

    // MARK: - History and the notice

    func testHistoryRecordsTheFirstSealAndAChangeOutsideUseMac() {
        let service = makeService()
        let first = relaunch(makeDefaults(), MemoryKeychain())
        service.recordSafetySealCheck(first)

        let (defaults, keychain) = sealedMac(loosened)
        defaults.set(true, forKey: Key.debugCaptureEnabled)
        service.recordSafetySealCheck(relaunch(defaults, keychain))

        let entries = service.recentAuditEntries(limit: 10).filter { $0.method == SafetySealNotice.auditMethod }
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries.contains { $0.success && $0.summary.hasPrefix("Sealed the safety settings") })
        XCTAssertTrue(entries.contains {
            !$0.success && $0.summary == "Safety settings changed outside UseMac (the seal doesn't match). Started paused with Debug capture off."
        })
        XCTAssertEqual(AuditEntryKind(method: SafetySealNotice.auditMethod), .other, "listed with the setting changes")
    }

    func testTheNoticeSendsTheUserToSettingsBeforeResuming() throws {
        for problem in SafetySealProblem.allCases {
            let notice = try XCTUnwrap(SafetySealNotice(.tampered(problem)))
            XCTAssertTrue(notice.message.contains("automation is paused"), "\(problem)")
            XCTAssertTrue(notice.message.contains("Settings → Safety before you resume"), "\(problem)")
            XCTAssertTrue(notice.menuSubtitle.contains("Settings → Safety"), "\(problem)")
            XCTAssertNotNil(SafetySealNotice.auditSummary(check: .tampered(problem), sealed: true))
        }
        XCTAssertEqual(
            SafetySealNotice(.tampered(.sealMismatch))?.message,
            "UseMac's safety settings were changed outside UseMac, so automation is paused and Debug capture is off. Check them in Settings → Safety before you resume."
        )
        XCTAssertNil(SafetySealNotice(.verified))
        XCTAssertNil(SafetySealNotice(.firstSeal))
    }

    /// Renaming a key would make every sealed Mac look tampered after the update.
    func testTheSealKeysDontChange() {
        XCTAssertEqual(Key.seal, "usemac.safety.seal")
        XCTAssertEqual(Key.sealVersion, "usemac.safety.sealVersion")
    }
}
