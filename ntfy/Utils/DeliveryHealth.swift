import Foundation
import UserNotifications

/// English copy for delivery health, shared with the notification extension.
/// Keep these together until this feature is localized.
enum DeliveryHealthCopy {
    static let notificationsOff = "Notifications are turned off for this app."
    static let openSettings = "Open Settings"
    static let allowNotifications = "Allow notifications"
    static let permissionNeeded = "Allow notifications to receive alerts."
    static let status = "Notification status"
    static let permission = "Permission"
    static let phoneRegistration = "Phone registration"
    static let pushRegistration = "Push registration"
    static let registered = "Registered"
    static let waiting = "Not registered yet"
    static let pendingTopics = "Topics waiting for push"
    static let repair = "Repair"
    static let repairing = "Repairing…"
    static let repairComplete = "Push setup is complete. This does not check delivery from your server."
    static let repairWaiting = "Push registration is not ready. Check your connection and try again."
    static let repairPending = "Push setup is still incomplete. Try again later."
    static let repairTimeout = "Repair is still running. Check again in a moment."
    static let unreachable = "Can't reach the server"
    static let unauthorized = "Sign-in failed"
    static let rateLimited = "The server is limiting requests"
    static let otherFailure = "Couldn't refresh this topic"

    static func permissionLabel(_ state: UNAuthorizationStatus) -> String {
        switch state {
        case .denied: return "Turned off"
        case .authorized: return "Allowed"
        case .provisional: return "Quiet delivery"
        case .ephemeral: return "Allowed temporarily"
        case .notDetermined: return "Not requested yet"
        @unknown default: return "Unknown"
        }
    }

    static func fetchFailure(topic: String) -> String {
        "New message on \(topic). Open the app to load it."
    }
}

enum NotificationHealth {
    static func showsBanner(for state: UNAuthorizationStatus) -> Bool { state == .denied }

    static func repairResult(permission: UNAuthorizationStatus, registered: Bool, bindingsComplete: Bool) -> String {
        switch permission {
        case .denied: return DeliveryHealthCopy.notificationsOff
        case .notDetermined: return DeliveryHealthCopy.permissionNeeded
        case .authorized, .provisional, .ephemeral: break
        @unknown default: return DeliveryHealthCopy.permissionNeeded
        }
        guard registered else { return DeliveryHealthCopy.repairWaiting }
        return bindingsComplete ? DeliveryHealthCopy.repairComplete : DeliveryHealthCopy.repairPending
    }

    /// Overwrite every server-controlled presentation field, preserving routing metadata only.
    /// This is also the best attempt installed BEFORE fetching, so expiry cannot show ciphertext.
    static func fetchFailureContent(_ content: UNNotificationContent, topic: String, baseUrl: String? = nil) -> UNMutableNotificationContent {
        let safe = (content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        safe.title = topic
        safe.subtitle = ""
        safe.body = DeliveryHealthCopy.fetchFailure(topic: topic)
        safe.attachments = []
        safe.categoryIdentifier = ""
        safe.userInfo.removeValue(forKey: "click")
        safe.userInfo.removeValue(forKey: "actions")
        safe.userInfo["topic"] = topic
        if let baseUrl { safe.userInfo["base_url"] = baseUrl }
        return safe
    }
}

/// Retain HTTP status and Retry-After without retaining response bodies or credentials.
struct PollHTTPError: Error {
    let status: Int
    let retryAfter: String?
}

enum PollFailure: Equatable {
    case unreachable, unauthorized, rateLimited, other

    static func classify(_ error: Error?) -> PollFailure {
        if let http = error as? PollHTTPError {
            switch http.status {
            case 401, 403: return .unauthorized
            case 429: return .rateLimited
            default: return .other
            }
        }
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                 .dnsLookupFailed, .timedOut, .secureConnectionFailed: return .unreachable
            default: return .other
            }
        }
        return .other
    }

    var label: String {
        switch self {
        case .unreachable: return DeliveryHealthCopy.unreachable
        case .unauthorized: return DeliveryHealthCopy.unauthorized
        case .rateLimited: return DeliveryHealthCopy.rateLimited
        case .other: return DeliveryHealthCopy.otherFailure
        }
    }
}

struct TopicDeliveryHealth {
    private(set) var failure: PollFailure?
    private(set) var consecutiveFailures = 0
    var label: String? { failure?.label }
    var needsAttention: Bool { consecutiveFailures >= 3 }

    mutating func record(_ failure: PollFailure?) {
        self.failure = failure
        consecutiveFailures = failure == nil ? 0 : consecutiveFailures + 1
    }
}

struct PollTiming {
    static let minimumInterval: TimeInterval = 30
    private(set) var nextAllowed = Date.distantPast
    private(set) var failures = 0
    private var limited = false

    func allowsPoll(now: Date, manual: Bool) -> Bool {
        now >= nextAllowed || (manual && !limited)
    }

    mutating func record(failure: PollFailure?, retryAfter: String?, now: Date) {
        failures = failure == nil ? 0 : min(failures + 1, 16)
        limited = failure == .rateLimited
        let base: TimeInterval = limited ? 60 : Self.minimumInterval
        let cap: TimeInterval = limited ? 3600 : 300
        let delay = failure == nil ? base : min(base * pow(2, Double(max(0, failures - 1))), cap)
        nextAllowed = now.addingTimeInterval(max(delay, limited ? Self.retryDelay(retryAfter, now: now) ?? 0 : 0))
    }

    /// RFC 9110: nonnegative integer delta-seconds or HTTP-date. Ignore malformed input.
    static func retryDelay(_ value: String?, now: Date) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.allSatisfy({ $0.isASCII && $0.isNumber }), let seconds = Double(value), seconds.isFinite {
            return seconds
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["EEE, dd MMM yyyy HH:mm:ss 'GMT'", "EEEE, dd-MMM-yy HH:mm:ss 'GMT'", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return max(0, date.timeIntervalSince(now)) }
        }
        return nil
    }
}
