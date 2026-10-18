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
    static let repairWaiting = "Push setup is still finishing. Check again in a moment."
    static let repairPending = "Push setup is still incomplete. Try again later."
    static let repairTimeout = "Repair is still running. Check again in a moment."
    static let unreachable = "Can't reach the server"
    static let unauthorized = "Sign-in failed"
    static let rateLimited = "The server is limiting requests"
    static func controlFailure(topic: String) -> String { "Open the app to update notifications for \(topic)." }
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
    static func fetchFailureContent(_ content: UNNotificationContent, topic: String, baseUrl: String? = nil, event: String = "message") -> UNMutableNotificationContent {
        let safe = (content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        safe.title = topic
        safe.subtitle = ""
        safe.body = event == "message_clear" || event == "message_delete"
            ? DeliveryHealthCopy.controlFailure(topic: topic) : DeliveryHealthCopy.fetchFailure(topic: topic)
        if event == "message_clear" || event == "message_delete" {
            safe.sound = nil
            safe.interruptionLevel = .passive
        }
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
    var retryCondition: String? = nil
}

/// Recognized server extensions never shorten a reset to the stock one-hour cap.
/// Unknown/malformed conditions leave the 1.17 policy in charge.
enum RetryDirective: Equatable {
    case time(TimeInterval), stateChange, requestChange

    static func parse(condition: String?, retryAfter: String?, now: Date = Date()) -> RetryDirective? {
        switch condition?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "state-change": return .stateChange
        case "request-change": return .requestChange
        case "time":
            guard let value = retryAfter?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
                  value.allSatisfy({ $0.isASCII && $0.isNumber }), let seconds = Double(value), seconds.isFinite else { return nil }
            // Dispatch nanosecond deadlines cannot represent arbitrarily large intervals. Do not
            // retry such a refusal early; require an explicit new user intent instead.
            return seconds < Double(Int64.max) / 1_000_000_000 ? .time(seconds) : .requestChange
        default: return nil
        }
    }
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

    mutating func record(_ failure: PollFailure?, attempted: Bool = true) {
        self.failure = failure
        if attempted { consecutiveFailures = failure == nil ? 0 : consecutiveFailures + 1 }
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
            return min(seconds, 3600)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["EEE, dd MMM yyyy HH:mm:ss 'GMT'", "EEEE, dd-MMM-yy HH:mm:ss 'GMT'", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return min(3600, max(0, date.timeIntervalSince(now))) }
        }
        return nil
    }
}


/// One server brake shared by polls and clears. Only deadlines and the last manual probe persist.
/// Stock deadlines remain capped at one hour; recognized extension resets preserve their full delay.
/// Explicit probes of non-time refusals are at most once a minute.
final class ServerCooldown {
    static let shared = ServerCooldown(defaults: UserDefaults(suiteName: Store.appGroup) ?? .standard)
    private let lock = NSLock()
    private let defaults: UserDefaults?
    private let now: () -> Date
    private let key = "deliveryHealthServerCooldowns"
    private let probeKey = "deliveryHealthServerProbes"
    private var until: [String: Double]
    private var probes: [String: Double]
    private var failures: [String: Int] = [:]
    private let uptime: () -> TimeInterval
    private var extended: [String: Double]
    private var monotonic: [String: Double] = [:]
    private var changes: [String: String]
    private let extendedKey = "serverExtensionCooldowns118"
    private let changeKey = "serverExtensionChanges118"
    // No request survives a launch; only the deadlines and manual-probe pacing need persistence.
    enum Kind: String { case poll, clear, clearThrough, relay, discovery }
    struct Attempt { fileprivate let generation: UUID?; fileprivate let kind: Kind }
    private func scope(_ server: String, _ kind: Kind) -> String { server + "|118|" + kind.rawValue }
    private var generations: [String: UUID] = [:]

