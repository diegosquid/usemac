import Foundation
import XCTest
@testable import UseMacEngine
@testable import UseMacProtocol

/// UseMac never observes or acts on its own windows (Settings, the setup guide); only the user changes its settings.
/// The decision is pure and tested here without NSWorkspace; the service tests only name UseMac directly
/// (by name, bundle ID or this test process's PID), so they do not depend on what is running.
final class SelfTargetTests: XCTestCase {
    private let selfPid: Int32 = 4242
    private let bundleId = WorkspaceMonitor.useMacBundleId

    private func app(_ pid: Int32, _ name: String, bundleId: String?, active: Bool = false) -> AppDescriptor {
        AppDescriptor(pid: pid, name: name, bundleId: bundleId, isActive: active)
    }

    /// Sorted like `listRunningApps()`: the active app first. UseMac is active because its Settings are open.
    private var running: [AppDescriptor] {
        [
            app(selfPid, "UseMac", bundleId: bundleId, active: true),
            app(500, "TextEdit", bundleId: "com.apple.TextEdit"),
            app(600, "Google Chrome", bundleId: "com.google.Chrome")
        ]
    }

    // MARK: isUseMac / excludingUseMac

    func testOwnPidIsUseMacWhateverItsBundleId() {
        XCTAssertTrue(WorkspaceMonitor.isUseMac(pid: selfPid, bundleId: bundleId, selfPid: selfPid))
        // `swift run` without an app bundle has no bundle ID.
        XCTAssertTrue(WorkspaceMonitor.isUseMac(pid: selfPid, bundleId: nil, selfPid: selfPid))
    }

    func testUseMacBundleIdUnderAnotherPidIsUseMac() {
        // A `--standalone` CLI runs in its own process, so the app it must not target has another PID.
        XCTAssertTrue(WorkspaceMonitor.isUseMac(pid: 777, bundleId: "app.usemac", selfPid: selfPid))
        XCTAssertTrue(WorkspaceMonitor.isUseMac(pid: 777, bundleId: "App.UseMac", selfPid: selfPid))
    }

    func testOtherAppsAreNotUseMac() {
        XCTAssertFalse(WorkspaceMonitor.isUseMac(pid: 500, bundleId: "com.apple.TextEdit", selfPid: selfPid))
        XCTAssertFalse(WorkspaceMonitor.isUseMac(pid: 501, bundleId: nil, selfPid: selfPid))
        XCTAssertFalse(WorkspaceMonitor.isUseMac(pid: 502, bundleId: "app.usemac.helper", selfPid: selfPid))
    }

    func testExcludingUseMacDropsOnlyUseMac() {
        let appSeenFromStandaloneCLI = app(777, "UseMac", bundleId: bundleId)
        let filtered = WorkspaceMonitor.excludingUseMac(running + [appSeenFromStandaloneCLI], selfPid: selfPid)
        XCTAssertEqual(filtered.map(\.pid), [500, 600])
    }

    // MARK: matchQuery

    func testQueryNamingUseMacIsRefused() {
        for query in ["UseMac", "usemac", "  UseMac ", "app.usemac", "APP.USEMAC", "\(selfPid)", "UseM"] {
            XCTAssertEqual(WorkspaceMonitor.matchQuery(query, in: running, selfPid: selfPid), .useMac, "query \(query)")
        }
    }

    func testLooseQueryThatLandsOnUseMacIsRefusedNotRedirected() {
        // "mac" would have matched UseMac first; it must not quietly fall through to another app.
        XCTAssertEqual(WorkspaceMonitor.matchQuery("mac", in: running, selfPid: selfPid), .useMac)
    }

    func testQueryNamingUseMacIsRefusedWhenItIsNotListed() {
        // With its windows closed UseMac is an accessory app, so it is not in the running list at all.
        let others = WorkspaceMonitor.excludingUseMac(running, selfPid: selfPid)
        for query in ["UseMac", "app.usemac", "\(selfPid)"] {
            XCTAssertEqual(WorkspaceMonitor.matchQuery(query, in: others, selfPid: selfPid), .useMac, "query \(query)")
        }
    }

    func testStandaloneCLIQueryForTheAppPidIsRefused() {
        let apps = [app(777, "UseMac", bundleId: bundleId), app(500, "TextEdit", bundleId: "com.apple.TextEdit")]
        XCTAssertEqual(WorkspaceMonitor.matchQuery("777", in: apps, selfPid: selfPid), .useMac)
    }

