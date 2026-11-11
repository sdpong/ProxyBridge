import Foundation
import Darwin

// The dns of the clients, end to end.
//
// The plan of a traffic is only half of the gateway mode: the other half is
// that a client of the network asks a resolver for a name, and the gateway
// has to learn the name from the answer of that resolver. These are the
// tests that send a real datagram through a real socket to a proxy that
// answers like one, and that check that the name ends up in the rules.

func check(_ condition: Bool, _ what: String) {
    if condition {
        print("  ok   \(what)")
    } else {
        print("  FAIL \(what)")
        exit(1)
    }
}

setvbuf(stdout, nil, _IONBF, 0)

print("gateway dns flow tests:")

// ---------------------------------------------------------------- the answers

func header(id: UInt16, flags: UInt16, qd: UInt16, an: UInt16) -> [UInt8] {
    return [
        UInt8(id >> 8), UInt8(id & 0xFF),
        UInt8(flags >> 8), UInt8(flags & 0xFF),
        UInt8(qd >> 8), UInt8(qd & 0xFF),
        UInt8(an >> 8), UInt8(an & 0xFF),
        0, 0, 0, 0
    ]
}

func wireName(_ name: String) -> [UInt8] {
    var out: [UInt8] = []
    for label in name.split(separator: ".") {
        out.append(UInt8(label.count))
        out.append(contentsOf: Array(label.utf8))
    }
    out.append(0)
    return out
}

// a query for one name
func query(_ name: String) -> Data {
    var bytes = header(id: 0x1234, flags: 0x0100, qd: 1, an: 0)
    bytes += wireName(name)
    bytes += [0x00, 0x01, 0x00, 0x01]
    return Data(bytes)
}

// the answer of a resolver: the name belongs to the address
func answer(_ name: String, _ ipv4: String) -> Data {
    var bytes = header(id: 0x1234, flags: 0x8180, qd: 1, an: 1)
    bytes += wireName(name)
    bytes += [0x00, 0x01, 0x00, 0x01]
    bytes += [0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x3C, 0x00, 0x04]
    bytes += ipv4.split(separator: ".").compactMap { UInt8($0) }
    return Data(bytes)
}

// ---------------------------------------------------------------- the proxy

// A proxy that answers a query for a name with an answer.
//
// The control connection says the greeting and the association, and the
// relay answers the datagram that comes in with the answer of a resolver.
// The answer says that www.google.com is 142.250.185.78.
final class ResolverProxy {

    let controlPort: Int
    let relayPort: Int
    private let controlFD: Int32
    private let relayFD: Int32

    // the answer the relay gives
    let reply: Data

    init(reply: Data) {
        self.reply = reply

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

    private func serveControl() {
        while true {
            let client = accept(controlFD, nil, nil)
            if client < 0 { continue }
            var greeting = [UInt8](repeating: 0, count: 3)
            _ = read(client, &greeting, greeting.count)
            var answerBytes: [UInt8] = [0x05, 0x00]
            _ = write(client, answerBytes, answerBytes.count)
            var request = [UInt8](repeating: 0, count: 10)
            _ = read(client, &request, request.count)
            var replyBytes: [UInt8] = [0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1,
                                       UInt8((relayPort >> 8) & 0xFF), UInt8(relayPort & 0xFF)]
            _ = write(client, replyBytes, replyBytes.count)
            var scratch = [UInt8](repeating: 0, count: 64)
            while read(client, &scratch, scratch.count) > 0 {}
            close(client)
        }
    }

    // the relay: the datagram comes in with the header of socks5 in front of
    // it, and the answer goes back out with the same header in front of it
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

            let bytes = Array(buffer[0..<n])
            guard let head = ResolverProxy.headerLength(bytes) else { continue }
            var out = Data(bytes[0..<head])
            out.append(reply)
            out.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                withUnsafePointer(to: &from) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                        _ = sendto(relayFD, base, raw.count, 0, generic, length)
                    }
                }
            }
        }
    }

    // how long the header of socks5 in front of the datagram is
    static func headerLength(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 5 else { return nil }
        switch bytes[3] {
        case 0x01:
            return bytes.count >= 10 ? 10 : nil
        case 0x04:
            return bytes.count >= 22 ? 22 : nil
        case 0x03:
            let name = Int(bytes[4])
            let total = 5 + name + 2
            return bytes.count >= total ? total : nil
        default:
            return nil
        }
    }
}

