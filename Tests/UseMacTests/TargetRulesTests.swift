import Foundation
import XCTest
@testable import UseMacEngine
@testable import UseMacProtocol

/// The user's app and site rules (TargetRules): matching, the stored form, and the guards in the engine and the bridge.
final class TargetRulesTests: XCTestCase {
    private var savedRules: TargetRules!

    override func setUp() {
        super.setUp()
        savedRules = TargetRulesStore.shared.rules
    }

    override func tearDown() {
        TargetRulesStore.shared.update(savedRules, persist: false)
        super.tearDown()
    }

    private func use(_ rules: TargetRules) {
        TargetRulesStore.shared.update(rules, persist: false)
    }

    // MARK: - Apps

    func testDefaultsBlockPasswordManagersAndKeychain() {
        let rules = TargetRules.defaults
        for id in [
            "com.apple.keychainaccess", "com.apple.Passwords", "com.1password.1password", "com.agilebits.onepassword7",
            "com.agilebits.onepassword-osx", "com.bitwarden.desktop", "org.keepassxc.keepassxc", "com.dashlane.Dashlane"
        ] {
            XCTAssertTrue(rules.blocksApp(bundleId: id), id)
        }
        for id in ["com.apple.TextEdit", "com.google.Chrome", "com.apple.finder", nil] {
            XCTAssertFalse(rules.blocksApp(bundleId: id), id ?? "nil")
        }
        XCTAssertEqual(rules.mode, .deny)
        XCTAssertFalse(rules.blocksBrowser)
    }

    func testAppPatternsAreCaseInsensitiveWithTrailingWildcard() {
        XCTAssertTrue(TargetRules.appPattern("com.apple.TextEdit", matches: "COM.APPLE.textedit"))
        XCTAssertFalse(TargetRules.appPattern("com.apple.TextEdit", matches: "com.apple.TextEditHelper"))
        XCTAssertTrue(TargetRules.appPattern("com.vendor.*", matches: "com.vendor.app"))
        XCTAssertFalse(TargetRules.appPattern("com.vendor.*", matches: "com.vendor"))
        XCTAssertFalse(TargetRules.appPattern("*", matches: "com.anything"), "a bare * is not a pattern")
        XCTAssertFalse(TargetRules.appPattern("", matches: "com.anything"))
    }

    func testAllowModeAllowsOnlyListedAppsAndDenyStillWins() {
        let rules = TargetRules(
            mode: .allow,
            deniedApps: ["com.apple.Passwords"],
            allowedApps: ["com.apple.TextEdit", "com.apple.Passwords"]
        )
        XCTAssertFalse(rules.blocksApp(bundleId: "com.apple.TextEdit"))
        XCTAssertTrue(rules.blocksApp(bundleId: "com.apple.Passwords"), "denied wins over allowed")
        XCTAssertTrue(rules.blocksApp(bundleId: "com.apple.finder"))
        XCTAssertTrue(rules.blocksApp(bundleId: nil), "an app without a bundle ID cannot be allowed")
    }

    func testAppAndSitePoliciesUseTheMostRestrictiveMatchInBothModes() {
        for mode in TargetRules.Mode.allCases {
            let rules = TargetRules(
                mode: mode,
                deniedApps: ["com.example.block"], deniedSites: [".block.example"],
                allowedApps: ["com.example.*"], allowedSites: ["example"],
                askApps: ["com.example.ask", "com.example.read", "com.example.block", "com.ask.only"],
                askSites: ["ask.example", "read.example", "block.example", "example.net"],
                readOnlyApps: ["com.example.read", "com.example.block", "com.read.only"],
                readOnlySites: ["read.example", "block.example", "example.org"]
            )
            XCTAssertEqual(rules.effectiveAppPolicy(bundleId: "COM.EXAMPLE.BLOCK"), .block)
            XCTAssertEqual(rules.effectiveAppPolicy(bundleId: "com.example.read"), .readOnly)
            XCTAssertEqual(rules.effectiveAppPolicy(bundleId: "com.example.ask"), .ask)
            XCTAssertEqual(rules.effectiveAppPolicy(bundleId: "com.example.allow"), .allow)
            XCTAssertEqual(rules.effectiveAppPolicy(bundleId: "com.ask.only"), .ask)
            XCTAssertEqual(rules.effectiveAppPolicy(bundleId: "com.read.only"), .readOnly)
            XCTAssertEqual(rules.effectiveAppPolicy(bundleId: "com.unlisted"), mode == .allow ? .block : .allow)

            XCTAssertEqual(rules.effectiveSitePolicy(url: "https://block.example/"), .block)
            XCTAssertEqual(rules.effectiveSitePolicy(url: "https://sub.block.example/"), .readOnly)
            XCTAssertEqual(rules.effectiveSitePolicy(url: "https://read.example/"), .readOnly)
            XCTAssertEqual(rules.effectiveSitePolicy(url: "https://ask.example/"), .ask)
            XCTAssertEqual(rules.effectiveSitePolicy(url: "https://allow.example/"), .allow)
            XCTAssertEqual(rules.effectiveSitePolicy(url: "https://example.net/"), .ask)
            XCTAssertEqual(rules.effectiveSitePolicy(url: "https://example.org/"), .readOnly)
            XCTAssertEqual(rules.effectiveSitePolicy(url: "https://other.net/"), mode == .allow ? .block : .allow)
            XCTAssertEqual(rules.effectiveSitePolicy(url: "about:blank"), .allow)
            XCTAssertEqual(rules.effectiveSitePolicy(url: ""), .allow)
        }
        XCTAssertFalse(TargetRules(askSites: ["ask.example"]).hasSiteRules)
        XCTAssertTrue(TargetRules(askSites: ["ask.example"]).hasGovernedSiteRules)
        XCTAssertTrue(TargetRules(readOnlySites: ["read.example"]).hasGovernedSiteRules)
    }

