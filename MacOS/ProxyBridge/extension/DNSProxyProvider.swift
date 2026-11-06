import NetworkExtension

// Intercepts system DNS, forwards each query to the real resolver, and records
// the resulting IP -> domain mapping so the transparent proxy can match rules by
// domain. DoH/DoT that an app does itself is not visible here (by design).
//
// The policy decides what happens to a name: which resolver answers it, whether
// the answer may become a proxy destination at all, and whether the proxy server
// is the one that resolves the name.
class DNSProxyProvider: NEDNSProxyProvider {
    // one udp session per (flow, resolver), reused for every query on that flow.
    // the system resolver keeps a handful of long-lived flows, so this replaces a
    // socket per query with a few sockets total
    private final class FlowSessions {
        private var sessions: [String: NWUDPSession] = [:]
        private let lock = NSLock()
        private var closed = false

        func session(for server: NWHostEndpoint, create: () -> NWUDPSession, onNew: (NWUDPSession) -> Void) -> NWUDPSession? {
            let key = "\(server.hostname):\(server.port)"
            lock.lock()
            defer { lock.unlock() }
            if closed { return nil }
            if let existing = sessions[key], existing.state == .ready || existing.state == .preparing || existing.state == .waiting {
                return existing
            }
            sessions[key]?.cancel()
            let fresh = create()
            sessions[key] = fresh
            onNew(fresh)
            return fresh
        }

        func closeAll() {
            lock.lock()
            closed = true
            let all = sessions.values
            sessions.removeAll()
            lock.unlock()
            all.forEach { $0.cancel() }
        }
    }

    private var flowStates: [ObjectIdentifier: FlowSessions] = [:]
    private let statesLock = NSLock()

    override func startProxy(options: [String: Any]?, completionHandler: @escaping (Error?) -> Void) {
        // start with a clean map so old browsing domains don't linger on disk
        DNSMapStore.shared.clear()
        ProviderDiagnostics.note("DNS proxy starting")
        completionHandler(nil)
    }

    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        ProviderDiagnostics.note("DNS proxy stopping: \(ProviderDiagnostics.text(for: reason))")
        statesLock.lock()
        let all = Array(flowStates.values)
        flowStates.removeAll()
        statesLock.unlock()
        all.forEach { $0.closeAll() }
        DNSMapStore.shared.clear()
        completionHandler()
    }

    // the policy reaches this provider through the shared container: a DNS proxy
    // provider has no session that can carry a provider message, so the
    // transparent proxy provider publishes it there and this one reads it back.
    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        // only proxy udp dns, let tcp dns (large responses) pass through untouched
        guard let udp = flow as? NEAppProxyUDPFlow else { return false }
        // with auto detect switched off and no resolver configured there is
        // nowhere to send the query, so leave dns alone and let macOS resolve it
        let policy = DNSPolicyStore.shared.policy
        if !policy.autoDetectUpstream && policy.upstreamResolvers.isEmpty {
            return false
        }
        udp.open(withLocalEndpoint: nil) { [weak self] error in
            guard error == nil, let self = self else {
                udp.closeReadWithError(error)
                udp.closeWriteWithError(error)
                return
            }
            let state = FlowSessions()
            self.statesLock.lock()
            self.flowStates[ObjectIdentifier(udp)] = state
            self.statesLock.unlock()
            self.readQueries(udp, state)
        }
        return true
    }

    private func finish(_ flow: NEAppProxyUDPFlow, _ state: FlowSessions) {
        statesLock.lock()
        flowStates.removeValue(forKey: ObjectIdentifier(flow))
        statesLock.unlock()
        state.closeAll()
        flow.closeReadWithError(nil)
        flow.closeWriteWithError(nil)
    }

    private func readQueries(_ flow: NEAppProxyUDPFlow, _ state: FlowSessions) {
        flow.readDatagrams { [weak self] datagrams, endpoints, error in
            guard let self = self else { return }

            guard error == nil, let datagrams = datagrams, let endpoints = endpoints, !datagrams.isEmpty else {
                self.finish(flow, state)
                return
            }

            for i in 0..<min(datagrams.count, endpoints.count) {
                guard let server = endpoints[i] as? NWHostEndpoint else { continue }
                self.forward(query: datagrams[i], to: server, on: flow, state: state)
            }

            self.readQueries(flow, state)
        }
    }

    // the resolver the query is actually sent to. it may be a configured
    // upstream instead of the one the app asked, but the answer still has to
    // look like it came from the server the app asked, or the app drops it.
    private func upstreamEndpoint() -> NWHostEndpoint? {
        let policy = DNSPolicyStore.shared.policy
        for raw in policy.upstreamResolvers {
            if let (host, port) = DNSPolicy.normalizeResolver(raw) {
                return NWHostEndpoint(hostname: host, port: String(port))
            }
        }
        return nil
    }

    // forward one query to its resolver over the flow's shared session
    private func forward(query: Data, to server: NWHostEndpoint, on flow: NEAppProxyUDPFlow, state: FlowSessions) {
        let target = upstreamEndpoint() ?? server
        let session = state.session(for: target, create: { createUDPSession(to: target, from: nil) }, onNew: { fresh in
            // replies are parsed for the ip -> domain map, then handed back to the app
            fresh.setReadHandler({ responses, _ in
                guard let responses = responses else { return }
                for response in responses {
                    if let parsed = DNSParser.parse(response) {
                        // an excluded name must not become a proxy destination, so
                        // it is not recorded at all
                        if !DNSPolicyStore.shared.policy.isExcluded(parsed.domain) {
                            DNSMapStore.shared.record(domain: parsed.domain, ips: parsed.ips)
                        }
                    }
                }
                flow.writeDatagrams(responses, sentBy: [NWEndpoint](repeating: server, count: responses.count)) { _ in }
            }, maxDatagrams: 16)
        })
        session?.writeDatagram(query) { _ in }
    }
}
