import Foundation
import XCTest
import UseMacProtocol

final class ProtocolDecodingTests: XCTestCase {
    func testReadmeActExampleDecodes() throws {
        let json = #"{"id":"4","method":"act","act":{"app":"TextEdit","steps":[{"action":"type","text":"Teste via NDJSON"}]}}"#
        let data = try XCTUnwrap(json.data(using: .utf8))

        let request = try JSONDecoder().decode(RPCRequest.self, from: data)
        XCTAssertEqual(request.id, "4")
        XCTAssertEqual(request.method, .act)

        let batch = try XCTUnwrap(request.act)
        XCTAssertEqual(batch.app, "TextEdit")
        XCTAssertEqual(batch.steps.count, 1)
        XCTAssertEqual(batch.steps[0].action, .type)
        XCTAssertEqual(batch.steps[0].text, "Teste via NDJSON")
        XCTAssertTrue(batch.stopOnError)
        XCTAssertTrue(batch.returnObservation)
        XCTAssertFalse(batch.returnDiffOnly)
        XCTAssertFalse(batch.includeScreenshot)
    }

    func testRequestWithoutIdGetsGeneratedId() throws {
        let data = try XCTUnwrap(#"{"method":"ping"}"#.data(using: .utf8))

        let first = try JSONDecoder().decode(RPCRequest.self, from: data)
        let second = try JSONDecoder().decode(RPCRequest.self, from: data)

        XCTAssertEqual(first.method, .ping)
        XCTAssertEqual(second.method, .ping)
        XCTAssertFalse(first.id.isEmpty)
        XCTAssertFalse(second.id.isEmpty)
        XCTAssertNotEqual(first.id, second.id)
    }

    func testScreenshotRequestDefaults() throws {
        let emptyData = try XCTUnwrap("{}".data(using: .utf8))
        let empty = try JSONDecoder().decode(ScreenshotRequest.self, from: emptyData)
        XCTAssertNil(empty.app)
        XCTAssertEqual(empty.maxDimension, 1280)
        XCTAssertEqual(empty.quality, 0.78, accuracy: 0.0001)
        XCTAssertFalse(empty.includeBase64)

        let partialData = try XCTUnwrap(#"{"maxDimension":640}"#.data(using: .utf8))
        let partial = try JSONDecoder().decode(ScreenshotRequest.self, from: partialData)
        XCTAssertNil(partial.app)
        XCTAssertEqual(partial.maxDimension, 640)
        XCTAssertEqual(partial.quality, 0.78, accuracy: 0.0001)
        XCTAssertFalse(partial.includeBase64)
    }

    func testExtractAndVisionModeDefaults() throws {
        let emptyData = try XCTUnwrap("{}".data(using: .utf8))

        let extract = try JSONDecoder().decode(BrowserExtractParams.self, from: emptyData)
        XCTAssertEqual(extract.mode, "auto")

        let vision = try JSONDecoder().decode(VisionQueryParams.self, from: emptyData)
        XCTAssertEqual(vision.mode, "ask")
    }

    func testBatchWithoutStepsFails() throws {
        let data = try XCTUnwrap(#"{"app":"Notes"}"#.data(using: .utf8))
        XCTAssertThrowsError(try JSONDecoder().decode(BatchActionRequest.self, from: data))
    }

    func testEncodingRoundTripIsUnchanged() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let batch = BatchActionRequest(
            app: "Notes",
            steps: [ActionStep(action: .type, text: "Hello")],
            stopOnError: false,
            returnObservation: true,
            returnDiffOnly: true,
            includeScreenshot: true
        )
        let batchData = try encoder.encode(batch)
        let decodedBatch = try decoder.decode(BatchActionRequest.self, from: batchData)
        XCTAssertEqual(decodedBatch, batch)

        let batchJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: batchData) as? [String: Any])
        XCTAssertEqual(
            Set(batchJSON.keys),
            Set(["app", "steps", "stopOnError", "returnObservation", "returnDiffOnly", "includeScreenshot"])
        )

        let screenshot = ScreenshotRequest(
            app: "Safari",
            maxDimension: 1024,
            quality: 0.85,
            includeBase64: true
        )
        let screenshotData = try encoder.encode(screenshot)
        let decodedScreenshot = try decoder.decode(ScreenshotRequest.self, from: screenshotData)
        XCTAssertEqual(decodedScreenshot, screenshot)

        let screenshotJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: screenshotData) as? [String: Any])
        XCTAssertEqual(
            Set(screenshotJSON.keys),
            Set(["app", "maxDimension", "quality", "includeBase64"])
        )
    }
}
