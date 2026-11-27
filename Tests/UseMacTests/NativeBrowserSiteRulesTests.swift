import Foundation
import XCTest
@testable import UseMacEngine
import UseMacProtocol

final class NativeBrowserSiteRulesTests: XCTestCase {
    private let deny = TargetRules(deniedSites: ["blocked.example"])
    private let allow = TargetRules(mode: .allow, allowedSites: ["allowed.example"])
    private let allowedURL = "https://allowed.example/"
    private let blockedURL = "https://vault.blocked.example/"
    private let blockedSite = TargetRules.blockedSiteMessage(host: nil)
    private let unknownSite = TargetRules.unconfirmedSiteMessage(reason: "the window's active tab URL is not known yet")
    private let ambiguousSite = TargetRules.unconfirmedSiteMessage(reason: "multiple Chrome windows matched the window title")

    func testIsChromiumAppMatchesKnownBrowsersAndRejectsOthers() {
        for id in [
            "com.google.Chrome", "COM.GOOGLE.CHROME.BETA", "com.google.Chrome.canary", "com.google.Chrome.dev",
            "org.chromium.Chromium", "com.brave.Browser.nightly", "com.microsoft.edgemac", "company.thebrowser.Browser"
        ] {
            XCTAssertTrue(NativeBrowserSiteRules.isChromiumApp(bundleId: id, name: nil), id)
        }
        for name in ["Google Chrome Beta", "Chromium", "Brave Browser", "Microsoft Edge", "Arc"] {
            XCTAssertTrue(NativeBrowserSiteRules.isChromiumApp(bundleId: nil, name: name), name)
            XCTAssertTrue(NativeBrowserSiteRules.isChromiumApp(bundleId: "", name: name), name)
        }
        for (id, name) in [
            ("com.apple.Safari", "Safari"), ("com.apple.Notes", "Notes"), ("com.apple.TextEdit", "TextEdit"),
            ("com.apple.finder", "Finder"), ("com.apple.archiveutility", "Archive Utility")
        ] {
            XCTAssertFalse(NativeBrowserSiteRules.isChromiumApp(bundleId: id, name: name), name)
            XCTAssertFalse(NativeBrowserSiteRules.isChromiumApp(bundleId: nil, name: name), name)
        }
        XCTAssertFalse(NativeBrowserSiteRules.isChromiumApp(bundleId: "com.apple.Safari", name: "Chrome"))
    }

    func testOperaAndOperaGXAreChromiumBrowsers() {
        for id in ["com.operasoftware.opera", "com.operasoftware.operagx"] {
            XCTAssertTrue(NativeBrowserSiteRules.isChromiumApp(bundleId: id, name: nil))
        }
        for name in ["Opera", "Opera GX"] {
            XCTAssertTrue(NativeBrowserSiteRules.isChromiumApp(bundleId: nil, name: name))
            let tabs = [BrowserTabInfo(tabId: 1, title: "Mail", url: allowedURL, active: true)]
            let match = NativeBrowserSiteRules.matchActiveTab(windowTitle: "Mail - \(name)", tabs: tabs, rules: deny)
            XCTAssertEqual(match.url, allowedURL)
        }
    }

    func testRecognizesRestrictedBrowserURLsWithoutMatchingLookalikes() {
        for url in [
            " chrome://settings ", "chrome-extension://extension-id/page.html", "chrome-untrusted://new-tab-page/",
            "edge://settings", "brave://settings", "arc://settings", "opera://settings", "devtools://devtools/",
            "view-source:https://example.com", "about:config",
            "https://chromewebstore.google.com/detail/example", "https://chrome.google.com/webstore",
            "https://chrome.google.com/webstore/detail/example", "https://microsoftedge.microsoft.com/addons",
            "https://microsoftedge.microsoft.com/addons/detail/example", "https://addons.opera.com/en/extensions/"
        ] {
            XCTAssertTrue(NativeBrowserSiteRules.isRestrictedBrowserURL(url), url)
        }
        for url in [
            "about:blank", "about:blank#fragment", "about:srcdoc", "https://chrome.google.com/",
            "https://chrome.google.com/webstore-archive", "https://microsoftedge.microsoft.com/addons-help",
            "https://chromewebstore.google.com.example.com/detail/example", "https://example.com/chrome://settings", ""
        ] {
            XCTAssertFalse(NativeBrowserSiteRules.isRestrictedBrowserURL(url), url)
        }
        XCTAssertFalse(NativeBrowserSiteRules.isRestrictedBrowserURL(nil))
    }

