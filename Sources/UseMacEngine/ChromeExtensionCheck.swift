import CryptoKit
import Darwin
import Foundation
import UseMacProtocol

/// Chrome extension IDs: 32 letters `a`–`p`. Chrome takes the first 128 bits of a SHA-256, writes them in hex and
/// maps the digits 0–f to a–p (`crx_file::id_util::GenerateId`). An unpacked extension whose manifest has no `key`
/// hashes its folder path; one with a `key` hashes the decoded key.
public enum ChromeExtensionID {
    public static func isValid(_ id: String) -> Bool {
        let scalars = id.unicodeScalars
        return scalars.count == 32 && scalars.allSatisfy { $0.value >= 97 && $0.value <= 112 }
    }

    public static func generate(from bytes: Data) -> String {
        let digest = SHA256.hash(data: bytes)
        var id = ""
        id.reserveCapacity(32)
        for byte in digest.prefix(16) {
            id.unicodeScalars.append(Unicode.Scalar(UInt8(97) + (byte >> 4)))
            id.unicodeScalars.append(Unicode.Scalar(UInt8(97) + (byte & 0x0f)))
        }
        return id
    }

    /// The ID Chrome gives a folder loaded with Load unpacked (`GenerateIdForPath`). Chrome first makes the path
    /// absolute with `base::MakeAbsoluteFilePath`, which is `realpath(3)` on macOS: symlinks resolved
    /// (`/tmp` → `/private/tmp`), no trailing slash, each name in its on-disk case. It hashes the path's UTF-8 bytes.
    public static func forUnpackedFolder(_ path: String) -> String {
        generate(from: Data(canonicalPath(path).utf8))
    }

    /// The ID of an extension whose manifest sets `key` (base64 of its public key).
    public static func forManifestKey(_ base64Key: String) -> String? {
        let compact = base64Key.filter { !$0.isWhitespace }
        guard let keyBytes = Data(base64Encoded: compact), !keyBytes.isEmpty else { return nil }
        return generate(from: keyBytes)
    }

    /// `realpath(3)`, or the standardized path when the folder does not exist.
    public static func canonicalPath(_ path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        if let resolved = realpath(path, &buffer) {
            return String(cString: resolved)
        }
        return (path as NSString).standardizingPath
    }
}

/// Orders extension versions as the extension reports them: `version_name` ("0.6.0 beta 2") or `version` ("0.6.0").
/// A release sorts after its pre-releases (alpha < beta < rc). Text that is not a version does not parse.
public struct ChromeExtensionVersion: Comparable, Sendable {
    let numbers: [Int]
    /// nil for a release; otherwise (alpha 0 / beta 1 / rc 2, number).
    let prerelease: (rank: Int, number: Int)?

    public init?(_ text: String) {
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        if rest.first == "v" { rest = rest.dropFirst() }
        let numericPart = rest.prefix { $0.isNumber || $0 == "." }
        let numbers = numericPart.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !numbers.isEmpty, numbers.allSatisfy({ $0 != nil }) else { return nil }
        self.numbers = numbers.compactMap { $0 }

        rest = rest.dropFirst(numericPart.count).drop { " -._".contains($0) }
        guard !rest.isEmpty else {
            self.prerelease = nil
            return
        }
        let word = rest.prefix { $0.isLetter }
        let rank: Int
        switch word {
        case "alpha", "a", "dev", "pre", "preview": rank = 0
        case "beta", "b": rank = 1
        case "rc": rank = 2
        default: return nil
        }
        let tail = rest.dropFirst(word.count).drop { " -._".contains($0) }
        guard tail.allSatisfy(\.isNumber) else { return nil }
        self.prerelease = (rank, Int(tail) ?? 0)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        let count = max(lhs.numbers.count, rhs.numbers.count)
        for index in 0..<count {
            let left = index < lhs.numbers.count ? lhs.numbers[index] : 0
            let right = index < rhs.numbers.count ? rhs.numbers[index] : 0
            if left != right { return left < right }
        }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil), (nil, _?): return false
        case (_?, nil): return true
        case let (left?, right?):
            return left.rank != right.rank ? left.rank < right.rank : left.number < right.number
        }
    }
}

/// The copy of the extension inside UseMac.app, and the ID Chrome gives it when that folder is loaded unpacked.
public struct BundledChromeExtension: Equatable, Sendable {
    public let directory: String
    public let version: String
    public let extensionId: String

    public init(directory: String, version: String, extensionId: String) {
        self.directory = directory
        self.version = version
        self.extensionId = extensionId
    }

