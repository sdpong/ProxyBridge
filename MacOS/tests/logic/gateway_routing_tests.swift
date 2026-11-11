import Foundation

// The routing of the traffic of the network.
//
// The gateway mode has the rules of the app and the switches above them, and
// it reads them the way the extension reads them: the rule that matched
// decides, and the global mode is the answer for the traffic that no rule
// names.
//
// These are the parts that can be checked without a root and without a
// machine that is really the gateway of a network.

func check(_ condition: Bool, _ what: String) {
    if condition {
        print("  ok   \(what)")
    } else {
        print("  FAIL \(what)")
        exit(1)
    }
}

setvbuf(stdout, nil, _IONBF, 0)

print("gateway routing tests:")

// a proxy of the app, as the engine reads it
let proxy = ProxyEndpoint(id: "108", name: "Local socks5", type: "socks5",
                           host: "127.0.0.1", port: 9991,
                           username: nil, password: nil)
let second = ProxyEndpoint(id: "117", name: "Other socks5", type: "socks5",
                            host: "127.0.0.1", port: 7991,
                            username: nil, password: nil)

// the switches above the rules, as the gateway reads them
func options(global: Bool = false,
              proxyId: String = "DIRECT",
              local: Bool = true,
              udp: Bool = true) -> GatewayRouting.Options {
    var out = GatewayRouting.Options()
    out.globalMode = global
    out.globalProxyId = proxyId
    out.localNetworkDirect = local
    out.proxyUDP = udp
    return out
}

// a decision, without going through the data plane
func decide(rules: [EngineRule],
             proxies: [ProxyEndpoint] = [proxy],
             chains: [String: [String]] = [:],
             options: GatewayRouting.Options,
             address: String = "93.184.216.34",
             port: Int = 443,
             transport: FlowProtocol = .tcp) -> GatewayRouting.Decision {
    let target = FlowTarget(address: address, port: port, transport: transport)
    return GatewayRouting.decide(rules: rules, proxies: proxies, chains: chains,
                                 options: options, target: target)
}

// ---------------------------------------------------------------- the rules first

print("the rules decide:")

// a rule that names the address sends the traffic through its proxy
let byAddress = EngineRule(action: "108", hosts: ["93.184.216.34"], ports: ["443"])
check(decide(rules: [byAddress], options: options()).upstream == .proxy(proxy),
      "a rule that names the address sends the traffic through its proxy")

// the global mode does not get in the way of a rule that matched
check(decide(rules: [byAddress], options: options(global: true, proxyId: "117")).upstream == .proxy(proxy),
      "a rule that matched decides even when the global mode is on")

// a rule that names a program is not about a client of the network
let withProgram = EngineRule(action: "BLOCK", hosts: [], ports: [], hasProgram: true)
check(decide(rules: [withProgram], options: options()).upstream == .direct,
      "a rule that names a program is skipped")

// a rule that blocks, blocks
let blocking = EngineRule(action: "BLOCK", hosts: ["93.184.216.34"])
check(decide(rules: [blocking], options: options()).upstream == .blocked,
      "a rule that blocks blocks the traffic")

// a rule that points at a chain walks through the chain
let chainRule = EngineRule(action: "chain:126", hosts: [])
check(decide(rules: [chainRule], proxies: [proxy, second],
             chains: ["126": ["117"]], options: options()).upstream == .chain([second]),
      "a rule that points at a chain walks through the chain")

// ---------------------------------------------------------------- the global mode

print("the global mode answers for the traffic that no rule names:")

// without the global mode the traffic goes straight out
check(decide(rules: [], options: options()).upstream == .direct,
      "a traffic that no rule names goes straight out without the global mode")

// with the global mode it goes through the proxy that was chosen
check(decide(rules: [], options: options(global: true, proxyId: "108")).upstream == .proxy(proxy),
      "the global mode sends the traffic that no rule names through its proxy")

// the global mode may name DIRECT, which is a proxy of its own
check(decide(rules: [], options: options(global: true, proxyId: "DIRECT")).upstream == .direct,
      "the global mode may send everything straight out")

// a global proxy that is not in the list says so instead of failing quietly
let missing = decide(rules: [], options: options(global: true, proxyId: "999"))
check(missing.upstream == .direct, "a global proxy that is not in the list sends the traffic straight out")
check(missing.note != nil, "a global proxy that is not in the list says why")

