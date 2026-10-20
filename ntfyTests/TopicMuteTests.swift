import XCTest
import CoreData
import UserNotifications
@testable import ntfy

final class TopicMuteTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_792_512_000)

    func testMuteDeadlineBoundaryAndUntilResumed() {
        XCTAssertFalse(TopicMute.isMuted(until: nil, now: now))
        XCTAssertFalse(TopicMute.isMuted(until: now, now: now))
        XCTAssertFalse(TopicMute.isMuted(until: now.addingTimeInterval(-1), now: now))
        XCTAssertTrue(TopicMute.isMuted(until: now.addingTimeInterval(1), now: now))
        XCTAssertTrue(TopicMute.isMuted(until: .distantFuture, now: now))
        XCTAssertNil(TopicMute.status(until: now, now: now))
        XCTAssertEqual(TopicMute.status(until: .distantFuture, now: now), "Notifications muted until resumed")
    }

    func testAndroidDurationsAndTomorrowAt0830AcrossDaylightSaving() throws {
        for (duration, seconds) in [(TopicMuteDuration.minutes30, 1800), (.hour1, 3600), (.hours2, 7200), (.hours8, 28800)] {
            XCTAssertEqual(duration.deadline(now: now).timeIntervalSince(now), Double(seconds))
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        for (month, day) in [(3, 7), (10, 31), (12, 31)] {
            let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 23, minute: 45)))
            let deadline = TopicMuteDuration.tomorrow.deadline(now: date, calendar: calendar)
            let parts = calendar.dateComponents([.hour, .minute, .second], from: deadline)
            XCTAssertEqual(parts.hour, 8); XCTAssertEqual(parts.minute, 30); XCTAssertEqual(parts.second, 0)
            XCTAssertEqual(calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: deadline)).day, 1)
        }
    }

    func testMuteIsScopedByServerAndTopicAndSavedOutsideTheViewContext() throws {
        let store = Store(inMemory: true)
        let sub = store.saveSubscription(baseUrl: "https://mute.example", topic: "noise")
        XCTAssertFalse(store.isTopicMuted(baseUrl: sub.baseUrl!, topic: sub.topic!, now: now))
        try store.setTopicMute(until: now.addingTimeInterval(10), subscription: sub)
        XCTAssertTrue(store.isTopicMuted(baseUrl: "https://mute.example/", topic: "noise", now: now))
        XCTAssertFalse(store.isTopicMuted(baseUrl: "https://other.example", topic: "noise", now: now))
        XCTAssertFalse(store.isTopicMuted(baseUrl: "https://mute.example", topic: "other", now: now))
        XCTAssertFalse(store.isTopicMuted(baseUrl: sub.baseUrl!, topic: sub.topic!, now: now.addingTimeInterval(10)))
        try store.setTopicMute(until: nil, subscription: sub)
        XCTAssertFalse(store.isTopicMuted(baseUrl: sub.baseUrl!, topic: sub.topic!, now: now))
    }

    func testEveryPriorityAndCriticalOptInIsQuietWhileHistoryAndBadgeRemain() throws {
        let store = Store.shared
        let sub = store.saveSubscription(baseUrl: "https://mute.example", topic: "priority-\(UUID().uuidString)")
        let oldCritical = store.getCriticalAlertsEnabled()
        let oldAuthorized = Store.getCriticalAlertsAuthorized()
        defer {
            store.saveCriticalAlertsEnabled(oldCritical)
            Store.saveCriticalAlertsAuthorized(oldAuthorized)
            store.context.delete(sub); try? store.context.save()
        }
        store.saveCriticalAlertsEnabled(true)
        Store.saveCriticalAlertsAuthorized(true)
        try store.setTopicMute(until: .distantFuture, subscription: sub)
        for priority in 1...5 {
            let message = Message(id: "mute-p\(priority)", time: Int64(Date().timeIntervalSince1970), event: "message", topic: sub.topic!, message: "Keep muted history", priority: Int16(priority))
            _ = store.save(notificationsFromMessages: [message], withSubscription: sub)
            let content = UNMutableNotificationContent()
            content.modify(message: message, baseUrl: sub.baseUrl!)
            XCTAssertNil(content.sound, "priority \(priority) must not make a sound")
            XCTAssertEqual(content.interruptionLevel, .passive)
            XCTAssertEqual(content.relevanceScore, 0)
            XCTAssertEqual(content.body, "Keep muted history")
            XCTAssertEqual(content.badge?.intValue, store.totalUnreadCount())
        }
        XCTAssertEqual(sub.notificationCount(), 5)
        XCTAssertEqual(sub.unreadCount(), 5)
        try store.setTopicMute(until: nil, subscription: sub)
        let content = UNMutableNotificationContent()
        content.modify(message: Message(id: "resumed", time: 1, event: "message", topic: sub.topic!, priority: 4), baseUrl: sub.baseUrl!)
        XCTAssertNotNil(content.sound)
        XCTAssertEqual(content.interruptionLevel, .timeSensitive)
    }

    func testFallbackAndReplayContentsAreQuietAndExpiryRestoresNormalMapping() throws {
        let store = Store(inMemory: true)
        let sub = store.saveSubscription(baseUrl: "https://mute.example", topic: "fallback")
        try store.setTopicMute(until: now.addingTimeInterval(1), subscription: sub)
        for text in ["New message", "Couldn't fetch notification", "Encrypted message", "Notification state synchronized"] {
            let content = UNMutableNotificationContent()
            content.body = text; content.sound = .defaultCritical; content.interruptionLevel = .critical; content.badge = 42
            content.applyTopicMute(baseUrl: sub.baseUrl!, topic: sub.topic!, store: store, now: now)
            XCTAssertNil(content.sound); XCTAssertEqual(content.interruptionLevel, .passive)
            XCTAssertEqual(content.badge, 42); XCTAssertEqual(content.body, text)
        }
        let content = UNMutableNotificationContent()
        let message = Message(id: "expired", time: 1, event: "message", topic: sub.topic!, priority: 4)
        content.configureInterruption(message: message)
        content.applyTopicMute(baseUrl: sub.baseUrl!, topic: sub.topic!, store: store, now: now)
        XCTAssertNil(content.sound)
        // A fetch/attachment crossing the deadline rechecks the policy at final delivery.
        content.configureInterruption(message: message)
        content.applyTopicMute(baseUrl: sub.baseUrl!, topic: sub.topic!, store: store, now: now.addingTimeInterval(1))
        XCTAssertNotNil(content.sound); XCTAssertEqual(content.interruptionLevel, .timeSensitive)
    }

    func testPollHashRawTopicFallbackAndMalformedMessagesUseSameMuteDecision() throws {
        let store = Store(inMemory: true)
        let sub = store.saveSubscription(baseUrl: "https://mute.example", topic: "hash-muted")
        try store.setTopicMute(until: now.addingTimeInterval(10), subscription: sub)
        for topic in [sub.topic!, sub.urlHash()] {
            let info: [AnyHashable: Any] = ["topic": topic, "event": "poll_request", "base_url": "https://mute.example/"]
            XCTAssertTrue(store.isNotificationMuted(userInfo: info, now: now))
            XCTAssertFalse(store.isNotificationMuted(userInfo: info, now: now.addingTimeInterval(10)))
            let content = UNMutableNotificationContent()
            content.userInfo = info; content.sound = .default; content.interruptionLevel = .timeSensitive
            content.applyTopicMute(store: store, now: now)
            XCTAssertNil(content.sound); XCTAssertEqual(content.interruptionLevel, .passive)
        }
        // Even without a parsable Message, routing metadata still protects the NSE fallback.
        XCTAssertTrue(store.isNotificationMuted(userInfo: ["topic": sub.topic!, "base_url": sub.baseUrl!], now: now))
        XCTAssertFalse(store.isNotificationMuted(userInfo: ["topic": sub.topic!, "base_url": "https://other.example"], now: now))
    }

    func testModel7MigrationPreservesHistoryAndMutePersistsAcrossTwoProcesses() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("upgrade118.sqlite")
        let modelURL = try XCTUnwrap(Bundle.main.url(forResource: "ntfy", withExtension: "momd"))
        let oldModel = try XCTUnwrap(NSManagedObjectModel(contentsOf: modelURL.appendingPathComponent("Model 7.mom")))
        let old = NSPersistentStoreCoordinator(managedObjectModel: oldModel)
        let disk = try old.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = old
        let sub = NSEntityDescription.insertNewObject(forEntityName: "Subscription", into: context)
        sub.setValue("https://mute.example", forKey: "baseUrl"); sub.setValue("upgrade", forKey: "topic")
        sub.setValue("My alerts", forKey: "customDisplayName"); sub.setValue(true, forKey: "pinned")
        let row = NSEntityDescription.insertNewObject(forEntityName: "Notification", into: context)
        row.setValue("before118", forKey: "id"); row.setValue("Retain history", forKey: "message")
        row.setValue(3, forKey: "priority"); row.setValue(false, forKey: "read"); row.setValue(sub, forKey: "subscription")
        try context.save(); context.reset(); try old.remove(disk)
        let app = Store(inMemory: true, storeURL: url)
        let migrated = try XCTUnwrap(app.getSubscriptions()?.first)
        XCTAssertNil(migrated.mutedUntil)
        XCTAssertEqual(migrated.customDisplayName, "My alerts"); XCTAssertTrue(migrated.pinned)
        XCTAssertEqual(migrated.notificationCount(), 1); XCTAssertEqual(migrated.unreadCount(), 1)
        let nse = Store(inMemory: true, storeURL: url)
        XCTAssertFalse(nse.isTopicMuted(baseUrl: migrated.baseUrl!, topic: migrated.topic!, now: now))
        try app.setTopicMute(until: .distantFuture, subscription: migrated)
        XCTAssertTrue(nse.isTopicMuted(baseUrl: migrated.baseUrl!, topic: migrated.topic!, now: now))
        try app.setTopicMute(until: now.addingTimeInterval(1), subscription: migrated)
        XCTAssertFalse(nse.isTopicMuted(baseUrl: migrated.baseUrl!, topic: migrated.topic!, now: now.addingTimeInterval(1)))
        try app.setTopicMute(until: nil, subscription: migrated)
        XCTAssertFalse(nse.isTopicMuted(baseUrl: migrated.baseUrl!, topic: migrated.topic!, now: now))
        for store in [nse, app] {
            store.context.reset()
            for disk in store.container.persistentStoreCoordinator.persistentStores { try store.container.persistentStoreCoordinator.remove(disk) }
        }
    }
}

