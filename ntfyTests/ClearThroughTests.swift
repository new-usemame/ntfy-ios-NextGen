import XCTest
import CoreData
@testable import ntfy

final class ClearThroughTests: XCTestCase {
    private let base = "https://bulk.example"
    private var coordinator: ClearThroughCoordinator!

    private func clear(_ id: String = "AbCdEf123456", sequence: String = "opaque-sequence") -> ClearRequest {
        ClearRequest(baseUrl: base, topic: "test-topic", sequence: sequence,
                     user: BasicUser(username: "reader", password: "topic-only"), messageId: id)
    }
    private func intent(_ boundary: ClearRequest? = nil, candidates: [ClearRequest]? = nil) -> ClearThroughIntent {
        let boundary = boundary ?? clear()
        return ClearThroughIntent(boundary: boundary, candidates: candidates ?? [boundary], known: [boundary])
    }
    private func response(_ request: URLRequest, status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
    }
    private func make(supported: Bool = true, invalidate: @escaping (String) -> Void = { _ in },
                      cooldown: ServerCooldown = ServerCooldown(defaults: nil),
                      transport: @escaping ClearThroughCoordinator.Transport) -> ClearThroughCoordinator {
        ClearThroughCoordinator(cooldown: cooldown, discover: { _, _, done in done(ServerCapabilities(clearThrough: supported)) },
                                invalidate: invalidate, transport: transport, schedule: { _, work in work() })
    }
    private func receipt(_ id: String = "AbCdEf123456") -> Data { Data("{\"cleared\":1,\"through_id\":\"\(id)\"}".utf8) }
    private func event(_ event: String = "message", id: String = "AbCdEf123456", sequence: String = "opaque-sequence") -> Data {
        Data("{\"id\":\"\(id)\",\"time\":100,\"event\":\"\(event)\",\"topic\":\"test-topic\",\"sequence_id\":\"\(sequence)\"}\n".utf8)
    }

