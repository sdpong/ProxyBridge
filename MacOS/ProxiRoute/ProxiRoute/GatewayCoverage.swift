import Foundation

// What the rules of the app cover for the traffic of the network.
//
// The traffic of the network is the traffic of the clients of the network,
// and it has no program behind it: a phone has no program to name. So a rule
// that names a program is not about that traffic at all, and a rule that
// names a host, a port or a protocol is.
//
// The card of the gateway mode says what is covered and what is not, because
// a rule that says TCP and a rule that says nothing look the same in the
// list of the rules, and they mean very different things for a client of the
// network.
enum GatewayCoverage {

    // What the rules cover.
    struct Report: Equatable {
        // the rules that can match the traffic of the network
        let clientRules: Int
        // the rules among them that speak about udp
        let udpRules: Int
        // the rules among them that speak about tcp
        let tcpRules: Int

        // Whether the traffic of the network is covered by any rule at all.
        var hasClientRules: Bool { clientRules > 0 }

        // Whether a datagram of the network is covered by any rule.
        //
        // A rule that says TCP is not about a datagram, and a rule that says
        // nothing at all - the rule that catches the traffic no other rule
        // names - is about the tcp of the client and not about its datagram.
        var coversUDP: Bool { udpRules > 0 }

        // Whether a connection of the network is covered by any rule.
        var coversTCP: Bool { tcpRules > 0 }
    }

    // What the rules cover, read the way the gateway reads them.
    //
    // A rule that is turned off covers nothing. A rule that names a program
    // covers nothing either, because the traffic of the network has no
    // program. The rest of them cover the protocol they speak about.
    static func report(rules: [EngineRule]) -> Report {
        var clientRules = 0
        var udpRules = 0
        var tcpRules = 0

        for rule in rules {
            guard rule.enabled else { continue }
            guard !rule.hasProgram else { continue }
            clientRules += 1
            if rule.speaksAbout(.udp) { udpRules += 1 }
            if rule.speaksAbout(.tcp) { tcpRules += 1 }
        }

        return Report(clientRules: clientRules, udpRules: udpRules, tcpRules: tcpRules)
    }

    // Whether a proxy can carry a datagram.
    //
    // Only a socks5 proxy can: the protocol of the others has no way of
    // saying "carry this datagram for me".
    static func canCarryUDP(_ proxy: ProxyEndpoint) -> Bool {
        return proxy.type.lowercased() == "socks5"
    }

    // What the card says about the datagrams of the network.
    //
    // A rule that says TCP is about the connections of the client, and its
    // datagrams - the dns, the quic, the tunnel of a call - are not about it.
    // They go where the global mode sends them, and that is worth saying out
    // loud: a person who writes one rule for a program and then watches the
    // dns of the phone go somewhere else should know why.
    static func udpNotice(_ report: Report) -> String? {
        guard report.hasClientRules, !report.coversUDP else { return nil }
        return L10n.t("None of the rules speaks about UDP, so the datagrams of the clients - the DNS, the QUIC, the tunnels of a call - go where the global mode sends them, and not by a rule. The connections of the clients are the ones the rules speak about.")
    }

    // What the card says when no rule speaks about the traffic of the network
    // at all.
    static func noRulesNotice(_ report: Report) -> String? {
        guard !report.hasClientRules else { return nil }
        return L10n.t("None of the rules speaks about the traffic of the network: every rule names a program, and a client of the network has no program. The traffic goes where the global mode sends it.")
    }

    // What the card says about the proxy the global mode sends the datagrams
    // through.
    //
    // Only a socks5 proxy can carry a datagram. The protocol of an http
    // proxy has no way of saying "carry this datagram for me", so the
    // datagrams of the clients go out directly when that proxy is the one
    // that was chosen.
    static func proxyNotice(_ proxy: ProxyEndpoint?) -> String? {
        guard let proxy else { return nil }
        guard !canCarryUDP(proxy) else { return nil }
        return L10n.f("The datagrams of the clients cannot go through %@: only a SOCKS5 proxy can carry them, so they go out directly.", proxy.label)
    }
}