    init(defaults: UserDefaults?, now: @escaping () -> Date = Date.init,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.defaults = defaults
        self.now = now
        self.uptime = uptime
        let date = now().timeIntervalSince1970
        until = (defaults?.dictionary(forKey: key) as? [String: Double] ?? [:])
            .filter { $0.value.isFinite && $0.value > date }
            .mapValues { min($0, date + 3600) }
        probes = (defaults?.dictionary(forKey: probeKey) as? [String: Double] ?? [:])
            .filter { $0.value.isFinite && $0.value > date - 60 }
            .mapValues { min($0, date) }
        extended = (defaults?.dictionary(forKey: extendedKey) as? [String: Double] ?? [:])
            .filter { $0.value.isFinite && $0.value > date && $0.value - date < Double(Int64.max) / 1_000_000_000 }
        changes = (defaults?.dictionary(forKey: changeKey) as? [String: String] ?? [:])
            .filter { ["state-change", "request-change"].contains($0.value) }
        monotonic = extended.mapValues { uptime() + $0 - date }
        generations = until.merging(extended) { max($0, $1) }.mapValues { _ in UUID() }
        for key in changes.keys { generations[key.components(separatedBy: "|118|")[0]] = UUID() }
        defaults?.set(until, forKey: key)
        defaults?.set(probes, forKey: probeKey)
    }

    func deadline(for server: String, kind: Kind = .poll) -> Date {
        lock.lock(); defer { lock.unlock() }
        let key = normalizeBaseUrl(server)
        if changes[scope(key, kind)] != nil { return .distantFuture }
        let remaining = max(0, (monotonic[key] ?? 0) - uptime())
        return max(Date(timeIntervalSince1970: until[key] ?? 0), now().addingTimeInterval(remaining))
    }

    func claim(server: String, manual: Bool, kind: Kind = .poll) -> Bool {
        claimAttempt(server: server, manual: manual, kind: kind) != nil
    }

    func claimAttempt(server: String, manual: Bool, kind: Kind = .poll) -> Attempt? {
        lock.lock(); defer { lock.unlock() }
        let server = normalizeBaseUrl(server)
        let date = now().timeIntervalSince1970
        let extensionWait = (monotonic[server] ?? 0) > uptime()
        // Explicit user probes may test a changed state/request, paced as in 1.17. Automatic
        // polling/clearing never resumes on a short timer for a non-time condition.
        if extensionWait { return nil }
        if changes[scope(server, kind)] != nil || (until[server] ?? 0) > date {
            guard manual, date - (probes[server] ?? 0) >= 60 else { return nil }
            probes[server] = date
            defaults?.set(probes, forKey: probeKey)
        }
        return Attempt(generation: generations[server], kind: kind)
    }

    func limit(server: String, retryAfter: String?, condition: String? = nil, kind: Kind = .poll) {
        lock.lock(); defer { lock.unlock() }
        let server = normalizeBaseUrl(server)
        let date = now()
        generations[server] = UUID() // A 429 invalidates older probes even if its deadline is unchanged.
        if let directive = RetryDirective.parse(condition: condition, retryAfter: retryAfter, now: date) {
            switch directive {
            case .time(let seconds):
                changes.removeValue(forKey: scope(server, kind))
                let delay = max(1, seconds)
                monotonic[server] = max(monotonic[server] ?? 0, uptime() + delay)
                extended[server] = max(extended[server] ?? 0, date.timeIntervalSince1970 + delay)
            case .stateChange: changes[scope(server, kind)] = "state-change"
            case .requestChange: changes[scope(server, kind)] = "request-change"
            }
            defaults?.set(extended, forKey: extendedKey)
            defaults?.set(changes, forKey: changeKey)
            return
        }
        let active = (until[server] ?? 0) > date.timeIntervalSince1970
        // Concurrent failures in the same burst are one attempt, not successive retries.
        if !active { failures[server] = min((failures[server] ?? 0) + 1, 7) }
        let fallback = min(60 * pow(2, Double(max(0, (failures[server] ?? 1) - 1))), 3600)
        let delay = max(1, PollTiming.retryDelay(retryAfter, now: date) ?? fallback)
        until[server] = min(date.timeIntervalSince1970 + 3600,
            max(until[server] ?? 0, date.addingTimeInterval(delay).timeIntervalSince1970))
        until = until.filter { $0.value > date.timeIntervalSince1970 }
        defaults?.set(until, forKey: key)
    }

