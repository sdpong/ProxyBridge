import Foundation

// The rule engine of the traffic that has no program.
//
// The traffic of another terminal comes in as a connection and nothing else:
// there is no process behind it that could be named. A rule that names a
// program is therefore not about that traffic, and the engine skips it.
//
// The engine is written on its own, with nothing of the app in it, because
// the helper of the gateway mode has to read the rules the same way the app
// does. A rule that the app and the helper read differently means two
// things, and the person who wrote it has no way of finding out which one
// is used.
//
// Four things are decided here, and they are the same in every mode:
//
//   - a rule that names a program is skipped;
//   - a rule is about one protocol or the other, and a rule about TCP is
//     not about a UDP flow;
//   - a rule that names a chain says so, and the chain is either walked
//     through or the traffic goes straight out with a reason;
//   - a rule that names a host is matched against the name of the host when
//     there is one, and against its address when there is not.

// MARK: - the protocol of a flow

// The two protocols a flow can have.
enum FlowProtocol: String, Equatable {
    case tcp = "TCP"
    case udp = "UDP"
}

// MARK: - where a flow wants to go

// What a flow wants to reach.
//
// The name of the host and its address are two different things: a client
// of the proxy server may say a name, and the gateway mode only knows the
// address until the dns of the client is hijacked. A rule that names a host
// is about the name when there is one.
struct FlowTarget: Equatable {
    // the name of the host, when it is known
    let name: String?
    // the address of the host, when it is known
    let address: String?
    let port: Int
    let transport: FlowProtocol

    init(name: String? = nil, address: String? = nil, port: Int, transport: FlowProtocol = .tcp) {
        self.name = name
        self.address = address
        self.port = port
        self.transport = transport
    }

    // a host of a kind that is not known: an address if it looks like one,
    // a name if it does not. An http client says the host it wants to reach
    // without saying what kind of host it is.
    init(host: String, port: Int, transport: FlowProtocol = .tcp) {
        if ProxyRuleEngine.looksLikeAddress(host) {
            self.init(address: host, port: port, transport: transport)
        } else {
            self.init(name: host, port: port, transport: transport)
        }
    }

    // what a rule pattern is compared with: the name first, the address
    // after it
    var hostCandidates: [String] {
        var out: [String] = []
        if let name, !name.isEmpty { out.append(name) }
        if let address, !address.isEmpty, out.first != address { out.append(address) }
        return out
    }

    // the host that is asked of the proxy: the name when there is one
    var proxyHost: String { hostCandidates.first ?? "" }

    var text: String { "\(proxyHost):\(port)" }

    // "host:port", as an http CONNECT line says it
    static func parse(hostPort: String) -> FlowTarget? {
        let text = hostPort.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        // an ipv6 address is written in brackets
        if text.hasPrefix("[") {
            guard let end = text.firstIndex(of: "]") else { return nil }
            // the brackets are not part of the host
            let host = String(text[text.index(after: text.startIndex)..<end])
            let rest = String(text[text.index(after: end)...])
            let port = rest.hasPrefix(":") ? Int(rest.dropFirst()) : nil
            guard let port, port > 0, port < 65536 else { return nil }
            return FlowTarget(host: host, port: port)
        }
        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let port = Int(parts[1]), port > 0, port < 65536 else { return nil }
        return FlowTarget(host: String(parts[0]), port: port)
    }

    // an absolute url, as an http proxy receives it
    static func parse(url: String) -> FlowTarget? {
        var rest = url
        var scheme = "http"
        if let range = rest.range(of: "://") {
            scheme = String(rest[rest.startIndex..<range.lowerBound]).lowercased()
            rest = String(rest[range.upperBound...])
        }
        // the part before the slash is the host
        let authority: String
        if let slash = rest.firstIndex(of: "/") {
            authority = String(rest[rest.startIndex..<slash])
        } else {
            authority = rest
        }
        // an url may leave the port out: then the scheme says which one it is
        if let target = parse(hostPort: authority) {
            return target
        }
        let host = authority.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard !host.isEmpty else { return nil }
        let port = scheme == "https" ? 443 : 80
        return FlowTarget(host: host, port: port)
    }
}

// MARK: - one proxy

// One proxy of the app, as the server needs it.
struct ProxyEndpoint: Equatable {
    let id: String
    let name: String
    let type: String
    let host: String
    let port: Int
    let username: String?
    let password: String?

    var label: String { "\(type.uppercased()) \(host):\(port)" }
}

// MARK: - one rule

