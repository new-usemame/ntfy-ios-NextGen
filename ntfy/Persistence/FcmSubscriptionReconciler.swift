import Foundation
import FirebaseMessaging

/// Abstracts the Firebase Messaging topic API.
///
/// FCM delivery cannot be exercised on the simulator (no APNs, no FCM), so the
/// *decision* logic — which topics still need subscribing, and when it is even
/// legal to try — lives in `FcmSubscriptionReconciler` behind this seam. Tests
/// inject a fake and assert on the calls we make; the network hop stays
/// device-only.
protocol FcmTopicSubscriber {
    /// FCM can only bind a topic to this device once the APNs token has been
    /// handed to Firebase. Subscribing before that fails for every topic.
    var hasApnsToken: Bool { get }
    func subscribe(toTopic topic: String, completion: @escaping (Error?) -> Void)
    func unsubscribe(fromTopic topic: String, completion: @escaping (Error?) -> Void)
}

struct FirebaseTopicSubscriber: FcmTopicSubscriber {
    var hasApnsToken: Bool { Messaging.messaging().apnsToken != nil }

    func subscribe(toTopic topic: String, completion: @escaping (Error?) -> Void) {
        Messaging.messaging().subscribe(toTopic: topic, completion: completion)
    }

    func unsubscribe(fromTopic topic: String, completion: @escaping (Error?) -> Void) {
        Messaging.messaging().unsubscribe(fromTopic: topic, completion: completion)
    }
}

/// Keeps the device's FCM topic subscriptions in sync with the subscriptions the
/// user actually has (ntfy#1305).
///
/// The bug this replaces: both `subscribe(toTopic:)` call sites were
/// fire-and-forget — they logged failures and moved on, while the Core Data row
/// was persisted regardless. A single transient failure (APNs token not yet
/// associated, network blip, FCM hiccup) left the app *looking* subscribed and
/// polling fine on refresh, while push was silently dead forever. Reinstalling
/// was the only repair, because it forced a fresh token and a clean re-subscribe
/// round.
///
/// The fix is to treat FCM subscription as *reconciled state* rather than a
/// one-shot side effect:
///   * every subscription carries `fcmSubscribed`, false until FCM confirms it;
///   * `reconcile()` re-fires only the ones still false, and is safe to call as
///     often as we like;
///   * it runs on APNs-token arrival, FCM-token arrival, and every foreground,
///     so a desynced device self-heals instead of needing a reinstall;
///   * a failure simply leaves the flag false, so the next reconcile retries —
///     no timers, no backoff bookkeeping.
final class FcmSubscriptionReconciler {
    private let tag = "FcmReconciler"

    /// Poll requests from the server arrive on this topic. It is not a user
    /// subscription, so its state lives in defaults rather than Core Data.
    static let pollTopic = "~poll" // See ntfy server if ever changed

    private static let defaultsKeyLastFcmToken = "lastFcmRegistrationToken"
    private static let defaultsKeyPollSubscribed = "pollTopicFcmSubscribed"

    static let shared = FcmSubscriptionReconciler(store: Store.shared)

    private let store: Store
    private let subscriber: FcmTopicSubscriber
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var inFlight = false

    init(store: Store,
         subscriber: FcmTopicSubscriber = FirebaseTopicSubscriber(),
         defaults: UserDefaults = UserDefaults(suiteName: Store.appGroup) ?? .standard) {
        self.store = store
        self.subscriber = subscriber
        self.defaults = defaults
    }

