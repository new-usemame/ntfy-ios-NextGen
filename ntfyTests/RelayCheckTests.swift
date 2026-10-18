import XCTest
import CryptoKit
@testable import ntfy

final class RelayCheckTests: XCTestCase {
    private var reads: [URLRequest] = []
    private var replies: [(Int, String, [String: String])] = []
    private var pending: [() -> Void] = []
    private var delays: [TimeInterval] = []
    private var publishes = 0
    private let stamp: Int64 = 1792330000123

    private func json(_ stamp: Int64? = nil) -> String {
        "{\"relayed\":\(stamp == nil ? "false" : "true"),\"relayed_at\":\(stamp.map(String.init) ?? "null"),\"window_seconds\":120}"
    }
    private func make(supported: Bool = true) -> RelayCheck {
        RelayCheck(discover: { $0(supported) }, read: { request, completion in
            self.reads.append(request)
            let reply = self.replies.removeFirst()
            completion(Data(reply.1.utf8), HTTPURLResponse(url: request.url!, statusCode: reply.0,
                httpVersion: "HTTP/1.1", headerFields: reply.2), nil)
        }, schedule: { delay, action in self.delays.append(delay); self.pending.append(action) },
        now: { Date(timeIntervalSince1970: 1792331000) })
    }
    private func drain() {
        let tick = expectation(description: "main queue callbacks")
        DispatchQueue.main.async { tick.fulfill() }
        wait(for: [tick], timeout: 2)
    }
    private func prepare(_ check: RelayCheck) {
        check.prepare(baseUrl: "https://private.example/ntfy", topic: "topic")
        drain()
    }
    private func approve(_ check: RelayCheck, error: String? = nil) {
        check.approve { done in self.publishes += 1; done(error) }
        drain()
    }
    private func advance() { pending.removeFirst()(); drain() }

