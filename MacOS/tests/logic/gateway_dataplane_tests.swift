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

// the lines are written as they come: the test waits for the datagrams of
// the network, and a line that is kept in a buffer is a line that is not
// there when it is needed
setvbuf(stdout, nil, _IONBF, 0)

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
var asked: (String, Int, String, Int, String)?
plane.lookupHandler = { clientAddress, clientPort, destinationAddress, destinationPort, transport in
    asked = (clientAddress, clientPort, destinationAddress, destinationPort, transport)
    var answer = GatewayProtocol.Response.success()
    answer.originalAddress = "93.184.216.34"
    answer.originalPort = 443
    return answer
}

let answer = plane.askWhereItWasGoing(peer: ("192.168.254.140", 54321),
                                       local: ("192.168.254.205", GatewayDataPlane.redirectPort))
check(asked?.0 == "192.168.254.140", "the question names the client")
check(asked?.1 == 54321, "the question names the port of the client")
check(asked?.2 == "192.168.254.205", "the question names the address the traffic was redirected to")
check(asked?.3 == GatewayDataPlane.redirectPort, "the question names the port the traffic was redirected to")
check(asked?.4 == "TCP", "the question about a connection says tcp")
check(answer.ok, "the answer of the helper comes back")
check(answer.originalAddress == "93.184.216.34", "the answer says where the connection was going")
check(answer.originalPort == 443, "the answer says the port the connection was going to")

// the question about a datagram says udp, and the kernel keeps the states of
// tcp and of udp apart
let datagramAnswer = plane.askWhereItWasGoing(peer: ("192.168.254.140", 54321),
                                               local: ("192.168.254.205", GatewayDataPlane.redirectPort),
                                               transport: "UDP")
check(asked?.4 == "UDP", "the question about a datagram says udp")
check(datagramAnswer.ok, "the answer about a datagram comes back")

// the plan of a datagram is read by the rules of the app
let udpPlan = GatewayDataPlane.plan(rules: [byAddress], proxies: [proxy], chains: [:],
                                    originalAddress: "93.184.216.34", originalPort: 443,
                                    transport: .udp)
check(udpPlan.target.transport == .udp, "the target of a datagram is udp")
check(udpPlan.upstream == .proxy(proxy), "the rule that names the address sends the datagram through its proxy")

// a rule that speaks about tcp does not speak about a datagram
let tcpOnly = EngineRule(action: "108", hosts: ["93.184.216.34"], protocolMode: "TCP")
let mixedPlan = GatewayDataPlane.plan(rules: [tcpOnly], proxies: [proxy], chains: [:],
                                      originalAddress: "93.184.216.34", originalPort: 443,
                                      transport: .udp)
check(mixedPlan.upstream == .direct, "a rule about tcp is not about a datagram")

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

// ---------------------------------------------------------------- the datagrams

print("gateway datagram tests:")

// A proxy that says it can carry datagrams, and carries them.
//
// The control connection answers the greeting and the request of the
// association, and the relay says back whatever it is given, with the header
// of socks5 in front of it. It is the same shape as a real proxy, and the
// point of it is that the plane has to speak to it the way it speaks to a
// real one.
final class FakeSocks5 {

    let controlPort: Int
    let relayPort: Int
    private let controlFD: Int32
    private let relayFD: Int32

    init() {
        let control = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(control, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = 0
        local.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        withUnsafePointer(to: &local) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                _ = bind(control, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        _ = listen(control, 16)
        var named = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &named) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                _ = getsockname(control, generic, &length)
            }
        }
        let controlPort = Int(UInt16(bigEndian: named.sin_port))

