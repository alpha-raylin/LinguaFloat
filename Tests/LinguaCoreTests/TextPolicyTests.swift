import XCTest
@testable import LinguaCore
final class TextPolicyTests: XCTestCase {
    func testRoundTripUnicodeAndCode() throws {
        let input = "請執行 `git status`\n```swift\nlet x = 1\n```\nhttps://example.com/a /tmp/file.txt"
        let protected = ProtectedText(input)
        XCTAssertFalse(protected.text.contains("git status"))
        XCTAssertEqual(try protected.restore(protected.text), input)
    }
    func testMissingTokenRejected() {
        let protected = ProtectedText("Run `rm example.txt`")
        XCTAssertThrowsError(try protected.restore("Run something"))
    }
    func testDuplicateTokenRejected() {
        let protected = ProtectedText("`git diff`")
        XCTAssertThrowsError(try protected.restore(protected.text + protected.text))
    }
    func testStaleOrWrongProcessRejected() {
        XCTAssertFalse(TextPolicy.canReplace(original: "hello", current: "hello world", pid: 1, currentPID: 1))
        XCTAssertFalse(TextPolicy.canReplace(original: "hello", current: "hello", pid: 1, currentPID: 2))
        XCTAssertTrue(TextPolicy.canReplace(original: "hello", current: "hello", pid: 1, currentPID: 1))
    }
}