    func testDisplayCaptureExcludesRestrictedAppsAndChromiumWhenSitesAreRestricted() {
        let notes = "com.apple.Notes"
        let rules = TargetRules(deniedApps: [notes], deniedSites: ["blocked.example"])
        XCTAssertTrue(FastScreenCapturer.shouldExcludeFromDisplayCapture(bundleId: notes, name: "Notes", rules: rules))
        XCTAssertTrue(FastScreenCapturer.shouldExcludeFromDisplayCapture(bundleId: "com.google.Chrome", name: nil, rules: rules))
        XCTAssertTrue(FastScreenCapturer.shouldExcludeFromDisplayCapture(bundleId: nil, name: "Opera GX", rules: rules))
        XCTAssertFalse(FastScreenCapturer.shouldExcludeFromDisplayCapture(bundleId: "com.apple.TextEdit", name: "TextEdit", rules: rules))
        XCTAssertFalse(FastScreenCapturer.shouldExcludeFromDisplayCapture(
            bundleId: "com.google.Chrome", name: "Chrome", rules: TargetRules(deniedApps: [notes])
        ))
    }

    func testChromiumCaptureDisablesLiveFramesAndRequiresKnownWindowWhenSitesAreRestricted() {
        var browser = chrome()
        browser.windowId = 101
        XCTAssertFalse(FastScreenCapturer.shouldAllowLiveFrameReuse(for: browser, rules: deny))
        XCTAssertTrue(FastScreenCapturer.requiresExactWindowID(for: browser, rules: deny))
        let noSiteRules = TargetRules(deniedApps: ["com.apple.Notes"])
        XCTAssertTrue(FastScreenCapturer.shouldAllowLiveFrameReuse(for: browser, rules: noSiteRules))
        XCTAssertFalse(FastScreenCapturer.requiresExactWindowID(for: browser, rules: noSiteRules))
        for unknownId: UInt32? in [nil, 0] {
            browser.windowId = unknownId
            XCTAssertFalse(FastScreenCapturer.requiresExactWindowID(for: browser, rules: deny))
            XCTAssertFalse(FastScreenCapturer.shouldAllowLiveFrameReuse(for: browser, rules: deny))
        }
        let notes = AppDescriptor(pid: 0, name: "Notes", bundleId: "com.apple.Notes", windowId: 101)
        XCTAssertTrue(FastScreenCapturer.shouldAllowLiveFrameReuse(for: notes, rules: deny))
        XCTAssertFalse(FastScreenCapturer.requiresExactWindowID(for: notes, rules: deny))
    }

    func testMissingNamedAppCaptureRefusesBeforeScreenCapture() async {
        let name = "Unavailable Test App"
        do {
            _ = try await FastScreenCapturer().captureWindow(.init(app: name), writeToDisk: false)
            XCTFail("A missing named app must not fall back to the display")
        } catch FastScreenCapturer.CaptureError.noCapturableWindow(let appName) {
            XCTAssertEqual(appName, name)
        } catch {
            XCTFail("Unexpected capture error: \(error)")
        }
    }

    func testNoSiteRulesAllowsWithoutBlocking() async {
        let rules = TargetRules(deniedApps: ["com.apple.Passwords"])
        XCTAssertNil(NativeBrowserSiteRules.evaluate(rules: rules, probe: .init(), blockedCandidateFound: true))

        let message = await NativeBrowserSiteRules.blockedMessage(for: chrome(), rules: rules)
        XCTAssertNil(message)
    }

    func testDeniedChromeBlocksImmediately() async {
        let rules = TargetRules(deniedApps: ["com.google.Chrome"])
        XCTAssertEqual(NativeBrowserSiteRules.evaluate(rules: rules, probe: .init(axURL: allowedURL)), TargetRules.blockedBrowserMessage)

        let message = await NativeBrowserSiteRules.blockedMessage(for: chrome(), rules: rules)
        XCTAssertEqual(message, TargetRules.blockedBrowserMessage)

        let safari = AppDescriptor(pid: 0, name: "Safari", bundleId: "com.apple.Safari", isActive: true)
        let safariMessage = await NativeBrowserSiteRules.blockedMessage(for: safari, rules: rules)
        XCTAssertNil(safariMessage)
    }

    func testBlockedAXURLRefusesWithBlockedSiteMessage() {
        let probe = NativeBrowserSiteRules.ProbeResult(axURL: " \n\(blockedURL) ", bridgeURL: allowedURL)
        XCTAssertEqual(NativeBrowserSiteRules.evaluate(rules: deny, probe: probe), blockedSite)
    }

