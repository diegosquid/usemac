import Foundation
import UseMacProtocol

extension UseMacEngineService {
    func handleBrowserStatus(_ request: RPCRequest, startNs: UInt64) -> RPCResponse {
        let profiles = chromeBridge.connectedProfiles()
        let latencyMs = elapsedMs(since: startNs)
        return .success(
            id: request.id,
            latencyMs: latencyMs,
            status: currentStatus(),
            browserProfiles: profiles
        )
    }

    func handleBrowserReloadExtension(_ request: RPCRequest, startNs: UInt64) async -> RPCResponse {
        let params = request.browserReloadExtension ?? BrowserReloadExtensionParams()
        if let blockReason = killSwitch.isBlocked(forSensitiveAction: false, isMutatingAction: false) {
            return blockedPolicyResponse(
                request: request,
                startNs: startNs,
                targetApp: params.profile ?? "Chrome",
                activityAppName: "Chrome (\(params.profile ?? "Browser"))",
                activityTitle: "Extension reload blocked",
                reason: blockReason
            )
        }
        let outcome = await chromeBridge.reloadExtension(profile: params.profile, force: params.force ?? false)
        let latencyMs = elapsedMs(since: startNs)
        let summary = outcome.ok
            ? "Reloaded the Chrome extension: " + outcome.profiles.map { "\($0.profileName) v\($0.extensionVersion)" }.joined(separator: ", ")
            : (outcome.error?.message ?? "Extension reload failed")
        appendAudit(method: request.method.rawValue, targetApp: "Chrome (\(params.profile ?? "all profiles"))", summary: summary, latencyMs: latencyMs, success: outcome.ok)
        if outcome.ok {
            return .success(id: request.id, latencyMs: latencyMs, browserProfiles: outcome.profiles)
        } else {
            return .failure(
                id: request.id,
                code: outcome.error?.code ?? "EXTENSION_ERROR",
                message: outcome.error?.message ?? "Extension reload failed",
                latencyMs: latencyMs
            )
        }
    }

    func handleBrowserTabs(_ request: RPCRequest, startNs: UInt64) async -> RPCResponse {
        let params = request.browserTabs ?? BrowserTabsParams()
        if let blockReason = killSwitch.isBlocked(forSensitiveAction: false, isMutatingAction: false) {
            return blockedPolicyResponse(
                request: request,
                startNs: startNs,
                targetApp: params.profile ?? "Chrome",
                activityAppName: "Chrome (\(params.profile ?? "Browser"))",
                activityTitle: "Browser tabs blocked",
                reason: blockReason
            )
        }
        let bridgeResp = await chromeBridge.tabs(params)
        let latencyMs = elapsedMs(since: startNs)
        let resolvedProfile = bridgeResp.profileName ?? params.profile ?? "Browser"
        if bridgeResp.ok {
            let tabs = bridgeResp.tabs ?? []
            appendAudit(
                method: request.method.rawValue,
                targetApp: "Chrome (\(resolvedProfile))",
                summary: "Listed \(tabs.count) tab(s)",
                latencyMs: latencyMs,
                success: true
            )
            return .success(
                id: request.id,
                latencyMs: latencyMs,
                browserTabs: tabs,
                browserTabId: bridgeResp.tabId
            )
        } else {
            let code = bridgeResp.error?.code ?? "BROWSER_TABS_FAILED"
            let message = bridgeResp.error?.message ?? "Failed to list Chrome tabs"
            appendAudit(method: request.method.rawValue, targetApp: "Chrome (\(resolvedProfile))", summary: message, latencyMs: latencyMs, success: false)
            return .failure(id: request.id, code: code, message: message, latencyMs: latencyMs)
        }
    }

