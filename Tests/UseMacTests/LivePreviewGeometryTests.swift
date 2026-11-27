import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import UseMacEngine

final class LivePreviewGeometryTests: XCTestCase {
    private let source = CGRect(x: 100, y: 50, width: 1600, height: 900)
    private let preview = CGSize(width: 280, height: 200)

    // MARK: Mapping

    func testDisplayedRectCentersWideSourcesAndKeepsTheTopAligned() {
        // Wider than the preview: fills the height and crops both sides equally.
        let wide = LivePreviewGeometry.displayedRect(sourceSize: source.size, in: preview)
        XCTAssertEqual(wide.minX, -37.778, accuracy: 0.001)
        XCTAssertEqual(wide.minY, 0, accuracy: 0.001)
        XCTAssertEqual(wide.height, 200, accuracy: 0.001)
        XCTAssertEqual(wide.width, 355.556, accuracy: 0.001)
        XCTAssertEqual(wide.midX, preview.width / 2, accuracy: 0.001)

        // Taller than the preview: fills the width, the bottom is cut off.
        let tall = LivePreviewGeometry.displayedRect(sourceSize: CGSize(width: 800, height: 1600), in: preview)
        XCTAssertEqual(tall.minX, 0, accuracy: 0.001)
        XCTAssertEqual(tall.minY, 0, accuracy: 0.001)
        XCTAssertEqual(tall.width, 280, accuracy: 0.001)
        XCTAssertEqual(tall.height, 560, accuracy: 0.001)

        XCTAssertEqual(LivePreviewGeometry.displayedRect(sourceSize: .zero, in: preview), .zero)
    }

    func testDisplayedRectFitsMatchingAspectRatio() {
        let shown = LivePreviewGeometry.displayedRect(
            sourceSize: CGSize(width: 1440, height: 900),
            in: CGSize(width: 280, height: 175)
        )
        XCTAssertEqual(shown.minX, 0, accuracy: 0.001)
        XCTAssertEqual(shown.minY, 0, accuracy: 0.001)
        XCTAssertEqual(shown.width, 280, accuracy: 0.001)
        XCTAssertEqual(shown.height, 175, accuracy: 0.001)
    }

    func testPointMapsIntoPreview() throws {
        let center = try XCTUnwrap(LivePreviewGeometry.previewPoint(CGPoint(x: 900, y: 500), sourceBounds: source, previewSize: preview))
        XCTAssertEqual(center.x, 140, accuracy: 0.001)
        XCTAssertEqual(center.y, 100, accuracy: 0.001)

        let nearLeft = try XCTUnwrap(LivePreviewGeometry.previewPoint(CGPoint(x: 271, y: 50), sourceBounds: source, previewSize: preview))
        XCTAssertEqual(nearLeft.x, 0.222, accuracy: 0.001)
        XCTAssertEqual(nearLeft.y, 0, accuracy: 0.001)

        let nearRight = try XCTUnwrap(LivePreviewGeometry.previewPoint(CGPoint(x: 1529, y: 50), sourceBounds: source, previewSize: preview))
        XCTAssertEqual(nearRight.x, 279.778, accuracy: 0.001)
        XCTAssertEqual(nearRight.y, 0, accuracy: 0.001)
    }

    func testPointInTheCroppedPartIsDropped() {
        // Inside the window, but in one of the cropped side strips.
        XCTAssertNil(LivePreviewGeometry.previewPoint(CGPoint(x: 100, y: 50), sourceBounds: source, previewSize: preview))
        XCTAssertNil(LivePreviewGeometry.previewPoint(CGPoint(x: 150, y: 500), sourceBounds: source, previewSize: preview))
        XCTAssertNil(LivePreviewGeometry.previewPoint(CGPoint(x: 1650, y: 500), sourceBounds: source, previewSize: preview))
    }

    func testPointOutsideThePreviewedWindowIsDropped() {
        XCTAssertNil(LivePreviewGeometry.previewPoint(CGPoint(x: 1800, y: 500), sourceBounds: source, previewSize: preview))
        XCTAssertNil(LivePreviewGeometry.previewPoint(CGPoint(x: 50, y: 500), sourceBounds: source, previewSize: preview))
        // With no crop, the legacy 5% slack still admits a point just outside the source.
        XCTAssertNotNil(LivePreviewGeometry.previewPoint(
            CGPoint(x: 60, y: 500),
            sourceBounds: source,
            previewSize: CGSize(width: 320, height: 180),
            tolerance: 0.05
        ))
    }