    func testQueriesForOtherAppsStillResolve() {
        let textEdit = running[1]
        let chrome = running[2]
        XCTAssertEqual(WorkspaceMonitor.matchQuery("TextEdit", in: running, selfPid: selfPid), .app(textEdit))
        XCTAssertEqual(WorkspaceMonitor.matchQuery("com.google.Chrome", in: running, selfPid: selfPid), .app(chrome))
        XCTAssertEqual(WorkspaceMonitor.matchQuery("600", in: running, selfPid: selfPid), .app(chrome))
        XCTAssertEqual(WorkspaceMonitor.matchQuery("chrome", in: running, selfPid: selfPid), .app(chrome))
        XCTAssertEqual(WorkspaceMonitor.matchQuery("Pages", in: running, selfPid: selfPid), .notFound)
        XCTAssertEqual(WorkspaceMonitor.matchQuery("999", in: running, selfPid: selfPid), .notFound)
        XCTAssertEqual(WorkspaceMonitor.matchQuery("   ", in: running, selfPid: selfPid), .notFound)
    }

    // MARK: Engine and executor

    /// Queries that name this test process (UseMac's engine runs here) or the UseMac app.
    private var ownQueries: [String] {
        ["UseMac", WorkspaceMonitor.useMacBundleId, String(ProcessInfo.processInfo.processIdentifier)]
    }

    private func makeService() -> UseMacEngineService {
        UseMacEngineService(socketPath: "/tmp/usemac-self-\(UUID().uuidString.prefix(8)).sock", extensionPort: 0)
    }

    func testServiceRefusesRequestsThatNameUseMac() async {
        let service = makeService()
        let wait = ActionStep(action: .wait, durationMs: 1)
        for query in ownQueries {
            let requests: [(name: String, request: RPCRequest)] = [
                ("observe", RPCRequest(method: .observe, observe: ObserveParams(app: query))),
                ("act", RPCRequest(method: .act, act: BatchActionRequest(app: query, steps: [wait], returnObservation: false))),
                ("act step", RPCRequest(method: .act, act: BatchActionRequest(
                    app: "no-such-app-\(UUID().uuidString)",
                    steps: [ActionStep(action: .wait, app: query, durationMs: 1)],
                    returnObservation: false
                ))),
                ("screenshot", RPCRequest(method: .screenshot, screenshot: ScreenshotRequest(app: query))),
                ("pair_app", RPCRequest(method: .pairApp, appTarget: query)),
                ("vision_query", RPCRequest(method: .visionQuery, visionQuery: VisionQueryParams(mode: "ask", query: "status", app: query)))
            ]
            for (name, request) in requests {
                let res = await service.handle(request)
                XCTAssertFalse(res.ok, "\(name) with \(query) should be refused")
                XCTAssertEqual(res.error?.code, "SELF_TARGET_BLOCKED", "\(name) with \(query)")
            }
        }
        XCTAssertNil(service.getPairedApp())
    }

    func testListAppsNeverListsUseMac() async {
        let service = makeService()
        let res = await service.handle(RPCRequest(method: .listApps))
        XCTAssertTrue(res.ok)
        let ownPid = ProcessInfo.processInfo.processIdentifier
        let listed = (res.apps ?? []).filter { WorkspaceMonitor.isUseMac(pid: $0.pid, bundleId: $0.bundleId, selfPid: ownPid) }
        XCTAssertTrue(listed.isEmpty, "list_apps listed UseMac: \(listed.map(\.name))")
    }

    func testExecutorRefusesBatchThatNamesUseMac() async {
        let executor = ActionExecutor(axIndexer: AXIndexer(), workspaceMonitor: WorkspaceMonitor(), killSwitch: KillSwitch())
        for query in ownQueries {
            let request = BatchActionRequest(app: query, steps: [ActionStep(action: .wait, durationMs: 1)], returnObservation: false)
            let (result, resolvedApp) = await executor.executeBatch(request)
            XCTAssertFalse(result.success, "query \(query)")
            XCTAssertNil(resolvedApp, "query \(query)")
            XCTAssertEqual(result.stepResults.first?.errorCode, "SELF_TARGET_BLOCKED", "query \(query)")
        }
    }
}
