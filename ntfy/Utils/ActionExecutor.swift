import Foundation
import UIKit
import UserNotifications

/// Outcome of an `http` action's network request, split out as a pure value so the
/// status-code classification can be unit-tested without touching the network.
enum HTTPActionResult: Equatable {
    case success
    case failure(String) // human-readable reason (transport error or non-2xx status)
}

struct ActionExecutor {
    private static let tag = "ActionExecutor"
        
    static func execute(_ action: Action) {
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
            switch httpActionResult(response: response, error: error) {
            case .success:
                Log.d(self.tag, "HTTP \(method) action succeeded", response)
                notifyActionResult(action, success: true, detail: nil)
            case .failure(let reason):
                Log.e(self.tag, "HTTP \(method) action failed: \(reason)")
                notifyActionResult(action, success: false, detail: reason)
            }
        }.resume()
    }

    /// Classifies an `http` action response. A transport `error`, or an HTTP status
    /// outside 2xx, is a failure — the previous code logged non-2xx (e.g. a 401 on an
    /// "Approve" action) as success, so the user got no signal the action didn't take.
    static func httpActionResult(response: URLResponse?, error: Error?) -> HTTPActionResult {
        if let error = error {
            return .failure(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            // Non-HTTP (or missing) response with no transport error: nothing to
            // assess, treat the completed request as a success.
            return .success
        }
        guard (200..<300).contains(http.statusCode) else {
            return .failure("HTTP \(http.statusCode)")
        }
        return .success
    }

    /// Posts a local notification so the user sees whether an action succeeded — the
    /// only feedback channel that works from a banner tap, where there is no in-app UI.
    private static func notifyActionResult(_ action: Action, success: Bool, detail: String?) {
        let content = UNMutableNotificationContent()
        content.title = success ? "✅ \(action.label)" : "⚠️ \(action.label) failed"
        if !success, let detail = detail {
            content.body = detail
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil /* now */)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                Log.e(tag, "Unable to post action-result notification", error)
            }
        }
    }

    private static func open(url: URL) {
        Log.d(tag, "Opening URL \(url)")
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
}
