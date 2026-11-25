import Darwin
import Foundation
import MacUseProtocol

public enum UnixSocketServerError: Error, LocalizedError, Sendable {
    case pathTooLong(String, maxBytes: Int)
    case pathOwnedByAnotherUser(String)
    case pathIsNotSocket(String)
    case alreadyListening(String)
    case socketCreationFailed(Int32)
    case bindFailed(String, Int32)
    case listenFailed(Int32)
    case chmodFailed(String, Int32)

    public var errorDescription: String? {
        switch self {
        case let .pathTooLong(path, maxBytes):
            return "Unix socket path exceeds maximum length (\(maxBytes) bytes): \(path)"
        case let .pathOwnedByAnotherUser(path):
            return "Socket path is owned by another user: \(path)"
        case let .pathIsNotSocket(path):
            return "Path exists and is not a Unix domain socket: \(path)"
        case let .alreadyListening(path):
            return "Another server is already listening on socket: \(path)"
        case let .socketCreationFailed(code):
            return "Failed to create Unix socket: \(String(cString: strerror(code))) (errno \(code))"
        case let .bindFailed(path, code):
            return "Failed to bind Unix socket at \(path): \(String(cString: strerror(code))) (errno \(code))"
        case let .listenFailed(code):
            return "Failed to listen on Unix socket: \(String(cString: strerror(code))) (errno \(code))"
        case let .chmodFailed(path, code):
            return "Failed to chmod Unix socket at \(path): \(String(cString: strerror(code))) (errno \(code))"
        }
    }
}

public final class UnixSocketServer: @unchecked Sendable {
    public static let maxRequestBytes = 16 * 1024 * 1024

    private let socketPath: String
    private let service: MacUseServiceProtocol
    private let onClientCountChange: (@Sendable (Int) -> Void)?
    private let allowedPeerUID: uid_t

    private let stateLock = NSLock()
    private var serverFd: Int32 = -1
    private var running = false
    private var clientFds: Set<Int32> = []

    private let acceptQueue = DispatchQueue(label: "com.macuse.ipc.server.accept", qos: .userInteractive)
    private let clientQueue = DispatchQueue(
        label: "com.macuse.ipc.server.clients",
        qos: .userInteractive,
        attributes: .concurrent
    )

    public init(
        socketPath: String = MacUseDefaults.defaultSocketPath,
        service: MacUseServiceProtocol,
        onClientCountChange: (@Sendable (Int) -> Void)? = nil,
        allowedPeerUID: uid_t = getuid()
    ) {
        self.socketPath = socketPath
        self.service = service
        self.onClientCountChange = onClientCountChange
        self.allowedPeerUID = allowedPeerUID
    }

    deinit {
        stop()
    }

    public var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    public func start() throws {
        Darwin.signal(SIGPIPE, SIG_IGN)

        stateLock.lock()
        if running {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        try prepareSocketPath()

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw UnixSocketServerError.socketCreationFailed(errno)
        }

        var closeOnError = true
        defer {
            if closeOnError {
                Darwin.close(fd)
            }
        }

        var noSigPipe: Int32 = 1
        _ = Darwin.setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )

