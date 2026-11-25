import Darwin
import Foundation
import XCTest
@testable import UseMacProtocol
@testable import UseMacIPC

final class StubService: UseMacServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _delayMs: UInt64
    private var _callCount: Int = 0
    private var _handler: (@Sendable (RPCRequest) -> RPCResponse)?

    init(
        delayMs: UInt64 = 0,
        handler: (@Sendable (RPCRequest) -> RPCResponse)? = nil
    ) {
        self._delayMs = delayMs
        self._handler = handler
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _callCount
    }

    func setDelayMs(_ value: UInt64) {
        lock.lock()
        _delayMs = value
        lock.unlock()
    }

    func setHandler(_ handler: (@Sendable (RPCRequest) -> RPCResponse)?) {
        lock.lock()
        _handler = handler
        lock.unlock()
    }

    func handle(_ request: RPCRequest) async -> RPCResponse {
        let (delay, customHandler): (UInt64, (@Sendable (RPCRequest) -> RPCResponse)?) = {
            lock.lock()
            defer { lock.unlock() }
            _callCount += 1
            return (_delayMs, _handler)
        }()

        if delay > 0 {
            try? await Task.sleep(nanoseconds: delay * 1_000_000)
        }

        if let customHandler {
            return customHandler(request)
        }

        switch request.method {
        case .ping:
            return RPCResponse.success(id: request.id, latencyMs: 0.1, pong: "pong")
        case .listApps:
            let app = AppDescriptor(pid: 1001, name: "StubApp", bundleId: "com.example.stub", isActive: true)
            return RPCResponse.success(id: request.id, latencyMs: 0.1, apps: [app])
        default:
            return RPCResponse.success(id: request.id, latencyMs: 0.1)
        }
    }
}

final class IPCHardeningTests: XCTestCase {

    private func makeTempSocketPath(prefix: String) -> String {
        "/tmp/\(prefix)-\(UUID().uuidString.prefix(8)).sock"
    }

    private func parseJSON(_ raw: String) throws -> [String: Any] {
        let data = try XCTUnwrap(raw.data(using: .utf8))
        let obj = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(obj as? [String: Any])
    }

