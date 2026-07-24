import XCTest
import UserNotifications
import CoreData
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

    // MARK: UNMutableNotificationContent.actionCategoryIdentifier — per-action-set banner category
    // Regression: the old code registered ONE global "ntfyActions" category and rewrote it for
    // every notification, so notifications delivered close together with different buttons
    // clobbered each other's banner actions. The fix keys the category off the action set, so
    // different sets get different (stable, cross-process) ids and can't overwrite each other.

    private func action(_ id: String, _ label: String) -> Action {
        return Action(id: id, action: "http", label: label, url: "https://ntfy.sh/x",
                      method: "POST", headers: nil, body: nil, clear: nil)
    }

    func testActionCategoryEmptyForNoActions() {
        XCTAssertEqual(UNMutableNotificationContent.actionCategoryIdentifier(for: []), "")
    }

    func testActionCategoryStableAndPrefixed() {
        let set = [action("0", "Approve"), action("1", "Reject")]
        let id = UNMutableNotificationContent.actionCategoryIdentifier(for: set)
        // Deterministic: recomputing the same set yields the same id (so two notifications
        // with identical buttons safely reuse one category), and it's namespaced.
        XCTAssertEqual(id, UNMutableNotificationContent.actionCategoryIdentifier(for: set))
        XCTAssertTrue(id.hasPrefix("ntfyActions."))
    }

    func testActionCategoryDistinctForDifferentSets() {
        // The core anti-clobber property: the old code returned the SAME "ntfyActions" for
        // both of these; the fix must return DIFFERENT ids.
        let approve = UNMutableNotificationContent.actionCategoryIdentifier(for: [action("0", "Approve")])
        let openUrl = UNMutableNotificationContent.actionCategoryIdentifier(for: [action("0", "Open")])
        XCTAssertNotEqual(approve, openUrl)
    }

    func testActionCategoryRespectsFieldBoundaries() {
        // Field/record delimiters must keep ["a","bc"] distinct from ["ab","c"] and from a
        // two-action set, so no accidental collisions across genuinely different button sets.
        let a = UNMutableNotificationContent.actionCategoryIdentifier(for: [action("a", "bc")])
        let b = UNMutableNotificationContent.actionCategoryIdentifier(for: [action("ab", "c")])
        let twoActions = UNMutableNotificationContent.actionCategoryIdentifier(for: [action("a", "b"), action("c", "d")])
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, twoActions)
    }

    func testActionCategoryIsOrderSensitive() {
        // iOS renders the buttons in order, so [Approve, Reject] is a different banner than
        // [Reject, Approve] and must get its own category.
        let ab = UNMutableNotificationContent.actionCategoryIdentifier(for: [action("0", "Approve"), action("1", "Reject")])
        let ba = UNMutableNotificationContent.actionCategoryIdentifier(for: [action("1", "Reject"), action("0", "Approve")])
        XCTAssertNotEqual(ab, ba)
    }

    func testActionCategoryCapsAtFourActions() {
        // iOS renders at most 4 actions, and the category id is derived from the same 4, so a
        // difference only in a 5th (never-rendered) action does not create a new category.
        let base = [action("0", "A"), action("1", "B"), action("2", "C"), action("3", "D")]
        let plusFifth = base + [action("4", "E")]
        XCTAssertEqual(
            UNMutableNotificationContent.actionCategoryIdentifier(for: base),
            UNMutableNotificationContent.actionCategoryIdentifier(for: plusFifth)
        )
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

    private func modifiedContent(priority: Int16?, title: String? = "T", baseUrl: String = "https://ntfy.sh",
                                 displayName: String? = nil, tags: [String]? = nil) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        let msg = Message(id: "x", time: 1, event: "message", topic: "mytopic",
                          message: "body", title: title, priority: priority, tags: tags)
        content.modify(message: msg, baseUrl: baseUrl, displayName: displayName)
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

    // MARK: UNMutableNotificationContent.modify — a renamed subscription must title its notifications
    //
    // A custom display name is a third display surface alongside the subscription list and the
    // notification list header. Titleless messages are the common case, so a renamed subscription
    // whose pushes still say "ntfy.sh/mytopic" looks broken exactly where the user looks most.
    // The Android client does honor it (Util.kt formatTitle -> displayName); iOS was the outlier.

    func testModifyUsesCustomDisplayNameWhenTitleMissing() {
        XCTAssertEqual(modifiedContent(priority: 3, title: "", displayName: "Home Server").title, "Home Server",
                       "an empty server title must fall back to the subscription's custom display name")
        XCTAssertEqual(modifiedContent(priority: 3, title: nil, displayName: "Home Server").title, "Home Server",
                       "a missing server title must fall back to the subscription's custom display name")
    }

    func testModifyPrefersServerTitleOverDisplayName() {
        // The server title is the more specific signal and still wins — renaming a subscription
        // must not start overwriting per-message titles.
        XCTAssertEqual(modifiedContent(priority: 3, title: "Header", displayName: "Home Server").title, "Header")
    }

    func testModifyFallsBackToShortUrlWithoutDisplayName() {
        // Control: passes before and after the fix. Pins that the change only affects the
        // renamed case and leaves an unnamed subscription's title exactly as it was.
        XCTAssertEqual(modifiedContent(priority: 3, title: "", displayName: nil).title, "ntfy.sh/mytopic")
        XCTAssertEqual(modifiedContent(priority: 3, title: nil, displayName: nil).title, "ntfy.sh/mytopic")
    }

    func testModifyIgnoresEmptyDisplayName() {
        // Defensive: Subscription.displayName() never returns empty, but a blank name must never
        // produce a blank notification title.
        XCTAssertEqual(modifiedContent(priority: 3, title: "", displayName: "").title, "ntfy.sh/mytopic")
        XCTAssertEqual(modifiedContent(priority: 3, title: "", displayName: "   ").title, "ntfy.sh/mytopic")
    }

    func testStoreLookupSuppliesCustomDisplayNameForNotificationTitle() {
        // Observes the exact expression both modify() call sites use (AppDelegate.showNotification and
        // the NSE's handleMessage), so the renamed-subscription -> notification-title chain is covered
        // end-to-end rather than only from modify()'s parameter inward.
        // NB: don't use Store.saveSubscription here — it does a DispatchQueue.main.sync and would
        // deadlock on XCTest's main thread. Building on the context directly is enough; Core Data
        // fetches include pending changes.
        let context = Store.shared.context
        let subscription = Subscription(context: context)
        subscription.baseUrl = "https://ntfy.sh"
        subscription.topic = "renamedtopic"
        subscription.customDisplayName = "Home Server"
        defer { context.delete(subscription) }

        let displayName = Store.shared.getSubscription(baseUrl: "https://ntfy.sh", topic: "renamedtopic")?.displayName()
        XCTAssertEqual(displayName, "Home Server", "a renamed subscription must resolve to its custom name")

        let content = UNMutableNotificationContent()
        let msg = Message(id: "y", time: 1, event: "message", topic: "renamedtopic", message: "body", title: nil)
        content.modify(message: msg, baseUrl: "https://ntfy.sh", displayName: displayName)
        XCTAssertEqual(content.title, "Home Server",
                       "a titleless message on a renamed subscription must be titled with the custom name")
    }

    func testStoreLookupFallsBackToShortUrlForUnnamedSubscription() {
        // Control: an un-renamed subscription keeps the existing short-URL title.
        let context = Store.shared.context
        let subscription = Subscription(context: context)
        subscription.baseUrl = "https://ntfy.sh"
        subscription.topic = "plaintopic"
        defer { context.delete(subscription) }

        let displayName = Store.shared.getSubscription(baseUrl: "https://ntfy.sh", topic: "plaintopic")?.displayName()
        XCTAssertEqual(displayName, "ntfy.sh/plaintopic")

        let content = UNMutableNotificationContent()
        let msg = Message(id: "z", time: 1, event: "message", topic: "plaintopic", message: "body", title: nil)
        content.modify(message: msg, baseUrl: "https://ntfy.sh", displayName: displayName)
        XCTAssertEqual(content.title, "ntfy.sh/plaintopic")
    }

    func testModifyRoutesEmojisToBodyWhenTitleMissingEvenWithDisplayName() {
        // Emoji routing must not change: with no server title the emojis prefix the BODY, and the
        // display name titles the notification cleanly (matches Android formatTitle/formatMessage).
        let c = modifiedContent(priority: 3, title: "", displayName: "Home Server", tags: ["+1"])
        XCTAssertEqual(c.title, "Home Server", "emojis must not be prefixed onto the display name")
        XCTAssertEqual(c.body, "👍 body")
    }

    // MARK: attachImageIfNeeded — Settings → "Download attachments" must gate the push/NSE path too
    //
    // Settings offers Never / Always / a size cap, and the in-app attachment path honors it in three
    // places (NotificationAttachmentController.swift:39, NotificationAttachmentSectionView.swift:296,343).
    // attachImageIfNeeded — the path BOTH the app (AppDelegate.swift:177) and the notification service
    // extension (ntfyNSE/NotificationService.swift:67) use — consulted the policy nowhere, so every image
    // arriving by push was fetched over the network and persisted regardless of the setting. These tests
    // assert on whether a request is even ATTEMPTED, which is the actual promise ("Never" = no traffic);
    // asserting only on the resulting body would pass either way, since a failed download also falls back
    // to the text summary.
    //
    // The `session` seam exists so this is provable offline: RecordingURLProtocol records each request and
    // fails it immediately, so no test here touches the network. The Always/under-cap cases are controls —
    // they must show a request ATTEMPTED, which is what makes the "no request" assertions meaningful.

    /// Records every request the download session starts, then fails it — so a test can prove a
    /// download was or wasn't attempted without any network access.
    private final class RecordingURLProtocol: URLProtocol {
        private static let lock = NSLock()
        private static var recorded: [URL] = []

        static var requestedUrls: [URL] {
            lock.lock(); defer { lock.unlock() }
            return recorded
        }

        static func reset() {
            lock.lock(); defer { lock.unlock() }
            recorded = []
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            if let url = request.url {
                RecordingURLProtocol.lock.lock()
                RecordingURLProtocol.recorded.append(url)
                RecordingURLProtocol.lock.unlock()
            }
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        }

        override func stopLoading() {}
    }

    private func recordingSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecordingURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// The auto-download preference is process-global (Core Data via Store.shared), so restore the
    /// default after each test rather than leaking a policy into whatever runs next.
    private func setAutoDownloadPolicy(_ maxSize: Int64) {
        Store.shared.saveAttachmentAutoDownloadMaxSize(maxSize)
        addTeardownBlock {
            Store.shared.saveAttachmentAutoDownloadMaxSize(Store.autoDownloadDefault)
        }
    }

    private func imageAttachmentMessage(size: Int64?, expires: Int64? = nil,
                                        type: String? = "image/png",
                                        url: String = "https://ntfy.sh/file/shot.png") -> Message {
        let attachment = MessageAttachment(name: "shot.png", type: type, size: size, expires: expires, url: url)
        return Message(id: "att1", time: 1, event: "message", topic: "mytopic",
                       message: "body", title: "T", attachment: attachment)
    }

    @discardableResult
    private func runAttachImage(_ message: Message) -> UNMutableNotificationContent {
        RecordingURLProtocol.reset()
        let content = UNMutableNotificationContent()
        let done = expectation(description: "attachImageIfNeeded calls its completion handler")
        content.attachImageIfNeeded(message: message, user: nil, session: recordingSession()) {
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return content
    }

    func testAttachImageSkipsDownloadWhenPolicyIsNever() {
        setAutoDownloadPolicy(Store.autoDownloadNever)
        runAttachImage(imageAttachmentMessage(size: 1024))
        XCTAssertEqual(RecordingURLProtocol.requestedUrls, [],
                       "\"Never\" must mean no attachment traffic at all on the push path")
    }

    func testAttachImageSkipsDownloadWhenAttachmentExceedsMaxSize() {
        setAutoDownloadPolicy(Store.autoDownload100KB)
        runAttachImage(imageAttachmentMessage(size: 5 * 1024 * 1024))
        XCTAssertEqual(RecordingURLProtocol.requestedUrls, [],
                       "a 5 MB attachment must not be fetched under a 100 KB cap")
    }

    func testAttachImageSkipsDownloadForExpiredAttachment() {
        setAutoDownloadPolicy(Store.autoDownloadAlways)
        // Expired server-side: the bytes are gone, so the fetch can only waste a request and fail.
        let expired = imageAttachmentMessage(size: 1024, expires: 1)
        runAttachImage(expired)
        XCTAssertEqual(RecordingURLProtocol.requestedUrls, [],
                       "an expired attachment must not be fetched even under \"Always\"")
    }

    func testAttachImageDownloadsWhenPolicyIsAlways() {
        // CONTROL: proves the recorder sees a real attempt, so the "no request" assertions above mean something.
        setAutoDownloadPolicy(Store.autoDownloadAlways)
        runAttachImage(imageAttachmentMessage(size: 5 * 1024 * 1024))
        XCTAssertEqual(RecordingURLProtocol.requestedUrls.map(\.absoluteString),
                       ["https://ntfy.sh/file/shot.png"],
                       "\"Always\" must still fetch, regardless of size")
    }

    func testAttachImageDownloadsWhenAttachmentIsUnderMaxSize() {
        // CONTROL: the cap must gate on size, not disable downloading outright.
        setAutoDownloadPolicy(Store.autoDownload100KB)
        runAttachImage(imageAttachmentMessage(size: 50 * 1024))
        XCTAssertEqual(RecordingURLProtocol.requestedUrls.map(\.absoluteString),
                       ["https://ntfy.sh/file/shot.png"],
                       "a 50 KB attachment is under the 100 KB cap and must still be fetched")
    }

    func testAttachImageDownloadsWhenAttachmentSizeIsUnknown() {
        // CONTROL + documented parity gap: with no server-declared size, Store.shouldAutoDownloadAttachment
        // returns true, matching the in-app path. The in-app path then aborts mid-flight via
        // DownloadDelegate(maxSize:); this path has no such abort. Pinning it here so the gap is a
        // deliberate, visible decision rather than an accident.
        setAutoDownloadPolicy(Store.autoDownload100KB)
        runAttachImage(imageAttachmentMessage(size: nil))
        XCTAssertEqual(RecordingURLProtocol.requestedUrls.map(\.absoluteString),
                       ["https://ntfy.sh/file/shot.png"])
    }

    func testAttachImageNeverDownloadsNonImageAttachment() {
        // CONTROL: pre-existing guard, must survive the policy gate.
        setAutoDownloadPolicy(Store.autoDownloadAlways)
        runAttachImage(imageAttachmentMessage(size: 1024, type: "application/pdf",
                                              url: "https://ntfy.sh/file/doc.pdf"))
        XCTAssertEqual(RecordingURLProtocol.requestedUrls, [])
    }

    func testAttachImageStillSummarizesSkippedAttachmentInBody() {
        // Skipping the download must not silently drop the attachment from the notification: the user
        // still gets the name/size line, which is the same fallback a failed download produces.
        setAutoDownloadPolicy(Store.autoDownloadNever)
        let content = runAttachImage(imageAttachmentMessage(size: 1024))
        XCTAssertTrue(content.body.contains("Attachment: shot.png"),
                      "expected an attachment summary in the body, got: \(content.body)")
        XCTAssertEqual(content.attachments.count, 0)
    }

    // MARK: ApiService.checkAuth — must ALWAYS call its completion handler (ntfy #999)
    //
    // "Add subscription" sets `loading = true` and only ever clears it from inside this
    // completion handler (SubscriptionAddView.swift:153/171/174 and :180/194/197). So any
    // path through checkAuth that returns WITHOUT calling the handler leaves the Subscribe
    // button as a permanent spinner: no error, no dismissal, sheet unusable until force-quit.
    //
    // The reachable path is an unparseable URL. isAddViewValid() only requires the base URL
    // to match `^https?://.+`, and normalizeBaseUrl() trims only the OUTER whitespace — so an
    // INTERNAL space ("https://my server.com", a realistic paste/typo for a self-hosted
    // server) passes validation, then makes URL(string:) return nil inside checkAuth.
    //
    // These tests assert the handler FIRES (and fires exactly once). Asserting on the result
    // value alone would be a fake test: a never-invoked handler trivially never produces a
    // wrong value. The invalid-URL cases need no network at all — checkAuth returns before it
    // builds a session — and the rest use the `session` seam so nothing here touches the wire.

    /// Base URLs that pass `isAddViewValid()`'s `^https?://.+` but that `URL(string:)` rejects.
    private static let unparseableButValidatedBaseUrls = [
        "https://my server.com",   // internal space — the realistic typo/paste
        "https://bad|host.com",    // pipe is not a legal URL character
    ]

    private func checkAuthResult(baseUrl: String, topic: String = "mytopic",
                                 session: URLSession? = nil) -> AuthResult? {
        let done = expectation(description: "checkAuth calls its completion handler")
        var result: AuthResult?
        var callCount = 0
        ApiService.shared.checkAuth(baseUrl: baseUrl, topic: topic, user: nil, session: session) { r in
            callCount += 1
            result = r
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(callCount, 1, "completion handler must fire exactly once")
        return result
    }

    func testCheckAuthCallsHandlerForUnparseableUrl() {
        // RED before the fix: `guard let url = ... else { return }` drops the handler on the
        // floor, so the expectation times out and the Subscribe spinner would hang forever.
        for baseUrl in Self.unparseableButValidatedBaseUrls {
            guard let result = checkAuthResult(baseUrl: baseUrl) else {
                XCTFail("no result for \(baseUrl)")
                continue
            }
            guard case .Error = result else {
                return XCTFail("expected .Error for unparseable \(baseUrl), got \(result)")
            }
        }
    }

    func testUnparseableBaseUrlsGenuinelyPassAppValidation() {
        // Pins the premise of the bug: these really are reachable from the Add-subscription
        // sheet. If validation ever tightens, this fails and tells the next reader why.
        for baseUrl in Self.unparseableButValidatedBaseUrls {
            XCTAssertNotNil(baseUrl.range(of: "^https?://.+", options: .regularExpression),
                            "\(baseUrl) should pass isAddViewValid()'s regex")
            XCTAssertEqual(normalizeBaseUrl(baseUrl), baseUrl,
                           "normalizeBaseUrl must not rescue \(baseUrl)")
            XCTAssertNil(URL(string: topicAuthUrl(baseUrl: baseUrl, topic: "mytopic")),
                         "\(baseUrl) should be unparseable, otherwise this bug isn't reachable")
        }
    }

    func testCheckAuthCallsHandlerForBodylessSuccessResponse() {
        // Defence in depth for the missing terminal `else`: a 200 with no decodable body must
        // still resolve the handler rather than silently falling off the end of the chain.
        let result = checkAuthResult(baseUrl: "https://ntfy.sh",
                                     session: StubURLProtocol.session(status: 200, body: Data()))
        guard case .Error = result else {
            return XCTFail("expected .Error for a bodyless 200, got \(String(describing: result))")
        }
    }

    // Controls — these pass BOTH before and after the fix. They pin the exact axis under test
    // (handler-always-fires) and prove the change didn't alter normal auth outcomes.

    func testCheckAuthUnauthorizedControl() {
        let result = checkAuthResult(baseUrl: "https://ntfy.sh",
                                     session: StubURLProtocol.session(status: 401, body: Data()))
        guard case .Unauthorized = result else {
            return XCTFail("expected .Unauthorized for 401, got \(String(describing: result))")
        }
    }

    func testCheckAuthSuccessControl() {
        let body = #"{"success":true}"#.data(using: .utf8)!
        let result = checkAuthResult(baseUrl: "https://ntfy.sh",
                                     session: StubURLProtocol.session(status: 200, body: body))
        guard case .Success = result else {
            return XCTFail("expected .Success, got \(String(describing: result))")
        }
    }

    func testCheckAuthTransportErrorControl() {
        let result = checkAuthResult(baseUrl: "https://ntfy.sh",
                                     session: StubURLProtocol.session(failWith: URLError(.notConnectedToInternet)))
        guard case .Error = result else {
            return XCTFail("expected .Error for a transport failure, got \(String(describing: result))")
        }
    }

    /// Serves a canned HTTP response (or a canned failure) so auth outcomes are provable offline.
    private final class StubURLProtocol: URLProtocol {
        private static let lock = NSLock()
        private static var status = 200
        private static var body = Data()
        private static var failure: Error?

        static func session(status: Int = 200, body: Data = Data(), failWith error: Error? = nil) -> URLSession {
            lock.lock()
            self.status = status
            self.body = body
            self.failure = error
            lock.unlock()
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [StubURLProtocol.self]
            return URLSession(configuration: config)
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            StubURLProtocol.lock.lock()
            let status = StubURLProtocol.status
            let body = StubURLProtocol.body
            let failure = StubURLProtocol.failure
            StubURLProtocol.lock.unlock()

            if let failure = failure {
                client?.urlProtocol(self, didFailWithError: failure)
                return
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !body.isEmpty {
                client?.urlProtocol(self, didLoad: body)
            }
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    // MARK: Store writes must be safe from ANY thread — Add-subscription runs them off-main
    //
    // `Store.context` is `container.viewContext`, i.e. an NSMainQueueConcurrencyType context, so every
    // fetch/insert/save against it must happen on the main queue. `SubscriptionAddView` violated that:
    // its `checkAuth` completion runs on a URLSession delegate queue and it then hopped further onto
    // `DispatchQueue.global(qos: .background)` before calling `store.saveUser` and
    // `subscriptionManager.subscribe` (-> `store.saveSubscription`). Core Data misuse like that is
    // silent-until-it-isn't (corruption / `__Multithreading_Violation_AllThatIsLeftToUsIsHonor__`),
    // so these tests pin the *contract* rather than one crash: a Store write must complete and persist
    // whichever queue calls it, main included.
    //
    // TWO of the four tests below are red before the fix, for two DIFFERENT reasons — the old
    // `saveSubscription` did the `Subscription(context:)` insert on the caller's thread and wrapped only
    // `try? context.save()` in `DispatchQueue.main.sync`:
    //   * called from MAIN, `main.sync`-from-main deadlocks   -> testSaveSubscriptionIsSafeToCallFromTheMainThread
    //   * called from a BACKGROUND queue, the row silently does not persist (the insert landed on the
    //     wrong queue and `try?` swallowed the failure) -> testSaveSubscriptionFromABackgroundQueuePersists
    // The second one is the user-visible half: the background queue is exactly what production used, so
    // "I added a topic and it didn't stick" was reachable. It was originally written expecting to be a
    // control and it failed — recorded here rather than quietly relabelled.
    //
    // The two saveUser tests ARE genuine controls: they pass on both sides. saveUser had no `main.sync`
    // and its insert+save were already on one thread, so it was an unsound-but-not-yet-failing threading
    // violation. They pin that this change is about queue affinity without regressing persistence.
    //
    // NB on the red signal: a `main.sync`-from-main deadlock HANGS rather than fails, so the red run was
    // taken with `-default-test-execution-time-allowance 30`; the hang surfaced as "Restarting after
    // unexpected exit, crash, or test timeout". Keep that flag in mind if this test stops returning.

    private func deleteAfterTest(_ object: NSManagedObject) {
        addTeardownBlock {
            Store.shared.context.performAndWait {
                Store.shared.context.delete(object)
                try? Store.shared.context.save()
            }
        }
    }

    func testSaveSubscriptionIsSafeToCallFromTheMainThread() {
        // RED before the fix: DispatchQueue.main.sync from the main thread never returns.
        XCTAssertTrue(Thread.isMainThread, "premise: XCTest runs test methods on the main thread")

        let subscription = Store.shared.saveSubscription(baseUrl: "https://ntfy.sh", topic: "mainqueuetopic")
        deleteAfterTest(subscription)

        XCTAssertEqual(
            Store.shared.getSubscription(baseUrl: "https://ntfy.sh", topic: "mainqueuetopic")?.topic,
            "mainqueuetopic",
            "saveSubscription must return and persist when called on the context's own queue"
        )
    }

    func testSaveSubscriptionFromABackgroundQueuePersists() {
        // CONTROL: passes on both sides. Pins that the fix did not break the queue-hopping path that
        // production actually used, i.e. the change is about reentrancy, not about persistence.
        let done = expectation(description: "saveSubscription returns off-main")
        var saved: Subscription?
        DispatchQueue.global(qos: .background).async {
            let subscription = Store.shared.saveSubscription(baseUrl: "https://ntfy.sh", topic: "bgqueuetopic")
            DispatchQueue.main.async {
                saved = subscription
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 5)

        guard let saved else { return XCTFail("saveSubscription never returned from a background queue") }
        deleteAfterTest(saved)
        XCTAssertEqual(
            Store.shared.getSubscription(baseUrl: "https://ntfy.sh", topic: "bgqueuetopic")?.topic,
            "bgqueuetopic",
            "saveSubscription must still persist when called off the main queue"
        )
    }

    func testSaveUserFromABackgroundQueuePersists() {
        // CONTROL: passes on both sides. saveUser had no main.sync, so it never hung — it simply did
        // fetch/insert/save on whatever thread called it. This is the SubscriptionAddView:187 path.
        let done = expectation(description: "saveUser returns off-main")
        DispatchQueue.global(qos: .background).async {
            Store.shared.saveUser(baseUrl: "https://ntfy.example.com", username: "bguser", password: "pw")
            DispatchQueue.main.async { done.fulfill() }
        }
        wait(for: [done], timeout: 5)

        guard let user = Store.shared.getUser(baseUrl: "https://ntfy.example.com") else {
            return XCTFail("saveUser did not persist from a background queue")
        }
        deleteAfterTest(user)
        XCTAssertEqual(user.username, "bguser")
    }

    func testSaveUserFromTheMainThreadPersists() {
        // CONTROL: passes on both sides. This is the SettingsView:46 path, which was already on main.
        Store.shared.saveUser(baseUrl: "https://ntfy.main.example.com", username: "mainuser", password: "pw")

        guard let user = Store.shared.getUser(baseUrl: "https://ntfy.main.example.com") else {
            return XCTFail("saveUser did not persist from the main thread")
        }
        deleteAfterTest(user)
        XCTAssertEqual(user.username, "mainuser")
    }

    // MARK: Store READS must be safe from the push path's background queue — display-name / user resolution
    //
    // The read-side sibling of the block above. The NSE's handleMessage and AppDelegate.showNotification
    // both resolve a subscription's display name (and the Basic-auth user) before building the notification,
    // and both run OFF the main queue — handleMessage on the extension's queue, showNotification inside a
    // URLSession poll completion (ApiService.newSession sets no delegate queue). PR #20 wrote the display
    // name as getSubscription(...)?.displayName(): that fetches a viewContext-owned managed object off the
    // context's queue AND reads its properties there. getBasicUser already hopped; the display-name read
    // did not. subscriptionDisplayName(baseUrl:topic:) does the fetch and the displayName() extraction
    // inside context.performAndWait and returns a String, so it is safe from any queue.
    //
    // RED before the fix: with -com.apple.CoreData.ConcurrencyDebug 1 (this scheme's Test action) the
    // off-queue fetch traps (__Multithreading_Violation_AllThatIsLeftToUsIsHonor__), surfacing as
    // "Restarting after unexpected exit, crash, or test timeout" (same red signal as the write tests above).
    // The getBasicUser test is a genuine CONTROL: it already hopped, so it is green on both sides — it pins
    // the axis as queue affinity (not value) and covers the accessor showNotification switches to in place
    // of getUser(...)?.toBasicUser().

    func testSubscriptionDisplayNameResolvesSafelyFromABackgroundQueue() {
        let context = Store.shared.context
        let subscription = Subscription(context: context)
        subscription.baseUrl = "https://ntfy.sh"
        subscription.topic = "offmaintopic"
        subscription.customDisplayName = "Home Server"
        deleteAfterTest(subscription)

        let done = expectation(description: "subscriptionDisplayName returns off the context queue")
        var resolved: String?
        DispatchQueue.global(qos: .background).async {
            resolved = Store.shared.subscriptionDisplayName(baseUrl: "https://ntfy.sh", topic: "offmaintopic")
            done.fulfill()
        }
        wait(for: [done], timeout: 5)

        XCTAssertEqual(resolved, "Home Server",
                       "a renamed subscription must resolve to its custom name from the push path's background queue")
    }

    func testGetBasicUserResolvesSafelyFromABackgroundQueue() {
        // CONTROL: getBasicUser already wraps its fetch + toBasicUser() in performAndWait and returns a
        // value, so it is green on both sides. Covers the accessor AppDelegate.showNotification switches to.
        Store.shared.saveUser(baseUrl: "https://ntfy.offmain.example.com", username: "offmainuser", password: "pw")
        if let user = Store.shared.getUser(baseUrl: "https://ntfy.offmain.example.com") {
            deleteAfterTest(user)
        }

        let done = expectation(description: "getBasicUser returns off the context queue")
        var resolved: BasicUser?
        DispatchQueue.global(qos: .background).async {
            resolved = Store.shared.getBasicUser(baseUrl: "https://ntfy.offmain.example.com")
            done.fulfill()
        }
        wait(for: [done], timeout: 5)

        XCTAssertEqual(resolved?.username, "offmainuser",
                       "getBasicUser must resolve the Basic-auth user from a background queue without tripping the concurrency guard")
    }

    // MARK: A poll must report only NEWLY-STORED messages — repeat alerts (ntfy #1111 "ghost messages")
    //
    // `Store.saveNotifications` already computes the answer: it fetches the existing rows for the
    // incoming ids and inserts only `messages.filter { !existingIDs.contains($0.id) }`. But
    // `save(notificationsFromMessages:)` returned Void, so `SubscriptionManager.poll` handed its
    // completion handler the RAW server response, and `AppDelegate.showNotificationsSequentially`
    // (the background `~poll` wakeup, AppDelegate:140) posted one local notification per element of
    // that raw list. The store knew which messages were new; the notification layer never asked.
    //
    // The overlap is reachable in production because `since` is read per-request: `ApiService.poll`
    // builds `?poll=1&since=\(subscription.lastNotificationId ?? "all")` at request time, and four
    // call sites can have a poll in flight simultaneously (AppDelegate:134 background wakeup,
    // NotificationListView:40 onAppear, :256 after publish, SubscriptionListView:88). Two overlapping
    // polls therefore compute the SAME `since`, receive the SAME messages, and the second inserts
    // nothing — yet still re-notifies for every message. Because the banner is added with
    // `UNNotificationRequest(identifier: message.id, ...)`, iOS REPLACES the delivered notification
    // rather than stacking it, so the symptom is a repeated alert (banner + sound) for a message the
    // user already saw, not a duplicated row. `didReceiveNewData` (AppDelegate:136) was wrong for the
    // same reason: an all-duplicate poll reported `.newData` and kept spending the refresh budget.
    //
    // RED technique (per the ledger): the return value was added FIRST returning `messages`
    // unfiltered — reproducing today's behavior exactly — so the two tests below fail BEHAVIORALLY
    // rather than failing to compile. The two controls pass on both sides and pin the axis: this
    // change is about what the poll REPORTS, not about what it stores.

    private func deleteNotificationsAfterTest(ids: [String]) {
        addTeardownBlock {
            Store.shared.context.performAndWait {
                let request = Notification.fetchRequest()
                request.predicate = NSPredicate(format: "id IN %@", ids)
                for object in (try? Store.shared.context.fetch(request)) ?? [] {
                    Store.shared.context.delete(object)
                }
                try? Store.shared.context.save()
            }
        }
    }

    private func pollMessage(_ id: String, topic: String) -> Message {
        Message(id: id, time: 1, event: "message", topic: topic, message: "body-\(id)", title: nil)
    }

    func testASecondPollOfTheSameMessagesReportsNothingNew() {
        // RED before the fix: returned both messages again, so the background wakeup re-alerted both.
        let topic = "polldedupe-repeat"
        let subscription = Store.shared.saveSubscription(baseUrl: "https://ntfy.sh", topic: topic)
        deleteAfterTest(subscription)
        let messages = [pollMessage("dedupe-a1", topic: topic), pollMessage("dedupe-a2", topic: topic)]
        deleteNotificationsAfterTest(ids: messages.map(\.id))

        let first = Store.shared.save(notificationsFromMessages: messages, withSubscription: subscription)
        XCTAssertEqual(first.map(\.id), ["dedupe-a1", "dedupe-a2"], "premise: a first poll reports both messages")

        let second = Store.shared.save(notificationsFromMessages: messages, withSubscription: subscription)
        XCTAssertEqual(second.map(\.id), [], "a re-poll of already-stored messages must report nothing to notify about")
    }

    func testAnOverlappingPollReportsOnlyTheUnseenMessages() {
        // RED before the fix: reported the already-seen message alongside the genuinely new one.
        let topic = "polldedupe-overlap"
        let subscription = Store.shared.saveSubscription(baseUrl: "https://ntfy.sh", topic: topic)
        deleteAfterTest(subscription)
        let seen = pollMessage("dedupe-b1", topic: topic)
        let fresh = pollMessage("dedupe-b2", topic: topic)
        deleteNotificationsAfterTest(ids: [seen.id, fresh.id])

        _ = Store.shared.save(notificationsFromMessages: [seen], withSubscription: subscription)
        let overlapping = Store.shared.save(notificationsFromMessages: [seen, fresh], withSubscription: subscription)

        XCTAssertEqual(
            overlapping.map(\.id), ["dedupe-b2"],
            "a poll whose window overlaps stored messages must report only the ones it actually stored"
        )
    }

    func testAFirstPollReportsEveryMessage() {
        // CONTROL: passes on both sides. Pins that the filter does not over-reject — a genuine first
        // poll must still notify for everything, which is the whole point of the background wakeup.
        let topic = "polldedupe-first"
        let subscription = Store.shared.saveSubscription(baseUrl: "https://ntfy.sh", topic: topic)
        deleteAfterTest(subscription)
        let messages = [pollMessage("dedupe-c1", topic: topic), pollMessage("dedupe-c2", topic: topic)]
        deleteNotificationsAfterTest(ids: messages.map(\.id))

        let reported = Store.shared.save(notificationsFromMessages: messages, withSubscription: subscription)
        XCTAssertEqual(reported.map(\.id), ["dedupe-c1", "dedupe-c2"])
    }

    func testADeduplicatedPollStillAdvancesLastNotificationId() {
        // CONTROL: passes on both sides. `saveNotifications`' early-return branch advances
        // `lastNotificationId` even when it inserts nothing, so the next poll's `since` moves forward.
        // Reporting fewer messages must not regress that — otherwise the same window is re-fetched
        // forever and the repeat-alert bug comes back by a different route.
        let topic = "polldedupe-since"
        let subscription = Store.shared.saveSubscription(baseUrl: "https://ntfy.sh", topic: topic)
        deleteAfterTest(subscription)
        let messages = [pollMessage("dedupe-d1", topic: topic), pollMessage("dedupe-d2", topic: topic)]
        deleteNotificationsAfterTest(ids: messages.map(\.id))

        _ = Store.shared.save(notificationsFromMessages: messages, withSubscription: subscription)
        _ = Store.shared.save(notificationsFromMessages: messages, withSubscription: subscription)

        XCTAssertEqual(
            subscription.lastNotificationId, "dedupe-d2",
            "an all-duplicate poll must still advance the since-cursor to the last message it saw"
        )
    }

    // MARK: A deleted notification must leave the published list at once — swipe-delete crash (ntfy #1058)
    //
    // `NotificationListView:183` renders `ForEach(notificationsModel.notifications, id: \.self)` and each
    // `NotificationRowView` binds its row to `@ObservedObject var notification: Notification`. Swiping a row
    // calls `Store.delete(notification:)`, which deletes AND saves inside `context.performAndWait`, so the
    // managed object is invalid the moment that call returns. But `NotificationsObservable`
    // republished through `DispatchQueue.main.async`, so for one full runloop turn `notifications` still
    // held the dead object while Core Data's save had already told SwiftUI that the row's `@ObservedObject`
    // changed. The row body is then re-evaluated against an object whose row is gone — `shortDateTime()`,
    // `priority`, `formatTitle()` and `renderedMessageAttributedString()` all fault — and the process dies
    // with no alert, which is exactly how ntfy #1058 puts it: "App simply disappears with no error message".
    //
    // This also explains the two qualifiers in that report. It needs MORE THAN ONE message because a
    // surviving sibling row is what keeps the list rendering through the deletion, and "clear all" is safe
    // because `delete(allNotificationsFor:)` removes every row at once, leaving no row pointed at a dead
    // object. The fix therefore belongs in the observable, not in the view: the published array must never
    // outlive the rows it points at.
    //
    // The first two tests fail BEHAVIORALLY before the fix (a stale array, not a compile error). The two
    // after them are CONTROLS that pass on BOTH sides and pin the axis — this change is about what the view
    // layer OBSERVES, not about whether the delete persists.

    private func makeNotificationsObservableFixture(
        topic: String,
        ids: [String]
    ) -> (subscription: Subscription, observable: NotificationsObservable, published: [ntfy.Notification]) {
        let subscription = Store.shared.saveSubscription(baseUrl: "https://ntfy.sh", topic: topic)
        deleteAfterTest(subscription)
        deleteNotificationsAfterTest(ids: ids)
        let messages = ids.map { pollMessage($0, topic: topic) }
        _ = Store.shared.save(notificationsFromMessages: messages, withSubscription: subscription)

        let observable = NotificationsObservable(subscriptionID: subscription.objectID)
        return (subscription, observable, observable.notifications)
    }

    func testDeletingOneNotificationRemovesItFromThePublishedListImmediately() {
        // RED before the fix: the async republish leaves the deleted row in the array for a whole runloop
        // turn, and that turn is exactly when SwiftUI re-renders the row bound to the dead object.
        let fixture = makeNotificationsObservableFixture(topic: "swipedelete-immediate",
                                                        ids: ["swipe-a1", "swipe-a2"])
        XCTAssertEqual(fixture.published.count, 2, "premise: the observable starts with both notifications")
        guard let victim = fixture.published.first(where: { $0.id == "swipe-a1" }) else {
            return XCTFail("premise: fixture did not contain swipe-a1")
        }

        Store.shared.delete(notification: victim)

        XCTAssertEqual(
            fixture.observable.notifications.count, 1,
            "a deleted notification must be gone from the published list as soon as delete() returns"
        )
        XCTAssertFalse(
            fixture.observable.notifications.contains { $0.id == "swipe-a1" },
            "the published list must not still contain the deleted notification"
        )
    }

    func testThePublishedListNeverExposesAnInvalidatedNotification() {
        // RED before the fix. This is the assertion that maps straight onto the crash: a managed object
        // whose managedObjectContext is nil has had its row deleted, so reading ANY property of it from a
        // SwiftUI body faults. It must never be reachable from the array the view renders.
        let fixture = makeNotificationsObservableFixture(topic: "swipedelete-invalidated",
                                                        ids: ["swipe-b1", "swipe-b2", "swipe-b3"])
        XCTAssertEqual(fixture.published.count, 3, "premise: the observable starts with all three")
        guard let victim = fixture.published.first(where: { $0.id == "swipe-b2" }) else {
            return XCTFail("premise: fixture did not contain swipe-b2")
        }

        Store.shared.delete(notification: victim)

        XCTAssertNil(
            victim.managedObjectContext,
            "premise: deleting through the store invalidates the managed object right away"
        )
        XCTAssertFalse(
            fixture.observable.notifications.contains { $0.managedObjectContext == nil },
            "the published list must never hand the view layer an invalidated managed object"
        )
    }

    func testDeletingOneNotificationStillLeavesTheOthersStored() {
        // CONTROL: green on BOTH sides. The delete itself was always correct — `Store.delete(notification:)`
        // has run inside `context.performAndWait` since PR #23. This pins that the fix is about what the
        // view layer observes, not about persistence.
        let ids = ["swipe-c1", "swipe-c2"]
        let fixture = makeNotificationsObservableFixture(topic: "swipedelete-persistence", ids: ids)
        guard let victim = fixture.published.first(where: { $0.id == "swipe-c1" }) else {
            return XCTFail("premise: fixture did not contain swipe-c1")
        }

        Store.shared.delete(notification: victim)

        let request = Notification.fetchRequest()
        request.predicate = NSPredicate(format: "id IN %@", ids)
        let remaining = (try? Store.shared.context.fetch(request)) ?? []
        XCTAssertEqual(
            remaining.compactMap(\.id), ["swipe-c2"],
            "the delete must persist: exactly the untouched notification remains in the store"
        )
    }

    func testTheObservablePublishesEveryNotificationForItsSubscription() {
        // CONTROL: green on BOTH sides. `init` -> `performFetch` is untouched by this fix; if this goes red,
        // the change broke the observable's normal population path rather than just its refresh path.
        let fixture = makeNotificationsObservableFixture(topic: "swipedelete-initialfetch",
                                                        ids: ["swipe-d1", "swipe-d2"])
        XCTAssertEqual(
            Set(fixture.observable.notifications.compactMap(\.id)), ["swipe-d1", "swipe-d2"],
            "the observable must publish every stored notification for its subscription"
        )
    }

    // MARK: EmojiManager — every gemoji alias must resolve, not just the first
    //
    // The bundled emojis.json is gemoji, where an emoji may carry several aliases
    // ("+1" and "thumbsup" are both 👍). EmojiManager indexed only aliases.first,
    // so 43 aliases that ntfy's web client accepts silently failed here: the tag
    // resolved to no emoji and then leaked into the row as a literal text tag.

    func testGetEmojiByAliasResolvesFirstAlias() {
        XCTAssertEqual(EmojiManager.shared.getEmojiByAlias(alias: "+1")?.getUnicode(), "👍")
        XCTAssertEqual(EmojiManager.shared.getEmojiByAlias(alias: "hankey")?.getUnicode(), "💩")
    }

    func testGetEmojiByAliasResolvesNonFirstAliases() {
        // Each of these is aliases[1..] of its entry — nil before the fix.
        XCTAssertEqual(EmojiManager.shared.getEmojiByAlias(alias: "thumbsup")?.getUnicode(), "👍")
        XCTAssertEqual(EmojiManager.shared.getEmojiByAlias(alias: "thumbsdown")?.getUnicode(), "👎")
        XCTAssertEqual(EmojiManager.shared.getEmojiByAlias(alias: "poop")?.getUnicode(), "💩")
        XCTAssertEqual(EmojiManager.shared.getEmojiByAlias(alias: "uk")?.getUnicode(), "🇬🇧")
        XCTAssertEqual(EmojiManager.shared.getEmojiByAlias(alias: "telephone")?.getUnicode(), "☎️")
    }

    func testGetEmojiByAliasIsNilForUnknownAndEmpty() {
        XCTAssertNil(EmojiManager.shared.getEmojiByAlias(alias: ""))
        XCTAssertNil(EmojiManager.shared.getEmojiByAlias(alias: "definitely-not-an-emoji-alias"))
    }

    func testEveryAliasInTheDatasetResolvesToItsOwnEmoji() {
        // The contract, dataset-wide: alias -> the emoji that declares it. Indexing every
        // alias is only safe because gemoji has no alias claimed by two entries; this pins
        // both halves (full coverage AND no entry shadowing another).
        let url = Bundle.main.url(forResource: "emojis", withExtension: "json")
        XCTAssertNotNil(url, "emojis.json must be bundled into the test host")
        let entries = try! JSONDecoder().decode([Emoji].self, from: Data(contentsOf: url!))
        XCTAssertGreaterThan(entries.count, 1800, "sanity: the gemoji dataset should be fully loaded")

        var aliasCount = 0
        for entry in entries {
            for alias in entry.aliases {
                aliasCount += 1
                XCTAssertEqual(EmojiManager.shared.getEmojiByAlias(alias: alias)?.getUnicode(),
                               entry.getUnicode(),
                               "alias '\(alias)' must resolve to \(entry.getUnicode())")
            }
        }
        // 1855 aliases across 1812 entries — the 43-alias gap is the bug this pins.
        XCTAssertGreaterThan(aliasCount, entries.count,
                             "sanity: the dataset must contain multi-alias entries for this to be meaningful")
    }

    // MARK: tag parsing over the real dataset — the user-visible half of the alias bug

    func testParseEmojiTagsResolvesNonFirstAlias() {
        XCTAssertEqual(parseEmojiTags("thumbsup"), ["👍"])
        XCTAssertEqual(parseEmojiTags("+1,thumbsdown"), ["👍", "👎"])
    }

    func testParseNonEmojiTagsDoesNotLeakKnownAliasAsLiteralTag() {
        // The symptom users see: an unresolved alias falls through to the literal tag list,
        // so the row renders "thumbsup" as text instead of 👍.
        XCTAssertEqual(parseNonEmojiTags("thumbsup"), [])
        XCTAssertEqual(parseNonEmojiTags("thumbsup,backup"), ["backup"])
    }
}
