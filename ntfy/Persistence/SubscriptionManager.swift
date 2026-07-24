import Foundation

/// Manager to combine persisting a subscription to the data store and subscribing to Firebase.
/// This is to centralize the logic in one place.
struct SubscriptionManager {
    private let tag = "SubscriptionManager"
    var store: Store
    var reconciler: FcmSubscriptionReconciler = .shared

    func subscribe(baseUrl: String, topic: String) {
        let normalizedBaseUrl = normalizeBaseUrl(baseUrl)
        Log.d(tag, "Subscribing to \(topicUrl(baseUrl: normalizedBaseUrl, topic: topic))")
        // Persist first. The row is created with `fcmSubscribed == false`, which
        // makes it the retry queue: if the FCM binding below fails (or never even
        // gets attempted because the APNs token hasn't landed yet), the next
        // reconcile picks it up. Previously the subscribe was fire-and-forget and
        // the row was saved regardless, so a single failure meant this topic
        // never received push again — ntfy#1305.
        let subscription = store.saveSubscription(baseUrl: normalizedBaseUrl, topic: topic)
        reconciler.reconcile(reason: "subscribed to \(topic)")
        poll(subscription)
    }

    func unsubscribe(_ subscription: Subscription) {
        Log.d(tag, "Unsubscribing from \(subscription.urlString())")
        DispatchQueue.main.async {
            if let baseUrl = subscription.baseUrl, let topic = subscription.topic {
                reconciler.unsubscribe(baseUrl: baseUrl, topic: topic)
            }
            store.delete(subscription: subscription)
        }
    }
    
    func poll(_ subscription: Subscription) {
        poll(subscription) { _ in }
    }
    
    func poll(_ subscription: Subscription, completionHandler: @escaping ([Message]) -> Void) {
        // This is a bit of a hack but it prevents us from polling dead subscriptions
        if (subscription.baseUrl == nil) {
            Log.d(tag, "Attempting to poll dead subscription failed")
            completionHandler([])
            return
        }
        
        let user = store.getUser(baseUrl: subscription.baseUrl!)?.toBasicUser()
        Log.d(tag, "Polling from \(subscription.urlString()) with user \(user?.username ?? "anonymous")")
        ApiService.shared.poll(subscription: subscription, user: user) { messages, error in
            guard let messages = messages else {
                Log.e(tag, "Polling failed", error)
                completionHandler([])
                return
            }
            // Report only what was actually stored. Overlapping polls share a `since` cursor (it is read
            // per-request in ApiService.poll), so the server routinely re-delivers messages we already
            // have — notifying for those re-alerts the user about a message they have already seen.
            let newMessages = store.save(notificationsFromMessages: messages, withSubscription: subscription)
            Log.d(tag, "Polling success, \(messages.count) message(s), \(newMessages.count) new", newMessages)
            completionHandler(newMessages)
        }
    }
}