// One rule of the app, as the engine needs it.
struct EngineRule: Equatable {
    let action: String
    let hosts: [String]
    let ports: [String]
    // the rule names a program, so it is about the traffic of this machine
    // and not about the traffic of a client
    let hasProgram: Bool
    let enabled: Bool
    // "TCP", "UDP" or "BOTH"
    let protocolMode: String

    init(action: String,
         hosts: [String] = [],
         ports: [String] = [],
         hasProgram: Bool = false,
         enabled: Bool = true,
         protocolMode: String = "BOTH") {
        self.action = action
        self.hosts = hosts
        self.ports = ports
        self.hasProgram = hasProgram
        self.enabled = enabled
        self.protocolMode = protocolMode
    }

    // does the rule speak about this protocol
    func speaksAbout(_ transport: FlowProtocol) -> Bool {
        let mode = protocolMode.trimmingCharacters(in: .whitespaces).uppercased()
        if mode == FlowProtocol.tcp.rawValue { return transport == .tcp }
        if mode == FlowProtocol.udp.rawValue { return transport == .udp }
        return true
    }

    // does the rule speak about this host
    func speaksAbout(host: String) -> Bool {
        hosts.isEmpty || hosts.contains { EngineRule.host($0, matches: host) }
    }

    // does the rule speak about this port
    func speaksAbout(port: Int) -> Bool {
        ports.isEmpty || ports.contains { EngineRule.port($0, matches: port) }
    }

    // does the rule speak about this flow at all
    func speaksAbout(_ target: FlowTarget) -> Bool {
        guard enabled else { return false }
        guard speaksAbout(target.transport) else { return false }
        guard speaksAbout(port: target.port) else { return false }
        guard !hosts.isEmpty else { return true }
        let candidates = target.hostCandidates
        guard !candidates.isEmpty else { return false }
        return candidates.contains { speaksAbout(host: $0) }
    }

    // a host pattern: "*.example.com", "example.com", "1.2.3.*"
    static func host(_ pattern: String, matches host: String) -> Bool {
        let pattern = pattern.trimmingCharacters(in: .whitespaces).lowercased()
        let host = host.lowercased()
        if pattern.isEmpty { return false }
        if !pattern.contains("*") { return pattern == host }
        // the pieces between the stars have to be there, in that order
        var rest = host
        var pieces = pattern.split(separator: "*", omittingEmptySubsequences: true).map(String.init)
        // a pattern that starts with a star may match anything before the
        // first piece
        if pattern.hasPrefix("*"), let first = pieces.first {
            guard let range = rest.range(of: first) else { return false }
            rest = String(rest[range.upperBound...])
            pieces.removeFirst()
        }
        for piece in pieces {
            guard let range = rest.range(of: piece) else { return false }
            rest = String(rest[range.upperBound...])
        }
        return true
    }

    // a port pattern: "80", "8000-9000", "*"
    static func port(_ pattern: String, matches port: Int) -> Bool {
        let pattern = pattern.trimmingCharacters(in: .whitespaces)
        if pattern.isEmpty || pattern == "*" { return true }
        if let dash = pattern.firstIndex(of: "-") {
            let low = Int(pattern[pattern.startIndex..<dash]) ?? -1
            let high = Int(pattern[pattern.index(after: dash)...]) ?? -1
            return port >= low && port <= high
        }
        return Int(pattern) == port
    }
}

// MARK: - where the traffic goes

// Where the traffic of a flow goes.
enum RuleUpstream: Equatable {
    case direct
    case blocked
    case proxy(ProxyEndpoint)
    // the proxies of a chain, in the order they are walked through
    case chain([ProxyEndpoint])
}

// What the engine decided, and why.
struct RuleDecision: Equatable {
    let upstream: RuleUpstream
    // the action of the rule that decided
    let action: String?
    // why the traffic did not go where the rule said
    let note: String?

    init(upstream: RuleUpstream, action: String? = nil, note: String? = nil) {
        self.upstream = upstream
        self.action = action
        self.note = note
    }
}

// MARK: - the engine

// The rules, read the one way that every mode reads them.
enum ProxyRuleEngine {

    // the prefix a rule uses to point at a chain. The app writes chains
    // with the same prefix (ProxyChain.actionPrefix).
    static let chainActionPrefix = "chain:"

    // the id of the chain a rule points at, when it points at one
    static func chainId(from action: String) -> String? {
        guard action.hasPrefix(chainActionPrefix) else { return nil }
        let id = String(action.dropFirst(chainActionPrefix.count))
        return id.isEmpty ? nil : id
    }

