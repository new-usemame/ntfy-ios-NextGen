import CoreData
import Foundation
import UserNotifications

/// Values match ntfy Android's global auto-delete options. Expiry uses message time.
enum NotificationRetention: Int64, CaseIterable {
    case forever = 0, day = 1, threeDays = 3, week = 7, month = 30, threeMonths = 90
    var seconds: Int64 { rawValue * 86_400 }
    var label: String {
        switch self {
        case .forever: return "Forever"
        case .day: return "1 day"
        case .threeDays: return "3 days"
        case .week: return "1 week"
        case .month: return "1 month (30 days)"
        case .threeMonths: return "3 months (90 days)"
        }
    }
}

enum NotificationHistoryStrings {
    static let title = "Keep notifications"
    static let section = "Notification history"
    static let explanation = "Older notifications and their downloaded attachments are permanently removed from this device while the app is open. Age is measured from the message date. Newly received messages and downloaded files have a one-hour grace period. Existing history is kept forever until you choose a limit. This does not clear notifications on other devices."
    static let loadOlder = "Load older notifications"
    static let noMatches = "No notifications match your search."
    static let search = "Search all notifications"
    static let saveError = "Could not save the setting"
    static let saveErrorExplanation = "Your previous retention setting is still in use. Try again."
}

extension Store {
    static let retentionPreferenceKey = "notificationRetentionDays"

    /// Adopt existing history without silently deleting it on upgrade. A fresh store uses Android's
    /// 30-day default. Persist the decision, so clearing a topic never changes the chosen policy.
    func notificationRetention() -> NotificationRetention {
        var result = NotificationRetention.forever
        context.performAndWait {
            do { result = try resolveRetention(in: context) }
            catch { Log.w(Store.tag, "Cannot read notification retention", error) }
        }
        return result
    }

    @discardableResult
    func saveNotificationRetention(_ policy: NotificationRetention) -> Bool {
        var saved = false
        context.performAndWait {
            do {
                let request = Preference.fetchRequest()
                request.predicate = NSPredicate(format: "key == %@", Self.retentionPreferenceKey)
                let pref = try context.fetch(request).first ?? Preference(context: context)
                pref.key = Self.retentionPreferenceKey
                pref.value = String(policy.rawValue)
                try context.save()
                saved = true
            } catch { Log.w(Store.tag, "Cannot save notification retention", error); context.rollback() }
        }
        if saved { pruneNotifications() }
        return saved
    }

    private func resolveRetention(in context: NSManagedObjectContext) throws -> NotificationRetention {
        let request = Preference.fetchRequest()
        request.predicate = NSPredicate(format: "key == %@", Self.retentionPreferenceKey)
        if let pref = try context.fetch(request).first {
            // Unknown future values fail safe instead of deleting someone's history.
            return Int64(pref.value ?? "").flatMap(NotificationRetention.init(rawValue:)) ?? .forever
        }
        let rows = Notification.fetchRequest()
        rows.fetchLimit = 1
        let policy: NotificationRetention = try context.count(for: rows) > 0 ? .forever : .month
        let pref = Preference(context: context)
        pref.key = Self.retentionPreferenceKey
        pref.value = String(policy.rawValue)
        try context.save()
        return policy
    }

