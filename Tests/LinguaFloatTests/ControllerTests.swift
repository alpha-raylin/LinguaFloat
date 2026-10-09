import XCTest
import AppKit
import ApplicationServices
@testable import LinguaFloat

@MainActor final class ControllerTests: XCTestCase {
    /// Waits up to three seconds for a condition instead of a fixed number of yields, which starve when the machine is busy.
    private func settle(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { await Task.yield(); try? await Task.sleep(for: .milliseconds(5)) }
    }
    func testPanelStaysHiddenAtLaunchAndReopensAsWorkbench() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        delegate.controller.setup(); delegate.controller.stopPolling()
        XCTAssertFalse(delegate.controller.panel.isVisible, "setup must not pop the panel over whatever the user is doing")
        delegate.controller.panel.close()
        XCTAssertFalse(delegate.controller.panel.isVisible)
        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(app))
        XCTAssertTrue(delegate.applicationShouldHandleReopen(app, hasVisibleWindows: false))
        XCTAssertTrue(delegate.controller.panel.isVisible)
        XCTAssertTrue(delegate.controller.pinned)
        XCTAssertTrue(delegate.controller.sourceExpanded)
        delegate.controller.escape()
        XCTAssertFalse(delegate.controller.panel.isVisible)
        delegate.controller.panel.close()
    }
    func testHotkeyCaptureStreamsPartialTextAndOffersSelectionReplace() async {
        let service = DelayedModel()
        let controller = Controller(makeClient: { _, _, _ in service })
        controller.setup(); controller.stopPolling()
        controller.input = "She go yesterday."
        controller.mode = .correct
        controller.run()
        await service.waitForRequests(1)
        XCTAssertTrue(controller.panel.isVisible)
        XCTAssertFalse(controller.pinned)
        await service.stream("She go yesterday.", partial: "She went")
        await settle { !controller.partial.isEmpty }
        XCTAssertEqual(controller.partial, "She went")
        XCTAssertTrue(controller.busy)
        await service.finish("She go yesterday.", text: "She went yesterday.")
        await settle { !controller.busy }
        XCTAssertEqual(controller.output, "She went yesterday.")
        XCTAssertEqual(controller.partial, "")
        XCTAssertFalse(controller.canApply, "a draft has no target to write back to")
        controller.escape()
        XCTAssertFalse(controller.panel.isVisible)
        controller.panel.close()
    }
    func testFollowEventsRouteByScriptAndNeverCancelManualWork() async {
        let service = DelayedModel()
        var languages: [String] = []
        let controller = Controller(makeClient: { _, language, _ in languages.append(language); return service })
        controller.setup(); controller.stopPolling()
        controller.settings.secondLanguage = "English"
        let element = AXUIElementCreateApplication(123)
        // Typing Chinese in a field: translated to the second language, silently (panel hidden → badge).
        let typed = TextSnapshot(text: "請幫我看一下這段程式碼", element: element, fullValue: "請幫我看一下這段程式碼", pid: 123, editable: true, kind: .field, appName: "Mail", bundleID: "com.apple.mail")
        controller.follow.handler(.typing(typed))
        await service.waitForRequests(1)
        XCTAssertEqual(controller.mode, .translateSecond)
        XCTAssertEqual(languages.last, "English")
        XCTAssertFalse(controller.panel.isVisible)
        await service.finish(typed.text, text: "Please take a look at this code")
        await settle { !controller.busy }
        XCTAssertTrue(controller.hasSuggestion)
        XCTAssertTrue(controller.canApply, "a whole editable field can be replaced")
        // New English terminal output: translated to the reading language, silently.
        let english = TextSnapshot(text: "Rerunning the deep capture with the test notice dismissed", element: element, fullValue: nil, pid: 123, editable: false, kind: .stream, appName: "iTerm2", bundleID: "com.googlecode.iterm2")
        controller.follow.handler(.content(english.text, english))
        await service.waitForRequests(1)
        XCTAssertEqual(controller.mode, .translate)
        XCTAssertEqual(languages.last, controller.settings.language)
        XCTAssertFalse(controller.panel.isVisible)
        XCTAssertEqual(controller.source?.kind, .stream)
        await service.finish(english.text, text: "重新執行深度擷取")
        await settle { !controller.busy }
        XCTAssertTrue(controller.hasSuggestion)
        XCTAssertFalse(controller.canApply, "terminal output is never written back")
        // New terminal output already in Chinese: nothing to translate.
        let stream = TextSnapshot(text: "這是中文的新回覆內容", element: element, fullValue: nil, pid: 123, editable: false, kind: .stream, bundleID: "com.googlecode.iterm2")
        controller.follow.handler(.content(stream.text, stream))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(controller.busy)
        // A manual request in flight is never cancelled by a follow event.
        controller.input = "manual draft"
        controller.draft(correct: false)
        await service.waitForRequests(1)
        let count = await service.requestCount
        controller.follow.handler(.selection(TextSnapshot(text: "selected words", element: element, fullValue: nil, pid: 123, editable: false, kind: .selection)))
        for _ in 0..<10 { await Task.yield() }
        let after = await service.requestCount
        XCTAssertEqual(after, count)
        XCTAssertEqual(controller.input, "manual draft")
        controller.invalidate()
        // A settled selection is user-initiated: it shows the panel.
        controller.follow.handler(.selection(TextSnapshot(text: "selected words", element: element, fullValue: nil, pid: 123, editable: false, kind: .selection)))
        await service.waitForRequests(1)
        XCTAssertTrue(controller.panel.isVisible)
        XCTAssertEqual(controller.mode, .translate)
        controller.invalidate()
        controller.panel.close()
    }
    func testTranslationModelOnlyServesTranslateMode() async {
        let service = DelayedModel()
        var plainFlags: [Bool] = []
        let controller = Controller(makeClient: { _, _, plain in plainFlags.append(plain); return service })
        controller.settings.translationModel = "translategemma:4b"
        defer { controller.settings.translationModel = "" }
        controller.input = "hello"
        controller.draft(correct: false)
        await service.waitForRequests(1)
        controller.invalidate()
        controller.draft(correct: true)
        await service.waitForRequests(1)
        controller.invalidate()
        controller.settings.translationModel = "  "
        controller.draft(correct: false)
        await service.waitForRequests(1)
        controller.invalidate()
        XCTAssertEqual(plainFlags, [true, false, false])
    }
    func testWindowCaptureWaitsForConfirmationAndEscapeHides() async {
        let service = DelayedModel()
        let controller = Controller(makeClient: { _, _, _ in service })
        controller.setup(); controller.stopPolling()
        controller.pendingWindowCapture = true
        controller.input = "menu menu body"
        controller.escape()
        XCTAssertFalse(controller.pendingWindowCapture)
        XCTAssertFalse(controller.busy)
        controller.pendingWindowCapture = true
        controller.confirmWindowCapture()
        await service.waitForRequests(1)
        XCTAssertTrue(controller.busy)
        XCTAssertFalse(controller.pendingWindowCapture)
        controller.escape()
        XCTAssertFalse(controller.busy, "Esc while working cancels instead of hiding")
        XCTAssertTrue(controller.panel.isVisible)
        controller.panel.close()
    }
    func testCancelledLateResultCannotOverwriteNewResult() async throws {
        let service = DelayedModel()
        let controller = Controller(makeClient: { _, _, _ in service })
        controller.input = "old"
        controller.draft(correct: true)
        await service.waitForRequests(1)
        controller.input = "new"
        controller.draft(correct: true)
        await service.waitForRequests(2)
        await service.finish("new", text: "new result")
        await settle { !controller.busy }
        XCTAssertEqual(controller.output, "new result")
        await service.finish("old", text: "stale result")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(controller.output, "new result")
        XCTAssertFalse(controller.busy)
    }
    func testDraftEditInvalidatesInFlightResult() async {
        let service = DelayedModel()
        let controller = Controller(makeClient: { _, _, _ in service })
        controller.input = "old"
        controller.draft(correct: false)
        await service.waitForRequests(1)
        controller.input = "edited"
        controller.draftChanged()
        await service.finish("old", text: "stale result")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(controller.output, "")
        XCTAssertFalse(controller.canApply)
        XCTAssertFalse(controller.busy)
    }
    func testTypingWithoutResultDoesNotReportCancellation() {
        let controller = Controller(makeClient: { _, _, _ in DelayedModel() })
        controller.input = "h"
        controller.draftChanged()
        XCTAssertEqual(controller.tone, .idle)
        XCTAssertEqual(controller.status, Controller.idleHint)
    }
    func testFailureShowsErrorAndRetryReusesMode() async {
        let service = FailingModel()
        let controller = Controller(makeClient: { _, _, _ in service })
        controller.input = "text"
        controller.mode = .correct
        controller.run()
        await settle { !controller.busy }
        XCTAssertTrue(controller.showsError)
        XCTAssertEqual(controller.lastCorrect, true)
        controller.retry()
        await settle { !controller.busy }
        let modes = await service.modes
        XCTAssertEqual(modes, [true, true])
    }
}

private actor FailingModel: ModelRunning {
    private(set) var modes: [Bool] = []
    func run(_ input: String, correct: Bool, progress: @escaping (String) async -> Void) async throws -> LanguageResult {
        modes.append(correct)
        throw AppError.message("模型請求逾時")
    }
}

private actor DelayedModel: ModelRunning {
    private var pending: [String: CheckedContinuation<LanguageResult, Never>] = [:]
    private var progress: [String: (String) async -> Void] = [:]
    private(set) var requestCount = 0
    func run(_ input: String, correct: Bool, progress: @escaping (String) async -> Void) async throws -> LanguageResult {
        requestCount += 1
        self.progress[input] = progress
        return await withCheckedContinuation { pending[input] = $0 }
    }
    func stream(_ input: String, partial: String) async { await progress[input]?(partial) }
    func waitForRequests(_ count: Int) async {
        while pending.count < count { await Task.yield() }
    }
    func finish(_ input: String, text: String) { pending.removeValue(forKey: input)?.resume(returning: LanguageResult(text: text, explanation: "")) }
}