    func testOldRulesJSONDecodesAndNewListsNormalize() throws {
        let json = #"{"mode":"deny","deniedApps":[],"deniedSites":[],"allowedApps":[],"allowedSites":[]}"#
        let oldRules = try JSONDecoder().decode(TargetRules.self, from: Data(json.utf8))
        XCTAssertEqual(oldRules, TargetRules())

        let rules = TargetRules(
            askApps: [" COM.EXAMPLE.* ", "com.example.*", "*"],
            askSites: ["https://ASK.Example/path", "ask.example"],
            readOnlyApps: [" com.example.app ", "com.example.app"],
            readOnlySites: ["https://READ.example/path", "read.example"]
        ).normalized()
        XCTAssertEqual(rules.askApps, ["COM.EXAMPLE.*"])
        XCTAssertEqual(rules.askSites, ["ask.example"])
        XCTAssertEqual(rules.readOnlyApps, ["com.example.app"])
        XCTAssertEqual(rules.readOnlySites, ["read.example"])
        XCTAssertEqual(try JSONDecoder().decode(TargetRules.self, from: JSONEncoder().encode(rules)), rules)
    }

    func testDenyingChromeBlocksTheBrowserTools() {
        XCTAssertTrue(TargetRules(deniedApps: ["com.google.Chrome"]).blocksBrowser)
        XCTAssertTrue(TargetRules(deniedApps: ["com.google.*"]).blocksBrowser)
        XCTAssertFalse(TargetRules(mode: .allow, allowedSites: ["example.com"]).blocksBrowser, "allow mode needs no Chrome entry")
        XCTAssertTrue(TargetRules(deniedApps: ["com.google.Chrome"]).hasSiteRules)
    }

    func testVisibleAppsLeavesBlockedAppsOut() {
        let apps = [
            AppDescriptor(pid: 1, name: "TextEdit", bundleId: "com.apple.TextEdit", isActive: false),
            AppDescriptor(pid: 2, name: "1Password", bundleId: "com.1password.1password", isActive: true),
            AppDescriptor(pid: 3, name: "Keychain Access", bundleId: "com.apple.keychainaccess", isActive: false)
        ]
        XCTAssertEqual(TargetRules.defaults.visibleApps(apps).map(\.pid), [1])
    }

    // MARK: - Sites

    func testSitePatternMatchesHostAndSubdomains() {
        let rules = TargetRules(deniedSites: ["bank.com"])
        XCTAssertTrue(rules.blocksURL("https://bank.com/login"))
        XCTAssertTrue(rules.blocksURL("https://www.bank.com/"))
        XCTAssertTrue(rules.blocksURL("http://a.b.BANK.com:8443/x"))
        XCTAssertFalse(rules.blocksURL("https://notbank.com/"))
        XCTAssertFalse(rules.blocksURL("https://bank.com.evil.example/"))
        XCTAssertFalse(rules.blocksURL("https://example.com/?next=https://bank.com"))
    }

    func testLeadingDotMeansThatHostOnly() {
        let rules = TargetRules(deniedSites: [".bank.com"])
        XCTAssertTrue(rules.blocksURL("https://bank.com/"))
        XCTAssertFalse(rules.blocksURL("https://www.bank.com/"))
    }

    func testPortPatternsMatchOnlyThatPort() {
        let rules = TargetRules(deniedSites: ["127.0.0.1:8123", "[::1]:9000", "secure.example:443"])
        XCTAssertTrue(rules.blocksURL("http://127.0.0.1:8123/"))
        XCTAssertFalse(rules.blocksURL("http://127.0.0.1:8124/"))
        XCTAssertTrue(rules.blocksURL("http://[::1]:9000/index.html"))
        XCTAssertTrue(rules.blocksURL("https://secure.example/"), "https without a port is 443")
        XCTAssertFalse(rules.blocksURL("http://secure.example/"))

        let anyPort = TargetRules(deniedSites: ["127.0.0.1"])
        XCTAssertTrue(anyPort.blocksURL("http://127.0.0.1:8123/"))
        XCTAssertTrue(anyPort.blocksURL("http://127.0.0.1/"))
    }

    func testUnknownAndBlankPagesAreNeverBlockedInDenyMode() {
        let rules = TargetRules(deniedSites: ["bank.com"])
        for url in [nil, "", "about:blank", "chrome://newtab/", "file:///Users/x/a.html"] {
            XCTAssertFalse(rules.blocksURL(url), url ?? "nil")
        }
    }

    func testAllowModeBlocksEverySiteNotListed() {
        let rules = TargetRules(mode: .allow, deniedSites: ["admin.example.com"], allowedSites: ["example.com"])
        XCTAssertFalse(rules.blocksURL("https://example.com/"))
        XCTAssertFalse(rules.blocksURL("https://docs.example.com/"))
        XCTAssertTrue(rules.blocksURL("https://admin.example.com/"), "denied wins over allowed")
        XCTAssertTrue(rules.blocksURL("https://other.org/"))
        XCTAssertTrue(rules.blocksURL("file:///etc/hosts"), "a page without a host is not on an allowed site")
        XCTAssertFalse(rules.blocksURL("about:blank"))
        XCTAssertFalse(rules.blocksURL(nil), "an unknown URL is left to the result check")
    }

    func testVisibleTabsLeavesBlockedTabsOut() {
        let tabs = [
            BrowserTabInfo(tabId: 1, title: "Mail", url: "https://mail.example.com/"),
            BrowserTabInfo(tabId: 2, title: "Vault", url: "https://my.1password.com/vaults"),
            BrowserTabInfo(tabId: 3, title: "Passwords", url: "https://passwords.google.com/")
        ]
        XCTAssertEqual(TargetRules.defaults.visibleTabs(tabs).map(\.tabId), [1])
    }

