import Foundation

/// Open and observe or extract multiple URLs in parallel Chrome background tabs.
public struct BrowserBatchParams: Codable, Equatable, Sendable {
    public var profile: String?
    public var urls: [String]
    /// `"observe"` or `"extract"`.
    public var mode: String?
    public var extractMode: String?
    public var maxElements: Int?
    public var autoDismissOverlays: Bool?
    public var closeAfter: Bool?

    public init(
        profile: String? = nil,
        urls: [String],
        mode: String? = nil,
        extractMode: String? = nil,
        maxElements: Int? = nil,
        autoDismissOverlays: Bool? = nil,
        closeAfter: Bool? = nil
    ) {
        self.profile = profile
        self.urls = urls
        self.mode = mode
        self.extractMode = extractMode
        self.maxElements = maxElements
        self.autoDismissOverlays = autoDismissOverlays
        self.closeAfter = closeAfter
    }
}

public struct BrowserBatchItemResult: Codable, Equatable, Sendable {
    public var url: String
    public var tabId: Int?
    public var success: Bool
    public var error: String?
    public var snapshot: WindowSnapshot?
    public var extract: BrowserExtractResult?
    public var latencyMs: Double

    public init(
        url: String,
        tabId: Int? = nil,
        success: Bool,
        error: String? = nil,
        snapshot: WindowSnapshot? = nil,
        extract: BrowserExtractResult? = nil,
        latencyMs: Double = 0
    ) {
        self.url = url
        self.tabId = tabId
        self.success = success
        self.error = error
        self.snapshot = snapshot
        self.extract = extract
        self.latencyMs = latencyMs
    }
}

public struct BrowserBatchResult: Codable, Equatable, Sendable {
    public var results: [BrowserBatchItemResult]
    public var totalLatencyMs: Double

    public init(
        results: [BrowserBatchItemResult],
        totalLatencyMs: Double = 0
    ) {
        self.results = results
        self.totalLatencyMs = totalLatencyMs
    }
}
