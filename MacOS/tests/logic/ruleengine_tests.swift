import Foundation

// The rule engine of the traffic that has no program.
//
// The traffic of another terminal comes in as a connection and nothing else.
// Four things have to be decided the one way in every mode, and this test
// says what they are:
//
//   - a rule that names a program is not about that traffic;
//   - a rule is about one protocol or the other;
//   - a rule that names a chain says so, and the chain is either walked
//     through or the traffic goes straight out with a reason;
//   - a rule that names a host is matched against the name of the host when
//     there is one, and against its address when there is not.
//
// Compiled as main.swift by run.sh.

setvbuf(stdout, nil, _IONBF, 0)

var fails = 0
func check(_ name: String, _ ok: Bool) {
    if ok {
        print("  ok   \(name)")
    } else {
        fails += 1
        print("FAIL \(name)")
    }
}

// MARK: - the things the test plays with

func proxy(_ id: String, _ type: String = "socks5", host: String = "127.0.0.1", port: Int = 1080) -> ProxyEndpoint {
    return ProxyEndpoint(id: id, name: "", type: type, host: host, port: port,
                          username: nil, password: nil)
}

let socks = proxy("p1")
let socks2 = proxy("p2", port: 1081)
let httpProxy = proxy("h1", "http", port: 8080)

// MARK: - a rule that names a program

let withProgram = ProxyRuleEngine.decide(
    rules: [EngineRule(action: "BLOCK", hasProgram: true)],
    target: FlowTarget(name: "example.com", port: 80),
    proxies: [], chains: [:])
check("a rule that names a program is skipped", withProgram.upstream == .direct)
check("a rule that names a program leaves no trace", withProgram.action == nil)

let withProgramFirst = ProxyRuleEngine.decide(
    rules: [EngineRule(action: "BLOCK", hasProgram: true),
            EngineRule(action: "BLOCK", hosts: ["*.example.com"])],
    target: FlowTarget(name: "www.example.com", port: 80),
    proxies: [], chains: [:])
check("the rule after a rule with a program still counts", withProgramFirst.upstream == .blocked)

// MARK: - the protocol of a rule

let tcpRule = EngineRule(action: "BLOCK", hosts: ["*.example.com"], protocolMode: "TCP")
let udpFlow = FlowTarget(name: "www.example.com", port: 53, transport: .udp)
let tcpFlow = FlowTarget(name: "www.example.com", port: 80, transport: .tcp)

check("a rule about TCP does not catch a UDP flow",
      !tcpRule.speaksAbout(udpFlow))
check("a rule about TCP catches a TCP flow",
      tcpRule.speaksAbout(tcpFlow))

let udpRule = EngineRule(action: "BLOCK", hosts: ["*.example.com"], protocolMode: "UDP")
check("a rule about UDP does not catch a TCP flow",
      !udpRule.speaksAbout(tcpFlow))
check("a rule about UDP catches a UDP flow",
      udpRule.speaksAbout(udpFlow))

let bothRule = EngineRule(action: "BLOCK", hosts: ["*.example.com"], protocolMode: "BOTH")
check("a rule about both catches a TCP flow", bothRule.speaksAbout(tcpFlow))
check("a rule about both catches a UDP flow", bothRule.speaksAbout(udpFlow))

let noProtocol = EngineRule(action: "BLOCK", hosts: ["*.example.com"], protocolMode: "")
check("a rule without a protocol speaks about both", noProtocol.speaksAbout(tcpFlow) && noProtocol.speaksAbout(udpFlow))

let decidedByProtocol = ProxyRuleEngine.decide(
    rules: [tcpRule], target: udpFlow, proxies: [], chains: [:])
check("the engine does not use a rule of the other protocol",
      decidedByProtocol.upstream == .direct)

// MARK: - where the host of a rule is compared with

let byName = ProxyRuleEngine.decide(
    rules: [EngineRule(action: "BLOCK", hosts: ["*.example.com"])],
    target: FlowTarget(name: "www.example.com", port: 80),
    proxies: [], chains: [:])
check("a rule that names a host matches the name of the host", byName.upstream == .blocked)

let byAddress = ProxyRuleEngine.decide(
    rules: [EngineRule(action: "BLOCK", hosts: ["93.184.*"])],
    target: FlowTarget(address: "93.184.216.34", port: 443),
    proxies: [], chains: [:])
check("a rule that names an address matches the address of the host", byAddress.upstream == .blocked)

let domainRuleOnAddress = ProxyRuleEngine.decide(
    rules: [EngineRule(action: "BLOCK", hosts: ["*.example.com"])],
    target: FlowTarget(address: "93.184.216.34", port: 443),
    proxies: [], chains: [:])
check("a rule that names a host does not match an address that is not a name",
      domainRuleOnAddress.upstream == .direct)

let addressRuleOnName = ProxyRuleEngine.decide(
    rules: [EngineRule(action: "BLOCK", hosts: ["93.184.*"])],
    target: FlowTarget(name: "www.example.com", port: 443),
    proxies: [], chains: [:])
check("a rule that names an address does not match a name", addressRuleOnName.upstream == .direct)

let bothKnown = ProxyRuleEngine.decide(
    rules: [EngineRule(action: "BLOCK", hosts: ["*.example.com"])],
    target: FlowTarget(name: "www.example.com", address: "93.184.216.34", port: 443),
    proxies: [], chains: [:])
check("a rule that names a host matches when the name is known", bothKnown.upstream == .blocked)

// MARK: - the rules in order

let inOrder = ProxyRuleEngine.decide(
    rules: [EngineRule(action: "BLOCK", hosts: ["*.example.com"]),
            EngineRule(action: "DIRECT")],
    target: FlowTarget(name: "www.example.com", port: 80),
    proxies: [], chains: [:])