    func handleBrowserOpen(_ request: RPCRequest, startNs: UInt64) async -> RPCResponse {
        guard var params = request.browserOpen else {
            let latencyMs = elapsedMs(since: startNs)
            return .failure(id: request.id, code: "INVALID_REQUEST", message: "Missing browserOpen payload", latencyMs: latencyMs)
        }

        // With a tabId and activate, an empty url means "only make this tab active" (no navigation).
        let activateOnly = params.activate == true && params.tabId != nil
            && params.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let urlValidation: Result<String, NavigationPolicy.BlockedURL> = activateOnly
            ? .success("")
            : NavigationPolicy.validate(params.url)
        if case .failure(let blocked) = urlValidation {
            let latencyMs = elapsedMs(since: startNs)
            appendAudit(method: request.method.rawValue, targetApp: params.profile ?? "Chrome", summary: "URL blocked: \(blocked.message)", latencyMs: latencyMs, success: false)
            emitLiveActivity(LiveActivityItem(
                kind: .policyOrSafety,
                appName: "Chrome (\(params.profile ?? "Browser"))",
                title: "Browser open URL blocked",
                subtitle: blocked.message,
                latencyMs: latencyMs,
                success: false,
                isInProgress: false
            ))
            return .failure(id: request.id, code: "URL_BLOCKED", message: blocked.message, latencyMs: latencyMs)
        }
        if case .success(let normalizedURL) = urlValidation {
            params.url = normalizedURL
        }

        if let invalidDialog = BrowserStepValidation.invalidDialogActionMessage(params.dialogAction) {
            let latencyMs = elapsedMs(since: startNs)
            appendAudit(method: request.method.rawValue, targetApp: params.profile ?? "Chrome", summary: invalidDialog, latencyMs: latencyMs, success: false)
            return .failure(id: request.id, code: "INVALID_REQUEST", message: invalidDialog, latencyMs: latencyMs)
        }

        // Govern any inline `steps` on browser_open identically to browser_act.
        let inlineOpenSteps = params.steps ?? []
        if !inlineOpenSteps.isEmpty {
            if let invalid = BrowserStepValidation.invalidStepMessage(in: inlineOpenSteps) {
                let latencyMs = elapsedMs(since: startNs)
                appendAudit(method: request.method.rawValue, targetApp: params.profile ?? "Chrome", summary: invalid, latencyMs: latencyMs, success: false)
                return .failure(id: request.id, code: "INVALID_REQUEST", message: invalid, latencyMs: latencyMs)
            }
            var stepUrlErr: String?
            var normalizedSteps = inlineOpenSteps
            for idx in normalizedSteps.indices where normalizedSteps[idx].action == .openURL || normalizedSteps[idx].action == .navigate {
                switch NavigationPolicy.validate(normalizedSteps[idx].url ?? normalizedSteps[idx].text) {
                case .success(let normalized):
                    normalizedSteps[idx].url = normalized
                case .failure(let err):
                    stepUrlErr = err.message
                }
                if stepUrlErr != nil { break }
            }
            if let stepUrlErr {
                let latencyMs = elapsedMs(since: startNs)
                appendAudit(method: request.method.rawValue, targetApp: params.profile ?? "Chrome", summary: "URL blocked: \(stepUrlErr)", latencyMs: latencyMs, success: false)
                return .failure(id: request.id, code: "URL_BLOCKED", message: stepUrlErr, latencyMs: latencyMs)
            }
            var uploadErr: String?
            for idx in normalizedSteps.indices where normalizedSteps[idx].action == .uploadFile {
                switch ActionExecutor.validateAndNormalizeUploadFiles(normalizedSteps[idx].files) {
                case .success(let canonical):
                    normalizedSteps[idx].files = canonical
                case .failure(let err):
                    uploadErr = err.message
                }
                if uploadErr != nil { break }
            }
            if let uploadErr {
                let latencyMs = elapsedMs(since: startNs)
                appendAudit(method: request.method.rawValue, targetApp: params.profile ?? "Chrome", summary: "Upload blocked: \(uploadErr)", latencyMs: latencyMs, success: false)
                return .failure(id: request.id, code: "UPLOAD_BLOCKED", message: uploadErr, latencyMs: latencyMs)
            }
            params.steps = normalizedSteps
        }

        let requestedSteps = params.steps ?? []
        let requestedAutoDismiss = params.autoDismissOverlays == true
        let openHasSensitive = requestedSteps.contains { isSensitiveStepForPolicy($0) }
        let openHasMutating = requestedSteps.contains { isMutatingStepForPolicy($0) }
            || requestedAutoDismiss
            || params.dialogAction != nil
        if let blockReason = killSwitch.isBlocked(forSensitiveAction: openHasSensitive, isMutatingAction: openHasMutating) {
            return blockedPolicyResponse(
                request: request,
                startNs: startNs,
                targetApp: params.profile ?? "Chrome",
                activityAppName: "Chrome (\(params.profile ?? "Browser"))",
                activityTitle: "Browser open blocked",
                reason: blockReason
            )
        }

        if openHasMutating || openHasSensitive {
            var validatedOpen = request
            validatedOpen.browserOpen = params
            if let refusal = await approvalRefusal(for: validatedOpen, startNs: startNs) {
                return refusal
            }
        }

        let targetProfile = params.profile ?? chromeBridge.connectedProfiles().first?.profileName ?? "Browser"
        let targetLabel = "Chrome (\(targetProfile))"
        emitLiveActivity(LiveActivityItem(
            kind: .actionStart,
            appName: targetLabel,
            title: "Opening \(params.url)",
            isInProgress: true,
            browserTabId: nil,
            browserProfile: targetProfile
        ))

        // When site rules or per-site Ask/Read-only policies are active, never dispatch overlay clicks or inline steps
        // inside `open` before the committed redirect destination URL has passed TargetRules on the daemon side.
        let deferMutationsForSiteRules = TargetRulesStore.shared.rules.hasGovernedSiteRules
            && (requestedAutoDismiss || !requestedSteps.isEmpty)
        var wireOpenParams = params
        if deferMutationsForSiteRules {
            wireOpenParams.steps = nil
            wireOpenParams.autoDismissOverlays = nil
        }

        let bridgeResp = await openBrowserTab(wireOpenParams, taskId: request.namedTaskId ?? TaskActivityContext.taskId)
        let resolvedProfile = bridgeResp.profileName ?? params.profile ?? "Browser"
        let resolvedLabel = "Chrome (\(resolvedProfile))"
        if bridgeResp.ok {
            var finalSnapshot = bridgeResp.snapshot ?? bridgeResp.actionResult?.observation
            var finalActionResult = bridgeResp.actionResult
            var finalScreenshot = bridgeResp.screenshot
            var finalUrl = bridgeResp.url
            var finalTitle = bridgeResp.title
            var followUpFailure: (code: String, message: String, hint: String?)?
            let openDialogs = bridgeResp.actionResult?.dialogs
                ?? (bridgeResp.snapshot?.pageState?.lastDialog.map { [$0] } ?? [])

            // Governed follow-up act: runs when (a) mutations were deferred until after redirect verification, or
            // (b) a legacy extension returned ok for `open` while silently ignoring inline `steps`.
            let legacySkippedSteps = !deferMutationsForSiteRules && !requestedSteps.isEmpty && bridgeResp.actionResult == nil
            if bridgeResp.restricted != true && (deferMutationsForSiteRules || legacySkippedSteps) {
                var followUpSteps: [ActionStep] = []
                if deferMutationsForSiteRules && requestedAutoDismiss,
                   let ov = bridgeResp.snapshot?.pageState?.blockingOverlay {
                    if let closeId = ov.closeElementId, !closeId.isEmpty {
                        followUpSteps.append(ActionStep(action: .click, elementId: closeId, optional: true))
                    } else if let cx = ov.closeX, let cy = ov.closeY, cx.isFinite, cy.isFinite {
                        followUpSteps.append(ActionStep(action: .click, x: cx, y: cy, optional: true))
                    }
                }
                followUpSteps.append(contentsOf: requestedSteps)

                if !followUpSteps.isEmpty {
                    if let targetTabId = bridgeResp.tabId ?? params.tabId {
                        let followUpParams = BrowserActParams(
                            profile: bridgeResp.profileName ?? params.profile,
                            tabId: targetTabId,
                            steps: followUpSteps,
                            stopOnError: true,
                            returnObservation: true,
                            returnDiffOnly: params.returnDiffOnly ?? false,
                            observationMode: params.observationMode,
                            dialogAction: params.dialogAction,
                            dialogPromptText: params.dialogPromptText
                        )
                        if deferMutationsForSiteRules,
                           let landedURL = bridgeResp.url,
                           TargetRules.site(ofURL: landedURL) != TargetRules.site(ofURL: params.url) {
                            let redirectedAct = RPCRequest(
                                id: request.id,
                                method: .browserAct,
                                browserAct: followUpParams,
                                taskId: request.namedTaskId,
                                agent: request.agent
                            )
                            if let refusal = await approvalRefusal(for: redirectedAct, startNs: startNs, browserAct: followUpParams) {
                                return refusal
                            }
                        }
                        let actResp = await chromeBridge.act(followUpParams)
                        if actResp.ok {
                            var mergedResult = actResp.actionResult
                            if !openDialogs.isEmpty, var res = mergedResult {
                                res.dialogs = openDialogs + (res.dialogs ?? [])
                                mergedResult = res
                            }
                            finalActionResult = mergedResult
                            var mergedSnap = actResp.snapshot ?? actResp.actionResult?.observation ?? finalSnapshot
                            if mergedSnap?.pageState != nil, mergedSnap?.pageState?.lastDialog == nil,
                               let lastOpenDialog = openDialogs.last {
                                mergedSnap?.pageState?.lastDialog = lastOpenDialog
                            }
                            finalSnapshot = mergedSnap
                            finalScreenshot = actResp.screenshot ?? finalScreenshot
                            finalUrl = actResp.url ?? finalUrl
                            finalTitle = actResp.title ?? finalTitle
                        } else {
                            followUpFailure = (
                                code: actResp.error?.code ?? "BROWSER_ACT_FAILED",
                                message: actResp.error?.message ?? "Failed to execute inline browser_open steps",
                                hint: actResp.error?.hint
                            )
                        }
                    } else {
                        followUpFailure = (
                            code: "BROWSER_OPEN_FAILED",
                            message: "Extension opened the page without returning a tabId to execute the requested inline steps.",
                            hint: nil
                        )
                    }
                }
            }

            let latencyMs = elapsedMs(since: startNs)
            if let failure = followUpFailure {
                appendAudit(method: request.method.rawValue, targetApp: resolvedLabel, summary: failure.message, latencyMs: latencyMs, success: false)
                emitLiveActivity(LiveActivityItem(
                    kind: .actionComplete,
                    appName: resolvedLabel,
                    title: ActivityCaption.hostOrText(params.url).map { "Couldn't complete \($0)" } ?? "Couldn't run page steps",
                    subtitle: ActivityCaption.reason(errorCode: failure.code, message: failure.message, inBrowser: true) ?? failure.message,
                    latencyMs: latencyMs,
                    success: false,
                    isInProgress: false,
                    browserTabId: bridgeResp.tabId,
                    browserProfile: resolvedProfile
                ))
                return .failure(id: request.id, code: failure.code, message: failure.message, latencyMs: latencyMs, hint: failure.hint)
            } else {
                if let stepCount = finalActionResult?.stepResults.count, stepCount > 0 {
                    incrementActionCount(by: stepCount)
                }
                appendAudit(
                    method: request.method.rawValue,
                    targetApp: resolvedLabel,
                    summary: "Opened \(finalUrl ?? params.url)",
                    latencyMs: latencyMs,
                    success: true
                )
                emitLiveActivity(LiveActivityItem(
                    kind: .actionComplete,
                    appName: resolvedLabel,
                    windowTitle: finalTitle,
                    title: "Opened \(finalTitle ?? params.url)",
                    subtitle: finalUrl,
                    latencyMs: latencyMs,
                    success: true,
                    isInProgress: false,
                    browserTabId: bridgeResp.tabId,
                    browserProfile: resolvedProfile
                ))
                return .success(
                    id: request.id,
                    latencyMs: latencyMs,
                    snapshot: finalSnapshot,
                    actionResult: finalActionResult,
                    screenshot: finalScreenshot,
                    browserTabId: bridgeResp.tabId,
                    browserUrl: finalUrl,
                    browserTitle: finalTitle
                )
            }
        } else {
            let latencyMs = elapsedMs(since: startNs)
            let code = bridgeResp.error?.code ?? "BROWSER_OPEN_FAILED"
            let message = bridgeResp.error?.message ?? "Failed to open URL in Chrome"
            appendAudit(method: request.method.rawValue, targetApp: resolvedLabel, summary: message, latencyMs: latencyMs, success: false)
            emitLiveActivity(LiveActivityItem(
                kind: .actionComplete,
                appName: resolvedLabel,
                title: ActivityCaption.hostOrText(params.url).map { "Couldn't open \($0)" } ?? "Couldn't open the page",
                subtitle: ActivityCaption.reason(errorCode: code, message: message, inBrowser: true) ?? message,
                latencyMs: latencyMs,
                success: false,
                isInProgress: false
            ))
            return .failure(id: request.id, code: code, message: message, latencyMs: latencyMs, hint: bridgeResp.error?.hint)
        }
    }

