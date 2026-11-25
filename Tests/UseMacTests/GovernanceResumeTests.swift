import XCTest
import UseMacEngine
import UseMacProtocol

final class GovernanceResumeTests: XCTestCase {
    func testNonPausedPolicyIsKept() {
        let nonPausedPolicies: [GovernancePolicy] = [.autonomous, .confirmSensitive, .readOnly]
        let histories: [GovernancePolicy?] = [nil, .autonomous, .confirmSensitive, .readOnly, .paused]

        for current in nonPausedPolicies {
            for beforePause in histories {
                XCTAssertEqual(
                    GovernanceResume.policyAfterResume(current: current, beforePause: beforePause),
                    current,
                    "Expected \(current) to be preserved when beforePause is \(String(describing: beforePause))"
                )
            }
        }
    }

    func testPausedRestoresPolicyBeforePause() {
        XCTAssertEqual(
            GovernanceResume.policyAfterResume(current: .paused, beforePause: .readOnly),
            .readOnly
        )
        XCTAssertEqual(
            GovernanceResume.policyAfterResume(current: .paused, beforePause: .confirmSensitive),
            .confirmSensitive
        )
        XCTAssertEqual(
            GovernanceResume.policyAfterResume(current: .paused, beforePause: .autonomous),
            .autonomous
        )
    }

    func testPausedWithoutHistoryFallsBackToAutonomous() {
        XCTAssertEqual(
            GovernanceResume.policyAfterResume(current: .paused, beforePause: nil),
            .autonomous
        )
    }

    func testPausedNeverResumesToPaused() {
        XCTAssertEqual(
            GovernanceResume.policyAfterResume(current: .paused, beforePause: .paused),
            .autonomous
        )
    }
}
