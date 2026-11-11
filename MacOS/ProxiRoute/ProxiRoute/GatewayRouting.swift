import Foundation

// Where the traffic of the network goes.
//
// The gateway mode has the same rules as the rest of the app and the same
// switches above them, and it reads them the same way. The extension reads
// them like this:
//
//   let globalAction = route.globalMode ? route.globalProxyId : nil
//   let action = matchedRule?.action ?? globalAction
//
// The rule that matched decides, and the global mode is the answer for the
// traffic that no rule names. This is the same order, and the reason is the
// same: a rule that names a program still decides what that program does,
// because the proxy server on this machine sends its own traffic out and
// handing that traffic back to it would never stop.
//
// The gateway has one thing the extension does not have: the traffic of the
// network has no program behind it. A client of the network is a phone or a
// laptop, and there is no program to name. So a rule that names a program is
// not about that traffic at all, and the gateway skips it.
//
// Everything else is the rules of the app, read the one way every mode reads
// them.
enum GatewayRouting {

    // The switches above the rules, as the gateway reads them.
    //
    // They are the settings of the app, read here so that the gateway does
    // not have to know where they come from.
    struct Options: Equatable {
        // everything goes to this proxy
        var globalMode = false
        // the proxy the global mode sends everything to. "DIRECT" is a proxy
        // of its own: it means everything goes out directly.
        var globalProxyId = "DIRECT"
        // the traffic of the local network stays local
        var localNetworkDirect = true
        // whether udp may go through a proxy
        var proxyUDP = true

        init() {}

        init(_ settings: RouteSettings) {
            globalMode = settings.globalMode
            globalProxyId = settings.globalProxyId
            localNetworkDirect = settings.localNetworkDirect
            proxyUDP = settings.proxyUDP
        }
    }

    // Where one flow goes.
    struct Decision: Equatable {
        let upstream: RuleUpstream
        // why the traffic did not go where it was supposed to go
        let note: String?

        init(upstream: RuleUpstream, note: String? = nil) {
            self.upstream = upstream
            self.note = note
        }
    }

    // The way out of a flow of the network.
    //
    // The rules are read first, and the global mode answers for the traffic
    // that no rule names. The order is the one the extension uses, so that a
    // person who writes a rule sees the same thing in both modes.
    static func decide(rules: [EngineRule],
                       proxies: [ProxyEndpoint],
                       chains: [String: [String]],
                       options: Options,
                       target: FlowTarget) -> Decision {
        let decision = ProxyRuleEngine.decide(rules: rules, target: target,
                                              proxies: proxies, chains: chains)

        // a rule named this traffic: it decides, and the global mode is not
        // looked at
        if decision.action != nil {
            return Decision(upstream: decision.upstream, note: decision.note)
        }

        // no rule named this traffic. the global mode is the answer for it,
        // and without the global mode the traffic goes out directly.
        guard options.globalMode else {
            return Decision(upstream: .direct, note: decision.note)
        }

        // The global mode names a proxy of the app. It may name one that is
        // not in the list any more, and then the traffic goes straight out
        // with a reason, the way a rule that names a proxy that is gone does.
        if options.globalProxyId == "DIRECT" {
            return Decision(upstream: .direct, note: decision.note)
        }
        guard let endpoint = proxies.first(where: { $0.id == options.globalProxyId }) else {
            return Decision(upstream: .direct,
                            note: "The proxy \(options.globalProxyId) is not in the list, the traffic goes straight out")
        }

        // udp may not go through a proxy: it goes out directly.
        //
        // A chain cannot carry a datagram either, and the engine has already
        // said so.
        if target.transport == .udp && !options.proxyUDP {
            return Decision(upstream: .direct, note: decision.note)
        }

        // The traffic of the local network is not part of the global mode: a
        // proxy on the internet cannot answer for a server on this network.
        //
        // The rules still decide - a rule that names this traffic says where
        // it goes - and this is about the traffic that no rule names.
        if options.localNetworkDirect, isLocalNetwork(target.address) {
            return Decision(upstream: .direct, note: decision.note)
        }

        return Decision(upstream: .proxy(endpoint), note: decision.note)
    }

    // Whether the address is on the network of the clients.
    //
    // The clients of the network are on the network of the interface the
    // gateway mode runs on, and the machines they reach by name are on it
    // too: the printer of the office, the screen they cast to, the router
    // that gives out the addresses.
    //
    // The check is about the address the traffic was going to, and it asks
    // the same question the extension asks: is this place on this network or
    // on the network it is in?
    static func isLocalNetwork(_ address: String?) -> Bool {
        guard let address, !address.isEmpty else { return false }
        return LocalAddress.isLocal(address)
    }
}
