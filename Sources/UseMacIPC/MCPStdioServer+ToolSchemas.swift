import UseMacProtocol

extension MCPStdioServer {
    // MARK: - 9 Ultra-Compact Orthogonal Tool Schemas

    private static let allStepActions: [JSONValue] = [
        "target", "openURL", "navigate", "click", "doubleClick", "rightClick", "hover",
        "setValue", "type", "pressKey", "scroll", "scrollIntoView", "scrollUntil",
        "focus", "wait", "waitFor", "axAction", "uploadFile", "assert", "fillForm", "menuAction", "drag", "saveFile"
    ]

    private static let elementMatchSchema: JSONValue = [
        "type": "object",
        "properties": [
            "role": ["type": "string"],
            "title": ["type": "string"],
            "value": ["type": "string"],
            "text": ["type": "string"],
            "exact": ["type": "boolean"],
            "index": ["type": "integer"]
        ]
    ]

    private static let observationModeSchema: JSONValue = [
        "type": "string",
        "enum": ["auto", "delta", "interactive", "full", "none"]
    ]

    private static let unifiedActionStepSchema: JSONValue = [
        "type": "object",
        "properties": [
            "action": ["type": "string", "enum": .array(allStepActions)],
            "elementId": ["type": "string"],
            "selector": ["type": "string"],
            "match": elementMatchSchema,
            "x": ["type": "number"],
            "y": ["type": "number"],
            "toElementId": ["type": "string"],
            "toSelector": ["type": "string"],
            "toMatch": elementMatchSchema,
            "toX": ["type": "number"],
            "toY": ["type": "number"],
            "overwrite": ["type": "boolean", "description": "Allow saveFile to replace an existing file (native only)."],
            "text": ["type": "string"],
            "files": ["type": "array", "items": ["type": "string"]],
            "key": ["type": "string"],
            "modifiers": ["type": "array", "items": ["type": "string"]],
            "deltaX": ["type": "number"],
            "deltaY": ["type": "number"],
            "durationMs": ["type": "integer"],
            "timeoutMs": ["type": "integer"],
            "maxScrolls": ["type": "integer"],
            "gone": ["type": "boolean"],
            "optional": ["type": "boolean"],
            "preferBackground": ["type": "boolean"],
            "restoreCursor": ["type": "boolean"],
            "actionName": ["type": "string"],
            "url": ["type": "string"],
            "newTab": ["type": "boolean"],
            "app": ["type": "string"],
            "menuPath": ["type": "array", "items": ["type": "string"]],
            "fields": ["type": "array", "items": ["type": "object"]],
            "submitMatch": ["type": "object"],
            "submitSelector": ["type": "string"],
            "expectText": ["type": "string"],
            "expectNotText": ["type": "string"],
            "expectUrl": ["type": "string"],
            "expectTitle": ["type": "string"]
        ],
        "required": ["action"]
    ]

