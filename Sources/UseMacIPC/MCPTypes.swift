import Foundation
import UseMacProtocol

/// Client-side filtering of observed elements for `usemac find` and `usemac observe --role/--text`.
/// Follows the same rules the engine uses to resolve `ActionStep.match`, so what `find` prints is what a
/// `match` step would hit: text compares are case- and diacritic-insensitive "contains" (equality with
/// `exact`), `title` also covers the AX description (the indexer stores it as the title), `text` checks title
/// and value, `role` is compared with or without the "AX" prefix, and every given field must match.
public enum ClientElementFilter {
    public static func matches(_ node: ElementNode, _ match: ElementMatch) -> Bool {
        let exact = match.exact ?? false
        if let role = nonEmpty(match.role), !roleMatches(node.role, role) {
            return false
        }
        if let title = nonEmpty(match.title), !textMatches(node.title, title, exact: exact) {
            return false
        }
        if let value = nonEmpty(match.value), !textMatches(node.value, value, exact: exact) {
            return false
        }
        if let text = nonEmpty(match.text),
           !textMatches(node.title, text, exact: exact),
           !textMatches(node.value, text, exact: exact) {
            return false
        }
        return true
    }

    /// Every element that matches, in tree order (`index` is ignored).
    public static func filter(_ nodes: [ElementNode], _ match: ElementMatch) -> [ElementNode] {
        nodes.filter { matches($0, match) }
    }

    /// The element a `match` step would resolve to: the `index`-th match (default 0), or nil.
    public static func resolve(_ nodes: [ElementNode], _ match: ElementMatch) -> ElementNode? {
        let all = filter(nodes, match)
        let index = max(0, match.index ?? 0)
        return index < all.count ? all[index] : nil
    }

    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !fold(text).isEmpty else { return nil }
        return text
    }

    private static func roleMatches(_ role: String, _ wanted: String) -> Bool {
        let have = fold(role)
        let want = fold(wanted)
        return have == want || have == "ax" + want || "ax" + have == want
    }

    private static func textMatches(_ haystack: String?, _ needle: String, exact: Bool) -> Bool {
        guard let haystack else { return false }
        let have = fold(haystack)
        let want = fold(needle)
        return exact ? have == want : have.contains(want)
    }
}

/// One-line "what to do next" for the error codes agents hit most. Shared by the CLI and the MCP server so
/// both give the same advice.
public enum UseMacErrorGuide {
    public static func hint(for code: String) -> String? {
        switch code {
        case "TARGET_NOT_FRONTMOST":
            return "This step needs real keyboard or mouse input but the app is not in front, so nothing was sent. Use a background step (click on an element with AXPress, setValue, axAction) or retry the batch with foreground: true."
        case "STALE_SNAPSHOT":
            return "The app's window changed since your last observe, so nothing ran. Observe again and use the new ids, or target the step with match."
        case "USER_ACTIVE":
            return "The user is typing or using the mouse, so the foreground burst was refused. Wait a few seconds and retry; never force it while the user is active."
        case "ELEMENT_NOT_FOUND":
            return "No element matched. Observe again (raise maxDepth/maxElements or scroll the list), loosen the match, or check its index."
        case "WAIT_TIMEOUT":
            return "The element did not appear (or go away) in time. Observe to see the current state before retrying."
        case "RESTRICTED_PAGE":
            return "The Chrome extension cannot script this page (Chrome Web Store or chrome:// pages). Make the tab active with browser_open tabId + activate: true (CLI: browser open --tab <id> --activate), or open the URL with newWindow: true (CLI: --new-window), then use native observe/act with app \"Google Chrome\"."
        case "CAPTURE_TOO_SMALL":
            return "The captured window is too small to trust (a helper strip or hidden window). Do not draw conclusions from it: observe the app instead, or make the right window visible and retry."
        case "POLICY_BLOCKED", "POLICY_LOCKED", "URL_BLOCKED", "UPLOAD_BLOCKED":
            return "Blocked by a UseMac safety rule. Stop and tell the user; do not look for another route."
        case "SELF_TARGET_BLOCKED":
            return "UseMac never observes or acts on its own windows. Stop and tell the user; never try to change UseMac's settings through its UI."
        case "TARGET_BUSY":
            return "Another agent's task is working in this window or tab, so nothing ran. Wait and retry once it finishes, or work in your own window or tab (browser_open for a new tab). Observe and screenshot still work. Never close or take over the other task's window."
        case "DAEMON_REQUIRED":
            return "Ask the user to open UseMac.app; do not bypass it with --standalone."
        default:
            return nil
        }
    }
}