    func handleBrowserObserve(_ request: RPCRequest, startNs: UInt64) async -> RPCResponse {
        let params = request.browserObserve ?? BrowserObserveParams()
        if let blockReason = killSwitch.isBlocked(forSensitiveAction: false, isMutatingAction: false) {
            return blockedPolicyResponse(
                request: request,
                startNs: startNs,
                targetApp: params.profile ?? "Chrome",
                activityAppName: "Chrome (\(params.profile ?? "Browser"))",
                activityTitle: "Browser observe blocked",
                reason: blockReason
            )
        }
        let bridgeResp = await chromeBridge.observe(params)
        let latencyMs = elapsedMs(since: startNs)
        let resolvedProfile = bridgeResp.profileName ?? params.profile ?? "Browser"
        let resolvedLabel = "Chrome (\(resolvedProfile))"

        if bridgeResp.ok, var snapshot = bridgeResp.snapshot {
            recordObserveMetrics(latencyMs: snapshot.latencyMs, fromHotCache: false)
            if let overlay = snapshot.pageState?.blockingOverlay {
                snapshot.agentFeedback = AgentFeedback(
                    severity: overlay.blocksScroll ? "blocked" : "warning",
                    trigger: "blocking_overlay",
                    diagnosis: "Overlay detected on page: \"\(overlay.summary)\"",
                    suggestedAction: overlay.closeElementId != nil || (overlay.closeX != nil && overlay.closeY != nil)
                        ? "Dismiss the overlay before interacting with the page."
                        : "Press Escape or call vision_query(mode: 'diagnose') to locate the close button.",
                    suggestedX: overlay.closeX,
                    suggestedY: overlay.closeY,
                    suggestedElementId: overlay.closeElementId,
                    source: "dom-overlay",
                    latencyMs: snapshot.latencyMs
                )
            }
            appendAudit(
                method: request.method.rawValue,
                targetApp: resolvedLabel,
                summary: "Observed \(snapshot.elements.count) DOM elements",
                latencyMs: latencyMs,
                success: true
            )
            emitLiveActivity(LiveActivityItem(
                kind: .observe,
                appName: resolvedLabel,
                windowTitle: bridgeResp.title ?? snapshot.app.windowTitle,
                windowBounds: snapshot.app.windowBounds,
                title: "Observed \(snapshot.elements.count) elements",
                subtitle: "chrome-dom",
                mechanism: "chrome-dom",
                latencyMs: snapshot.latencyMs,
                success: true,
                isInProgress: false,
                browserTabId: bridgeResp.tabId ?? params.tabId,
                browserProfile: resolvedProfile
            ))
            return .success(
                id: request.id,
                latencyMs: latencyMs,
                snapshot: snapshot,
                screenshot: bridgeResp.screenshot,
                browserTabId: bridgeResp.tabId,
                browserUrl: bridgeResp.url,
                browserTitle: bridgeResp.title
            )
        } else {
            let code = bridgeResp.error?.code ?? "BROWSER_OBSERVE_FAILED"
            let message = bridgeResp.error?.message ?? "Failed to observe browser tab"
            appendAudit(method: request.method.rawValue, targetApp: resolvedLabel, summary: message, latencyMs: latencyMs, success: false)
            emitLiveActivity(LiveActivityItem(
                kind: .observe,
                appName: resolvedLabel,
                title: "Couldn't read the page",
                subtitle: ActivityCaption.reason(errorCode: code, message: message, inBrowser: true) ?? message,
                latencyMs: latencyMs,
                success: false,
                isInProgress: false
            ))
            return .failure(id: request.id, code: code, message: message, latencyMs: latencyMs, hint: bridgeResp.error?.hint)
        }
    }

