import XCTest
@testable import LinguaCore

final class StreamingTests: XCTestCase {
    func testPartialStringFieldDecodesPrefixes() {
        XCTAssertNil(PartialJSON.stringField("text", in: ""))
        XCTAssertNil(PartialJSON.stringField("text", in: #"{"tex"#))
        XCTAssertNil(PartialJSON.stringField("text", in: #"{"text":"#))
        XCTAssertEqual(PartialJSON.stringField("text", in: #"{"text":""#), "")
        XCTAssertEqual(PartialJSON.stringField("text", in: #"{"text": "你好，wor"#), "你好，wor")
        XCTAssertEqual(PartialJSON.stringField("text", in: #"{"text":"a\nb\"c\\d\/e"#), "a\nb\"c\\d/e")
        XCTAssertEqual(PartialJSON.stringField("text", in: #"{"text":"done","explanation":"x"}"#), "done")
        XCTAssertEqual(PartialJSON.stringField("explanation", in: #"{"text":"done","explanation":"why"#), "why")
    }
    func testIncompleteEscapesAreHiddenNotShownRaw() {
        XCTAssertEqual(PartialJSON.stringField("text", in: #"{"text":"ab\"#), "ab")
        XCTAssertEqual(PartialJSON.stringField("text", in: #"{"text":"ab\u00"#), "ab")
        XCTAssertEqual(PartialJSON.stringField("text", in: #"{"text":"\u4f60\u597d"#), "你好")
        XCTAssertEqual(PartialJSON.stringField("text", in: #"{"text":"\ud83d"#), "")
        XCTAssertEqual(PartialJSON.stringField("text", in: #"{"text":"\ud83d\ude00!"#), "😀!")
    }
    func testRestorePartialSwapsCompletePlaceholdersOnly() {
        let protected = ProtectedText("see `a` and `b`")
        let keys = protected.placeholders.map(\.0)
        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(protected.restorePartial("see \(keys[1]) and \(keys[0])"), "see `a` and `b`")
        XCTAssertEqual(protected.restorePartial("see \(keys[1]) and \(keys[0].dropLast(3))"), "see `a` and ")
        XCTAssertEqual(protected.restorePartial("plain"), "plain")
    }
    func testPlacementPrefersBelowThenAboveThenPointer() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: 400, height: 220)
        let high = Placement.place(size: size, anchor: CGRect(x: 300, y: 600, width: 200, height: 20), pointer: nil, screen: screen)
        XCTAssertEqual(high.edge, .below)
        XCTAssertEqual(high.frame, CGRect(x: 300, y: 372, width: 400, height: 220))
        let low = Placement.place(size: size, anchor: CGRect(x: 1300, y: 100, width: 200, height: 20), pointer: nil, screen: screen)
        XCTAssertEqual(low.edge, .above)
        XCTAssertEqual(low.frame, CGRect(x: 1032, y: 128, width: 400, height: 220))
        let tall = Placement.place(size: CGSize(width: 400, height: 880), anchor: CGRect(x: 10, y: 400, width: 50, height: 20), pointer: nil, screen: screen)
        XCTAssertEqual(tall.edge, .free)
        XCTAssertTrue(screen.insetBy(dx: 8, dy: 8).contains(tall.frame))
        let pointer = Placement.place(size: size, anchor: nil, pointer: CGPoint(x: 700, y: 500), screen: screen)
        XCTAssertEqual(pointer.edge, .free)
        XCTAssertEqual(pointer.frame.origin, CGPoint(x: 676, y: 264))
        let huge = Placement.place(size: size, anchor: CGRect(x: 0, y: 0, width: 1440, height: 860), pointer: CGPoint(x: 700, y: 500), screen: screen)
        XCTAssertEqual(huge.frame.origin, CGPoint(x: 676, y: 264), "window-sized anchors fall back to the pointer")
        let fallback = Placement.place(size: size, anchor: CGRect(x: -5000, y: 0, width: 10, height: 10), pointer: CGPoint(x: -1, y: -1), screen: screen)
        XCTAssertEqual(fallback.frame.midX, 720)
    }
    func testResizeKeepsTheEdgeNearestTheText() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = CGRect(x: 300, y: 372, width: 400, height: 220)
        let below = Placement.resize(frame, to: 320, edge: .below, screen: screen)
        XCTAssertEqual(below.maxY, 592)
        XCTAssertEqual(below.height, 320)
        let above = Placement.resize(frame, to: 320, edge: .above, screen: screen)
        XCTAssertEqual(above.minY, 372)
        let clamped = Placement.resize(CGRect(x: 300, y: 20, width: 400, height: 220), to: 600, edge: .below, screen: screen)
        XCTAssertGreaterThanOrEqual(clamped.minY, 8)
        XCTAssertEqual(clamped.height, 600)
    }
}