    // MARK: - What the user types

    func testSitePatternsAreNormalizedFromWhatUsersPaste() {
        XCTAssertEqual(TargetRules.normalizedSitePattern("https://Bank.com/login?x=1"), "bank.com")
        XCTAssertEqual(TargetRules.normalizedSitePattern("  www.Bank.com.  "), "www.bank.com")
        XCTAssertEqual(TargetRules.normalizedSitePattern("*.bank.com"), "bank.com")
        XCTAssertEqual(TargetRules.normalizedSitePattern(".bank.com"), ".bank.com")
        XCTAssertEqual(TargetRules.normalizedSitePattern("http://127.0.0.1:8000/"), "127.0.0.1:8000")
        XCTAssertEqual(TargetRules.normalizedSitePattern("[::1]:9000"), "[::1]:9000")
        XCTAssertEqual(TargetRules.normalizedSitePattern("user@host.example"), "host.example")
        for bad in ["", "   ", "bank .com", "bank.com:99999", "bank.com:abc", "*"] {
            XCTAssertNil(TargetRules.normalizedSitePattern(bad), bad)
        }
    }

    func testAppPatternsAreValidated() {
        XCTAssertEqual(TargetRules.normalizedAppPattern(" com.example.App "), "com.example.App")
        XCTAssertEqual(TargetRules.normalizedAppPattern("com.example.*"), "com.example.*")
        for bad in ["", "com example", "/Applications/X.app", "*", "com.*.app"] {
            XCTAssertNil(TargetRules.normalizedAppPattern(bad), bad)
        }
    }

    func testNormalizedDropsInvalidEntriesAndDuplicates() {
        let rules = TargetRules(
            deniedApps: ["com.a.b", "COM.A.B", "bad id"],
            deniedSites: ["https://bank.com/", "bank.com", "  "]
        ).normalized()
        XCTAssertEqual(rules.deniedApps, ["com.a.b"])
        XCTAssertEqual(rules.deniedSites, ["bank.com"])
    }

    // MARK: - Storage

    func testStoreUsesDefaultsUntilListsAreSaved() throws {
        let suite = "usemac.tests.rules.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(TargetRulesStore(defaults: defaults).rules, TargetRules.defaults)

        // What `defaults write app.usemac usemac.rules.deniedApps -array …` stores.
        defaults.set(["com.apple.TextEdit"], forKey: "usemac.rules.deniedApps")
        defaults.set([String](), forKey: "usemac.rules.deniedSites")
        defaults.set("allow", forKey: "usemac.rules.mode")
        let loaded = TargetRulesStore(defaults: defaults).rules
        XCTAssertEqual(loaded.deniedApps, ["com.apple.TextEdit"])
        XCTAssertEqual(loaded.deniedSites, [], "a saved empty list stays empty")
        XCTAssertEqual(loaded.mode, .allow)

        // Saving goes through the sealed settings (SafetySettingsStore.saveRules), never straight to the preferences.
        let store = TargetRulesStore(defaults: defaults)
        var persisted: TargetRules?
        store.persistHandler = { persisted = $0 }
        store.update(TargetRules(deniedSites: ["https://bank.com/x"]))
        XCTAssertEqual(persisted?.deniedSites, ["bank.com"])
        XCTAssertEqual(store.rules.deniedSites, ["bank.com"])
        XCTAssertEqual(defaults.stringArray(forKey: "usemac.rules.deniedSites"), [], "unchanged: only the handler saves")

        persisted = nil
        store.update(TargetRules.defaults, persist: false)
        XCTAssertNil(persisted, "the app's launch replaces the rules without saving them")
    }

    func testNoRPCMethodEditsTheRules() {
        // Like relaxing the execution mode, the rules are edited only in the app.
        for name in ["set_rules", "set_target_rules", "update_rules", "rules", "target_rules", "set_app_rules", "set_site_rules"] {
            XCTAssertNil(RPCMethod(rawValue: name), name)
        }
    }

    // MARK: - Engine guards

    private func makeService(bridgeKeyDirectory: URL? = nil) -> UseMacEngineService {
        UseMacEngineService(socketPath: "/tmp/usemac-rules-\(UUID().uuidString.prefix(8)).sock", extensionPort: 0, bridgeKeyDirectory: bridgeKeyDirectory)
    }

    /// Finder runs in every GUI session; the native guards are checked against it.
    private func runningFinder() throws -> AppDescriptor {
        guard let finder = WorkspaceMonitor().listRunningApps().first(where: { $0.bundleId == "com.apple.finder" }) else {
            throw XCTSkip("Finder is not running")
        }
        return finder
    }

