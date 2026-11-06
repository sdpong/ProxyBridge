import Foundation

// The DNS policy is the layer that decides what happens to a name before it is
// allowed to reach a proxy server.
//
// Without it the DNS proxy forwards every query to the resolver macOS handed it
// and remembers what came back. That is enough to put a name on a destination,
// but it leaves the user with no say over which names may become proxy
// destinations, where the answer comes from, or whether the local resolver is
// allowed to see the query at all.
//
// The policy deliberately carries no NetworkExtension types, so it can be
// compiled and tested on its own, the same way LiveFlowRegistry is.

// how a name is resolved
enum DNSResolutionMode: String, CaseIterable {
    // the operating system's resolver answers
    case system
    // a resolver on this machine answers and the proxy server is given the address
    case local
    // the proxy server resolves the name itself, the local answer is only a bootstrap
    case remote
}

// what the transparent proxy puts in the request it sends to the proxy server
enum DNSAddressing {
    // send the address, the proxy server must not resolve names
    case address
    // send the name, the proxy server resolves it
    case hostname
}

// what the DNS proxy does with one query
enum DNSDecision {
    // the name is excluded: answer it with the system resolver and never let the
    // name reach a proxy server
    case excluded
    // answer it with this resolver, nil means the one the system handed us
    case forward(resolver: String?)
    // answer it through the proxy server's tunnel, the local resolver never sees it
    case forwardThroughProxy
}

struct DNSPolicy {
    var mode: DNSResolutionMode = .system
    // names that must never become a proxy destination. "example.com" matches that
    // name only, "*.example.com" matches every name below it, "*" matches everything
    var excludedDomains: [String] = []
    // resolvers to ask, in order. empty means "use the system resolver"
    var upstreamResolvers: [String] = []
    // when there is no configured resolver, use the one the system handed us
    var autoDetectUpstream: Bool = true
    // send the query through the proxy server's tunnel, so the local resolver
    // never sees which names are looked up
    var leakProtection: Bool = false

    // the resolver to ask, nil means the one the system handed us
    var preferredResolver: String? {
        upstreamResolvers.first
    }

    // does this name match the exclusion list?
    func isExcluded(_ domain: String) -> Bool {
        let name = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !name.isEmpty else { return false }
        return excludedDomains.contains { DNSPolicy.matches(pattern: $0, name: name) }
    }

    // what to do with a query for this name
    func decision(for domain: String) -> DNSDecision {
        // an excluded name is answered by the system resolver and is not recorded,
        // so no proxy server ever learns it
        if isExcluded(domain) { return .excluded }
        if leakProtection { return .forwardThroughProxy }
        switch mode {
        case .system:
            // the system's resolver answers
            return .forward(resolver: nil)
        case .local, .remote:
            // a configured resolver answers, the system resolver is the fallback
            return .forward(resolver: preferredResolver)
        }
    }

    // what the transparent proxy should hand to the proxy server for this name.
    // nil means the per-rule setting decides, which is what the system mode does.
    func addressing(for domain: String) -> DNSAddressing? {
        // an excluded name never becomes a proxy destination
        if isExcluded(domain) { return .address }
        // leak protection wins over every other setting: the proxy server resolves
        // the name, so the answer the local resolver gave can never be the address
        // the proxy connects to
        if leakProtection { return .hostname }
        switch mode {
        case .system: return nil
        case .local: return .address
        case .remote: return .hostname
        }
    }

    // splits "1.1.1.1" or "1.1.1.1:5353" into a host and a port. the default
    // port is 53, which is what a resolver listens on unless it says otherwise.
    static func normalizeResolver(_ raw: String) -> (host: String, port: UInt16)? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // an ipv6 literal has colons of its own, so only split on the last one
        if let colon = trimmed.lastIndex(of: ":"), trimmed.filter({ $0 == ":" }).count == 1 {
            let host = String(trimmed[trimmed.startIndex..<colon])
            let portText = String(trimmed[trimmed.index(after: colon)...])
            guard let port = UInt16(portText), port > 0 else { return nil }
            return (host, port)
        }
        return (trimmed, 53)
    }

    // matches one exclusion pattern against a name. both are lower case.
    static func matches(pattern: String, name: String) -> Bool {
        let pattern = pattern.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !pattern.isEmpty else { return false }
        if pattern == "*" { return true }
        if pattern.hasPrefix("*.") {
            // "*.example.com" matches every name below example.com, not example.com itself
            let suffix = String(pattern.dropFirst(2))
            guard !suffix.isEmpty else { return false }
            return name.hasSuffix("." + suffix)
        }
        return pattern == name
    }

    // the wire form, so the app can hand the policy to the extension
    func toDictionary() -> [String: Any] {
        return [
            "mode": mode.rawValue,
            "excludedDomains": excludedDomains,
            "upstreamResolvers": upstreamResolvers,
            "autoDetectUpstream": autoDetectUpstream,
            "leakProtection": leakProtection
        ]
    }

    // reads the wire form back. unknown or missing fields fall back to the default
    // so an older app talking to a newer extension still works
    static func fromDictionary(_ dict: [String: Any]) -> DNSPolicy {
        var policy = DNSPolicy()
        if let raw = dict["mode"] as? String, let parsed = DNSResolutionMode(rawValue: raw) {
            policy.mode = parsed
        }
        if let list = dict["excludedDomains"] as? [String] {
            policy.excludedDomains = list
        }
        if let list = dict["upstreamResolvers"] as? [String] {
            policy.upstreamResolvers = list
        }
        if let flag = dict["autoDetectUpstream"] as? Bool {
            policy.autoDetectUpstream = flag
        }
        if let flag = dict["leakProtection"] as? Bool {
            policy.leakProtection = flag
        }
        return policy
    }
}

// The extension holds one policy. The DNS proxy provider cannot be sent a
// provider message, so the app hands the policy to the transparent proxy
// provider, which publishes it in the shared container; the DNS proxy provider
// reads it back from there.
final class DNSPolicyStore {
    static let shared = DNSPolicyStore()

    private let lock = NSLock()
    private var current = DNSPolicy()
    private var lastRead: TimeInterval = 0

    // re-read the shared file at most this often, so a burst of dns queries does
    // not turn into a burst of file reads
    private static let refreshInterval: TimeInterval = 2

    private init() {}

    var policy: DNSPolicy {
        refreshIfStale()
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    // takes the policy for this process
    func set(_ policy: DNSPolicy) {
        lock.lock()
        current = policy
        lastRead = ProcessInfo.processInfo.systemUptime
        lock.unlock()
    }

    // takes the policy and publishes it where the DNS proxy provider can find
    // it. the two providers are the same extension binary but not necessarily
    // the same process, so the shared container is what both can rely on.
    func publish(_ policy: DNSPolicy) {
        set(policy)
        guard let url = DNSPolicyStore.sharedURL,
              let data = try? JSONSerialization.data(withJSONObject: policy.toDictionary()) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func refreshIfStale() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let age = now - lastRead
        lock.unlock()
        guard age > DNSPolicyStore.refreshInterval else { return }
        if let loaded = DNSPolicyStore.readShared() {
            set(loaded)
        } else {
            // nothing to read: remember the attempt, so the file system is not
            // asked on every query
            lock.lock()
            lastRead = now
            lock.unlock()
        }
    }

    static var sharedURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.interceptsuite.ProxyBridge")?
            .appendingPathComponent("dns_policy.json")
    }

    static func readShared() -> DNSPolicy? {
        guard let url = sharedURL else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return DNSPolicy.fromDictionary(dict)
    }
}