    private func makeSockAddrUn(path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        addr.sun_family = sa_family_t(AF_UNIX)
        let utf8Bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in utf8Bytes.enumerated() {
                buffer[index] = byte
            }
        }
        return addr
    }

    func testServerRejectsOversizedRequestLine() throws {
        let socketPath = makeTempSocketPath(prefix: "usemac-ht-oversize")
        let stub = StubService()
        let server = UnixSocketServer(socketPath: socketPath, service: stub)
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(atPath: socketPath)
        }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { Darwin.close(fd) }

        var noSigPipe: Int32 = 1
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = makeSockAddrUn(path: socketPath)
        let connectRes = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(connectRes, 0)

        let totalToSend = UnixSocketServer.maxRequestBytes + 1
        let chunkSize = 65536
        let chunk = [UInt8](repeating: 0x61, count: chunkSize) // 'a', no newline
        var remaining = totalToSend

        while remaining > 0 {
            let toWrite = min(chunkSize, remaining)
            let written = chunk.withUnsafeBytes { rawBuf in
                Darwin.write(fd, rawBuf.baseAddress!, toWrite)
            }
            if written < 0 {
                if errno == EINTR { continue }
                // Server may have already closed after detecting overflow on final chunk
                break
            }
            if written == 0 {
                break
            }
            remaining -= written
        }

        var responseBytes = Data()
        var readBuf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.read(fd, &readBuf, readBuf.count)
            if n < 0 {
                if errno == EINTR { continue }
                break
            }
            if n == 0 {
                break
            }
            responseBytes.append(contentsOf: readBuf[..<n])
        }

        // Verify EOF after the single response line
        var probe: UInt8 = 0
        XCTAssertEqual(Darwin.read(fd, &probe, 1), 0)

        let newlineIndex = try XCTUnwrap(responseBytes.firstIndex(of: 0x0A))
        XCTAssertEqual(responseBytes.index(after: newlineIndex), responseBytes.endIndex)
        let lineData = responseBytes.subdata(in: responseBytes.startIndex..<newlineIndex)
        let rpcResponse = try JSONDecoder().decode(RPCResponse.self, from: lineData)

        XCTAssertFalse(rpcResponse.ok)
        XCTAssertEqual(rpcResponse.error?.code, "message_too_large")
        XCTAssertEqual(rpcResponse.error?.message, "Request exceeds 16 MiB")
        XCTAssertEqual(stub.callCount, 0)
    }

    func testServerDropsPeerWithUnexpectedUID() async throws {
        final class CountRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [Int] = []
            func append(_ count: Int) {
                lock.lock()
                values.append(count)
                lock.unlock()
            }
            func snapshot() -> [Int] {
                lock.lock()
                defer { lock.unlock() }
                return values
            }
        }

        let socketPath = makeTempSocketPath(prefix: "usemac-ht-uid-srv")
        let stub = StubService()
        let recorder = CountRecorder()
        let server = UnixSocketServer(
            socketPath: socketPath,
            service: stub,
            onClientCountChange: { count in recorder.append(count) },
            allowedPeerUID: getuid() + 1
        )
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(atPath: socketPath)
        }

        let client = UnixSocketClient(socketPath: socketPath, timeoutMs: 2000, keepAlive: false)
        defer { client.close() }

        do {
            _ = try client.send(RPCRequest(method: .ping))
            XCTFail("Expected server to drop peer with unexpected UID")
        } catch let error as UnixSocketClientError {
            switch error {
            case .disconnected, .sendFailed, .receiveFailed:
                break
            default:
                XCTFail("Unexpected UnixSocketClientError: \(error)")
            }
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(recorder.snapshot().contains(1), "Unexpected UID peer should never be counted as active client")
        XCTAssertEqual(stub.callCount, 0)
    }

    func testClientRefusesSocketOwnedByUnexpectedUser() throws {
        let socketPath = makeTempSocketPath(prefix: "usemac-ht-uid-cli")
        let stub = StubService()
        let server = UnixSocketServer(socketPath: socketPath, service: stub)
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(atPath: socketPath)
        }

        let client = UnixSocketClient(
            socketPath: socketPath,
            timeoutMs: 2000,
            keepAlive: true,
            expectedPeerUID: getuid() + 1
        )
        defer { client.close() }

        XCTAssertFalse(client.isDaemonReachable())
        XCTAssertFalse(client.ensureConnected())

        do {
            _ = try client.send(RPCRequest(method: .ping))
            XCTFail("Expected client to refuse socket owned by unexpected user")
        } catch let error as UnixSocketClientError {
            guard case let .untrustedSocket(path) = error else {
                XCTFail("Expected .untrustedSocket, got \(error)")
                return
            }
            XCTAssertEqual(path, socketPath)
        }

        XCTAssertEqual(stub.callCount, 0)
    }

    func testReadTimeoutIsNotClampedByEnsureConnected() throws {
        let socketPath = makeTempSocketPath(prefix: "usemac-ht-clamp")
        let stub = StubService(delayMs: 900)
        let server = UnixSocketServer(socketPath: socketPath, service: stub)
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(atPath: socketPath)
        }

        let client = UnixSocketClient(socketPath: socketPath, timeoutMs: 5000, keepAlive: true)
        defer { client.close() }

        XCTAssertTrue(client.ensureConnected())

        let (response, _) = try client.send(RPCRequest(method: .ping))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.pong, "pong")
    }

    func testPerRequestTimeoutOverrideAndRecovery() throws {
        let socketPath = makeTempSocketPath(prefix: "usemac-ht-override")
        let stub = StubService(delayMs: 900)
        let server = UnixSocketServer(socketPath: socketPath, service: stub)
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(atPath: socketPath)
        }

        let client = UnixSocketClient(socketPath: socketPath, timeoutMs: 5000, keepAlive: true)
        defer { client.close() }

        do {
            _ = try client.send(RPCRequest(method: .ping), timeoutMs: 200)
            XCTFail("Expected short per-request timeout to throw .timeout")
        } catch let error as UnixSocketClientError {
            guard case .timeout = error else {
                XCTFail("Expected .timeout, got \(error)")
                return
            }
        }

        let (response, _) = try client.send(RPCRequest(method: .ping), timeoutMs: 3000)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.pong, "pong")
    }

    func testClientRejectsOversizedResponseLine() throws {
        let socketPath = makeTempSocketPath(prefix: "usemac-ht-res-big")
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let listenFd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listenFd, 0)
        defer { Darwin.close(listenFd) }

        var addr = makeSockAddrUn(path: socketPath)
        let bindRes = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(listenFd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bindRes, 0)
        XCTAssertEqual(Darwin.listen(listenFd, 4), 0)

        let serverDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { serverDone.signal() }
            var clientAddr = sockaddr_un()
            var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let connFd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.accept(listenFd, sockaddrPtr, &clientLen)
                }
            }
            guard connFd >= 0 else { return }
            defer { Darwin.close(connFd) }

            var noSigPipe: Int32 = 1
            _ = Darwin.setsockopt(connFd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

            var reqBuf = [UInt8](repeating: 0, count: 4096)
            _ = Darwin.read(connFd, &reqBuf, reqBuf.count)

            let payload = [UInt8](repeating: 0x78, count: 2048) // 'x', no newline, > 1024
            payload.withUnsafeBytes { rawBuf in
                _ = Darwin.write(connFd, rawBuf.baseAddress!, rawBuf.count)
            }
        }

        let client = UnixSocketClient(
            socketPath: socketPath,
            timeoutMs: 2000,
            keepAlive: true,
            expectedPeerUID: getuid(),
            maxResponseBytes: 1024
        )
        defer { client.close() }

        do {
            _ = try client.send(RPCRequest(method: .ping))
            XCTFail("Expected oversized response line to throw .decodingFailed")
        } catch let error as UnixSocketClientError {
            guard case .decodingFailed = error else {
                XCTFail("Expected .decodingFailed, got \(error)")
                return
            }
        }

        _ = serverDone.wait(timeout: .now() + 2)
    }

    func testMCPDoesNotFallBackOnTimeout() async throws {
        let socketPath = makeTempSocketPath(prefix: "usemac-ht-mcp-to")
        let daemonStub = StubService(delayMs: 1500)
        let fallbackStub = StubService(delayMs: 0)
        let server = UnixSocketServer(socketPath: socketPath, service: daemonStub)
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(atPath: socketPath)
        }

        let mcp = MCPStdioServer(
            socketPath: socketPath,
            fallbackService: fallbackStub,
            requestTimeoutMs: 300
        )
        defer { mcp.close() }

        let callLine = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"usemac_list_apps","arguments":{}}}"#
        let rawOut = await mcp.processLine(callLine)
        let obj = try parseJSON(try XCTUnwrap(rawOut))
        let result = try XCTUnwrap(obj["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("did not answer within"), "Unexpected error text: \(text)")
        XCTAssertEqual(fallbackStub.callCount, 0)
    }

    func testMCPFallsBackWhenDaemonIsUnreachable() async throws {
        let missingSocket = makeTempSocketPath(prefix: "usemac-ht-missing")
        let fallbackStub = StubService(delayMs: 0)
        let mcp = MCPStdioServer(socketPath: missingSocket, fallbackService: fallbackStub)
        defer { mcp.close() }

        let callLine = #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"usemac_list_apps","arguments":{}}}"#
        let rawOut = await mcp.processLine(callLine)
        let obj = try parseJSON(try XCTUnwrap(rawOut))
        let result = try XCTUnwrap(obj["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        XCTAssertEqual(fallbackStub.callCount, 1)
    }

    func testMCPOnlyInlinesImagesFromCaptureDirectory() async throws {
        let socketPath = makeTempSocketPath(prefix: "usemac-ht-img")
        let daemonStub = StubService { req in
            RPCResponse.success(
                id: req.id,
                latencyMs: 1.0,
                screenshot: ScreenshotResult(
                    path: "/etc/hosts",
                    mimeType: "image/jpeg",
                    width: 100,
                    height: 100,
                    byteCount: 64,
                    latencyMs: 1.0,
                    base64Data: nil
                )
            )
        }
        let server = UnixSocketServer(socketPath: socketPath, service: daemonStub)
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(atPath: socketPath)
        }

        let mcp = MCPStdioServer(socketPath: socketPath)
        defer { mcp.close() }

        let shotCall = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"usemac_screenshot","arguments":{"returnImageContent":true}}}"#

        // 1. Path outside captureDirectory must NOT be read or inlined
        let outsideRaw = await mcp.processLine(shotCall)
        let outsideObj = try parseJSON(try XCTUnwrap(outsideRaw))
        let outsideResult = try XCTUnwrap(outsideObj["result"] as? [String: Any])
        XCTAssertEqual(outsideResult["isError"] as? Bool, false)
        let outsideBlocks = try XCTUnwrap(outsideResult["content"] as? [[String: Any]])
        XCTAssertFalse(outsideBlocks.contains(where: { ($0["type"] as? String) == "image" }))

        // 2. File inside captureDirectory IS allowed and inlined
        try FileManager.default.createDirectory(
            atPath: UseMacDefaults.captureDirectory,
            withIntermediateDirectories: true
        )
        let captureFile = (UseMacDefaults.captureDirectory as NSString)
            .appendingPathComponent("ht-capture-\(UUID().uuidString).jpg")
        let fakeJPEG = Data([0xFF, 0xD8, 0xFF, 0xD9])
        try fakeJPEG.write(to: URL(fileURLWithPath: captureFile))
        defer { try? FileManager.default.removeItem(atPath: captureFile) }

        daemonStub.setHandler { req in
            RPCResponse.success(
                id: req.id,
                latencyMs: 1.0,
                screenshot: ScreenshotResult(
                    path: captureFile,
                    mimeType: "image/jpeg",
                    width: 100,
                    height: 100,
                    byteCount: fakeJPEG.count,
                    latencyMs: 1.0,
                    base64Data: nil
                )
            )
        }

        let insideRaw = await mcp.processLine(shotCall)
        let insideObj = try parseJSON(try XCTUnwrap(insideRaw))
        let insideResult = try XCTUnwrap(insideObj["result"] as? [String: Any])
        XCTAssertEqual(insideResult["isError"] as? Bool, false)
        let insideBlocks = try XCTUnwrap(insideResult["content"] as? [[String: Any]])
        let imageBlock = try XCTUnwrap(insideBlocks.first(where: { ($0["type"] as? String) == "image" }))
        XCTAssertEqual(imageBlock["data"] as? String, fakeJPEG.base64EncodedString())
        XCTAssertEqual(imageBlock["mimeType"] as? String, "image/jpeg")
    }

    func testToolAnnotationsInstructionsAndArgumentTypes() async throws {
        let missingSocket = makeTempSocketPath(prefix: "usemac-ht-meta")
        let fallbackStub = StubService()
        let mcp = MCPStdioServer(socketPath: missingSocket, fallbackService: fallbackStub)
        defer { mcp.close() }

        // 1. initialize returns instructions containing "untrusted data"
        let initLine = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"xctest","version":"1.0"}}}"#
        let initRaw = await mcp.processLine(initLine)
        let initObj = try parseJSON(try XCTUnwrap(initRaw))
        let initResult = try XCTUnwrap(initObj["result"] as? [String: Any])
        let instructions = try XCTUnwrap(initResult["instructions"] as? String)
        XCTAssertTrue(instructions.contains("untrusted data"))

        // 2. tools/list returns 16 tools, all with boolean annotations.readOnlyHint
        let listLine = #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#
        let listRaw = await mcp.processLine(listLine)
        let listObj = try parseJSON(try XCTUnwrap(listRaw))
        let listResult = try XCTUnwrap(listObj["result"] as? [String: Any])
        let tools = try XCTUnwrap(listResult["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 16)

        for tool in tools {
            let name = try XCTUnwrap(tool["name"] as? String)
            let annotations = try XCTUnwrap(tool["annotations"] as? [String: Any], "Missing annotations on \(name)")
            XCTAssertNotNil(annotations["readOnlyHint"] as? Bool, "Missing boolean readOnlyHint on \(name)")
        }

        let actTool = try XCTUnwrap(tools.first(where: { ($0["name"] as? String) == "usemac_act" }))
        let actAnnotations = try XCTUnwrap(actTool["annotations"] as? [String: Any])
        XCTAssertEqual(actAnnotations["destructiveHint"] as? Bool, true)

        let statusTool = try XCTUnwrap(tools.first(where: { ($0["name"] as? String) == "usemac_status" }))
        let statusAnnotations = try XCTUnwrap(statusTool["annotations"] as? [String: Any])
        XCTAssertEqual(statusAnnotations["readOnlyHint"] as? Bool, true)

        // 3. Wrong argument type returns JSON-RPC error -32602 naming the key
        let badArgsLine = #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"usemac_browser_observe","arguments":{"tabId":"77"}}}"#
        let badArgsRaw = await mcp.processLine(badArgsLine)
        let badArgsObj = try parseJSON(try XCTUnwrap(badArgsRaw))
        let rpcError = try XCTUnwrap(badArgsObj["error"] as? [String: Any])
        XCTAssertEqual(rpcError["code"] as? Int, -32602)
        let message = try XCTUnwrap(rpcError["message"] as? String)
        XCTAssertTrue(message.contains("tabId"), "Expected error message to mention tabId, got: \(message)")
    }
}
