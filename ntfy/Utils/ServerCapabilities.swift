import Foundation

/// Only the explicitly versioned extensions are enabled. Invalid discovery retains stock behavior.
struct ServerCapabilities: Equatable {
    var clearThrough = false
    var relayCheck = false
    var relayWindowSeconds = 120
    static let unsupported = ServerCapabilities()

    static func decode(_ data: Data) -> ServerCapabilities {
        struct Document: Decodable {
            let version: Int
            let retry_after: Int?
            let relay_check: Int?
            let relay_window_seconds: Int?
            let clear_through: Bool?
            let clear_max_sequences: Int?
            let clear_max_rows: Int?
        }
        guard let doc = try? JSONDecoder().decode(Document.self, from: data), doc.version == 1 else { return .unsupported }
        return ServerCapabilities(clearThrough: doc.clear_through == true && doc.clear_max_sequences == 100 && doc.clear_max_rows == 1000,
            relayCheck: doc.relay_check == 1 && doc.relay_window_seconds == 120,
            relayWindowSeconds: 120)
    }
}

/// Extension discovery never follows redirects, including login pages. Credentials belong only to
/// the server named by the request. Diagnostic callers build their relay requests without them.
final class ServerExtensionTransport: NSObject, URLSessionTaskDelegate {
    static let shared = ServerExtensionTransport()
    func send(_ request: URLRequest, completion: @escaping (Data?, URLResponse?, Error?) -> Void) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        session.dataTask(with: request, completionHandler: completion).resume()
        session.finishTasksAndInvalidate()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

final class ServerCapabilitiesCache {
    static let shared = ServerCapabilitiesCache()
    typealias Transport = (URLRequest, @escaping (Data?, URLResponse?, Error?) -> Void) -> Void
    private struct Entry { let value: ServerCapabilities; let expires: TimeInterval }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var waiting: [String: [(ServerCapabilities) -> Void]] = [:]
    private var generations: [String: UUID] = [:]
    private let now: () -> TimeInterval
    private let transport: Transport
    private let api: ApiService
    private let cooldown: ServerCooldown
    private let allowInsecureLoopback: Bool

    init(api: ApiService = .shared, cooldown: ServerCooldown = .shared, allowInsecureLoopback: Bool = false, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         transport: @escaping Transport = { ServerExtensionTransport.shared.send($0, completion: $1) }) {
        self.api = api; self.cooldown = cooldown; self.allowInsecureLoopback = allowInsecureLoopback; self.now = now; self.transport = transport
    }

    func invalidate(baseUrl: String) {
        lock.lock(); defer { lock.unlock() }
        entries.removeValue(forKey: baseUrl)
        generations[baseUrl] = UUID()
    }

    func discover(baseUrl: String, user: BasicUser? = nil, completion: @escaping (ServerCapabilities) -> Void) {
        lock.lock()
        let instant = now()
        if let entry = entries[baseUrl], entry.expires > instant {
            lock.unlock(); completion(entry.value); return
        }
        if waiting[baseUrl] != nil {
            waiting[baseUrl]?.append(completion); lock.unlock(); return
        }
        waiting[baseUrl] = [completion]
        let generation = UUID()
        generations[baseUrl] = generation
        lock.unlock()
        guard let url = URL(string: "\(baseUrl)/v1/ntfyme/capabilities"),
              url.scheme?.lowercased() == "https" || (allowInsecureLoopback && url.scheme == "http" && ["127.0.0.1", "::1", "[::1]"].contains(url.host ?? "")),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              cooldown.claim(server: baseUrl, manual: false, kind: .discovery) else {
            finish(baseUrl, generation: generation, value: .unsupported); return
        }
        var request = api.newRequest(url: url, baseUrl: baseUrl, user: user)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        transport(request) { data, response, error in
            let http = response as? HTTPURLResponse
            if http?.statusCode == 429 {
                self.cooldown.limit(server: baseUrl, retryAfter: http?.value(forHTTPHeaderField: "Retry-After"),
                    condition: http?.value(forHTTPHeaderField: "Retry-After-Condition"), kind: .discovery)
            }
            let valid = error == nil && http?.statusCode == 200 && http?.url == url
                && http?.mimeType?.lowercased() == "application/json"
            let value = valid ? data.map(ServerCapabilities.decode) ?? .unsupported : .unsupported
            self.finish(baseUrl, generation: generation, value: value)
        }
    }

    private func finish(_ server: String, generation: UUID, value: ServerCapabilities) {
        lock.lock()
        let callbacks = waiting.removeValue(forKey: server) ?? []
        let valid = generations[server] == generation
        entries = entries.filter { $0.value.expires > now() }
        if entries.count >= 64, let oldest = entries.min(by: { $0.value.expires < $1.value.expires })?.key { entries.removeValue(forKey: oldest) }
        if valid { entries[server] = Entry(value: value, expires: now() + 300) }
        generations.removeValue(forKey: server)
        lock.unlock()
        callbacks.forEach { $0(valid ? value : .unsupported) }
    }
}
