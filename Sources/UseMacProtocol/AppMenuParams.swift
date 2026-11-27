import Foundation

/// Inspect or invoke a native macOS application's menu bar items without focusing the app.
public struct AppMenuParams: Codable, Equatable, Sendable {
    public var app: String?
    /// Substring filter when listing menu items.
    public var query: String?
    /// Menu hierarchy to invoke, e.g. `["File", "Export as PDF…"]`. Omit to list items.
    public var menuPath: [String]?

    public init(
        app: String? = nil,
        query: String? = nil,
        menuPath: [String]? = nil
    ) {
        self.app = app
        self.query = query
        self.menuPath = menuPath
    }
}

public struct AppMenuItemInfo: Codable, Equatable, Sendable {
    public var path: [String]
    public var title: String
    public var shortcut: String?
    public var enabled: Bool

    public init(
        path: [String],
        title: String,
        shortcut: String? = nil,
        enabled: Bool = true
    ) {
        self.path = path
        self.title = title
        self.shortcut = shortcut
        self.enabled = enabled
    }
}

public struct AppMenuResult: Codable, Equatable, Sendable {
    public var app: String
    public var items: [AppMenuItemInfo]?
    public var invokedPath: [String]?
    public var message: String?

    public init(
        app: String,
        items: [AppMenuItemInfo]? = nil,
        invokedPath: [String]? = nil,
        message: String? = nil
    ) {
        self.app = app
        self.items = items
        self.invokedPath = invokedPath
        self.message = message
    }
}
