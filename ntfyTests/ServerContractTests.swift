import XCTest
@testable import ntfy

final class ServerContractTests: XCTestCase {
    private func response(_ headers: [String: String], status: Int = 429) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://server.invalid/t")!, statusCode: status, httpVersion: nil, headerFields: headers)!
    }

    func testActionWaitsFullDailyResetOnlyWithTimeCondition() {
        let headers = ["Retry-After": "72000", "Retry-After-Condition": "time"]
        XCTAssertEqual(ActionExecutor.retryDelay(response: response(headers), error: nil, attempt: 1), 72000)
        XCTAssertEqual(ActionExecutor.retryDelay(response: response(["Retry-After": "72000"]), error: nil, attempt: 1), 10)
    }

    func testActionDoesNotTimerRetryStateOrRequestChanges() {
        for condition in ["state-change", "request-change"] {
            XCTAssertNil(ActionExecutor.retryDelay(response: response(["Retry-After-Condition": condition]), error: nil, attempt: 1))
        }
        XCTAssertEqual(ActionExecutor.retryDelay(response: response([:]), error: nil, attempt: 1), 1)
        XCTAssertEqual(ActionExecutor.retryDelay(response: response([:]), error: nil, attempt: 2), 2)
        XCTAssertNil(ActionExecutor.retryDelay(response: response([:]), error: nil, attempt: 3))
    }

    func testUnknownConditionsAnd503KeepStockActionBehavior() {
        XCTAssertEqual(ActionExecutor.retryDelay(response: response(["Retry-After-Condition": "future"]), error: nil, attempt: 1), 1)
        XCTAssertEqual(ActionExecutor.retryDelay(response: response(["Retry-After-Condition": "state-change"], status: 503), error: nil, attempt: 1), 1)
        XCTAssertNil(RetryDirective.parse(condition: "time", retryAfter: "nan"))
        XCTAssertEqual(RetryDirective.parse(condition: "time", retryAfter: "9999999999999999999"), .requestChange)
    }

    func testExtendedCooldownUsesMonotonicClockAndPersistsDailyReset() {
        var wall = Date(timeIntervalSince1970: 1_700_000_000)
        var uptime: TimeInterval = 100
        let suite = "ServerContractTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let cooldown = ServerCooldown(defaults: defaults, now: { wall }, uptime: { uptime })
        cooldown.limit(server: "https://s.invalid", retryAfter: "72000", condition: "time")
        XCTAssertFalse(cooldown.claim(server: "https://s.invalid", manual: true))
        wall = wall.addingTimeInterval(80000) // Clock change must not shorten a live deadline.
        XCTAssertFalse(cooldown.claim(server: "https://s.invalid", manual: false))
        uptime += 72000
        XCTAssertTrue(cooldown.claim(server: "https://s.invalid", manual: false))
        wall = Date(timeIntervalSince1970: 1_700_000_010)
        let relaunched = ServerCooldown(defaults: defaults, now: { wall }, uptime: { 200 })
        XCTAssertGreaterThan(relaunched.deadline(for: "https://s.invalid").timeIntervalSince(wall), 71000)
    }

    func testNonTimeCooldownNeverAutomaticallyRestartsAndExplicitProbeIsPaced() {
        var date = Date(timeIntervalSince1970: 1_700_000_000)
        let cooldown = ServerCooldown(defaults: nil, now: { date })
        for condition in ["state-change", "request-change"] {
            cooldown.limit(server: condition, retryAfter: nil, condition: condition)
            date += 86400
            XCTAssertFalse(cooldown.claim(server: condition, manual: false))
            let attempt = cooldown.claimAttempt(server: condition, manual: true)
            XCTAssertNotNil(attempt)
            XCTAssertFalse(cooldown.claim(server: condition, manual: true))
            cooldown.succeeded(server: condition, attempt: attempt!)
            XCTAssertTrue(cooldown.claim(server: condition, manual: false))
        }
    }

    func testSubscriptionManagerCarriesConditionIntoSharedPollBrake() {
        let store = Store(inMemory: true)
        let subscription = store.saveSubscription(baseUrl: "https://condition.invalid", topic: "topic")
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        let polling = PollCoordinator(defaults: nil, now: { clock })
        var manager = SubscriptionManager(store: store, polling: polling)
        var fetches = 0
        manager.fetch = { _, done in
            fetches += 1
            done(nil, PollHTTPError(status: 429, retryAfter: nil, retryCondition: "state-change"))
        }
        manager.pollWithOutcome(subscription) { XCTAssertTrue($0.attempted) }
        clock += 7200
        manager.pollWithOutcome(subscription) { XCTAssertFalse($0.attempted) }
        XCTAssertEqual(fetches, 1)
    }

    func testNewTimeConditionAfterExplicitStateProbeCanRecover() {
        var clock: TimeInterval = 0
        let cooldown = ServerCooldown(defaults: nil, uptime: { clock })
        cooldown.limit(server: "https://s.invalid", retryAfter: nil, condition: "state-change")
        cooldown.limit(server: "https://s.invalid", retryAfter: "10", condition: "time")
        clock = 10
        XCTAssertTrue(cooldown.claim(server: "https://s.invalid", manual: false))
    }

    func testConditionClearStopsQueuedRequestsOnThatServer() {
        let cooldown = ServerCooldown(defaults: nil)
        let pacer = ClearPacer(cooldown: cooldown)
        var complete: ((ClearOutcome) -> Void)?
        var sent = 0
        var finished = 0
        let requests = (0..<3).map { ClearRequest(baseUrl: "https://s.invalid", topic: "t", sequence: "id\($0)", user: nil) }
        pacer.send(requests, via: { _, done in sent += 1; complete = done }) { _, _ in finished += 1 }
        complete?(.conditionLimited(.stateChange))
        XCTAssertEqual(sent, 1)
        XCTAssertEqual(finished, 3)
        XCTAssertFalse(cooldown.claim(server: "https://s.invalid", manual: false, kind: .clear))
        XCTAssertTrue(cooldown.claim(server: "https://s.invalid", manual: false), "a refused clear must not starve admissible GET polls")
    }

    func testBulkAuthFailureAppearsInTopicHealth() {
        let store = Store(inMemory: true)
        let subscription = store.saveSubscription(baseUrl: "https://auth-health.invalid", topic: "topic")
        let request = store.pollRequest(for: subscription)!
        let monitor = DeliveryHealthMonitor()
        monitor.register(request)
        NotificationCenter.default.post(name: ClearThroughCoordinator.didFail, object: nil,
            userInfo: ["baseUrl": request.baseUrl, "topic": "topic", "failure": PollFailure.unauthorized])
        XCTAssertEqual(monitor.topics[subscription.objectID.uriRepresentation().absoluteString]?.failure, .unauthorized)
    }

    func testDiscoveryRequiresHTTPSAndKeepsTimedGateAcrossCacheInstances() {
        let cooldown = ServerCooldown(defaults: nil)
        var sends = 0
        func cache() -> ServerCapabilitiesCache {
            ServerCapabilitiesCache(cooldown: cooldown, transport: { request, done in
                sends += 1
                done(nil, HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil,
                    headerFields: ["Retry-After-Condition": "time", "Retry-After": "72000"]), nil)
            })
        }
        cache().discover(baseUrl: "http://self-host.invalid") { XCTAssertEqual($0, .unsupported) }
        XCTAssertEqual(sends, 0)
        cache().discover(baseUrl: "https://rate-discovery.invalid") { XCTAssertEqual($0, .unsupported) }
        XCTAssertEqual(sends, 1)
        cache().discover(baseUrl: "https://rate-discovery.invalid") { XCTAssertEqual($0, .unsupported) }
        XCTAssertEqual(sends, 1)
    }

    func testNonTimeBrakeScopesRequestChangesWhileTimedBrakeIsShared() {
        let cooldown = ServerCooldown(defaults: nil)
        cooldown.limit(server: "https://s.invalid", retryAfter: nil, condition: "request-change", kind: .clearThrough)
        XCTAssertFalse(cooldown.claim(server: "https://s.invalid", manual: false, kind: .clearThrough))
        XCTAssertTrue(cooldown.claim(server: "https://s.invalid", manual: false, kind: .poll))
        cooldown.requestChanged(server: "https://s.invalid", kind: .clearThrough)
        XCTAssertTrue(cooldown.claim(server: "https://s.invalid", manual: false, kind: .clearThrough))
        cooldown.limit(server: "https://s.invalid", retryAfter: "72000", condition: "time", kind: .clearThrough)
        XCTAssertFalse(cooldown.claim(server: "https://s.invalid", manual: true, kind: .poll))
    }

    func testCapabilitiesExplicitVersionsAndLimits() {
        func decode(_ value: String) -> ServerCapabilities { ServerCapabilities.decode(Data(value.utf8)) }
        XCTAssertTrue(decode(Self.document).clearThrough)
        XCTAssertTrue(decode(Self.document).relayCheck)
        XCTAssertEqual(decode(Self.document.replacingOccurrences(of: "\"version\":1", with: "\"version\":2")), .unsupported)
        XCTAssertFalse(decode(Self.document.replacingOccurrences(of: "\"relay_check\":1", with: "\"relay_check\":2")).relayCheck)
        XCTAssertFalse(decode(Self.document.replacingOccurrences(of: "\"clear_max_rows\":1000", with: "\"clear_max_rows\":2000")).clearThrough)
        XCTAssertEqual(decode("{\"version\":true,\"clear_through\":true}"), .unsupported)
        XCTAssertEqual(decode("<html>login</html>"), .unsupported)
    }

    static let document = "{\"version\":1,\"retry_after\":1,\"relay_check\":1,\"relay_window_seconds\":120,\"clear_through\":true,\"clear_max_sequences\":100,\"clear_max_rows\":1000}"

    func testDiscoverySingleFlightCachesUnsupportedAndExpiresPerServer() {
        var clock: TimeInterval = 10
        var count = 0
        var reply: ((Data?, URLResponse?, Error?) -> Void)?
        let cache = ServerCapabilitiesCache(now: { clock }, transport: { _, completion in count += 1; reply = completion })
        var results = 0
        cache.discover(baseUrl: "https://stock.invalid") { XCTAssertEqual($0, .unsupported); results += 1 }
        cache.discover(baseUrl: "https://stock.invalid") { XCTAssertEqual($0, .unsupported); results += 1 }
        XCTAssertEqual(count, 1)
        reply?(nil, HTTPURLResponse(url: URL(string: "https://stock.invalid/v1/ntfyme/capabilities")!, statusCode: 404, httpVersion: nil, headerFields: nil), nil)
        XCTAssertEqual(results, 2)
        cache.discover(baseUrl: "https://stock.invalid") { _ in results += 1 }
        XCTAssertEqual(count, 1)
        clock += 300
        cache.discover(baseUrl: "https://stock.invalid") { _ in }
        XCTAssertEqual(count, 2)
        cache.discover(baseUrl: "https://other.invalid") { _ in }
        XCTAssertEqual(count, 3)
    }

    func testDiscoveryAcceptsJSONOnlyAndInvalidationRejectsInFlightSupport() {
        var reply: ((Data?, URLResponse?, Error?) -> Void)?
        var requested: URLRequest?
        let cache = ServerCapabilitiesCache(transport: { request, completion in requested = request; reply = completion })
        var value: ServerCapabilities?
        cache.discover(baseUrl: "https://s.invalid") { value = $0 }
        cache.invalidate(baseUrl: "https://s.invalid")
        reply?(Data(Self.document.utf8), HTTPURLResponse(url: requested!.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]), nil)
        XCTAssertEqual(value, .unsupported)
        cache.discover(baseUrl: "https://s.invalid") { value = $0 }
        reply?(Data(Self.document.utf8), HTTPURLResponse(url: requested!.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html"]), nil)
        XCTAssertEqual(value, .unsupported)
    }

    func testClearReadsConditionFromHTTPResponse() {
        ContractURLProtocol.headers = ["Retry-After-Condition": "time", "Retry-After": "72000"]
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ContractURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let done = expectation(description: "condition propagated")
        ApiService().action(ClearRequest(baseUrl: "https://s.invalid", topic: "t", sequence: "id", user: nil), session: session) {
            XCTAssertEqual($0, .conditionLimited(.time(72000)))
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
    }
}

private final class ContractURLProtocol: URLProtocol {
    static var headers: [String: String] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: Self.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Opt-in integration gate. The private loopback harness supplies ephemeral server URLs through
/// the xctestrun environment; ordinary CI skips this test rather than relying on a public service.
final class NativeServerContractTests: XCTestCase {
    func testNativeRateResponsesDriveAppPolicies() throws {
        guard let encoded = ProcessInfo.processInfo.environment["NTFY_CONTRACT_NATIVE"],
              let data = encoded.data(using: .utf8),
              let cases = try? JSONDecoder().decode([NativeCase].self, from: data) else {
            throw XCTSkip("Run the native loopback contract harness to provide server cases")
        }
        for item in cases {
            let done = expectation(description: "native \(item.condition)")
            let store = Store(inMemory: true)
            let subscription = store.saveSubscription(baseUrl: item.url, topic: "audit-contract")
            let request = try XCTUnwrap(store.pollRequest(for: subscription))
            ApiService().poll(request) { _, error in
                let error = error as? PollHTTPError
                XCTAssertEqual(error?.status, 429)
                XCTAssertEqual(error?.retryCondition, item.condition.isEmpty ? nil : item.condition)
                let http = HTTPURLResponse(url: URL(string: item.url)!, statusCode: 429, httpVersion: nil,
                    headerFields: ["Retry-After-Condition": item.condition, "Retry-After": error?.retryAfter ?? ""])!
                let delay = ActionExecutor.retryDelay(response: http, error: nil, attempt: 1)
                let cooldown = ServerCooldown(defaults: nil)
                cooldown.limit(server: item.url, retryAfter: error?.retryAfter, condition: error?.retryCondition)
                switch item.condition {
                case "time":
                    let seconds = Double(error?.retryAfter ?? "") ?? -1
                    XCTAssertGreaterThan(seconds, 3600, "native daily reset must exercise beyond the former cap")
                    XCTAssertEqual(delay, seconds)
                    XCTAssertGreaterThan(cooldown.deadline(for: item.url).timeIntervalSinceNow, seconds - 2)
                case "state-change", "request-change":
                    XCTAssertNil(error?.retryAfter)
                    XCTAssertNil(delay)
                    XCTAssertFalse(cooldown.claim(server: item.url, manual: false))
                default:
                    XCTAssertEqual(delay, 1)
                    XCTAssertGreaterThan(cooldown.deadline(for: item.url).timeIntervalSinceNow, 58)
                }
                done.fulfill()
            }
            wait(for: [done], timeout: 15)
        }
    }
    private struct NativeCase: Decodable { let url: String; let condition: String }
}
