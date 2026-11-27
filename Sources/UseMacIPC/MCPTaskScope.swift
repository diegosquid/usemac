import Foundation
import UseMacProtocol

/// The tasks this MCP connection started, so its requests carry their `taskId` without the agent passing it.
///
/// One MCP server process serves one client. While exactly one task it started is open, every request without a
/// `taskId` belongs to that task. When it started several (subagents sharing the connection, or a task never
/// finished), it stamps nothing and the daemon's own rules apply, so it never ties a request to the wrong task.
final class MCPTaskScope: @unchecked Sendable {
    /// Same as the daemon's idle expiry (TaskTabRegistry.idleExpiry): a task idle this long is gone there too.
    static let idleExpiry: TimeInterval = 30 * 60

    private var openTasks: [String: Date] = [:]
    private var _clientName: String?
    private let lock = NSLock()

    /// The MCP client's name from `initialize` (`clientInfo.name`): the default agent name on its preview cards.
    var clientName: String? {
        get { lock.lock(); defer { lock.unlock() }; return _clientName }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            lock.lock(); _clientName = (trimmed?.isEmpty == false) ? trimmed : nil; lock.unlock()
        }
    }

    /// The task a request of this connection belongs to, when there is exactly one.
    func currentTaskId(now: Date = Date()) -> String? {
        lock.lock(); defer { lock.unlock() }
        openTasks = openTasks.filter { now.timeIntervalSince($0.value) < Self.idleExpiry }
        guard openTasks.count == 1, let (id, _) = openTasks.first else { return nil }
        openTasks[id] = now
        return id
    }

    /// Stamps the connection's task on a request that names none (`task_start` and piggybacked `taskStart` never:
    /// they open a new task).
    func stamp(_ request: inout RPCRequest, explicitTaskId: String?, now: Date = Date()) {
        guard request.method != .taskStart, request.taskStart == nil else { return }
        if request.taskId == nil {
            request.taskId = explicitTaskId ?? currentTaskId(now: now)
        }
        if request.taskComplete != nil, request.taskComplete?.taskId == nil {
            request.taskComplete?.taskId = request.taskId
        }
    }

    /// Tools that work in a window or tab take an optional `taskId`, for a connection that runs several tasks.
    static let taskScopedTools: Set<String> = [
        "usemac_observe", "usemac_act", "usemac_browser_open", "usemac_browser_extract",
        "usemac_screenshot", "usemac_vision", "usemac_skill", "usemac_session",
        // Legacy aliases kept for callers or tests checking them directly
        "usemac_browser_observe", "usemac_browser_screenshot", "usemac_browser_act", "usemac_vision_query"
    ]

    /// The tool with a `taskId` argument added to its schema when it is task-scoped and has none yet.
    static func withTaskIdArgument(_ tool: MCPToolDefinition) -> MCPToolDefinition {
        guard taskScopedTools.contains(tool.name),
              var schema = tool.inputSchema.objectValue,
              var properties = schema["properties"]?.objectValue,
              properties["taskId"] == nil else { return tool }
        properties["taskId"] = [
            "type": "string",
            "description": "Task id (auto-filled)."
        ]
        schema["properties"] = .object(properties)
        var copy = tool
        copy.inputSchema = .object(schema)
        return copy
    }

    /// Notes a finished request: `task_start` (or piggybacked `taskStart`) opens a task on this connection,
    /// `task_complete` (or piggybacked `taskComplete`) closes it. Reconciles returned task IDs and summaries even
    /// when a piggybacked main operation fails, because the daemon still applies the lifecycle change.
    func record(_ request: RPCRequest, response: RPCResponse, now: Date = Date()) {
        let startsTask = request.method == .taskStart || request.taskStart != nil
        let completesTask = request.method == .taskComplete || request.taskComplete != nil
        guard startsTask || completesTask else { return }

        lock.lock(); defer { lock.unlock() }
        if startsTask && !completesTask {
            if let taskId = response.taskId, (response.ok || request.taskStart != nil) {
                openTasks[taskId] = now
            }
        } else if completesTask {
            if response.ok || response.taskSummary != nil {
                if let taskId = response.taskSummary?.taskId ?? response.taskId ?? request.taskComplete?.taskId ?? request.taskId {
                    openTasks.removeValue(forKey: taskId)
                }
            }
        }
    }
}