    func testDiscoveryDoesNotSendTestWithoutConsent() {
        let check = make(); prepare(check)
        XCTAssertEqual(check.state, .consent)
        XCTAssertTrue(reads.isEmpty); XCTAssertEqual(publishes, 0)
    }
    func testUnsupportedDoesNotPublishOrReadAndGivesManualGuidance() {
        let check = make(supported: false); prepare(check); approve(check)
        XCTAssertEqual(check.state, .unsupported)
        XCTAssertTrue(reads.isEmpty); XCTAssertEqual(publishes, 0)
        XCTAssertTrue(check.state.message!.contains("upstream-base-url"))
    }
    func testPlainHTTPRejectedBeforeDiscovery() {
        var discovered = false
        let check = RelayCheck(discover: { _ in discovered = true })
        check.prepare(baseUrl: "http://private.example", topic: "topic")
        XCTAssertFalse(discovered)
        XCTAssertTrue(check.state.message!.contains("requires HTTPS"))
    }
    func testInsecureRelayAndEmbeddedCredentialsAreRejected() {
        XCTAssertFalse(RelayCheck.isSecureBase("https://user:pass@example.com"))
        XCTAssertFalse(RelayCheck.isSecureBase("https://example.com?secret=yes"))
        XCTAssertFalse(RelayCheck.isSecureBase("http://example.com"))
        XCTAssertTrue(RelayCheck.isSecureBase("https://Example.com:8443/path/"))
    }
    func testHashPreservesExactConfiguredSpelling() {
        let base = "https://EXAMPLE.com:8443/ntfy/"
        let expected = SHA256.hash(data: Data((base + "/topic").utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(RelayCheck.topicHash(baseUrl: base, topic: "topic"), expected)
        XCTAssertNotEqual(expected, RelayCheck.topicHash(baseUrl: "https://example.com:8443/ntfy", topic: "topic"))
    }
    func testNewerTimestampStopsAfterFirstPostPublishRead() {
        replies = [(200,json(stamp),[:]), (200,json(stamp + 1),[:])]
        let check = make(); prepare(check); approve(check); advance()
        XCTAssertEqual(check.state, .received(stamp + 1))
        XCTAssertEqual(reads.count, 2); XCTAssertEqual(publishes, 1); XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(delays, [1])
    }
    func testUnchangedBaselineDoesNotProveTestWasForwarded() {
        replies = Array(repeating: (200,json(stamp),[:]), count: 5)
        let check = make(); prepare(check); approve(check)
        for _ in 0..<4 { advance() }
        XCTAssertEqual(check.state, .notObserved)
        XCTAssertEqual(reads.count, 5); XCTAssertEqual(publishes, 1)
        XCTAssertEqual(delays, [1, 2, 3, 4])
    }
    func testOlderTimestampAfterRestartDoesNotCountAsNewWake() {
        replies = [(200,json(stamp),[:])] + Array(repeating: (200,json(stamp - 1),[:]), count: 4)
        let check = make(); prepare(check); approve(check)
        for _ in 0..<4 { advance() }
        XCTAssertEqual(check.state, .notObserved)
    }
    func testNoBaselineThenRecentWakeIsObserved() {
        replies = [(200,json(),[:]), (200,json(stamp),[:])]
        let check = make(); prepare(check); approve(check); advance()
        XCTAssertEqual(check.state, .received(stamp))
    }
    func testDiagnosticBodyContainsOnlyHashAndNoCredentialsOrTopicURL() throws {
        replies = [(200,json(),[:])]
        let check = make(); prepare(check); approve(check)
        let request = try XCTUnwrap(reads.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://ntfy-me.com/v1/ntfyme/relay-check")
        XCTAssertNil(request.url?.query)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(Array(json.keys), ["hash"])
        XCTAssertEqual(json["hash"]?.count, 64)
        XCTAssertLessThanOrEqual(body.count, 128)
    }
    func testBaselineFailureDoesNotSendVisibleMessage() {
        replies = [(503,"",[:])]
        let check = make(); prepare(check); approve(check)
        XCTAssertEqual(publishes, 0); XCTAssertTrue(pending.isEmpty)
        XCTAssertTrue(check.state.message!.contains("HTTP 503"))
    }
    func testRateLimitStateChangeStopsWithoutRetry() {
        replies = [(429,"",["Retry-After-Condition":"state-change"])]
        let check = make(); prepare(check); approve(check)
        XCTAssertTrue(check.state.message!.contains("state to change"))
        XCTAssertEqual(reads.count, 1); XCTAssertTrue(pending.isEmpty); XCTAssertEqual(publishes, 0)
    }
    func testRateLimitRequestChangeStopsWithoutRetry() {
        replies = [(429,"",["Retry-After-Condition":"request-change"])]
        let check = make(); prepare(check); approve(check)
        XCTAssertTrue(check.state.message!.contains("different request")); XCTAssertTrue(pending.isEmpty)
    }
    func testTimedRateLimitRetainsDailyDelayInsteadOf3600Cap() {
        replies = [(429,"",["Retry-After-Condition":"time","Retry-After":"86400"])]
        let check = make(); prepare(check); approve(check)
        XCTAssertTrue(check.state.message!.contains("86400 seconds")); XCTAssertTrue(pending.isEmpty)
        prepare(check)
        XCTAssertTrue(check.state.message!.contains("86400 seconds"))
        XCTAssertEqual(reads.count, 1)
    }
    func testUnsupportedEndpointStopsReads() {
        replies = [(404,"",[:])]
        let check = make(); prepare(check); approve(check)
        XCTAssertEqual(check.state, .unsupported); XCTAssertEqual(publishes, 0)
    }
    func testMalformedSnapshotDoesNotPublish() {
        replies = [(200,"{\"relayed\":false,\"relayed_at\":123,\"window_seconds\":120}",[:])]
        let check = make(); prepare(check); approve(check)
        XCTAssertEqual(publishes, 0); XCTAssertTrue(check.state.message!.contains("valid check result"))
    }
    func testPublishFailureStopsReads() {
        replies = [(200,json(),[:])]
        let check = make(); prepare(check); approve(check, error: "HTTP 403")
        XCTAssertEqual(reads.count, 1); XCTAssertTrue(pending.isEmpty)
        XCTAssertTrue(check.state.message!.contains("could not be confirmed"))
    }
    func testCancellationPreventsScheduledRead() {
        replies = [(200,json(),[:])]
        let check = make(); prepare(check); approve(check); check.cancel(); advance()
        XCTAssertEqual(check.state, .cancelled); XCTAssertEqual(reads.count, 1)
    }
    func testCancellationIgnoresLateDiscovery() {
        var callback: ((Bool) -> Void)?
        let check = RelayCheck(discover: { callback = $0 })
        check.prepare(baseUrl: "https://private.example", topic: "topic")
        check.cancel(); callback?(true); drain()
        XCTAssertEqual(check.state, .cancelled)
    }
    func testReceivedCopyDoesNotClaimPhoneDelivery() {
        let message = RelayCheck.State.received(stamp).message!
        XCTAssertTrue(message.contains("FCM accepted"))
        XCTAssertTrue(message.contains("does not prove your phone received"))
        XCTAssertTrue(message.contains("this test caused"))
    }
    func testNoObservationCopyDoesNotAssertWrongConfigurationOrTwoMinuteTest() {
        let message = RelayCheck.State.notObserved.message!
        XCTAssertTrue(message.contains("about 10 seconds"))
        XCTAssertTrue(message.contains("Network or FCM trouble"))
        XCTAssertFalse(message.contains("in 2 minutes"))
    }
}
