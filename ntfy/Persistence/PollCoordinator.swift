import Foundation
import Combine

final class DeliveryHealthMonitor: ObservableObject {
    static let shared = DeliveryHealthMonitor()
    @Published private(set) var topics: [String: TopicDeliveryHealth] = [:]

    func record(key: String, failure: PollFailure?) {
        let update = {
            if failure == nil {
                if self.topics[key] != nil { self.topics.removeValue(forKey: key) }
            } else {
                var state = self.topics[key] ?? TopicDeliveryHealth()
                state.record(failure)
                self.topics[key] = state
            }
        }
        if Thread.isMainThread { update() } else { DispatchQueue.main.async(execute: update) }
    }
}

/// One process-wide gate for automatic polls. Manual refresh joins an in-flight request instead
/// of racing it, and bypasses ordinary cooldowns, but never a server's rate limit.
/// Only server cooldown deadlines persist; no Core Data schema or message state is involved.
final class PollCoordinator {
    static let shared = PollCoordinator(defaults: UserDefaults(suiteName: Store.appGroup) ?? .standard)
    private static let cooldownKey = "deliveryHealthServerCooldowns"
    private let lock = NSLock()
    private let defaults: UserDefaults?
    private let now: () -> Date
    private var timing: [String: PollTiming] = [:]
    private var serverTiming: [String: PollTiming] = [:]
    private var serverUntil: [String: Double]
    private struct Waiting {
        let presenting: Bool
        let completion: (PollOutcome) -> Void
    }
    private var callbacks: [String: [Waiting]] = [:]
    private var lastOutcome: [String: PollOutcome] = [:]

    init(defaults: UserDefaults?, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
        self.serverUntil = defaults?.dictionary(forKey: Self.cooldownKey) as? [String: Double] ?? [:]
    }

    /// True means the caller owns the network request. Otherwise the completion is either queued
    /// behind the existing request, or answered with the previous result during a cooldown.
    func begin(_ request: PollRequest, manual: Bool, presenting: Bool = false, completion: @escaping (PollOutcome) -> Void) -> Bool {
        lock.lock()
        let key = request.subscriptionID.uriRepresentation().absoluteString
        if callbacks[key] != nil {
            callbacks[key]?.append(Waiting(presenting: presenting, completion: completion))
            lock.unlock()
            return false
        }
        let server = normalizeBaseUrl(request.baseUrl)
        let date = now()
        let limited = (serverUntil[server] ?? 0) > date.timeIntervalSince1970
        if limited || !(timing[key] ?? PollTiming()).allowsPoll(now: date, manual: manual) {
            let outcome = limited ? PollOutcome(succeeded: false, newMessages: [], failure: .rateLimited)
                : lastOutcome[key] ?? PollOutcome(succeeded: true, newMessages: [])
            lock.unlock()
            if limited { DeliveryHealthMonitor.shared.record(key: key, failure: .rateLimited) }
            completion(outcome)
            return false
        }
        callbacks[key] = [Waiting(presenting: presenting, completion: completion)]
        lock.unlock()
        return true
    }

    func finish(_ request: PollRequest, outcome: PollOutcome, retryAfter: String?) {
        lock.lock()
        let key = request.subscriptionID.uriRepresentation().absoluteString
        let server = normalizeBaseUrl(request.baseUrl)
        let date = now()
        let previousCooldowns = serverUntil
        var topicTiming = timing[key] ?? PollTiming()
        topicTiming.record(failure: outcome.failure, retryAfter: retryAfter, now: date)
        timing[key] = topicTiming
        if outcome.failure == .rateLimited {
            if (serverUntil[server] ?? 0) <= date.timeIntervalSince1970 {
                var policy = serverTiming[server] ?? PollTiming()
                policy.record(failure: .rateLimited, retryAfter: retryAfter, now: date)
                serverTiming[server] = policy
                serverUntil[server] = policy.nextAllowed.timeIntervalSince1970
            } else if let delay = PollTiming.retryDelay(retryAfter, now: date) {
                // Several requests already in flight can receive 429 together. They are one
                // failed burst, not successive retries; only a later retry doubles the delay.
                serverUntil[server] = max(serverUntil[server] ?? 0, date.addingTimeInterval(delay).timeIntervalSince1970)
            }
        } else if outcome.succeeded, (serverUntil[server] ?? 0) <= date.timeIntervalSince1970 {
            serverTiming.removeValue(forKey: server)
            serverUntil.removeValue(forKey: server)
        }
        serverUntil = serverUntil.filter { $0.value > date.timeIntervalSince1970 }
        if previousCooldowns != serverUntil { defaults?.set(serverUntil, forKey: Self.cooldownKey) }
        // A deferred caller must never replay already-ingested messages to background presentation.
        lastOutcome[key] = PollOutcome(succeeded: outcome.succeeded, newMessages: [], failure: outcome.failure)
        let waiting = callbacks.removeValue(forKey: key) ?? []
        lock.unlock()
        DeliveryHealthMonitor.shared.record(key: key, failure: outcome.failure)
        var presentationClaimed = false
        for waiter in waiting {
            var result = outcome
            if waiter.presenting {
                if presentationClaimed {
                    result = PollOutcome(succeeded: outcome.succeeded, newMessages: [], failure: outcome.failure)
                }
                presentationClaimed = true
            }
            waiter.completion(result)
        }
    }
}
