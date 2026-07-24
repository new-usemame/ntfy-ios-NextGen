import Foundation
import UIKit
import UserNotifications

struct ActionExecutor {
    private static let tag = "ActionExecutor"

    /// Executes a user-tapped action. When the action carries ntfy's `clear`
    /// flag and the id of the delivered notification is known, that notification
    /// is removed from Notification Center so the tap gives visible feedback
    /// (ntfy #1728 — e.g. a remote "Approve" button that otherwise leaves the
    /// banner on screen with no change). Adapted from binwiederhier/ntfy-ios#38
    /// (@abreparentesis) for this fork's ActionExecutor.
    static func execute(_ action: Action, notificationId: String? = nil) {
        Log.d(tag, "Executing user action", action)
        switch action.action {
        case "view":
            if let url = URL(string: action.url ?? "") {
                open(url: url)
            } else {
                Log.w(tag, "Unable to parse action URL", action)
            }
        case "http":
            http(action)
        default:
            Log.w(tag, "Action \(action.action) not supported", action)
        }

        if let ids = identifiersToClear(for: action, notificationId: notificationId) {
            Log.d(tag, "Clearing delivered notification(s) for action.clear", ids)
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    /// Pure decision — which delivered-notification identifiers a tap on `action`
    /// should dismiss, or `nil` when nothing should be cleared. The `clear` flag is
    /// honored only when a non-empty notification id is actually known (otherwise
    /// there is nothing to remove). Split out from the side effect above so it is
    /// unit-testable without touching Notification Center (see ntfyTests).
    static func identifiersToClear(for action: Action, notificationId: String?) -> [String]? {
        guard action.clear == true,
              let notificationId, !notificationId.isEmpty else {
            return nil
        }
        return [notificationId]
    }
    
    private static func http(_ action: Action) {
        guard let actionUrl = action.url, let url = URL(string: actionUrl) else {
            Log.w(tag, "Unable to execute HTTP action, no or invalid URL", action)
            return
        }
        let method = action.method ?? "POST" // POST is the default!!
        let body = action.body ?? ""

        Log.d(tag, "Performing HTTP \(method) \(url)")
        
        var request = URLRequest(url: url)
        request.httpMethod = method
        action.headers?.forEach { key, value in
            request.setValue(value, forHTTPHeaderField: key)
        }
        if !["GET", "HEAD"].contains(method) {
            request.httpBody = body.data(using: .utf8)
        }
        URLSession.shared.dataTask(with: request) { (data, response, error) in
            guard error == nil else {
                Log.e(self.tag, "Error performing HTTP \(method)", error!)
                return
            }
            Log.d(self.tag, "HTTP \(method) succeeded", response)
        }.resume()
    }
    
    private static func open(url: URL) {
        Log.d(tag, "Opening URL \(url)")
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
}