    func testRectIsClippedToTheSourceAndThePreview() throws {
        // Runs past the preview's right edge: only the part on the preview maps.
        let right = try XCTUnwrap(LivePreviewGeometry.previewRect(
            CGRect(x: 1400, y: 500, width: 200, height: 100),
            sourceBounds: source,
            previewSize: preview
        ))
        XCTAssertEqual(right.minX, 251.111, accuracy: 0.001)
        XCTAssertEqual(right.maxX, 280, accuracy: 0.001)
        XCTAssertEqual(right.minY, 100, accuracy: 0.001)
        XCTAssertEqual(right.height, 22.222, accuracy: 0.001)

        let left = try XCTUnwrap(LivePreviewGeometry.previewRect(
            CGRect(x: 200, y: 500, width: 150, height: 100),
            sourceBounds: source,
            previewSize: preview
        ))
        XCTAssertEqual(left.minX, 0, accuracy: 0.001)
        XCTAssertEqual(left.width, 17.778, accuracy: 0.001)
        XCTAssertEqual(left.minY, 100, accuracy: 0.001)
        XCTAssertEqual(left.height, 22.222, accuracy: 0.001)

        // In the window but entirely in a cropped side strip.
        XCTAssertNil(LivePreviewGeometry.previewRect(
            CGRect(x: 150, y: 500, width: 100, height: 100),
            sourceBounds: source,
            previewSize: preview
        ))
        XCTAssertNil(LivePreviewGeometry.previewRect(
            CGRect(x: 1550, y: 500, width: 100, height: 100),
            sourceBounds: source,
            previewSize: preview
        ))
        XCTAssertNil(LivePreviewGeometry.previewRect(
            CGRect(x: 2000, y: 500, width: 200, height: 100),
            sourceBounds: source,
            previewSize: preview
        ))
        // Zero-size element bounds (Chrome, clipped elements) still mark their position.
        XCTAssertNotNil(LivePreviewGeometry.previewRect(
            CGRect(x: 900, y: 500, width: 0, height: 0),
            sourceBounds: source,
            previewSize: preview
        ))
    }

    func testPreviewShowsOverlayOnlyForTheShownWindow() {
        // No identity: unchanged behavior.
        XCTAssertTrue(LivePreviewGeometry.previewShowsOverlay(
            overlayPid: nil, overlayWindowId: nil,
            sourceIsBrowserFrame: true, sourceIsWindow: true, sourcePid: nil, sourceWindowId: nil
        ))
        // Extension frames are in page coordinates.
        XCTAssertFalse(LivePreviewGeometry.previewShowsOverlay(
            overlayPid: 500, overlayWindowId: 11,
            sourceIsBrowserFrame: true, sourceIsWindow: true, sourcePid: 500, sourceWindowId: nil
        ))
        // A display stream maps every window.
        XCTAssertTrue(LivePreviewGeometry.previewShowsOverlay(
            overlayPid: 500, overlayWindowId: 11,
            sourceIsBrowserFrame: false, sourceIsWindow: false, sourcePid: nil, sourceWindowId: nil
        ))
        XCTAssertTrue(LivePreviewGeometry.previewShowsOverlay(
            overlayPid: 500, overlayWindowId: 11,
            sourceIsBrowserFrame: false, sourceIsWindow: true, sourcePid: 500, sourceWindowId: 11
        ))
        XCTAssertFalse(LivePreviewGeometry.previewShowsOverlay(
            overlayPid: 500, overlayWindowId: 11,
            sourceIsBrowserFrame: false, sourceIsWindow: true, sourcePid: 500, sourceWindowId: 10
        ))
        // Window unknown on one side: fall back to the app.
        XCTAssertTrue(LivePreviewGeometry.previewShowsOverlay(
            overlayPid: 500, overlayWindowId: nil,
            sourceIsBrowserFrame: false, sourceIsWindow: true, sourcePid: 500, sourceWindowId: 10
        ))
        XCTAssertFalse(LivePreviewGeometry.previewShowsOverlay(
            overlayPid: 500, overlayWindowId: 11,
            sourceIsBrowserFrame: false, sourceIsWindow: true, sourcePid: 600, sourceWindowId: nil
        ))
    }

    // MARK: Local vision size guard

    func testVisionRefusesTinyCaptures() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usemac-vision-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let tiny = dir.appendingPathComponent("tiny.png")
        let fine = dir.appendingPathComponent("fine.png")
        try writePNG(width: 52, height: 20, to: tiny)
        try writePNG(width: 200, height: 64, to: fine)

        XCTAssertThrowsError(try LocalVisionEngine.validateImageSize(atPath: tiny.path)) { error in
            XCTAssertEqual(error as? LocalVisionError, .captureTooSmall(width: 52, height: 20))
            XCTAssertTrue(error.localizedDescription.hasPrefix("CAPTURE_TOO_SMALL:"))
        }
        XCTAssertNoThrow(try LocalVisionEngine.validateImageSize(atPath: fine.path))
        // Unreadable files are left to the normal error paths.
        XCTAssertNoThrow(try LocalVisionEngine.validateImageSize(atPath: dir.appendingPathComponent("missing.png").path))
    }

    func testVisionQueryAnswersWithTheRefusalForTinyCaptures() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usemac-vision-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tiny = dir.appendingPathComponent("tiny.png")
        try writePNG(width: 52, height: 20, to: tiny)

        let result = await LocalVisionEngine().query(
            mode: "verify",
            query: "Is the order saved?",
            imagePath: tiny.path,
            viewportWidth: 52,
            viewportHeight: 20
        )
        XCTAssertTrue(result.answer.hasPrefix(LocalVisionEngine.captureTooSmallPrefix))
        XCTAssertEqual(result.verified, false)
        XCTAssertTrue(result.detections.isEmpty)
    }

    private func writePNG(width: Int, height: Int, to url: URL) throws {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
