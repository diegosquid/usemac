import XCTest
@testable import UseMacEngine

/// The on-device model is opt-in, and only the app's engine may load it.
final class LocalVisionOptInTests: XCTestCase {
    private let enabledKey = "usemac.vision.enabled"

    private func withSavedEnabled(_ value: Bool?, _ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: enabledKey)
        if let value {
            defaults.set(value, forKey: enabledKey)
        } else {
            defaults.removeObject(forKey: enabledKey)
        }
        defer {
            if let previous {
                defaults.set(previous, forKey: enabledKey)
            } else {
                defaults.removeObject(forKey: enabledKey)
            }
        }
        try body()
    }

    func testModelIsOffWhenTheUserNeverTurnedItOn() {
        withSavedEnabled(nil) {
            // Even on a Mac with the runtime and a model already in the Hugging Face cache.
            let status = LocalVisionEngine(allowsModel: true).currentStatus()
            XCTAssertFalse(status.enabled)
            XCTAssertEqual(status.backend, "apple-vision-ocr")
        }
    }

    func testSavedChoiceStillWins() {
        withSavedEnabled(true) {
            XCTAssertTrue(LocalVisionEngine(allowsModel: true).currentStatus().enabled)
        }
    }

    func testEngineThatMayNotLoadTheModelAnswersWithOCR() {
        withSavedEnabled(true) {
            let status = LocalVisionEngine(allowsModel: false).currentStatus()
            XCTAssertTrue(status.enabled, "the user's choice is reported as it is")
            XCTAssertEqual(status.backend, "apple-vision-ocr")
            XCTAssertFalse(status.workerRunning)
        }
    }

    func testServiceEnginesDefaultToOCROnly() {
        withSavedEnabled(true) {
            let service = UseMacEngineService(socketPath: NSTemporaryDirectory() + "usemac-optin-\(UUID().uuidString).sock")
            XCTAssertEqual(service.localVision.currentStatus().backend, "apple-vision-ocr")
        }
    }
}
