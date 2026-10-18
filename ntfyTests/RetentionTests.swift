import XCTest
import CoreData
import Combine
@testable import ntfy

final class RetentionTests: XCTestCase {
    private var store: Store { Store.shared }
    private var subscriptions: [ntfy.Subscription] = []

    override func tearDown() {
        store.context.performAndWait {
            subscriptions.forEach { store.context.delete($0) }
            try? store.context.save()
        }
        subscriptions = []
        super.tearDown()
    }

    private func fixture(_ count: Int) throws -> ntfy.Subscription {
        let subscription = store.saveSubscription(baseUrl: "https://retention.example", topic: "scale-\(UUID().uuidString)")
        subscriptions.append(subscription)
        for i in 0..<count {
            let row = ntfy.Notification(context: store.context)
            row.id = "fixture-\(subscription.topic!)-\(i)"
            row.time = Int64(1_790_000_000 + i)
            row.message = "Monitoring sample \(i): backup completed"
            row.title = "Backup \(i)"
            row.priority = 3
            row.read = true
            row.subscription = subscription
        }
        try store.context.save()
        store.hardRefresh()
        return subscription
    }

    func testRetentionRemovesExpiredRowsAndFilesButKeepsBoundaryAndFreshWrites() throws {
        let isolated = Store(inMemory: true)
        isolated.saveNotificationRetention(.month)
        let context = isolated.context
        let subscription = isolated.saveSubscription(baseUrl: "https://retention.example", topic: "expiry")
        let now = Date()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var rows: [String: ntfy.Notification] = [:]
        for (id, age, fresh) in [("old", 31, false), ("boundary", 30, false), ("new", 2, false), ("incoming", 60, true)] {
            let row = ntfy.Notification(context: context)
            row.id = "retention-" + id
            row.message = id
            row.time = Int64(now.timeIntervalSince1970) - Int64(age * 86_400)
            row.subscription = subscription
            row.storedAt = fresh ? now : nil // nil models rows migrated from Model 6
            let file = dir.appendingPathComponent(id)
            try Data(id.utf8).write(to: file)
            if !fresh { try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-31 * 86_400)], ofItemAtPath: file.path) }
            row.attachmentLocalPath = file.path
            rows[id] = row
        }
        try context.save()
        let done = expectation(description: "background expiry committed")
        isolated.pruneNotifications(now: now) { result in
            XCTAssertFalse(Thread.isMainThread, "expiry and file cleanup run off main")
            XCTAssertEqual(try? result.get(), 1)
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        context.performAndWait {
            let remaining = try? context.fetch(ntfy.Notification.fetchRequest())
            XCTAssertEqual(Set(remaining?.compactMap(\.id) ?? []), ["retention-boundary", "retention-new", "retention-incoming"])
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("old").path))
        for id in ["new", "boundary", "incoming"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(id).path))
        }
    }

    func testForeverKeepsAllHistoryAndAttachments() throws {
        let isolated = Store(inMemory: true)
        isolated.saveNotificationRetention(.forever)
        let sub = isolated.saveSubscription(baseUrl: "https://retention.example", topic: "forever")
        let row = ntfy.Notification(context: isolated.context)
        row.id = "forever-old"
        row.message = "keep"
        row.time = 1
        row.subscription = sub
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("keep".utf8).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        row.attachmentLocalPath = path.path
        try isolated.context.save()
        let done = expectation(description: "forever finishes")
        isolated.pruneNotifications { result in
            XCTAssertEqual(try? result.get(), 0)
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(try isolated.context.count(for: ntfy.Notification.fetchRequest()), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
    }

    func testRetentionAdoptionPreservesExistingUsersAndUsesAndroidDefaultForFreshStore() throws {
        let fresh = Store(inMemory: true)
        XCTAssertEqual(fresh.notificationRetention(), .month)
        let existing = Store(inMemory: true)
        let sub = existing.saveSubscription(baseUrl: "https://retention.example", topic: "existing")
        let row = ntfy.Notification(context: existing.context)
        row.id = "before-upgrade"
        row.message = "old history"
        row.time = 1
        row.subscription = sub
        try existing.context.save()
        XCTAssertEqual(existing.notificationRetention(), .forever)
        existing.context.delete(row)
        try existing.context.save()
        XCTAssertEqual(existing.notificationRetention(), .forever, "emptying history must not switch the adopted policy")
    }

    func testLoadOlderAndPushAreIncrementalAndSearchReachesUnloadedHistory() throws {
        let sub = try fixture(151)
        let model = NotificationsObservable(subscriptionID: sub.objectID)
        XCTAssertEqual(model.notifications.count, 50)
        model.loadOlder()
        XCTAssertEqual(model.notifications.count, 100)
        XCTAssertEqual(Set(model.notifications.map(\.objectID)).count, 100)
        let fetches = model.fetchCount
        let message = Message(id: "incremental-push", time: 1_790_010_000, event: "message", topic: sub.topic!, message: "live push")
        _ = store.ingest(pushedMessage: message, baseUrl: sub.baseUrl!, topic: sub.topic!)
        XCTAssertEqual(model.notifications.first?.id, "incremental-push")
        XCTAssertEqual(model.fetchCount, fetches, "a push must not performFetch against loaded history")
        XCTAssertEqual(model.notifications.count, 100)
        model.search("sample 0:")
        XCTAssertEqual(model.notifications.map(\.time), [1_790_000_000], "search must run in the store, including unloaded pages")
        model.search("")
        model.loadOlder()
        model.loadOlder()
        model.loadOlder()
        XCTAssertEqual(model.notifications.count, 152)
        XCTAssertFalse(model.hasOlder)
    }

    func testPagingDoesNotNarrowReadCountsOrClearAllAndDeleteRemovesVisibleRowsImmediately() throws {
        store.clearPublisher = { _, done in done(true) }
        store.wakePublisher = { _, done in done() }
        store.notificationRemover = { _ in }
        let sub = try fixture(151)
        let request = ntfy.Notification.fetchRequest()
        request.predicate = NSPredicate(format: "subscription == %@", sub)
        for row in try store.context.fetch(request) { row.read = false }
        try store.context.save()
        let model = NotificationsObservable(subscriptionID: sub.objectID)
        XCTAssertEqual(sub.unreadCount(), 151)
        store.setRead(true, forSubscription: sub)
        XCTAssertEqual(sub.unreadCount(), 0)
        XCTAssertTrue(model.notifications.allSatisfy(\.read))
        store.delete(notification: try XCTUnwrap(model.notifications.first))
        XCTAssertEqual(model.notifications.count, 50)
        XCTAssertFalse(model.notifications.contains { $0.isDeleted || $0.managedObjectContext == nil })
        store.delete(allNotificationsFor: sub)
        XCTAssertTrue(model.notifications.isEmpty)
        XCTAssertEqual(try store.context.count(for: request), 0)
        XCTAssertEqual(sub.unreadCount(), 0)
    }


    func testCrossCoordinatorPushMergesIntoOpenPageWithoutRefetch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("shared.sqlite")
        // Distinct persistent-store coordinators model the app and NSE processes, not merely two
        // contexts whose saves automatically merge from the same parent.
        let app = Store(inMemory: true, storeURL: url)
        app.saveNotificationRetention(.forever)
        let sub = app.saveSubscription(baseUrl: "https://retention.example", topic: "cross-process")
        let model = NotificationsObservable(subscriptionID: sub.objectID, context: app.context)
        let fetches = model.fetchCount
        let writer = Store(inMemory: true, storeURL: url)
        writer.context.transactionAuthor = "ntfy.appex"
        let message = Message(id: "nse-writer", time: Int64(Date().timeIntervalSince1970), event: "message", topic: "cross-process", message: "written by push")
        XCTAssertNotNil(writer.ingest(pushedMessage: message, baseUrl: "https://retention.example", topic: "cross-process"))
        let merged = expectation(description: "NSE history merged")
        app.mergeRemoteHistory { merged.fulfill() }
        wait(for: [merged], timeout: 10)
        XCTAssertEqual(model.notifications.map(\.id), ["nse-writer"])
        XCTAssertEqual(model.fetchCount, fetches, "the remote push must apply changed IDs without a window fetch")
        XCTAssertEqual(app.unreadCount(baseUrl: "https://retention.example", topic: "cross-process"), 1)

        let writerRow = try XCTUnwrap(writer.context.fetch(ntfy.Notification.fetchRequest()).first)
        writer.delete(notification: writerRow)
        let deleted = expectation(description: "NSE delete merged")
        app.mergeRemoteHistory { deleted.fulfill() }
        wait(for: [deleted], timeout: 10)
        XCTAssertTrue(model.notifications.isEmpty)
    }

    func testPruneCannotDeleteARowUpdatedByPushAfterItsFetch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("shared.sqlite")
        let app = Store(inMemory: true, storeURL: url)
        app.saveNotificationRetention(.month)
        let sub = app.saveSubscription(baseUrl: "https://retention.example", topic: "race")
        let now = Date()
        let row = ntfy.Notification(context: app.context)
        row.id = "old-version"
        row.sequenceID = "running-job"
        row.sequenceKey = "https://retention.example/race/running-job"
        row.time = Int64(now.timeIntervalSince1970) - 31 * 86_400
        row.message = "old"
        row.subscription = sub
        try app.context.save()
        let writer = Store(inMemory: true, storeURL: url)
        writer.context.transactionAuthor = "ntfy.appex"
        let file = dir.appendingPathComponent("incoming-attachment")
        try Data("new attachment".utf8).write(to: file)
        let pushed = expectation(description: "push updated the row during pruning")
        // WillSave fires after the candidates were fetched but before their delete commits.
        let observer = NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextWillSave, object: app.retentionContext, queue: nil
        ) { _ in
            guard !app.retentionContext.deletedObjects.isEmpty else { return }
            writer.context.performAndWait {
                let message = Message(id: "new-version", time: Int64(now.timeIntervalSince1970), event: "message", topic: "race", message: "new", sequenceID: "running-job")
                XCTAssertNotNil(writer.ingest(pushedMessage: message, baseUrl: "https://retention.example", topic: "race"))
                writer.completeAttachmentDownload(notificationID: "new-version", localPath: file.path, resolvedType: nil, resolvedSize: 14)
            }
            pushed.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let finished = expectation(description: "prune either safely aborts or excludes updated row")
        app.pruneNotifications(now: now) { _ in finished.fulfill() }
        wait(for: [pushed, finished], timeout: 10)
        writer.context.performAndWait {
            writer.hardRefresh()
            let rows = try? writer.context.fetch(ntfy.Notification.fetchRequest())
            XCTAssertEqual(rows?.compactMap(\.id), ["new-version"])
            XCTAssertEqual(rows?.first?.message, "new")
            XCTAssertEqual(rows?.first?.attachmentLocalPath, file.path)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testEveryAndroidRetentionChoiceAndRecentPushGrace() throws {
        XCTAssertEqual(NotificationRetention.allCases.map(\.rawValue), [0, 1, 3, 7, 30, 90])
        for policy in NotificationRetention.allCases where policy != .forever {
            let isolated = Store(inMemory: true)
            isolated.saveNotificationRetention(policy)
            let sub = isolated.saveSubscription(baseUrl: "https://retention.example", topic: "policy")
            let now = Date()
            let message = Message(id: "old-but-arriving-now", time: Int64(now.timeIntervalSince1970) - policy.seconds - 1,
                                  event: "message", topic: "policy", message: "keep while NSE writes")
            XCTAssertNotNil(isolated.ingest(pushedMessage: message, baseUrl: sub.baseUrl!, topic: sub.topic!))
            let grace = expectation(description: "newly written push survives expiry")
            isolated.pruneNotifications(now: now) { result in
                XCTAssertEqual(try? result.get(), 0)
                grace.fulfill()
            }
            wait(for: [grace], timeout: 10)
            XCTAssertEqual(try isolated.context.count(for: ntfy.Notification.fetchRequest()), 1)
            let expired = expectation(description: "message expires after ingestion grace")
            isolated.pruneNotifications(now: now.addingTimeInterval(3601)) { result in
                XCTAssertEqual(try? result.get(), 1)
                expired.fulfill()
            }
            wait(for: [expired], timeout: 10)
            XCTAssertEqual(try isolated.context.count(for: ntfy.Notification.fetchRequest()), 0)
        }
    }

    func testCommittedAttachmentCleanupSurvivesInterruptionAndProtectsUncommittedDownloads() throws {
        let isolated = Store(inMemory: true)
        isolated.saveNotificationRetention(.forever)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("download in flight".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        // Represents a crash after committing the row deletion, before unlinking its old path.
        let entry = NSEntityDescription.insertNewObject(forEntityName: "PendingAttachmentDeletion", into: isolated.context)
        entry.setValue(file.path, forKey: "path")
        let missing = NSEntityDescription.insertNewObject(forEntityName: "PendingAttachmentDeletion", into: isolated.context)
        missing.setValue(file.path + ".missing", forKey: "path")
        try isolated.context.save()
        let now = Date()
        let protected = expectation(description: "uncommitted download survives")
        isolated.pruneNotifications(now: now) { _ in protected.fulfill() }
        wait(for: [protected], timeout: 10)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try isolated.context.count(for: NSFetchRequest<NSManagedObject>(entityName: "PendingAttachmentDeletion")), 1,
                       "an already-missing file must not leave a permanent cleanup entry")
        let retried = expectation(description: "committed cleanup retried after grace")
        isolated.pruneNotifications(now: now.addingTimeInterval(3601)) { _ in retried.fulfill() }
        wait(for: [retried], timeout: 10)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try isolated.context.count(for: NSFetchRequest<NSManagedObject>(entityName: "PendingAttachmentDeletion")), 0)
    }

    func testLateDownloadCompletionCleansFileAfterItsRowWasDeleted() throws {
        let isolated = Store(inMemory: true)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("late".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        isolated.completeAttachmentDownload(notificationID: "already-deleted", localPath: file.path, resolvedType: nil, resolvedSize: 4)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testModel6HistoryMigratesWithoutDeletingRowsOrAttachmentPaths() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("old.sqlite")
        try autoreleasepool {
            let modelURL = try XCTUnwrap(Bundle.main.url(forResource: "ntfy", withExtension: "momd"))
                .appendingPathComponent("Model 6.mom")
            let model = try XCTUnwrap(NSManagedObjectModel(contentsOf: modelURL))
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
            let disk = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url)
            let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
            context.persistentStoreCoordinator = coordinator
            let sub = NSManagedObject(entity: try XCTUnwrap(model.entitiesByName["Subscription"]), insertInto: context)
            sub.setValue("https://retention.example", forKey: "baseUrl")
            sub.setValue("migrate", forKey: "topic")
            let row = NSManagedObject(entity: try XCTUnwrap(model.entitiesByName["Notification"]), insertInto: context)
            row.setValue("model6-history", forKey: "id")
            row.setValue("history", forKey: "message")
            row.setValue(1, forKey: "time")
            row.setValue("/example/attachment", forKey: "attachmentLocalPath")
            row.setValue(sub, forKey: "subscription")
            try context.save()
            context.reset()
            try coordinator.remove(disk)
        }
        let migrated = Store(inMemory: true, storeURL: url)
        let rows = try migrated.context.fetch(ntfy.Notification.fetchRequest())
        XCTAssertEqual(rows.compactMap(\.id), ["model6-history"])
        XCTAssertEqual(rows.first?.attachmentLocalPath, "/example/attachment")
        XCTAssertNil(rows.first?.storedAt)
        XCTAssertEqual(migrated.notificationRetention(), .forever)
    }


    func testFileAccessSerializesWritersAndPruning() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("shared-file")
        let firstEntered = expectation(description: "writer holds file lock")
        let firstExited = expectation(description: "writer finished")
        let secondEntered = expectation(description: "pruner acquired file lock after writer")
        let release = DispatchSemaphore(value: 0)
        let firstDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            do {
                try AttachmentFileStore.withFileAccess(at: file) {
                    firstEntered.fulfill()
                    _ = release.wait(timeout: .now() + 5)
                    firstDone.signal()
                }
            } catch { XCTFail("writer lock: \(error)") }
            firstExited.fulfill()
        }
        wait(for: [firstEntered], timeout: 5)
        DispatchQueue.global().async {
            do {
                try AttachmentFileStore.withFileAccess(at: file) {
                    XCTAssertEqual(firstDone.wait(timeout: .now()), .success, "pruner cannot enter while writer still owns the directory lock")
                    secondEntered.fulfill()
                }
            } catch { XCTFail("pruner lock: \(error)") }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { release.signal() }
        wait(for: [firstExited, secondEntered], timeout: 5)
    }

    func testSameSecondPagingHasNoDuplicatesOrGaps() throws {
        let sub = try fixture(125)
        let request = ntfy.Notification.fetchRequest()
        request.predicate = NSPredicate(format: "subscription == %@", sub)
        let all = try store.context.fetch(request)
        all.forEach { $0.time = 1_790_000_000 }
        try store.context.save()
        let model = NotificationsObservable(subscriptionID: sub.objectID)
        model.loadOlder()
        model.loadOlder()
        XCTAssertEqual(model.notifications.count, 125)
        XCTAssertEqual(Set(model.notifications.map(\.objectID)), Set(all.map(\.objectID)))
        XCTAssertFalse(model.hasOlder)
    }

    func testSequenceBookkeepingIsBoundedAndProtectsRecentWrites() throws {
        let isolated = Store(inMemory: true)
        isolated.saveNotificationRetention(.month)
        let now = Date()
        for (key, time, stored) in [("expired", Int64(1), Optional<Date>.none),
                                    ("boundary", Int64(now.timeIntervalSince1970) - 120 * 86_400, nil),
                                    ("incoming", Int64(1), now)] {
            let state = NSEntityDescription.insertNewObject(forEntityName: "SequenceState", into: isolated.context)
            state.setValue(key, forKey: "key")
            state.setValue(key, forKey: "sequenceID")
            state.setValue(key, forKey: "eventID")
            state.setValue("message_delete", forKey: "event")
            state.setValue(time, forKey: "time")
            state.setValue(stored, forKey: "storedAt")
        }
        try isolated.context.save()
        let done = expectation(description: "bookkeeping expiry")
        isolated.pruneNotifications(now: now) { _ in done.fulfill() }
        wait(for: [done], timeout: 10)
        let rows = try isolated.context.fetch(NSFetchRequest<NSManagedObject>(entityName: "SequenceState"))
        XCTAssertEqual(Set(rows.compactMap { $0.value(forKey: "key") as? String }), ["boundary", "incoming"])
    }

    func testScaleMeasurement10k() throws {
        let subscription = try fixture(10_000)
        let start = CFAbsoluteTimeGetCurrent()
        let model = NotificationsObservable(subscriptionID: subscription.objectID)
        // Read the same properties SwiftUI's rows need; don't time only an array of faults.
        let characters = model.notifications.reduce(0) { $0 + ($1.message?.count ?? 0) }
        let opened = CFAbsoluteTimeGetCurrent()
        model.refetch()
        let refreshedCharacters = model.notifications.reduce(0) { $0 + ($1.message?.count ?? 0) }
        let refreshed = CFAbsoluteTimeGetCurrent()
        let message = Message(id: "scale-push-\(UUID().uuidString)", time: 1_790_020_000, event: "message", topic: subscription.topic!, message: "new monitoring message")
        _ = store.ingest(pushedMessage: message, baseUrl: subscription.baseUrl!, topic: subscription.topic!)
        let pushCharacters = model.notifications.reduce(0) { $0 + ($1.message?.count ?? 0) }
        let end = CFAbsoluteTimeGetCurrent()
        print("RETENTION_SCALE rows=10000 published=\(model.notifications.count) open_ms=\((opened-start)*1000) remote_refresh_ms=\((refreshed-opened)*1000) push_ingest_and_publish_ms=\((end-refreshed)*1000) chars=\(characters)/\(refreshedCharacters)/\(pushCharacters)")
        XCTAssertGreaterThan(characters, 0)
    }

    func testFirstPageIsBoundedWith10kRows() throws {
        let subscription = try fixture(10_000)
        let model = NotificationsObservable(subscriptionID: subscription.objectID)
        XCTAssertEqual(model.notifications.count, 50, "Opening a topic must not publish its entire history")
        XCTAssertEqual(model.notifications.first?.time, 1_790_009_999)
    }
}