        let relay = socket(AF_INET, SOCK_DGRAM, 0)
        setsockopt(relay, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var relayLocal = sockaddr_in()
        relayLocal.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        relayLocal.sin_family = sa_family_t(AF_INET)
        relayLocal.sin_port = 0
        relayLocal.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        withUnsafePointer(to: &relayLocal) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                _ = bind(relay, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var relayNamed = sockaddr_in()
        var relayLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &relayNamed) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                _ = getsockname(relay, generic, &relayLength)
            }
        }
        let relayPort = Int(UInt16(bigEndian: relayNamed.sin_port))

        controlFD = control
        relayFD = relay
        self.controlPort = controlPort
        self.relayPort = relayPort
    }

    func start() {
        let control = Thread { [weak self] in self?.serveControl() }
        control.start()
        let relay = Thread { [weak self] in self?.serveRelay() }
        relay.start()
    }

    // the control connection: the greeting, and then the association
    private func serveControl() {
        while true {
            let client = accept(controlFD, nil, nil)
            if client < 0 { continue }
            // the greeting: the version, the number of ways, the ways
            var greeting = [UInt8](repeating: 0, count: 3)
            _ = read(client, &greeting, greeting.count)
            var answer: [UInt8] = [0x05, 0x00]
            _ = write(client, answer, answer.count)
            // the request of the association: ten bytes
            var request = [UInt8](repeating: 0, count: 10)
            _ = read(client, &request, request.count)
            var reply: [UInt8] = [0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1,
                                  UInt8((relayPort >> 8) & 0xFF), UInt8(relayPort & 0xFF)]
            _ = write(client, reply, reply.count)
            // the connection stays open: the association lives as long as it
            // does
            var scratch = [UInt8](repeating: 0, count: 64)
            while read(client, &scratch, scratch.count) > 0 {}
            close(client)
        }
    }

    // the relay: the datagram comes in with a header, and it goes back out
    // with the same header
    private func serveRelay() {
        var buffer = [UInt8](repeating: 0, count: 65535)
        while true {
            var from = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { pointer -> Int in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                    recvfrom(relayFD, &buffer, buffer.count, 0, generic, &length)
                }
            }
            guard n > 0 else { continue }
            // only what came in goes back out: the buffer of the socket is
            // much bigger than the datagram
            let datagram = Data(buffer[0..<n])
            datagram.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                withUnsafePointer(to: &from) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                        _ = sendto(relayFD, base, raw.count, 0, generic, length)
                    }
                }
            }
        }
    }
}

// The plane takes the datagrams in and carries them through the proxy.
let fake = FakeSocks5()
fake.start()

let throughProxy = ProxyEndpoint(id: "200", name: "Fake socks5", type: "socks5",
                                 host: "127.0.0.1", port: fake.controlPort,
                                 username: nil, password: nil)

let udpPlane = GatewayDataPlane()
var udpAsked: (String, Int, String, Int, String)?
udpPlane.lookupHandler = { clientAddress, clientPort, destinationAddress, destinationPort, transport in
    udpAsked = (clientAddress, clientPort, destinationAddress, destinationPort, transport)
    var answer = GatewayProtocol.Response.success()
    answer.originalAddress = "93.184.216.34"
    answer.originalPort = 443
    return answer
}
udpPlane.update(rules: [EngineRule(action: "200", hosts: [])],
                proxies: [throughProxy],
                chains: [:])
udpPlane.logHandler = { message, level in
    print("    [\(level)] \(message)")
}

let started = udpPlane.start(port: 0, address: "127.0.0.1")
guard case .success(let message) = started else {
    print("  FAIL the plane of the datagrams could not be started")
    exit(1)
}
check(true, "the plane takes the datagrams in")

// the port the plane was given
let planePort = udpPlane.datagramPort
check(planePort > 0, "the plane was given a port for the datagrams")

// a client sends a datagram to the plane
let udpClient = socket(AF_INET, SOCK_DGRAM, 0)
guard udpClient >= 0 else {
    print("  FAIL the socket of the udpClient could not be made")
    exit(1)
}
defer { Darwin.close(udpClient) }
var udpClientLocal = sockaddr_in()
udpClientLocal.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
udpClientLocal.sin_family = sa_family_t(AF_INET)
udpClientLocal.sin_port = 0
udpClientLocal.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
_ = withUnsafePointer(to: &udpClientLocal) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
        Darwin.bind(udpClient, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
}

let payload = Data("HELLO-UDP".utf8)
var to = sockaddr_in()
to.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
to.sin_family = sa_family_t(AF_INET)
to.sin_port = in_port_t(UInt16(planePort)).bigEndian
to.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
payload.withUnsafeBytes { raw in
    guard let base = raw.baseAddress else { return }
    withUnsafePointer(to: &to) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
            let sent = sendto(udpClient, base, raw.count, 0, generic,
                              socklen_t(MemoryLayout<sockaddr_in>.size))
            check(sent == payload.count, "the datagram goes out to the plane")
        }
    }
}

// the answer comes back, and it comes back from the plane
var answerBuffer = [UInt8](repeating: 0, count: 4096)
var timeout = timeval(tv_sec: 5, tv_usec: 0)
setsockopt(udpClient, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
var answerFrom = sockaddr_in()
var answerLength = socklen_t(MemoryLayout<sockaddr_in>.size)
let received = withUnsafeMutablePointer(to: &answerFrom) { pointer -> Int in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
        recvfrom(udpClient, &answerBuffer, answerBuffer.count, 0, generic, &answerLength)
    }
}
check(received == payload.count, "the datagram comes back")
check(String(decoding: answerBuffer[0..<max(0, received)], as: UTF8.self) == "HELLO-UDP",
      "the datagram that comes back is the one that was sent")
check(udpAsked?.4 == "UDP", "the plane asked the kernel about a datagram")
udpPlane.stop()

print("gateway data plane tests: ALL PASS")