    /// Reads `<directory>/manifest.json`. nil when the folder has no readable manifest.
    public init?(directory: String) {
        let canonical = ChromeExtensionID.canonicalPath(directory)
        let manifestURL = URL(fileURLWithPath: canonical).appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let versionName = (manifest["version_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = (manifest["version"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let reported = [versionName, version].compactMap({ $0 }).first(where: { !$0.isEmpty }) else {
            return nil
        }
        self.directory = canonical
        self.version = reported
        self.extensionId = (manifest["key"] as? String).flatMap(ChromeExtensionID.forManifestKey)
            ?? ChromeExtensionID.forUnpackedFolder(canonical)
    }

    /// `UseMac.app/Contents/Resources/chrome-extension`, for the app and for `Contents/Helpers/usemac`.
    public static func locate(bundle: Bundle = .main) -> BundledChromeExtension? {
        var candidates: [URL] = []
        if let resources = bundle.resourceURL {
            candidates.append(resources.appendingPathComponent("chrome-extension"))
        }
        if let executable = bundle.executableURL {
            candidates.append(executable
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/chrome-extension"))
        }
        for candidate in candidates {
            if let found = BundledChromeExtension(directory: candidate.path) {
                return found
            }
        }
        return nil
    }
}

/// What the app knows about the extension a Chrome profile runs: where Chrome loads it from, and whether it is
/// older than the copy this app ships.
public struct ChromeExtensionHealth: Equatable, Sendable {
    public enum Source: String, Sendable {
        /// Loaded from this app's own folder (`UseMac.app/Contents/Resources/chrome-extension`).
        case app
        /// Installed from the Chrome Web Store.
        case webStore = "web_store"
        /// Loaded unpacked from another folder (a repo checkout, an older copy of the app): app updates never reach it.
        case otherFolder = "other_folder"
        /// The extension did not report its ID, or this app has no bundled copy to compare with.
        case unknown
    }

    public var source: Source
    public var bundledVersion: String?
    public var outdated: Bool?
    public var reloadable: Bool
    public var note: String?

    public static func evaluate(
        extensionVersion: String,
        extensionId: String?,
        reloadable: Bool,
        bundled: BundledChromeExtension?,
        webStoreId: String?
    ) -> ChromeExtensionHealth {
        let id = extensionId?.lowercased()
        let storeId = webStoreId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let source: Source
        if let id, let storeId, !storeId.isEmpty, id == storeId {
            source = .webStore
        } else if let id, let bundled {
            source = id == bundled.extensionId.lowercased() ? .app : .otherFolder
        } else {
            source = .unknown
        }

        var outdated: Bool?
        if let bundled,
           let running = ChromeExtensionVersion(extensionVersion),
           let shipped = ChromeExtensionVersion(bundled.version) {
            outdated = running < shipped
        }

        var notes: [String] = []
        if source == .otherFolder {
            notes.append("Loaded from another folder, app updates won't reach it.")
        }
        if outdated == true, let bundled {
            let versions = "Chrome runs extension \(extensionVersion); this app ships \(bundled.version)."
            switch source {
            case .webStore:
                notes.append("\(versions) Chrome installs Web Store updates on its own.")
            case .otherFolder:
                notes.append(reloadable
                    ? "\(versions) Reload it to pick up that folder's current code, or load the app's copy instead."
                    : "\(versions) Reload it once in chrome://extensions to pick up that folder's current code.")
            case .app, .unknown:
                notes.append(reloadable
                    ? "\(versions) Reload the extension to run the new code."
                    : "\(versions) Reload it once in chrome://extensions; after that UseMac can reload it for you.")
            }
        }

        return ChromeExtensionHealth(
            source: source,
            bundledVersion: bundled?.version,
            outdated: outdated,
            reloadable: reloadable,
            note: notes.isEmpty ? nil : notes.joined(separator: " ")
        )
    }
}

/// Remembers the extension IDs from recent WebSocket `Origin` headers (`chrome-extension://<id>`). The upgrade
/// handler cannot tell which connection a header belongs to, so a session takes an ID only when every upgrade since
/// it was accepted came from the same extension. Extensions that predate `hello.extensionId` are identified this way.
final class ExtensionOriginLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(id: String, at: Date)] = []
    private let retention: TimeInterval = 30

    func record(_ id: String, at date: Date = Date()) {
        lock.lock()
        entries.removeAll { date.timeIntervalSince($0.at) > retention }
        entries.append((id.lowercased(), date))
        lock.unlock()
    }

    /// The one extension ID seen since `date`, or nil when there were none or several.
    func unambiguousId(since date: Date) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let ids = Set(entries.filter { $0.at >= date }.map(\.id))
        return ids.count == 1 ? ids.first : nil
    }
}