    func testAllowedAXURLPermitsInDenyAndAllowModes() {
        XCTAssertNil(NativeBrowserSiteRules.evaluate(rules: allow, probe: .init(axURL: allowedURL, bridgeAmbiguous: true)))
        for url in [allowedURL, "https://chromewebstore.google.com/detail/example", "chrome://extensions"] {
            XCTAssertNil(NativeBrowserSiteRules.evaluate(rules: deny, probe: .init(axURL: url)), url)
        }
    }

    func testAllowModeBlocksChromeInternalAndUnlistedSites() {
        for url in ["chrome://extensions", "https://unlisted.example/"] {
            XCTAssertEqual(NativeBrowserSiteRules.evaluate(rules: allow, probe: .init(axURL: url)), blockedSite, url)
        }
    }

    func testBridgeMatchResolvesSingleWindowTitleWithChromeSuffix() {
        let tabs = [
            BrowserTabInfo(tabId: 1, title: "Mail", url: allowedURL, active: true),
            BrowserTabInfo(tabId: 2, title: "Calendar", url: blockedURL, active: true),
            BrowserTabInfo(tabId: 3, title: "Mail", url: blockedURL, active: false)
        ]
        for title in [
            "Mail - Google Chrome", "Mail — Google Chrome", "Mail - Google Chrome - Profile",
            "Mail - Google Chrome Canary", "Mail - Chromium", "Mail - Brave", "Mail - Microsoft Edge", "Mail - Arc"
        ] {
            let match = NativeBrowserSiteRules.matchActiveTab(windowTitle: title, tabs: tabs, rules: deny)
            XCTAssertEqual(match.url, allowedURL, title)
            XCTAssertFalse(match.ambiguous, title)
            XCTAssertFalse(match.blockedCandidateFound, title)
            XCTAssertNil(NativeBrowserSiteRules.evaluate(rules: deny, probe: .init(bridgeURL: match.url, bridgeAvailable: true)), title)
        }
    }

    func testBridgeMatchDetectsBlockedSiteWhenAXUnavailable() {
        let tabs = [BrowserTabInfo(tabId: 1, title: "Vault", url: blockedURL, active: true)]
        let match = NativeBrowserSiteRules.matchActiveTab(windowTitle: "Vault - Google Chrome", tabs: tabs, rules: deny)
        XCTAssertEqual(match.url, blockedURL)
        XCTAssertFalse(match.ambiguous)
        XCTAssertTrue(match.blockedCandidateFound)
        XCTAssertEqual(NativeBrowserSiteRules.evaluate(
            rules: deny,
            probe: .init(bridgeURL: match.url, bridgeAvailable: true),
            blockedCandidateFound: match.blockedCandidateFound
        ), blockedSite)
    }

    func testFailsClosedWhenNeitherAXNorBridgeCanConfirmURL() async {
        let unavailable = TargetRules.unconfirmedSiteMessage(
            reason: "the window's active URL could not be read via Accessibility and the Chrome extension is not connected"
        )
        XCTAssertEqual(NativeBrowserSiteRules.evaluate(rules: deny, probe: .init()), unavailable)
        XCTAssertEqual(NativeBrowserSiteRules.evaluate(rules: deny, probe: .init(bridgeAvailable: true)), unknownSite)
        let reason = "the tab lookup timed out"
        XCTAssertEqual(
            NativeBrowserSiteRules.evaluate(rules: deny, probe: .init(bridgeAvailable: true, bridgeFailureReason: reason)),
            TargetRules.unconfirmedSiteMessage(reason: reason)
        )

        let message = await NativeBrowserSiteRules.blockedMessage(for: chrome(), rules: deny)
        XCTAssertEqual(message, unavailable)
    }

    func testFailsClosedOnAmbiguousWindowTitleAcrossTabs() {
        for (secondURL, containsBlocked, expected) in [
            ("https://also-allowed.example/", false, ambiguousSite), (blockedURL, true, blockedSite)
        ] {
            let tabs = [
                BrowserTabInfo(tabId: 1, title: "Same title", url: allowedURL, active: true),
                BrowserTabInfo(tabId: 2, title: "Same title", url: secondURL, active: true)
            ]
            let match = NativeBrowserSiteRules.matchActiveTab(windowTitle: "Same title - Google Chrome", tabs: tabs, rules: deny)
            XCTAssertNil(match.url)
            XCTAssertTrue(match.ambiguous)
            XCTAssertEqual(match.blockedCandidateFound, containsBlocked)
            let probe = NativeBrowserSiteRules.ProbeResult(bridgeAmbiguous: match.ambiguous, bridgeAvailable: true)
            XCTAssertEqual(NativeBrowserSiteRules.evaluate(rules: deny, probe: probe, blockedCandidateFound: match.blockedCandidateFound), expected)
        }
        let probe = NativeBrowserSiteRules.ProbeResult(bridgeURL: allowedURL, bridgeAmbiguous: true, bridgeAvailable: true)
        XCTAssertEqual(NativeBrowserSiteRules.evaluate(rules: deny, probe: probe), ambiguousSite)
    }

