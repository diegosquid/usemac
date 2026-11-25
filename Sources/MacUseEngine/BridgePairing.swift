import CryptoKit
import Darwin
import Foundation

private enum BridgeHex {
    private static let alphabet: [UInt8] = Array("0123456789abcdef".utf8)

    static func encode<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            out.append(alphabet[Int(byte >> 4)])
            out.append(alphabet[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func decodeLowercaseHex(_ hex: String, expectedByteCount: Int) -> Data? {
        let utf8 = Array(hex.utf8)
        guard utf8.count == expectedByteCount * 2 else {
            return nil
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(expectedByteCount)
        var i = 0
        while i < utf8.count {
            guard let hi = nibble(utf8[i]), let lo = nibble(utf8[i + 1]) else {
                return nil
            }
            bytes.append((hi << 4) | lo)
            i += 2
        }
        return Data(bytes)
    }

    static func isLowercaseHex(_ value: String, expectedLength: Int) -> Bool {
        let utf8 = value.utf8
        guard utf8.count == expectedLength else {
            return false
        }
        for byte in utf8 {
            if nibble(byte) == nil {
                return false
            }
        }
        return true
    }

    private static func nibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39:
            return byte - 0x30
        case 0x61...0x66:
            return byte - 0x61 + 10
        default:
            return nil
        }
    }
}

public struct BridgeKey: Equatable, Sendable {
    public let bytes: Data

    public var text: String {
        "umk_" + BridgeHex.encode(bytes)
    }

    public init?(text: String) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.hasPrefix("umk_") else {
            return nil
        }
        let hexPart = String(normalized.dropFirst(4))
        guard let decoded = BridgeHex.decodeLowercaseHex(hexPart, expectedByteCount: 32) else {
            return nil
        }
        self.bytes = decoded
    }

    public init?(bytes: Data) {
        guard bytes.count == 32 else {
            return nil
        }
        self.bytes = bytes
    }

    public static func random() -> BridgeKey {
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        return BridgeKey(bytes: data)!
    }
}

public enum BridgeAuth {
    public static func randomNonceHex() -> String {
        let key = SymmetricKey(size: .bits256)
        return key.withUnsafeBytes { BridgeHex.encode($0) }
    }

    public static func isNonceHex(_ value: String) -> Bool {
        BridgeHex.isLowercaseHex(value, expectedLength: 64)
    }

    public static func serverProof(key: BridgeKey, clientNonce: String, serverNonce: String) -> String {
        hmacHex(key: key, message: "usemac-bridge-v2|server|\(clientNonce)|\(serverNonce)")
    }

    public static func clientProof(key: BridgeKey, clientNonce: String, serverNonce: String) -> String {
        hmacHex(key: key, message: "usemac-bridge-v2|client|\(clientNonce)|\(serverNonce)")
    }

    public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        let maxLen = max(aBytes.count, bBytes.count)
        var diff: UInt8 = (aBytes.count == bBytes.count) ? 0 : 1
        for i in 0..<maxLen {
            let ab = i < aBytes.count ? aBytes[i] : 0
            let bb = i < bBytes.count ? bBytes[i] : 0
            diff |= ab ^ bb
        }
        return diff == 0
    }

    private static func hmacHex(key: BridgeKey, message: String) -> String {
        let symKey = SymmetricKey(data: key.bytes)
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: symKey)
        return mac.withUnsafeBytes { BridgeHex.encode($0) }
    }
}

public final class BridgePairingStore: @unchecked Sendable {
    public static var defaultDirectory: URL {
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return appSupport.appendingPathComponent("usemac", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/usemac", isDirectory: true)
    }

    private let directory: URL
    private let lock = NSLock()

    private var keyFileURL: URL {
        directory.appendingPathComponent("bridge-key", isDirectory: false)
    }

    public init(directory: URL = BridgePairingStore.defaultDirectory) {
        self.directory = directory
    }

    public func loadOrCreateKey() throws -> BridgeKey {
        lock.lock()
        defer { lock.unlock() }

        if let existing = readExistingKeyLocked() {
            return existing
        }

        let created = BridgeKey.random()
        try writeKeyAtomicallyLocked(created)
        return created
    }

    public func resetKey() throws -> BridgeKey {
        lock.lock()
        defer { lock.unlock() }

        let created = BridgeKey.random()
        try writeKeyAtomicallyLocked(created)
        return created
    }

    private func readExistingKeyLocked() -> BridgeKey? {
        let path = keyFileURL.path
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            return nil
        }
        defer { Darwin.close(fd) }

        var st = stat()
        guard Darwin.fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 256)
        while data.count < 4096 {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n > 0 {
                data.append(contentsOf: buffer[0..<n])
            } else if n == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                return nil
            }
        }

        guard let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return BridgeKey(text: text)
    }

    private func writeKeyAtomicallyLocked(_ key: BridgeKey) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if Darwin.chmod(directory.path, 0o700) != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        let tempURL = directory.appendingPathComponent(".bridge-key.\(UUID().uuidString).tmp", isDirectory: false)
        let tempPath = tempURL.path
        let fd = Darwin.open(tempPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        var renamed = false
        defer {
            if !renamed {
                Darwin.unlink(tempPath)
            }
        }

        do {
            if Darwin.fchmod(fd, 0o600) != 0 {
                let err = errno
                Darwin.close(fd)
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
            }

            let content = Array((key.text + "\n").utf8)
            var offset = 0
            while offset < content.count {
                let written = content.withUnsafeBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return -1 }
                    return Darwin.write(fd, base.advanced(by: offset), content.count - offset)
                }
                if written > 0 {
                    offset += written
                } else if written < 0 && errno == EINTR {
                    continue
                } else {
                    let err = errno
                    Darwin.close(fd)
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
                }
            }

            _ = Darwin.fsync(fd)
            if Darwin.close(fd) != 0 {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }

            if Darwin.rename(tempPath, keyFileURL.path) != 0 {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            renamed = true
        }
    }
}