    func testServiceRefusesNativeRequestsForABlockedApp() async throws {
        let finder = try runningFinder()
        use(TargetRules(deniedApps: ["com.apple.finder"]))
        let service = makeService()
        let wait = ActionStep(action: .wait, durationMs: 1)
        let requests: [(name: String, request: RPCRequest)] = [
            ("observe", RPCRequest(method: .observe, observe: ObserveParams(app: "Finder"))),
            ("observe by pid", RPCRequest(method: .observe, observe: ObserveParams(app: String(finder.pid)))),
            ("act", RPCRequest(method: .act, act: BatchActionRequest(app: "Finder", steps: [wait], returnObservation: false))),
            ("act step", RPCRequest(method: .act, act: BatchActionRequest(
                app: "no-such-app-\(UUID().uuidString)",
                steps: [ActionStep(action: .wait, app: "com.apple.finder", durationMs: 1)],
                returnObservation: false
            ))),
            ("screenshot", RPCRequest(method: .screenshot, screenshot: ScreenshotRequest(app: "Finder"))),
            ("pair_app", RPCRequest(method: .pairApp, appTarget: "Finder")),
            ("vision_query", RPCRequest(method: .visionQuery, visionQuery: VisionQueryParams(mode: "ask", query: "status", app: "Finder")))
        ]
        for (name, request) in requests {
            let res = await service.handle(request)
            XCTAssertFalse(res.ok, "\(name) should be refused")
            XCTAssertEqual(res.error?.code, "TARGET_BLOCKED", name)
            XCTAssertTrue(res.error?.message.contains("Stop and tell the user") == true, name)
        }
        XCTAssertNil(service.getPairedApp())

        let listed = await service.handle(RPCRequest(method: .listApps))
        XCTAssertTrue(listed.ok)
        XCTAssertFalse((listed.apps ?? []).contains { $0.bundleId == "com.apple.finder" }, "list_apps listed a blocked app")

        let audit = service.recentAuditEntries(limit: 50)
        XCTAssertTrue(audit.contains { $0.summary == "Blocked by the app and site rules" && !$0.success })
    }

    func testAskAppHoldsNonSensitiveStepsInAutonomousModeAndRedactsTypedText() async throws {
        let app = try runningFinder()
        let bundleId = try XCTUnwrap(app.bundleId)
        use(TargetRules(askApps: [bundleId]))
        let service = makeService()
        service.setGovernancePolicy(.autonomous)

        async let result = service.handle(RPCRequest(method: .act, act: BatchActionRequest(
            app: bundleId, steps: [ActionStep(action: .type, text: "private text")]
        )))
        let shown = await waitForBridgeCondition { service.approvals.currentPrompt != nil }
        XCTAssertTrue(shown)
        let prompt = try XCTUnwrap(service.approvals.currentPrompt)
        XCTAssertEqual(prompt.kinds, [.targetRule])
        XCTAssertTrue(prompt.target.contains(app.name))
        XCTAssertTrue(prompt.steps.joined().contains("12 chars"))
        XCTAssertFalse(prompt.steps.joined().contains("private text"))

        // Moving between non-blocking modes doesn't cancel a prompt required by a target.
        service.setGovernancePolicy(.confirmSensitive)
        let click = ApprovalInputCheck.PhysicalClick(sourcePid: 0, downTime: 1, upTime: 1.1)
        XCTAssertTrue(service.approvals.decide(promptId: prompt.id, decision: .deny, click: click))
        let refusal = await result
        XCTAssertEqual(refusal.error?.code, "APPROVAL_DENIED")
    }

