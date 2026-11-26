import CryptoKit
import Darwin
import Foundation
import UseMacProtocol

/// Which Chrome extensions may open the bridge WebSocket, judged by the `chrome-extension://<id>` in the upgrade's
/// `Origin` header. The pairing handshake, not this check, is what proves an extension to the app. This only keeps
/// other extensions away from the handshake once the app knows its own IDs.
///
/// - No Chrome Web Store ID and no `USEMAC_ALLOWED_EXTENSION_IDS` (beta builds): every extension origin may try.
/// - Otherwise only those IDs, plus the ID Chrome gives the app's own extension folder when it is loaded unpacked,
///   plus the IDs in the app's `usemac.bridge.allowedExtensionIds` default. So a store build still pairs with the
///   "Load unpacked" fallback the setup guide offers, and refuses copies loaded from other folders (a repo checkout)
///   unless the user lists their ID. Only the user can set that default (`defaults write app.usemac …`); nothing
///   over the socket, MCP or CLI writes it, and it only widens the check, never turns it on.
enum BridgeOriginPolicy {
    static let allowedIdsEnvironmentKey = "USEMAC_ALLOWED_EXTENSION_IDS"
    static let allowedIdsDefaultsKey = "usemac.bridge.allowedExtensionIds"

    /// The extra IDs in the app's defaults: an array of IDs, or one comma-separated string.
    static func defaultsExtensionIds(_ defaults: UserDefaults = .standard) -> [String] {
        switch defaults.object(forKey: allowedIdsDefaultsKey) {
        case let ids as [Any]:
            return ids.compactMap { $0 as? String }
        case let text as String:
            return text.split(separator: ",").map(String.init)
        default:
            return []
        }
    }

    /// The extension ID in an `Origin` header value, lowercased, or nil when it is not a `chrome-extension://` origin.
    static func extensionId(fromOrigin origin: String) -> String? {
        let normalized = origin.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.hasPrefix("chrome-extension://") else {
            return nil
        }
        let afterScheme = normalized.dropFirst("chrome-extension://".count)
        let extId = afterScheme.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return extId.isEmpty ? nil : extId
    }

    /// The extension IDs the bridge accepts, lowercased. Empty means any extension origin is accepted.
    static func allowedExtensionIds(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaultsIds: [String] = BridgeOriginPolicy.defaultsExtensionIds(),
        webStoreId: String? = UseMacDefaults.chromeWebStoreExtensionId,
        bundledUnpackedId: String? = BridgeOriginPolicy.bundledUnpackedExtensionId
    ) -> Set<String> {
        func normalized(_ ids: [String]) -> [String] {
            ids.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
        }
        // The store ID and USEMAC_ALLOWED_EXTENSION_IDS turn the check on.
        var allowed = Set(normalized(environment[allowedIdsEnvironmentKey]?.split(separator: ",").map(String.init) ?? []))
        allowed.formUnion(normalized([webStoreId].compactMap { $0 }))
        guard !allowed.isEmpty else {
            return []
        }
        // The user's extra IDs and the copy the app ships only widen it.
        allowed.formUnion(normalized(defaultsIds))
        allowed.formUnion(normalized([bundledUnpackedId].compactMap { $0 }))
        return allowed
    }

    /// The ID Chrome gives `UseMac.app/Contents/Resources/chrome-extension` when it is loaded unpacked, or nil when
    /// the running app has no bundled copy (tests, `swift run`). Computed once: the bundle does not move while it runs.
    static let bundledUnpackedExtensionId: String? = {
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("chrome-extension"),
              FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.json").path) else {
            return nil
        }
        return unpackedExtensionId(forFolder: folder.path)
    }()

    /// Chrome's ID for a folder loaded unpacked (`crx_file::id_util::GenerateIdForPath`): SHA-256 of the folder's
    /// `realpath(3)` (what `base::MakeAbsoluteFilePath` returns on macOS), first 16 bytes in hex, digits 0–f mapped
    /// to a–p.
    static func unpackedExtensionId(forFolder path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let canonical = realpath(path, &buffer).map { String(cString: $0) } ?? (path as NSString).standardizingPath
        let digest = SHA256.hash(data: Data(canonical.utf8))
        var id = ""
        id.reserveCapacity(32)
        for byte in digest.prefix(16) {
            id.unicodeScalars.append(Unicode.Scalar(UInt8(97) + (byte >> 4)))
            id.unicodeScalars.append(Unicode.Scalar(UInt8(97) + (byte & 0x0f)))
        }
        return id
    }
}
