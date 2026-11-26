import Foundation
import XCTest
@testable import UseMacEngine
@testable import UseMacProtocol

/// Pins the mode UseMac starts in. Nothing saved must mean Autonomous with the Emergency stop off: a Mac that ended
/// up in Read-only or Paused without the user meaning it is what #61 is about.
final class StartupSafetyStateTests: XCTestCase {
    private var suiteNames: [String] = []

    override func tearDown() {
        for name in suiteNames {
            UserDefaults().removePersistentDomain(forName: name)
        }
        suiteNames = []
        super.tearDown()
    }

    private func makeDefaults() -> UserDefaults {
        let name = "usemac-startup-safety-tests-\(UUID().uuidString)"
        suiteNames.append(name)
        return UserDefaults(suiteName: name)!
    }

    private func makeService() -> UseMacEngineService {
        UseMacEngineService(socketPath: "/tmp/usemac-startup-\(UUID().uuidString.prefix(8)).sock", extensionPort: 0)
    }

    // MARK: - Nothing saved

    func testNothingSavedStartsAutonomousWithTheEmergencyStopOff() {
        let fromNothing = StartupSafetyState.resolve(savedPolicy: nil, savedPolicyBeforePause: nil, savedKillSwitchTripped: false)
        XCTAssertEqual(fromNothing, .factoryDefault)
        XCTAssertEqual(fromNothing.policy, .autonomous)
        XCTAssertFalse(fromNothing.killSwitchTripped)
        XCTAssertNil(fromNothing.policyBeforePause)

        XCTAssertEqual(StartupSafetyState.load(from: makeDefaults()), .factoryDefault)
    }

    func testANewEngineAndAFreshInstallBothStartAutonomous() {
        XCTAssertEqual(KillSwitch().policy, .autonomous)
        XCTAssertFalse(KillSwitch().isTripped)

        let service = makeService()
        XCTAssertEqual(service.getGovernancePolicy(), .autonomous)
        XCTAssertFalse(service.isKillSwitchTripped())

        StartupSafetyState.load(from: makeDefaults()).apply(to: service)
        XCTAssertEqual(service.getGovernancePolicy(), .autonomous)
        XCTAssertFalse(service.isKillSwitchTripped())
    }

    // MARK: - Saved values

    func testSavedValuesAreHonoured() {
        for policy in GovernancePolicy.allCases {
            let state = StartupSafetyState.resolve(savedPolicy: policy.rawValue, savedPolicyBeforePause: nil, savedKillSwitchTripped: false)
            XCTAssertEqual(state.policy, policy)
            XCTAssertEqual(state.policyBeforePause, policy == .paused ? nil : policy, "\(policy)")
            XCTAssertFalse(state.killSwitchTripped)
        }

        let defaults = makeDefaults()
        defaults.set("paused", forKey: StartupSafetyState.DefaultsKey.policy)
        defaults.set("readOnly", forKey: StartupSafetyState.DefaultsKey.policyBeforePause)
        defaults.set(true, forKey: StartupSafetyState.DefaultsKey.killSwitchTripped)
        let saved = StartupSafetyState.load(from: defaults)
        XCTAssertEqual(saved, StartupSafetyState(policy: .paused, policyBeforePause: .readOnly, killSwitchTripped: true))

        let service = makeService()
        saved.apply(to: service)
        XCTAssertEqual(service.getGovernancePolicy(), .paused)
        XCTAssertTrue(service.isKillSwitchTripped())
    }

    func testTheModeToResumeToSkipsPaused() {
        XCTAssertEqual(
            StartupSafetyState.resolve(savedPolicy: "paused", savedPolicyBeforePause: "ask", savedKillSwitchTripped: false).policyBeforePause,
            .ask
        )
        XCTAssertNil(StartupSafetyState.resolve(savedPolicy: "paused", savedPolicyBeforePause: nil, savedKillSwitchTripped: false).policyBeforePause)
        XCTAssertNil(StartupSafetyState.resolve(savedPolicy: "paused", savedPolicyBeforePause: "paused", savedKillSwitchTripped: false).policyBeforePause)
        // A saved "before pause" wins over the saved mode.
        XCTAssertEqual(
            StartupSafetyState.resolve(savedPolicy: "readOnly", savedPolicyBeforePause: "confirmSensitive", savedKillSwitchTripped: false).policyBeforePause,
            .confirmSensitive
        )
    }

    // MARK: - Unknown values

    func testAnUnknownModeFallsBackToAutonomous() {
        for raw in ["", "readonly", "ReadOnly", "PAUSED", " paused", "blockSensitive", "strict"] {
            let state = StartupSafetyState.resolve(savedPolicy: raw, savedPolicyBeforePause: nil, savedKillSwitchTripped: false)
            XCTAssertEqual(state.policy, .autonomous, "\"\(raw)\"")
            XCTAssertNil(state.policyBeforePause, "\"\(raw)\"")
        }

        let unknownBeforePause = StartupSafetyState.resolve(savedPolicy: "readOnly", savedPolicyBeforePause: "later", savedKillSwitchTripped: false)
        XCTAssertEqual(unknownBeforePause.policy, .readOnly)
        XCTAssertEqual(unknownBeforePause.policyBeforePause, .readOnly)

        let defaults = makeDefaults()
        defaults.set("somethingNew", forKey: StartupSafetyState.DefaultsKey.policy)
        let service = makeService()
        service.setGovernancePolicy(.readOnly)
        StartupSafetyState.load(from: defaults).apply(to: service)
        XCTAssertEqual(service.getGovernancePolicy(), .autonomous)
    }

    /// Renaming a key would silently drop every user's saved mode.
    func testTheDefaultsKeysDontChange() {
        XCTAssertEqual(StartupSafetyState.DefaultsKey.policy, "usemac.safety.policy")
        XCTAssertEqual(StartupSafetyState.DefaultsKey.policyBeforePause, "usemac.safety.policyBeforePause")
        XCTAssertEqual(StartupSafetyState.DefaultsKey.killSwitchTripped, "usemac.safety.killSwitchTripped")
    }
}