    func testBlockedBridgeURLOverridesUnblockedAXURL() {
        let probe = NativeBrowserSiteRules.ProbeResult(axURL: allowedURL, bridgeURL: blockedURL, bridgeAmbiguous: true)
        XCTAssertEqual(NativeBrowserSiteRules.evaluate(rules: deny, probe: probe), blockedSite)
        XCTAssertEqual(NativeBrowserSiteRules.evaluate(rules: deny, probe: .init(axURL: allowedURL), blockedCandidateFound: true), blockedSite)
    }

    func testAboutBlankPermittedInDenyAndAllowModes() {
        for rules in [deny, allow] {
            XCTAssertNil(NativeBrowserSiteRules.evaluate(rules: rules, probe: .init(axURL: "about:blank")))
            XCTAssertNil(NativeBrowserSiteRules.evaluate(rules: rules, probe: .init(bridgeURL: " about:blank ", bridgeAvailable: true)))
        }
    }

    func testMalformedURLsDoNotConfirmTheSite() {
        for url in ["  ", "Not a URL", "allowed.example", "https:", "https://", "https:allowed.example", "about:", "blob:"] {
            let probe = NativeBrowserSiteRules.ProbeResult(axURL: url, bridgeURL: url, bridgeAvailable: true)
            XCTAssertEqual(NativeBrowserSiteRules.evaluate(rules: deny, probe: probe), unknownSite, url)
        }
    }

    func testBlobAndFileURLsFollowTargetRules() {
        XCTAssertEqual(NativeBrowserSiteRules.evaluate(rules: deny, probe: .init(axURL: "blob:\(blockedURL)id")), blockedSite)
        XCTAssertNil(NativeBrowserSiteRules.evaluate(rules: allow, probe: .init(axURL: "blob:\(allowedURL)id")))
        XCTAssertNil(NativeBrowserSiteRules.evaluate(rules: deny, probe: .init(axURL: "file:///tmp/example.html")))
        XCTAssertEqual(NativeBrowserSiteRules.evaluate(rules: allow, probe: .init(axURL: "file:///tmp/example.html")), blockedSite)
    }

    func testIdenticalURLsAcrossMatchingWindowsAreNotAmbiguous() {
        let tabs = [
            BrowserTabInfo(tabId: 1, title: "Same title", url: allowedURL, active: true),
            BrowserTabInfo(tabId: 2, title: "Same title", url: allowedURL, active: true)
        ]
        let match = NativeBrowserSiteRules.matchActiveTab(windowTitle: "Same title", tabs: tabs, rules: deny)
        XCTAssertEqual(match.url, allowedURL)
        XCTAssertFalse(match.ambiguous)
        XCTAssertFalse(match.blockedCandidateFound)
    }

    func testUnmatchedTitleDoesNotUseTheOnlyActiveTab() {
        let tabs = [BrowserTabInfo(tabId: 1, title: "Mail settings", url: blockedURL, active: true)]

        let unmatched = NativeBrowserSiteRules.matchActiveTab(windowTitle: "Mail - Google Chrome", tabs: tabs, rules: deny)
        XCTAssertNil(unmatched.url)
        XCTAssertTrue(unmatched.ambiguous)
        XCTAssertFalse(unmatched.blockedCandidateFound)

        let empty = NativeBrowserSiteRules.matchActiveTab(windowTitle: "Mail", tabs: [], rules: deny)
        XCTAssertNil(empty.url)
        XCTAssertFalse(empty.ambiguous)
    }

    func testMissingWindowTitleDoesNotInheritTheOnlyActiveTab() {
        for url in [allowedURL, blockedURL] {
            let tabs = [BrowserTabInfo(tabId: 1, title: "Mail", url: url, active: true)]
            for title: String? in [nil, "", " \n"] {
                let match = NativeBrowserSiteRules.matchActiveTab(windowTitle: title, tabs: tabs, rules: deny)
                XCTAssertNil(match.url)
                XCTAssertTrue(match.ambiguous)
                XCTAssertFalse(match.blockedCandidateFound)
            }
        }
    }