    func testExecutorRefusesABatchOnABlockedApp() async throws {
        _ = try runningFinder()
        use(TargetRules(deniedApps: ["com.apple.finder"]))
        let executor = ActionExecutor(axIndexer: AXIndexer(), workspaceMonitor: WorkspaceMonitor(), killSwitch: KillSwitch())
        let request = BatchActionRequest(app: "Finder", steps: [ActionStep(action: .wait, durationMs: 1)], returnObservation: false)
        let (result, _) = await executor.executeBatch(request)
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.stepResults.first?.errorCode, "TARGET_BLOCKED")
        XCTAssertEqual(result.stepResults.first?.mechanism, "target-rules")
    }

    func testAnUnblockedAppStillWorks() async throws {
        _ = try runningFinder()
        use(TargetRules(deniedApps: ["com.apple.TextEdit"]))
        let res = await makeService().handle(RPCRequest(
            method: .act,
            act: BatchActionRequest(app: "Finder", steps: [ActionStep(action: .wait, durationMs: 1)], returnObservation: false)
        ))
        XCTAssertNotEqual(res.error?.code, "TARGET_BLOCKED")
        XCTAssertNotEqual(res.actionResult?.stepResults.first?.errorCode, "TARGET_BLOCKED")
    }

    func testBrowserOpenOfABlockedSiteIsRefusedBeforeAnythingIsSent() async {
        use(TargetRules(deniedSites: ["127.0.0.1"]))
        // No extension is connected: a request that got past the rules would fail with EXTENSION_NOT_CONNECTED.
        let service = makeService()
        let res = await service.handle(RPCRequest(
            method: .browserOpen,
            browserOpen: BrowserOpenParams(url: "http://127.0.0.1:8123/", profile: "Nobody")
        ))
        XCTAssertEqual(res.error?.code, "TARGET_BLOCKED")
        XCTAssertTrue(res.error?.message.contains("127.0.0.1") == true)

        let step = ActionStep(action: .navigate, url: "http://127.0.0.1:8123/")
        let act = await service.handle(RPCRequest(method: .browserAct, browserAct: BrowserActParams(steps: [step])))
        XCTAssertEqual(act.error?.code, "TARGET_BLOCKED")

        let allowed = await service.handle(RPCRequest(
            method: .browserOpen,
            browserOpen: BrowserOpenParams(url: "http://localhost:8123/", profile: "Nobody")
        ))
        XCTAssertEqual(allowed.error?.code, "EXTENSION_NOT_CONNECTED")
    }

    func testStatusLeavesOutABlockedFrontmostApp() {
        use(TargetRules(mode: .allow))
        let status = makeService().currentStatus()
        XCTAssertNil(status.frontmostApp, "in allow mode with nothing allowed, no app is reported")
        XCTAssertNil(status.pairedApp)
    }

    // MARK: - Bridge

    func testCommandTargetTabFollowsTheExtension() {
        let tabs = [
            BrowserTabInfo(tabId: 1, title: "User", url: "https://a.example/", active: true),
            BrowserTabInfo(tabId: 2, title: "UseMac old", url: "https://b.example/", active: false, usemac: true),
            BrowserTabInfo(tabId: 3, title: "UseMac", url: "https://c.example/", active: true, usemac: true),
            BrowserTabInfo(tabId: 4, title: "UseMac last", url: "https://d.example/", active: false, usemac: true)
        ]
        XCTAssertEqual(ChromeExtensionBridge.commandTargetTab(requested: 1, lastTabId: 2, in: tabs)?.tabId, 1)
        XCTAssertNil(ChromeExtensionBridge.commandTargetTab(requested: 99, lastTabId: 2, in: tabs))
        XCTAssertEqual(ChromeExtensionBridge.commandTargetTab(requested: nil, lastTabId: 2, in: tabs)?.tabId, 2)
        XCTAssertEqual(ChromeExtensionBridge.commandTargetTab(requested: nil, lastTabId: 77, in: tabs)?.tabId, 3)
        XCTAssertEqual(ChromeExtensionBridge.commandTargetTab(requested: nil, lastTabId: nil, in: Array(tabs.prefix(2)) + [tabs[3]])?.tabId, 4)
        XCTAssertNil(ChromeExtensionBridge.commandTargetTab(requested: nil, lastTabId: nil, in: [tabs[0]]))
    }

    func testBridgeChecksTheTabBeforeSendingAndEveryResult() async throws {
        use(TargetRules(deniedSites: ["blocked.example"]))
        let keyDir = makeTemporaryBridgeKeyDirectory()
        defer { try? FileManager.default.removeItem(at: keyDir) }
        let bridge = ChromeExtensionBridge(port: 0, pairingStore: BridgePairingStore(directory: keyDir))
        bridge.baseCommandTimeoutSeconds = 3
        bridge.start()
        defer { bridge.stop() }
        let port = await waitForListeningPort(of: bridge)
        let key = try XCTUnwrap(bridge.pairingKeyText().flatMap(BridgeKey.init(text:)))
        let wsTask = try await connectAuthenticatedMockExtension(port: port, key: key, profileName: "Rules", tabCount: 2)
        defer { wsTask.cancel(with: .goingAway, reason: nil) }
        let ready = await waitForBridgeCondition { bridge.connectedProfiles().first?.profileName == "Rules" }
        XCTAssertTrue(ready)

        let commands = CommandLog()
        // Tab 10 is on an allowed site, tab 20 on a blocked one. Tab 10's page "navigates" to the blocked site on act.
        let responder = Task {
            while !Task.isCancelled {
                guard let obj = try? await receiveBridgeJSON(from: wsTask) else { break }
                guard (obj["type"] as? String) == "request", let id = obj["id"] as? String,
                      let command = obj["command"] as? String else { continue }
                commands.append(command)
                var resp: [String: Any] = ["type": "response", "id": id, "ok": true, "profileName": "Rules"]
                switch command {
                case "tabs":
                    resp["tabId"] = 10
                    resp["tabs"] = [
                        ["tabId": 10, "title": "Fine", "url": "https://fine.example/", "active": true, "usemac": true],
                        ["tabId": 20, "title": "Secret", "url": "https://www.blocked.example/", "active": false]
                    ]
                case "act":
                    resp["tabId"] = 10
                    resp["url"] = "https://blocked.example/after-click"
                    resp["screenshotBase64"] = Data("not really a jpeg".utf8).base64EncodedString()
                default:
                    resp["tabId"] = obj["tabId"] as? Int ?? 10
                    resp["url"] = "https://fine.example/"
                }
                try? await sendBridgeJSON(resp, on: wsTask)
            }
        }
        defer { responder.cancel() }

        // browser_tabs hides the blocked tab.
        let tabs = await bridge.tabs(BrowserTabsParams(profile: "Rules"))
        XCTAssertTrue(tabs.ok)
        XCTAssertEqual(tabs.tabs?.map(\.tabId), [10])

        // A command on the blocked tab never reaches the extension.
        commands.reset()
        let blockedObserve = await bridge.observe(BrowserObserveParams(profile: "Rules", tabId: 20))
        XCTAssertEqual(blockedObserve.error?.code, "TARGET_BLOCKED")
        XCTAssertEqual(commands.all, ["tabs"], "only the lookup was sent")

        // The default tab (the extension's last tab, 10) is fine.
        commands.reset()
        let fineObserve = await bridge.observe(BrowserObserveParams(profile: "Rules"))
        XCTAssertTrue(fineObserve.ok, String(describing: fineObserve.error))
        XCTAssertEqual(commands.all, ["tabs", "observe"])

        // A result from a page on a blocked site is withheld, and its screenshot is never written or cached.
        let act = await bridge.act(BrowserActParams(profile: "Rules", tabId: 10, steps: [ActionStep(action: .click, elementId: "@b1")]))
        XCTAssertEqual(act.error?.code, "TARGET_BLOCKED")
        XCTAssertNil(act.screenshot)
        XCTAssertNil(bridge.latestFrame(profileQuery: "Rules", tabId: 10))

        // Opening a blocked site, or a step that navigates there, is refused without a round trip.
        commands.reset()
        let open = await bridge.open(BrowserOpenParams(url: "https://blocked.example/", profile: "Rules"))
        XCTAssertEqual(open.error?.code, "TARGET_BLOCKED")
        let nav = await bridge.act(BrowserActParams(profile: "Rules", steps: [ActionStep(action: .navigate, url: "https://x.blocked.example/")]))
        XCTAssertEqual(nav.error?.code, "TARGET_BLOCKED")
        XCTAssertEqual(commands.all, [])
    }

    func testFramesOfBlockedPagesAreDroppedAndTheirStreamStops() async throws {
        use(TargetRules(deniedSites: ["blocked.example"]))
        let keyDir = makeTemporaryBridgeKeyDirectory()
        defer { try? FileManager.default.removeItem(at: keyDir) }
        let bridge = ChromeExtensionBridge(port: 0, pairingStore: BridgePairingStore(directory: keyDir))
        let forwarded = CommandLog()
        bridge.onBrowserFrame = { tabId, _, _, _, _, _ in forwarded.append("\(tabId ?? -1)") }
        bridge.start()
        defer { bridge.stop() }
        let port = await waitForListeningPort(of: bridge)
        let key = try XCTUnwrap(bridge.pairingKeyText().flatMap(BridgeKey.init(text:)))
        let wsTask = try await connectAuthenticatedMockExtension(port: port, key: key, profileName: "Frames", tabCount: 2)
        defer { wsTask.cancel(with: .goingAway, reason: nil) }
        let ready = await waitForBridgeCondition { bridge.connectedProfiles().first?.profileName == "Frames" }
        XCTAssertTrue(ready)

        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9]).base64EncodedString()
        func frame(tabId: Int, url: String) -> [String: Any] {
            ["type": "frame", "tabId": tabId, "profileName": "Frames", "url": url, "title": "T", "viewportWidth": 800, "viewportHeight": 600, "jpegBase64": jpeg]
        }
        try await sendBridgeJSON(frame(tabId: 5, url: "https://blocked.example/"), on: wsTask)
        let stop = try await receiveBridgeJSON(from: wsTask)
        XCTAssertEqual(stop["command"] as? String, "stop_stream")
        XCTAssertEqual(stop["tabId"] as? Int, 5)

        try await sendBridgeJSON(frame(tabId: 6, url: "https://fine.example/"), on: wsTask)
        let cached = await waitForBridgeCondition { bridge.latestFrame(tabId: 6) != nil }
        XCTAssertTrue(cached)
        XCTAssertNotEqual(bridge.latestFrame(tabId: 5)?.tabId, 5, "the blocked frame was never cached")
        XCTAssertEqual(forwarded.all, ["6"])
        XCTAssertNotEqual(bridge.connectedProfiles().first?.streamingUrl, "https://blocked.example/")

        // A frame cached before the site was blocked is not handed out afterwards.
        use(TargetRules(deniedSites: ["fine.example"]))
        XCTAssertNil(bridge.latestFrame(tabId: 6))
    }

    func testReadOnlySiteRefusesMutationPreflightButStillAllowsObserve() async throws {
        use(TargetRules(readOnlySites: ["read.example"]))
        try await withMockExtension(profile: "Read Only", respond: { command, _ in
            command == "tabs"
                ? ["ok": true, "tabId": 7, "tabs": [["tabId": 7, "title": "Read", "url": "https://read.example/", "active": true, "usemac": true]]]
                : ["ok": true, "tabId": 7, "url": "https://read.example/"]
        }) { bridge, commands in
            let direct = await bridge.targetRulesPreflight(
                profile: "Read Only", tabId: nil, url: "https://read.example/", checksTab: false, isMutating: true
            )
            XCTAssertEqual(direct?.error?.code, "POLICY_BLOCKED")
            XCTAssertEqual(direct?.error?.hint, TargetRules.stopHint)
            XCTAssertEqual(commands.all, [])

            let lookup = await bridge.targetRulesPreflight(profile: "Read Only", tabId: nil, isMutating: true)
            XCTAssertEqual(lookup?.error?.code, "POLICY_BLOCKED")
            XCTAssertEqual(lookup?.tabId, 7)
            XCTAssertEqual(lookup?.profileName, "Read Only")
            XCTAssertEqual(commands.all, ["tabs"])

            let observe = await bridge.observe(BrowserObserveParams(profile: "Read Only", tabId: 7))
            XCTAssertTrue(observe.ok)
            XCTAssertEqual(commands.all, ["tabs", "observe"])
        }
    }

    func testAskSiteHoldsBrowserMutationsInAutonomousModeButNotObservation() async throws {
        use(TargetRules(askSites: ["ask.example"]))
        let keyDir = makeTemporaryBridgeKeyDirectory()
        defer { try? FileManager.default.removeItem(at: keyDir) }
        let service = makeService(bridgeKeyDirectory: keyDir)
        service.setGovernancePolicy(.autonomous)
        try await withMockExtension(profile: "Ask Site", bridge: service.chromeBridge, respond: { command, _ in
            command == "tabs"
                ? ["ok": true, "tabId": 7, "tabs": [["tabId": 7, "title": "Ask", "url": "https://ask.example/", "active": true, "usemac": true]]]
                : ["ok": true, "tabId": 7, "url": "https://ask.example/"]
        }) { bridge, commands in
            let read = await bridge.observe(BrowserObserveParams(profile: "Ask Site", tabId: 7))
            XCTAssertTrue(read.ok)
            XCTAssertNil(service.approvals.currentPrompt)
            commands.reset()

            let request = RPCRequest(method: .browserAct, browserAct: BrowserActParams(
                profile: "Ask Site", tabId: 7, steps: [ActionStep(action: .click, elementId: "@b1")]
            ))
            async let result = service.handle(request)
            let shown = await waitForBridgeCondition { service.approvals.currentPrompt != nil }
            XCTAssertTrue(shown)
            let prompt = try XCTUnwrap(service.approvals.currentPrompt)
            XCTAssertEqual(prompt.kinds, [.targetRule])
            XCTAssertTrue(prompt.target.contains("ask.example"))
            XCTAssertTrue(prompt.steps.joined().contains("click"))
            XCTAssertEqual(commands.all, ["tabs"])

            let click = ApprovalInputCheck.PhysicalClick(sourcePid: 0, downTime: 1, upTime: 1.1)
            XCTAssertTrue(service.approvals.decide(promptId: prompt.id, decision: .deny, click: click))
            let refusal = await result
            XCTAssertEqual(refusal.error?.code, "APPROVAL_DENIED")
            XCTAssertEqual(commands.all, ["tabs"])

            let unknown = await bridge.resolveGovernedTabSitePolicy(profile: "Ask Site", tabId: 999)
            XCTAssertEqual(unknown.failure?.error?.code, TargetRules.errorCode)
        }
    }

    func testAskBrowserOpenUsesTheDestinationWhenCreatingATab() async throws {
        use(TargetRules(askSites: ["ask.example"]))
        let service = makeService()
        service.setGovernancePolicy(.autonomous)
        let request = RPCRequest(method: .browserOpen, browserOpen: BrowserOpenParams(
            url: "https://ask.example/", autoDismissOverlays: true
        ))
        async let result = service.approvalRefusal(for: request, startNs: DispatchTime.now().uptimeNanoseconds)
        // No extension is connected: an explicit new tab only needs the supplied destination to ask.
        let shown = await waitForBridgeCondition { service.approvals.currentPrompt != nil }
        XCTAssertTrue(shown)
        let prompt = try XCTUnwrap(service.approvals.currentPrompt)
        XCTAssertEqual(prompt.kinds, [.targetRule])
        XCTAssertEqual(prompt.steps, ["Dismiss browser overlays"])
        XCTAssertTrue(prompt.target.contains("new tab"))
        XCTAssertTrue(prompt.target.contains("ask.example"))

        let click = ApprovalInputCheck.PhysicalClick(sourcePid: 0, downTime: 1, upTime: 1.1)
        XCTAssertTrue(service.approvals.decide(promptId: prompt.id, decision: .deny, click: click))
        let refusal = await result
        XCTAssertEqual(refusal?.error?.code, "APPROVAL_DENIED")
    }

    func testAskTargetCanAllowForTaskButNeverWhenThereIsAnUpload() async throws {
        let broker = ApprovalBroker()
        let ask = ApprovalBroker.Request(
            method: "act", target: "TextEdit", steps: ["type (12 chars)"], kinds: [.targetRule],
            taskId: "task-a", grantTarget: "app:com.apple.textedit"
        )
        let click = ApprovalInputCheck.PhysicalClick(sourcePid: 0, downTime: 1, upTime: 1.1)
        async let result = broker.requestApproval(ask)
        let shown = await waitForBridgeCondition { broker.currentPrompt != nil }
        XCTAssertTrue(shown)
        let prompt = try XCTUnwrap(broker.currentPrompt)
        XCTAssertTrue(prompt.canAllowForTask)
        XCTAssertTrue(broker.decide(promptId: prompt.id, decision: .allowForTask, click: click))
        let first = await result
        XCTAssertEqual(first, .allowedForTask(taskId: "task-a"))
        let granted = await broker.requestApproval(ask)
        XCTAssertEqual(granted, .allowedByTaskGrant(taskId: "task-a"))

        var upload = ask
        upload.kinds.insert(.upload)
        let uploadRequest = upload
        async let uploadResult = broker.requestApproval(uploadRequest)
        let uploadShown = await waitForBridgeCondition { broker.currentPrompt != nil }
        XCTAssertTrue(uploadShown)
        let uploadPrompt = try XCTUnwrap(broker.currentPrompt)
        XCTAssertFalse(uploadPrompt.canAllowForTask)
        XCTAssertFalse(broker.decide(promptId: uploadPrompt.id, decision: .allowForTask, click: click))
        XCTAssertTrue(broker.decide(promptId: uploadPrompt.id, decision: .deny, click: click))
        let denied = await uploadResult
        XCTAssertEqual(denied, .denied)
    }

    func testNativeBrowserProbeAppliesReadOnlyAndAskAndFailsClosedWhenUnknown() {
        let rules = TargetRules(askSites: ["ask.example", "read.example"], readOnlySites: ["read.example"])
        let read = NativeBrowserSiteRules.decision(rules: rules, probe: .init(axURL: "https://read.example"))
        XCTAssertEqual(read.policy, .readOnly)
        XCTAssertNil(read.unconfirmedMessage)
        let ask = NativeBrowserSiteRules.decision(rules: rules, probe: .init(bridgeURL: "https://ask.example"))
        XCTAssertEqual(ask.policy, .ask)
        XCTAssertEqual(ask.site?.host, "ask.example")
        let unknown = NativeBrowserSiteRules.decision(rules: rules, probe: .init(bridgeAmbiguous: true))
        XCTAssertEqual(unknown.policy, .block)
        XCTAssertNotNil(unknown.unconfirmedMessage)
    }

    /// A connected bridge whose mock extension answers each request with `respond` (nil: no answer at all).
    private func withMockExtension(
        profile: String,
        bridge existingBridge: ChromeExtensionBridge? = nil,
        respond: @escaping @Sendable (_ command: String, _ request: [String: Any]) -> [String: Any]?,
        _ body: (ChromeExtensionBridge, CommandLog) async throws -> Void
    ) async throws {
        let keyDir = makeTemporaryBridgeKeyDirectory()
        defer { try? FileManager.default.removeItem(at: keyDir) }
        let bridge = existingBridge ?? ChromeExtensionBridge(port: 0, pairingStore: BridgePairingStore(directory: keyDir))
        bridge.baseCommandTimeoutSeconds = 0.15
        bridge.start()
        defer { bridge.stop() }
        let port = await waitForListeningPort(of: bridge)
        let key = try XCTUnwrap(bridge.pairingKeyText().flatMap(BridgeKey.init(text:)))
        let wsTask = try await connectAuthenticatedMockExtension(port: port, key: key, profileName: profile, tabCount: 1)
        defer { wsTask.cancel(with: .goingAway, reason: nil) }
        let ready = await waitForBridgeCondition { bridge.connectedProfiles().first?.profileName == profile }
        XCTAssertTrue(ready)

        let commands = CommandLog()
        let responder = Task {
            while !Task.isCancelled {
                guard let obj = try? await receiveBridgeJSON(from: wsTask) else { break }
                guard (obj["type"] as? String) == "request", let id = obj["id"] as? String,
                      let command = obj["command"] as? String else { continue }
                commands.append(command)
                guard var resp = respond(command, obj) else { continue }
                resp["type"] = "response"
                resp["id"] = id
                resp["profileName"] = profile
                try? await sendBridgeJSON(resp, on: wsTask)
            }
        }
        defer { responder.cancel() }
        try await body(bridge, commands)
    }

    func testATabCommandIsRefusedWhenTheTabLookupTimesOut() async throws {
        use(TargetRules(deniedSites: ["blocked.example"]))
        // The extension never answers the lookup, but would answer anything else.
        try await withMockExtension(profile: "Mute", respond: { command, _ in
            command == "tabs" ? nil : ["ok": true, "tabId": 7, "url": "https://fine.example/"]
        }) { bridge, commands in
            let calls: [(String, () async -> ChromeExtensionBridge.BridgeResponse)] = [
                ("act", { await bridge.act(BrowserActParams(profile: "Mute", tabId: 7, steps: [ActionStep(action: .click, elementId: "@b1")])) }),
                ("observe", { await bridge.observe(BrowserObserveParams(profile: "Mute", tabId: 7)) }),
                ("extract", { await bridge.extract(BrowserExtractParams(profile: "Mute", tabId: 7)) }),
                ("screenshot", { await bridge.screenshot(BrowserScreenshotParams(profile: "Mute", tabId: 7)) }),
                ("open on a tab", { await bridge.open(BrowserOpenParams(url: "https://fine.example/", profile: "Mute", tabId: 7)) })
            ]
            for (name, call) in calls {
                commands.reset()
                let resp = await call()
                XCTAssertEqual(resp.error?.code, "TARGET_BLOCKED", name)
                XCTAssertTrue(resp.error?.message.contains("couldn't confirm this tab's site") == true, name)
                XCTAssertTrue(resp.error?.message.contains("Retry once") == true, name)
                XCTAssertEqual(commands.all, ["tabs"], "\(name): nothing but the lookup was sent")
            }

            // browser_tabs is only a listing, filtered afterwards: it reports the extension's own timeout.
            let tabs = await bridge.tabs(BrowserTabsParams(profile: "Mute"))
            XCTAssertEqual(tabs.error?.code, "EXTENSION_TIMEOUT")
        }
    }

    func testATabWhoseAddressIsUnknownIsRefused() async throws {
        use(TargetRules(deniedSites: ["blocked.example"]))
        try await withMockExtension(profile: "Loading", respond: { command, _ in
            command == "tabs"
                ? ["ok": true, "tabId": 3, "tabs": [["tabId": 3, "title": "", "url": "", "active": true, "usemac": true]]]
                : ["ok": true, "tabId": 3, "url": "https://fine.example/"]
        }) { bridge, commands in
            let resp = await bridge.act(BrowserActParams(profile: "Loading", steps: [ActionStep(action: .click, elementId: "@b1")]))
            XCTAssertEqual(resp.error?.code, "TARGET_BLOCKED")
            XCTAssertTrue(resp.error?.message.contains("not known yet") == true)
            XCTAssertEqual(commands.all, ["tabs"])

            // A tab id Chrome does not list goes on to the extension, which answers for a missing tab itself.
            commands.reset()
            _ = await bridge.observe(BrowserObserveParams(profile: "Loading", tabId: 999))
            XCTAssertEqual(commands.all, ["tabs", "observe"])
        }
    }

    func testNoTabLookupWithoutSiteRules() async throws {
        use(TargetRules(deniedApps: ["com.apple.Passwords"]))
        try await withMockExtension(profile: "Plain", respond: { _, _ in
            ["ok": true, "tabId": 7, "url": "https://anything.example/"]
        }) { bridge, commands in
            let resp = await bridge.observe(BrowserObserveParams(profile: "Plain", tabId: 7))
            XCTAssertTrue(resp.ok, String(describing: resp.error))
            XCTAssertEqual(commands.all, ["observe"], "no extra round trip without a site rule")
        }
    }

    func testVisionOnABlockedTabIsRefused() async throws {
        use(TargetRules(deniedSites: ["blocked.example"]))
        try await withMockExtension(profile: "Vision", respond: { command, _ in
            command == "tabs"
                ? ["ok": true, "tabId": 4, "tabs": [["tabId": 4, "title": "Secret", "url": "https://blocked.example/", "active": true, "usemac": true]]]
                : ["ok": true, "tabId": 4, "url": "https://blocked.example/"]
        }) { bridge, _ in
            let refusal = await bridge.targetRulesVisionPreflight(VisionQueryParams(mode: "ask", query: "what is shown?", profile: "Vision", tabId: 4))
            XCTAssertEqual(refusal?.error?.code, "TARGET_BLOCKED")
            // A query on a native app does not read a tab.
            let native = await bridge.targetRulesVisionPreflight(VisionQueryParams(mode: "ask", query: "what is shown?", app: "TextEdit"))
            XCTAssertNil(native)
        }
    }
}

private final class CommandLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func append(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
    func reset() { lock.lock(); items.removeAll(); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}
