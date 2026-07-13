import XCTest
import UserNotifications
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

    // MARK: UNMutableNotificationContent.modify — never leak the "New message" placeholder (#1080)

    func testModifyReplacesPlaceholderWithRealBody() {
        let content = UNMutableNotificationContent()
        content.body = "New message"  // the incoming server placeholder
        let msg = Message(id: "x", time: 1, event: "message", topic: "t", message: "real body", title: "T")
        content.modify(message: msg, baseUrl: "https://ntfy.sh")
        XCTAssertEqual(content.body, "real body")
    }

    func testModifyNeverLeaksPlaceholderForBodylessMessage() {
        // A title-only (or attachment-only) message has message.message == nil. Before the fix the
        // body kept the incoming "New message" placeholder; now it must be cleared. (#1080 regression)
        let content = UNMutableNotificationContent()
        content.body = "New message"
        let msg = Message(id: "x", time: 1, event: "message", topic: "t", message: nil, title: "Only Title")
        content.modify(message: msg, baseUrl: "https://ntfy.sh")
        XCTAssertNotEqual(content.body, "New message",
                          "a processed message must never show the raw push placeholder")
    }

    // MARK: Message.icon — per-message icon field (#1107), poll + push paths

    func testMessageDecodesIconFromJson() throws {
        let json = #"{"id":"x","time":1,"event":"message","topic":"t","message":"hi","icon":"https://ntfy.sh/i.png"}"#.data(using: .utf8)!
        let m = try JSONDecoder().decode(Message.self, from: json)
        XCTAssertEqual(m.icon, "https://ntfy.sh/i.png")
    }

    func testMessageIconRoundTripsThroughUserInfo() {
        // push/NSE path: toUserInfo -> from(userInfo:) must preserve the icon
        let m = Message(id: "x", time: 1, event: "message", topic: "t", message: "hi",
                        icon: "https://ntfy.sh/i.png")
        XCTAssertEqual(Message.from(userInfo: m.toUserInfo())?.icon, "https://ntfy.sh/i.png")
    }

    func testMessageIconAbsentNormalizesToNil() throws {
        let json = #"{"id":"x","time":1,"event":"message","topic":"t","message":"hi"}"#.data(using: .utf8)!
        let m = try JSONDecoder().decode(Message.self, from: json)
        XCTAssertNil(m.icon)
        // empty "" in userInfo must come back as nil, not empty string
        XCTAssertNil(Message.from(userInfo: m.toUserInfo())?.icon)
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

    func testRenderMarkdownLinkifiesBareUrls() {
        // A bare URL inside a markdown message must be tappable too — Foundation's
        // markdown parser only links [text](url)/<url>, not bare "https://…", so the
        // plain-text path linkified it while the markdown path left it dead (#1743 parity).
        let out = renderMessageBody("visit https://ntfy.sh now", contentType: "text/markdown")
        XCTAssertTrue(out.runs.contains { $0.link != nil }, "bare URLs in markdown should be linkified")
    }

    func testRenderMarkdownBareUrlLinkCoexistsWithBold() {
        // Adding bare-URL linkification must not clobber markdown's own styling runs.
        let out = renderMessageBody("**bold** see https://ntfy.sh", contentType: "text/markdown")
        XCTAssertFalse(String(out.characters).contains("**"), "markdown bold syntax should still be consumed")
        XCTAssertTrue(out.runs.contains { $0.link != nil }, "the bare URL should still become a link")
    }

    func testRenderMarkdownAuthoredLinkPreserved() {
        // An explicit markdown link must keep its target (label != URL), not be overwritten
        // by the bare-URL detector pass.
        let out = renderMessageBody("see [ntfy](https://ntfy.sh) here", contentType: "text/markdown")
        XCTAssertFalse(String(out.characters).contains("]("), "link markdown syntax should be consumed")
        XCTAssertTrue(out.runs.contains { $0.link != nil }, "the authored link run should survive")
    }

    // MARK: Helpers — URL/tag utilities (rebase-regression coverage)

    func testNormalizeBaseUrlStripsTrailingSlashesAndWhitespace() {
        XCTAssertEqual(normalizeBaseUrl("https://ntfy.sh/"), "https://ntfy.sh")
        XCTAssertEqual(normalizeBaseUrl("https://ntfy.sh///"), "https://ntfy.sh")
        XCTAssertEqual(normalizeBaseUrl("  https://ntfy.sh/  "), "https://ntfy.sh")
        XCTAssertEqual(normalizeBaseUrl("https://ntfy.sh"), "https://ntfy.sh")
    }

    func testTopicUrlAndShortUrl() {
        XCTAssertEqual(topicUrl(baseUrl: "https://ntfy.sh/", topic: "mytopic"), "https://ntfy.sh/mytopic")
        XCTAssertEqual(shortUrl(url: "https://ntfy.sh/mytopic"), "ntfy.sh/mytopic")
        XCTAssertEqual(topicShortUrl(baseUrl: "https://ntfy.sh/", topic: "mytopic"), "ntfy.sh/mytopic")
    }

    func testParseAllTagsTrimsAndDropsEmpties() {
        // spaces after commas must not leak into tag names (they break emoji lookup + display)
        XCTAssertEqual(parseAllTags("tag1, tag2 ,  ,tag3"), ["tag1", "tag2", "tag3"])
        XCTAssertEqual(parseAllTags(""), [])
        XCTAssertEqual(parseAllTags(nil), [])
    }

    func testFirebaseTopicHashesForNonDefaultServer() {
        // A clearly non-default self-hosted server must map to a 64-char SHA-256 hex hash,
        // never the raw topic (which would leak across servers on the shared FCM sender).
        let t = firebaseTopic(baseUrl: "https://ntfy.example-selfhosted-12345.tld", topic: "secret")
        XCTAssertEqual(t.count, 64)
        XCTAssertTrue(t.allSatisfy { $0.isHexDigit })
        XCTAssertNotEqual(t, "secret")
        // deterministic
        XCTAssertEqual(t, firebaseTopic(baseUrl: "https://ntfy.example-selfhosted-12345.tld", topic: "secret"))
    }

    // MARK: Notification.format{Message,Title} — title/message/emoji placement rules
    // (deterministic assertions only — no dependency on the emoji dataset)

    private func makeNotification(message: String?, title: String?, tags: String? = nil) -> ntfy.Notification {
        let n = ntfy.Notification(context: Store.shared.context)  // in-memory under XCTest; ntfy. disambiguates from Foundation.Notification
        n.message = message
        n.title = title
        n.tags = tags
        return n
    }

    func testFormatMessagePlainWhenNoTitleNoTags() {
        XCTAssertEqual(makeNotification(message: "hello", title: nil, tags: nil).formatMessage(), "hello")
    }

    func testFormatMessageIsUnchangedWhenTitlePresent() {
        // With a title, emoji tags decorate the TITLE, so the message body is untouched.
        XCTAssertEqual(makeNotification(message: "hello", title: "Header", tags: "warning").formatMessage(), "hello")
    }

    func testFormatMessageNilMessageIsEmptyString() {
        XCTAssertEqual(makeNotification(message: nil, title: nil, tags: nil).formatMessage(), "")
    }

    func testFormatTitleNilWhenNoTitle() {
        XCTAssertNil(makeNotification(message: "hello", title: nil, tags: "warning").formatTitle())
        XCTAssertNil(makeNotification(message: "hello", title: "", tags: nil).formatTitle())
    }

    func testFormatTitleReturnsTitleWhenNoTags() {
        XCTAssertEqual(makeNotification(message: "hello", title: "Header", tags: nil).formatTitle(), "Header")
    }

    // MARK: UNMutableNotificationContent.modify — priority → interruption level / relevance (critical alerts, ntfy #1235)
    //
    // These pin the flagship critical-alerts mapping (the 47-reaction #1235, implemented on main but
    // previously with zero unit coverage). The priority switch in NotificationContent.modify() *is* the
    // feature: p5 only elevates to `.critical` when the user opted in (getCriticalAlertsEnabled) AND iOS
    // granted the critical-alert entitlement (getCriticalAlertsAuthorized) — otherwise it must fall back
    // to `.timeSensitive`. A silent regression there (e.g. dropping the entitlement gate, or reordering
    // the relevanceScore ranking) is exactly the class of break a unit test catches before a device
    // round-trip. All inputs are deterministic under XCTest: Store.shared is in-memory (Store.swift:26)
    // and both critical-alerts flags are test-settable (Core Data preference + app-group UserDefaults).

    override func tearDown() {
        // Critical-alerts state is process-global (Store.shared + shared UserDefaults); reset so the
        // p5 tests can't leak enabled/authorized into each other regardless of execution order.
        Store.shared.saveCriticalAlertsEnabled(false)
        Store.saveCriticalAlertsAuthorized(false)
        super.tearDown()
    }

    private func modifiedContent(priority: Int16?, title: String? = "T", baseUrl: String = "https://ntfy.sh") -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        let msg = Message(id: "x", time: 1, event: "message", topic: "mytopic",
                          message: "body", title: title, priority: priority)
        content.modify(message: msg, baseUrl: baseUrl)
        return content
    }

    func testModifyPriority1IsPassiveAndLowestRelevance() {
        let c = modifiedContent(priority: 1)
        XCTAssertEqual(c.interruptionLevel, .passive)
        XCTAssertEqual(c.relevanceScore, 0, accuracy: 0.0001)
    }

    func testModifyPriority2IsPassiveAndLowRelevance() {
        let c = modifiedContent(priority: 2)
        XCTAssertEqual(c.interruptionLevel, .passive)
        XCTAssertEqual(c.relevanceScore, 0.25, accuracy: 0.0001)
    }

    func testModifyPriority4IsTimeSensitive() {
        let c = modifiedContent(priority: 4)
        XCTAssertEqual(c.interruptionLevel, .timeSensitive)
        XCTAssertEqual(c.relevanceScore, 0.75, accuracy: 0.0001)
    }

    func testModifyDefaultPriorityIsActive() {
        // Priority 3 (server default) and an absent priority both fall through to the `default` branch.
        for p: Int16? in [3, nil] {
            let c = modifiedContent(priority: p)
            XCTAssertEqual(c.interruptionLevel, .active, "priority \(String(describing: p)) should be .active")
            XCTAssertEqual(c.relevanceScore, 0.5, accuracy: 0.0001)
        }
    }

    func testModifyPriority5IsCriticalOnlyWhenEnabledAndAuthorized() {
        Store.shared.saveCriticalAlertsEnabled(true)
        Store.saveCriticalAlertsAuthorized(true)
        let c = modifiedContent(priority: 5)
        XCTAssertEqual(c.interruptionLevel, .critical, "p5 with opt-in + entitlement must be .critical")
        XCTAssertEqual(c.relevanceScore, 1, accuracy: 0.0001)
    }

    func testModifyPriority5FallsBackToTimeSensitiveWhenNotAuthorized() {
        // Opted in, but iOS has NOT granted the critical-alert entitlement → must never use .critical.
        Store.shared.saveCriticalAlertsEnabled(true)
        Store.saveCriticalAlertsAuthorized(false)
        let c = modifiedContent(priority: 5)
        XCTAssertEqual(c.interruptionLevel, .timeSensitive)
        XCTAssertEqual(c.relevanceScore, 1, accuracy: 0.0001)
    }

    func testModifyPriority5FallsBackToTimeSensitiveWhenNotEnabled() {
        // Entitlement granted, but the user hasn't opted in → must never use .critical.
        Store.shared.saveCriticalAlertsEnabled(false)
        Store.saveCriticalAlertsAuthorized(true)
        let c = modifiedContent(priority: 5)
        XCTAssertEqual(c.interruptionLevel, .timeSensitive)
        XCTAssertEqual(c.relevanceScore, 1, accuracy: 0.0001)
    }

    // MARK: UNMutableNotificationContent.modify — title falls back to the short topic URL

    func testModifyUsesTopicShortUrlWhenTitleMissing() {
        XCTAssertEqual(modifiedContent(priority: 3, title: "").title, "ntfy.sh/mytopic",
                       "an empty server title must fall back to the short topic URL")
        XCTAssertEqual(modifiedContent(priority: 3, title: nil).title, "ntfy.sh/mytopic",
                       "a missing server title must fall back to the short topic URL")
    }

    func testModifyKeepsServerTitleWhenPresent() {
        XCTAssertEqual(modifiedContent(priority: 3, title: "Header").title, "Header")
    }
}
