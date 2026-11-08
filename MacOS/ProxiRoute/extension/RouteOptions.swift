import Foundation

// How the traffic is routed.
//
// The rules are the normal way: every flow is matched against the rule list
// and the rule that matches decides where the traffic goes. The options here
// are the two switches that sit above the rules.
//
// They are kept apart from the rules on purpose: a rule is a statement about
// a program, a host or a port, and the user may have dozens of them. These
// are one statement about the whole machine, and they are what a "routing
// mode" is: everything goes one way, no matter what the rules say.
struct RouteOptions: Equatable {

    // everything goes to this proxy, the rules are not looked at.
    // "DIRECT" is a proxy id as well: it means everything goes out directly.
    var globalMode = false
    var globalProxyId = "DIRECT"

    // the name of the interface the traffic has to leave through ("en0",
    // "en1", ...). empty means the system decides, which is what it did
    // before this option existed.
    var outboundInterface = ""

    // whether udp is allowed to go through a proxy. it is on by default:
    // a rule that names a socks5 proxy means the udp of that program too.
    var proxyUDP = true

    // whether the traffic of the local network stays local. a proxy on the
    // internet cannot answer for a server on this network, and a program that
    // asks the nameserver of the local router would wait for an answer that
    // never comes. it is on by default, and the rules still decide: a rule
    // that names a program says where that program goes.
    var localNetworkDirect = true

    static let `default` = RouteOptions()

    init() {}

    init(globalMode: Bool, globalProxyId: String, outboundInterface: String, proxyUDP: Bool, localNetworkDirect: Bool = true) {
        self.globalMode = globalMode
        self.globalProxyId = globalProxyId
        self.outboundInterface = outboundInterface
        self.proxyUDP = proxyUDP
        self.localNetworkDirect = localNetworkDirect
    }

    // the wire form the app sends the options in
    func toDictionary() -> [String: Any] {
        return [
            "globalMode": globalMode,
            "globalProxyId": globalProxyId,
            "outboundInterface": outboundInterface,
            "proxyUDP": proxyUDP,
            "localNetworkDirect": localNetworkDirect
        ]
    }

    // what the app sent. a payload from an older build has none of these
    // keys, and then the defaults are used: the rules decide, and the
    // system picks the interface.
    static func fromDictionary(_ dict: [String: Any]) -> RouteOptions {
        var options = RouteOptions()
        options.globalMode = dict["globalMode"] as? Bool ?? false
        options.globalProxyId = dict["globalProxyId"] as? String ?? "DIRECT"
        options.outboundInterface = dict["outboundInterface"] as? String ?? ""
        options.proxyUDP = dict["proxyUDP"] as? Bool ?? true
        options.localNetworkDirect = dict["localNetworkDirect"] as? Bool ?? true
        return options
    }
}
