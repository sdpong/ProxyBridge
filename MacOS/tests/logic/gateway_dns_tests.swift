import Foundation

// The dns of the clients of the gateway.
//
// The names the clients look up are learned from the answers of the
// resolvers, and the rules that name a host can match their traffic only
// because of that. These are the parts of it that can be checked without a
// root and without a machine that is really the gateway of a network.

func check(_ condition: Bool, _ what: String) {
    if condition {
        print("  ok   \(what)")
    } else {
        print("  FAIL \(what)")
        exit(1)
    }
}

setvbuf(stdout, nil, _IONBF, 0)

print("gateway dns tests:")

// ---------------------------------------------------------------- the answers

// a dns header: id, flags and the four counters
func header(id: UInt16, flags: UInt16, qd: UInt16, an: UInt16) -> [UInt8] {
    return [
        UInt8(id >> 8), UInt8(id & 0xFF),
        UInt8(flags >> 8), UInt8(flags & 0xFF),
        UInt8(qd >> 8), UInt8(qd & 0xFF),
        UInt8(an >> 8), UInt8(an & 0xFF),
        0, 0, 0, 0
    ]
}

// a name in the wire form: length prefixed labels and a zero byte
func wireName(_ name: String) -> [UInt8] {
    var out: [UInt8] = []
    for label in name.split(separator: ".") {
        out.append(UInt8(label.count))
        out.append(contentsOf: Array(label.utf8))
    }
    out.append(0)
    return out
}

// an answer that says the name belongs to the address
func answer(_ name: String, _ ipv4: String) -> Data {
    var bytes = header(id: 0x1234, flags: 0x8180, qd: 1, an: 1)
    bytes += wireName(name)
    bytes += [0x00, 0x01, 0x00, 0x01]
    bytes += [0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x3C, 0x00, 0x04]
    bytes += ipv4.split(separator: ".").compactMap { UInt8($0) }
    return Data(bytes)
}

// a query is not an answer
func query(_ name: String) -> Data {
    var bytes = header(id: 0x1234, flags: 0x0100, qd: 1, an: 0)
    bytes += wireName(name)
    bytes += [0x00, 0x01, 0x00, 0x01]
    return Data(bytes)
}

print("the answers of the resolvers:")

// the answer of a resolver is remembered
let recorded = GatewayDNS.record(answer: answer("www.google.com", "142.250.185.78"))
check(recorded?.domain == "www.google.com", "the answer names the place")
check(recorded?.ips == ["142.250.185.78"], "the answer carries the address")

// and the address is known by the name afterwards
check(GatewayDNS.names(for: "142.250.185.78") == ["www.google.com"],
      "the address is known by the name of the answer")
check(GatewayDNS.proxyName(for: "142.250.185.78") == "www.google.com",
      "the proxy server is asked for the name")

// an address that was never in an answer is unknown
check(GatewayDNS.names(for: "203.0.113.7").isEmpty, "an address that was never in an answer is unknown")

// a query is not an answer and is not remembered
check(GatewayDNS.record(answer: query("www.example.com")) == nil, "a query is not an answer")
check(GatewayDNS.names(for: "203.0.113.8").isEmpty, "a query is not remembered")

// ---------------------------------------------------------------- the rules

print("the rules can match the name:")

// a proxy of the app, as the engine reads it
let proxy = ProxyEndpoint(id: "108", name: "Local socks5", type: "socks5",
                           host: "127.0.0.1", port: 9991,
                           username: nil, password: nil)

// a rule that names a host, the way the rules of the app are written
let byHost = EngineRule(action: "108", hosts: ["*.google.com"], ports: [])

// without the name the rule does not match the address
let withoutName = GatewayDataPlane.plan(rules: [byHost], proxies: [proxy], chains: [:],
                                         originalAddress: "142.250.185.78", originalPort: 443)
check(withoutName.upstream == .direct,
      "a rule that names a host does not match an address that has no name")

// with the name the rule matches
let withName = GatewayDataPlane.plan(rules: [byHost], proxies: [proxy], chains: [:],
                                     originalAddress: "142.250.185.78", originalPort: 443,
                                     names: ["www.google.com"])
check(withName.upstream == .proxy(proxy),
      "a rule that names a host matches a traffic that has the name")

// and the proxy server is asked for the name, so that it resolves it itself
check(withName.target.proxyHost == "www.google.com", "the proxy server is asked for the name")
check(withName.target.address == "142.250.185.78", "the address is still known")

// a traffic that goes straight out goes to the address: a name that has gone
// stale would take it to the wrong place
check(withName.target.directHost == "142.250.185.78", "a traffic that goes straight out goes to the address")

// ---------------------------------------------------------------- many names

print("one address may serve many names:")

// two answers for the same address, the second one is the freshest
_ = GatewayDNS.record(answer: answer("www.google.com", "142.250.186.78"))
_ = GatewayDNS.record(answer: answer("fonts.googleapis.com", "142.250.186.78"))

let names = GatewayDNS.names(for: "142.250.186.78")
check(names.contains("www.google.com"), "the first name of the address is kept")
check(names.contains("fonts.googleapis.com"), "the second name of the address is kept")
check(GatewayDNS.proxyName(for: "142.250.186.78") == "fonts.googleapis.com",
      "the freshest name is the one the proxy server is asked for")

// a rule that names any of them matches
let byOther = EngineRule(action: "108", hosts: ["*.googleapis.com"], ports: [])
let byEither = GatewayDataPlane.plan(rules: [byOther], proxies: [proxy], chains: [:],
                                     originalAddress: "142.250.186.78", originalPort: 443,
                                     names: names)
check(byEither.upstream == .proxy(proxy),
      "a rule that names one of the names of the address matches it")

// a rule that names none of them does not
let byNothing = EngineRule(action: "108", hosts: ["*.example.com"], ports: [])
let byNeither = GatewayDataPlane.plan(rules: [byNothing], proxies: [proxy], chains: [:],
                                      originalAddress: "142.250.186.78", originalPort: 443,
                                      names: names)
check(byNeither.upstream == .direct,
      "a rule that names none of the names of the address does not match it")

// ---------------------------------------------------------------- the flow of dns

print("the flow of dns:")

check(GatewayDNS.isDNS(port: 53), "the port of a query for a name is the port of dns")
check(!GatewayDNS.isDNS(port: 443), "the port of a web page is not the port of dns")

// ---------------------------------------------------------------- the resolvers

print("the resolvers of the system:")

let resolvConf = """
# Mac OS X
#
# This file is not consulted for DNS hostname resolution.
#
nameserver 202.101.172.35
nameserver 223.5.5.5
nameserver 202.101.172.35
"""
let resolvers = GatewayDNS.resolvers(in: resolvConf)
check(resolvers == ["202.101.172.35", "223.5.5.5"], "the file of the system names the resolvers")
check(GatewayDNS.resolvers(in: "# nothing here\n").isEmpty, "a file with no resolver has none")
check(GatewayDNS.systemResolver() != nil || GatewayDNS.resolvers().isEmpty,
      "the resolver of the system is read")

print("gateway dns tests: ALL PASS")
