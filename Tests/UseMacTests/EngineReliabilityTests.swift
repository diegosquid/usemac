import Foundation
import XCTest
@testable import UseMacEngine
@testable import UseMacProtocol

/// Pure parts of the reliability pass: semantic matching, offscreen detection, stale-title comparison and
/// the new protocol fields. The live AX paths need Accessibility permission and are exercised manually.
final class EngineReliabilityTests: XCTestCase {

    // MARK: ElementMatcher

    func testMatchIgnoresCaseDiacriticsAndRolePrefix() {
        let match = ElementMatch(role: "button", title: "salvar RASCUNHO")
        XCTAssertTrue(ElementMatcher.matches(role: "AXButton", title: "Salvar rascunho", description: nil, value: nil, match: match))
        XCTAssertFalse(ElementMatcher.matches(role: "AXLink", title: "Salvar rascunho", description: nil, value: nil, match: match))

        let accented = ElementMatch(text: "ingles (estados unidos)")
        XCTAssertTrue(ElementMatcher.matches(role: "AXStaticText", title: nil, description: nil, value: "inglês (Estados Unidos)", match: accented))
    }

    func testMatchTitleChecksDescriptionToo() {
        let match = ElementMatch(title: "Enviar para análise")
        XCTAssertTrue(ElementMatcher.matches(role: "AXButton", title: nil, description: "Enviar para análise", value: nil, match: match))
    }

    func testExactMatchRequiresEquality() {
        let match = ElementMatch(value: "usemaccws-icon.png", exact: true)
        XCTAssertTrue(ElementMatcher.matches(role: "AXTextField", title: nil, description: nil, value: "usemaccws-icon.png", match: match))
        XCTAssertFalse(ElementMatcher.matches(role: "AXTextField", title: nil, description: nil, value: "usemaccws-icon.png.bak", match: match))
    }

    func testAllGivenFieldsMustMatch() {
        let match = ElementMatch(role: "AXComboBox", title: "Idioma", value: "inglês")
        XCTAssertTrue(ElementMatcher.matches(role: "AXComboBox", title: "Idioma", description: nil, value: "inglês (Estados Unidos)", match: match))
        XCTAssertFalse(ElementMatcher.matches(role: "AXComboBox", title: "Idioma", description: nil, value: "assamês", match: match))
    }

    func testEmptyMatchNeverMatches() {
        XCTAssertFalse(ElementMatcher.matches(role: "AXButton", title: "OK", description: nil, value: nil, match: ElementMatch()))
    }

    func testWhitespaceIsCollapsed() {
        XCTAssertEqual(ElementMatcher.normalize("  Página   \"Detalhes\n do app\" "), "pagina \"detalhes do app\"")
    }

    // MARK: Offscreen

    func testZeroSizeAndMissingFramesAreOffscreen() {
        let viewport = ScreenRect(x: 0, y: 25, width: 2560, height: 1333)
        XCTAssertTrue(AXIndexer.isOffscreen(frame: nil, viewport: viewport))
        XCTAssertTrue(AXIndexer.isOffscreen(frame: ScreenRect(x: 512, y: 962, width: 336, height: 0), viewport: viewport))
        XCTAssertFalse(AXIndexer.isOffscreen(frame: ScreenRect(x: 512, y: 926, width: 336, height: 36), viewport: viewport))
    }

    func testFramesOutsideTheWindowAreOffscreen() {
        let viewport = ScreenRect(x: 0, y: 25, width: 1280, height: 800)
        XCTAssertTrue(AXIndexer.isOffscreen(frame: ScreenRect(x: 100, y: 2000, width: 300, height: 40), viewport: viewport))
        XCTAssertFalse(AXIndexer.isOffscreen(frame: ScreenRect(x: 100, y: 800, width: 300, height: 40), viewport: viewport))
    }

    func testCompactLineMarksOffscreenInsteadOfFrame() {
        let node = ElementNode(id: "@e7", role: "AXStaticText", value: "inglês", frame: ScreenRect(x: 0, y: 0, width: 0, height: 0), offscreen: true)
        XCTAssertTrue(node.compactLine.contains("(offscreen)"))
        XCTAssertFalse(node.compactLine.contains("0x0"))
    }

    // MARK: Stale snapshot titles

    func testComparableTitleIgnoresCountersAndEmoji() {
        XCTAssertEqual(
            ActionExecutor.comparableTitle("Inbox (60.421) - someone - Mail"),
            ActionExecutor.comparableTitle("Inbox (60.423) - someone - Mail")
        )
        XCTAssertEqual(
            ActionExecutor.comparableTitle("Distribuição 🔊"),
            ActionExecutor.comparableTitle("Distribuição")
        )
        XCTAssertNotEqual(
            ActionExecutor.comparableTitle("Caixa de entrada (60.421) - Gmail"),
            ActionExecutor.comparableTitle("Confirme seu endereço de e-mail de contato - Gmail")
        )
    }

    // MARK: Protocol

