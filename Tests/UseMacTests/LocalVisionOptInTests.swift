import XCTest
@testable import UseMacEngine

/// LocalVisionEngine uses Apple Vision OCR directly on-device with no MLX/Python sidecar.
final class LocalVisionOptInTests: XCTestCase {
    func testLocalVisionAlwaysReportsAppleVisionOCRReady() {
        let status = LocalVisionEngine().currentStatus()
        XCTAssertTrue(status.enabled)
        XCTAssertEqual(status.state, "ready")
        XCTAssertEqual(status.backend, "apple-vision-ocr")
        XCTAssertTrue(status.ocrAvailable)
        XCTAssertFalse(status.runtimeInstalled)
        XCTAssertFalse(status.modelDownloaded)
        XCTAssertFalse(status.workerRunning)
        XCTAssertNil(status.installProgress)
        XCTAssertNil(status.lastError)
    }

    func testServiceEngineReportsAppleVisionOCR() {
        let service = UseMacEngineService(socketPath: NSTemporaryDirectory() + "usemac-ocr-\(UUID().uuidString).sock")
        let status = service.localVision.currentStatus()
        XCTAssertEqual(status.backend, "apple-vision-ocr")
        XCTAssertEqual(status.state, "ready")
        XCTAssertTrue(status.ocrAvailable)
        XCTAssertFalse(status.workerRunning)
    }
}
