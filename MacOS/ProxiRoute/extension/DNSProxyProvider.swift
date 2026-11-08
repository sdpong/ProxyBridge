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
            let all = sessions.values
            sessions.removeAll()
            closed = true
            lock.unlock()
            all.forEach { $0.cancel() }
        }
    }

    // what the provider has done so far. the app reads this back from the log,
    // which is the only channel a build that is not signed by a developer has.
    private final class Counters {
        private let lock = NSLock()
        private var queries = 0
        private var answers = 0
        private var namesSeen = Set<String>()
        private var lastName = ""
        private var lastAddresses = ""

        func countQuery() {
            lock.lock(); queries += 1; lock.unlock()
        }

        func countAnswer(name: String, addresses: [String]) {
            lock.lock()
            answers += 1
            namesSeen.insert(name)
            lastName = name
            lastAddresses = addresses.joined(separator: ", ")
            lock.unlock()
        }

        func snapshot() -> (queries: Int, answers: Int, names: Int, lastName: String, lastAddresses: String) {
            lock.lock(); defer { lock.unlock() }
            return (queries, answers, namesSeen.count, lastName, lastAddresses)
        }
    }

    private var flowStates: [ObjectIdentifier: FlowSessions] = [:]
    private let statesLock = NSLock()
    private let counters = Counters()

    override func startProxy(options: [String: Any]?, completionHandler: @escaping (Error?) -> Void) {
        // start with a clean map so old browsing domains don't linger on disk
        DNSMapStore.shared.clear()
        ProviderDiagnostics.note("DNS proxy starting")
        writeStatus(running: true)
        completionHandler(nil)
    }

    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        ProviderDiagnostics.note("DNS proxy stopping: \(ProviderDiagnostics.text(for: reason))")
        writeStatus(running: false)
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

        // The DNS proxy takes every query.
        //
        // What it builds while it does is the ip -> name map, and that map is the
        // only place a host name is known. Without it two things break: a rule
        // that names a host never matches, and the proxy server is given the
        // address instead of the name. An address that only means something on
        // this machine - a local address, or a fake address from a transparent
        // proxy on the network - cannot be used by a server on the other side,
        // so the connection simply fails.
        //
        // The policy says where a query goes, not whether the proxy takes it.
        // Letting the query through used to be the behaviour when no upstream
        // resolver was configured, and it turned every host name rule off
        // without saying anything.

        // the map is what host name rules are matched against, so it has to be
        // filled. the first answers are written to the log, otherwise an empty
        // map looks the same as a provider that never started at all
        DNSProxyProvider.noteAnswers += 1
        if DNSProxyProvider.noteAnswers <= 20 {
            ProviderDiagnostics.note("DNS provider is taking a query")
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

    // how many dns answers were written to the log. the counter is per process,
    // the extension is restarted with every tunnel
    private static var noteAnswers = 0

    // the status line is written at most this often, so a busy resolver does not
    // fill the log with it
    private var lastStatusAt: TimeInterval = 0
    private let statusInterval: TimeInterval = 10

    // writes what the provider is doing, so the app can show it
    private func writeStatus(running: Bool, force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        if !force, now - lastStatusAt < statusInterval { return }
        lastStatusAt = now
        let snapshot = counters.snapshot()
        ProviderDiagnostics.note(DNSStatusWriter.make(running: running,
                                                   queries: snapshot.queries,
                                                   answers: snapshot.answers,
                                                   names: snapshot.names,
                                                   lastName: snapshot.lastName,
                                                   lastAddresses: snapshot.lastAddresses))
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

    // forward one query to its resolver over the flow's shared session
    private func forward(query: Data, to server: NWHostEndpoint, on flow: NEAppProxyUDPFlow, state: FlowSessions) {
        counters.countQuery()

        // the name the query asks for. it decides where the query goes and
        // whether the answer may become a proxy destination
        let name = DNSParser.questionName(query)
        let policy = DNSPolicyStore.shared.policy
        let excluded: Bool
        var target = server
        if let name {
            switch policy.decision(for: name) {
            case .excluded:
                // an excluded name is answered by the resolver the system handed
                // us, so it never reaches a resolver the user configured
                excluded = true
            case .forward(let resolver):
                excluded = false
                if let resolver, let (host, port) = DNSPolicy.normalizeResolver(resolver) {
                    target = NWHostEndpoint(hostname: host, port: String(port))
                }
            }
        } else {
            excluded = false
        }

        let session = state.session(for: target, create: { createUDPSession(to: target, from: nil) }, onNew: { fresh in
            // replies are parsed for the ip -> domain map, then handed back to the app
            fresh.setReadHandler({ [weak self] responses, _ in
                guard let responses = responses else { return }
                for response in responses {
                    if let parsed = DNSParser.parse(response) {
                        // an excluded name must not become a proxy destination, so
                        // it is not recorded at all
                        if !excluded && !DNSPolicyStore.shared.policy.isExcluded(parsed.domain) {
                            DNSMapStore.shared.record(domain: parsed.domain, ips: parsed.ips)
                            self?.counters.countAnswer(name: parsed.domain, addresses: parsed.ips)
                            if DNSProxyProvider.noteAnswers <= 20 {
                                ProviderDiagnostics.note("DNS answer: \(parsed.domain) -> \(parsed.ips.joined(separator: ", "))")
                            }
                        }
                    }
                }
                flow.writeDatagrams(responses, sentBy: [NWEndpoint](repeating: server, count: responses.count)) { _ in }
                self?.writeStatus(running: true)
            }, maxDatagrams: 16)
        })
        session?.writeDatagram(query) { _ in }
    }
}
