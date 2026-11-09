import Foundation
import Darwin

// The tests of the data plane of the gateway mode: the part that reads the
// rules of the app, and the part that asks the kernel where a connection was
// going.
//
// These are the parts that can be checked without a root and without a
// machine that is really the gateway of a network: the rest needs a second
// machine, and that is a test a person runs by hand.

func check(_ condition: Bool, _ what: String) {
    if condition {
        print("  ok   \(what)")
    } else {
        print("  FAIL \(what)")
        exit(1)
    }
}

// ---------------------------------------------------------------- the rules

print("gateway data plane tests:")

// a proxy of the app, as the engine reads it
let proxy = ProxyEndpoint(id: "108", name: "Local socks5", type: "socks5",
                           host: "127.0.0.1", port: 9991,
                           username: nil, password: nil)
let second = ProxyEndpoint(id: "117", name: "Other socks5", type: "socks5",
                            host: "127.0.0.1", port: 7991,
                            username: nil, password: nil)

// a rule that says nothing goes straight out
let direct = GatewayDataPlane.plan(rules: [], proxies: [proxy], chains: [:],
                                   originalAddress: "93.184.216.34", originalPort: 443)
check(direct.upstream == .direct, "a traffic that no rule names goes straight out")

// the place the connection was going is the target of the rules
check(direct.target.address == "93.184.216.34", "the target is the address the connection was going to")
check(direct.target.port == 443, "the target is the port the connection was going to")
check(direct.target.transport == .tcp, "the target is tcp")

// a rule that names a program is not about a client of the network
let withProgram = EngineRule(action: "BLOCK", hosts: [], ports: [], hasProgram: true)
let programPlan = GatewayDataPlane.plan(rules: [withProgram], proxies: [proxy], chains: [:],
                                        originalAddress: "93.184.216.34", originalPort: 443)
check(programPlan.upstream == .direct, "a rule that names a program is skipped")

// a rule that names the address sends the traffic through its proxy
let byAddress = EngineRule(action: "108", hosts: ["93.184.216.34"], ports: ["443"])
let addressPlan = GatewayDataPlane.plan(rules: [byAddress], proxies: [proxy], chains: [:],
                                        originalAddress: "93.184.216.34", originalPort: 443)
check(addressPlan.upstream == .proxy(proxy), "a rule that names the address sends the traffic through its proxy")

// a rule of another address does not
let otherPlan = GatewayDataPlane.plan(rules: [byAddress], proxies: [proxy], chains: [:],
                                      originalAddress: "1.1.1.1", originalPort: 443)
check(otherPlan.upstream == .direct, "a rule of another address does not send the traffic anywhere")

// a rule that blocks, blocks
let blocking = EngineRule(action: "BLOCK", hosts: ["93.184.216.34"])
let blockedPlan = GatewayDataPlane.plan(rules: [blocking], proxies: [proxy], chains: [:],
                                         originalAddress: "93.184.216.34", originalPort: 443)
check(blockedPlan.upstream == .blocked, "a rule that blocks blocks the traffic")

// a rule that points at a chain walks through the chain
let chainRule = EngineRule(action: "chain:126", hosts: [])
let chainPlan = GatewayDataPlane.plan(rules: [chainRule], proxies: [proxy, second],
                                      chains: ["126": ["117"]],
                                      originalAddress: "93.184.216.34", originalPort: 443)
check(chainPlan.upstream == .chain([second]), "a rule that points at a chain walks through the chain")

// a chain that cannot be walked through says so instead of failing quietly
let emptyChain = GatewayDataPlane.plan(rules: [chainRule], proxies: [proxy], chains: [:],
                                       originalAddress: "93.184.216.34", originalPort: 443)
check(emptyChain.upstream == .direct, "a chain with nothing in it goes straight out")
check(emptyChain.note != nil, "a chain with nothing in it says why")

// ---------------------------------------------------------------- the question

print("gateway lookup tests:")

// the plane asks the helper with the two ends of the connection, the way the
// socket sees them
let plane = GatewayDataPlane()
var asked: (String, Int, String, Int)?
plane.lookupHandler = { clientAddress, clientPort, destinationAddress, destinationPort in
    asked = (clientAddress, clientPort, destinationAddress, destinationPort)
    var answer = GatewayProtocol.Response.success()
    answer.originalAddress = "93.184.216.34"
    answer.originalPort = 443
    return answer
}

let answer = plane.askWhereItWasGoing(peer: ("192.168.254.140", 54321),
                                       local: ("127.0.0.1", GatewayDataPlane.redirectPort))
check(asked?.0 == "192.168.254.140", "the question names the client")
check(asked?.1 == 54321, "the question names the port of the client")
check(asked?.2 == "127.0.0.1", "the question names the address the traffic was redirected to")
check(asked?.3 == GatewayDataPlane.redirectPort, "the question names the port the traffic was redirected to")
check(answer.ok, "the answer of the helper comes back")
check(answer.originalAddress == "93.184.216.34", "the answer says where the connection was going")
check(answer.originalPort == 443, "the answer says the port the connection was going to")

// ---------------------------------------------------------------- the ends of a connection

print("gateway socket tests:")

// a real connection, so that the ends of it are read the way the kernel says
let listener = LocalProxySocket.listen(address: "127.0.0.1", port: 0, interfaceName: nil)
guard let listenFD = listener.fd else {
    print("  FAIL the socket could not be made")
    exit(1)
}
defer { Darwin.close(listenFD) }

// the port the system gave the socket
var listenAddress = sockaddr_in()
var listenLength = socklen_t(MemoryLayout<sockaddr_in>.size)
let named = withUnsafeMutablePointer(to: &listenAddress) { pointer -> Int32 in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
        Darwin.getsockname(listenFD, generic, &listenLength)
    }
}
check(named == 0, "the socket knows its own address")
let listenPort = Int(UInt16(bigEndian: listenAddress.sin_port))
check(listenPort > 0, "the socket was given a port")

guard let client = LocalProxySocket.connect(host: "127.0.0.1", port: listenPort, timeout: 5).fd else {
    print("  FAIL the connection could not be made")
    exit(1)
}
defer { Darwin.close(client) }

var clientAddress = sockaddr_in()
var clientLength = socklen_t(MemoryLayout<sockaddr_in>.size)
let accepted = withUnsafeMutablePointer(to: &clientAddress) { pointer -> Int32 in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
        Darwin.accept(listenFD, generic, &clientLength)
    }
}
guard accepted >= 0 else {
    print("  FAIL the connection was not accepted")
    exit(1)
}
defer { Darwin.close(accepted) }

// the other end of the connection is the client, and this end is the port the
// traffic was taken in on
guard let peer = GatewayDataPlane.peer(of: accepted),
      let local = GatewayDataPlane.local(of: accepted) else {
    print("  FAIL the ends of the connection could not be read")
    exit(1)
}
check(peer.address == "127.0.0.1", "the other end of the connection is the client")
check(peer.port > 0, "the other end of the connection has a port")
check(local.address == "127.0.0.1", "this end of the connection is the loopback")
check(local.port == listenPort, "this end of the connection is the port the traffic was taken in on")

print("gateway data plane tests: ALL PASS")