    static let toolDefinitions: [MCPToolDefinition] = [
        MCPToolDefinition(
            name: "usemac_observe",
            description: "Inspect native window (@eN via app/window) or Chrome tab (@bN/tables/text via tabId/profile). Supports filter, returnImageContent, inline task.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "app": ["type": "string"],
                    "window": ["type": "string"],
                    "tabId": ["type": "integer"],
                    "profile": ["type": "string"],
                    "filter": ["type": "object", "description": "{role,text,selector,viewportOnly}"],
                    "includeOffscreen": ["type": "boolean"],
                    "maxDepth": ["type": "integer"],
                    "maxElements": ["type": "integer"],
                    "useCache": ["type": "boolean"],
                    "includeDiff": ["type": "boolean"],
                    "includeText": ["type": "boolean"],
                    "includeTables": ["type": "boolean"],
                    "includeScreenshot": ["type": "boolean"],
                    "returnImageContent": ["type": "boolean"],
                    "task": ["type": "string"]
                ]
            ],
            annotations: MCPToolAnnotations(
                title: "Observe",
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: true
            )
        ),
        MCPToolDefinition(
            name: "usemac_act",
            description: "Run batched UI actions on native app (app/window) or Chrome tab (tabId/profile). Supports drag, native saveFile, match, optional, assert, scrollUntil, fillForm, menuAction, verify, diffCrop, inline task/completeTask.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "app": ["type": "string"],
                    "window": ["type": "string"],
                    "tabId": ["type": "integer"],
                    "profile": ["type": "string"],
                    "steps": ["type": "array", "items": unifiedActionStepSchema],
                    "verify": ["type": "string"],
                    "observationMode": observationModeSchema,
                    "returnObservation": ["type": "boolean"],
                    "returnDiffOnly": ["type": "boolean"],
                    "maxElements": ["type": "integer"],
                    "diffCrop": ["type": "boolean"],
                    "includeScreenshot": ["type": "boolean"],
                    "returnImageContent": ["type": "boolean"],
                    "stopOnError": ["type": "boolean"],
                    "foreground": ["type": "boolean"],
                    "foregroundFallback": ["type": "boolean"],
                    "expectWindowTitle": ["type": "string"],
                    "allowStaleSnapshot": ["type": "boolean"],
                    "readOnly": ["type": "boolean"],
                    "waitForLeaseMs": ["type": "integer"],
                    "dialogAction": ["type": "string", "enum": ["accept", "dismiss"], "description": "Chrome JS dialog action. By default, dismisses confirm and prompt; accepts alert and beforeunload."],
                    "dialogPromptText": ["type": "string", "description": "Text to send when accepting a Chrome JS prompt."],
                    "task": ["type": "string"],
                    "completeTask": ["type": "string"]
                ],
                "required": ["steps"]
            ],
            annotations: MCPToolAnnotations(
                title: "Act",
                readOnlyHint: false,
                destructiveHint: true,
                idempotentHint: false,
                openWorldHint: true
            )
        ),
        MCPToolDefinition(
            name: "usemac_browser_open",
            description: "Open URL in background Chrome tab, navigate/activate tabId (url optional with activate), or open unfocused newWindow. Supports inline post-load steps, autoDismissOverlays, task.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "url": ["type": "string"],
                    "tabId": ["type": "integer"],
                    "profile": ["type": "string"],
                    "newTab": ["type": "boolean"],
                    "activate": ["type": "boolean"],
                    "newWindow": ["type": "boolean"],
                    "stream": ["type": "boolean"],
                    "steps": ["type": "array", "items": ["type": "object"], "description": "Same steps as usemac_act for Chrome, including drag."],
                    "autoDismissOverlays": ["type": "boolean"],
                    "observationMode": observationModeSchema,
                    "returnDiffOnly": ["type": "boolean"],
                    "waitForLeaseMs": ["type": "integer"],
                    "dialogAction": ["type": "string", "enum": ["accept", "dismiss"], "description": "JS dialog action during navigation and steps. By default, dismisses confirm and prompt; accepts alert and beforeunload."],
                    "dialogPromptText": ["type": "string", "description": "Text to send when accepting a JS prompt."],
                    "task": ["type": "string"]
                ]
            ],
            annotations: MCPToolAnnotations(
                title: "Open URL",
                readOnlyHint: false,
                destructiveHint: false,
                idempotentHint: false,
                openWorldHint: true
            )
        ),
        MCPToolDefinition(
            name: "usemac_browser_extract",
            description: "Extract Chrome tables, KPIs, text, network JSON (urlFilter), or JS eval (expression); or pass urls for a parallel multi-tab batch. Downloads mode lists downloads per Chrome profile; do not pass urls.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "mode": ["type": "string", "enum": ["auto", "tables", "text", "kpis", "network", "downloads", "eval", "observe"]],
                    "tabId": ["type": "integer"],
                    "profile": ["type": "string"],
                    "selector": ["type": "string"],
                    "expression": ["type": "string"],
                    "urlFilter": ["type": "string"],
                    "scanHorizontal": ["type": "boolean"],
                    "scanVertical": ["type": "boolean"],
                    "frameIndex": ["type": "integer"],
                    "maxChars": ["type": "integer"],
                    "urls": ["type": "array", "items": ["type": "string"]],
                    "autoDismissOverlays": ["type": "boolean"],
                    "closeAfter": ["type": "boolean"],
                    "maxElements": ["type": "integer"]
                ]
            ],
            annotations: MCPToolAnnotations(
                title: "Extract",
                readOnlyHint: false,
                destructiveHint: false,
                idempotentHint: false,
                openWorldHint: true
            )
        ),
        MCPToolDefinition(
            name: "usemac_screenshot",
            description: "Capture JPEG of native window (app) or Chrome tab/element (tabId/profile/elementId/selector/fullPage). Inline image default true; supports diffCrop & region {x,y,width,height}.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "app": ["type": "string"],
                    "tabId": ["type": "integer"],
                    "profile": ["type": "string"],
                    "maxDimension": ["type": "integer"],
                    "diffCrop": ["type": "boolean"],
                    "region": ["type": "object"],
                    "elementId": ["type": "string"],
                    "selector": ["type": "string"],
                    "fullPage": ["type": "boolean"],
                    "returnImageContent": ["type": "boolean"]
                ]
            ],
            annotations: MCPToolAnnotations(
                title: "Screenshot",
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: true
            )
        ),
        MCPToolDefinition(
            name: "usemac_discover",
            description: "Read-only discovery: running apps, Chrome tabs (profile/query), native menu items (app/query), or daemon/Chrome status.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "kind": ["type": "string", "enum": ["apps", "tabs", "menu", "status"]],
                    "app": ["type": "string"],
                    "profile": ["type": "string"],
                    "query": ["type": "string"]
                ],
                "required": ["kind"]
            ],
            annotations: MCPToolAnnotations(
                title: "Discover",
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: true
            )
        ),
        MCPToolDefinition(
            name: "usemac_vision",
            description: "Instant on-device Apple Vision OCR (0 cloud image tokens): ocr, verify assertion, locate text (x,y), or diagnose popups.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "mode": ["type": "string", "enum": ["ocr", "verify", "locate", "diagnose"]],
                    "query": ["type": "string"],
                    "app": ["type": "string"],
                    "tabId": ["type": "integer"],
                    "profile": ["type": "string"],
                    "imagePath": ["type": "string"],
                    "selector": ["type": "string"],
                    "elementId": ["type": "string"]
                ]
            ],
            annotations: MCPToolAnnotations(
                title: "Vision OCR",
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
        ),
        MCPToolDefinition(
            name: "usemac_skill",
            description: "List, save (steps + optional postAssertions), or deterministically replay parameterized ({{param}}) automation skills.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "action": ["type": "string", "enum": ["list", "save", "run"]],
                    "name": ["type": "string"],
                    "description": ["type": "string"],
                    "kind": ["type": "string", "enum": ["browser", "native"]],
                    "app": ["type": "string"],
                    "urlPattern": ["type": "string"],
                    "profile": ["type": "string"],
                    "tabId": ["type": "integer"],
                    "query": ["type": "string"],
                    "params": ["type": "object"],
                    "steps": ["type": "array", "items": ["type": "object"]],
                    "waitForLeaseMs": ["type": "integer"],
                    "postAssertions": ["type": "array", "items": ["type": "object"]],
                    "delete": ["type": "boolean"]
                ],
                "required": ["action"]
            ],
            annotations: MCPToolAnnotations(
                title: "Skills",
                readOnlyHint: false,
                destructiveHint: true,
                idempotentHint: false,
                openWorldHint: true
            )
        ),
        MCPToolDefinition(
            name: "usemac_session",
            description: "Session & utility ops: status, task_start, task_complete (keepTabs/keepTabIds), highlight @eN, or report_prepare (bug report reviewed by user in UseMac).",
            inputSchema: [
                "type": "object",
                "properties": [
                    "action": ["type": "string", "enum": ["status", "task_start", "task_complete", "highlight", "report_prepare"]],
                    "summary": ["type": "string"],
                    "agent": ["type": "string"],
                    "keepTabs": ["type": "boolean"],
                    "keepTabIds": ["type": "array", "items": ["type": "integer"]],
                    "elementId": ["type": "string"],
                    "durationMs": ["type": "integer"],
                    "title": ["type": "string"],
                    "app": ["type": "string"],
                    "profile": ["type": "string"],
                    "tabId": ["type": "integer"]
                ],
                "required": ["action"]
            ],
            annotations: MCPToolAnnotations(
                title: "Session",
                readOnlyHint: false,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
        )
    ]
}
