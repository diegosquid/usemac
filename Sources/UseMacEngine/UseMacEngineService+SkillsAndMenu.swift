import Foundation
import UseMacProtocol

extension UseMacEngineService {
    func handleAppMenu(_ request: RPCRequest, startNs: UInt64) async -> RPCResponse {
        let params = request.appMenu ?? AppMenuParams()
        let cleanedPath = (params.menuPath ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let isInvoke = !cleanedPath.isEmpty

        if let blockReason = killSwitch.isBlocked(forSensitiveAction: false, isMutatingAction: isInvoke) {
            return blockedPolicyResponse(
                request: request,
                startNs: startNs,
                targetApp: params.app,
                activityTitle: isInvoke ? "App menu invoke blocked" : "App menu search blocked",
                reason: blockReason
            )
        }

        let target = workspaceMonitor.resolveTarget(query: params.app)
        if target == .useMac {
            return selfTargetResponse(request: request, startNs: startNs, targetApp: params.app, activityTitle: "App menu blocked")
        }
        if case .app(let app) = target, let blocked = TargetRulesStore.shared.blockedMessage(for: app) {
            return targetBlockedResponse(request: request, startNs: startNs, targetApp: app.name, activityTitle: "App menu blocked", message: blocked)
        }
        guard case .app(let resolvedApp) = target else {
            let latencyMs = elapsedMs(since: startNs)
            appendAudit(method: request.method.rawValue, targetApp: params.app, summary: "App not found", latencyMs: latencyMs, success: false)
            return .failure(id: request.id, code: "APP_NOT_FOUND", message: "No matching target application found", latencyMs: latencyMs)
        }
        if isInvoke, let readOnly = TargetRulesStore.shared.readOnlyMessage(for: resolvedApp) {
            return targetReadOnlyResponse(request: request, startNs: startNs, targetApp: resolvedApp.name, activityTitle: "App menu invoke blocked", message: readOnly)
        }
        let app = WorkspaceMonitor.withTargetWindow(resolvedApp)
        if isInvoke {
            if let refusal = await NativeBrowserSiteRules.mutatingPolicyRefusal(for: app, chromeBridge: chromeBridge) {
                if refusal.code == "POLICY_BLOCKED" {
                    return targetReadOnlyResponse(request: request, startNs: startNs, targetApp: app.name, activityTitle: "App menu invoke blocked", message: refusal.message)
                }
                return targetBlockedResponse(request: request, startNs: startNs, targetApp: app.name, activityTitle: "App menu blocked", message: refusal.message)
            }
        } else if let blocked = await NativeBrowserSiteRules.blockedMessage(for: app, chromeBridge: chromeBridge) {
            return targetBlockedResponse(request: request, startNs: startNs, targetApp: app.name, activityTitle: "App menu blocked", message: blocked)
        }
        let pinnedTitle = WindowResolver.pinnedTitle(pid: app.pid)
        let governedBrowser = (isInvoke ? TargetRulesStore.shared.rules.hasGovernedSiteRules : TargetRulesStore.shared.rules.hasSiteRules)
            && NativeBrowserSiteRules.isChromiumApp(bundleId: app.bundleId, name: app.name)
        let focusedId = pinnedTitle != nil || governedBrowser ? InputRouting.focusedWindowId(pid: app.pid) : nil
        if isInvoke, let pinnedTitle {
            let pinnedId = WindowResolver.window(pid: app.pid, titleContains: pinnedTitle).flatMap { WindowResolver.windowID(of: $0) }
            guard let pinnedId, pinnedId == focusedId else {
                let latencyMs = elapsedMs(since: startNs)
                let message = "App menus act on the focused window, not the task's pinned window."
                appendAudit(method: request.method.rawValue, targetApp: app.name, summary: message, latencyMs: latencyMs, success: false)
                return .failure(id: request.id, code: "TARGET_NOT_FRONTMOST", message: message, latencyMs: latencyMs)
            }
        }
        if governedBrowser, focusedId == nil || focusedId != app.windowId {
            if isInvoke {
                if let refusal = await withActionWindow("", app: app, operation: { focusedApp in
                    await NativeBrowserSiteRules.mutatingPolicyRefusal(for: focusedApp, chromeBridge: chromeBridge)
                }) {
                    if refusal.code == "POLICY_BLOCKED" {
                        return targetReadOnlyResponse(request: request, startNs: startNs, targetApp: app.name, activityTitle: "App menu invoke blocked", message: refusal.message)
                    }
                    return targetBlockedResponse(request: request, startNs: startNs, targetApp: app.name, activityTitle: "App menu blocked", message: refusal.message)
                }
            } else if let blocked = await withActionWindow("", app: app, operation: { focusedApp in
                await NativeBrowserSiteRules.blockedMessage(for: focusedApp, chromeBridge: chromeBridge)
            }) {
                return targetBlockedResponse(request: request, startNs: startNs, targetApp: app.name, activityTitle: "App menu blocked", message: blocked)
            }
        }
        if isInvoke, let refusal = await approvalRefusal(for: request, startNs: startNs) {
            return refusal
        }
        taskTabs.recordApp(app.pid, taskId: TaskActivityContext.taskId ?? request.namedTaskId)

        guard currentPermissions(promptAccessibility: false).accessibilityGranted else {
            let latencyMs = elapsedMs(since: startNs)
            appendAudit(method: request.method.rawValue, targetApp: app.name, summary: "Accessibility permission denied", latencyMs: latencyMs, success: false)
            return .failure(id: request.id, code: "PERMISSION_DENIED", message: "Accessibility permission not granted", latencyMs: latencyMs)
        }

        if isInvoke {
            let invokeRes = await Task.detached(priority: .userInitiated) {
                MenuBarController.invoke(pid: app.pid, appName: app.name, path: cleanedPath)
            }.value
            let latencyMs = elapsedMs(since: startNs)
            if invokeRes.success {
                let resolvedPath = invokeRes.result.invokedPath ?? cleanedPath
                let joined = resolvedPath.joined(separator: " > ")
                incrementActionCount(by: 1)
                appendAudit(method: request.method.rawValue, targetApp: app.name, summary: "Invoked menu \(joined)", latencyMs: latencyMs, success: true)
                emitLiveActivity(LiveActivityItem(
                    kind: .actionComplete,
                    appName: app.name,
                    appPid: app.pid,
                    bundleId: app.bundleId,
                    windowTitle: app.windowTitle,
                    title: "Menu: \(resolvedPath.last ?? joined)",
                    subtitle: joined,
                    mechanism: "ax-menu",
                    latencyMs: latencyMs,
                    success: true,
                    isInProgress: false,
                    windowId: app.windowId
                ))
                return .success(
                    id: request.id,
                    latencyMs: latencyMs,
                    appMenuResult: invokeRes.result
                )
            } else {
                let code = invokeRes.errorCode ?? "ELEMENT_NOT_FOUND"
                let message = invokeRes.message ?? invokeRes.result.message ?? "Failed to invoke menu item."
                appendAudit(method: request.method.rawValue, targetApp: app.name, summary: message, latencyMs: latencyMs, success: false)
                return .failure(id: request.id, code: code, message: message, latencyMs: latencyMs)
            }
        } else {
            let query = params.query
            let menuResult = await Task.detached(priority: .userInitiated) {
                MenuBarController.search(pid: app.pid, appName: app.name, query: query, maxItems: 200)
            }.value
            let latencyMs = elapsedMs(since: startNs)
            let count = menuResult.items?.count ?? 0
            appendAudit(method: request.method.rawValue, targetApp: app.name, summary: "Found \(count) menu item(s)", latencyMs: latencyMs, success: true)
            return .success(
                id: request.id,
                latencyMs: latencyMs,
                appMenuResult: menuResult
            )
        }
    }

    func handleSkillList(_ request: RPCRequest, startNs: UInt64) -> RPCResponse {
        if let blockReason = killSwitch.isBlocked(forSensitiveAction: false, isMutatingAction: false) {
            return blockedPolicyResponse(
                request: request,
                startNs: startNs,
                targetApp: nil,
                activityTitle: "Skill list blocked",
                reason: blockReason
            )
        }
        let skills = skillStore.list(filter: request.skillList)
        let latencyMs = elapsedMs(since: startNs)
        appendAudit(
            method: request.method.rawValue,
            targetApp: nil,
            summary: "Listed \(skills.count) skill(s)",
            latencyMs: latencyMs,
            success: true
        )
        return .success(id: request.id, latencyMs: latencyMs, skills: SkillListResult(skills: skills))
    }

    func handleSkillSave(_ request: RPCRequest, startNs: UInt64) -> RPCResponse {
        guard let params = request.skillSave else {
            let latencyMs = elapsedMs(since: startNs)
            return .failure(id: request.id, code: "INVALID_REQUEST", message: "Missing skillSave payload", latencyMs: latencyMs)
        }
        if let blockReason = killSwitch.isBlocked(forSensitiveAction: false, isMutatingAction: true) {
            return blockedPolicyResponse(
                request: request,
                startNs: startNs,
                targetApp: params.app,
                activityTitle: "Skill save blocked",
                reason: blockReason
            )
        }

        do {
            if params.delete == true {
                let removed = try skillStore.delete(name: params.name)
                let latencyMs = elapsedMs(since: startNs)
                appendAudit(
                    method: request.method.rawValue,
                    targetApp: params.app,
                    summary: removed ? "Deleted skill '\(params.name)'" : "Skill '\(params.name)' not found for delete",
                    latencyMs: latencyMs,
                    success: removed
                )
                return .success(id: request.id, latencyMs: latencyMs, skills: SkillListResult(skills: skillStore.list()))
            } else {
                let saved = try skillStore.save(params)
                let latencyMs = elapsedMs(since: startNs)
                appendAudit(
                    method: request.method.rawValue,
                    targetApp: saved.app ?? saved.target,
                    summary: "Saved skill '\(saved.name)' (\(saved.steps.count) step(s))",
                    latencyMs: latencyMs,
                    success: true
                )
                return .success(id: request.id, latencyMs: latencyMs, skills: SkillListResult(skills: skillStore.list(), saved: saved))
            }
        } catch {
            let latencyMs = elapsedMs(since: startNs)
            appendAudit(method: request.method.rawValue, targetApp: params.app, summary: error.localizedDescription, latencyMs: latencyMs, success: false)
            return .failure(id: request.id, code: "INVALID_REQUEST", message: error.localizedDescription, latencyMs: latencyMs)
        }
    }

    struct PreparedSkillRun {
        let params: SkillRunParams
        let skill: SkillRecord
        let targetKind: String
        let delegatedRequest: RPCRequest
    }

    enum PreparedSkillOutcome {
        case success(PreparedSkillRun)
        case failure(RPCResponse)
    }

    func prepareSkillRun(_ request: RPCRequest, startNs: UInt64) -> PreparedSkillOutcome {
        guard let params = request.skillRun else {
            let latencyMs = elapsedMs(since: startNs)
            return .failure(.failure(id: request.id, code: "INVALID_REQUEST", message: "Missing skillRun payload", latencyMs: latencyMs))
        }
        if let blockReason = killSwitch.isBlocked(forSensitiveAction: false, isMutatingAction: false) {
            return .failure(blockedPolicyResponse(
                request: request,
                startNs: startNs,
                targetApp: params.app ?? params.profile,
                activityTitle: "Skill run blocked",
                reason: blockReason
            ))
        }

        guard let skill = skillStore.get(name: params.name) else {
            let latencyMs = elapsedMs(since: startNs)
            let msg = SkillStoreError.notFound(params.name).localizedDescription
            appendAudit(method: request.method.rawValue, targetApp: params.app, summary: msg, latencyMs: latencyMs, success: false)
            return .failure(.failure(id: request.id, code: "SKILL_NOT_FOUND", message: msg, latencyMs: latencyMs))
        }

        let interpolatedSteps = SkillStore.interpolate(steps: skill.steps, with: params.params ?? [:])
        let missingParams = SkillStore.extractParamNames(from: interpolatedSteps)
        if !missingParams.isEmpty {
            let latencyMs = elapsedMs(since: startNs)
            let msg = "Missing skill parameter(s) for '\(skill.name)': \(missingParams.joined(separator: ", "))."
            appendAudit(method: request.method.rawValue, targetApp: params.app ?? skill.app, summary: msg, latencyMs: latencyMs, success: false)
            return .failure(.failure(id: request.id, code: "INVALID_REQUEST", message: msg, latencyMs: latencyMs))
        }

        let targetKind: String = {
            if let explicit = skill.target?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !explicit.isEmpty {
                return explicit
            }
            if params.tabId != nil || params.profile != nil || (skill.urlPattern?.isEmpty == false) {
                return "browser"
            }
            if params.app != nil || (skill.app?.isEmpty == false) {
                return "native"
            }
            if interpolatedSteps.contains(where: { $0.selector != nil || $0.action == .openURL || $0.action == .navigate }) {
                return "browser"
            }
            return "native"
        }()

        let effectiveWait = params.waitForLeaseMs ?? request.waitForLeaseMs
        let delegatedRequest: RPCRequest
        if targetKind == "browser" {
            delegatedRequest = RPCRequest(
                id: request.id,
                method: .browserAct,
                browserAct: BrowserActParams(
                    profile: params.profile,
                    tabId: params.tabId,
                    steps: interpolatedSteps,
                    stopOnError: params.stopOnError ?? true,
                    returnObservation: params.returnObservation ?? true,
                    returnDiffOnly: params.returnDiffOnly ?? false,
                    observationMode: params.observationMode,
                    waitForLeaseMs: effectiveWait
                ),
                taskId: request.namedTaskId,
                waitForLeaseMs: effectiveWait
            )
        } else {
            delegatedRequest = RPCRequest(
                id: request.id,
                method: .act,
                act: BatchActionRequest(
                    app: params.app ?? skill.app,
                    steps: interpolatedSteps,
                    stopOnError: params.stopOnError ?? true,
                    returnObservation: params.returnObservation ?? true,
                    returnDiffOnly: params.returnDiffOnly ?? false,
                    observationMode: params.observationMode,
                    waitForLeaseMs: effectiveWait
                ),
                taskId: request.namedTaskId,
                waitForLeaseMs: effectiveWait
            )
        }

        return .success(PreparedSkillRun(
            params: params,
            skill: skill,
            targetKind: targetKind,
            delegatedRequest: delegatedRequest
        ))
    }

    func finalizeSkillRun(
        request: RPCRequest,
        prepared: PreparedSkillRun,
        execResp: RPCResponse,
        startNs: UInt64
    ) -> RPCResponse {
        let latencyMs = elapsedMs(since: startNs)
        if !execResp.ok {
            return execResp
        }

        let skill = prepared.skill
        let params = prepared.params
        let actionResult = execResp.actionResult
        let succeeded = actionResult?.success ?? true
        let updatedSkill = skillStore.recordRun(name: skill.name, success: succeeded)
        let driftMessage: String? = {
            guard !succeeded else { return nil }
            if let failed = actionResult?.stepResults.first(where: { !$0.success }) {
                let reason = failed.message ?? failed.errorCode ?? "failed"
                return "Skill '\(skill.name)' drifted at step \(failed.index) (\(failed.action.rawValue)): \(reason)"
            }
            return "Skill '\(skill.name)' did not complete all steps."
        }()

        let skillResult = SkillRunResult(
            name: skill.name,
            success: succeeded,
            actionResult: actionResult,
            totalLatencyMs: (latencyMs * 100).rounded() / 100,
            message: driftMessage,
            skill: updatedSkill ?? skill
        )
        appendAudit(
            method: request.method.rawValue,
            targetApp: params.app ?? skill.app ?? params.profile ?? prepared.targetKind,
            summary: "Ran skill '\(skill.name)': \(succeeded ? "ok" : (driftMessage ?? "failed"))",
            latencyMs: latencyMs,
            success: succeeded
        )
        return .success(
            id: request.id,
            latencyMs: latencyMs,
            snapshot: execResp.snapshot ?? actionResult?.observation,
            actionResult: actionResult,
            screenshot: execResp.screenshot,
            browserTabId: execResp.browserTabId,
            browserUrl: execResp.browserUrl,
            browserTitle: execResp.browserTitle,
            skillResult: skillResult
        )
    }

    func handleSkillRun(_ request: RPCRequest, startNs: UInt64) async -> RPCResponse {
        switch prepareSkillRun(request, startNs: startNs) {
        case .failure(let errorResponse):
            return errorResponse
        case .success(let prepared):
            let execResp = await handleRequest(prepared.delegatedRequest)
            return finalizeSkillRun(request: request, prepared: prepared, execResp: execResp, startNs: startNs)
        }
    }
}
