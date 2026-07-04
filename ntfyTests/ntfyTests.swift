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
}