// a rule that names a program does not stop the global mode from answering
// for the traffic of the network: the client has no program, so the rule was
// never about it
check(decide(rules: [withProgram], options: options(global: true, proxyId: "108")).upstream == .proxy(proxy),
      "the global mode answers for the traffic a program rule never named")

// ---------------------------------------------------------------- the local network

print("the traffic of the local network stays local:")

// the traffic of the local network is not part of the global mode
check(decide(rules: [], options: options(global: true, proxyId: "108"),
             address: "192.168.254.140").upstream == .direct,
      "the traffic of the local network stays out of the global mode")

// it goes through the proxy when the switch is off
check(decide(rules: [], options: options(global: true, proxyId: "108", local: false),
             address: "192.168.254.140").upstream == .proxy(proxy),
      "the traffic of the local network goes through the proxy when the switch is off")

// a rule that named the traffic still decides: the switch is about the
// traffic that no rule names
check(decide(rules: [byAddress], options: options(global: true, proxyId: "108"),
             address: "93.184.216.34").upstream == .proxy(proxy),
      "a rule that matched decides over the local network switch")

// ---------------------------------------------------------------- udp

print("udp:")

// udp goes through the proxy of the global mode like tcp does
check(decide(rules: [], options: options(global: true, proxyId: "108"),
             transport: .udp).upstream == .proxy(proxy),
      "the global mode sends a datagram through its proxy")

// when udp may not use a proxy it goes out directly
check(decide(rules: [], options: options(global: true, proxyId: "108", udp: false),
             transport: .udp).upstream == .direct,
      "a datagram goes straight out when udp may not use a proxy")

// the switch is about the proxy only: a rule that blocks still blocks
check(decide(rules: [blocking], options: options(global: true, proxyId: "108", udp: false),
             transport: .udp).upstream == .blocked,
      "a rule that blocks a datagram still blocks it when udp may not use a proxy")

// a chain cannot carry a datagram, and the engine has already said so
let chainUDP = decide(rules: [chainRule], proxies: [proxy, second],
                       chains: ["126": ["117"]], options: options(global: true, proxyId: "108"),
                       transport: .udp)
check(chainUDP.upstream == .direct, "a datagram cannot walk a chain")
check(chainUDP.note != nil, "a datagram that cannot walk a chain says why")

// ---------------------------------------------------------------- the ports

print("the ports:")

// a rule that names the port sends the traffic through its proxy
let byPort = EngineRule(action: "108", hosts: [], ports: ["443"])
check(decide(rules: [byPort], options: options()).upstream == .proxy(proxy),
      "a rule that names the port sends the traffic through its proxy")

// a rule of another port does not
check(decide(rules: [byPort], options: options(), port: 80).upstream == .direct,
      "a rule of another port does not send the traffic anywhere")

// the global mode answers for a port no rule names
check(decide(rules: [byPort], options: options(global: true, proxyId: "108"), port: 80).upstream == .proxy(proxy),
      "the global mode answers for a port that no rule names")

// ---------------------------------------------------------------- the data plane

print("the data plane reads the same:")

// the plan of the data plane carries the decision of the routing
let plan = GatewayDataPlane.plan(rules: [], proxies: [proxy], chains: [:],
                                 options: options(global: true, proxyId: "108"),
                                 originalAddress: "93.184.216.34", originalPort: 443)
check(plan.upstream == .proxy(proxy),
      "the data plane sends the traffic that no rule names through the proxy of the global mode")

// and the plan of a datagram as well
let datagram = GatewayDataPlane.plan(rules: [], proxies: [proxy], chains: [:],
                                     options: options(global: true, proxyId: "108"),
                                     originalAddress: "93.184.216.34", originalPort: 443,
                                     transport: .udp)
check(datagram.upstream == .proxy(proxy),
      "the data plane sends a datagram that no rule names through the proxy of the global mode")

// without the global mode the traffic still goes straight out
let plain = GatewayDataPlane.plan(rules: [], proxies: [proxy], chains: [:],
                                  originalAddress: "93.184.216.34", originalPort: 443)
check(plain.upstream == .direct, "the data plane sends the traffic straight out without the global mode")

print("gateway routing tests: ALL PASS")
