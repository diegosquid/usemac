import Darwin
import Foundation
import UseMacProtocol

public enum UnixSocketServerError: Error, LocalizedError, Sendable {
    case pathTooLong(String, maxBytes: Int)
    case pathOwnedByAnotherUser(String)
    case unsafeSocketDirectory(String)
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
        case let .unsafeSocketDirectory(path):
            return "Socket folder is not private to this user: \(path)"
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

/// Rules for the private folder that holds the default socket (`/tmp/usemac-$UID`).
public enum PrivateSocketDirectory {
    /// Creates the folder with mode 0700, or tightens an existing one that this user owns.
    /// Throws when the path is a symlink, not a folder, or owned by someone else.
    public static func ensure(atPath path: String) throws {
        var st = Darwin.stat()
        if Darwin.lstat(path, &st) != 0 {
            guard errno == ENOENT else {
                throw UnixSocketServerError.unsafeSocketDirectory(path)
            }
            if Darwin.mkdir(path, 0o700) != 0 && errno != EEXIST {
                throw UnixSocketServerError.unsafeSocketDirectory(path)
            }
            guard Darwin.lstat(path, &st) == 0 else {
                throw UnixSocketServerError.unsafeSocketDirectory(path)
            }
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid() else {
            throw UnixSocketServerError.unsafeSocketDirectory(path)
        }
        if (st.st_mode & 0o077) != 0 {
            guard Darwin.chmod(path, 0o700) == 0 else {
                throw UnixSocketServerError.unsafeSocketDirectory(path)
            }
        }
    }

    /// True when the folder is a real folder (not a symlink) owned by `expectedUID` with no group or other access.
    public static func isTrusted(atPath path: String, expectedUID: uid_t) -> Bool {
        var st = Darwin.stat()
        guard Darwin.lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFDIR
            && st.st_uid == expectedUID
            && (st.st_mode & 0o077) == 0
    }
}

public final class UnixSocketServer: @unchecked Sendable {
    public static let maxRequestBytes = 16 * 1024 * 1024

    private let socketPath: String
    private let service: UseMacServiceProtocol
    private let onClientCountChange: (@Sendable (Int) -> Void)?
    private let allowedPeerUID: uid_t

    private let stateLock = NSLock()
    private var serverFd: Int32 = -1
    private var running = false
    private var clientFds: Set<Int32> = []
    private var boundInode: ino_t = 0
    private var boundDevice: dev_t = 0
    private var pathHealthTimer: DispatchSourceTimer?
    private let pathCheckInterval: TimeInterval

    private let acceptQueue = DispatchQueue(label: "app.usemac.ipc.server.accept", qos: .userInteractive)
    private let healthQueue = DispatchQueue(label: "app.usemac.ipc.server.path-health", qos: .utility)
    private let clientQueue = DispatchQueue(
        label: "app.usemac.ipc.server.clients",
        qos: .userInteractive,
        attributes: .concurrent
    )

    public init(
        socketPath: String = UseMacDefaults.defaultSocketPath,
        service: UseMacServiceProtocol,
        onClientCountChange: (@Sendable (Int) -> Void)? = nil,
        allowedPeerUID: uid_t = getuid(),
        pathCheckInterval: TimeInterval = 30
    ) {
        self.socketPath = socketPath
        self.service = service
        self.onClientCountChange = onClientCountChange
        self.allowedPeerUID = allowedPeerUID
        self.pathCheckInterval = pathCheckInterval
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

        let bound = try bindListeningSocket()

        stateLock.lock()
        serverFd = bound.fd
        boundInode = bound.inode
        boundDevice = bound.device
        running = true
        stateLock.unlock()

        acceptQueue.async { [weak self] in
            self?.runAcceptLoop(listenFd: bound.fd)
        }
        startPathHealthTimer()
    }

    /// Creates, binds and listens on the socket path. Returns the listening descriptor and the
    /// identity of the file it created, so later checks can tell our socket from a replacement.
    private func bindListeningSocket() throws -> (fd: Int32, inode: ino_t, device: dev_t) {
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

        var st = Darwin.stat()
        guard Darwin.lstat(socketPath, &st) == 0 else {
            let err = errno
            throw UnixSocketServerError.bindFailed(socketPath, err)
        }

        closeOnError = false
        return (fd, st.st_ino, st.st_dev)
    }

    // MARK: - Self-healing socket path

    private func startPathHealthTimer() {
        guard pathCheckInterval > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: healthQueue)
        timer.schedule(deadline: .now() + pathCheckInterval, repeating: pathCheckInterval, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            self?.checkSocketPathHealth()
        }
        stateLock.lock()
        pathHealthTimer?.cancel()
        pathHealthTimer = timer
        stateLock.unlock()
        timer.resume()
    }

