import XCTest
@testable import ntfy

/// Seed unit-test suite for ntfy iOS NextGen.
///
/// This target exists so `test_sim` is a real verification step (it was a no-op
/// before — the project shipped with no test target). These assertions exercise
/// pure, deterministic app logic through `@testable import ntfy`; future fixes
/// add their regression tests here.
final class ntfyTests: XCTestCase {

    // MARK: BasicUser.toHeader() — deterministic Basic-auth header

    func testBasicUserHeaderIsExpectedBase64() {
        let user = BasicUser(username: "phil", password: "mypass")
        // base64("phil:mypass") == "cGhpbDpteXBhc3M="
        XCTAssertEqual(user.toHeader(), "Basic cGhpbDpteXBhc3M=")
    }

    // MARK: Actions.parse — guards + supported-action filtering

    func testActionsParseReturnsNilForNilAndEmpty() {
        XCTAssertNil(Actions.shared.parse(nil))
        XCTAssertNil(Actions.shared.parse(""))
    }

    func testActionsParseFiltersUnsupportedActions() {
        let json = """
        [{"id":"1","action":"view","label":"Open","url":"https://ntfy.sh"},\
        {"id":"2","action":"bogus","label":"Nope"}]
        """
        let parsed = Actions.shared.parse(json)
        // "view" is supported, "bogus" is filtered out.
        XCTAssertEqual(parsed?.count, 1)
        XCTAssertEqual(parsed?.first?.action, "view")
    }

    // MARK: Actions.encode — nil round-trips to empty string

    func testActionsEncodeNilIsEmptyString() {
        XCTAssertEqual(Actions.shared.encode(nil), "")
    }

    // MARK: renderMessageBody — markdown (#1072) vs plain-text linkification

    func testRenderMarkdownStripsSyntax() {
        // text/markdown → "**bold**" parses to "bold" (asterisks consumed = markdown applied)
        let out = renderMessageBody("**bold** text", contentType: "text/markdown")
        let plain = String(out.characters)
        XCTAssertEqual(plain, "bold text")
        XCTAssertFalse(plain.contains("**"))
    }

    func testRenderMarkdownParsesLink() {
        let out = renderMessageBody("see [ntfy](https://ntfy.sh) here", contentType: "text/markdown")
        XCTAssertFalse(String(out.characters).contains("]("), "link markdown syntax should be consumed")
        XCTAssertTrue(out.runs.contains { $0.link != nil }, "a real link run should exist")
    }

    func testRenderPlainLeavesMarkdownLiteral() {
        // no content type → markdown syntax stays literal (plain-text path)
        let out = renderMessageBody("**bold**", contentType: nil)
        XCTAssertEqual(String(out.characters), "**bold**")
    }

    func testRenderPlainLinkifiesUrls() {
        let out = renderMessageBody("visit https://ntfy.sh now", contentType: nil)
        XCTAssertTrue(out.runs.contains { $0.link != nil }, "plain-text URLs should be linkified")
    }
}
