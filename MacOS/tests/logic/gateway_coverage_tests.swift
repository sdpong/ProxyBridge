import Foundation

// What the rules of the app cover for the traffic of the network.
//
// The traffic of the network has no program behind it, so a rule that names
// one is not about that traffic. The card of the gateway mode says what is
// covered, because a rule that says TCP and a rule that says nothing at all
// look the same in the list of the rules and mean very different things for a
// client of the network.

func check(_ condition: Bool, _ what: String) {
    if condition {
        print("  ok   \(what)")
    } else {
        print("  FAIL \(what)")
        exit(1)
    }
}

setvbuf(stdout, nil, _IONBF, 0)

print("gateway coverage tests:")

// ---------------------------------------------------------------- what the rules cover

// a rule that names a host covers the traffic of the network
let byHost = EngineRule(action: "108", hosts: ["*.example.com"])
let hostReport = GatewayCoverage.report(rules: [byHost])
check(hostReport.hasClientRules, "a rule that names a host covers the traffic of the network")
check(hostReport.clientRules == 1, "the rule is counted once")
check(hostReport.coversTCP, "a rule that names a host covers the connections")
check(hostReport.coversUDP, "a rule that names a host covers the datagrams as well")

// a rule that names a program covers nothing: a client has no program
let byProgram = EngineRule(action: "108", hosts: [], ports: [], hasProgram: true)
let programReport = GatewayCoverage.report(rules: [byProgram])
check(!programReport.hasClientRules, "a rule that names a program covers nothing")
check(programReport.clientRules == 0, "a rule that names a program is not counted")

// a rule that is turned off covers nothing
let turnedOff = EngineRule(action: "108", hosts: ["*.example.com"], enabled: false)
check(!GatewayCoverage.report(rules: [turnedOff]).hasClientRules,
      "a rule that is turned off covers nothing")

// a rule that says TCP is not about the datagrams
let tcpOnly = EngineRule(action: "108", hosts: ["*.example.com"], protocolMode: "TCP")
let tcpReport = GatewayCoverage.report(rules: [tcpOnly])
check(tcpReport.coversTCP, "a rule that says TCP covers the connections")
check(!tcpReport.coversUDP, "a rule that says TCP does not cover the datagrams")

// a rule that says UDP is not about the connections
let udpOnly = EngineRule(action: "108", hosts: ["*.example.com"], protocolMode: "UDP")
let udpReport = GatewayCoverage.report(rules: [udpOnly])
check(udpReport.coversUDP, "a rule that says UDP covers the datagrams")
check(!udpReport.coversTCP, "a rule that says UDP does not cover the connections")

// a rule that says BOTH covers the two
let both = EngineRule(action: "108", hosts: ["*.example.com"], protocolMode: "BOTH")
let bothReport = GatewayCoverage.report(rules: [both])
check(bothReport.coversTCP && bothReport.coversUDP, "a rule that says BOTH covers the two")

// a rule that says nothing at all is about the tcp of the client
//
// This is the rule that catches the traffic no other rule names, and the
// traffic it catches is the connection of the client. A datagram is a
// different thing.
let catchAll = EngineRule(action: "DIRECT", hosts: [], ports: [], protocolMode: "TCP")
let catchAllReport = GatewayCoverage.report(rules: [catchAll])
check(catchAllReport.coversTCP, "the rule that catches the rest covers the connections")
check(!catchAllReport.coversUDP, "the rule that catches the rest does not cover the datagrams")

// the rules are counted as they are
let mixed = GatewayCoverage.report(rules: [
    byHost,
    byProgram,
    turnedOff,
    tcpOnly,
    udpOnly,
])
check(mixed.clientRules == 3, "the rules that count are counted")
check(mixed.coversTCP && mixed.coversUDP, "the two protocols are told apart")

// no rule at all
let empty = GatewayCoverage.report(rules: [])
check(!empty.hasClientRules, "no rule covers the traffic of the network")

// ---------------------------------------------------------------- what the card says

// the card says nothing when the rules speak about both
check(GatewayCoverage.udpNotice(bothReport) == nil,
      "the card says nothing when a rule speaks about the datagrams")

// the card says something when no rule speaks about the datagrams
check(GatewayCoverage.udpNotice(tcpReport) != nil,
      "the card says something when no rule speaks about the datagrams")

// and what it says mentions the connections as well: the gateway carries
// both, and a person who reads only the notice should not think that the
// connections of the clients are not affected
let notice = GatewayCoverage.udpNotice(tcpReport) ?? ""
check(notice.contains("connections"),
      "the notice says that the connections of the clients are the ones the rules speak about")
check(notice.contains("UDP"),
      "the notice says that the datagrams are the ones no rule speaks about")

// the card says something when no rule speaks about the traffic at all
check(GatewayCoverage.noRulesNotice(programReport) != nil,
      "the card says something when every rule names a program")
check(GatewayCoverage.noRulesNotice(hostReport) == nil,
      "the card says nothing when a rule speaks about the traffic")

// ---------------------------------------------------------------- the proxies

// only a socks5 proxy can carry a datagram
let socks5 = ProxyEndpoint(id: "1", name: "", type: "socks5", host: "127.0.0.1", port: 9991,
                           username: nil, password: nil)
let http = ProxyEndpoint(id: "2", name: "", type: "http", host: "127.0.0.1", port: 8080,
                         username: nil, password: nil)
check(GatewayCoverage.canCarryUDP(socks5), "a socks5 proxy can carry a datagram")
check(!GatewayCoverage.canCarryUDP(http), "an http proxy cannot carry a datagram")

// the card says nothing about a proxy that can carry a datagram
check(GatewayCoverage.proxyNotice(socks5) == nil,
      "the card says nothing about a socks5 proxy")

// the card says something about a proxy that cannot
let proxyNotice = GatewayCoverage.proxyNotice(http) ?? ""
check(!proxyNotice.isEmpty, "the card says something about an http proxy")
check(proxyNotice.contains("SOCKS5"),
      "the notice says that only a socks5 proxy can carry a datagram")

// and nothing about a proxy that is not there
check(GatewayCoverage.proxyNotice(nil) == nil,
      "the card says nothing when no proxy was chosen")

print("gateway coverage tests: ALL PASS")