    /// Recreates the socket when its file was deleted (for example by a manual `rm`) while the server
    /// keeps running. Never touches a path that now holds something else or another live server.
    private func checkSocketPathHealth() {
        stateLock.lock()
        let isActive = running
        let inode = boundInode
        let device = boundDevice
        stateLock.unlock()
        guard isActive else { return }

        var st = Darwin.stat()
        if Darwin.lstat(socketPath, &st) == 0 {
            if (st.st_mode & S_IFMT) == S_IFSOCK && st.st_ino == inode && st.st_dev == device {
                return
            }
            if (st.st_mode & S_IFMT) != S_IFSOCK || isExistingSocketActive() {
                return
            }
        }

        guard let bound = try? bindListeningSocket() else { return }

        stateLock.lock()
        guard running else {
            stateLock.unlock()
            Darwin.close(bound.fd)
            unlinkIfOwned(inode: bound.inode, device: bound.device)
            return
        }
        let previousFd = serverFd
        serverFd = bound.fd
        boundInode = bound.inode
        boundDevice = bound.device
        stateLock.unlock()

        if previousFd >= 0 {
            Darwin.shutdown(previousFd, SHUT_RDWR)
            Darwin.close(previousFd)
        }
        acceptQueue.async { [weak self] in
            self?.runAcceptLoop(listenFd: bound.fd)
        }
    }

    /// Removes the socket file only when it is still the one this server created.
    private func unlinkIfOwned(inode: ino_t, device: dev_t) {
        var st = Darwin.stat()
        guard Darwin.lstat(socketPath, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFSOCK,
              st.st_ino == inode,
              st.st_dev == device else {
            return
        }
        Darwin.unlink(socketPath)
    }

    public func stop() {
        let fdToClose: Int32
        let clientsToClose: [Int32]
        let shouldNotifyZero: Bool

        let ownedInode: ino_t
        let ownedDevice: dev_t

        stateLock.lock()
        pathHealthTimer?.cancel()
        pathHealthTimer = nil
        if !running && serverFd < 0 && clientFds.isEmpty {
            stateLock.unlock()
            return
        }
        running = false
        fdToClose = serverFd
        serverFd = -1
        ownedInode = boundInode
        ownedDevice = boundDevice
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

        unlinkIfOwned(inode: ownedInode, device: ownedDevice)

        if shouldNotifyZero {
            onClientCountChange?(0)
        }
    }

    private func prepareSocketPath() throws {
        let parentDir = (socketPath as NSString).deletingLastPathComponent
        if parentDir == UseMacDefaults.defaultSocketDirectory {
            try PrivateSocketDirectory.ensure(atPath: parentDir)
        } else if !parentDir.isEmpty {
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

    private final class AtomicFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = false

        var value: Bool {
            lock.lock()
            defer { lock.unlock() }
            return _value
        }

        func set(_ newValue: Bool) {
            lock.lock()
            _value = newValue
            lock.unlock()
        }
    }

    private func handleClient(clientFd: Int32) {
        let replyQueue = DispatchQueue(label: "app.usemac.ipc.server.reply.\(clientFd)", qos: .userInteractive)
        let inFlightGroup = DispatchGroup()
        let writeFailed = AtomicFlag()

        defer {
            inFlightGroup.wait()
            replyQueue.sync {}
            unregisterAndCloseClient(clientFd)
        }

        let sendResponse: @Sendable (RPCResponse) -> Void = { [weak self] response in
            guard let self, self.isRunning, !writeFailed.value else { return }
            guard var encoded = try? JSONEncoder().encode(response) else { return }
            encoded.append(0x0A)
            replyQueue.async { [weak self] in
                guard let self, self.isRunning, !writeFailed.value else { return }
                if !self.writeAll(fd: clientFd, data: encoded) {
                    writeFailed.set(true)
                    Darwin.shutdown(clientFd, SHUT_RDWR)
                }
            }
        }

        let decoder = JSONDecoder()
        var readBuffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)

        while isRunning && !writeFailed.value {
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
                        replyQueue.sync {
                            sendOversizedRequestError(clientFd: clientFd)
                        }
                        return
                    }

                    var lineData = readBuffer.subdata(in: readBuffer.startIndex..<newlineIndex)
                    readBuffer.removeSubrange(readBuffer.startIndex...newlineIndex)

                    if lineData.last == 0x0D {
                        lineData.removeLast()
                    }
                    if !lineData.isEmpty {
                        do {
                            let request = try decoder.decode(RPCRequest.self, from: lineData)
                            let svc = service
                            inFlightGroup.enter()
                            Task {
                                defer { inFlightGroup.leave() }
                                let response = await svc.handle(request)
                                sendResponse(response)
                            }
                        } catch {
                            let failure = RPCResponse.failure(
                                id: "unknown",
                                code: "invalid_request",
                                message: "Failed to decode RPCRequest: \(error.localizedDescription)"
                            )
                            sendResponse(failure)
                        }
                    }

                    guard let nextNewline = readBuffer.firstIndex(of: 0x0A) else {
                        break
                    }
                    newlineIndex = nextNewline
                }
            }

            if readBuffer.count > Self.maxRequestBytes {
                replyQueue.sync {
                    sendOversizedRequestError(clientFd: clientFd)
                }
                return
            }
        }
    }

    private func sendOversizedRequestError(clientFd: Int32) {
        let response = RPCResponse.failure(
            id: "unknown",
            code: "message_too_large",
            message: "Request exceeds 16 MiB"
        )
        if var encoded = try? JSONEncoder().encode(response) {
            encoded.append(0x0A)
            _ = writeAll(fd: clientFd, data: encoded)
        }
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
