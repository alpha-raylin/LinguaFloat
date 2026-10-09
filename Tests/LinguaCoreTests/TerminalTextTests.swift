import XCTest
@testable import LinguaCore

final class TerminalTextTests: XCTestCase {
    let screen = [
        "left pane text                     │  Previous reply line one                                  ",
        "more left                          │  Previous reply line two                                  ",
        "                                   │                                                            ",
        "                                   │────────────────────────────────────────────────────────────",
        "                                   │❯ 請 幫 我 看 一 下 這 段 code                              ",
        "                                   │  wrapped second line of input                              ",
        "                                   │────────────────────────────────────────────────────────────",
        "                                   │  ~/.ssh Opus 5.5 ctx:16%                                   ",
    ]
    func testCollapseWideDropsCellPaddingOnly() {
        XCTAssertEqual(TerminalText.collapseWide("還 有 一 個  mask 已 經"), "還有一個 mask 已經")
        XCTAssertEqual(TerminalText.collapseWide("plain ascii  text"), "plain ascii  text")
        XCTAssertEqual(TerminalText.collapseWide("中 文  English 混 合"), "中文 English 混合")
    }
    func testScriptDetection() {
        XCTAssertTrue(Script.isCJK("請幫我看一下這段 code"))
        XCTAssertFalse(Script.isCJK("Please review this code 的"))
        XCTAssertFalse(Script.isCJK("1234 ---"))
    }
    func testSegmentFollowsPaneBorders() {
        let line = "abc│def│ghi"
        XCTAssertEqual(TerminalText.segment(of: line, column: 1), 0..<3)
        XCTAssertEqual(TerminalText.segment(of: line, column: 5), 4..<7)
        XCTAssertEqual(TerminalText.segment(of: line, column: 9), 8..<11)
        XCTAssertEqual(TerminalText.slice(line, 4..<7), "def")
        XCTAssertEqual(TerminalText.slice("ab", 4..<7), "")
    }
    func testInputTextTakesPromptRowAndWrappedRowsInsideThePane() {
        let text = TerminalText.inputText(lines: screen, cursorLine: 4, cursorColumn: 60)
        XCTAssertEqual(text, "請幫我看一下這段code\nwrapped second line of input")
        XCTAssertNil(TerminalText.inputText(lines: screen, cursorLine: 2, cursorColumn: 60))
        XCTAssertNil(TerminalText.inputText(lines: screen, cursorLine: 0, cursorColumn: 60), "cursor parked in output is not an input box")
        XCTAssertNil(TerminalText.inputText(lines: screen, cursorLine: 99, cursorColumn: 0))
    }
    func testNewLinesOnlyAboveCursorAndOnlyUnseen() {
        var next = screen
        next[2] = "                                   │  Fresh reply line three                                    "
        let fresh = TerminalText.newLines(previous: screen, current: next, cursorLine: 4, cursorColumn: 60)
        XCTAssertEqual(fresh, ["Fresh reply line three"])
        XCTAssertEqual(TerminalText.newLines(previous: next, current: next, cursorLine: 4, cursorColumn: 60), [])
        var typed = next
        typed[4] = "                                   │❯ more typing here                                          "
        XCTAssertEqual(TerminalText.newLines(previous: next, current: typed, cursorLine: 4, cursorColumn: 60), [], "the input box is never new content")
    }
    func testPromptPaddingAndStatusRows() {
        let rows = ["                       │❯\u{00A0}                                   ", "                       │  ~/x ctx:43%                        "]
        XCTAssertNil(TerminalText.inputText(lines: rows, cursorLine: 0, cursorColumn: 26), "an empty prompt is not a draft")
        let typed = ["                       │❯\u{00A0}hello there                        "]
        XCTAssertEqual(TerminalText.inputText(lines: typed, cursorLine: 0, cursorColumn: 30), "hello there")
        XCTAssertTrue(TerminalText.isStatus("· Ruminating… (10m 5s · ↓ 17.1k tokens)"))
        XCTAssertTrue(TerminalText.isStatus("✻ Brewed for 3m 3s · done (esc to interrupt)"))
        XCTAssertFalse(TerminalText.isStatus("⏺ Rerunning the deep capture with the test notice dismissed"))
        var next = screen
        next[2] = "                                   │· Thinking… (12s · ↓ 1.2k tokens)                            "
        XCTAssertEqual(TerminalText.newLines(previous: screen, current: next, cursorLine: 4, cursorColumn: 60), [])
    }
    func testWholesaleChangeMeansDifferentSessionNotNewOutput() {
        let other = (0..<12).map { "                                   │  Session B line \($0)                                        " } + [screen[3], screen[4], screen[6]]
        XCTAssertNil(TerminalText.newLines(previous: screen, current: other, cursorLine: 13, cursorColumn: 60))
        XCTAssertEqual(TerminalText.newLines(previous: [], current: screen, cursorLine: 4, cursorColumn: 60)?.count, 2, "first snapshot with no history is reported, callers decide to ignore it")
    }
}
