import XCTest
@testable import UseMacEngine

final class VisionRuntimeCheckTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("usemac-vision-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testFindsMLXVLMInAnyPythonSitePackages() throws {
        let lib = root.appendingPathComponent("lib", isDirectory: true)
        try FileManager.default.createDirectory(
            at: lib.appendingPathComponent("python3.12/site-packages/mlx_vlm", isDirectory: true),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(LocalVisionEngine.sitePackagesContainMLXVLM(libDir: lib))
    }

    func testMissingPackageOrLibIsNotInstalled() throws {
        let lib = root.appendingPathComponent("lib", isDirectory: true)
        XCTAssertFalse(LocalVisionEngine.sitePackagesContainMLXVLM(libDir: lib), "no lib folder")
        try FileManager.default.createDirectory(
            at: lib.appendingPathComponent("python3.12/site-packages/mlx", isDirectory: true),
            withIntermediateDirectories: true
        )
        XCTAssertFalse(LocalVisionEngine.sitePackagesContainMLXVLM(libDir: lib), "mlx alone is not mlx_vlm")
        let file = lib.appendingPathComponent("python3.12/site-packages/mlx_vlm")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        XCTAssertFalse(LocalVisionEngine.sitePackagesContainMLXVLM(libDir: lib), "a file named mlx_vlm is not the package")
    }
}