/// Uses only 1.18 APIs so these tests compile and fail as assertions on main.
final class MuteMainRegressionTests: XCTestCase {
    func testPersistedMuteDeadlineExists() {
        XCTAssertNotNil(Store.shared.container.managedObjectModel.entitiesByName["Subscription"]?.attributesByName["mutedUntil"], "1.18 has no durable per-topic mute state")
    }
    func testMutedPriorityFiveDoesNotAlertAndStillStoresHistory() throws {
        let store = Store.shared
        let sub = store.saveSubscription(baseUrl: "https://mute.example", topic: "main-red")
        defer { store.context.delete(sub); try? store.context.save() }
        if sub.entity.attributesByName["mutedUntil"] != nil {
            sub.setValue(Date.distantFuture, forKey: "mutedUntil"); try store.context.save()
        }
        let msg = Message(id: "mute-main-red", time: Int64(Date().timeIntervalSince1970), event: "message", topic: "main-red", message: "Quiet history", priority: 5)
        _ = store.save(notificationsFromMessages: [msg], withSubscription: sub)
        let content = UNMutableNotificationContent()
        content.modify(message: msg, baseUrl: sub.baseUrl!)
        XCTAssertNil(content.sound, "muted priority 5 must not play sound")
        XCTAssertEqual(content.interruptionLevel, .passive, "muted priority 5 must not bypass Focus")
        XCTAssertEqual(sub.notificationCount(), 1)
        XCTAssertEqual(content.body, "Quiet history")
    }
}

