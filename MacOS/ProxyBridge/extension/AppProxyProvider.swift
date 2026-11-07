import NetworkExtension
import Foundation

enum RuleProtocol: String, Codable {
    case tcp = "TCP"
    case udp = "UDP"
    case both = "BOTH"
}

struct ProxyRule: Codable {
    var ruleId: UInt32
    let processNames: String
    let targetHosts: String
    let targetPorts: String
    let ruleProtocol: RuleProtocol
    let action: String  // "DIRECT", "BLOCK", or a proxy config UUID
    var enabled: Bool

    enum CodingKeys: String, CodingKey {
        case ruleId
        case processNames
        case targetHosts
        case targetPorts
        case ruleProtocol
        case action = "ruleAction"
        case enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.ruleId = try container.decodeIfPresent(UInt32.self, forKey: .ruleId) ?? 0
        self.processNames = try container.decode(String.self, forKey: .processNames)
        self.targetHosts = try container.decode(String.self, forKey: .targetHosts)
        self.targetPorts = try container.decode(String.self, forKey: .targetPorts)
        self.ruleProtocol = try container.decode(RuleProtocol.self, forKey: .ruleProtocol)
        self.action = try container.decode(String.self, forKey: .action)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    init(ruleId: UInt32, processNames: String, targetHosts: String, targetPorts: String, ruleProtocol: RuleProtocol, action: String, enabled: Bool) {
        self.ruleId = ruleId
        self.processNames = processNames
        self.targetHosts = targetHosts
        self.targetPorts = targetPorts
        self.ruleProtocol = ruleProtocol
        self.action = action
        self.enabled = enabled
    }
    
    func matchesProcess(bundleId: String, processName: String?) -> Bool {
        if Self.matchProcessList(processNames, processPath: bundleId) {
            return true
        }
        
        if let procName = processName {
            if Self.matchProcessList(processNames, processPath: procName) {
                return true
            }
        }
        
        return false
    }
    
    func matchesIP(_ ipString: String) -> Bool {
        return Self.matchIPList(targetHosts, ipString: ipString)
    }

    // matches targetHosts against the destination ip and any domains that
    // resolved to it (from the dns proxy). a pattern can be an ip/range or a
    // domain like *.github.com
    func matchesHost(ip: String, domains: [String]) -> Bool {
        if targetHosts.isEmpty || targetHosts == "*" { return true }
        for raw in targetHosts.components(separatedBy: ";") {
            let pattern = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if pattern.isEmpty { continue }
            if Self.matchIPPattern(pattern, ipString: ip) { return true }

            let lowered = pattern.lowercased()
            // *.example.com also covers the apex example.com, which is what users expect
            let apex = lowered.hasPrefix("*.") ? String(lowered.dropFirst(2)) : nil
            for domain in domains {
                if Self.globMatch(lowered, domain) { return true }
                if let apex = apex, domain == apex { return true }
            }
        }
        return false
    }


    func matchesPort(_ port: UInt16) -> Bool {
        return Self.matchPortList(targetPorts, port: port)
    }
    
    private static func matchProcessList(_ processList: String, processPath: String) -> Bool {
        if processList.isEmpty || processList == "*" {
            return true
        }
        
        let filename = (processPath as NSString).lastPathComponent
        let patterns = processList.components(separatedBy: CharacterSet(charactersIn: ",;"))
        
        for pattern in patterns {
            let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            if matchProcessPattern(trimmed, processPath: processPath, filename: filename) {
                return true
            }
        }
        return false
    }
    
    private static func matchProcessPattern(_ pattern: String, processPath: String, filename: String) -> Bool {
        if pattern.isEmpty || pattern == "*" {
            return true
        }

        let isFullPathPattern = pattern.contains("/") || pattern.contains("\\")
        let matchTarget = isFullPathPattern ? processPath : filename
        return globMatch(pattern.lowercased(), matchTarget.lowercased())
    }

    // wildcard match supporting any number of "*", e.g. *chrome*, com.*.browser, curl*
    private static func globMatch(_ pattern: String, _ text: String) -> Bool {
        return globMatch(Array(pattern), Array(text))
    }

    fileprivate static func globMatch(_ p: [Character], _ t: [Character]) -> Bool {
        var pi = 0, ti = 0, star = -1, mark = 0
        while ti < t.count {
            if pi < p.count, p[pi] == t[ti] {
                pi += 1; ti += 1
            } else if pi < p.count, p[pi] == "*" {
                star = pi; mark = ti; pi += 1
            } else if star != -1 {
                pi = star + 1; mark += 1; ti = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
    
    private static func matchIPList(_ ipList: String, ipString: String) -> Bool {
        if ipList.isEmpty || ipList == "*" {
            return true
        }
        
        let patterns = ipList.components(separatedBy: ";")
        for pattern in patterns {
            let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            if matchIPPattern(trimmed, ipString: ipString) {
                return true
            }
        }
        return false
    }
    
    // raw bytes of a v4 (4) or v6 (16) address, nil if not an ip literal
    private static func ipToBytes(_ ipString: String) -> [UInt8]? {
        if let v4 = IPv4Address(ipString) { return Array(v4.rawValue) }
        if let v6 = IPv6Address(ipString) { return Array(v6.rawValue) }
        return nil
    }

    private static func compareBytes(_ a: [UInt8], _ b: [UInt8]) -> Int {
        for i in 0..<min(a.count, b.count) where a[i] != b[i] {
            return a[i] < b[i] ? -1 : 1
        }
        return 0
    }

    // full 8 hextet form of a v6 address, e.g. ["2001","db8","0",...]
    private static func expandIPv6(_ ipString: String) -> [String]? {
        guard let v6 = IPv6Address(ipString) else { return nil }
        let bytes = Array(v6.rawValue)
        var groups: [String] = []
        for i in stride(from: 0, to: 16, by: 2) {
            let value = (UInt16(bytes[i]) << 8) | UInt16(bytes[i + 1])
            groups.append(String(format: "%x", value))
        }
        return groups
    }

    fileprivate static func matchIPPattern(_ pattern: String, ipString: String) -> Bool {
        if pattern.isEmpty || pattern == "*" {
            return true
        }

        // range, works for v4 and v6, e.g. 10.0.0.1-10.0.0.254 or fe80::1-fe80::ff
        if pattern.contains("-") {
            let parts = pattern.components(separatedBy: "-")
            guard parts.count == 2,
                  let lo = ipToBytes(parts[0].trimmingCharacters(in: .whitespaces)),
                  let hi = ipToBytes(parts[1].trimmingCharacters(in: .whitespaces)),
                  let target = ipToBytes(ipString),
                  lo.count == hi.count, target.count == lo.count else {
                return false
            }
            return compareBytes(target, lo) >= 0 && compareBytes(target, hi) <= 0
        }

        // v6 pattern (contains a colon)
        if pattern.contains(":") {
            return matchIPv6Pattern(pattern, ipString: ipString)
        }

        // v4 wildcard, e.g. 192.168.1.*
        let patternOctets = pattern.components(separatedBy: ".")
        let ipOctets = ipString.components(separatedBy: ".")
        if patternOctets.count != 4 || ipOctets.count != 4 {
            return false
        }
        for i in 0..<4 {
            if patternOctets[i] == "*" { continue }
            if patternOctets[i] != ipOctets[i] { return false }
        }
        return true
    }

    private static func matchIPv6Pattern(_ pattern: String, ipString: String) -> Bool {
        // prefix wildcard on leading hextets, e.g. 2001:db8:* (no :: compression)
        if pattern.hasSuffix("*") {
            guard let target = expandIPv6(ipString) else { return false }
            var groups = pattern.lowercased().dropLast()
                .split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            if groups.last == "" { groups.removeLast() }
            for (i, g) in groups.enumerated() {
                guard i < 8, !g.isEmpty, let value = UInt16(g, radix: 16) else { return false }
                if String(format: "%x", value) != target[i] { return false }
            }
            return true
        }

        // exact match, compared on normalized bytes so ::1 == 0:0:...:1
        guard let p = ipToBytes(pattern), let t = ipToBytes(ipString) else { return false }
        return p == t
    }
    
    private static func matchPortList(_ portList: String, port: UInt16) -> Bool {
        if portList.isEmpty || portList == "*" {
            return true
        }
        
        let patterns = portList.components(separatedBy: CharacterSet(charactersIn: ",;"))
        for pattern in patterns {
            let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            if matchPortPattern(trimmed, port: port) {
                return true
            }
        }
        return false
    }
    
    private static func matchPortPattern(_ pattern: String, port: UInt16) -> Bool {
        if pattern.isEmpty || pattern == "*" {
            return true
        }
        
        if let dashIndex = pattern.firstIndex(of: "-") {
            let startStr = String(pattern[..<dashIndex])
            let endStr = String(pattern[pattern.index(after: dashIndex)...])
            
            if let start = UInt16(startStr), let end = UInt16(endStr) {
                return port >= start && port <= end
            }
            return false
        }
        
        if let patternPort = UInt16(pattern) {
            return port == patternPort
        }
        return false
    }
}

// Pre-parsed form of a rule. Rules are matched on every new flow, so the string
// splitting, lowercasing and number parsing happens once when the rule is added
// instead of once per rule per connection.
extension ProxyRule {
    // lowercased forms of the flow's process, built once per flow
    struct FlowProcess {
        let candidates: [(path: [Character], file: [Character])]

        init(bundleId: String, processName: String?) {
            var list = [bundleId]
            if let processName = processName { list.append(processName) }
            candidates = list.map {
                (Array($0.lowercased()), Array((($0 as NSString).lastPathComponent).lowercased()))
            }
        }
    }

    struct Matcher {
        let processAll: Bool
        let processPatterns: [(chars: [Character], fullPath: Bool)]
        let hostAll: Bool
        let hostPatterns: [(raw: String, glob: [Character], apex: String?)]
        let portAll: Bool
        let portRanges: [ClosedRange<UInt16>]

        init(_ rule: ProxyRule) {
            func isAll(_ s: String) -> Bool { s.isEmpty || s == "*" }

            // empty segments are skipped, "Safari;" used to match every process
            // because the empty pattern after the ; counted as a wildcard
            var all = isAll(rule.processNames)
            var procs: [(chars: [Character], fullPath: Bool)] = []
            if !all {
                for raw in rule.processNames.components(separatedBy: CharacterSet(charactersIn: ",;")) {
                    let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if t.isEmpty { continue }
                    if t == "*" { all = true; break }
                    procs.append((Array(t.lowercased()), t.contains("/") || t.contains("\\")))
                }
            }
            processAll = all
            processPatterns = procs

            var hostsAll = isAll(rule.targetHosts)
            var hosts: [(raw: String, glob: [Character], apex: String?)] = []
            if !hostsAll {
                for raw in rule.targetHosts.components(separatedBy: ";") {
                    let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if t.isEmpty { continue }
                    if t == "*" { hostsAll = true; break }
                    let lowered = t.lowercased()
                    let apex = lowered.hasPrefix("*.") ? String(lowered.dropFirst(2)) : nil
                    hosts.append((t, Array(lowered), apex))
                }
            }
            hostAll = hostsAll
            hostPatterns = hosts

            var portsAll = isAll(rule.targetPorts)
            var ranges: [ClosedRange<UInt16>] = []
            if !portsAll {
                for raw in rule.targetPorts.components(separatedBy: CharacterSet(charactersIn: ",;")) {
                    let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if t.isEmpty { continue }
                    if t == "*" { portsAll = true; break }
                    if let dash = t.firstIndex(of: "-") {
                        if let lo = UInt16(t[..<dash]), let hi = UInt16(t[t.index(after: dash)...]), lo <= hi {
                            ranges.append(lo...hi)
                        }
                    } else if let p = UInt16(t) {
                        ranges.append(p...p)
                    }
                }
            }
            portAll = portsAll
            portRanges = ranges
        }

        var hasHostFilter: Bool { !hostAll }
        var hasPortFilter: Bool { !portAll }

        func matchesProcess(_ flow: FlowProcess) -> Bool {
            if processAll { return true }
            for cand in flow.candidates {
                for p in processPatterns {
                    if ProxyRule.globMatch(p.chars, p.fullPath ? cand.path : cand.file) { return true }
                }
            }
            return false
        }

        func matchesHost(ip: String, domains: [(name: String, chars: [Character])]) -> Bool {
            if hostAll { return true }
            for p in hostPatterns {
                if ProxyRule.matchIPPattern(p.raw, ipString: ip) { return true }
                for d in domains {
                    if ProxyRule.globMatch(p.glob, d.chars) { return true }
                    if let apex = p.apex, d.name == apex { return true }
                }
            }
            return false
        }

        func matchesPort(_ port: UInt16) -> Bool {
            if portAll { return true }
            for r in portRanges where r.contains(port) { return true }
            return false
        }
    }
}

class AppProxyProvider: NETransparentProxyProvider {
    
    // The version of the message protocol between the app and the extension.
    // The app checks it when the tunnel comes up: an extension that answers with
    // another number is an older build, and its rules and proxies would be
    // ignored in silence. The app and the extension must agree on this number.
    static let protocolAPI = 2
    
    // one log entry, kept as an enum so we don't allocate a dictionary per line,
    // the dict is only built when the gui drains a batch
    private enum LogEntry {
        case connection(proto: String, process: String, destination: String, port: String, proxy: String)
        case activity(timestamp: String, level: String, message: String)

        func toDict() -> [String: String] {
            switch self {
            case let .connection(proto, process, destination, port, proxy):
                return ["type": "connection", "protocol": proto, "process": process,
                        "destination": destination, "port": port, "proxy": proxy]
            case let .activity(timestamp, level, message):
                return ["type": "activity", "timestamp": timestamp, "level": level, "message": message]
            }
        }
    }

    // circular buffer for logs, avoids shifting the whole array on every pop
    private static let logCapacity = 500
    private var logBuffer = [LogEntry?](repeating: nil, count: AppProxyProvider.logCapacity)
    private var logHead = 0
    private var logTail = 0
    private var logCount = 0
    private let logQueueLock = NSLock()
    private let dateFormatter: ISO8601DateFormatter = ISO8601DateFormatter()
    
    // cache by pid + pid version so we don't call proc_pidpath on every
    // connection. the version changes when a pid is reused, so a new process
    // never inherits the previous owner's name
    private var pidCache: [UInt64: String] = [:]
    private let pidCacheLock = NSLock()
    private static let pidCacheMaxSize = 256
    
    private func getProcessName(from metaData: NEFlowMetaData) -> String? {
        guard let auditTokenData = metaData.sourceAppAuditToken else {
            return nil
        }
        guard auditTokenData.count == MemoryLayout<audit_token_t>.size else {
            return nil
        }
        
        let (pid, pidVersion) = auditTokenData.withUnsafeBytes { ptr -> (pid_t, UInt32) in
            guard let baseAddress = ptr.baseAddress else { return (0, 0) }
            let token = baseAddress.assumingMemoryBound(to: UInt32.self)
            return (pid_t(token[5]), token[7])
        }
        
        guard pid > 0 else { return nil }
        let key = (UInt64(UInt32(pid)) << 32) | UInt64(pidVersion)
        
        pidCacheLock.lock()
        if let cached = pidCache[key] {
            pidCacheLock.unlock()
            return cached
        }
        pidCacheLock.unlock()

        var pathBuffer = [Int8](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &pathBuffer, UInt32(MAXPATHLEN)) > 0 else {
            return nil
        }
        
        let fullPath = String(cString: pathBuffer)
        let processName = (fullPath as NSString).lastPathComponent
        
        // store in cache, evict everything if full - processes rarely hit this
        pidCacheLock.lock()
        if pidCache.count >= AppProxyProvider.pidCacheMaxSize {
            pidCache.removeAll(keepingCapacity: true)
        }
        pidCache[key] = processName
        pidCacheLock.unlock()
        
        return processName
    }
    
    // guarded by its own lock, the old OSAtomic compare-and-swap setter could
    // silently no-op if the stored value wasn't the exact expected one
    private var _trafficLoggingEnabled = true
    private let trafficLoggingLock = NSLock()
    private var trafficLoggingEnabled: Bool {
        get { trafficLoggingLock.lock(); defer { trafficLoggingLock.unlock() }; return _trafficLoggingEnabled }
        set { trafficLoggingLock.lock(); _trafficLoggingEnabled = newValue; trafficLoggingLock.unlock() }
    }
    
    private typealias CompiledRule = (rule: ProxyRule, matcher: ProxyRule.Matcher)
    private var rules: [CompiledRule] = []
    private let rulesLock = NSLock()
    private var nextRuleId: UInt32 = 1
    
    private struct StoredProxyConfig {
        let type: String
        let host: String
        let port: Int
        let username: String?
        let password: String?
        let sendDomain: Bool   // hand the proxy the host name instead of the ip when it is known
    }
    private var storedProxyConfigs: [String: StoredProxyConfig] = [:]
    // a chain is a list of proxy ids, walked through in order
    private var storedChains: [String: [String]] = [:]
    private let proxyLock = NSLock()
    // problems that would repeat on every connection are reported once per proxy list
    private var warnedKeys = Set<String>()

    private func warnOnce(_ key: String, _ message: String) {
        proxyLock.lock()
        let isNew = warnedKeys.insert(key).inserted
        proxyLock.unlock()
        if isNew { log(message, level: "ERROR") }
    }
    
    private func log(_ message: String, level: String = "INFO") {
        appendLog(.activity(timestamp: dateFormatter.string(from: Date()), level: level, message: message))
    }

    // the extension's own life cycle: to the unified log, which survives the extension, and to the
    // activity log, which the app shows while it is connected
    private func diag(_ message: String, level: String = "INFO") {
        ProviderDiagnostics.note(message, error: level == "ERROR")
        log(message, level: level)
    }

    // a short reason why a rule was turned away. the app passes it on, so the person
    // sees which field is wrong instead of a number of rules that vanished.
    static func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return error.localizedDescription }
        func field(_ context: DecodingError.Context) -> String {
            context.codingPath.first?.stringValue ?? "?"
        }
        switch decoding {
        case .keyNotFound(let key, _): return "the field '\(key.stringValue)' is missing"
        case .typeMismatch(let type, let context): return "the field '\(field(context))' is not a \(type)"
        case .valueNotFound(let type, let context): return "the field '\(field(context))' has no \(type) value"
        case .dataCorrupted(let context): return "the field '\(field(context))' cannot be read"
        @unknown default: return error.localizedDescription
        }
    }

    private func appendLog(_ entry: LogEntry) {
        logQueueLock.lock()
        logBuffer[logTail] = entry
        logTail = (logTail + 1) % AppProxyProvider.logCapacity
        if logCount < AppProxyProvider.logCapacity {
            logCount += 1
        } else {
            // buffer full, bump head to drop the oldest entry
            logHead = (logHead + 1) % AppProxyProvider.logCapacity
        }
        logQueueLock.unlock()
    }

    override func startProxy(options: [String : Any]?, completionHandler: @escaping (Error?) -> Void) {
        let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        
        let allTrafficRule = NENetworkRule(
            remoteNetwork: nil,
            remotePrefix: 0,
            localNetwork: nil,
            localPrefix: 0,
            protocol: .any,
            direction: .outbound
        )
        
        settings.includedNetworkRules = [allTrafficRule]

        startUDPSweepTimer()
        startFlowReportTimer()
        diag("Tunnel starting")
        // the rules and the proxy list can come with the configuration itself. they
        // do when the provider channel does not open, which is what happens on a
        // build that is not signed by a developer.
        applyConfigurationPayload(options)

        self.setTunnelNetworkSettings(settings) { [weak self] error in
            if let error = error {
                self?.diag("Could not apply the tunnel network settings: \(error.localizedDescription)", level: "ERROR")
            } else {
                self?.diag("Tunnel started")
            }
            completionHandler(error)
        }
    }
    
    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        diag("Tunnel stopping: \(ProviderDiagnostics.text(for: reason))")
        udpSweepTimer?.cancel()
        udpSweepTimer = nil
        stopFlowReportTimer()
        sweepHandshakes(all: true)
        udpLock.lock()
        let all = Array(udpAssociations.values)
        udpAssociations.removeAll()
        udpLock.unlock()
        for a in all {
            a.release()
        }
        // nothing is proxied any more, so nothing is a live flow
        for flow in liveFlows.removeAll() { reportFlowEnd(flow) }
        liveMapLock.lock()
        tcpFlowIds.removeAll()
        flowDescriptors.removeAll()
        liveMapLock.unlock()
        completionHandler()
    }
    
