import Foundation
import UseMacProtocol

extension UseMacEngineService {
    // MARK: - The setting (app only)

    /// Whether the user turned on Debug capture in Settings.
    public var isDebugCaptureEnabled: Bool {
        debugCaptureGate.isEnabled
    }

    /// Turns Debug capture on or off. Only the app calls this, in-process, with what the user chose in Settings (or
    /// what it saved, at launch). No RPC method, MCP tool or CLI command reaches it. `recordInHistory` adds an
    /// audit entry when the value changes; the app leaves it off when it restores the saved value at launch.
    public func setDebugCaptureEnabled(_ enabled: Bool, recordInHistory: Bool = true) {
        let changed = debugCaptureGate.setEnabled(enabled)
        guard changed, recordInHistory else { return }
        appendAudit(
            method: DebugCaptureNotice.settingAuditMethod,
            targetApp: nil,
            summary: enabled ? "Turned on by the user in Settings" : "Turned off",
            latencyMs: 0,
            success: true
        )
        onStateChanged?()
    }

    /// The app lists its windows here (which one is the live preview, which one Settings, …). It is called off the
    /// main thread, once per frame of a capture.
    public func setDebugCaptureWindowProvider(_ provider: DebugCaptureGate.WindowProvider?) {
        debugCaptureGate.setWindowProvider(provider)
    }

    // MARK: - debug_capture

    /// `debug_capture`: PNGs of UseMac's own windows, for developing UseMac. Refused with `DEBUG_CAPTURE_OFF` unless
    /// the user turned it on; there is no other route. The caller has already checked the Kill Switch and pause.
    func handleDebugCapture(_ request: RPCRequest, startNs: UInt64) async -> RPCResponse {
        let elapsed = { Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000 }
        let selfName = WorkspaceMonitor.useMacAppName

        guard debugCaptureGate.isEnabled else {
            let latencyMs = elapsed()
            appendAudit(method: request.method.rawValue, targetApp: selfName, summary: "Blocked: Debug capture is off", latencyMs: latencyMs, success: false)
            onLiveActivity?(LiveActivityItem(
                kind: .policyOrSafety,
                title: "Debug capture is off",
                subtitle: "An agent asked to capture UseMac's windows. Turn it on in Settings → Developer if you want that.",
                latencyMs: latencyMs,
                success: false,
                isInProgress: false
            ))
            return .failure(
                id: request.id,
                code: DebugCaptureNotice.offCode,
                message: DebugCaptureNotice.offMessage,
                latencyMs: latencyMs,
                hint: DebugCaptureNotice.offHint
            )
        }

        let options: DebugCaptureOptions
        do {
            options = try (request.debugCapture ?? DebugCaptureParams()).resolved()
        } catch let invalid as DebugCaptureParams.InvalidWindow {
            return .failure(id: request.id, code: "INVALID_REQUEST", message: invalid.message, latencyMs: elapsed())
        } catch {
            return .failure(id: request.id, code: "INVALID_REQUEST", message: error.localizedDescription, latencyMs: elapsed())
        }

        guard currentPermissions().screenRecordingGranted else {
            let latencyMs = elapsed()
            appendAudit(method: request.method.rawValue, targetApp: selfName, summary: "Screen Recording permission denied", latencyMs: latencyMs, success: false)
            return .failure(id: request.id, code: "PERMISSION_DENIED", message: "Screen Recording permission not granted", latencyMs: latencyMs)
        }

        // No live preview activity on success: a card about the capture would change the very window being captured.
        let capturer = DebugCaptureCapturer()
        do {
            let output = try await capturer.run(options: options) { [debugCaptureGate] in
                await debugCaptureGate.windows()
            }
            let latencyMs = elapsed()
            var notes = options.notes
            // With `all`, most kinds are missing on any given day; name them only when the agent asked for them.
            if !output.missingKinds.isEmpty, options.kinds.count < DebugCaptureWindowKind.allCases.count {
                notes.append("not on screen: \(output.missingKinds.map(\.rawValue).joined(separator: ", "))")
            }
            if output.contextMissing {
                notes.append("context: the live preview was not on screen")
            }
            let result = DebugCaptureResult(
                window: options.label,
                frames: options.frames,
                intervalMs: options.intervalMs,
                directory: capturer.directory,
                images: output.images,
                latencyMs: latencyMs,
                notes: notes
            )
            appendAudit(
                method: request.method.rawValue,
                targetApp: selfName,
                summary: Self.debugCaptureSummary(result),
                latencyMs: latencyMs,
                success: true
            )
            return .success(id: request.id, latencyMs: latencyMs, debugCapture: result)
        } catch DebugCaptureCapturer.Failure.nothingOnScreen {
            let latencyMs = elapsed()
            appendAudit(method: request.method.rawValue, targetApp: selfName, summary: "Nothing on screen (\(options.label))", latencyMs: latencyMs, success: false)
            return .failure(
                id: request.id,
                code: "CAPTURE_FAILED",
                message: DebugCaptureNotice.nothingOnScreenMessage(label: options.label),
                latencyMs: latencyMs,
                hint: DebugCaptureNotice.nothingOnScreenHint
            )
        } catch {
            let latencyMs = elapsed()
            let message: String
            if case DebugCaptureCapturer.Failure.captureFailed(let reason) = error {
                message = reason
            } else {
                message = error.localizedDescription
            }
            appendAudit(method: request.method.rawValue, targetApp: selfName, summary: message, latencyMs: latencyMs, success: false)
            return .failure(id: request.id, code: "CAPTURE_FAILED", message: message, latencyMs: latencyMs)
        }
    }

    /// "Captured 3 PNG(s) of preview, settings (1 frame)". Kinds only: window titles stay out of the log.
    static func debugCaptureSummary(_ result: DebugCaptureResult) -> String {
        let kinds = Set(result.images.map(\.kind))
        let ordered = (DebugCaptureWindowKind.allCases.map(\.rawValue) + [DebugCaptureParams.contextName]).filter(kinds.contains)
        let frames = result.frames == 1 ? "1 frame" : "\(result.frames) frames, \(result.intervalMs) ms apart"
        return "Captured \(result.images.count) PNG(s) of \(ordered.joined(separator: ", ")) (\(frames))"
    }
}
