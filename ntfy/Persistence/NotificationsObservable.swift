import CoreData
import SwiftUI

class NotificationsObservable: NSObject, ObservableObject {
    private let tag = "NotificationsObservable"
    private var subscriptionID: NSManagedObjectID
    
    private lazy var fetchedResultsController: NSFetchedResultsController<Notification> = {
        let fetchRequest: NSFetchRequest<Notification> = Notification.fetchRequest()
        
        // Filter by the desired subscription
        fetchRequest.predicate = NSPredicate(format: "subscription == %@", subscriptionID)
        
        // Sort descriptors if you need them
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "time", ascending: false)] // Assuming you have a 'date' attribute on the NotificationEntity
        
        let controller = NSFetchedResultsController(fetchRequest: fetchRequest, managedObjectContext: Store.shared.context, sectionNameKeyPath: nil, cacheName: nil)
        controller.delegate = self
        return controller
    }()
    
    @Published var notifications: [Notification] = []
    
    init(subscriptionID: NSManagedObjectID) {
        self.subscriptionID = subscriptionID
        super.init()
        
        do {
            Log.d(tag, "Fetching notifications")
            try self.fetchedResultsController.performFetch()
            self.notifications = self.fetchedResultsController.fetchedObjects ?? []
        } catch {
            Log.w(tag, "Failed to fetch notifications \(error)")
        }
    }
}

extension NotificationsObservable: NSFetchedResultsControllerDelegate {
    func controllerDidChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>) {
        // The published array must never outlive the rows it points at. This delegate already runs on the
        // context's own queue — the main queue, since `Store.context` is the container's viewContext — so
        // republishing through `DispatchQueue.main.async` deferred the update by a whole runloop turn. For
        // that turn `notifications` still held a just-deleted Notification, while the save had already told
        // SwiftUI that the row's `@ObservedObject` changed; `NotificationRowView` then re-rendered against an
        // invalidated managed object and faulted. That is ntfy #1058: swipe-deleting one message in a topic
        // holding two or more kills the app with no error. Reading `fetchedObjects` here rather than inside
        // the closure also stops a deferred update from publishing a newer fetch than the one it was sent for.
        let fetched = fetchedResultsController.fetchedObjects ?? []
        if Thread.isMainThread {
            notifications = fetched
        } else {
            DispatchQueue.main.async { self.notifications = fetched }
        }
    }
}