        var addr = try makeSockAddrUn(path: socketPath)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            throw UnixSocketServerError.bindFailed(socketPath, errno)
        }

        guard Darwin.chmod(socketPath, 0o600) == 0 else {
            let err = errno
            Darwin.unlink(socketPath)
            throw UnixSocketServerError.chmodFailed(socketPath, err)
        }

        guard Darwin.listen(fd, 64) == 0 else {
            let err = errno
            Darwin.unlink(socketPath)
            throw UnixSocketServerError.listenFailed(err)
        }

        stateLock.lock()
        serverFd = fd
        running = true
        stateLock.unlock()

        closeOnError = false

        acceptQueue.async { [weak self] in
            self?.runAcceptLoop(listenFd: fd)
        }
    }

    public func stop() {
        let fdToClose: Int32
        let clientsToClose: [Int32]
        let shouldNotifyZero: Bool

        stateLock.lock()
        if !running && serverFd < 0 && clientFds.isEmpty {
            stateLock.unlock()
            return
        }
        running = false
        fdToClose = serverFd
        serverFd = -1
        clientsToClose = Array(clientFds)
        shouldNotifyZero = !clientFds.isEmpty
        clientFds.removeAll()
        stateLock.unlock()

        if fdToClose >= 0 {
            Darwin.shutdown(fdToClose, SHUT_RDWR)
            Darwin.close(fdToClose)
        }

        for clientFd in clientsToClose {
            Darwin.shutdown(clientFd, SHUT_RDWR)
        }

        Darwin.unlink(socketPath)

        if shouldNotifyZero {
            onClientCountChange?(0)
        }
    }

    private func prepareSocketPath() throws {
        let parentDir = (socketPath as NSString).deletingLastPathComponent
        if !parentDir.isEmpty {
            try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
        }

        var st = Darwin.stat()
        guard Darwin.lstat(socketPath, &st) == 0 else {
            return
        }

        guard st.st_uid == getuid() else {
            throw UnixSocketServerError.pathOwnedByAnotherUser(socketPath)
        }

        guard (st.st_mode & S_IFMT) == S_IFSOCK else {
            throw UnixSocketServerError.pathIsNotSocket(socketPath)
        }

        if isExistingSocketActive() {
            throw UnixSocketServerError.alreadyListening(socketPath)
        }

        Darwin.unlink(socketPath)
    }

    private func isExistingSocketActive() -> Bool {
        let probeFd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard probeFd >= 0 else {
            return false
        }
        defer { Darwin.close(probeFd) }

        let currentFlags = Darwin.fcntl(probeFd, F_GETFL, 0)
        if currentFlags >= 0 {
            _ = Darwin.fcntl(probeFd, F_SETFL, currentFlags | O_NONBLOCK)
        }

        guard var addr = try? makeSockAddrUn(path: socketPath) else {
            return false
        }

        let res = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(probeFd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        if res == 0 {
            return true
        }

        if errno == EINPROGRESS {
            var pfd = pollfd(fd: probeFd, events: Int16(POLLOUT), revents: 0)
            let polled = Darwin.poll(&pfd, 1, 50)
            if polled > 0 {
                var sockErr: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                if Darwin.getsockopt(probeFd, SOL_SOCKET, SO_ERROR, &sockErr, &len) == 0 {
                    return sockErr == 0
                }
            }
        }

        return false
    }

    private func makeSockAddrUn(path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        addr.sun_family = sa_family_t(AF_UNIX)

        let utf8Bytes = Array(path.utf8)
        let maxSunPathSize = MemoryLayout.size(ofValue: addr.sun_path)
        guard utf8Bytes.count < maxSunPathSize else {
            throw UnixSocketServerError.pathTooLong(path, maxBytes: maxSunPathSize - 1)
        }

        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in utf8Bytes.enumerated() {
                buffer[index] = byte
            }
        }
        return addr
    }

    private func runAcceptLoop(listenFd: Int32) {
        while isRunning {
            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.accept(listenFd, sockaddrPtr, &clientAddrLen)
                }
            }

            if clientFd < 0 {
                if errno == EINTR && isRunning {
                    continue
                }
                break
            }

            if !isRunning {
                Darwin.close(clientFd)
                break
            }

            var peerUID: uid_t = 0
            var peerGID: gid_t = 0
            if Darwin.getpeereid(clientFd, &peerUID, &peerGID) != 0 || peerUID != allowedPeerUID {
                Darwin.shutdown(clientFd, SHUT_RDWR)
                Darwin.close(clientFd)
                continue
            }

            var noSigPipe: Int32 = 1
            _ = Darwin.setsockopt(
                clientFd,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSigPipe,
                socklen_t(MemoryLayout<Int32>.size)
            )

            let newCount: Int
            stateLock.lock()
            if running {
                clientFds.insert(clientFd)
                newCount = clientFds.count
                stateLock.unlock()
            } else {
                stateLock.unlock()
                Darwin.close(clientFd)
                break
            }

            onClientCountChange?(newCount)

            clientQueue.async { [weak self] in
                guard let self else {
                    Darwin.shutdown(clientFd, SHUT_RDWR)
                    Darwin.close(clientFd)
                    return
                }
                self.handleClient(clientFd: clientFd)
            }
        }
    }

    private func handleClient(clientFd: Int32) {
        defer {
            unregisterAndCloseClient(clientFd)
        }

        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        var readBuffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)

        while isRunning {
            let bytesRead = Darwin.read(clientFd, &chunk, chunk.count)
            if bytesRead < 0 {
                if errno == EINTR {
                    continue
                }
                break
            }
            if bytesRead == 0 {
                break
            }

            let previousCount = readBuffer.count
            readBuffer.append(contentsOf: chunk[..<bytesRead])

            let searchStart = readBuffer.index(readBuffer.startIndex, offsetBy: previousCount)
            if var newlineIndex = readBuffer[searchStart...].firstIndex(of: 0x0A) {
                while true {
                    let lineLength = readBuffer.distance(from: readBuffer.startIndex, to: newlineIndex)
                    if lineLength > Self.maxRequestBytes {
                        sendOversizedRequestError(clientFd: clientFd, encoder: encoder)
                        return
                    }

                    var lineData = readBuffer.subdata(in: readBuffer.startIndex..<newlineIndex)
                    readBuffer.removeSubrange(readBuffer.startIndex...newlineIndex)

                    if lineData.last == 0x0D {
                        lineData.removeLast()
                    }
                    if !lineData.isEmpty {
                        let response: RPCResponse
                        do {
                            let request = try decoder.decode(RPCRequest.self, from: lineData)
                            response = awaitService(request)
                        } catch {
                            response = RPCResponse.failure(
                                id: "unknown",
                                code: "invalid_request",
                                message: "Failed to decode RPCRequest: \(error.localizedDescription)"
                            )
                        }

                        guard isRunning else {
                            return
                        }

                        do {
                            var encoded = try encoder.encode(response)
                            encoded.append(0x0A)
                            if !writeAll(fd: clientFd, data: encoded) {
                                return
                            }
                        } catch {
                            return
                        }
                    }

                    guard let nextNewline = readBuffer.firstIndex(of: 0x0A) else {
                        break
                    }
                    newlineIndex = nextNewline
                }
            }

            if readBuffer.count > Self.maxRequestBytes {
                sendOversizedRequestError(clientFd: clientFd, encoder: encoder)
                return
            }
        }
    }

    private func sendOversizedRequestError(clientFd: Int32, encoder: JSONEncoder) {
        let response = RPCResponse.failure(
            id: "unknown",
            code: "message_too_large",
            message: "Request exceeds 16 MiB"
        )
        if var encoded = try? encoder.encode(response) {
            encoded.append(0x0A)
            _ = writeAll(fd: clientFd, data: encoded)
        }
    }

    private final class ResponseBox: @unchecked Sendable {
        var value: RPCResponse?
    }

    private func awaitService(_ request: RPCRequest) -> RPCResponse {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResponseBox()
        let svc = service
        Task {
            box.value = await svc.handle(request)
            semaphore.signal()
        }
        semaphore.wait()
        return box.value ?? RPCResponse.failure(
            id: request.id,
            code: "internal_error",
            message: "Service returned no response"
        )
    }

    private func writeAll(fd: Int32, data: Data) -> Bool {
        return data.withUnsafeBytes { rawBuffer in
            guard let basePtr = rawBuffer.baseAddress else { return true }
            var totalWritten = 0
            let totalBytes = rawBuffer.count

            while totalWritten < totalBytes {
                let ptr = basePtr.advanced(by: totalWritten)
                let written = Darwin.write(fd, ptr, totalBytes - totalWritten)
                if written < 0 {
                    if errno == EINTR {
                        continue
                    }
                    return false
                }
                if written == 0 {
                    return false
                }
                totalWritten += written
            }
            return true
        }
    }

    private func unregisterAndCloseClient(_ clientFd: Int32) {
        let removed: Bool
        let remainingCount: Int

        stateLock.lock()
        removed = clientFds.remove(clientFd) != nil
        remainingCount = clientFds.count
        stateLock.unlock()

        Darwin.shutdown(clientFd, SHUT_RDWR)
        Darwin.close(clientFd)

        if removed {
            onClientCountChange?(remainingCount)
        }
    }
}
