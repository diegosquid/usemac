import Foundation

public enum NavigationPolicy {
    public struct BlockedURL: Error, Equatable, Sendable {
        public let message: String

        public init(message: String) {
            self.message = message
        }
    }

    /// Returns the normalized absolute URL string, or the reason it is blocked.
    public static func validate(_ raw: String?) -> Result<String, BlockedURL> {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(BlockedURL(message: "A URL is required."))
        }

        if trimmed.lowercased() == "about:blank" {
            return .success("about:blank")
        }

        if trimmed.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            return .failure(BlockedURL(message: "Invalid URL."))
        }

        let candidate: String
        if let colonIndex = trimmed.firstIndex(of: ":") {
            let potentialScheme = trimmed[..<colonIndex]
            let afterColon = trimmed[trimmed.index(after: colonIndex)...]
            if isValidSchemePrefix(potentialScheme) && !isPortPrefix(afterColon) {
                let lowerScheme = potentialScheme.lowercased()
                guard lowerScheme == "http" || lowerScheme == "https" else {
                    return .failure(BlockedURL(
                        message: "Only http(s) URLs can be opened. Blocked scheme: \(lowerScheme)"
                    ))
                }
                candidate = trimmed
            } else {
                candidate = "https://\(trimmed)"
            }
        } else {
            candidate = "https://\(trimmed)"
        }

        guard let parsed = URL(string: candidate),
              let scheme = parsed.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = parsed.host,
              !host.isEmpty else {
            return .failure(BlockedURL(message: "Invalid URL."))
        }

        return .success(parsed.absoluteString)
    }

    private static func isValidSchemePrefix(_ prefix: Substring) -> Bool {
        guard let first = prefix.unicodeScalars.first else {
            return false
        }
        guard isASCIIAlpha(first) else {
            return false
        }
        for scalar in prefix.unicodeScalars.dropFirst() {
            guard isASCIIAlpha(scalar)
                || isASCIIDigit(scalar)
                || scalar == "+"
                || scalar == "."
                || scalar == "-" else {
                return false
            }
        }
        return true
    }

    private static func isPortPrefix(_ suffix: Substring) -> Bool {
        var digitCount = 0
        var idx = suffix.startIndex
        while idx < suffix.endIndex {
            let ch = suffix[idx]
            if let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1, isASCIIDigit(scalar) {
                digitCount += 1
                if digitCount > 5 {
                    return false
                }
                idx = suffix.index(after: idx)
            } else {
                break
            }
        }
        guard digitCount >= 1 else {
            return false
        }
        return idx == suffix.endIndex || suffix[idx] == "/"
    }

    private static func isASCIIAlpha(_ scalar: UnicodeScalar) -> Bool {
        (scalar.value >= 65 && scalar.value <= 90) || (scalar.value >= 97 && scalar.value <= 122)
    }

    private static func isASCIIDigit(_ scalar: UnicodeScalar) -> Bool {
        scalar.value >= 48 && scalar.value <= 57
    }
}