    // The upstream of a flow, by the rules.
    //
    // The rules are read in the order they are in, and the first one that
    // speaks about the flow decides. A rule that is not about the flow is
    // not about it, and the next one gets its chance.
    static func decide(rules: [EngineRule],
                       target: FlowTarget,
                       proxies: [ProxyEndpoint],
                       chains: [String: [String]]) -> RuleDecision {
        for rule in rules {
            guard rule.enabled else { continue }
            // a rule that names a program is about this machine, not about
            // a client
            if rule.hasProgram { continue }
            guard rule.speaksAbout(target) else { continue }

            let action = rule.action
            if action == "DIRECT" {
                return RuleDecision(upstream: .direct, action: action)
            }
            if action == "BLOCK" {
                return RuleDecision(upstream: .blocked, action: action)
            }
            if let chainId = chainId(from: action) {
                return decideChain(chainId: chainId, action: action, target: target,
                                   proxies: proxies, chains: chains)
            }
            if let endpoint = proxies.first(where: { $0.id == action }) {
                return RuleDecision(upstream: .proxy(endpoint), action: action)
            }
            // the rule points at a proxy that is not in the list any more.
            // the traffic still goes out, but it says so instead of going
            // out quietly.
            return RuleDecision(upstream: .direct, action: action,
                                note: "The proxy \(action) is not in the list, the traffic goes straight out")
        }
        return RuleDecision(upstream: .direct)
    }

    // A rule that points at a chain. The chain is walked through when it
    // can be, and the traffic goes straight out with a reason when it can
    // not.
    private static func decideChain(chainId: String,
                                     action: String,
                                     target: FlowTarget,
                                     proxies: [ProxyEndpoint],
                                     chains: [String: [String]]) -> RuleDecision {
        let ids = chains[chainId] ?? []
        if ids.isEmpty {
            return RuleDecision(upstream: .direct, action: action,
                                note: "The chain \(action) has no proxy in it, the traffic goes straight out")
        }
        // udp cannot walk a chain: only a socks5 proxy can carry it, and a
        // chain of several proxies cannot be asked to carry a datagram
        if target.transport == .udp {
            return RuleDecision(upstream: .direct, action: action,
                                note: "UDP cannot walk a chain, the traffic goes straight out")
        }
        var hops: [ProxyEndpoint] = []
        for id in ids {
            guard let endpoint = proxies.first(where: { $0.id == id }) else {
                return RuleDecision(upstream: .direct, action: action,
                                    note: "A proxy of the chain \(action) is not in the list, the traffic goes straight out")
            }
            hops.append(endpoint)
        }
        let problems = chainProblems(hops)
        if !problems.isEmpty {
            return RuleDecision(upstream: .direct, action: action,
                                note: "The chain \(action) cannot work: \(problems.joined(separator: "; ")). The traffic goes straight out.")
        }
        return RuleDecision(upstream: .chain(hops), action: action)
    }

    // What is wrong with a chain of these proxies.
    //
    // The types are checked because an http proxy cannot be a hop in the
    // middle: it opens a tunnel with a CONNECT, and the reply can leave
    // bytes behind that the next handshake would read as its own answer.
    // The extension checks the same things (ChainPlan in the extension).
    static func chainProblems(_ hops: [ProxyEndpoint]) -> [String] {
        var out: [String] = []
        if hops.isEmpty {
            out.append("the chain has no proxy in it")
            return out
        }
        for i in hops.indices {
            let type = hops[i].type.lowercased()
            if type.isEmpty {
                out.append("proxy \(i + 1) of the chain does not exist")
                continue
            }
            if type != "socks5" && type != "socks4" && type != "http" {
                out.append("proxy \(i + 1) of the chain has the type '\(type)', it must be socks5, socks4 or http")
                continue
            }
            // only the last hop may be an http proxy
            if type == "http" && i != hops.count - 1 {
                out.append("proxy \(i + 1) of the chain is an http proxy, only the last proxy of a chain may be one")
            }
        }
        for i in 1..<hops.count where hops[i].id == hops[i - 1].id {
            out.append("the same proxy is used twice in a row")
            break
        }
        return out
    }

    // whether a text is an address and not a name
    static func looksLikeAddress(_ text: String) -> Bool {
        if text.isEmpty { return false }
        if text.contains(":") { return true }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count != 4 { return false }
        for part in parts {
            guard let number = Int(part), (0...255).contains(number) else { return false }
        }
        return true
    }
}