    func testTitleMatchingHandlesTruncationAndPreservesBrowserNamesInPageTitles() {
        for (windowTitle, tabTitle) in [
            ("A long title… - Google Chrome", "A long title with more words"),
            ("A long title with more words - Google Chrome", "A long title..."),
            ("Mail - Google Chrome - Settings - Google Chrome - Profile", "Mail - Google Chrome - Settings")
        ] {
            let tabs = [BrowserTabInfo(tabId: 1, title: tabTitle, url: allowedURL, active: true)]
            let match = NativeBrowserSiteRules.matchActiveTab(windowTitle: windowTitle, tabs: tabs, rules: deny)
            XCTAssertEqual(match.url, allowedURL, windowTitle)
            XCTAssertFalse(match.ambiguous, windowTitle)
        }
    }

    func testAsyncGuardUsesTheUnfilteredBridgeListingWhenAXIsUnavailable() async throws {
        let savedRules = TargetRulesStore.shared.rules
        TargetRulesStore.shared.update(deny, persist: false)
        defer { TargetRulesStore.shared.update(savedRules, persist: false) }

        let keyDir = makeTemporaryBridgeKeyDirectory()
        defer { try? FileManager.default.removeItem(at: keyDir) }
        let bridge = ChromeExtensionBridge(port: 0, pairingStore: BridgePairingStore(directory: keyDir))
        bridge.start()
        defer { bridge.stop() }
        let port = await waitForListeningPort(of: bridge)
        let key = try XCTUnwrap(bridge.pairingKeyText().flatMap(BridgeKey.init(text:)))
        let profile = "Site rules"
        let extensionSocket = try await connectAuthenticatedMockExtension(port: port, key: key, profileName: profile, tabCount: 2)
        defer { extensionSocket.cancel(with: .goingAway, reason: nil) }
        let ready = await waitForBridgeCondition { bridge.connectedProfiles().first?.profileName == profile }
        XCTAssertTrue(ready)

        let vaultURL = blockedURL
        let mailURL = allowedURL
        let responder = Task {
            while !Task.isCancelled {
                let request = try await receiveBridgeJSON(from: extensionSocket)
                guard request["command"] as? String == "tabs", let id = request["id"] as? String else { continue }
                try await sendBridgeJSON([
                    "type": "response", "id": id, "ok": true, "profileName": profile,
                    "tabs": [
                        ["tabId": 1, "title": "Vault", "url": vaultURL, "active": true],
                        ["tabId": 2, "title": "Mail", "url": mailURL, "active": true]
                    ]
                ], on: extensionSocket)
            }
        }
        defer { responder.cancel() }

        let blocked = await NativeBrowserSiteRules.blockedMessage(for: chrome(title: "Vault - Google Chrome"), rules: deny, chromeBridge: bridge)
        XCTAssertEqual(blocked, blockedSite)
        let allowed = await NativeBrowserSiteRules.blockedMessage(for: chrome(title: "Mail - Google Chrome"), rules: deny, chromeBridge: bridge)
        XCTAssertNil(allowed)
    }

    func testAsyncGuardRejectsCaseInsensitiveDuplicateProfileNames() async throws {
        let keyDir = makeTemporaryBridgeKeyDirectory()
        defer { try? FileManager.default.removeItem(at: keyDir) }
        let bridge = ChromeExtensionBridge(port: 0, pairingStore: BridgePairingStore(directory: keyDir))
        bridge.start()
        defer { bridge.stop() }
        let port = await waitForListeningPort(of: bridge)
        let key = try XCTUnwrap(bridge.pairingKeyText().flatMap(BridgeKey.init(text:)))
        let first = try await connectAuthenticatedMockExtension(port: port, key: key, profileName: "Work", tabCount: 1)
        defer { first.cancel(with: .goingAway, reason: nil) }
        let second = try await connectAuthenticatedMockExtension(port: port, key: key, profileName: "work", tabCount: 1)
        defer { second.cancel(with: .goingAway, reason: nil) }
        let ready = await waitForBridgeCondition {
            Set(bridge.connectedProfiles().map(\.profileName)) == ["Work", "work"]
        }
        XCTAssertTrue(ready)

        let refusal = await NativeBrowserSiteRules.blockedMessage(for: chrome(title: "Mail"), rules: deny, chromeBridge: bridge)
        XCTAssertEqual(refusal, TargetRules.unconfirmedSiteMessage(reason: "multiple Chrome profiles share the same name"))
    }

    private func chrome(title: String? = nil) -> AppDescriptor {
        AppDescriptor(pid: 0, name: "Google Chrome", bundleId: "com.google.Chrome", isActive: true, windowTitle: title)
    }
}
