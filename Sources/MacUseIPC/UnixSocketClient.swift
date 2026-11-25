import Darwin
import Foundation
import MacUseProtocol

public enum UnixSocketClientError: Error, LocalizedError, Sendable {
    case pathTooLong(String, maxBytes: Int)
    case untrustedSocket(String)
    case socketCreationFailed(Int32)
    case connectionFailed(String, Int32)
    case timeout
    case disconnected
    case encodingFailed(String)
    case decodingFailed(String)
    case sendFailed(Int32)
    case receiveFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case let .pathTooLong(path, maxBytes):
            return "Unix socket path exceeds maximum length (\(maxBytes) bytes): \(path)"
        case let .untrustedSocket(path):
            return "Refusing to connect: socket is not owned by the expected user: \(path)"
        case let .socketCreationFailed(code):
            return "Failed to create Unix socket: \(String(cString: strerror(code))) (errno \(code))"
        case let .connectionFailed(path, code):
            return "Failed to connect to \(path): \(String(cString: strerror(code))) (errno \(code))"
        case .timeout:
            return "Timed out waiting for daemon response"
        case .disconnected:
            return "Daemon closed the socket connection"
        case let .encodingFailed(message):
            return "Failed to encode RPC request: \(message)"
        case let .decodingFailed(message):
            return "Failed to decode RPC response: \(message)"
        case let .sendFailed(code):
            return "Failed to write to Unix socket: \(String(cString: strerror(code))) (errno \(code))"
        case let .receiveFailed(code):
            return "Failed to read from Unix socket: \(String(cString: strerror(code))) (errno \(code))"
        }
    }

    fileprivate var isTransientConnectionDrop: Bool {
        switch self {
        case .disconnected:
            return true
        case let .sendFailed(code), let .receiveFailed(code):
            return code == EPIPE || code == ECONNRESET || code == ENOTCONN || code == EBADF
        default:
            return false
        }
    }
}

public final class UnixSocketClient: @unchecked Sendable {
    public static let maxResponseBytes = 64 * 1024 * 1024

    private let socketPath: String
    private let timeoutMs: Int
    private let keepAlive: Bool
    private let expectedPeerUID: uid_t
    private let responseByteLimit: Int

    private let lock = NSLock()
    private var fd: Int32 = -1
    private var readBuffer = Data()

    public convenience init(
        socketPath: String = MacUseDefaults.defaultSocketPath,
        timeoutMs: Int = 5000,
        keepAlive: Bool = true,
        expectedPeerUID: uid_t = getuid()
    ) {
        self.init(
            socketPath: socketPath,
            timeoutMs: timeoutMs,
            keepAlive: keepAlive,
            expectedPeerUID: expectedPeerUID,
            maxResponseBytes: Self.maxResponseBytes
        )
    }

    internal init(
        socketPath: String = MacUseDefaults.defaultSocketPath,
        timeoutMs: Int = 5000,
        keepAlive: Bool = true,
        expectedPeerUID: uid_t = getuid(),
        maxResponseBytes: Int
    ) {
        self.socketPath = socketPath
        self.timeoutMs = max(1, timeoutMs)
        self.keepAlive = keepAlive
        self.expectedPeerUID = expectedPeerUID
        self.responseByteLimit = max(1, maxResponseBytes)
    }

    deinit {
        close()
    }