    // one association per udp flow, holds both channels so we tear the whole thing
    // down together when any side goes away
    private final class UDPAssociation {
        let clientFlow: NEAppProxyUDPFlow
        let controlConnection: NWTCPConnection  // socks5 tcp control channel, keeps the association alive
        let udpSession: NWUDPSession            // relay channel to the socks server
        let displayName: String
        var loggedDestinations = Set<String>()  // dedupe connection logs, bounded
        var isTornDown = false
        // the id of this association in the live flow list, so the app can terminate it
        var liveFlowId: UInt64?
        var liveDestination: String?
        private var lastActivity = Date()
        private let activityLock = NSLock()

        // per-packet work is the hot path for quic/video, so the socks5 header for
        // a destination and the endpoint for a relay source are built once and
        // reused. both are capped so they can't grow forever.
        struct HostPort: Hashable { let host: String; let port: UInt16 }
        var headerCache: [HostPort: Data] = [:]
        var endpointCache: [UInt64: (host: String, port: UInt16)] = [:]
        static let cacheLimit = 64

        func touch() {
            activityLock.lock(); lastActivity = Date(); activityLock.unlock()
        }

        func idleTime() -> TimeInterval {
            activityLock.lock(); defer { activityLock.unlock() }
            return Date().timeIntervalSince(lastActivity)
        }

        // NWUDPSession keeps its read handler after cancel(), and that handler
        // refers back to this association, so the whole graph (association,
        // session, tcp control connection, flow) used to stay alive after every
        // udp flow. swap the handler out first, then cancel.
        func release() {
            udpSession.setReadHandler({ _, _ in }, maxDatagrams: 1)
            controlConnection.cancel()
            udpSession.cancel()
        }

        init(clientFlow: NEAppProxyUDPFlow, controlConnection: NWTCPConnection, udpSession: NWUDPSession, displayName: String) {
            self.clientFlow = clientFlow
            self.controlConnection = controlConnection
            self.udpSession = udpSession
            self.displayName = displayName
        }
    }
    private var udpAssociations: [NEAppProxyUDPFlow: UDPAssociation] = [:]
    private let udpLock = NSLock()

    // ---- live flows ----
    //
    // The app lists the flows that are proxied right now and can terminate one of them. A flow is
    // registered when its relay starts and dropped again when the relay tears down, so the list
    // always shows the channels that are actually open.
    private let liveFlows = LiveFlowRegistry()

    // what the app shows for a flow. filled in before the handshake starts, because only then
    // are the process, the destination and the proxy known.
    private struct FlowDescriptor {
        let process: String
        let destination: String
        let port: UInt16
        let proxy: String
    }

    // proxy connection -> live flow id, so the relay can count its bytes and the teardown can
    // find the entry again
    private var tcpFlowIds: [ObjectIdentifier: UInt64] = [:]
    // proxy connection -> what to show for it
    private var flowDescriptors: [ObjectIdentifier: FlowDescriptor] = [:]
    private let liveMapLock = NSLock()

    private func setFlowDescriptor(_ descriptor: FlowDescriptor, for connection: NWTCPConnection) {
        liveMapLock.lock()
        flowDescriptors[ObjectIdentifier(connection)] = descriptor
        liveMapLock.unlock()
    }

    private func takeFlowDescriptor(for connection: NWTCPConnection) -> FlowDescriptor? {
        liveMapLock.lock(); defer { liveMapLock.unlock() }
        return flowDescriptors.removeValue(forKey: ObjectIdentifier(connection))
    }

    private func setTCPFlowId(_ id: UInt64, for connection: NWTCPConnection) {
        liveMapLock.lock()
        tcpFlowIds[ObjectIdentifier(connection)] = id
        liveMapLock.unlock()
    }

    private func peekTCPFlowId(for connection: NWTCPConnection) -> UInt64? {
        liveMapLock.lock(); defer { liveMapLock.unlock() }
        return tcpFlowIds[ObjectIdentifier(connection)]
    }

    private func takeTCPFlowId(for connection: NWTCPConnection) -> UInt64? {
        liveMapLock.lock(); defer { liveMapLock.unlock() }
        return tcpFlowIds.removeValue(forKey: ObjectIdentifier(connection))
    }

