import Foundation
import UseMacProtocol

extension MCPStdioServer {
    // MARK: - Formatting

    func formatSuccessBlocks(
        request: RPCRequest,
        response: RPCResponse,
        returnImageContent: Bool
    ) -> [MCPContentBlock] {
        var blocks = formatMethodBlocks(request: request, response: response, returnImageContent: returnImageContent)
        if request.method != .taskStart, request.taskStart != nil, let taskId = response.taskId {
            blocks = appendingFooterLine("taskId: \(taskId)", to: blocks)
        }
        if request.method != .taskComplete, request.taskComplete != nil, let done = response.taskSummary {
            blocks = appendingFooterLine(formatTaskSummaryLines(done), to: blocks)
        }
        return blocks
    }

    private func appendingFooterLine(_ footer: String, to blocks: [MCPContentBlock]) -> [MCPContentBlock] {
        guard !footer.isEmpty else { return blocks }
        var copy = blocks
        if case let .text(existing)? = copy.first {
            copy[0] = .text(existing + "\n" + footer)
        } else {
            copy.insert(.text(footer), at: 0)
        }
        return copy
    }

    private func formatMethodBlocks(
        request: RPCRequest,
        response: RPCResponse,
        returnImageContent: Bool
    ) -> [MCPContentBlock] {
        switch request.method {
        case .status:
            if let status = response.status {
                var text = formatStatus(status)
                if status.browserProfiles.isEmpty, let profiles = response.browserProfiles, !profiles.isEmpty {
                    text += "\n" + formatBrowserProfiles(profiles)
                }
                return [.text(text)]
            }
            if let profiles = response.browserProfiles {
                return [.text(formatBrowserProfiles(profiles))]
            }
            return [.text("Status unavailable")]

        case .listApps:
            let apps = response.apps ?? []
            if apps.isEmpty {
                return [.text("No running GUI applications found.")]
            }
            return [.text(apps.map(formatAppDescriptor).joined(separator: "\n"))]

        case .observe:
            guard let snapshot = response.snapshot else {
                return [.text("Observation unavailable")]
            }
            let maxEls = request.observe?.maxElements ?? 250
            let diffOnly = snapshot.elements.isEmpty && snapshot.diff != nil
            var blocks: [MCPContentBlock] = [
                .text(snapshot.formattedCompactSummary(maxElements: maxEls, returnDiffOnly: diffOnly))
            ]
            if returnImageContent,
               let imageBlock = inlineImageBlock(screenshot: response.screenshot, snapshotPath: snapshot.screenshotPath) {
                blocks.append(imageBlock)
            }
            return blocks

        case .act:
            guard let actionResult = response.actionResult else {
                return [.text("Action result unavailable")]
            }
            let diffOnly = (request.act?.returnDiffOnly ?? false) || request.act?.observationMode == .delta
            let maxEls = request.act?.maxElements ?? 250
            var text = formatBatchActionResult(actionResult, maxElements: maxEls, returnDiffOnly: diffOnly)
            let shot = response.screenshot ?? actionResult.screenshot
            if let shot, actionResult.observation?.screenshotPath != shot.path {
                text += "\n" + String(format: "Screenshot: %@ (%dx%d, %d bytes)", shot.path, shot.width, shot.height, shot.byteCount)
            }
            var blocks: [MCPContentBlock] = [.text(text)]
            if returnImageContent,
               let imageBlock = inlineImageBlock(
                screenshot: shot,
                snapshotPath: actionResult.observation?.screenshotPath ?? response.snapshot?.screenshotPath
               ) {
                blocks.append(imageBlock)
            }
            return blocks

        case .browserTabs:
            let tabs = response.browserTabs ?? []
            if tabs.isEmpty {
                return [.text("No matching Chrome tabs found.")]
            }
            var lines: [String] = ["Chrome Tabs (\(tabs.count)):"]
            for tab in tabs {
                let activeTag = tab.active ? " [ACTIVE]" : ""
                let pinnedTag = tab.pinned == true ? " [pinned]" : ""
                lines.append("  - tabId=\(tab.tabId)\(activeTag)\(pinnedTag) | \"\(tab.title)\" | \(tab.url)")
            }
            return [.text(lines.joined(separator: "\n"))]

        case .browserOpen:
            var lines: [String] = []
            let openParams = request.browserOpen
            let prefix: String
            if openParams?.url.isEmpty == true {
                prefix = "Activated browser tab"
            } else if openParams?.newWindow == true {
                prefix = "Opened browser tab in a new window"
            } else {
                prefix = "Opened browser tab"
            }
            lines.append(formatBrowserTabHeader(
                prefix: prefix,
                tabId: response.browserTabId,
                url: response.browserUrl ?? openParams?.url,
                title: response.browserTitle,
                latencyMs: response.serverLatencyMs
            ))
            let diffOnly = (openParams?.returnDiffOnly ?? false) || openParams?.observationMode == .delta
            if let actionResult = response.actionResult {
                lines.append("")
                lines.append(formatBatchActionResult(actionResult, maxElements: 250, returnDiffOnly: diffOnly))
            } else if let snapshot = response.snapshot {
                lines.append("")
                let effectiveDiffOnly = diffOnly || (snapshot.elements.isEmpty && snapshot.diff != nil)
                lines.append(snapshot.formattedCompactSummary(maxElements: 250, returnDiffOnly: effectiveDiffOnly))
            }
            return [.text(lines.joined(separator: "\n"))]

        case .browserObserve:
            var lines: [String] = []
            if response.browserTabId != nil || response.browserUrl != nil || response.browserTitle != nil {
                lines.append(formatBrowserTabHeader(
                    prefix: "Browser tab",
                    tabId: response.browserTabId,
                    url: response.browserUrl,
                    title: response.browserTitle,
                    latencyMs: response.serverLatencyMs
                ))
            }
            if let snapshot = response.snapshot {
                let maxEls = request.browserObserve?.maxElements ?? 250
                let diffOnly = snapshot.elements.isEmpty && snapshot.diff != nil
                lines.append(snapshot.formattedCompactSummary(maxElements: maxEls, returnDiffOnly: diffOnly))
            } else {
                lines.append("Browser observation unavailable")
            }
            var blocks: [MCPContentBlock] = [.text(lines.joined(separator: "\n"))]
            if returnImageContent,
               let imageBlock = inlineImageBlock(screenshot: response.screenshot, snapshotPath: response.snapshot?.screenshotPath) {
                blocks.append(imageBlock)
            }
            return blocks

        case .browserExtract:
            guard let ext = response.browserExtract else {
                return [.text("Browser extract result unavailable")]
            }
            return [.text(formatBrowserExtract(ext, fallbackTabId: response.browserTabId, fallbackUrl: response.browserUrl))]

        case .browserBatch:
            guard let batch = response.browserBatchResult else {
                return [.text("Browser batch result unavailable")]
            }
            return [.text(formatBrowserBatch(batch, maxElements: request.browserBatch?.maxElements ?? 250))]

        case .browserScreenshot:
            guard let shot = response.screenshot else {
                return [.text("Browser screenshot unavailable")]
            }
            var header = formatBrowserTabHeader(
                prefix: "Browser screenshot",
                tabId: response.browserTabId,
                url: response.browserUrl,
                title: response.browserTitle,
                latencyMs: shot.latencyMs
            )
            header += String(format: "\nPath: %@ (%dx%d, %d bytes, %@)", shot.path, shot.width, shot.height, shot.byteCount, shot.mimeType)
            if shot.truncated == true {
                let params = request.browserScreenshot
                header += "\n" + ScreenshotResult.truncatedNote(element: params?.elementId != nil || params?.selector != nil)
            }
            var blocks: [MCPContentBlock] = [.text(header)]
            if returnImageContent,
               let imageBlock = inlineImageBlock(screenshot: shot, snapshotPath: nil) {
                blocks.append(imageBlock)
            }
            return blocks

        case .browserAct:
            var lines: [String] = []
            if response.browserTabId != nil || response.browserUrl != nil || response.browserTitle != nil {
                lines.append(formatBrowserTabHeader(
                    prefix: "Browser tab",
                    tabId: response.browserTabId,
                    url: response.browserUrl,
                    title: response.browserTitle,
                    latencyMs: nil
                ))
            }
            let diffOnly = (request.browserAct?.returnDiffOnly ?? false) || request.browserAct?.observationMode == .delta
            let maxEls = request.browserAct?.maxElements ?? 250
            if let actionResult = response.actionResult {
                lines.append(formatBatchActionResult(actionResult, maxElements: maxEls, returnDiffOnly: diffOnly))
            } else if let snapshot = response.snapshot {
                let effectiveDiffOnly = diffOnly || (snapshot.elements.isEmpty && snapshot.diff != nil)
                lines.append(snapshot.formattedCompactSummary(maxElements: maxEls, returnDiffOnly: effectiveDiffOnly))
            } else {
                lines.append("Browser action result unavailable")
            }
            let shot = response.screenshot ?? response.actionResult?.screenshot
            if let shot {
                lines.append(String(format: "Screenshot: %@ (%dx%d, %d bytes)", shot.path, shot.width, shot.height, shot.byteCount))
            }
            var blocks: [MCPContentBlock] = [.text(lines.joined(separator: "\n"))]
            if returnImageContent,
               let imageBlock = inlineImageBlock(
                screenshot: shot,
                snapshotPath: response.actionResult?.observation?.screenshotPath ?? response.snapshot?.screenshotPath
               ) {
                blocks.append(imageBlock)
            }
            return blocks

        case .screenshot:
            guard let shot = response.screenshot else {
                return [.text("Screenshot unavailable")]
            }
            var blocks: [MCPContentBlock] = [
                .text(
                    String(
                        format: "Screenshot: %@ (%dx%d, %d bytes, %.2f ms, %@)",
                        shot.path,
                        shot.width,
                        shot.height,
                        shot.byteCount,
                        shot.latencyMs,
                        shot.mimeType
                    )
                )
            ]
            if returnImageContent,
               let imageBlock = inlineImageBlock(screenshot: shot, snapshotPath: nil) {
                blocks.append(imageBlock)
            }
            return blocks

        case .highlight:
            let elementId = request.elementId ?? "unknown"
            let durationPart = request.durationMs.map { " for \($0) ms" } ?? ""
            return [
                .text(
                    String(
                        format: "Highlighted %@%@ (%.2f ms)",
                        elementId,
                        durationPart,
                        response.serverLatencyMs
                    )
                )
            ]

        case .appMenu:
            guard let menu = response.appMenuResult else {
                return [.text("Menu result unavailable")]
            }
            return [.text(formatAppMenu(menu))]

        case .skillSave, .skillList:
            if let skillsRes = response.skills {
                return [.text(formatSkillList(skillsRes, deletedName: request.skillSave?.delete == true ? request.skillSave?.name : nil))]
            }
            if let sr = response.skillResult {
                return [.text(formatSkillRun(sr, returnDiffOnly: false))]
            }
            if request.skillSave?.delete == true, let name = request.skillSave?.name {
                return [.text("Deleted skill '\(name)'.")]
            }
            return [.text("Skill result unavailable")]

        case .skillRun:
            guard let sr = response.skillResult else {
                return [.text("Skill run result unavailable")]
            }
            let diffOnly = (request.skillRun?.returnDiffOnly ?? false) || request.skillRun?.observationMode == .delta
            return [.text(formatSkillRun(sr, returnDiffOnly: diffOnly))]

        case .visionStatus:
            if let v = response.visionStatus {
                let text = "Local Vision: state=\(v.state) | enabled=\(v.enabled) | backend=\(v.backend) | ocr=\(v.ocrAvailable)"
                return [.text(text)]
            }
            return [.text("Vision status unavailable")]

        case .visionQuery:
            guard let vr = response.visionResult else {
                return [.text("Vision result unavailable")]
            }
            var lines: [String] = [
                String(format: "Vision %@ [%@] (%.1f ms)", vr.mode, vr.backend, vr.latencyMs),
                "Answer: \(vr.answer)"
            ]
            if let verified = vr.verified {
                lines.append("Verified: \(verified ? "true" : "false")")
            }
            if let x = vr.x, let y = vr.y {
                lines.append(String(format: "Point: (%.1f, %.1f)", x, y))
            }
            if vr.blockingDetected {
                lines.append("BlockingOverlayDetected: true")
            }
            if let path = vr.imagePath {
                lines.append("Image: \(path)")
            }
            for det in vr.detections.prefix(20) {
                lines.append(String(format: "  - \"%@\" at (%.1f, %.1f) [%@]", det.label, det.x, det.y, det.source))
            }
            return [.text(lines.joined(separator: "\n"))]

        case .taskStart:
            let summary = request.taskStart?.summary ?? "Task started"
            var text = "Started continuous preview session: \(summary)"
            if let taskId = response.taskId {
                text += "\ntaskId: \(taskId) (later calls on this connection belong to it automatically)."
            }
            return [.text(text)]

        case .taskComplete:
            let summary = request.taskComplete?.summary ?? "Task completed"
            let taskTag = response.taskId.map { " (task \($0))" } ?? ""
            var text = "Marked task complete\(taskTag): \(summary)"
            if let done = response.taskSummary {
                text += "\n" + formatTaskSummaryLines(done)
            }
            return [.text(text)]

        case .reportPrepare:
            guard let receipt = response.problemReport else {
                return [.text("Report status unavailable")]
            }
            let scope = receipt.taskId.map { "task \($0)" } ?? "recent activity"
            let codes = receipt.errorCodes.isEmpty ? "no error codes" : receipt.errorCodes.joined(separator: ", ")
            return [.text("Report \(receipt.status) (\(scope), \(receipt.entryCount) audit entries, \(codes)).\n\(receipt.message)")]

        default:
            return [.text("OK")]
        }
    }