/// Compiles the actual extension source into the test bundle. This exercises its final
/// delivery gate, without pretending that a simulator APNs push launched an NSE process.
final class TopicMuteNSETests: XCTestCase {
    func testActualNSESuccessAndDecodeFallbackStayQuietAtPriorityFive() throws {
        let store = Store.shared
        let sub = store.saveSubscription(baseUrl: "https://mute.example", topic: "nse-success")
        defer { store.context.delete(sub); try? store.context.save() }
        try store.setTopicMute(until: .distantFuture, subscription: sub)
        for malformed in [false, true] {
            let service = NotificationService()
            let content = UNMutableNotificationContent()
            content.body = "Incoming fallback"; content.sound = .defaultCritical; content.interruptionLevel = .critical
            if malformed {
                content.userInfo = ["base_url": sub.baseUrl!, "topic": sub.topic!]
            } else {
                content.userInfo = Message(id: "nse-stored", time: Int64(Date().timeIntervalSince1970), event: "message", topic: sub.topic!, message: "NSE stored muted history", priority: 5).toUserInfo()
                content.userInfo["base_url"] = sub.baseUrl!
            }
            let done = expectation(description: "actual NSE handler \(malformed)")
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            DispatchQueue.global(qos: .userInitiated).async {
                service.didReceive(request) { output in
                    XCTAssertNil(output.sound); XCTAssertEqual(output.interruptionLevel, .passive)
                    XCTAssertEqual(output.body, malformed ? "Incoming fallback" : "NSE stored muted history")
                    done.fulfill()
                }
            }
            wait(for: [done], timeout: 8)
        }
        XCTAssertEqual(sub.notificationCount(), 1)
        XCTAssertEqual(sub.unreadCount(), 1)
    }

    func testActualNSEHashedPollExpiryAndFailureUseQuietFallbackExactlyOnce() throws {
        let store = Store.shared
        let sub = store.saveSubscription(baseUrl: "http://127.0.0.1:1", topic: "nse-fallback")
        defer { store.context.delete(sub); try? store.context.save() }
        try store.setTopicMute(until: .distantFuture, subscription: sub)
        let expectedTopic = sub.topic!
        let service = NotificationService()
        let content = UNMutableNotificationContent()
        content.sound = .default; content.interruptionLevel = .timeSensitive
        content.userInfo = ["id": "nse-poll", "time": "1", "event": "poll_request", "topic": sub.urlHash(), "poll_id": "nse-poll", "base_url": sub.baseUrl!]
        let request = UNNotificationRequest(identifier: "nse-poll", content: content, trigger: nil)
        let done = expectation(description: "one final delivery")
        done.assertForOverFulfill = true
        service.didReceive(request) { output in
            XCTAssertNil(output.sound); XCTAssertEqual(output.interruptionLevel, .passive)
            XCTAssertEqual(output.title, expectedTopic)
            done.fulfill()
        }
        // This is the real expiry entry point while the fetch is still pending.
        service.serviceExtensionTimeWillExpire()
        wait(for: [done], timeout: 8)
    }
}