    /// All fetch/delete/unlink work runs on a private queue. Each save is at most 200 rows.
    /// Default error merge policy is intentional: an NSE update after the fetch must abort that
    /// chunk, not let a store-trump merge silently delete the newly updated row. Files go only
    /// after a successful commit. No directory sweep can unlink an attachment still being written.
    func pruneNotifications(now: Date = Date(), completion: ((Result<Int, Error>) -> Void)? = nil) {
        retentionContext.perform {
            self.retentionContext.reset()
            do {
                let request = Notification.fetchRequest()
                request.fetchLimit = 200
                request.fetchBatchSize = 200
                var count = 0
                while true {
                    let policy = try self.resolveRetention(in: self.retentionContext)
                    guard policy != .forever else { break }
                    request.predicate = NSPredicate(format: "time < %lld AND (storedAt == nil OR storedAt < %@)",
                        Int64(now.timeIntervalSince1970) - policy.seconds, now.addingTimeInterval(-3600) as NSDate)
                    let rows = try self.retentionContext.fetch(request)
                    guard !rows.isEmpty else { break }
                    let paths = Set(rows.compactMap(\.attachmentLocalPath).filter { !$0.isEmpty })
                    let pending = NSFetchRequest<NSManagedObject>(entityName: "PendingAttachmentDeletion")
                    pending.predicate = NSPredicate(format: "path IN %@", Array(paths))
                    let queued = Set(try self.retentionContext.fetch(pending).compactMap { $0.value(forKey: "path") as? String })
                    for path in paths.subtracting(queued) {
                        let entry = NSEntityDescription.insertNewObject(forEntityName: "PendingAttachmentDeletion", into: self.retentionContext)
                        entry.setValue(path, forKey: "path")
                    }
                    let banners = rows.compactMap { row -> SequenceRemoval? in
                        guard let sub = row.subscription, let baseUrl = sub.baseUrl,
                              let topic = sub.topic, let id = row.id else { return nil }
                        return SequenceRemoval(baseUrl: baseUrl, topic: topic, sequence: row.sequenceID ?? id, throughTime: row.time)
                    }
                    rows.forEach(self.retentionContext.delete)
                    try self.retentionContext.save()
                    // One system query per chunk, rather than one per expired message.
                    if !banners.isEmpty {
                        let center = UNUserNotificationCenter.current()
                        center.getDeliveredNotifications { delivered in
                            let ids = delivered.filter { banner in
                                banners.contains { $0.matches(userInfo: banner.request.content.userInfo) }
                            }.map { $0.request.identifier }
                            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
                        }
                    }
                    count += rows.count
                    self.retentionContext.reset()
                }
                // Sequence deduplication tombstones also need a bound. Keep at least 120 days,
                // matching Android's hard-delete window, so delayed controls cannot revive history.
                let policy = try self.resolveRetention(in: self.retentionContext)
                if policy != .forever {
                    let states = NSFetchRequest<NSManagedObject>(entityName: "SequenceState")
                    states.fetchLimit = 200
                    states.predicate = NSPredicate(format: "time < %lld AND (storedAt == nil OR storedAt < %@)",
                        Int64(now.timeIntervalSince1970) - max(policy.seconds, 120 * 86_400), now.addingTimeInterval(-3600) as NSDate)
                    while true {
                        let rows = try self.retentionContext.fetch(states)
                        guard !rows.isEmpty else { break }
                        rows.forEach(self.retentionContext.delete)
                        try self.retentionContext.save()
                        self.retentionContext.reset()
                    }
                }
                try self.removeExpiredAttachmentFiles(now: now)
                // History is only used by live processes; new processes start at the current token.
                _ = try self.retentionContext.execute(NSPersistentHistoryChangeRequest.deleteHistory(before: now.addingTimeInterval(-7 * 86_400)))
                completion?(.success(count))
            } catch {
                self.retentionContext.rollback()
                self.retentionContext.reset()
                Log.w(Store.tag, "Cannot prune notification history; will retry on next maintenance", error)
                completion?(.failure(error))
            }
        }
    }

    /// Queue entries commit atomically with row deletion. A crash or failed unlink can therefore
    /// retry next time. Only exact retired paths are considered; never sweep the shared directory.
    private func removeExpiredAttachmentFiles(now: Date) throws {
        let request = NSFetchRequest<NSManagedObject>(entityName: "PendingAttachmentDeletion")
        request.fetchLimit = 200
        request.sortDescriptors = [NSSortDescriptor(key: "path", ascending: true)]
        var after = ""
        while true {
            request.predicate = NSPredicate(format: "path > %@", after)
            let entries = try retentionContext.fetch(request)
            guard !entries.isEmpty else { break }
            for entry in entries {
                guard let path = entry.value(forKey: "path") as? String else { continue }
                after = path
                do {
                    let removed = try AttachmentFileStore.withFileAccess(at: URL(fileURLWithPath: path)) {
                        let live = Notification.fetchRequest()
                        live.predicate = NSPredicate(format: "attachmentLocalPath == %@", path)
                        if try retentionContext.count(for: live) > 0 { return true } // path is owned again
                        let attributes = try FileManager.default.attributesOfItem(atPath: path)
                        // A download may finish before its row is saved. The shared file lock
                        // makes this check atomic with replacement by the app or NSE downloader.
                        if let modified = attributes[.modificationDate] as? Date,
                           modified > now.addingTimeInterval(-3600) { return false }
                        try FileManager.default.removeItem(atPath: path)
                        return true
                    }
                    if removed { retentionContext.delete(entry) }
                } catch let error as NSError {
                    if error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
                        retentionContext.delete(entry)
                    } else { Log.w(Store.tag, "Cannot remove expired attachment; queued for retry", error) }
                }
            }
            try retentionContext.save()
            retentionContext.reset()
        }
    }

}
