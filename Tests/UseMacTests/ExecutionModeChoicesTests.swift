import Foundation
import XCTest
@testable import UseMacEngine
import UseMacProtocol

/// Settings and the Setup guide both build their mode pickers from `ExecutionModeChoices`. These tests keep
/// that list complete and in order, so a new mode can't be left out of one place again.
final class ExecutionModeChoicesTests: XCTestCase {
    func testSettingsOffersEveryModeOnce() {
        XCTAssertEqual(Set(ExecutionModeChoices.settings), Set(GovernancePolicy.allCases))
        XCTAssertEqual(ExecutionModeChoices.settings.count, GovernancePolicy.allCases.count)
    }

    func testSettingsListsModesFromLeastToMostRestrictive() {
        let ranks = ExecutionModeChoices.settings.map { KillSwitch.strictnessRank(of: $0) }
        XCTAssertEqual(ranks, ranks.sorted())
    }

    func testSetupGuideOffersEveryWorkingModeInSettingsOrder() {
        XCTAssertEqual(
            ExecutionModeChoices.setupGuide,
            ExecutionModeChoices.settings.filter { $0 != .paused }
        )
        XCTAssertFalse(ExecutionModeChoices.setupGuide.contains(.paused))
        XCTAssertEqual(ExecutionModeChoices.setupGuide.first, .autonomous)
    }

    func testEveryModeHasADistinctNameAndASummary() {
        let names = GovernancePolicy.allCases.map(ExecutionModeChoices.name)
        XCTAssertEqual(Set(names).count, names.count)
        for policy in GovernancePolicy.allCases {
            XCTAssertFalse(ExecutionModeChoices.name(policy).isEmpty)
            let summary = ExecutionModeChoices.summary(policy)
            XCTAssertFalse(summary.isEmpty)
            XCTAssertFalse(summary.contains("\n"), "\(policy) summary should be one line")
        }
    }

    func testNamesMatchTheReadmeModesTable() throws {
        let readmeURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/UseMacTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
            .appendingPathComponent("README.md")
        let readme = try String(contentsOf: readmeURL, encoding: .utf8)
        for policy in GovernancePolicy.allCases {
            let row = "| `\(policy.rawValue)` | **\(ExecutionModeChoices.name(policy))** |"
            XCTAssertTrue(readme.contains(row), "README execution modes table should have the row \(row)")
        }
    }
}