    private func formatTaskSummaryLines(_ done: TaskSummary) -> String {
        let tabs = { (ids: [Int]) in ids.isEmpty ? "none" : ids.map(String.init).joined(separator: ", ") }
        return "Summary: \(done.requests) requests, \(done.actions) actions (\(done.failedActions) failed), \(done.blocked) blocked, "
            + String(format: "%.1f s", Double(done.durationMs) / 1000)
            + "\nTabs opened: \(tabs(done.tabsOpened)); closed during the task: \(tabs(done.tabsClosed)); closing now: \(tabs(done.tabsClosing))"
    }

    private func formatBrowserExtract(_ ext: BrowserExtractResult, fallbackTabId: Int?, fallbackUrl: String?) -> String {
        let isDownloads = ext.mode.lowercased() == "downloads"
        var lines: [String] = []
        var meta: [String] = ["Browser extract [\(ext.mode)]"]
        if !isDownloads, let tabId = ext.tabId ?? fallbackTabId { meta.append("tabId=\(tabId)") }
        if let rows = ext.rowCount, let cols = ext.columnCount, rows > 0 {
            meta.append("\(rows) rows × \(cols) cols")
        }
        if let steps = ext.scannedHorizontalSteps, steps > 1 {
            meta.append("horizontalScan=\(steps) slices")
        }
        meta.append(String(format: "(%.1f ms)", ext.latencyMs))
        lines.append(meta.joined(separator: " | "))
        if !isDownloads, let url = ext.url ?? fallbackUrl, !url.isEmpty {
            lines.append("URL: \(url)")
        }
        if let tables = ext.tablesMarkdown, !tables.isEmpty {
            lines.append("")
            lines.append("--- TABLES / DATA GRIDS ---")
            lines.append(tables)
        }
        if let json = ext.jsonResult, !json.isEmpty {
            lines.append("")
            lines.append(ext.mode == "network" ? "--- NETWORK RESULT ---" : "--- EVAL RESULT ---")
            lines.append(json)
        }
        if let text = ext.text, !text.isEmpty {
            lines.append("")
            lines.append("--- EXTRACTED TEXT ---")
            lines.append(text)
        }
        if let downloads = ext.downloads {
            lines.append("")
            if downloads.isEmpty {
                lines.append("No recent Chrome downloads.")
            } else {
                lines.append("--- RECENT DOWNLOADS (\(downloads.count)) ---")
                for dl in downloads {
                    lines.append("  - \(dl.formattedStatus)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    private func formatBrowserBatch(_ batch: BrowserBatchResult, maxElements: Int) -> String {
        var lines: [String] = [
            String(format: "Browser batch (%d URLs, %.1f ms):", batch.results.count, batch.totalLatencyMs)
        ]
        for (idx, item) in batch.results.enumerated() {
            let tabPart = item.tabId.map { " | tabId=\($0)" } ?? ""
            let status = item.success ? "OK" : "FAIL"
            var header = String(format: "[%d] %@ | %@%@ (%.1f ms)", idx, status, item.url, tabPart, item.latencyMs)
            if let err = item.error, !err.isEmpty {
                header += " — \(err)"
            }
            lines.append(header)
            if let ext = item.extract {
                lines.append(formatBrowserExtract(ext, fallbackTabId: item.tabId, fallbackUrl: item.url))
            }
            if let snap = item.snapshot {
                lines.append(snap.formattedCompactSummary(maxElements: maxElements, returnDiffOnly: snap.elements.isEmpty && snap.diff != nil))
            }
        }
        return lines.joined(separator: "\n")
    }

    private func formatAppMenu(_ menu: AppMenuResult) -> String {
        if let invoked = menu.invokedPath, !invoked.isEmpty {
            let msg = menu.message.map { " — \($0)" } ?? ""
            return "Menu [\(menu.app)]: invoked \(invoked.joined(separator: " → "))\(msg)"
        }
        guard let items = menu.items else {
            return menu.message ?? "Menu [\(menu.app)]: no items."
        }
        if items.isEmpty {
            return "Menu [\(menu.app)]: no matching items."
        }
        var lines: [String] = ["Menu [\(menu.app)] (\(items.count) items):"]
        for item in items {
            let shortcut = item.shortcut.flatMap { $0.isEmpty ? nil : " (\($0))" } ?? ""
            let disabled = item.enabled ? "" : " [disabled]"
            lines.append("  - \(item.path.joined(separator: " → "))\(shortcut)\(disabled)")
        }
        return lines.joined(separator: "\n")
    }

    private func formatSkillList(_ result: SkillListResult, deletedName: String?) -> String {
        if let saved = result.saved {
            let target = saved.target.map { " [\($0)]" } ?? ""
            let params = (saved.params?.isEmpty == false) ? " params=\(saved.params!.joined(separator: ","))" : ""
            return "Saved skill '\(saved.name)'\(target) (\(saved.steps.count) steps\(params))."
        }
        if let deletedName {
            return "Deleted skill '\(deletedName)'."
        }
        if result.skills.isEmpty {
            return "No saved skills found."
        }
        var lines: [String] = ["Skills (\(result.skills.count)):"]
        for skill in result.skills {
            let target = skill.target ?? "auto"
            let scope = [skill.app, skill.urlPattern].compactMap { $0 }.joined(separator: " / ")
            let scopePart = scope.isEmpty ? "" : " (\(scope))"
            let paramsPart = (skill.params?.isEmpty == false) ? " params=[\(skill.params!.joined(separator: ","))]" : ""
            let descPart = skill.description.flatMap { $0.isEmpty ? nil : " — \($0)" } ?? ""
            lines.append("  - \(skill.name) [\(target)]\(scopePart) | \(skill.steps.count) steps | runs=\(skill.runCount)\(paramsPart)\(descPart)")
        }
        return lines.joined(separator: "\n")
    }

    private func formatSkillRun(_ sr: SkillRunResult, returnDiffOnly: Bool) -> String {
        var lines: [String] = [
            String(
                format: "Skill '%@' %@ (%.1f ms)%@",
                sr.name,
                sr.success ? "succeeded" : "failed",
                sr.totalLatencyMs,
                sr.message.flatMap { $0.isEmpty ? nil : " — \($0)" } ?? ""
            )
        ]
        if let actionResult = sr.actionResult {
            lines.append(formatBatchActionResult(actionResult, maxElements: 250, returnDiffOnly: returnDiffOnly))
        }
        return lines.joined(separator: "\n")
    }

    private func formatStatus(_ status: DaemonStatus) -> String {
        var lines: [String] = [
            "UseMac daemon v\(status.version) (pid \(status.pid))",
            "Socket: \(status.socketPath)",
            "Policy: \(status.policy.rawValue) | KillSwitch: \(status.killSwitchTripped)",
            "Permissions: accessibility=\(status.permissions.accessibilityGranted), screenRecording=\(status.permissions.screenRecordingGranted)"
        ]
        if let paired = status.pairedApp {
            lines.append("Paired App: \(paired.name) (pid \(paired.pid))")
        }
        if let frontmost = status.frontmostApp {
            lines.append("Frontmost App: \(frontmost.name) (pid \(frontmost.pid))")
        }
        let tel = status.telemetry
        lines.append(
            String(
                format: "Telemetry: uptime=%.1fs requests=%d actions=%d avgObserve=%.2fms lastObserve=%.2fms cacheHits=%d activeClients=%d",
                tel.uptimeSeconds,
                tel.totalRequests,
                tel.totalActions,
                tel.avgObserveLatencyMs,
                tel.lastObserveLatencyMs,
                tel.hotCacheHits,
                tel.activeClients
            )
        )
        if !status.browserProfiles.isEmpty {
            lines.append(formatBrowserProfiles(status.browserProfiles))
        }
        return lines.joined(separator: "\n")
    }

    private func formatBrowserProfiles(_ profiles: [BrowserProfileStatus]) -> String {
        if profiles.isEmpty {
            return "Browser Profiles: none connected"
        }
        var lines: [String] = ["Browser Profiles (\(profiles.count)):"]
        for profile in profiles {
            let emailPart = profile.profileEmail.map { " <\($0)>" } ?? ""
            let streamPart = profile.streamingTabId.map { tabId in
                let urlPart = profile.streamingUrl.map { " (\($0))" } ?? ""
                return ", streaming tab=\(tabId)\(urlPart)"
            } ?? ""
            let outdatedPart = profile.extensionOutdated == true
                ? ", outdated: app ships \(profile.bundledExtensionVersion ?? "a newer version")"
                : ""
            let sourcePart = profile.extensionSource.map { ", source=\($0)" } ?? ""
            lines.append("  - \(profile.profileName)\(emailPart) [v\(profile.extensionVersion), tabs=\(profile.tabCount)\(streamPart)\(outdatedPart)\(sourcePart)]")
            if let note = profile.extensionNote {
                lines.append("    \(note) Tell the user; reloading the extension stops every agent's browser work.")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func formatBrowserTabHeader(
        prefix: String,
        tabId: Int?,
        url: String?,
        title: String?,
        latencyMs: Double?
    ) -> String {
        var parts: [String] = [prefix]
        if let tabId {
            parts.append("tabId=\(tabId)")
        }
        if let title, !title.isEmpty {
            parts.append("\"\(title)\"")
        }
        if let url, !url.isEmpty {
            parts.append(url)
        }
        if let latencyMs {
            parts.append(String(format: "(%.2f ms)", latencyMs))
        }
        return parts.joined(separator: " | ")
    }

    private func formatAppDescriptor(_ app: AppDescriptor) -> String {
        var parts: [String] = ["pid \(app.pid) | \(app.name)"]
        if let bundleId = app.bundleId, !bundleId.isEmpty {
            parts.append("(\(bundleId))")
        }
        if app.isActive {
            parts.append("[active]")
        }
        if app.isHidden {
            parts.append("[hidden]")
        }
        if let title = app.windowTitle, !title.isEmpty {
            parts.append("— \"\(title)\"")
        }
        return parts.joined(separator: " ")
    }

    private func formatBatchActionResult(
        _ result: BatchActionResult,
        maxElements: Int,
        returnDiffOnly: Bool
    ) -> String {
        var lines: [String] = [
            String(
                format: "Batch %@ (%.2f ms, %d steps)",
                result.success ? "succeeded" : "failed",
                result.totalLatencyMs,
                result.stepResults.count
            )
        ]

        var firstFailureCode: String?
        for step in result.stepResults {
            var statusTag = step.skipped == true ? "SKIPPED" : (step.success ? "OK" : "FAIL")
            if let code = step.errorCode, !code.isEmpty {
                statusTag += " [\(code)]"
                if !step.success, step.skipped != true, firstFailureCode == nil {
                    firstFailureCode = code
                }
            }
            var extras: [String] = []
            if let resolved = step.resolvedElementId, !resolved.isEmpty {
                extras.append("target=\(resolved)")
            }
            if let effect = step.effect, effect != .none {
                extras.append("effect=\(effect.rawValue)")
            }
            if let dx = step.scrollDeltaX, dx != 0 {
                extras.append(String(format: "scrollDeltaX=%.0fpx", dx))
            }
            if let d = step.scrollDeltaY {
                extras.append(String(format: "scrollDeltaY=%.0fpx", d))
            }
            if let v = step.visualChangePercent {
                extras.append(String(format: "visualDiff=%.2f%%", v))
            }
            if let dl = step.downloadPath, !dl.isEmpty {
                extras.append("downloadPath=\(dl)")
            }
            if let w = step.blockedWarning, !w.isEmpty {
                extras.append("WARNING: \(w)")
            } else if let m = step.message, !m.isEmpty {
                extras.append(m)
            }
            let msgPart = extras.isEmpty ? "" : " — " + extras.joined(separator: " | ")
            lines.append(
                String(
                    format: "  [%d] %@ -> %@ (%@, %.2f ms)%@",
                    step.index,
                    step.action.rawValue,
                    statusTag,
                    step.mechanism,
                    step.latencyMs,
                    msgPart
                )
            )
            let warning = step.warning.flatMap { $0.isEmpty ? nil : $0 }
            if step.effect == ActionEffect.none {
                lines.append("      WARNING: no visible effect (effect=none)\(warning.map { ": \($0)" } ?? ""). Observe before continuing; do not assume the step worked.")
            } else if let warning {
                lines.append("      WARNING: \(warning)")
            }
        }

        if let code = firstFailureCode, let hint = UseMacErrorGuide.hint(for: code) {
            lines.append("Next: \(hint)")
        }

        if let dialogs = result.dialogs, !dialogs.isEmpty {
            lines.append("Dialogs (\(dialogs.count)):")
            for dialog in dialogs {
                lines.append("  [\(dialog.type)] \(dialog.message.debugDescription) -> \(dialog.accepted ? "accepted" : "dismissed")")
            }
        }

        if let netErrors = result.networkErrors, !netErrors.isEmpty {
            lines.append("NetworkErrors (\(netErrors.count)):")
            for err in netErrors.prefix(10) {
                lines.append("  ! \(err)")
            }
        }

        if let rect = result.dirtyRect {
            lines.append(String(format: "DirtyRect: (%.0f,%.0f %.0fx%.0f)", rect.x, rect.y, rect.width, rect.height))
        }

        if let deltaOCR = result.visualDeltaOCR, !deltaOCR.isEmpty {
            lines.append("VisualDeltaOCR: \(deltaOCR)")
        }

        if let verification = result.visualVerification {
            lines.append("")
            let badge = verification.verified == true ? "PASS" : (verification.verified == false ? "FAIL" : "INFO")
            lines.append(
                String(
                    format: "Local Visual Verification [%@ via %@, %.0f ms]: %@",
                    badge,
                    verification.backend,
                    verification.latencyMs,
                    verification.answer
                )
            )
        }

        if let feedback = result.agentFeedback {
            lines.append("")
            lines.append(feedback.formattedBanner)
        }

        if let observation = result.observation {
            lines.append("")
            let effectiveDiffOnly = returnDiffOnly || (observation.elements.isEmpty && observation.diff != nil)
            lines.append(observation.formattedCompactSummary(maxElements: maxElements, returnDiffOnly: effectiveDiffOnly))
        }

        return lines.joined(separator: "\n")
    }
}