    func handleBrowserExtract(_ request: RPCRequest, startNs: UInt64) async -> RPCResponse {
        let params = request.browserExtract ?? BrowserExtractParams()
        let isEvalMode = (params.normalizedMode == "eval")
        if let blockReason = killSwitch.isBlocked(forSensitiveAction: isEvalMode, isMutatingAction: isEvalMode) {
            return blockedPolicyResponse(
                request: request,
                startNs: startNs,
                targetApp: params.profile ?? "Chrome",
                activityAppName: "Chrome (\(params.profile ?? "Browser"))",
                activityTitle: isEvalMode ? "Browser eval blocked" : "Browser extract blocked",
                reason: blockReason
            )
        }
        if let refusal = await approvalRefusal(for: request, startNs: startNs) {
            return refusal
        }
        let bridgeResp = await chromeBridge.extract(params)
        let latencyMs = elapsedMs(since: startNs)
        let resolvedProfile = bridgeResp.profileName ?? params.profile ?? "Browser"
        let resolvedLabel = "Chrome (\(resolvedProfile))"

        if bridgeResp.ok, let extracted = bridgeResp.extractResult {
            let resultMode = extracted.mode.lowercased()
            let isDownloads = resultMode == "downloads"
            let auditSummary: String
            var subtitle = extracted.rowCount.map { "\($0) rows · \(extracted.columnCount ?? 0) cols" } ?? "chrome-extract"
            if isEvalMode {
                auditSummary = AuditRedactor.evalSummary(params.expression ?? "")
            } else if isDownloads {
                let count = extracted.downloads?.count ?? 0
                subtitle = "\(count) \(count == 1 ? "download" : "downloads")"
                auditSummary = "Extracted downloads (\(subtitle))"
            } else if resultMode == "network" {
                let count = extracted.rowCount ?? 0
                subtitle = "\(count) \(count == 1 ? "response" : "responses")"
                auditSummary = "Extracted network (\(subtitle))"
            } else {
                auditSummary = "Extracted \(extracted.mode) (\(extracted.rowCount ?? 0) rows, \(extracted.columnCount ?? 0) cols)"
            }
            appendAudit(
                method: request.method.rawValue,
                targetApp: resolvedLabel,
                summary: auditSummary,
                latencyMs: latencyMs,
                success: true
            )
            emitLiveActivity(LiveActivityItem(
                kind: .observe,
                appName: resolvedLabel,
                windowTitle: bridgeResp.title ?? extracted.title,
                title: "Extracted \(extracted.mode) data",
                subtitle: subtitle,
                mechanism: "chrome-extract",
                latencyMs: extracted.latencyMs,
                success: true,
                isInProgress: false,
                browserTabId: isDownloads ? nil : (bridgeResp.tabId ?? params.tabId),
                browserProfile: resolvedProfile
            ))
            return .success(
                id: request.id,
                latencyMs: latencyMs,
                browserExtract: extracted,
                browserTabId: isDownloads ? nil : (bridgeResp.tabId ?? extracted.tabId),
                browserUrl: bridgeResp.url ?? extracted.url,
                browserTitle: bridgeResp.title ?? extracted.title
            )
        } else {
            let code = bridgeResp.error?.code ?? "BROWSER_EXTRACT_FAILED"
            let message = bridgeResp.error?.message ?? "Failed to extract browser data"
            appendAudit(method: request.method.rawValue, targetApp: resolvedLabel, summary: message, latencyMs: latencyMs, success: false)
            return .failure(id: request.id, code: code, message: message, latencyMs: latencyMs, hint: bridgeResp.error?.hint)
        }
    }

    func handleBrowserScreenshot(_ request: RPCRequest, startNs: UInt64) async -> RPCResponse {
        let params = request.browserScreenshot ?? BrowserScreenshotParams()
        if let blockReason = killSwitch.isBlocked(forSensitiveAction: false, isMutatingAction: false) {
            return blockedPolicyResponse(
                request: request,
                startNs: startNs,
                targetApp: params.profile ?? "Chrome",
                activityAppName: "Chrome (\(params.profile ?? "Browser"))",
                activityTitle: "Browser screenshot blocked",
                reason: blockReason
            )
        }
        let beforeShotFrame = (params.diffCrop == true)
            ? chromeBridge.latestFrame(profileQuery: params.profile, tabId: params.tabId)
            : nil
        let bridgeResp = await chromeBridge.screenshot(params)
        let latencyMs = elapsedMs(since: startNs)
        let resolvedProfile = bridgeResp.profileName ?? params.profile ?? "Browser"
        let resolvedLabel = "Chrome (\(resolvedProfile))"

        if bridgeResp.ok, let rawShot = bridgeResp.screenshot {
            var shot = rawShot
            let resolvedTabId = bridgeResp.tabId ?? params.tabId
            let targetKey = "browser:\(resolvedProfile.lowercased()):\(resolvedTabId ?? -1)"
            let rawData = rawShot.base64Data.flatMap { Data(base64Encoded: $0) }
                ?? (try? Data(contentsOf: URL(fileURLWithPath: rawShot.path)))
            if let rawData {
                if params.diffCrop == true, cachedScreenshotJPEG(forKey: targetKey) == nil, let beforeJPEG = beforeShotFrame?.jpegData {
                    storeScreenshotJPEG(beforeJPEG, forKey: targetKey)
                }
                let maxDim = max(params.viewportWidth ?? 1280, params.viewportHeight ?? 1280)
                let quality = Double(params.quality ?? 84) / 100.0
                let cropped = applyRegionOrDiffCrop(
                    jpegData: rawData,
                    original: rawShot,
                    targetKey: targetKey,
                    region: params.region,
                    diffCrop: params.diffCrop == true,
                    maxDimension: maxDim,
                    quality: quality,
                    includeBase64: params.returnImageContent != false
                )
                shot = cropped.screenshot
            }
            appendAudit(
                method: request.method.rawValue,
                targetApp: resolvedLabel,
                summary: "Captured browser \(shot.width)x\(shot.height) JPEG (\(shot.byteCount) bytes)",
                latencyMs: latencyMs,
                success: true
            )
            emitLiveActivity(LiveActivityItem(
                kind: .screenshot,
                appName: resolvedLabel,
                windowTitle: bridgeResp.title,
                title: (params.selector != nil || params.elementId != nil) ? "Inspecting element" : "Inspecting page",
                subtitle: "\(shot.width)×\(shot.height) · \(max(1, shot.byteCount / 1024)) KB",
                latencyMs: shot.latencyMs,
                success: true,
                isInProgress: false,
                browserTabId: bridgeResp.tabId ?? params.tabId,
                browserProfile: resolvedProfile
            ))
            return .success(
                id: request.id,
                latencyMs: latencyMs,
                screenshot: shot,
                browserTabId: bridgeResp.tabId,
                browserUrl: bridgeResp.url,
                browserTitle: bridgeResp.title
            )
        } else {
            let code = bridgeResp.error?.code ?? "BROWSER_SCREENSHOT_FAILED"
            let message = bridgeResp.error?.message ?? "Failed to capture browser screenshot"
            appendAudit(method: request.method.rawValue, targetApp: resolvedLabel, summary: message, latencyMs: latencyMs, success: false)
            return .failure(id: request.id, code: code, message: message, latencyMs: latencyMs, hint: bridgeResp.error?.hint)
        }
    }

