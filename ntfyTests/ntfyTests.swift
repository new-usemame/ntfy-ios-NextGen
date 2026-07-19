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