public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else if let double = try? container.decode(Double.self) {
            self = .double(double)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .int(value):
            try container.encode(value)
        case let .double(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case let .int(value):
            return value
        case let .double(value):
            guard value.isFinite,
                  value.rounded(.towardZero) == value,
                  value >= Double(Int.min),
                  value < Double(Int.max) else {
                return nil
            }
            return Int(value)
        default:
            return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case let .double(value):
            return value
        case let .int(value):
            return Double(value)
        default:
            return nil
        }
    }

    public var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    public subscript(index: Int) -> JSONValue? {
        guard let array = arrayValue, index >= 0, index < array.count else {
            return nil
        }
        return array[index]
    }
}

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) {
        self = .null
    }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self = .int(value)
    }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) {
        self = .double(value)
    }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) {
        self = .array(elements)
    }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        var dict: [String: JSONValue] = [:]
        dict.reserveCapacity(elements.count)
        for (key, value) in elements {
            dict[key] = value
        }
        self = .object(dict)
    }
}

public enum JSONRPCId: Codable, Equatable, Sendable {
    case int(Int)
    case string(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intId = try? container.decode(Int.self) {
            self = .int(intId)
        } else if let stringId = try? container.decode(String.self) {
            self = .string(stringId)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "JSON-RPC id must be an integer or string"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .int(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        }
    }
}

public struct MCPRequest: Codable, Equatable, Sendable {
    public var jsonrpc: String
    public var id: JSONRPCId?
    public var method: String
    public var params: [String: JSONValue]?

    public init(
        jsonrpc: String = "2.0",
        id: JSONRPCId? = nil,
        method: String,
        params: [String: JSONValue]? = nil
    ) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct MCPError: Codable, Equatable, Sendable {
    public static let parseError = -32700
    public static let invalidRequest = -32600
    public static let methodNotFound = -32601
    public static let invalidParams = -32602
    public static let internalError = -32603

    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

public struct MCPResponse: Codable, Equatable, Sendable {
    public var jsonrpc: String
    public var id: JSONRPCId?
    public var result: JSONValue?
    public var error: MCPError?

    public init(
        jsonrpc: String = "2.0",
        id: JSONRPCId? = nil,
        result: JSONValue? = nil,
        error: MCPError? = nil
    ) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.result = result
        self.error = error
    }

    public static func success(id: JSONRPCId?, result: JSONValue) -> MCPResponse {
        MCPResponse(jsonrpc: "2.0", id: id, result: result, error: nil)
    }

    public static func failure(
        id: JSONRPCId?,
        code: Int,
        message: String,
        data: JSONValue? = nil
    ) -> MCPResponse {
        MCPResponse(
            jsonrpc: "2.0",
            id: id,
            result: nil,
            error: MCPError(code: code, message: message, data: data)
        )
    }
}

public struct MCPToolAnnotations: Codable, Equatable, Sendable {
    public var title: String
    public var readOnlyHint: Bool
    public var destructiveHint: Bool
    public var idempotentHint: Bool
    public var openWorldHint: Bool

    public init(
        title: String,
        readOnlyHint: Bool,
        destructiveHint: Bool,
        idempotentHint: Bool,
        openWorldHint: Bool
    ) {
        self.title = title
        self.readOnlyHint = readOnlyHint
        self.destructiveHint = destructiveHint
        self.idempotentHint = idempotentHint
        self.openWorldHint = openWorldHint
    }

    public var jsonValue: JSONValue {
        .object([
            "title": .string(title),
            "readOnlyHint": .bool(readOnlyHint),
            "destructiveHint": .bool(destructiveHint),
            "idempotentHint": .bool(idempotentHint),
            "openWorldHint": .bool(openWorldHint)
        ])
    }
}

public struct MCPToolDefinition: Codable, Equatable, Sendable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue
    public var annotations: MCPToolAnnotations?

    public init(
        name: String,
        description: String,
        inputSchema: JSONValue,
        annotations: MCPToolAnnotations? = nil
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.annotations = annotations
    }

    public var jsonValue: JSONValue {
        var obj: [String: JSONValue] = [
            "name": .string(name),
            "description": .string(description),
            "inputSchema": inputSchema
        ]
        if let annotations {
            obj["annotations"] = annotations.jsonValue
        }
        return .object(obj)
    }
}

public enum MCPContentBlock: Codable, Equatable, Sendable {
    case text(String)
    case image(data: String, mimeType: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case data
        case mimeType
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            let text = try container.decode(String.self, forKey: .text)
            self = .text(text)
        case "image":
            let data = try container.decode(String.self, forKey: .data)
            let mimeType = try container.decode(String.self, forKey: .mimeType)
            self = .image(data: data, mimeType: mimeType)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unsupported MCPContentBlock type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case let .image(data, mimeType):
            try container.encode("image", forKey: .type)
            try container.encode(data, forKey: .data)
            try container.encode(mimeType, forKey: .mimeType)
        }
    }

    public var jsonValue: JSONValue {
        switch self {
        case let .text(text):
            return .object([
                "type": .string("text"),
                "text": .string(text)
            ])
        case let .image(data, mimeType):
            return .object([
                "type": .string("image"),
                "data": .string(data),
                "mimeType": .string(mimeType)
            ])
        }
    }
}