    /// A new explicit read intent may change an oversized batch. Scheduled retries never call
    /// this; unrelated GET polls remain useful while a clear requires a different request.
    func requestChanged(server: String, kind: Kind) {
        lock.lock(); defer { lock.unlock() }
        let key = scope(normalizeBaseUrl(server), kind)
        if changes[key] == "request-change" {
            changes.removeValue(forKey: key)
            defaults?.set(changes, forKey: changeKey)
        }
    }

    func succeeded(server: String, attempt: Attempt) {
        lock.lock(); defer { lock.unlock() }
        let server = normalizeBaseUrl(server)
        // Clear only the brake this fetch tested, never a newer concurrent 429 from a poll or clear.
        guard generations[server] == attempt.generation else { return }
        until.removeValue(forKey: server)
        extended.removeValue(forKey: server)
        monotonic.removeValue(forKey: server)
        changes.removeValue(forKey: scope(server, attempt.kind))
        defaults?.set(extended, forKey: extendedKey)
        defaults?.set(changes, forKey: changeKey)
        failures.removeValue(forKey: server)
        generations.removeValue(forKey: server)
        defaults?.set(until, forKey: key)
    }
}

/// Expiry always uses the latest safe presentation, including a successful fetch before attachments.
final class NotificationBestAttempt {
    private let lock = NSLock()
    private var current: UNMutableNotificationContent
    init(_ content: UNMutableNotificationContent) { current = content }
    var content: UNMutableNotificationContent {
        lock.lock(); defer { lock.unlock() }; return current
    }
    func replace(with content: UNMutableNotificationContent) {
        lock.lock(); defer { lock.unlock() }; current = content
    }
}

/// Wait up to five seconds for registration callbacks, then let reconciliation report its result.
enum RegistrationRepair {
    static func wait(isReady: @escaping () -> Bool,
                     schedule: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: $0) },
                     remaining: Int = 10, completion: @escaping () -> Void) {
        guard !isReady(), remaining > 0 else { completion(); return }
        schedule { wait(isReady: isReady, schedule: schedule, remaining: remaining - 1, completion: completion) }
    }
}

/// A successful push fetch/ingestion also repairs an earlier row error across the app/NSE boundary.
/// These timestamps contain no message content or credentials; Core Data needs no new field.
enum DeliveryReceipt {
    static let changed = Foundation.Notification.Name("DeliveryReceiptChanged")
    static let externalChanged = "net.ntfy.deliveryHealthReceiptChanged"
    static let key = "deliveryHealthPushReceipts"
    static func identity(baseUrl: String, topic: String) -> String { topicUrl(baseUrl: normalizeBaseUrl(baseUrl), topic: topic) }
    static func record(baseUrl: String, topic: String) {
        record(topicUrl: identity(baseUrl: baseUrl, topic: topic))
    }
    static func record(topicUrl: String) {
        let defaults = UserDefaults(suiteName: Store.appGroup) ?? .standard
        var receipts = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        let date = Date().timeIntervalSince1970
        receipts = receipts.filter { $0.value > date - 86400 }
        receipts[topicUrl] = date
        defaults.set(receipts, forKey: key)
        // Publish after the cross-process defaults write, independently of the earlier database save.
        defaults.synchronize()
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(externalChanged as CFString), nil, nil, true)
        NotificationCenter.default.post(name: changed, object: nil)
    }
}