// ---------------------------------------------------------------- the plane

let resolver = ResolverProxy(reply: answer("www.google.com", "142.250.185.78"))
resolver.start()

let proxy = ProxyEndpoint(id: "200", name: "Resolver socks5", type: "socks5",
                           host: "127.0.0.1", port: resolver.controlPort,
                           username: nil, password: nil)

let plane = GatewayDataPlane()
plane.lookupHandler = { clientAddress, clientPort, destinationAddress, destinationPort, transport in
    var answerResponse = GatewayProtocol.Response.success()
    answerResponse.originalAddress = "8.8.8.8"
    answerResponse.originalPort = 53
    return answerResponse
}
plane.update(rules: [EngineRule(action: "200", hosts: [])],
             proxies: [proxy],
             chains: [:])
plane.logHandler = { message, level in
    print("    [\(level)] \(message)")
}

guard case .success = plane.start(port: 0, address: "127.0.0.1") else {
    print("  FAIL the plane could not be started")
    exit(1)
}
check(true, "the plane takes the datagrams in")

let planePort = plane.datagramPort
check(planePort > 0, "the plane was given a port for the datagrams")

// ---------------------------------------------------------------- the query

print("a query for a name:")

// a client sends the query to the plane
let client = socket(AF_INET, SOCK_DGRAM, 0)
guard client >= 0 else {
    print("  FAIL the socket of the client could not be made")
    exit(1)
}
defer { Darwin.close(client) }
var clientLocal = sockaddr_in()
clientLocal.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
clientLocal.sin_family = sa_family_t(AF_INET)
clientLocal.sin_port = 0
clientLocal.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
_ = withUnsafePointer(to: &clientLocal) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
        _ = bind(client, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
}

let asked = query("www.google.com")
var to = sockaddr_in()
to.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
to.sin_family = sa_family_t(AF_INET)
to.sin_port = in_port_t(UInt16(planePort)).bigEndian
to.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
asked.withUnsafeBytes { raw in
    guard let base = raw.baseAddress else { return }
    withUnsafePointer(to: &to) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
            let sent = sendto(client, base, raw.count, 0, generic,
                              socklen_t(MemoryLayout<sockaddr_in>.size))
            check(sent == asked.count, "the query goes out to the plane")
        }
    }
}

// the answer comes back to the client
var answerBuffer = [UInt8](repeating: 0, count: 4096)
var timeout = timeval(tv_sec: 10, tv_usec: 0)
setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
var answerFrom = sockaddr_in()
var answerLength = socklen_t(MemoryLayout<sockaddr_in>.size)
let received = withUnsafeMutablePointer(to: &answerFrom) { pointer -> Int in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
        recvfrom(client, &answerBuffer, answerBuffer.count, 0, generic, &answerLength)
    }
}
check(received > 0, "the answer of the resolver comes back to the client")

// the name is learned from the answer
check(GatewayDNS.names(for: "142.250.185.78").contains("www.google.com"),
      "the gateway learned the name of the place from the answer")

// ---------------------------------------------------------------- the rules

print("the rules match the name afterwards:")

// a rule that names a host, the way the rules of the app are written
let byHost = EngineRule(action: "200", hosts: ["*.google.com"], ports: [])

// without the name the rule does not match
let withoutName = GatewayDataPlane.plan(rules: [byHost], proxies: [proxy], chains: [:],
                                         originalAddress: "142.250.185.78", originalPort: 443)
check(withoutName.upstream == .direct, "the rule does not match an address that has no name")

// with the name it matches, and the proxy server is asked for the name
let names = GatewayDNS.names(for: "142.250.185.78")
let withName = GatewayDataPlane.plan(rules: [byHost], proxies: [proxy], chains: [:],
                                     originalAddress: "142.250.185.78", originalPort: 443,
                                     names: names)
check(withName.upstream == .proxy(proxy), "the rule matches the traffic that has the name")
check(withName.target.proxyHost == "www.google.com", "the proxy server is asked for the name")
check(withName.target.address == "142.250.185.78", "the address is still known")

plane.stop()
print("gateway dns flow tests: ALL PASS")