    /// Record the FCM registration token and invalidate everything if it changed.
    ///
    /// This is the half the original code got structurally wrong. FCM binds
    /// topics to a *token*, so when the token rotates every prior subscription
    /// is void — but the old code only re-subscribed opportunistically and
    /// nothing recorded whether the round worked. Tracking the last-seen token
    /// means a rotation reliably marks all topics stale, and reconciliation then
    /// rebuilds them (with retries) instead of hoping one pass succeeded.
    ///
    /// Returns true if the token was new (i.e. state was invalidated).
    @discardableResult
    func noteRegistrationToken(_ token: String?) -> Bool {
        guard let token = token, !token.isEmpty else {
            Log.w(tag, "FCM registration token missing; leaving subscription state untouched")
            return false
        }
        let previous = defaults.string(forKey: Self.defaultsKeyLastFcmToken)
        guard previous != token else { return false }

        Log.d(tag, "FCM token changed (\(previous?.prefix(12) ?? "none")... -> \(token.prefix(12))...); "
                 + "marking all topic subscriptions stale")
        defaults.set(token, forKey: Self.defaultsKeyLastFcmToken)
        defaults.set(false, forKey: Self.defaultsKeyPollSubscribed)
        store.markAllFcmSubscriptionsStale()
        return true
    }

    /// Re-subscribe every topic FCM has not confirmed for the current token.
    ///
    /// Safe and cheap to call repeatedly: with nothing pending it is a fetch and
    /// a return. Callers do not need to know whether the APNs token has landed —
    /// if it hasn't, this no-ops and the APNs callback drives the retry.
    func reconcile(reason: String) {
        guard subscriber.hasApnsToken else {
            // Not an error: `didReceiveRegistrationToken` routinely beats
            // `didRegisterForRemoteNotifications...`. Whichever lands second
            // re-drives us, so we just wait rather than burning a failed round.
            Log.d(tag, "reconcile(\(reason)) deferred — APNs token not associated with Firebase yet")
            return
        }

        lock.lock()
        if inFlight {
            lock.unlock()
            Log.d(tag, "reconcile(\(reason)) skipped — a round is already in flight")
            return
        }
        inFlight = true
        lock.unlock()

        var work: [(topic: String, confirm: () -> Void)] = []

        if !defaults.bool(forKey: Self.defaultsKeyPollSubscribed) {
            work.append((Self.pollTopic, { [weak self] in
                self?.defaults.set(true, forKey: Self.defaultsKeyPollSubscribed)
            }))
        }

        for subscription in store.getSubscriptionsPendingFcmSubscribe() {
            guard let baseUrl = subscription.baseUrl, let topic = subscription.topic else { continue }
            let name = firebaseTopic(baseUrl: baseUrl, topic: topic)
            work.append((name, { [weak self] in
                self?.store.setFcmSubscribed(subscription, true)
            }))
        }

        guard !work.isEmpty else {
            Log.d(tag, "reconcile(\(reason)): nothing pending")
            finish()
            return
        }

        Log.d(tag, "reconcile(\(reason)): (re-)subscribing \(work.count) topic(s)")
        let group = DispatchGroup()
        for item in work {
            group.enter()
            subscriber.subscribe(toTopic: item.topic) { [weak self] error in
                if let error = error {
                    // Leave the flag false on purpose — that IS the retry queue.
                    Log.e(self?.tag ?? "FcmReconciler",
                          "Firebase subscribe failed for \(item.topic); will retry on next reconcile", error)
                } else {
                    Log.d(self?.tag ?? "FcmReconciler", "Firebase subscribe confirmed for \(item.topic)")
                    item.confirm()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            self?.finish()
        }
    }

    /// Drop a topic's FCM binding. Used when the user removes a subscription.
    func unsubscribe(baseUrl: String, topic: String) {
        let name = firebaseTopic(baseUrl: baseUrl, topic: topic)
        subscriber.unsubscribe(fromTopic: name) { [weak self] error in
            if let error = error {
                Log.e(self?.tag ?? "FcmReconciler", "Firebase unsubscribe failed for \(name)", error)
            } else {
                Log.d(self?.tag ?? "FcmReconciler", "Firebase unsubscribe succeeded for \(name)")
            }
        }
    }

    private func finish() {
        lock.lock()
        inFlight = false
        lock.unlock()
    }
}