check("the first rule that speaks about the flow decides", inOrder.upstream == .blocked)
check("the rule that decided is named", inOrder.action == "BLOCK")

let disabled = ProxyRuleEngine.decide(
    rules: [EngineRule(action: "BLOCK", hosts: ["*.example.com"], enabled: false),
            EngineRule(action: "DIRECT")],
    target: FlowTarget(name: "www.example.com", port: 80),
    proxies: [], chains: [:])
check("a rule that is switched off does not count", disabled.upstream == .direct)

let byPort = ProxyRuleEngine.decide(
    rules: [EngineRule(action: "BLOCK", ports: ["8000-9000"])],
    target: FlowTarget(name: "www.example.com", port: 8443),
    proxies: [], chains: [:])
check("a rule that names a port matches", byPort.upstream == .blocked)

let notByPort = ProxyRuleEngine.decide(
    rules: [EngineRule(action: "BLOCK", ports: ["8000-9000"])],
    target: FlowTarget(name: "www.example.com", port: 443),
    proxies: [], chains: [:])
check("a rule that names another port does not match", notByPort.upstream == .direct)

// MARK: - a rule that points at a proxy

let toProxy = ProxyRuleEngine.decide(
    rules: [EngineRule(action: "p1")],
    target: FlowTarget(name: "www.example.com", port: 80),
    proxies: [socks], chains: [:])
check("a rule that points at a proxy uses that proxy", toProxy.upstream == .proxy(socks))

let toMissingProxy = ProxyRuleEngine.decide(
    rules: [EngineRule(action: "p9")],
    target: FlowTarget(name: "www.example.com", port: 80),
    proxies: [socks], chains: [:])
check("a rule that points at a proxy that is not there goes straight out",
      toMissingProxy.upstream == .direct)
check("a rule that points at a proxy that is not there says so",
      toMissingProxy.note != nil)

// MARK: - a rule that points at a chain

let chains: [String: [String]] = ["c1": ["p1", "p2"]]

let toChain = ProxyRuleEngine.decide(
    rules: [EngineRule(action: "chain:c1")],
    target: FlowTarget(name: "www.example.com", port: 80),
    proxies: [socks, socks2], chains: chains)
check("a rule that points at a chain walks through it", toChain.upstream == .chain([socks, socks2]))
check("a rule that points at a chain leaves no reason behind", toChain.note == nil)

let toEmptyChain = ProxyRuleEngine.decide(
    rules: [EngineRule(action: "chain:c9")],
    target: FlowTarget(name: "www.example.com", port: 80),
    proxies: [socks], chains: chains)
check("a rule that points at a chain that is not there goes straight out",
      toEmptyChain.upstream == .direct)
check("a rule that points at a chain that is not there says so",
      toEmptyChain.note != nil)

let toBrokenChain = ProxyRuleEngine.decide(
    rules: [EngineRule(action: "chain:c1")],
    target: FlowTarget(name: "www.example.com", port: 80),
    proxies: [socks], chains: chains)
check("a chain with a proxy that is not there goes straight out",
      toBrokenChain.upstream == .direct)
check("a chain with a proxy that is not there says so", toBrokenChain.note != nil)

let httpInTheMiddle = ProxyRuleEngine.decide(
    rules: [EngineRule(action: "chain:c1")],
    target: FlowTarget(name: "www.example.com", port: 80),
    proxies: [httpProxy, socks2], chains: chains)
check("a chain with an http proxy in the middle goes straight out",
      httpInTheMiddle.upstream == .direct)
check("a chain with an http proxy in the middle says so", httpInTheMiddle.note != nil)

let chainForUDP = ProxyRuleEngine.decide(
    rules: [EngineRule(action: "chain:c1")],
    target: FlowTarget(name: "www.example.com", port: 53, transport: .udp),
    proxies: [socks, socks2], chains: chains)
check("udp does not walk a chain", chainForUDP.upstream == .direct)
check("udp that cannot walk a chain says so", chainForUDP.note != nil)

let httpChainAtTheEnd = ProxyRuleEngine.decide(
    rules: [EngineRule(action: "chain:c2")],
    target: FlowTarget(name: "www.example.com", port: 80),
    proxies: [socks, httpProxy], chains: ["c2": ["p1", "h1"]])
check("a chain may end in an http proxy", httpChainAtTheEnd.upstream == .chain([socks, httpProxy]))

// MARK: - the actions

check("DIRECT goes straight out",
      ProxyRuleEngine.decide(rules: [EngineRule(action: "DIRECT")],
                             target: FlowTarget(name: "a.com", port: 80),
                             proxies: [], chains: [:]).upstream == .direct)
check("BLOCK stops the traffic",
      ProxyRuleEngine.decide(rules: [EngineRule(action: "BLOCK")],
                             target: FlowTarget(name: "a.com", port: 80),
                             proxies: [], chains: [:]).upstream == .blocked)

// MARK: - the target of a flow

check("a host that is not an address is a name",
      FlowTarget(host: "example.com", port: 80).name == "example.com")
check("a host that is an address is an address",
      FlowTarget(host: "93.184.216.34", port: 80).address == "93.184.216.34")
check("a host that is an address has no name",
      FlowTarget(host: "93.184.216.34", port: 80).name == nil)
check("the name of a target is what the proxy is asked for",
      FlowTarget(name: "example.com", port: 80).proxyHost == "example.com")
check("the address of a target is what the proxy is asked for when there is no name",
      FlowTarget(address: "93.184.216.34", port: 80).proxyHost == "93.184.216.34")

// MARK: - the end

if fails == 0 {
    print("rule engine tests: ALL PASS")
} else {
    print("rule engine tests: \(fails) FAILED")
    exit(1)
}
