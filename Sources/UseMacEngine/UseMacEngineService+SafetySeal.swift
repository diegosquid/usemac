import Foundation

extension UseMacEngineService {
    /// Records in History what the seal check at launch found (SafetySeal.swift): the first seal, or settings changed
    /// outside UseMac. A matching seal adds nothing.
    public func recordSafetySealCheck(_ launch: SafetySettingsStore.Launch) {
        guard let summary = SafetySealNotice.auditSummary(check: launch.check, sealed: launch.sealed) else { return }
        appendAudit(
            method: SafetySealNotice.auditMethod,
            targetApp: nil,
            summary: summary,
            latencyMs: 0,
            success: launch.check.problem == nil && launch.sealed
        )
    }
}