    func handleBrowserAct(_ request: RPCRequest, startNs: UInt64) async -> RPCResponse {
        guard var params = request.browserAct else {
            let latencyMs = elapsedMs(since: startNs)
            return .failure(id: request.id, code: "INVALID_REQUEST", message: "Missing browserAct payload", latencyMs: latencyMs)
        }
        if let invalidDialog = BrowserStepValidation.invalidDialogActionMessage(params.dialogAction) {
            let latencyMs = elapsedMs(since: startNs)
            appendAudit(method: request.method.rawValue, targetApp: params.profile ?? "Chrome", summary: invalidDialog, latencyMs: latencyMs, success: false)
            return .failure(id: request.id, code: "INVALID_REQUEST", message: invalidDialog, latencyMs: latencyMs)
        }
        if let invalid = BrowserStepValidation.invalidStepMessage(in: params.steps) {
            let latencyMs = elapsedMs(since: startNs)
            appendAudit(method: request.method.rawValue, targetApp: params.profile ?? "Chrome", summary: invalid, latencyMs: latencyMs, success: false)
            return .failure(id: request.id, code: "INVALID_REQUEST", message: invalid, latencyMs: latencyMs)
        }

        var urlValidationError: String?
        for idx in params.steps.indices where params.steps[idx].action == .openURL || params.steps[idx].action == .navigate {
            switch NavigationPolicy.validate(params.steps[idx].url ?? params.steps[idx].text) {
            case .success(let normalizedURL):
                params.steps[idx].url = normalizedURL
            case .failure(let err):
                urlValidationError = err.message
            }
            if urlValidationError != nil { break }
        }
        if let urlErr = urlValidationError {
            let latencyMs = elapsedMs(since: startNs)
            appendAudit(method: request.method.rawValue, targetApp: params.profile ?? "Chrome", summary: "URL blocked: \(urlErr)", latencyMs: latencyMs, success: false)
            emitLiveActivity(LiveActivityItem(
                kind: .policyOrSafety,
                appName: "Chrome (\(params.profile ?? "Browser"))",
                title: "Browser URL blocked",
                subtitle: urlErr,
                latencyMs: latencyMs,
                success: false,
                isInProgress: false
            ))
            return .failure(id: request.id, code: "URL_BLOCKED", message: urlErr, latencyMs: latencyMs)
        }

        let hasSensitive = params.steps.contains { isSensitiveStepForPolicy($0) }
        let hasMutating = params.steps.contains { isMutatingStepForPolicy($0) } || params.dialogAction != nil
        var blockReason = killSwitch.isBlocked(forSensitiveAction: hasSensitive, isMutatingAction: hasMutating)
        let readOnlyRequested = blockReason == nil && params.readOnly == true && hasMutating
        if readOnlyRequested {
            blockReason = "Mutating browser step blocked because readOnly=true was requested (only scroll, hover, wait, and target are permitted)."
        }
        if let blockReason {
            return blockedPolicyResponse(
                request: request,
                startNs: startNs,
                targetApp: params.profile ?? "Chrome",
                activityAppName: "Chrome (\(params.profile ?? "Browser"))",
                activityTitle: "Browser action blocked",
                reason: blockReason,
                readOnlyRequested: readOnlyRequested
            )
        }

        // Validate & canonicalize local file paths before sending uploadFile steps to Chrome CDP
        var uploadValidationError: String?
        for idx in params.steps.indices where params.steps[idx].action == .uploadFile {
            switch ActionExecutor.validateAndNormalizeUploadFiles(params.steps[idx].files) {
            case .success(let canonicalPaths):
                params.steps[idx].files = canonicalPaths
            case .failure(let err):
                uploadValidationError = err.message
            }
            if uploadValidationError != nil { break }
        }
        if let uploadErr = uploadValidationError {
            let latencyMs = elapsedMs(since: startNs)
            appendAudit(method: request.method.rawValue, targetApp: params.profile ?? "Chrome", summary: "Upload blocked: \(uploadErr)", latencyMs: latencyMs, success: false)
            emitLiveActivity(LiveActivityItem(
                kind: .policyOrSafety,
                appName: "Chrome (\(params.profile ?? "Browser"))",
                title: "File upload blocked",
                subtitle: uploadErr,
                latencyMs: latencyMs,
                success: false,
                isInProgress: false
            ))
            return .failure(id: request.id, code: "UPLOAD_BLOCKED", message: uploadErr, latencyMs: latencyMs)
        }

        if let refusal = await approvalRefusal(for: request, startNs: startNs, browserAct: params) {
            return refusal
        }
        let targetProfile = params.profile ?? chromeBridge.connectedProfiles().first?.profileName ?? "Browser"
        let targetLabel = "Chrome (\(targetProfile))"
        emitLiveActivity(LiveActivityItem(
            kind: .actionStart,
            appName: targetLabel,
            title: "Running \(params.steps.count) browser step\(params.steps.count == 1 ? "" : "s")…",
            isInProgress: true,
            browserTabId: params.tabId,
            browserProfile: targetProfile
        ))

        let beforeFrame = chromeBridge.latestFrame(profileQuery: params.profile, tabId: params.tabId)
        let bridgeResp = await chromeBridge.act(params)
        let afterFrame = chromeBridge.latestFrame(profileQuery: bridgeResp.profileName ?? params.profile, tabId: bridgeResp.tabId ?? params.tabId)
        let latencyMs = elapsedMs(since: startNs)
        let resolvedProfile = bridgeResp.profileName ?? params.profile ?? "Browser"
        let resolvedLabel = "Chrome (\(resolvedProfile))"

        if bridgeResp.ok {
            var enrichedActionResult = bridgeResp.actionResult
            var responseScreenshot = bridgeResp.screenshot
            var noVisualEffectStep: ActionStepType?
            var noVisualEffectDiffPct: Double?
            var computedDirty: DirtyRegionResult?

            let resolvedTabId = bridgeResp.tabId ?? params.tabId
            let browserTargetKey = "browser:\(resolvedProfile.lowercased()):\(resolvedTabId ?? -1)"
            let afterShotJPEG: Data? = bridgeResp.screenshot?.base64Data.flatMap { Data(base64Encoded: $0) }
                ?? (bridgeResp.screenshot.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0.path)) })
            let effectiveAfterJPEG = afterShotJPEG ?? afterFrame?.jpegData
            let effectiveBeforeJPEG: Data? = {
                if let before = beforeFrame?.jpegData {
                    if afterShotJPEG != nil || beforeFrame?.capturedAt != afterFrame?.capturedAt {
                        return before
                    }
                }
                return cachedScreenshotJPEG(forKey: browserTargetKey)
            }()

            if let beforeJPEG = effectiveBeforeJPEG,
               let afterJPEG = effectiveAfterJPEG {
                let dirty = LocalVisionEngine.computeDirtyRegion(beforeJPEG: beforeJPEG, afterJPEG: afterJPEG)
                computedDirty = dirty
                let diffPct = dirty.overallDiffPercent

                if var actionRes = enrichedActionResult {
                    if let dirtyRect = dirty.dirtyRect {
                        actionRes.dirtyRect = dirtyRect
                    }
                    if !actionRes.stepResults.isEmpty {
                        let lastActionIdx = actionRes.stepResults.lastIndex(where: { $0.action != .wait }) ?? (actionRes.stepResults.count - 1)
                        actionRes.stepResults[lastActionIdx].visualChangePercent = diffPct
                        let stepAction = actionRes.stepResults[lastActionIdx].action
                        let mechLower = actionRes.stepResults[lastActionIdx].mechanism.lowercased()
                        let isDownloadClick = mechLower.contains("download") || actionRes.stepResults[lastActionIdx].downloadPath != nil
                        // Only flag low visual diff on scroll, or no-effect click/key when BOTH DOM is unchanged AND max 16x10 tile diff < 0.8%.
                        let urlChanged = beforeFrame?.url != nil && afterFrame?.url != nil && beforeFrame?.url != afterFrame?.url
                        let domUnchanged: Bool = {
                            guard let diff = actionRes.observation?.diff else { return true }
                            return diff.added.isEmpty && diff.changed.isEmpty && diff.removedIds.isEmpty
                        }()
                        if diffPct < 1.2 && !isDownloadClick && !urlChanged && stepAction == .scroll && actionRes.stepResults[lastActionIdx].blockedWarning == nil {
                            actionRes.stepResults[lastActionIdx].blockedWarning = String(
                                format: "Visual diff after %@ was only %.2f%% — screen barely changed (possible popup/overlay or scroll lock).",
                                stepAction.rawValue,
                                diffPct
                            )
                        } else if (stepAction == .click || stepAction == .doubleClick || stepAction == .pressKey),
                                  !isDownloadClick,
                                  !urlChanged,
                                  domUnchanged && dirty.maxTileDiffPercent < 0.8,
                                  actionRes.stepResults[lastActionIdx].blockedWarning == nil {
                            noVisualEffectStep = stepAction
                            noVisualEffectDiffPct = diffPct
                        }

                        // Fast <20 ms dirty-rect Apple Vision OCR delta when pixels changed locally without a DOM diff (e.g. canvas/toast).
                        if let dirtyRect = dirty.dirtyRect,
                           dirty.maxTileDiffPercent >= 0.8,
                           (domUnchanged || params.diffCrop == true) {
                            let deltaOCR = await Task.detached(priority: .userInitiated) {
                                LocalVisionEngine.recognizeText(inJPEG: afterJPEG, region: dirtyRect, fast: true)
                            }.value
                            if !deltaOCR.text.isEmpty {
                                actionRes.visualDeltaOCR = deltaOCR.text
                            }
                        }
                    }
                    enrichedActionResult = actionRes
                }
            }
            if let effectiveAfterJPEG {
                storeScreenshotJPEG(effectiveAfterJPEG, forKey: browserTargetKey)
            }

            // Wire `diffCrop: true` on browser_act: crop post-action JPEG to dirtyRect.
            if params.diffCrop == true,
               let afterJPEG = effectiveAfterJPEG,
               let dirtyRect = computedDirty?.dirtyRect {
                if let croppedShot = saveCroppedJPEG(
                    fromJPEG: afterJPEG,
                    rect: dirtyRect,
                    padding: 24,
                    maxDimension: 1024,
                    quality: 0.80,
                    includeBase64: params.returnImageContent != false,
                    latencyMs: bridgeResp.screenshot?.latencyMs ?? 0
                ) {
                    responseScreenshot = croppedShot
                    enrichedActionResult?.screenshot = croppedShot
                    enrichedActionResult?.observation?.screenshotPath = croppedShot.path
                }
            }

            // Two-Way Auto-Visual Reflex: when a scroll stalls or an overlay blocks the page,
            // UseMac immediately diagnoses what happened locally (DOM + fast <20ms dirty-rect Apple Vision OCR) with zero disk I/O.
            if var actionRes = enrichedActionResult {
                let blockedStep = actionRes.stepResults.last(where: { $0.blockedWarning != nil })
                let domOverlay = actionRes.observation?.pageState?.blockingOverlay
                if blockedStep != nil || domOverlay != nil {
                    if let overlay = domOverlay, (overlay.closeElementId != nil || (overlay.closeX != nil && overlay.closeY != nil)) {
                        actionRes.agentFeedback = AgentFeedback(
                            severity: "blocked",
                            trigger: blockedStep?.action == .scroll ? "scroll_blocked" : "blocking_overlay",
                            diagnosis: blockedStep?.blockedWarning ?? "Overlay blocking page: \"\(overlay.summary)\"",
                            suggestedAction: "Click the overlay close control, then retry your action.",
                            suggestedX: overlay.closeX,
                            suggestedY: overlay.closeY,
                            suggestedElementId: overlay.closeElementId,
                            source: "dom-overlay",
                            latencyMs: 0.2
                        )
                    } else if let afterJPEG = effectiveAfterJPEG {
                        let reflexStartNs = DispatchTime.now().uptimeNanoseconds
                        let vpW = Double(afterFrame?.viewportWidth ?? Int(actionRes.observation?.pageState?.viewportWidth ?? 1280))
                        let vpH = Double(afterFrame?.viewportHeight ?? Int(actionRes.observation?.pageState?.viewportHeight ?? 800))
                        let reflexRegion = computedDirty?.dirtyRect
                        let diag = await Task.detached(priority: .userInitiated) {
                            Self.diagnoseInMemoryWithAppleVision(
                                jpegData: afterJPEG,
                                dirtyRect: reflexRegion,
                                viewportWidth: vpW,
                                viewportHeight: vpH
                            )
                        }.value
                        let reflexMs = elapsedMs(since: reflexStartNs)
                        if actionRes.visualDeltaOCR == nil, !diag.deltaText.isEmpty {
                            actionRes.visualDeltaOCR = diag.deltaText
                        }
                        if diag.blockingDetected {
                            let suggestion: String
                            if let rx = diag.closeX, let ry = diag.closeY {
                                suggestion = String(format: "Click the detected dismiss/close control at (%.1f, %.1f), then retry.", rx, ry)
                            } else {
                                suggestion = "Check the validation error / disabled control or press Escape before retrying."
                            }
                            actionRes.agentFeedback = AgentFeedback(
                                severity: "blocked",
                                trigger: blockedStep?.action == .scroll
                                    ? "scroll_blocked"
                                    : (noVisualEffectStep != nil ? "action_no_visual_change" : "blocking_overlay"),
                                diagnosis: "\(blockedStep?.blockedWarning ?? "") \(diag.summary)".trimmingCharacters(in: .whitespaces),
                                suggestedAction: suggestion,
                                suggestedX: diag.closeX,
                                suggestedY: diag.closeY,
                                source: "apple-vision-ocr",
                                latencyMs: (reflexMs * 100).rounded() / 100
                            )
                        } else if let warn = blockedStep?.blockedWarning {
                            actionRes.agentFeedback = AgentFeedback(
                                severity: "warning",
                                trigger: "scroll_blocked",
                                diagnosis: "\(warn) Apple Vision OCR saw no popup overlay.",
                                suggestedAction: "Try scrolling inside a specific inner container or check if you reached the end of the page.",
                                source: "apple-vision-ocr",
                                latencyMs: (reflexMs * 100).rounded() / 100
                            )
                        } else if let noEff = noVisualEffectStep, !diag.summary.isEmpty {
                            actionRes.agentFeedback = AgentFeedback(
                                severity: "info",
                                trigger: "action_no_visual_change",
                                diagnosis: String(format: "After %@ (visualDiff=%.2f%%), Apple Vision OCR reports: %@", noEff.rawValue, noVisualEffectDiffPct ?? 0, diag.summary),
                                suggestedAction: "Use vision_query(mode: 'ask') if you need more visual detail without taking a full screenshot.",
                                source: "apple-vision-ocr",
                                latencyMs: (reflexMs * 100).rounded() / 100
                            )
                        }
                    }
                    enrichedActionResult = actionRes
                }

                // Tiered fast inline verification (`params.verify`): DOM text first (<1 ms), then negation-safe Apple Vision OCR (~20 ms).
                if let verifyPrompt = params.verify?.trimmingCharacters(in: .whitespacesAndNewlines), !verifyPrompt.isEmpty {
                    let verifyRes = await runTieredVerify(
                        assertion: verifyPrompt,
                        snapshot: bridgeResp.snapshot ?? actionRes.observation,
                        visionParams: VisionQueryParams(
                            mode: "verify",
                            query: verifyPrompt,
                            profile: resolvedProfile,
                            tabId: resolvedTabId
                        ),
                        inMemoryJPEG: effectiveAfterJPEG,
                        viewportWidth: Double(afterFrame?.viewportWidth ?? Int(actionRes.observation?.pageState?.viewportWidth ?? 1280)),
                        viewportHeight: Double(afterFrame?.viewportHeight ?? Int(actionRes.observation?.pageState?.viewportHeight ?? 800))
                    )
                    if let vr = verifyRes {
                        actionRes.visualVerification = vr
                        if vr.verified == false && actionRes.agentFeedback == nil {
                            actionRes.agentFeedback = AgentFeedback(
                                severity: "warning",
                                trigger: "visual_verify_failed",
                                diagnosis: vr.answer,
                                suggestedAction: "Inspect the local verification result or call vision_query(mode: 'ask') before retrying.",
                                source: vr.backend,
                                latencyMs: vr.latencyMs
                            )
                        }
                        enrichedActionResult = actionRes
                    }
                }
            }

            if let shot = responseScreenshot {
                enrichedActionResult?.screenshot = shot
                if enrichedActionResult?.observation != nil && enrichedActionResult?.observation?.screenshotPath == nil {
                    enrichedActionResult?.observation?.screenshotPath = shot.path
                }
            }
            let stepCount = enrichedActionResult?.stepResults.count ?? params.steps.count
            let actionSuccess = enrichedActionResult?.success ?? true
            incrementActionCount(by: stepCount)
            appendAudit(
                method: request.method.rawValue,
                targetApp: resolvedLabel,
                summary: "Executed \(stepCount) browser step(s): \(actionSuccess ? "ok" : "failed") · \(AuditRedactor.describeSteps(params.steps))",
                latencyMs: latencyMs,
                success: actionSuccess
            )
            let browserFailure = actionSuccess ? nil : ActivityCaption.batchFailure(
                steps: params.steps,
                results: enrichedActionResult?.stepResults ?? [],
                inBrowser: true,
                elementName: { id in (bridgeResp.snapshot ?? enrichedActionResult?.observation)?.elements.first(where: { $0.id == id })?.title }
            )
            emitLiveActivity(LiveActivityItem(
                kind: .actionComplete,
                appName: resolvedLabel,
                windowTitle: bridgeResp.title,
                title: browserFailure?.title
                    ?? "Finished \(stepCount) browser step\(stepCount == 1 ? "" : "s")",
                subtitle: browserFailure.map { $0.reason } ?? bridgeResp.url,
                latencyMs: enrichedActionResult?.totalLatencyMs ?? latencyMs,
                success: actionSuccess,
                isInProgress: false,
                browserTabId: resolvedTabId,
                browserProfile: resolvedProfile
            ))
            return .success(
                id: request.id,
                latencyMs: latencyMs,
                snapshot: bridgeResp.snapshot ?? enrichedActionResult?.observation,
                actionResult: enrichedActionResult,
                screenshot: responseScreenshot,
                browserTabId: bridgeResp.tabId,
                browserUrl: bridgeResp.url,
                browserTitle: bridgeResp.title
            )
        } else {
            let code = bridgeResp.error?.code ?? "BROWSER_ACT_FAILED"
            let message = bridgeResp.error?.message ?? "Failed to execute browser action"
            appendAudit(method: request.method.rawValue, targetApp: resolvedLabel, summary: message, latencyMs: latencyMs, success: false)
            let failedSteps = bridgeResp.actionResult.map { ActivityCaption.batchFailure(steps: params.steps, results: $0.stepResults, inBrowser: true) }
            emitLiveActivity(LiveActivityItem(
                kind: .actionComplete,
                appName: resolvedLabel,
                title: failedSteps?.title ?? "Couldn't act in Chrome",
                subtitle: ActivityCaption.reason(errorCode: code, message: message, inBrowser: true) ?? failedSteps?.reason ?? message,
                latencyMs: latencyMs,
                success: false,
                isInProgress: false
            ))
            return .failure(id: request.id, code: code, message: message, latencyMs: latencyMs, hint: bridgeResp.error?.hint)
        }
    }

    func handleBrowserBatch(_ request: RPCRequest, startNs: UInt64) async -> RPCResponse {
        guard let params = request.browserBatch, !params.urls.isEmpty else {
            let latencyMs = elapsedMs(since: startNs)
            return .failure(id: request.id, code: "INVALID_REQUEST", message: "browser_batch requires a non-empty urls array.", latencyMs: latencyMs)
        }

        let batchMode = (params.mode ?? "observe").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let extractMode = (params.extractMode ?? "auto").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if extractMode == "downloads" {
            return .failure(
                id: request.id,
                code: "INVALID_ARGUMENT",
                message: "Downloads are listed per Chrome profile. Use browser_extract with mode=\"downloads\" instead of browser_batch.",
                latencyMs: elapsedMs(since: startNs)
            )
        }
        let isEvalMode = (batchMode == "extract" && extractMode == "eval")
        let isMutatingBatch = isEvalMode || params.autoDismissOverlays == true

        if let blockReason = killSwitch.isBlocked(forSensitiveAction: isEvalMode, isMutatingAction: isMutatingBatch) {
            return blockedPolicyResponse(
                request: request,
                startNs: startNs,
                targetApp: params.profile ?? "Chrome",
                activityAppName: "Chrome (\(params.profile ?? "Browser"))",
                activityTitle: "Browser batch blocked",
                reason: blockReason
            )
        }
        if TargetRulesStore.shared.rules.blocksBrowser {
            return targetBlockedResponse(
                request: request,
                startNs: startNs,
                targetApp: params.profile ?? "Chrome",
                activityTitle: "Browser batch blocked",
                message: TargetRules.blockedBrowserMessage
            )
        }

        let taskId = request.namedTaskId ?? TaskActivityContext.taskId
        let rules = TargetRulesStore.shared.rules
        let profile = params.profile
        let maxElements = params.maxElements
        let autoDismiss = params.autoDismissOverlays
        let deferDismissForSiteRules = rules.hasGovernedSiteRules && autoDismiss == true
        let closeAfter = params.closeAfter == true
        let bridge = self.chromeBridge

        var indexedResults: [(Int, BrowserBatchItemResult, Int?)] = []
        indexedResults.reserveCapacity(params.urls.count)

        let maxBatchConcurrency = 3
        let urls = params.urls

        await withTaskGroup(of: (Int, BrowserBatchItemResult, Int?).self) { group in
            var nextIndex = 0

            func enqueueItem(at index: Int) {
                let rawUrl = urls[index]
                group.addTask {
                    let itemStart = DispatchTime.now().uptimeNanoseconds
                    func itemElapsed() -> Double {
                        ((Double(DispatchTime.now().uptimeNanoseconds - itemStart) / 1_000_000.0) * 100).rounded() / 100
                    }

                    let normalizedUrl: String
                    switch NavigationPolicy.validate(rawUrl) {
                    case .success(let valid):
                        normalizedUrl = valid
                    case .failure(let blocked):
                        return (index, BrowserBatchItemResult(
                            url: rawUrl,
                            tabId: nil,
                            success: false,
                            error: "URL_BLOCKED: \(blocked.message)",
                            latencyMs: itemElapsed()
                        ), nil)
                    }

                    if rules.blocksURL(normalizedUrl) {
                        let msg = TargetRules.blockedSiteMessage(host: TargetRules.host(ofURL: normalizedUrl))
                        return (index, BrowserBatchItemResult(
                            url: normalizedUrl,
                            tabId: nil,
                            success: false,
                            error: "\(TargetRules.errorCode): \(msg)",
                            latencyMs: itemElapsed()
                        ), nil)
                    }

                    let openResp = await self.openBrowserTab(BrowserOpenParams(
                        url: normalizedUrl,
                        profile: profile,
                        newTab: true,
                        stream: false,
                        taskId: taskId,
                        autoDismissOverlays: deferDismissForSiteRules ? nil : autoDismiss,
                        observationMode: (batchMode == "extract" && !deferDismissForSiteRules) ? ObservationMode.none : nil
                    ), taskId: taskId, recordOwnership: !closeAfter)
                    guard openResp.ok, let openedTabId = openResp.tabId else {
                        let code = openResp.error?.code ?? "BROWSER_OPEN_FAILED"
                        let message = openResp.error?.message ?? "Failed to open URL"
                        return (index, BrowserBatchItemResult(
                            url: normalizedUrl,
                            tabId: openResp.tabId,
                            success: false,
                            error: "\(code): \(message)",
                            latencyMs: itemElapsed()
                        ), openResp.tabId)
                    }

                    let resolvedProf = openResp.profileName ?? profile
                    var effectiveSnapshot = openResp.snapshot

                    // When governed site rules are active, dismiss overlays only after the landed redirect URL passed TargetRules as .allow.
                    if deferDismissForSiteRules,
                       openResp.restricted != true,
                       rules.effectiveSitePolicy(url: openResp.url ?? normalizedUrl) == .allow,
                       let ov = openResp.snapshot?.pageState?.blockingOverlay {
                        var dismissStep: ActionStep?
                        if let closeId = ov.closeElementId, !closeId.isEmpty {
                            dismissStep = ActionStep(action: .click, elementId: closeId, optional: true)
                        } else if let cx = ov.closeX, let cy = ov.closeY, cx.isFinite, cy.isFinite {
                            dismissStep = ActionStep(action: .click, x: cx, y: cy, optional: true)
                        }
                        if let step = dismissStep {
                            let dismissResp = await bridge.act(BrowserActParams(
                                profile: resolvedProf,
                                tabId: openedTabId,
                                steps: [step],
                                returnObservation: batchMode != "extract"
                            ))
                            if dismissResp.ok, let refreshed = dismissResp.snapshot ?? dismissResp.actionResult?.observation {
                                effectiveSnapshot = refreshed
                            }
                        }
                    }

                    if batchMode == "extract" {
                        let extParams = BrowserExtractParams(
                            profile: resolvedProf,
                            tabId: openedTabId,
                            mode: extractMode
                        )
                        if isEvalMode, rules.effectiveSitePolicy(url: openResp.url ?? normalizedUrl) == .ask {
                            let itemExtractReq = RPCRequest(
                                id: request.id,
                                method: .browserExtract,
                                browserExtract: extParams,
                                taskId: taskId,
                                agent: request.agent
                            )
                            if let refusal = await self.approvalRefusal(for: itemExtractReq, startNs: itemStart) {
                                let code = refusal.error?.code ?? "APPROVAL_DENIED"
                                let msg = refusal.error?.message ?? "Approval refused"
                                return (index, BrowserBatchItemResult(
                                    url: openResp.url ?? normalizedUrl,
                                    tabId: openedTabId,
                                    success: false,
                                    error: "\(code): \(msg)",
                                    latencyMs: itemElapsed()
                                ), openedTabId)
                            }
                        }
                        let extResp = await bridge.extract(extParams)
                        if extResp.ok {
                            return (index, BrowserBatchItemResult(
                                url: openResp.url ?? normalizedUrl,
                                tabId: openedTabId,
                                success: true,
                                extract: extResp.extractResult,
                                latencyMs: itemElapsed()
                            ), openedTabId)
                        } else {
                            let code = extResp.error?.code ?? "BROWSER_EXTRACT_FAILED"
                            let msg = extResp.error?.message ?? "Failed to extract page"
                            return (index, BrowserBatchItemResult(
                                url: openResp.url ?? normalizedUrl,
                                tabId: openedTabId,
                                success: false,
                                error: "\(code): \(msg)",
                                latencyMs: itemElapsed()
                            ), openedTabId)
                        }
                    } else {
                        var snap = effectiveSnapshot
                        if snap == nil {
                            let obsResp = await bridge.observe(BrowserObserveParams(
                                profile: resolvedProf,
                                tabId: openedTabId,
                                maxElements: maxElements
                            ))
                            if !obsResp.ok {
                                let code = obsResp.error?.code ?? "BROWSER_OBSERVE_FAILED"
                                let msg = obsResp.error?.message ?? "Failed to observe page"
                                return (index, BrowserBatchItemResult(
                                    url: openResp.url ?? normalizedUrl,
                                    tabId: openedTabId,
                                    success: false,
                                    error: "\(code): \(msg)",
                                    latencyMs: itemElapsed()
                                ), openedTabId)
                            }
                            snap = obsResp.snapshot
                        }
                        return (index, BrowserBatchItemResult(
                            url: openResp.url ?? normalizedUrl,
                            tabId: openedTabId,
                            success: true,
                            snapshot: snap,
                            latencyMs: itemElapsed()
                        ), openedTabId)
                    }
                }
            }

            let initialCount = min(maxBatchConcurrency, urls.count)
            while nextIndex < initialCount {
                enqueueItem(at: nextIndex)
                nextIndex += 1
            }

            for await item in group {
                indexedResults.append(item)
                if nextIndex < urls.count {
                    enqueueItem(at: nextIndex)
                    nextIndex += 1
                }
            }
        }

        indexedResults.sort { $0.0 < $1.0 }
        let items = indexedResults.map(\.1)
        let openedTabIds = indexedResults.compactMap(\.2)
        if closeAfter, !openedTabIds.isEmpty {
            _ = await chromeBridge.closeOwnedTabs(profile: profile, keepTabIds: [], closeTabIds: openedTabIds)
            for tid in openedTabIds {
                taskTabs.forgetTab(tid)
            }
        }

        let latencyMs = elapsedMs(since: startNs)
        let okCount = items.filter(\.success).count
        let batchResult = BrowserBatchResult(results: items, totalLatencyMs: (latencyMs * 100).rounded() / 100)
        appendAudit(
            method: request.method.rawValue,
            targetApp: "Chrome (\(params.profile ?? "Browser"))",
            summary: "Batch \(batchMode) \(okCount)/\(items.count) URL(s)",
            latencyMs: latencyMs,
            success: okCount == items.count
        )
        return .success(id: request.id, latencyMs: latencyMs, browserBatchResult: batchResult)
    }

    /// Keep the open pending until its ownership is visible to a concurrent cleanup or reconnect.
    private func openBrowserTab(
        _ params: BrowserOpenParams,
        taskId: String?,
        recordOwnership: Bool = true
    ) async -> ChromeExtensionBridge.BridgeResponse {
        let createdFallback = params.tabId == nil && (params.newTab != false || params.newWindow == true)
        taskTabs.beginBrowserOpen()
        defer { taskTabs.endBrowserOpen() }
        let response = await chromeBridge.open(params)
        let didCreateTab = response.createdTab ?? (response.ok && createdFallback)
        if recordOwnership, didCreateTab, let tabId = response.tabId {
            taskTabs.recordOpenedTab(tabId, taskId: taskId, profile: response.ownershipKey ?? response.profileName ?? params.profile)
        }
        return response
    }

    /// Closes the Chrome tabs UseMac opened during the task once the completion animation has played, so the
    /// user's tab strip does not fill up with agent tabs. The extension never closes tabs the user had open,
    /// the tab the user is looking at, or tabs with a running download.
    func scheduleOwnedTabCleanup(profile: String?, keepTabIds: [Int], closeTabIds: [Int]? = nil) {
        let profiles: [String?] = {
            if let profile, !profile.isEmpty { return [profile] }
            let connected = chromeBridge.connectedProfiles().map(\.profileName)
            return connected.isEmpty ? [] : connected.map { Optional($0) }
        }()
        guard !profiles.isEmpty else { return }
        let delayNs = self.ownedTabCleanupDelayNs
        Task { [chromeBridge, taskTabs] in
            if delayNs > 0 {
                try? await Task.sleep(nanoseconds: delayNs)
            }
            if closeTabIds == nil {
                for _ in 0..<15 {
                    guard taskTabs.hasPendingBrowserOpen else { break }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                guard !taskTabs.hasPendingBrowserOpen else { return }
            }
            for name in profiles {
                // The previous profile's response could have taken long enough for a new open to start.
                if closeTabIds == nil && taskTabs.hasPendingBrowserOpen { return }
                let keep = Set(keepTabIds).union(taskTabs.protectedTabIds()).sorted()
                _ = await chromeBridge.closeOwnedTabs(profile: name, keepTabIds: keep, closeTabIds: closeTabIds)
            }
        }
    }
}