    // The relay is running, so the flow is a live connection: give it an id the app can address
    // and remember which proxy connection it belongs to.
    private func registerLiveTCPFlow(clientFlow: NEAppProxyTCPFlow, proxyConnection: NWTCPConnection) {
        guard let descriptor = takeFlowDescriptor(for: proxyConnection) else { return }
        let id = liveFlows.register(proto: "TCP", process: descriptor.process, destination: descriptor.destination,
                                     port: descriptor.port, proxy: descriptor.proxy) { [weak self] in
            // the user terminated it: tear the relay down so the application sees the connection die
            self?.closeRelay(clientFlow, proxyConnection, error: FlowFailure.terminated)
        }
        setTCPFlowId(id, for: proxyConnection)
        if let flow = liveFlows.snapshot(id: id) { reportFlowOpen(flow) }
    }

    private func noteFlowBytes(_ connection: NWTCPConnection, up: Int64, down: Int64) {
        guard let id = peekTCPFlowId(for: connection) else { return }
        liveFlows.note(id: id, up: up, down: down)
    }

    // udp has no close signal we can rely on (quic flows come and go), so idle
    // associations are reaped here, otherwise each one pins a flow, a tcp
    // control connection and a udp session for the life of the extension
    private static let udpIdleTimeout: TimeInterval = 120
    private var udpSweepTimer: DispatchSourceTimer?

    private func startUDPSweepTimer() {
        udpSweepTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.sweepHandshakes()
            self.udpLock.lock()
            let stale = self.udpAssociations.filter { $0.value.idleTime() > AppProxyProvider.udpIdleTimeout }.map { $0.key }
            self.udpLock.unlock()
            for flow in stale { self.teardownUDP(flow) }
        }
        timer.resume()
        udpSweepTimer = timer
    }

    // tcp and udp proxy handshakes have no timeout of their own, so a proxy that
    // accepts the connection and then goes quiet would pin the flow forever.
    // entries are checked by the shared sweep timer, no per-flow timer is
    // scheduled (a timer closure would hold the flow for its full delay even
    // after the handshake succeeded, which adds up with quic churn)
    private var pendingHandshakes: [ObjectIdentifier: (deadline: Date, flow: NEAppProxyFlow, connection: NWTCPConnection)] = [:]
    private let handshakeLock = NSLock()
    private static let handshakeTimeout: TimeInterval = 20
    // grace between a client FIN and tearing the relay down, lets the upstream FIN flush
    private static let halfCloseTimeout: TimeInterval = 3

    private func armHandshakeTimeout(flow: NEAppProxyFlow, connection: NWTCPConnection) {
        let deadline = Date().addingTimeInterval(AppProxyProvider.handshakeTimeout)
        handshakeLock.lock()
        pendingHandshakes[ObjectIdentifier(connection)] = (deadline, flow, connection)
        handshakeLock.unlock()
    }

    // false means the sweep already timed it out and tore everything down
    private func completeHandshake(_ connection: NWTCPConnection) -> Bool {
        handshakeLock.lock()
        defer { handshakeLock.unlock() }
        return pendingHandshakes.removeValue(forKey: ObjectIdentifier(connection)) != nil
    }

    private func sweepHandshakes(now: Date = Date(), all: Bool = false) {
        handshakeLock.lock()
        let expired = pendingHandshakes.filter { all || $0.value.deadline <= now }
        for key in expired.keys { pendingHandshakes.removeValue(forKey: key) }
        handshakeLock.unlock()
        for (_, entry) in expired {
            // a tcp flow must fail its connect (see FlowFailure), udp flows keep the clean close
            if let tcpFlow = entry.flow as? NEAppProxyTCPFlow {
                closeRelay(tcpFlow, entry.connection, error: FlowFailure.timedOut)
            } else {
                entry.connection.cancel()
                entry.flow.closeReadWithError(nil)
                entry.flow.closeWriteWithError(nil)
            }
        }
    }

    private func closeRelay(_ flow: NEAppProxyTCPFlow, _ connection: NWTCPConnection, error: Error? = nil) {
        connection.cancel()
        flow.closeReadWithError(error)
        flow.closeWriteWithError(error)
        // the relay is gone, so the flow is no longer live
        if let id = takeTCPFlowId(for: connection), let flow = liveFlows.remove(id: id) { reportFlowEnd(flow) }
        // and whatever was remembered about it goes with it, so a later connection that happens to
        // reuse the same address does not inherit the wrong process or destination
        takeFlowDescriptor(for: connection)
    }
    
    // The traffic of the open flows goes to the unified log, so the app can show it without the
    // message channel. The channel is checked against the app's signature, and a build that is not
    // signed by a developer gets nothing through it - so for those builds the log is the only way
    // the traffic can be shown at all.
    //
    // Five kinds of line:
    //   FlowOpen <id> <proto> <process> -> <host>:<port> via <proxy>   a flow was opened
    //   Flows <id>:<sent>:<received> ...                               the flows that are open
    //   FlowLive <id> <proto> <process> -> <host>:<port> via <proxy> <sent> <received>
    //   FlowEnd <id> <sent> <received>                                 a flow was closed
    //   ProxyTotals <name>|<sent>|<received>|<connections>;...        the totals of every proxy
    //
    // They go to the unified log only: the activity log the app shows is for what the extension has
    // to say, and a line a second would bury it.
    private func reportFlowOpen(_ flow: LiveFlowRegistry.Snapshot) {
        ProviderDiagnostics.note("FlowOpen \(flow.id) \(flow.proto) \(flow.process) -> \(flow.destination):\(flow.port) via \(flow.proxy)")
    }

    private func reportFlowEnd(_ flow: LiveFlowRegistry.Snapshot) {
        // the bytes of the flow go into the total of its proxy, so the number in the app does not
        // depend on the app having seen the flow
        countFinishedBytes(proxy: flow.proxy, up: flow.bytesUp, down: flow.bytesDown)
        ProviderDiagnostics.note("FlowEnd \(flow.id) \(flow.bytesUp) \(flow.bytesDown)")
    }

    // The flows that are open right now, with the bytes each one carried.
    //
    // The line is only written when something changed: a flow that opened or closed says so
    // on its own line, so a line that repeats the same numbers says nothing new.
    private func reportOpenFlows() {
        let flows = liveFlows.snapshot()
        guard !flows.isEmpty else { return }
        let rows = flows.map { "\($0.id):\($0.bytesUp):\($0.bytesDown)" }.joined(separator: " ")
        reportLock.lock()
        let unchanged = rows == lastFlowReport
        if !unchanged { lastFlowReport = rows }
        reportLock.unlock()
        guard !unchanged else { return }
        ProviderDiagnostics.note("Flows \(rows)")
    }

    // Every open flow gets a line of its own, with the bytes it has carried.
    //
    // The line a flow gets when it opens is not enough on its own: an app that starts
    // later never sees it, and a flow that was already open when the app started would
    // stay invisible to it forever. So the line is written again for every open flow,
    // and the app takes what it needs from whichever line it saw last.
    //
    // A flow that carries nothing is written every tenth round only: it says the same
    // thing every time, and it is still there when the app that missed it starts.
    private func reportLiveFlows(writeEveryFlow: Bool) {
        for flow in liveFlows.snapshot() {
            reportLock.lock()
            let last = lastReportedBytes[flow.id]
            let unchanged = !writeEveryFlow && last?.up == flow.bytesUp && last?.down == flow.bytesDown
            if !unchanged { lastReportedBytes[flow.id] = (up: flow.bytesUp, down: flow.bytesDown) }
            reportLock.unlock()
            if unchanged { continue }
            ProviderDiagnostics.note("FlowLive \(flow.id) \(flow.proto) \(flow.process) -> \(flow.destination):\(flow.port) via \(flow.proxy) \(flow.bytesUp) \(flow.bytesDown)")
        }
    }

    // The totals of every proxy, counted by the extension itself.
    //
    // The app cannot count them: it only sees what the unified log hands it, and a flow
    // that opened and closed before the app started is gone from the log by the time the
    // app looks. The extension keeps the numbers, so the table in the app is right from
    // the first second and does not lose a connection when the window is closed.
    private func reportProxyTotals() {
        counterLock.lock()
        let counters = proxyCounters
        counterLock.unlock()
        guard !counters.isEmpty else { return }

        // the flows that are open right now still have to be counted: their bytes have not
        // been added to the total yet, they only go there when they end
        let open = liveFlows.snapshot()
        var records: [String] = []
        for (name, counter) in counters {
            var up = counter.finishedUp
            var down = counter.finishedDown
            for flow in open where flow.proxy == name {
                up += flow.bytesUp
                down += flow.bytesDown
            }
            records.append("\(name)|\(up)|\(down)|\(counter.connections)")
        }
        ProviderDiagnostics.note("ProxyTotals \(records.joined(separator: ";"))")
    }

    // ---- what the extension counted ----
    //
    // The connections that went through a proxy and the bytes they carried. The bytes of a
    // direct connection are not in here: macOS hands those flows back to the system, so the
    // extension never carries them and never sees them.
    private struct ProxyCounter {
        var connections: Int = 0
        var finishedUp: Int64 = 0
        var finishedDown: Int64 = 0
    }
    private var proxyCounters: [String: ProxyCounter] = [:]
    private let counterLock = NSLock()

    // Counts a connection that was decided.
    private func countConnection(proxy: String) {
        counterLock.lock()
        proxyCounters[proxy, default: ProxyCounter()].connections += 1
        counterLock.unlock()
    }

    // Adds the bytes of a flow that ended to the total of its proxy.
    private func countFinishedBytes(proxy: String, up: Int64, down: Int64) {
        guard up > 0 || down > 0 else { return }
        counterLock.lock()
        var counter = proxyCounters[proxy, default: ProxyCounter()]
        counter.finishedUp += up
        counter.finishedDown += down
        proxyCounters[proxy] = counter
        counterLock.unlock()
    }

    // One line a second. The app reads the traffic from it, so this interval is how fresh the
    // numbers in the window are.
    private var flowReportTimer: DispatchSourceTimer?
    // The numbers of the last line about the open flows, so a line that says the same thing
    // again is not written again.
    private var lastFlowReport: String?
    // The bytes of every flow as they were written the last time, so a flow that carried
    // nothing is not written again.
    private var lastReportedBytes: [UInt64: (up: Int64, down: Int64)] = [:]
    // how many rounds of reports have gone by. every tenth round every open flow is written.
    private var reportRound = 0
    // the timer writes the report from its own queue and the tunnel is started and stopped from
    // another one, so the two do not touch the same state at the same time
    private let reportLock = NSLock()

