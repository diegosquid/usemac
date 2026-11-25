import Darwin
import Foundation
import XCTest
@testable import UseMacEngine
@testable import UseMacIPC
@testable import UseMacProtocol

final class SocketPathTests: XCTestCase {

    private func uniquePath(_ prefix: String) -> String {
        "/tmp/\(prefix)-\(UUID().uuidString.prefix(8))"
    }

    private func mode(of path: String) -> mode_t? {
        var st = Darwin.stat()
        guard Darwin.lstat(path, &st) == 0 else { return nil }
        return st.st_mode & 0o777
    }

    private func inode(of path: String) -> ino_t? {
        var st = Darwin.stat()
        guard Darwin.lstat(path, &st) == 0 else { return nil }
        return st.st_ino
    }

    private func waitUntil(timeoutSeconds: Double = 3, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return condition()
    }

    private func ping(_ path: String) -> Bool {
        let client = UnixSocketClient(socketPath: path, timeoutMs: 2000, keepAlive: false)
        defer { client.close() }
        guard let (response, _) = try? client.send(RPCRequest(method: .ping)) else { return false }
        return response.ok && response.pong == "pong"
    }

    func testDefaultSocketLivesInPrivatePerUserFolder() {
        XCTAssertEqual(UseMacDefaults.defaultSocketDirectory, "/tmp/usemac-\(getuid())")
        if ProcessInfo.processInfo.environment["USEMAC_SOCKET"] == nil {
            XCTAssertEqual(UseMacDefaults.defaultSocketPath, "/tmp/usemac-\(getuid())/usemac.sock")
        }
    }

    func testPrivateDirectoryIsCreatedOwnerOnly() throws {
        let dir = uniquePath("usemac-ut-dir")
        defer { try? FileManager.default.removeItem(atPath: dir) }

        try PrivateSocketDirectory.ensure(atPath: dir)

        XCTAssertEqual(mode(of: dir), 0o700)
        XCTAssertTrue(PrivateSocketDirectory.isTrusted(atPath: dir, expectedUID: getuid()))
        XCTAssertFalse(PrivateSocketDirectory.isTrusted(atPath: dir, expectedUID: getuid() + 1))
    }

    func testExistingOpenDirectoryIsTightened() throws {
        let dir = uniquePath("usemac-ut-open")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        XCTAssertEqual(Darwin.mkdir(dir, 0o755), 0)
        XCTAssertEqual(Darwin.chmod(dir, 0o755), 0)
        XCTAssertFalse(PrivateSocketDirectory.isTrusted(atPath: dir, expectedUID: getuid()))

        try PrivateSocketDirectory.ensure(atPath: dir)

        XCTAssertEqual(mode(of: dir), 0o700)
    }

    func testSymlinkedDirectoryIsRejected() throws {
        let realDir = uniquePath("usemac-ut-real")
        let link = uniquePath("usemac-ut-link")
        defer {
            try? FileManager.default.removeItem(atPath: link)
            try? FileManager.default.removeItem(atPath: realDir)
        }
        XCTAssertEqual(Darwin.mkdir(realDir, 0o700), 0)
        XCTAssertEqual(Darwin.symlink(realDir, link), 0)

        XCTAssertThrowsError(try PrivateSocketDirectory.ensure(atPath: link))
        XCTAssertFalse(PrivateSocketDirectory.isTrusted(atPath: link, expectedUID: getuid()))
    }

    func testServerRecreatesSocketAfterItsFileIsDeleted() throws {
        let path = uniquePath("usemac-ut-heal") + ".sock"
        let server = UnixSocketServer(
            socketPath: path,
            service: UseMacEngineService(socketPath: path),
            pathCheckInterval: 0.1
        )
        try server.start()
        defer { server.stop() }

        XCTAssertTrue(ping(path))
        let originalInode = inode(of: path)

        XCTAssertEqual(Darwin.unlink(path), 0)
        XCTAssertFalse(ping(path))

        let recreated = waitUntil { self.inode(of: path) != nil && self.inode(of: path) != originalInode }
        XCTAssertTrue(recreated, "Expected the server to recreate its socket file")
        XCTAssertTrue(ping(path))
        XCTAssertEqual(mode(of: path), 0o600)
    }

    func testServerDoesNotTakeOverOrDeleteAnotherServersSocket() throws {
        let path = uniquePath("usemac-ut-share") + ".sock"
        let first = UnixSocketServer(
            socketPath: path,
            service: UseMacEngineService(socketPath: path),
            pathCheckInterval: 0.1
        )
        try first.start()
        XCTAssertEqual(Darwin.unlink(path), 0)

        let second = UnixSocketServer(
            socketPath: path,
            service: UseMacEngineService(socketPath: path),
            pathCheckInterval: 0
        )
        try second.start()
        defer { second.stop() }
        let secondInode = inode(of: path)

        // Give the first server's health check several chances to (wrongly) reclaim the path.
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(inode(of: path), secondInode)

        first.stop()
        XCTAssertEqual(inode(of: path), secondInode, "Stopping the first server must not delete the second server's socket")
        XCTAssertTrue(ping(path))
    }
}