    func testOneRequestUsesBoundaryMessageIDAndOnlyTopicCredentials() throws {
        let finished = expectation(description: "bulk sent")
        coordinator = make { request, done in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.absoluteString, "https://bulk.example/test-topic/opaque-sequence/clear-through")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-NtfyMe-Through-ID"), "AbCdEf123456")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), self.clear().user?.toHeader())
            XCTAssertEqual(request.httpBody?.count, 0)
            done(self.receipt(), self.response(request, status: 200), nil)
        }
        coordinator.send(intent()) { result in
            guard case .sent = result else { return XCTFail("bulk should succeed") }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 2)
    }

    func testUnsupportedDiscoveryRetainsLegacyFallbackWithoutBulkRequest() {
        let finished = expectation(description: "stock fallback")
        coordinator = make(supported: false) { _, _ in XCTFail("stock does not receive extension requests") }
        coordinator.send(intent()) { result in
            guard case .fallback = result else { return XCTFail("stock should use individual clears") }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 2)
    }

    func test404405InvalidateAnd413FallbackWithoutRetry() {
        for status in [404, 405, 413] {
            let finished = expectation(description: "fallback \(status)")
            var sends = 0; var invalidated = 0
            coordinator = make(invalidate: { server in XCTAssertEqual(server, self.base); invalidated += 1 }) { request, done in
                sends += 1; done(Data(), self.response(request, status: status), nil)
            }
            coordinator.send(intent()) { result in
                guard case .fallback = result else { return XCTFail("expected safe fallback") }
                XCTAssertEqual(sends, 1); XCTAssertEqual(invalidated, status == 413 ? 0 : 1)
                finished.fulfill()
            }
            wait(for: [finished], timeout: 2)
        }
    }

    func test400AuthAnd429NeverFanOutToIndividualClears() {
        for status in [400, 401, 403, 429] {
            let finished = expectation(description: "deferred \(status)")
            let cooldown = ServerCooldown(defaults: nil)
            var sends = 0
            coordinator = make(cooldown: cooldown) { request, done in
                sends += 1
                done(Data(), self.response(request, status: status, headers: ["Retry-After-Condition": "request-change"]), nil)
            }
            coordinator.send(intent()) { result in
                guard case .deferred = result else { return XCTFail("failure must not fan out") }
                XCTAssertEqual(sends, 1)
                if status == 429 { XCTAssertFalse(cooldown.claim(server: self.base, manual: false)) }
                finished.fulfill()
            }
            wait(for: [finished], timeout: 2)
        }
    }

    func test409PollsThenRetriesOnlyTwiceBeforePacedFallback() {
        let finished = expectation(description: "bounded boundary retry")
        var methods: [String] = []
        coordinator = make { request, done in
            methods.append(request.httpMethod ?? "GET")
            done(request.httpMethod == "PUT" ? Data() : self.event(),
                 self.response(request, status: request.httpMethod == "PUT" ? 409 : 200), nil)
        }
        coordinator.send(intent()) { result in
            guard case .fallback = result else { return XCTFail("unavailable boundary should fall back") }
            XCTAssertEqual(methods, ["PUT", "GET", "PUT", "GET", "PUT", "GET"])
            finished.fulfill()
        }
        wait(for: [finished], timeout: 2)
    }

    func testLostResponsePollSeesCommittedControlAndDoesNotPublishAgain() {
        for status in [0, 500, 503] {
            let finished = expectation(description: "reconcile lost response \(status)")
            var methods: [String] = []
            coordinator = make { request, done in
                methods.append(request.httpMethod ?? "GET")
                if request.httpMethod == "PUT" {
                    done(nil, status == 0 ? nil : self.response(request, status: status), status == 0 ? URLError(.timedOut) : nil)
                } else { done(self.event("message_clear", id: "ClrAbC123456"), self.response(request, status: 200), nil) }
            }
            coordinator.send(intent()) { result in
                guard case .sent = result else { return XCTFail("poll proved clear committed") }
                XCTAssertEqual(methods, ["PUT", "GET"])
                finished.fulfill()
            }
            wait(for: [finished], timeout: 2)
        }
    }

    func testLostResponseWithNoControlsPollsBeforeEachBoundedRetryAndNeverFallbacks() {
        let finished = expectation(description: "bounded uncertain transaction")
        var methods: [String] = []
        coordinator = make { request, done in
            methods.append(request.httpMethod ?? "GET")
            done(request.httpMethod == "PUT" ? Data() : self.event(),
                 self.response(request, status: request.httpMethod == "PUT" ? 500 : 200), nil)
        }
        coordinator.send(intent()) { result in
            guard case .deferred = result else { return XCTFail("uncertain transaction cannot fan out") }
            XCTAssertEqual(methods, ["PUT", "GET", "PUT", "GET", "PUT", "GET"])
            finished.fulfill()
        }
        wait(for: [finished], timeout: 2)
    }

    func testReconciliationPoll429StopsWithoutResending() {
        let finished = expectation(description: "poll honors quota")
        var sends = 0
        coordinator = make { request, done in
            sends += 1
            done(nil, self.response(request, status: sends == 1 ? 500 : 429,
                                   headers: ["Retry-After-Condition": "state-change"]), nil)
        }
        coordinator.send(intent()) { result in
            guard case .deferred = result else { return XCTFail("poll quota cannot cause fallback") }
            XCTAssertEqual(sends, 2); finished.fulfill()
        }
        wait(for: [finished], timeout: 2)
    }

    func testEqualSecondBoundaryUsesLastKnownMessageInServerOrder() {
        let first = clear("ZzzzzZ123456", sequence: "larger-lexical-id")
        let last = clear("AaaaaA123456", sequence: "smaller-lexical-id")
        let finished = expectation(description: "server order boundary")
        var methods: [String] = []
        coordinator = make { request, done in
            methods.append(request.httpMethod ?? "GET")
            if request.httpMethod == "PUT" {
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-NtfyMe-Through-ID"), last.messageId)
                XCTAssertTrue(request.url!.path.contains(last.sequence))
                done(self.receipt(last.messageId!), self.response(request, status: 200), nil)
            } else {
                done(self.event(id: first.messageId!, sequence: first.sequence) + self.event(id: last.messageId!, sequence: last.sequence),
                     self.response(request, status: 200), nil)
            }
        }
        coordinator.send(intent(first, candidates: [first, last])) { result in
            guard case .sent = result else { return XCTFail("tie should resolve") }
            XCTAssertEqual(methods, ["GET", "PUT"]); finished.fulfill()
        }
        wait(for: [finished], timeout: 2)
    }

    func testAbsentTieCandidatesFallbackInsteadOfGuessing() {
        let finished = expectation(description: "missing boundary")
        coordinator = make { request, done in
            XCTAssertNotEqual(request.httpMethod, "PUT")
            done(Data(), self.response(request, status: 200), nil)
        }
        coordinator.send(intent(candidates: [clear(), clear("OtherA123456", sequence: "other")])) { result in
            guard case .fallback = result else { return XCTFail("missing candidates are not ordered") }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 2)
    }

    func testTopicReadCommitsLocallyWhileDiscoveryWaitsAndUsesOneBulkRequest() throws {
        let store = Store.shared
        let sub = store.saveSubscription(baseUrl: base, topic: "test-topic")
        defer { store.delete(subscription: sub); store.clearThrough = nil }
        store.credentialStore = InMemoryCredentialStore()
        store.clearPublisher = { _, _ in XCTFail("advertised support uses one bulk request") }
        store.topicNotificationRemover = { _, _, _, _ in }
        store.wakePublisher = { _, done in done() }
        store.save(notificationsFromMessages: [Message(id: "OldMsg123456", time: 90, event: "message", topic: "test-topic"),
            Message(id: "AbCdEf123456", time: 100, event: "message", topic: "test-topic")], withSubscription: sub)
        let discovering = expectation(description: "discover started")
        let finished = expectation(description: "one bulk completed")
        var discovery: ((ServerCapabilities) -> Void)?
        var sends = 0
        coordinator = ClearThroughCoordinator(cooldown: ServerCooldown(defaults: nil), discover: { _, _, done in
            discovery = done; discovering.fulfill()
        }, transport: { request, done in
            sends += 1
            XCTAssertTrue(request.url!.path.hasSuffix("/AbCdEf123456/clear-through"))
            done(self.receipt(), self.response(request, status: 200), nil)
            finished.fulfill()
        })
        store.clearThrough = coordinator
        store.setRead(true, forSubscription: sub)
        XCTAssertEqual(store.unreadCount(baseUrl: base, topic: "test-topic"), 0)
        wait(for: [discovering], timeout: 2)
        XCTAssertEqual(sends, 0)
        discovery?(ServerCapabilities(clearThrough: true))
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(sends, 1)
    }
}