    public var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isSocketAliveLocked()
    }

    @discardableResult
    public func ensureConnected() -> Bool {
        guard keepAlive else {
            return isDaemonReachable()
        }

        lock.lock()
        defer { lock.unlock() }

        if isSocketAliveLocked() {
            return true
        }

        closeLocked()
        do {
            fd = try openAndConnectSocket(connectTimeoutMs: min(timeoutMs, 500))
            readBuffer.removeAll(keepingCapacity: true)
            return true
        } catch {
            return false
        }
    }

    public func isDaemonReachable() -> Bool {
        lock.lock()
        if keepAlive && isSocketAliveLocked() {
            lock.unlock()
            return true
        }
        lock.unlock()

        guard let probeFd = try? openAndConnectSocket(connectTimeoutMs: min(timeoutMs, 250)) else {
            return false
        }
        Darwin.close(probeFd)
        return true
    }

    public func send(_ request: RPCRequest) throws -> (response: RPCResponse, roundTripMs: Double) {
        try send(request, timeoutMs: nil)
    }

    public func send(_ request: RPCRequest, timeoutMs overrideTimeoutMs: Int?) throws -> (response: RPCResponse, roundTripMs: Double) {
        let startNs = DispatchTime.now().uptimeNanoseconds
        let effectiveTimeoutMs = overrideTimeoutMs.map { max(1, $0) } ?? self.timeoutMs

        var payload: Data
        do {
            payload = try JSONEncoder().encode(request)
            payload.append(0x0A)
        } catch {
            throw UnixSocketClientError.encodingFailed(error.localizedDescription)
        }

        lock.lock()
        defer { lock.unlock() }

        if !keepAlive {
            closeLocked()
        }

        let wasReused = keepAlive && (fd >= 0)
        if fd < 0 {
            fd = try openAndConnectSocket(connectTimeoutMs: effectiveTimeoutMs)
            readBuffer.removeAll(keepingCapacity: true)
        }

        if overrideTimeoutMs != nil {
            applySocketTimeout(fd: fd, timeoutMs: effectiveTimeoutMs)
        }

        defer {
            if !keepAlive {
                closeLocked()
            } else if overrideTimeoutMs != nil, fd >= 0 {
                applySocketTimeout(fd: fd, timeoutMs: self.timeoutMs)
            }
        }

        do {
            let response = try performExchangeLocked(payload: payload)
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000.0
            return (response, elapsedMs)
        } catch let error as UnixSocketClientError where wasReused && error.isTransientConnectionDrop {
            closeLocked()
            fd = try openAndConnectSocket(connectTimeoutMs: effectiveTimeoutMs)
            readBuffer.removeAll(keepingCapacity: true)
            if overrideTimeoutMs != nil {
                applySocketTimeout(fd: fd, timeoutMs: effectiveTimeoutMs)
            }

            let response = try performExchangeLocked(payload: payload)
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000.0
            return (response, elapsedMs)
        } catch {
            closeLocked()
            throw error
        }
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        closeLocked()
    }

    private func isSocketAliveLocked() -> Bool {
        guard fd >= 0 else { return false }

        var pfd = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
        let polled = Darwin.poll(&pfd, 1, 0)
        if polled < 0 {
            return errno == EINTR
        }
        if polled == 0 {
            return true
        }
        if (pfd.revents & Int16(POLLERR | POLLNVAL)) != 0 {
            return false
        }

        var byte: UInt8 = 0
        let peeked = Darwin.recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        if peeked == 0 {
            return false
        }
        if peeked < 0 {
            let err = errno
            return err == EAGAIN || err == EWOULDBLOCK || err == EINTR
        }
        return true
    }

    private func closeLocked() {
        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
            fd = -1
        }
        readBuffer.removeAll(keepingCapacity: false)
    }

    private func applySocketTimeout(fd: Int32, timeoutMs: Int) {
        let clamped = max(1, timeoutMs)
        var tv = timeval(
            tv_sec: clamped / 1000,
            tv_usec: __darwin_suseconds_t((clamped % 1000) * 1000)
        )
        _ = Darwin.setsockopt(
            fd,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &tv,
            socklen_t(MemoryLayout<timeval>.size)
        )
        _ = Darwin.setsockopt(
            fd,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &tv,
            socklen_t(MemoryLayout<timeval>.size)
        )
    }

    private func openAndConnectSocket(connectTimeoutMs: Int) throws -> Int32 {
        var st = Darwin.stat()
        if Darwin.lstat(socketPath, &st) == 0 {
            guard st.st_uid == expectedPeerUID else {
                throw UnixSocketClientError.untrustedSocket(socketPath)
            }
        }

        let sockFd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard sockFd >= 0 else {
            throw UnixSocketClientError.socketCreationFailed(errno)
        }

        var closeOnError = true
        defer {
            if closeOnError {
                Darwin.close(sockFd)
            }
        }

        var noSigPipe: Int32 = 1
        _ = Darwin.setsockopt(
            sockFd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )

        applySocketTimeout(fd: sockFd, timeoutMs: connectTimeoutMs)

        var addr = sockaddr_un()
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        addr.sun_family = sa_family_t(AF_UNIX)

        let utf8Bytes = Array(socketPath.utf8)
        let maxSunPathSize = MemoryLayout.size(ofValue: addr.sun_path)
        guard utf8Bytes.count < maxSunPathSize else {
            throw UnixSocketClientError.pathTooLong(socketPath, maxBytes: maxSunPathSize - 1)
        }

        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in utf8Bytes.enumerated() {
                buffer[index] = byte
            }
        }

        let res = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(sockFd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard res == 0 else {
            throw UnixSocketClientError.connectionFailed(socketPath, errno)
        }

        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard Darwin.getpeereid(sockFd, &peerUID, &peerGID) == 0, peerUID == expectedPeerUID else {
            throw UnixSocketClientError.untrustedSocket(socketPath)
        }

        applySocketTimeout(fd: sockFd, timeoutMs: self.timeoutMs)

        closeOnError = false
        return sockFd
    }

    private func performExchangeLocked(payload: Data) throws -> RPCResponse {
        try writeAllLocked(payload)
        let lineData = try readLineLocked()
        do {
            return try JSONDecoder().decode(RPCResponse.self, from: lineData)
        } catch {
            throw UnixSocketClientError.decodingFailed(error.localizedDescription)
        }
    }

    private func writeAllLocked(_ data: Data) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let basePtr = rawBuffer.baseAddress else { return }
            var totalWritten = 0
            let totalBytes = rawBuffer.count

            while totalWritten < totalBytes {
                let ptr = basePtr.advanced(by: totalWritten)
                let written = Darwin.write(fd, ptr, totalBytes - totalWritten)
                if written < 0 {
                    let err = errno
                    if err == EINTR {
                        continue
                    }
                    if err == EAGAIN || err == EWOULDBLOCK {
                        throw UnixSocketClientError.timeout
                    }
                    throw UnixSocketClientError.sendFailed(err)
                }
                if written == 0 {
                    throw UnixSocketClientError.disconnected
                }
                totalWritten += written
            }
        }
    }

    private func readLineLocked() throws -> Data {
        var chunk = [UInt8](repeating: 0, count: 65536)
        var searchOffset = 0

        while true {
            let searchStart = readBuffer.index(readBuffer.startIndex, offsetBy: searchOffset)
            if let newlineIndex = readBuffer[searchStart...].firstIndex(of: 0x0A) {
                let lineLength = readBuffer.distance(from: readBuffer.startIndex, to: newlineIndex)
                if lineLength > responseByteLimit {
                    closeLocked()
                    throw UnixSocketClientError.decodingFailed("Response exceeds 64 MiB")
                }
                var lineData = readBuffer.subdata(in: readBuffer.startIndex..<newlineIndex)
                readBuffer.removeSubrange(readBuffer.startIndex...newlineIndex)
                if lineData.last == 0x0D {
                    lineData.removeLast()
                }
                return lineData
            }

            if readBuffer.count > responseByteLimit {
                closeLocked()
                throw UnixSocketClientError.decodingFailed("Response exceeds 64 MiB")
            }

            searchOffset = readBuffer.count

            let bytesRead = Darwin.read(fd, &chunk, chunk.count)
            if bytesRead < 0 {
                let err = errno
                if err == EINTR {
                    continue
                }
                if err == EAGAIN || err == EWOULDBLOCK {
                    throw UnixSocketClientError.timeout
                }
                throw UnixSocketClientError.receiveFailed(err)
            }
            if bytesRead == 0 {
                throw UnixSocketClientError.disconnected
            }

            readBuffer.append(contentsOf: chunk[..<bytesRead])
        }
    }
}