    func testNewActFieldsDecode() throws {
        let json = """
        {"app":"Google Chrome","expectWindowTitle":"Detalhes do app","allowStaleSnapshot":true,"foreground":true,
         "steps":[
           {"action":"click","match":{"role":"AXButton","title":"Salvar rascunho","index":1}},
           {"action":"axAction","elementId":"@e125","actionName":"AXOpen"},
           {"action":"waitFor","match":{"text":"Item salvo"},"timeoutMs":4000},
           {"action":"waitFor","match":{"role":"AXSheet"},"gone":true},
           {"action":"scrollIntoView","match":{"text":"inglês (Estados Unidos)","exact":true}}
         ]}
        """
        let request = try JSONDecoder().decode(BatchActionRequest.self, from: Data(json.utf8))
        XCTAssertEqual(request.expectWindowTitle, "Detalhes do app")
        XCTAssertEqual(request.allowStaleSnapshot, true)
        XCTAssertEqual(request.foreground, true)
        XCTAssertEqual(request.steps[0].match?.index, 1)
        XCTAssertEqual(request.steps[1].action, .axAction)
        XCTAssertEqual(request.steps[1].actionName, "AXOpen")
        XCTAssertEqual(request.steps[2].timeoutMs, 4000)
        XCTAssertEqual(request.steps[3].gone, true)
        XCTAssertEqual(request.steps[4].match?.exact, true)
        // Defaults stay as before.
        XCTAssertTrue(request.stopOnError)
        XCTAssertTrue(request.returnObservation)
    }

    func testStepResultEncodesEffectAndCodes() throws {
        let result = ActionStepResult(
            index: 0, action: .scroll, success: true, mechanism: "cgevent-pid-scroll", latencyMs: 3,
            errorCode: nil, effect: ActionEffect.none, warning: "Nothing moved.", resolvedElementId: "@e9"
        )
        let data = try JSONEncoder().encode(result)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["effect"] as? String, "none")
        XCTAssertEqual(object["warning"] as? String, "Nothing moved.")
        XCTAssertEqual(object["resolvedElementId"] as? String, "@e9")
    }

    func testOldPayloadsStillDecode() throws {
        let json = #"{"steps":[{"action":"click","elementId":"@e3"}]}"#
        let request = try JSONDecoder().decode(BatchActionRequest.self, from: Data(json.utf8))
        XCTAssertNil(request.foreground)
        XCTAssertNil(request.steps[0].match)
        let node = try JSONDecoder().decode(ElementNode.self, from: Data(#"{"id":"@e1","role":"AXButton","enabled":true,"focused":false,"frame":{"x":0,"y":0,"width":10,"height":10},"actions":[]}"#.utf8))
        XCTAssertNil(node.offscreen)
    }

    // MARK: Chrome preview privacy

    func testChromeWindowStreamsOnlyWhenItShowsAUsemacTab() {
        let tabs = [
            BrowserTabInfo(tabId: 1, windowId: 10, title: "Weekend plans : r/example", url: "https://forum.example.com", active: true),
            BrowserTabInfo(tabId: 2, windowId: 20, title: "App Store Connect", url: "https://appstoreconnect.apple.com/apps", active: true, usemac: true),
            BrowserTabInfo(tabId: 3, windowId: 20, title: "Gmail", url: "https://mail.google.com", active: false, usemac: true)
        ]
        // The user's own active tab never streams.
        XCTAssertFalse(UsemacTabPrivacy.windowShowsUsemacTab(windowTitle: "Weekend plans : r/example", tabs: tabs))
        // An active UseMac tab streams, even with Chrome's audio indicator after the title.
        XCTAssertTrue(UsemacTabPrivacy.windowShowsUsemacTab(windowTitle: "App Store Connect", tabs: tabs))
        XCTAssertTrue(UsemacTabPrivacy.windowShowsUsemacTab(windowTitle: "App Store Connect 🔊", tabs: tabs))
        // A UseMac tab that is not the active one does not make its window streamable.
        XCTAssertFalse(UsemacTabPrivacy.windowShowsUsemacTab(windowTitle: "Gmail", tabs: tabs))
        XCTAssertFalse(UsemacTabPrivacy.windowShowsUsemacTab(windowTitle: "", tabs: tabs))
    }

    // MARK: Executor refusals that need no Accessibility

    func testWaitForWithoutTargetAppFails() async {
        let executor = ActionExecutor(axIndexer: AXIndexer(), workspaceMonitor: WorkspaceMonitor(), killSwitch: KillSwitch())
        let request = BatchActionRequest(app: "no-such-app-\(UUID().uuidString)", steps: [
            ActionStep(action: .waitFor, match: ElementMatch(text: "anything"), timeoutMs: 200)
        ], returnObservation: false)
        let (result, _) = await executor.executeBatch(request)
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.stepResults.first?.errorCode, "APP_NOT_FOUND")
    }

    func testAxActionNeedsActionName() async {
        let executor = ActionExecutor(axIndexer: AXIndexer(), workspaceMonitor: WorkspaceMonitor(), killSwitch: KillSwitch())
        let request = BatchActionRequest(app: "no-such-app-\(UUID().uuidString)", steps: [
            ActionStep(action: .axAction)
        ], returnObservation: false)
        let (result, _) = await executor.executeBatch(request)
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.stepResults.first?.errorCode, "INVALID_REQUEST")
    }

    func testUnknownElementIdIsReportedNotClicked() async {
        let executor = ActionExecutor(axIndexer: AXIndexer(), workspaceMonitor: WorkspaceMonitor(), killSwitch: KillSwitch())
        let request = BatchActionRequest(app: "no-such-app-\(UUID().uuidString)", steps: [
            ActionStep(action: .click, elementId: "@e999999")
        ], returnObservation: false)
        let (result, _) = await executor.executeBatch(request)
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.stepResults.first?.errorCode, "ELEMENT_NOT_FOUND")
    }
}
