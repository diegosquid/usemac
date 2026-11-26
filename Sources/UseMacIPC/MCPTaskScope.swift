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
    private let lock = NSLock()

    /// The task a request of this connection belongs to, when there is exactly one.
    func currentTaskId(now: Date = Date()) -> String? {
        lock.lock(); defer { lock.unlock() }
        openTasks = openTasks.filter { now.timeIntervalSince($0.value) < Self.idleExpiry }
        guard openTasks.count == 1, let (id, _) = openTasks.first else { return nil }
        openTasks[id] = now
        return id
    }

    /// Stamps the connection's task on a request that names none (`task_start` never: it opens a new task).
    func stamp(_ request: inout RPCRequest, explicitTaskId: String?, now: Date = Date()) {
        guard request.method != .taskStart, request.taskId == nil else { return }
        request.taskId = explicitTaskId ?? currentTaskId(now: now)
    }

    /// Tools that work in a window or tab take an optional `taskId`, for a connection that runs several tasks.
    static let taskScopedTools: Set<String> = [
        "usemac_observe", "usemac_act", "usemac_screenshot",
        "usemac_browser_observe", "usemac_browser_extract", "usemac_browser_screenshot", "usemac_browser_act",
        "usemac_vision_query"
    ]

    /// The tool with a `taskId` argument added to its schema when it is task-scoped and has none yet.
    static func withTaskIdArgument(_ tool: MCPToolDefinition) -> MCPToolDefinition {
        guard taskScopedTools.contains(tool.name),
              var schema = tool.inputSchema.objectValue,
              var properties = schema["properties"]?.objectValue,
              properties["taskId"] == nil else { return tool }
        properties["taskId"] = [
            "type": "string",
            "description": "Optional taskId from usemac_task_start. Leave it out when this connection started one task: UseMac uses that task. Without tabId, browser tools go to this task's own last tab."
        ]
        schema["properties"] = .object(properties)
        var copy = tool
        copy.inputSchema = .object(schema)
        return copy
    }

    /// Notes a finished request: `task_start` opens a task on this connection, `task_complete` closes it.
    func record(_ request: RPCRequest, response: RPCResponse, now: Date = Date()) {
        guard response.ok, let taskId = response.taskId else { return }
        lock.lock(); defer { lock.unlock() }
        switch request.method {
        case .taskStart:
            openTasks[taskId] = now
        case .taskComplete:
            openTasks.removeValue(forKey: taskId)
        default:
            break
        }
    }
}