    private func startFlowReportTimer() {
        stopFlowReportTimer()
        // the flow ids start over with every tunnel, so the last line says nothing about
        // the one that is starting
        reportLock.lock()
        lastFlowReport = nil
        lastReportedBytes.removeAll()
        reportRound = 0
        reportLock.unlock()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.reportRound += 1
            self.reportOpenFlows()
            self.reportLiveFlows(writeEveryFlow: self.reportRound % 10 == 0)
            self.reportProxyTotals()
        }
        timer.resume()
        flowReportTimer = timer
    }

    private func stopFlowReportTimer() {
        flowReportTimer?.cancel()
        flowReportTimer = nil
    }

    // ---- the rules and the proxy list ----
    //
    // They reach the extension in two ways: in a message over the provider channel,
    // and with the configuration the tunnel is started with.
    //
    // The channel is the normal way, but the system checks it against the app's
    // signature. A build that is not signed by a developer never gets a message
    // through: the tunnel comes up, the extension runs, and it has no rules at all,
    // so every connection goes direct and the list of connections stays empty. The
    // system hands the start options to the provider without that check, so the
    // rules travel that way as well - that is what keeps a build that is signed
    // ad-hoc usable.

    // how many flows arrived, for the log
    private var flowCounter = 0

    private func applyProxyConfigs(_ configs: [[String: Any]], chains: [[String: Any]]) {
        proxyLock.lock()
        storedProxyConfigs = [:]
        warnedKeys.removeAll()
        for configDict in configs {
            guard let id = configDict["id"] as? String,
                  let type = configDict["proxyType"] as? String,
                  let host = configDict["proxyHost"] as? String,
                  let port = configDict["proxyPort"] as? Int else { continue }
            storedProxyConfigs[id] = StoredProxyConfig(
                type: type, host: host, port: port,
                username: configDict["proxyUsername"] as? String,
                password: configDict["proxyPassword"] as? String,
                // an app that doesn't send the key keeps the old behavior (ip)
                sendDomain: configDict["sendDomainToProxy"] as? Bool ?? false
            )
        }
        // the chains come with the proxies: a chain is nothing but an ordered
        // list of proxy ids
        storedChains = [:]
        for chainDict in chains {
            guard let chainId = chainDict["id"] as? String else { continue }
            let proxies = chainDict["proxies"] as? [String] ?? []
            guard !proxies.isEmpty else { continue }
            storedChains[chainId] = proxies
        }
        let configCount = storedProxyConfigs.count
        let chainCount = storedChains.count
        proxyLock.unlock()
        diag("Proxy configs updated: \(configCount) config(s), \(chainCount) chain(s)")
    }

    // replaces the rule list. returns how many rules were applied, how many were
    // turned away, and the reason of the first one that was
    @discardableResult
    private func applyRules(_ raw: [[String: Any]]) -> (Int, Int, String?) {
        var built: [CompiledRule] = []
        built.reserveCapacity(raw.count)
        var rejected = 0
        var firstReason: String?
        for dict in raw {
            guard let ruleData = try? JSONSerialization.data(withJSONObject: dict) else {
                rejected += 1
                if firstReason == nil { firstReason = "the rule is not valid json" }
                continue
            }
            do {
                let rule = try JSONDecoder().decode(ProxyRule.self, from: ruleData)
                built.append((rule, ProxyRule.Matcher(rule)))
            } catch {
                // a rule that is turned away is a rule that does not exist for the
                // traffic, so the reason is worth more than the number
                rejected += 1
                if firstReason == nil { firstReason = AppProxyProvider.describe(error) }
            }
        }
        rulesLock.lock()
        rules = built.map { item in
            var rule = item.rule
            rule.ruleId = nextRuleId
            nextRuleId += 1
            return (rule, item.matcher)
        }
        rulesLock.unlock()
        let summary = "Rules: \(built.count) applied, \(rejected) rejected" + (firstReason.map { " (the first one: \($0))" } ?? "")
        log(summary)
        diag(summary)
        return (built.count, rejected, firstReason)
    }

    // The rules and the proxy list that came with the configuration. The system
    // hands them to the provider when the tunnel starts.
    private func applyConfigurationPayload(_ options: [String: Any]?) {
        guard let payload = options?["proxybridge"] as? [String: Any] else { return }
        if let configs = payload["proxies"] as? [[String: Any]] {
            applyProxyConfigs(configs, chains: payload["chains"] as? [[String: Any]] ?? [])
        }
        if let rules = payload["rules"] as? [[String: Any]] {
            applyRules(rules)
        }
        if let policy = payload["dnsPolicy"] as? [String: Any] {
            // the DNS proxy provider cannot be sent a message, so the policy is
            // published in the container it reads
            DNSPolicyStore.shared.publish(DNSPolicy.fromDictionary(policy))
            log("DNS policy updated")
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let message = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any],
              let action = message["action"] as? String else {
            completionHandler?(nil)
            return
        }
        
        // every message that arrives is written down. when the app says the rules were
        // not applied, this line is the one that says whether the message came in at all.
        ProviderDiagnostics.note("Message: \(action)")

        switch action {
        case "getInfo":
            // Who is answering? The app asks as soon as the tunnel is up.
            //
            // macOS keeps every registered version of a system extension under the
            // same bundle id. If an older ProxyBridge is still registered, the
            // system may bind the tunnel to that one instead of this build. The
            // old one speaks an older protocol: it ignores the rules and the
            // proxies, so nothing is proxied and the window stays empty with no
            // reason given. This answer is what lets the app say what is wrong.
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
            let info: [String: Any] = [
                "status": "ok",
                "api": AppProxyProvider.protocolAPI,
                "version": version,
                "pid": ProcessInfo.processInfo.processIdentifier
            ]
            completionHandler?(try? JSONSerialization.data(withJSONObject: info))
        case "getLogs":
            logQueueLock.lock()
            if logCount > 0 {
                let batchSize = min(100, logCount)
                var logsToSend: [[String: String]] = []
                logsToSend.reserveCapacity(batchSize)
                for _ in 0..<batchSize {
                    if let entry = logBuffer[logHead] {
                        logsToSend.append(entry.toDict())
                    }
                    logBuffer[logHead] = nil  // release the drained entry
                    logHead = (logHead + 1) % AppProxyProvider.logCapacity
                    logCount -= 1
                }
                logQueueLock.unlock()
                completionHandler?(try? JSONSerialization.data(withJSONObject: logsToSend))
            } else {
                logQueueLock.unlock()
                completionHandler?(nil)
            }
        case "setTrafficLogging":
            if let enabled = message["enabled"] as? Bool {
                trafficLoggingEnabled = enabled
                let response = ["status": "ok"]
                completionHandler?(try? JSONSerialization.data(withJSONObject: response))
            } else {
                completionHandler?(nil)
            }
        case "setDNSPolicy":
            if let raw = message["policy"] as? [String: Any] {
                // published in the shared container so the DNS proxy provider,
                // which cannot be sent a message, sees the same policy
                DNSPolicyStore.shared.publish(DNSPolicy.fromDictionary(raw))
                log("DNS policy updated")
            }
            completionHandler?(try? JSONSerialization.data(withJSONObject: ["status": "ok"]))
        case "setProxyConfigs":
            if let configs = message["configs"] as? [[String: Any]] {
                applyProxyConfigs(configs, chains: message["chains"] as? [[String: Any]] ?? [])
            }
            completionHandler?(try? JSONSerialization.data(withJSONObject: ["status": "ok"]))

        case "addRule":
            if let ruleData = try? JSONSerialization.data(withJSONObject: message),
               var rule = try? JSONDecoder().decode(ProxyRule.self, from: ruleData) {
                rulesLock.lock()
                rule.ruleId = nextRuleId
                nextRuleId += 1
                rules.append((rule, ProxyRule.Matcher(rule)))
                rulesLock.unlock()

                let response: [String: Any] = [
                    "status": "ok",
                    "ruleId": rule.ruleId,
                    "processNames": rule.processNames,
                    "targetHosts": rule.targetHosts,
                    "targetPorts": rule.targetPorts,
                    "protocol": rule.ruleProtocol.rawValue,
                    "action": rule.action,
                    "enabled": rule.enabled
                ]
                completionHandler?(try? JSONSerialization.data(withJSONObject: response))
            } else {
                let response = ["status": "error", "message": "Invalid rule format"]
                completionHandler?(try? JSONSerialization.data(withJSONObject: response))
            }
        
        case "setRules":
            // replace the whole rule list in one step. the old way was clearRules
            // followed by one addRule per rule, and any connection that arrived
            // in between was matched against a half-built list (so it went direct)
            guard let raw = message["rules"] as? [[String: Any]] else {
                completionHandler?(try? JSONSerialization.data(withJSONObject: ["status": "error", "message": "Invalid rules payload"]))
                return
            }
            let (count, rejected, firstReason) = applyRules(raw)
            var response: [String: Any] = ["status": "ok", "count": count, "skipped": rejected]
            if let firstReason = firstReason { response["message"] = firstReason }
            completionHandler?(try? JSONSerialization.data(withJSONObject: response))

        case "clearRules":
            rulesLock.lock()
            let count = rules.count
            rules.removeAll()
            rulesLock.unlock()
            let response: [String: Any] = ["status": "ok", "cleared": count]
            completionHandler?(try? JSONSerialization.data(withJSONObject: response))
        
        case "clearConfig":
            // drop the stored proxy configs so credentials don't sit in memory after stop
            proxyLock.lock()
            storedProxyConfigs.removeAll()
            warnedKeys.removeAll()
            proxyLock.unlock()
            completionHandler?(try? JSONSerialization.data(withJSONObject: ["status": "ok"]))

        case "getFlows":
            // the flows that are proxied right now, so the app can show them and terminate one
            let now = Date()
            let flows: [[String: Any]] = liveFlows.snapshot().map { flow in
                [
                    "id": flow.id,
                    "protocol": flow.proto,
                    "process": flow.process,
                    "destination": flow.destination,
                    "port": Int(flow.port),
                    "proxy": flow.proxy,
                    "up": flow.bytesUp,
                    "down": flow.bytesDown,
                    "age": flow.ageSeconds(now: now),
                    "idle": flow.idleSeconds(now: now)
                ]
            }
            completionHandler?(try? JSONSerialization.data(withJSONObject: flows))

        case "killFlow":
            // terminate one live connection: the relay is torn down, so the application sees the
            // connection die instead of waiting for a proxy that stopped answering
            var killed = false
            if let id = (message["id"] as? NSNumber)?.uint64Value {
                // the flow is taken out of the registry by the teardown below, so the bytes it
                // carried are read before that happens
                let flow = liveFlows.snapshot(id: id)
                killed = liveFlows.terminate(id: id)
                if killed, let flow { reportFlowEnd(flow) }
            }
            completionHandler?(try? JSONSerialization.data(withJSONObject: ["status": "ok", "killed": killed]))

        default:
            completionHandler?(nil)
        }
    }
    
    override func sleep(completionHandler: @escaping () -> Void) {
        completionHandler()
    }
    
    override func wake() {
    }
    
    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        // a word about the flow in the unified log: when nothing is proxied, the
        // first question is whether the flows arrive at all
        flowCounter += 1
        if flowCounter <= 10 || flowCounter % 50 == 0 {
            diag("Flow #\(flowCounter) from \(flow.metaData.sourceAppSigningIdentifier ?? "?")")
        }
        if let tcpFlow = flow as? NEAppProxyTCPFlow {
            return handleTCPFlow(tcpFlow)
        } else if let udpFlow = flow as? NEAppProxyUDPFlow {
            return handleUDPFlow(udpFlow)
        }
        return false
    }
    
    private func handleTCPFlow(_ flow: NEAppProxyTCPFlow) -> Bool {
        let metaData = flow.metaData
        let processPath = metaData.sourceAppSigningIdentifier
        
        // never proxy our own traffic, it would loop
        // our own bundle ids: the app and the extension. the old extension id is still
        // listed so that a build that was not updated does not proxy itself either.
        if processPath == "com.interceptsuite.ProxyBridge" || processPath == "com.interceptsuite.ProxyBridge.fork" || processPath == "com.interceptsuite.ProxyBridge.extension" {
            return false
        }

        let remoteEndpoint = flow.remoteEndpoint
        var destination = ""
        var portNum: UInt16 = 0
        var portStr = ""
        
        if let remoteHost = remoteEndpoint as? NWHostEndpoint {
            destination = remoteHost.hostname
            portStr = remoteHost.port
            portNum = UInt16(portStr) ?? 0
        } else {
            destination = String(describing: remoteEndpoint)
            portStr = "unknown"
        }
        
        let processName = getProcessName(from: metaData)
        let displayName = processName ?? processPath

        // domains that resolved to this ip (from the dns proxy), used for domain
        // rules and to show the hostname in the log instead of the raw ip
        let domains = DNSMapStore.shared.domains(forIP: destination)
        let logDest = domains.first ?? destination

        // rules are always evaluated. a proxy config is only needed by a rule that
        // routes to one, BLOCK and DIRECT rules work without any (they used to be
        // skipped whenever no proxy was configured, so a lone BLOCK rule did nothing)
        let matchedRule = findMatchingRule(bundleId: processPath, processName: processName, destination: destination, port: portNum, connectionProtocol: .tcp, checkIpPort: true, domains: domains)

        if let rule = matchedRule {
            switch rule.action {
            case "DIRECT":
                sendLogToApp(protocol: "TCP", process: displayName, destination: logDest, port: portStr, proxy: "Direct", rule: matchedRule?.ruleId)
                return false
            case "BLOCK":
                sendLogToApp(protocol: "TCP", process: displayName, destination: logDest, port: portStr, proxy: "BLOCK", rule: matchedRule?.ruleId)
                flow.closeReadWithError(nil)
                flow.closeWriteWithError(nil)
                return true
            default:
                proxyLock.lock()
                let config = storedProxyConfigs[rule.action]
                // a chain walks through several proxies, one after the other
                let chainIds = ChainAction.isChain(rule.action)
                    ? ChainPlan.proxyIds(forAction: rule.action, chains: storedChains)
                    : []
                let hops = chainIds.compactMap { storedProxyConfigs[$0] }
                // the type of every proxy the chain names. a chain may name the
                // same proxy twice, so the map is built by hand: the initializer
                // that demands unique keys would trap on that
                var chainTypes: [String: String] = [:]
                for id in chainIds {
                    if let type = storedProxyConfigs[id]?.type.lowercased() {
                        chainTypes[id] = type
                    }
                }
                proxyLock.unlock()

                if ChainAction.isChain(rule.action) {
                    guard !hops.isEmpty else {
                        warnOnce("missing-chain:\(rule.action)", "A rule routes to a chain that has no usable proxy in it, its traffic is going direct")
                        sendLogToApp(protocol: "TCP", process: displayName, destination: logDest, port: portStr, proxy: "Direct", rule: matchedRule?.ruleId)
                        return false
                    }
                    let problems = ChainPlan.problems(withProxyIds: chainIds, proxyTypes: chainTypes)
                    if !problems.isEmpty {
                        warnOnce("broken-chain:\(rule.action)", "A rule routes to a chain that cannot work: \(problems.joined(separator: "; ")). Its traffic is going direct.")
                        sendLogToApp(protocol: "TCP", process: displayName, destination: logDest, port: portStr, proxy: "Direct", rule: matchedRule?.ruleId)
                        return false
                    }
                    sendLogToApp(protocol: "TCP", process: displayName, destination: logDest, port: portStr, proxy: chainLabel(hops), rule: matchedRule?.ruleId)
                    proxyTCPFlow(flow, destination: destination, displayDestination: logDest, port: portNum, process: displayName, hops: hops)
                    return true
                }

                guard let config = config else {
                    // rule points at a proxy that no longer exists. it still goes
                    // direct, but say so instead of leaking silently
                    warnOnce("missing:\(rule.action)", "A rule routes to a proxy that no longer exists, its traffic is going direct")
                    sendLogToApp(protocol: "TCP", process: displayName, destination: logDest, port: portStr, proxy: "Direct", rule: matchedRule?.ruleId)
                    return false
                }
                sendLogToApp(protocol: "TCP", process: displayName, destination: logDest, port: portStr, proxy: proxyLabel(config), rule: matchedRule?.ruleId)
                proxyTCPFlow(flow, destination: destination, displayDestination: logDest, port: portNum, process: displayName, hops: [config])
                return true
            }
        } else {
            sendLogToApp(protocol: "TCP", process: displayName, destination: logDest, port: portStr, proxy: "Direct", rule: matchedRule?.ruleId)
            return false
        }
    }

    // human readable label for the connection log, e.g. SOCKS5 127.0.0.1:1080
    private func proxyLabel(_ config: StoredProxyConfig) -> String {
        return "\(config.type.uppercased()) \(sanitize(config.host)):\(config.port)"
    }

    // The name of a proxy goes into a line of the log where a "|" and a ";" separate
    // the fields, so a host that has one of them in it would break the reading of the
    // line - and the numbers of that proxy would end up on another one.
    //
    // A host name does not have those in it, but nothing stops a person from typing
    // them, so they are put to "_" instead.
    private func sanitize(_ host: String) -> String {
        return host
            .replacingOccurrences(of: "|", with: "_")
            .replacingOccurrences(of: ";", with: "_")
    }

    // the label of a chain: every proxy it walks through, in order
    private func chainLabel(_ hops: [StoredProxyConfig]) -> String {
        return hops.map { proxyLabel($0) }.joined(separator: " -> ")
    }
    
    private func handleUDPFlow(_ flow: NEAppProxyUDPFlow) -> Bool {
        let metaData = flow.metaData
        let processPath = metaData.sourceAppSigningIdentifier
        let processName = getProcessName(from: metaData)
        let displayName = processName ?? processPath
        
        // our own bundle ids: the app and the extension. the old extension id is still
        // listed so that a build that was not updated does not proxy itself either.
        if processPath == "com.interceptsuite.ProxyBridge" || processPath == "com.interceptsuite.ProxyBridge.fork" || processPath == "com.interceptsuite.ProxyBridge.extension" {
            return false
        }
        
        // rules first: udp BLOCK and DIRECT need no proxy at all. only a rule that
        // sends udp through a proxy needs a socks5 one (http proxies can't carry udp)
        proxyLock.lock()
        let hasAnySocks5 = storedProxyConfigs.values.contains { $0.type.lowercased() == "socks5" }
        proxyLock.unlock()

        let matchedRule = findMatchingRule(bundleId: processPath, processName: processName, destination: "", port: 0, connectionProtocol: .udp, checkIpPort: false)

        if let rule = matchedRule {
            let action = rule.action
            switch action {
            case "DIRECT":
                sendLogToApp(protocol: "UDP", process: displayName, destination: "unknown", port: "unknown", proxy: "Direct", rule: matchedRule?.ruleId)
                return false
            case "BLOCK":
                sendLogToApp(protocol: "UDP", process: displayName, destination: "unknown", port: "unknown", proxy: "BLOCK", rule: matchedRule?.ruleId)
                // a handled flow that is never closed stays pinned in the extension
                flow.closeReadWithError(nil)
                flow.closeWriteWithError(nil)
                return true
            default:
                if ChainAction.isChain(action) {
                    // udp cannot walk a chain: only a socks5 proxy can carry it,
                    // and a socks5 udp association is a session of its own
                    warnOnce("udp-chain:\(action)", "UDP can't go through a proxy chain, UDP traffic for that rule is going direct")
                    return false
                }
                proxyLock.lock()
                let matched = storedProxyConfigs[action]
                proxyLock.unlock()
                guard let socks5Config = matched else {
                    warnOnce("missing:\(action)", "A rule routes to a proxy that no longer exists, its traffic is going direct")
                    return false
                }
                guard socks5Config.type.lowercased() == "socks5" else {
                    warnOnce("udp-http:\(action)", "UDP can't go through an HTTP proxy, UDP traffic for that rule is going direct")
                    return false
                }
                flow.open(withLocalEndpoint: nil) { [weak self] error in
                    guard let self = self else { return }
                    // a closed flow here is normal churn (quic opening and dropping
                    // udp/443 flows constantly), nothing to do and not worth logging
                    if error != nil {
                        return
                    }
                    // pass the resolved display name (curl), not the raw signing id (curl-<hash>)
                    self.proxyUDPFlowViaSOCKS5(flow, displayName: displayName, socksHost: socks5Config.host, socksPort: socks5Config.port, username: socks5Config.username, password: socks5Config.password)
                }
                return true
            }
        } else {
            // no rule matched. as before, only log it when udp proxying is possible
            // at all, otherwise every mDNS/NTP flow would fill the log
            if hasAnySocks5 {
                sendLogToApp(protocol: "UDP", process: displayName, destination: "unknown", port: "unknown", proxy: "Direct", rule: matchedRule?.ruleId)
            }
            return false
        }
    }
    
    // handshake failed before an association existed, so drop the control
    // connection and close the flow instead of leaking them
    private func failUDPHandshake(_ clientFlow: NEAppProxyUDPFlow, _ tcpConnection: NWTCPConnection, _ reason: String) {
        log(reason, level: "ERROR")
        tcpConnection.cancel()
        clientFlow.closeReadWithError(nil)
        clientFlow.closeWriteWithError(nil)
    }

    private func proxyUDPFlowViaSOCKS5(_ clientFlow: NEAppProxyUDPFlow, displayName: String, socksHost: String, socksPort: Int, username: String?, password: String?) {
        let proxyEndpoint = NWHostEndpoint(hostname: socksHost, port: String(socksPort))
        let tcpConnection = createTCPConnection(to: proxyEndpoint, enableTLS: false, tlsParameters: nil, delegate: nil)
        armHandshakeTimeout(flow: clientFlow, connection: tcpConnection)

        // offer username/password auth when we have credentials, same as the tcp path
        let useAuth = (username != nil && password != nil)
        let greeting: [UInt8] = useAuth ? [0x05, 0x02, 0x00, 0x02] : [0x05, 0x01, 0x00]

        tcpConnection.write(Data(greeting)) { [weak self] error in
            guard let self = self else { return }

            if let error = error {
                self.failUDPHandshake(clientFlow, tcpConnection, "SOCKS5 UDP greeting failed: \(error.localizedDescription)")
                return
            }

            tcpConnection.readMinimumLength(2, maximumLength: 2) { [weak self] data, error in
                guard let self = self else { return }

                if let error = error {
                    self.failUDPHandshake(clientFlow, tcpConnection, "SOCKS5 UDP greeting response failed: \(error.localizedDescription)")
                    return
                }

                guard let data = data, data.count == 2, data[0] == 0x05 else {
                    self.failUDPHandshake(clientFlow, tcpConnection, "SOCKS5 UDP greeting response invalid")
                    return
                }

                switch data[1] {
                case 0x00:
                    self.sendSOCKS5UDPAssociate(clientFlow: clientFlow, tcpConnection: tcpConnection, socksHost: socksHost, displayName: displayName)
                case 0x02:
                    self.sendSOCKS5UDPAuth(clientFlow: clientFlow, tcpConnection: tcpConnection, socksHost: socksHost, displayName: displayName, username: username ?? "", password: password ?? "")
                default:
                    self.failUDPHandshake(clientFlow, tcpConnection, "SOCKS5 UDP no acceptable auth method")
                }
            }
        }
    }

    private func sendSOCKS5UDPAuth(clientFlow: NEAppProxyUDPFlow, tcpConnection: NWTCPConnection, socksHost: String, displayName: String, username: String, password: String) {
        let user = Array(username.utf8), pass = Array(password.utf8)
        guard user.count <= 255, pass.count <= 255 else {
            self.failUDPHandshake(clientFlow, tcpConnection, "SOCKS5 UDP credentials too long")
            return
        }

        var authData = Data()
        authData.append(0x01)
        authData.append(UInt8(user.count))
        authData.append(contentsOf: user)
        authData.append(UInt8(pass.count))
        authData.append(contentsOf: pass)

        tcpConnection.write(authData) { [weak self] error in
            guard let self = self else { return }

            if let error = error {
                self.failUDPHandshake(clientFlow, tcpConnection, "SOCKS5 UDP auth write failed: \(error.localizedDescription)")
                return
            }

            tcpConnection.readMinimumLength(2, maximumLength: 2) { [weak self] data, error in
                guard let self = self else { return }

                if let error = error {
                    self.failUDPHandshake(clientFlow, tcpConnection, "SOCKS5 UDP auth response failed: \(error.localizedDescription)")
                    return
                }

                guard let data = data, data.count == 2, data[1] == 0x00 else {
                    self.failUDPHandshake(clientFlow, tcpConnection, "SOCKS5 UDP auth rejected")
                    return
                }

                self.sendSOCKS5UDPAssociate(clientFlow: clientFlow, tcpConnection: tcpConnection, socksHost: socksHost, displayName: displayName)
            }
        }
    }

    private func sendSOCKS5UDPAssociate(clientFlow: NEAppProxyUDPFlow, tcpConnection: NWTCPConnection, socksHost: String, displayName: String) {
        var request = Data()
        request.append(0x05)
        request.append(0x03)
        request.append(0x00)
        request.append(0x01)
        request.append(contentsOf: [0, 0, 0, 0])
        request.append(contentsOf: [0, 0])
        
        tcpConnection.write(request) { [weak self] error in
            guard let self = self else { return }

            if let error = error {
                self.failUDPHandshake(clientFlow, tcpConnection, "SOCKS5 UDP ASSOCIATE failed: \(error.localizedDescription)")
                return
            }

            self.readSOCKS5Reply(tcpConnection) { [weak self] reply in
                guard let self = self else { return }

                switch reply {
                case .failed(let reason):
                    self.failUDPHandshake(clientFlow, tcpConnection, "SOCKS5 UDP ASSOCIATE failed: \(reason)")
                case .rejected(let rep):
                    self.failUDPHandshake(clientFlow, tcpConnection, "SOCKS5 UDP ASSOCIATE rejected, REP=0x\(String(format: "%02x", rep)) (\(self.socksReplyReason(rep)))")
                case .success(let data):
                    let (parsedHost, relayPort) = self.parseSOCKS5Address(from: data, offset: 3)
                    // many socks servers reply 0.0.0.0 meaning "reuse the control connection host"
                    let relayHost = (parsedHost == "0.0.0.0" || parsedHost == "::" || parsedHost.isEmpty) ? socksHost : parsedHost
                    guard relayPort != 0 else {
                        self.failUDPHandshake(clientFlow, tcpConnection, "SOCKS5 UDP ASSOCIATE returned no relay port")
                        return
                    }
                    self.relayUDPThroughSOCKS5(clientFlow: clientFlow, relayHost: relayHost, relayPort: relayPort, tcpConnection: tcpConnection, displayName: displayName)
                }
            }
        }
    }

    private enum SOCKS5Reply {
        case success(Data)       // the whole reply, VER REP RSV ATYP BND.ADDR BND.PORT
        case rejected(UInt8)     // REP != 0
        case failed(String)
    }

    // reads exactly n bytes, never more, so nothing the server sends after what we
    // asked for (a banner from a server-first protocol) is consumed here
    private func readExact(_ connection: NWTCPConnection, _ n: Int, completion: @escaping (Data?, Error?) -> Void) {
        connection.readMinimumLength(n, maximumLength: n) { data, error in
            if let error = error { completion(nil, error); return }
            guard let data = data, data.count == n else { completion(nil, nil); return }
            completion(data, nil)
        }
    }

    // reads one SOCKS5 reply. the length depends on the address type (10 bytes for
    // ipv4, 22 for ipv6, variable for a domain), reading a fixed 10 used to leave
    // part of an ipv6/domain reply in the client's data and could swallow the
    // first bytes the real server sent
    private func readSOCKS5Reply(_ connection: NWTCPConnection, completion: @escaping (SOCKS5Reply) -> Void) {
        readExact(connection, 4) { [weak self] header, error in
            guard let self = self else { return }
            if let error = error { completion(.failed(error.localizedDescription)); return }
            guard let header = header, header[0] == 0x05 else { completion(.failed("invalid reply")); return }
            guard header[1] == 0x00 else { completion(.rejected(header[1])); return }

            func finish(_ rest: Data?, _ error: Error?, prefix: Data) {
                if let error = error { completion(.failed(error.localizedDescription)); return }
                guard let rest = rest else { completion(.failed("short reply")); return }
                completion(.success(prefix + rest))
            }

            switch header[3] {
            case 0x01:
                self.readExact(connection, 6) { rest, error in finish(rest, error, prefix: header) }
            case 0x04:
                self.readExact(connection, 18) { rest, error in finish(rest, error, prefix: header) }
            case 0x03:
                self.readExact(connection, 1) { lenByte, error in
                    guard let lenByte = lenByte else { completion(.failed(error?.localizedDescription ?? "short reply")); return }
                    self.readExact(connection, Int(lenByte[0]) + 2) { rest, error in
                        finish(rest, error, prefix: header + lenByte)
                    }
                }
            default:
                completion(.failed("unsupported address type 0x\(String(format: "%02x", header[3]))"))
            }
        }
    }

    // reads an http proxy's reply up to the end of its headers. returns the status
    // code and whatever the server already sent after the headers, which belongs to
    // the tunnel and has to reach the client first
    private func readHTTPConnectResponse(_ connection: NWTCPConnection, buffer: Data = Data(), completion: @escaping (Int?, Data, String) -> Void) {
        connection.readMinimumLength(1, maximumLength: 8192) { [weak self] data, error in
            guard let self = self else { return }
            if let error = error { completion(nil, Data(), error.localizedDescription); return }
            var buffer = buffer
            if let data = data { buffer.append(data) }

            if let end = buffer.range(of: Data([0x0d, 0x0a, 0x0d, 0x0a])) {
                let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
                let statusLine = head.components(separatedBy: "\r\n").first ?? ""
                let parts = statusLine.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), let status = Int(parts[1]) else {
                    completion(nil, Data(), "invalid status line: \(statusLine.prefix(80))")
                    return
                }
                completion(status, Data(buffer[end.upperBound...]), statusLine)
            } else if buffer.count >= 16384 || data == nil || data!.isEmpty {
                completion(nil, Data(), "response headers incomplete or too large")
            } else {
                self.readHTTPConnectResponse(connection, buffer: buffer, completion: completion)
            }
        }
    }

    // human readable name for a socks5 REP code, from RFC 1928
    private func socksReplyReason(_ rep: UInt8) -> String {
        switch rep {
        case 0x01: return "general failure"
        case 0x02: return "not allowed by ruleset"
        case 0x03: return "network unreachable"
        case 0x04: return "host unreachable"
        case 0x05: return "connection refused"
        case 0x06: return "TTL expired"
        case 0x07: return "command not supported"
        case 0x08: return "address type not supported"
        default: return "unknown"
        }
    }

    private func parseSOCKS5Address(from data: Data, offset: Int) -> (String, UInt16) {
        guard data.count > offset else { return ("0.0.0.0", 0) }
        let atyp = data[offset]

        if atyp == 0x01 {
            guard data.count >= offset + 7 else { return ("0.0.0.0", 0) }
            let ip = "\(data[offset+1]).\(data[offset+2]).\(data[offset+3]).\(data[offset+4])"
            let port = (UInt16(data[offset+5]) << 8) | UInt16(data[offset+6])
            return (ip, port)
        } else if atyp == 0x04 {
            guard data.count >= offset + 19 else { return ("0.0.0.0", 0) }
            var ipv6Parts: [String] = []
            for i in 0..<8 {
                let idx = offset + 1 + (i * 2)
                let part = (UInt16(data[idx]) << 8) | UInt16(data[idx+1])
                ipv6Parts.append(String(format: "%x", part))
            }
            let ip = ipv6Parts.joined(separator: ":")
            let port = (UInt16(data[offset+17]) << 8) | UInt16(data[offset+18])
            return (ip, port)
        } else if atyp == 0x03 {
            guard data.count >= offset + 2 else { return ("0.0.0.0", 0) }
            let len = Int(data[offset+1])
            guard data.count >= offset + 2 + len + 2 else { return ("0.0.0.0", 0) }
            let domain = String(data: data[(offset+2)..<(offset+2+len)], encoding: .utf8) ?? "unknown"
            let port = (UInt16(data[offset+2+len]) << 8) | UInt16(data[offset+2+len+1])
            return (domain, port)
        }

        return ("0.0.0.0", 0)
    }
    
    private func relayUDPThroughSOCKS5(clientFlow: NEAppProxyUDPFlow, relayHost: String, relayPort: UInt16, tcpConnection: NWTCPConnection, displayName: String) {
        guard completeHandshake(tcpConnection) else { return }
        let relayEndpoint = NWHostEndpoint(hostname: relayHost, port: String(relayPort))
        let udpSession = self.createUDPSession(to: relayEndpoint, from: nil)

        let association = UDPAssociation(clientFlow: clientFlow, controlConnection: tcpConnection, udpSession: udpSession, displayName: displayName)

        udpLock.lock()
        let existing = udpAssociations[clientFlow]
        udpAssociations[clientFlow] = association
        udpLock.unlock()
        // if the app reused a flow, drop the stale association first
        existing?.release()

        // the udp channel is live: register it so the app can list and terminate it. the
        // destination is only known once the first datagram arrives.
        let liveId = liveFlows.register(proto: "UDP", process: displayName, destination: "unknown", port: 0,
                                        proxy: "SOCKS5 \(relayHost):\(relayPort)") { [weak self] in
            self?.teardownUDP(clientFlow)
        }
        association.liveFlowId = liveId
        if let flow = liveFlows.snapshot(id: liveId) { reportFlowOpen(flow) }

        readAndForwardClientUDP(association)
        readAndForwardRelayUDP(association)
        // note: we deliberately don't read the control connection to detect close.
        // holding a strong ref keeps the associate alive, and reading it risks a
        // spurious teardown that would EPIPE the app's udp socket.
    }

    // idempotent, cancels both channels and closes the flow exactly once
    private func teardownUDP(_ flow: NEAppProxyUDPFlow) {
        udpLock.lock()
        guard let assoc = udpAssociations.removeValue(forKey: flow), !assoc.isTornDown else {
            udpLock.unlock()
            return
        }
        assoc.isTornDown = true
        udpLock.unlock()

        assoc.release()
        flow.closeReadWithError(nil)
        flow.closeWriteWithError(nil)
        // the channel is gone, so it is no longer a live flow
        if let liveId = assoc.liveFlowId, let flow = liveFlows.remove(id: liveId) { reportFlowEnd(flow) }
    }

    private func readAndForwardClientUDP(_ association: UDPAssociation) {
        let clientFlow = association.clientFlow
        clientFlow.readDatagrams { [weak self] datagrams, endpoints, error in
            guard let self = self else { return }

            if let error = error {
                self.log("UDP read error: \(error.localizedDescription)", level: "ERROR")
                self.teardownUDP(clientFlow)
                return
            }

            // nil or empty datagrams with no error = flow closed for reading.
            // re-arming on empty spins at 100% cpu because the read completes
            // immediately forever once the flow is closed (issue #89 / pr #90)
            guard let datagrams = datagrams, let endpoints = endpoints, !datagrams.isEmpty else {
                self.teardownUDP(clientFlow)
                return
            }

            association.touch()
            var toSend: [Data] = []
            toSend.reserveCapacity(datagrams.count)

            for i in 0..<min(datagrams.count, endpoints.count) {
                guard let nwHost = endpoints[i] as? NWHostEndpoint else { continue }
                let destHost = nwHost.hostname
                let destPort = UInt16(nwHost.port) ?? 0
                guard destPort != 0 else { continue }

                // a udp flow has no destination until its first datagram arrives, and it can
                // change afterwards, so the live flow list follows the last one seen
                if let liveId = association.liveFlowId, association.liveDestination != destHost {
                    association.liveDestination = destHost
                    self.liveFlows.setDestination(destHost, for: liveId)
                }

                // log each distinct destination once, cap the set so it can't grow forever
                if !association.loggedDestinations.contains(destHost) {
                    if association.loggedDestinations.count < 64 {
                        association.loggedDestinations.insert(destHost)
                    }
                    self.sendLogToApp(protocol: "UDP", process: association.displayName, destination: destHost, port: nwHost.port, proxy: "SOCKS5")
                }

                let key = UDPAssociation.HostPort(host: destHost, port: destPort)
                var header = association.headerCache[key]
                if header == nil, let built = self.socks5UDPHeader(destHost: destHost, destPort: destPort) {
                    if association.headerCache.count < UDPAssociation.cacheLimit { association.headerCache[key] = built }
                    header = built
                }
                // a udp payload can be up to ~65507 bytes, don't drop mtu-sized quic packets
                if let header = header, datagrams[i].count <= 65507 {
                    var packet = Data(capacity: header.count + datagrams[i].count)
                    packet.append(header)
                    packet.append(datagrams[i])
                    toSend.append(packet)
                }
            }

            if !toSend.isEmpty {
                association.udpSession.writeMultipleDatagrams(toSend) { [weak self] error in
                    if let error = error {
                        self?.log("UDP write error: \(error.localizedDescription)", level: "ERROR")
                    }
                }
            }

            self.readAndForwardClientUDP(association)
        }
    }

    private func readAndForwardRelayUDP(_ association: UDPAssociation) {
        let clientFlow = association.clientFlow
        association.udpSession.setReadHandler({ [weak self, weak association] datagrams, error in
            guard let self = self, let association = association else { return }

            if let error = error {
                // stop reading the relay but don't close the app's flow, let it
                // time out on its own instead of getting a hard EPIPE
                self.log("UDP relay error: \(error.localizedDescription)", level: "ERROR")
                return
            }

            guard let datagrams = datagrams, !datagrams.isEmpty else { return }
            association.touch()

            var payloads: [Data] = []
            var endpoints: [NWEndpoint] = []
            payloads.reserveCapacity(datagrams.count)
            endpoints.reserveCapacity(datagrams.count)

            for datagram in datagrams {
                if let (payload, destHost, destPort) = self.decapsulateSOCKS5UDPWithEndpoint(datagram: datagram, association: association) {
                    payloads.append(payload)
                    endpoints.append(NWHostEndpoint(hostname: destHost, port: String(destPort)))
                }
            }

            if !payloads.isEmpty {
                clientFlow.writeDatagrams(payloads, sentBy: endpoints) { [weak self] error in
                    if let error = error {
                        self?.log("UDP response write error: \(error.localizedDescription)", level: "ERROR")
                    }
                }
            }
        }, maxDatagrams: 32)
    }
    
    // the socks5 udp request header for one destination, the payload follows it
    private func socks5UDPHeader(destHost: String, destPort: UInt16) -> Data? {
        var header = Data()
        header.append(contentsOf: [0, 0])
        header.append(0x00)
        
        if let ipv4 = IPv4Address(destHost) {
            header.append(0x01)
            header.append(contentsOf: ipv4.rawValue)
        } else if let ipv6 = IPv6Address(destHost) {
            header.append(0x04)
            header.append(contentsOf: ipv6.rawValue)
        } else {
            // length prefix must be the utf8 byte count, not the character count
            let hostBytes = Array(destHost.utf8)
            guard hostBytes.count <= 255 else {
                self.log("Domain name too long: \(hostBytes.count) bytes", level: "ERROR")
                return nil
            }
            header.append(0x03)
            header.append(UInt8(hostBytes.count))
            header.append(contentsOf: hostBytes)
        }
        
        header.append(UInt8(destPort >> 8))
        header.append(UInt8(destPort & 0xFF))
        return header
    }
    
    private func decapsulateSOCKS5UDPWithEndpoint(datagram: Data, association: UDPAssociation) -> (Data, String, UInt16)? {
        guard datagram.count > 10 else { return nil }

        // byte 2 is FRAG, we don't reassemble so drop any fragmented datagram
        guard datagram[2] == 0x00 else { return nil }

        let atyp = datagram[3]
        var headerLen = 4
        var destHost = ""
        var destPort: UInt16 = 0

        if atyp == 0x01 {
            // ipv4 is 4 bytes + 2 port, already covered by count > 10. the dotted
            // string is cached by the raw 6 bytes, a flow talks to few peers
            let raw = (UInt64(datagram[4]) << 40) | (UInt64(datagram[5]) << 32) | (UInt64(datagram[6]) << 24)
                | (UInt64(datagram[7]) << 16) | (UInt64(datagram[8]) << 8) | UInt64(datagram[9])
            if let hit = association.endpointCache[raw] {
                destHost = hit.host
                destPort = hit.port
            } else {
                destHost = "\(datagram[4]).\(datagram[5]).\(datagram[6]).\(datagram[7])"
                destPort = (UInt16(datagram[8]) << 8) | UInt16(datagram[9])
                if association.endpointCache.count < UDPAssociation.cacheLimit {
                    association.endpointCache[raw] = (destHost, destPort)
                }
            }
            headerLen += 6
        } else if atyp == 0x04 {
            // ipv6 needs 16 bytes + 2 port
            guard datagram.count >= 22 else { return nil }
            var ipv6Parts: [String] = []
            for i in 0..<8 {
                let idx = 4 + (i * 2)
                let part = (UInt16(datagram[idx]) << 8) | UInt16(datagram[idx+1])
                ipv6Parts.append(String(format: "%x", part))
            }
            destHost = ipv6Parts.joined(separator: ":")
            destPort = (UInt16(datagram[20]) << 8) | UInt16(datagram[21])
            headerLen += 18
        } else if atyp == 0x03 {
            // byte 4 is the domain length, then the domain, then 2 port bytes
            guard datagram.count >= 6 else { return nil }
            let domainLen = Int(datagram[4])
            guard datagram.count >= 5 + domainLen + 2 else { return nil }
            destHost = String(data: datagram[5..<(5+domainLen)], encoding: .utf8) ?? "unknown"
            destPort = (UInt16(datagram[5+domainLen]) << 8) | UInt16(datagram[5+domainLen+1])
            headerLen += 1 + domainLen + 2
        } else {
            return nil
        }

        guard datagram.count > headerLen else { return nil }

        let payload = datagram[headerLen...]
        return (Data(payload), destHost, destPort)
    }
    
    // how long a DNS answer stays good enough to name a destination for the proxy
    private static let dnsNameMaxAge: TimeInterval = 300

    // a connection walks through the proxies of a chain, one after the other.
    // the last hop is the one that talks to the destination, the hops before it
    // are asked to open a tunnel to the next proxy.
    private func proxyTCPFlow(_ flow: NEAppProxyTCPFlow, destination originalDestination: String, displayDestination: String, port: UInt16, process: String, hops: [StoredProxyConfig]) {
        guard let first = hops.first else {
            log("A chain has no proxy in it", level: "ERROR")
            flow.closeReadWithError(FlowFailure.refused)
            flow.closeWriteWithError(FlowFailure.refused)
            return
        }
        let proxyEndpoint = NWHostEndpoint(hostname: first.host, port: String(first.port))
        let proxyConnection = createTCPConnection(to: proxyEndpoint, enableTLS: false, tlsParameters: nil, delegate: nil)
        armHandshakeTimeout(flow: flow, connection: proxyConnection)
        // remember what this flow is, so the relay can register it as a live connection later
        setFlowDescriptor(FlowDescriptor(process: process, destination: displayDestination, port: port, proxy: chainLabel(hops)), for: proxyConnection)
        connectHop(flow: flow, proxyConnection: proxyConnection, hops: hops, index: 0, destination: originalDestination, port: port)
    }

    // the handshake with one hop of the chain. the tunnel it opens is either the
    // way to the next proxy or, for the last hop, the way to the destination.
    private func connectHop(flow: NEAppProxyTCPFlow, proxyConnection: NWTCPConnection, hops: [StoredProxyConfig], index: Int, destination: String, port: UInt16) {
        guard index < hops.count else { return }
        let config = hops[index]
        let isLast = index == hops.count - 1

        // what this hop is asked to reach
        var targetHost = destination
        var targetPort = port
        if isLast {
            // "let proxy resolve DNS", per proxy like the windows app: when the app
            // resolved this address through our DNS proxy, ask the proxy for the name
            // (socks5 domain address / CONNECT host:port) and fall back to the ip
            if IPv4Address(destination) != nil || IPv6Address(destination) != nil,
               let name = DNSMapStore.shared.latestDomain(forIP: destination, maxAge: AppProxyProvider.dnsNameMaxAge) {
                // the DNS policy has the last word: in local mode the proxy server
                // must not resolve names, in remote mode it must, and leak protection
                // forces the name even when the proxy's own setting says otherwise
                let addressing = DNSPolicyStore.shared.policy.addressing(for: name)
                let sendName: Bool
                switch addressing {
                case .some(.hostname): sendName = true
                case .some(.address): sendName = false
                case .none: sendName = config.sendDomain
                }
                if sendName {
                    targetHost = name
                }
            }
        } else {
            // an intermediate hop is asked to open a tunnel to the next proxy.
            // the name goes over as it is, so the hop resolves it.
            let next = hops[index + 1]
            targetHost = next.host
            targetPort = UInt16(clamping: next.port)
        }

        // the tunnel is open: keep walking the chain, or start the relay
        let onEstablished: (Data?) -> Void = { [weak self] leftover in
            guard let self = self else { return }
            if index + 1 < hops.count {
                // only a socks5 proxy may sit in the middle of a chain, so there
                // is never a leftover to carry over
                self.connectHop(flow: flow, proxyConnection: proxyConnection, hops: hops, index: index + 1, destination: destination, port: port)
            } else {
                self.relayData(clientFlow: flow, proxyConnection: proxyConnection, initialData: leftover)
            }
        }

        switch config.type.lowercased() {
        case "socks5":
            handleSOCKS5Proxy(clientFlow: flow, proxyConnection: proxyConnection, destination: targetHost, port: targetPort, username: config.username, password: config.password, onEstablished: onEstablished)
        case "socks4":
            handleSOCKS4Proxy(clientFlow: flow, proxyConnection: proxyConnection, destination: targetHost, port: targetPort, username: config.username, onEstablished: onEstablished)
        case "http":
            handleHTTPProxy(clientFlow: flow, proxyConnection: proxyConnection, destination: targetHost, port: targetPort, username: config.username, password: config.password, onEstablished: onEstablished)
        default:
            log("unsupported proxy type: \(config.type)", level: "ERROR")
            flow.closeReadWithError(FlowFailure.refused)
            flow.closeWriteWithError(FlowFailure.refused)
        }
    }
    
    // SOCKS4 and SOCKS4a. there is no method negotiation, only a user id in
    // the request, and the reply is eight bytes.
    private func handleSOCKS4Proxy(clientFlow: NEAppProxyTCPFlow, proxyConnection: NWTCPConnection, destination: String, port: UInt16, username: String?, onEstablished: ((Data?) -> Void)? = nil) {
        guard let request = Socks4Request.build(destination: destination, port: port, username: username) else {
            log("SOCKS4 cannot ask for \(destination)", level: "ERROR")
            closeRelay(clientFlow, proxyConnection, error: FlowFailure.refused)
            return
        }

        proxyConnection.write(request) { [weak self] error in
            if let error = error {
                self?.log("SOCKS4 request write failed: \(error.localizedDescription)", level: "ERROR")
                self?.closeRelay(clientFlow, proxyConnection, error: FlowFailure.proxyUnreachable)
                return
            }

            proxyConnection.readMinimumLength(8, maximumLength: 8) { [weak self] data, error in
                guard let self = self else { return }

                if let error = error {
                    self.log("SOCKS4 reply failed: \(error.localizedDescription)", level: "ERROR")
                    self.closeRelay(clientFlow, proxyConnection, error: FlowFailure.proxyUnreachable)
                    return
                }

                guard let data = data, data.count == 8 else {
                    self.log("SOCKS4 invalid reply", level: "ERROR")
                    self.closeRelay(clientFlow, proxyConnection, error: FlowFailure.proxyUnreachable)
                    return
                }

                if Socks4Request.isGranted(data) {
                    if let onEstablished = onEstablished {
                        onEstablished(nil)
                    } else {
                        self.relayData(clientFlow: clientFlow, proxyConnection: proxyConnection)
                    }
                } else {
                    self.log("SOCKS4 connect rejected (\(Socks4Request.reason(data)))", level: "ERROR")
                    self.closeRelay(clientFlow, proxyConnection, error: FlowFailure.refused)
                }
            }
        }
    }

    private func handleSOCKS5Proxy(clientFlow: NEAppProxyTCPFlow, proxyConnection: NWTCPConnection, destination: String, port: UInt16, username: String?, password: String?, onEstablished: ((Data?) -> Void)? = nil) {
        var greeting: [UInt8]
        if username != nil && password != nil {
            greeting = [0x05, 0x02, 0x00, 0x02]
        } else {
            greeting = [0x05, 0x01, 0x00]
        }
        
        let greetingData = Data(greeting)
        proxyConnection.write(greetingData) { [weak self] error in
            if let error = error {
                self?.log("SOCKS5 greeting write failed: \(error.localizedDescription)", level: "ERROR")
                self?.closeRelay(clientFlow, proxyConnection, error: FlowFailure.proxyUnreachable)
                return
            }
            
            proxyConnection.readMinimumLength(2, maximumLength: 2) { [weak self] data, error in
                guard let self = self else { return }
                
                if let error = error {
                    self.log("SOCKS5 greeting response failed: \(error.localizedDescription)", level: "ERROR")
                    self.closeRelay(clientFlow, proxyConnection, error: FlowFailure.proxyUnreachable)
                    return
                }
                
                guard let data = data, data.count == 2 else {
                    self.log("SOCKS5 invalid greeting response", level: "ERROR")
                    self.closeRelay(clientFlow, proxyConnection, error: FlowFailure.proxyUnreachable)
                    return
                }
                
                let version = data[0]
                let method = data[1]
                
                if version != 0x05 {
                    self.log("SOCKS5 invalid version: \(version)", level: "ERROR")
                    self.closeRelay(clientFlow, proxyConnection, error: FlowFailure.proxyUnreachable)
                    return
                }
                
                if method == 0x00 {
                    self.sendSOCKS5ConnectRequest(clientFlow: clientFlow, proxyConnection: proxyConnection, destination: destination, port: port, onEstablished: onEstablished)
                } else if method == 0x02 {
                    self.sendSOCKS5Auth(clientFlow: clientFlow, proxyConnection: proxyConnection, destination: destination, port: port, username: username ?? "", password: password ?? "", onEstablished: onEstablished)
                } else {
                    self.log("SOCKS5 no acceptable auth method: \(method)", level: "ERROR")
                    self.closeRelay(clientFlow, proxyConnection, error: FlowFailure.refused)
                }
            }
        }
    }
    
    private func sendSOCKS5Auth(clientFlow: NEAppProxyTCPFlow, proxyConnection: NWTCPConnection, destination: String, port: UInt16, username: String, password: String, onEstablished: ((Data?) -> Void)? = nil) {
        let user = Array(username.utf8), pass = Array(password.utf8)
        guard user.count <= 255, pass.count <= 255 else {
            log("SOCKS5 credentials too long", level: "ERROR")
            closeRelay(clientFlow, proxyConnection, error: FlowFailure.refused)
            return
        }
        var authData = Data()
        authData.append(0x01)
        authData.append(UInt8(user.count))
        authData.append(contentsOf: user)
        authData.append(UInt8(pass.count))
        authData.append(contentsOf: pass)
        
        proxyConnection.write(authData) { [weak self] error in
            if let error = error {
                self?.log("SOCKS5 auth write failed: \(error.localizedDescription)", level: "ERROR")
                self?.closeRelay(clientFlow, proxyConnection, error: FlowFailure.proxyUnreachable)
                return
            }
            
            proxyConnection.readMinimumLength(2, maximumLength: 2) { [weak self] data, error in
                guard let self = self else { return }
                
                if let error = error {
                    self.log("SOCKS5 auth response failed: \(error.localizedDescription)", level: "ERROR")
                    self.closeRelay(clientFlow, proxyConnection, error: FlowFailure.proxyUnreachable)
                    return
                }
                
                guard let data = data, data.count == 2, data[1] == 0x00 else {
                    self.log("SOCKS5 auth failed", level: "ERROR")
                    self.closeRelay(clientFlow, proxyConnection, error: FlowFailure.refused)
                    return
                }
                
                self.sendSOCKS5ConnectRequest(clientFlow: clientFlow, proxyConnection: proxyConnection, destination: destination, port: port, onEstablished: onEstablished)
            }
        }
    }
    
    private func sendSOCKS5ConnectRequest(clientFlow: NEAppProxyTCPFlow, proxyConnection: NWTCPConnection, destination: String, port: UInt16, onEstablished: ((Data?) -> Void)? = nil) {
        var request = Data()
        request.append(0x05)
        request.append(0x01)
        request.append(0x00)
        
        if let ipAddr = IPv4Address(destination) {
            request.append(0x01)
            request.append(contentsOf: ipAddr.rawValue)
        } else if let ipAddr = IPv6Address(destination) {
            request.append(0x04)
            request.append(contentsOf: ipAddr.rawValue)
        } else {
            let hostBytes = Array(destination.utf8)
            guard hostBytes.count <= 255 else {
                log("SOCKS5 destination name too long", level: "ERROR")
                closeRelay(clientFlow, proxyConnection, error: FlowFailure.refused)
                return
            }
            request.append(0x03)
            request.append(UInt8(hostBytes.count))
            request.append(contentsOf: hostBytes)
        }
        
        request.append(UInt8(port >> 8))
        request.append(UInt8(port & 0xFF))
        
        proxyConnection.write(request) { [weak self] error in
            if let error = error {
                self?.log("SOCKS5 connect write failed: \(error.localizedDescription)", level: "ERROR")
                self?.closeRelay(clientFlow, proxyConnection, error: FlowFailure.proxyUnreachable)
                return
            }
            
            self?.readSOCKS5Reply(proxyConnection) { [weak self] reply in
                guard let self = self else { return }
                switch reply {
                case .success:
                    if let onEstablished = onEstablished {
                        onEstablished(nil)
                    } else {
                        self.relayData(clientFlow: clientFlow, proxyConnection: proxyConnection)
                    }
                case .rejected(let rep):
                    self.log("SOCKS5 connect rejected, REP=0x\(String(format: "%02x", rep)) (\(self.socksReplyReason(rep)))", level: "ERROR")
                    self.closeRelay(clientFlow, proxyConnection, error: FlowFailure.socks(rep))
                case .failed(let reason):
                    self.log("SOCKS5 connect failed: \(reason)", level: "ERROR")
                    self.closeRelay(clientFlow, proxyConnection, error: FlowFailure.proxyUnreachable)
                }
            }
        }
    }
    
    private func handleHTTPProxy(clientFlow: NEAppProxyTCPFlow, proxyConnection: NWTCPConnection, destination: String, port: UInt16, username: String?, password: String?, onEstablished: ((Data?) -> Void)? = nil) {
        // ipv6 literals must be bracketed in the request line and Host header
        let host = IPv6Address(destination) != nil ? "[\(destination)]" : destination
        var request = "CONNECT \(host):\(port) HTTP/1.1\r\n"
        request += "Host: \(host):\(port)\r\n"
        
        if let username = username, let password = password {
            let credentials = "\(username):\(password)"
            if let credData = credentials.data(using: .utf8) {
                let base64Creds = credData.base64EncodedString()
                request += "Proxy-Authorization: Basic \(base64Creds)\r\n"
            }
        }
        
        request += "\r\n"
        
        guard let requestData = request.data(using: .utf8) else {
            log("HTTP CONNECT request encoding failed", level: "ERROR")
            closeRelay(clientFlow, proxyConnection, error: FlowFailure.refused)
            return
        }
        
        proxyConnection.write(requestData) { [weak self] error in
            if let error = error {
                self?.log("HTTP CONNECT write failed: \(error.localizedDescription)", level: "ERROR")
                self?.closeRelay(clientFlow, proxyConnection, error: FlowFailure.proxyUnreachable)
                return
            }
            
            self?.readHTTPConnectResponse(proxyConnection) { [weak self] status, leftover, detail in
                guard let self = self else { return }
                // any 2xx opens the tunnel, a "200" somewhere else in the reply
                // (407 with Content-Length: 200) used to count as success
                if let status = status, (200...299).contains(status) {
                    if let onEstablished = onEstablished {
                        onEstablished(leftover)
                    } else {
                        self.relayData(clientFlow: clientFlow, proxyConnection: proxyConnection, initialData: leftover)
                    }
                } else {
                    self.log("HTTP CONNECT failed: \(detail)", level: "ERROR")
                    self.closeRelay(clientFlow, proxyConnection, error: FlowFailure.http(status))
                }
            }
        }
    }
    
    private func relayData(clientFlow: NEAppProxyTCPFlow, proxyConnection: NWTCPConnection, initialData: Data? = nil) {
        guard completeHandshake(proxyConnection) else { return }
        // the channel is live now: register it so the app can list it and terminate it
        registerLiveTCPFlow(clientFlow: clientFlow, proxyConnection: proxyConnection)
        clientFlow.open(withLocalEndpoint: nil) { [weak self] error in
            if let error = error {
                self?.log("Failed to open client flow: \(error.localizedDescription)", level: "ERROR")
                self?.closeRelay(clientFlow, proxyConnection, error: error)
                return
            }
            
            self?.relayClientToProxy(clientFlow: clientFlow, proxyConnection: proxyConnection)
            // bytes the proxy sent right behind its reply are the start of the
            // server's data, deliver them before the normal relay takes over
            if let initial = initialData, !initial.isEmpty {
                clientFlow.write(initial) { [weak self] error in
                    if let error = error {
                        self?.log("Client write error: \(error.localizedDescription)", level: "ERROR")
                        self?.closeRelay(clientFlow, proxyConnection, error: error)
                        return
                    }
                    self?.relayProxyToClient(clientFlow: clientFlow, proxyConnection: proxyConnection)
                }
            } else {
                self?.relayProxyToClient(clientFlow: clientFlow, proxyConnection: proxyConnection)
            }
        }
    }
    
    private func relayClientToProxy(clientFlow: NEAppProxyTCPFlow, proxyConnection: NWTCPConnection) {
        clientFlow.readData { [weak self] data, error in
            if let error = error {
                // ignore expected errors
                let code = (error as NSError).code
                if code != 57 && code != 54 && code != 89 {
                    self?.log("Client read error: \(error.localizedDescription)", level: "ERROR")
                }
                self?.closeRelay(clientFlow, proxyConnection)
                return
            }
            
            guard let data = data, !data.isEmpty else {
                // the client finished sending (FIN). macOS closes the flow in
                // both directions at that point (the system log shows "Closing
                // writes" right after the EOF), so a reply can't be delivered
                // to a client that half-closes. send a FIN upstream so the request
                // is flushed cleanly, then tear down after a short grace instead
                // of cancelling mid-flush.
                proxyConnection.writeClose()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + AppProxyProvider.halfCloseTimeout) { [weak self] in
                    self?.closeRelay(clientFlow, proxyConnection)
                }
                return
            }

            proxyConnection.write(data) { error in
                if let error = error {
                    self?.log("Proxy write error: \(error.localizedDescription)", level: "ERROR")
                    self?.closeRelay(clientFlow, proxyConnection, error: error)
                } else {
                    self?.noteFlowBytes(proxyConnection, up: Int64(data.count), down: 0)
                    self?.relayClientToProxy(clientFlow: clientFlow, proxyConnection: proxyConnection)
                }
            }
        }
    }
    
    private func relayProxyToClient(clientFlow: NEAppProxyTCPFlow, proxyConnection: NWTCPConnection) {
        proxyConnection.readMinimumLength(1, maximumLength: 65536) { [weak self] data, error in
            if let error = error {
                let code = (error as NSError).code
                if code != 57 && code != 54 && code != 89 {
                    self?.log("Proxy read error: \(error.localizedDescription)", level: "ERROR")
                }
                self?.closeRelay(clientFlow, proxyConnection)
                return
            }
            
            guard let data = data, !data.isEmpty else {
                self?.closeRelay(clientFlow, proxyConnection)
                return
            }
            
            clientFlow.write(data) { error in
                if let error = error {
                    self?.log("Client write error: \(error.localizedDescription)", level: "ERROR")
                    self?.closeRelay(clientFlow, proxyConnection, error: error)
                } else {
                    self?.noteFlowBytes(proxyConnection, up: 0, down: Int64(data.count))
                    self?.relayProxyToClient(clientFlow: clientFlow, proxyConnection: proxyConnection)
                }
            }
        }
    }
    
    private func findMatchingRule(bundleId: String, processName: String?, destination: String, port: UInt16, connectionProtocol: RuleProtocol, checkIpPort: Bool, domains: [String] = []) -> ProxyRule? {
        rulesLock.lock()
        let currentRules = rules
        rulesLock.unlock()
        if currentRules.isEmpty { return nil }

        let flowProcess = ProxyRule.FlowProcess(bundleId: bundleId, processName: processName)
        let domainChars = domains.map { (name: $0, chars: Array($0)) }

        var wildcardRule: ProxyRule? = nil

        for (rule, m) in currentRules {
            guard rule.enabled else { continue }

            if rule.ruleProtocol != .both && rule.ruleProtocol != connectionProtocol {
                continue
            }

            if m.processAll {
                if m.hasHostFilter || m.hasPortFilter {
                    // udp has no destination here, so a filtered wildcard can't match
                    if checkIpPort, m.matchesHost(ip: destination, domains: domainChars), m.matchesPort(port) {
                        return rule
                    }
                    continue
                }

                // pure wildcard, keep the first one as a fallback
                if wildcardRule == nil {
                    wildcardRule = rule
                }
                continue
            }

            if m.matchesProcess(flowProcess) {
                if checkIpPort {
                    if m.matchesHost(ip: destination, domains: domainChars) && m.matchesPort(port) {
                        return rule
                    }
                } else {
                    // udp matches on process alone
                    return rule
                }
            }
        }

        return wildcardRule
    }
    
    // the rule that sent the traffic where it went is written with it. a user who
    // asks "why did this go direct" needs the number of the rule, not the name of
    // the proxy alone
    private func sendLogToApp(protocol: String, process: String, destination: String, port: String, proxy: String, rule: UInt32? = nil) {
        // the connection is counted before the switch is looked at: the traffic log can be off
        // while the connection is still made, and the table in the app has to show it either way
        countConnection(proxy: proxy)
        guard trafficLoggingEnabled else { return }
        appendLog(.connection(proto: `protocol`, process: process, destination: destination, port: port, proxy: proxy))
        // the same line in the unified log. the app reads the activity log over the
        // provider channel, and that channel does not open on a build that is not
        // signed by a developer: this is then the only place where the decision the
        // extension made can be seen.
        let proto = `protocol`
        let ruleText = rule.map { " (rule \($0))" } ?? ""
        diag("Connection \(proto) \(process) -> \(destination):\(port) via \(proxy)\(ruleText)")
    }
}


