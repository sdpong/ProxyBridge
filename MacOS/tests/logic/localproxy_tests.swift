import Foundation
import Darwin

// The proxy server of the app.
//
// The test starts the server on a port of its own, talks to it with a
// SOCKS5 client and with an http client, and looks at what comes back. A
// server that only works when a person clicks on it is a server that is
// never tested.
//
// Compiled as main.swift by run.sh.

// the output is not buffered: the test may hang, and then the lines that
// were printed before are the ones that say where it stopped
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

// MARK: - the echo server the proxy talks to

// A server that sends back what it gets. It stands for the site the client
// wants to reach.
final class EchoServer {
    private var fd: Int32 = -1
    private var thread: Thread?
    private(set) var port: Int = 0

    func start() -> Bool {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return false }
        var yes: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.bind(socket, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(socket, 16) == 0 else {
            Darwin.close(socket)
            return false
        }
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &local) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                getsockname(socket, generic, &length)
            }
        }
        port = Int(UInt16(bigEndian: local.sin_port))
        fd = socket
        let thread = Thread { [weak self] in self?.loop() }
        thread.stackSize = 256 * 1024
        thread.start()
        self.thread = thread
        return true
    }

    private func loop() {
        while true {
            let client = Darwin.accept(fd, nil, nil)
            if client < 0 { return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let n = Darwin.recv(client, &buffer, buffer.count, 0)
            if n > 0 {
                _ = buffer[0..<n].withUnsafeBytes { raw in
                    Darwin.send(client, raw.baseAddress, raw.count, 0)
                }
            }
            Darwin.close(client)
        }
    }

    // the udp side of the echo server. a datagram comes in and the same
    // datagram goes back.
    private var udpFD: Int32 = -1
    private(set) var udpPort: Int = 0

    func startUDP() -> Bool {
        let socket = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard socket >= 0 else { return false }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.bind(socket, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            Darwin.close(socket)
            return false
        }
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &local) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                getsockname(socket, generic, &length)
            }
        }
        udpPort = Int(UInt16(bigEndian: local.sin_port))
        udpFD = socket
        let thread = Thread { [weak self] in self?.udpLoop() }
        thread.stackSize = 256 * 1024
        thread.start()
        return true
    }

    private func udpLoop() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            var from = sockaddr_in()
            var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { pointer -> Int in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                    recvfrom(udpFD, &buffer, buffer.count, 0, generic, &fromLength)
                }
            }
            if n > 0 {
                // the answer goes back to the one who sent it
                withUnsafePointer(to: &from) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                        buffer[0..<n].withUnsafeBytes { raw in
                            sendto(udpFD, raw.baseAddress, raw.count, 0, generic, fromLength)
                        }
                    }
                }
            }
        }
    }

    func stop() {
        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
            fd = -1
        }
    }
}

// MARK: - a client that talks to the server

func connectLocal(port: Int) -> Int32? {
    let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard socket >= 0 else { return nil }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(UInt16(port)).bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let connected = withUnsafePointer(to: &address) { pointer -> Int32 in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
            Darwin.connect(socket, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    if connected != 0 {
        Darwin.close(socket)
        return nil
    }
    return socket
}

func sendBytes(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
    return bytes.withUnsafeBytes { raw -> Bool in
        var sent = 0
        while sent < raw.count {
            let n = Darwin.send(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent, 0)
            if n <= 0 { return false }
            sent += n
        }
        return true
    }
}

func readSome(_ fd: Int32, _ count: Int) -> [UInt8] {
    var buffer = [UInt8](repeating: 0, count: count)
    let n = Darwin.recv(fd, &buffer, count, 0)
    return n > 0 ? Array(buffer[0..<n]) : []
}

// MARK: - the test

let echo = EchoServer()
guard echo.start() else {
    print("FAIL the echo server did not start")
    exit(1)
}
_ = echo.startUDP()

var settings = LocalProxySettings.default
settings.enabled = true
settings.protocolMode = .both
settings.listenAddress = "127.0.0.1"
settings.port = 45871
settings.upstream = .direct
// the udp association is off by default: a server that carries udp is
// something a person asks for
settings.udpEnabled = true

let server = LocalProxyServer()
server.logHandler = { message, level in
    if level == "ERROR" { print("  note the server says: \(message)") }
}
var startResult: LocalProxyServer.StartResult? = nil
server.start(settings: settings) { startResult = $0 }
guard case .started? = startResult else {
    print("FAIL the server did not start: \(String(describing: startResult))")
    exit(1)
}
print("  ok   the server starts")

// socks5: the greeting, the request, and the answer
if let client = connectLocal(port: settings.port) {
    check("the greeting is answered", sendBytes(client, [0x05, 0x01, 0x00]))
    let greeting = readSome(client, 2)
    check("the server answers the greeting", greeting == [0x05, 0x00])

    var request: [UInt8] = [0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1]
    request.append(UInt8((echo.port >> 8) & 0xFF))
    request.append(UInt8(echo.port & 0xFF))
    check("the request is sent", sendBytes(client, request))
    let answer = readSome(client, 10)
    check("the server grants the request", answer.count == 10 && answer[0] == 0x05 && answer[1] == 0x00)

    check("the payload goes out", sendBytes(client, Array("hello".utf8)))
    let back = readSome(client, 5)
    check("the payload comes back", String(decoding: back, as: UTF8.self) == "hello")
    Darwin.close(client)
} else {
    check("the client can reach the server", false)
}

// http: CONNECT
if let client = connectLocal(port: settings.port) {
    let request = "CONNECT 127.0.0.1:\(echo.port) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
    check("the connect is sent", sendBytes(client, Array(request.utf8)))
    let answer = readSome(client, 64)
    let text = String(decoding: answer, as: UTF8.self)
    check("the server answers the connect", text.contains("200"))
    check("the payload goes out", sendBytes(client, Array("hello".utf8)))
    let back = readSome(client, 5)
    check("the payload comes back", String(decoding: back, as: UTF8.self) == "hello")
    Darwin.close(client)
} else {
    check("the client can reach the server", false)
}

// a port that is taken is reported with the name of the program that has it
let second = LocalProxyServer()
var secondResult: LocalProxyServer.StartResult? = nil
second.start(settings: settings) { secondResult = $0 }
if case .failed(let reason)? = secondResult {
    check("the taken port is reported", reason.contains("taken") || reason.contains("taken by"))
} else {
    check("the taken port is reported", false)
}

// the udp association of socks5
//
// The client opens an association over tcp, is told the port its datagrams
// have to go to, and sends them there. The datagrams carry the address they
// are for in a small header.
if let client = connectLocal(port: settings.port) {
    sendBytes(client, [0x05, 0x01, 0x00])
    _ = readSome(client, 2)
    // udp associate
    sendBytes(client, [0x05, 0x03, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
    let answer = readSome(client, 10)
    check("the association is granted", answer.count == 10 && answer[0] == 0x05 && answer[1] == 0x00)
    if answer.count == 10 {
        let relayPort = (Int(answer[8]) << 8) | Int(answer[9])
        check("the relay has a port", relayPort > 0)

        // a datagram for the echo server, in the socks5 udp header
        let echoPort = echo.udpPort
        var datagram: [UInt8] = [0x00, 0x00, 0x00, 0x01, 127, 0, 0, 1]
        datagram.append(UInt8((echoPort >> 8) & 0xFF))
        datagram.append(UInt8(echoPort & 0xFF))
        datagram.append(contentsOf: Array("hello".utf8))

        let udp = socket(AF_INET, SOCK_DGRAM, 0)
        // the wait for the answer is not for ever: a test that hangs says
        // nothing about what went wrong
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(udp, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var to = sockaddr_in()
        to.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        to.sin_family = sa_family_t(AF_INET)
        to.sin_port = in_port_t(UInt16(relayPort)).bigEndian
        to.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let sent = withUnsafePointer(to: &to) { pointer -> Int in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                datagram.withUnsafeBytes { raw in
                    sendto(udp, raw.baseAddress, raw.count, 0, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        check("the datagram goes out", sent == datagram.count)

        // and the answer comes back with the same header
        var back = [UInt8](repeating: 0, count: 2048)
        var from = sockaddr_in()
        var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ready = withUnsafeMutablePointer(to: &from) { pointer -> Int in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                recvfrom(udp, &back, back.count, 0, generic, &fromLength)
            }
        }
        check("the answer comes back", ready > 10)
        if ready > 10 {
            let payload = String(decoding: back[10..<ready], as: UTF8.self)
            check("the payload is the answer of the far side", payload == "hello")
        }
        Darwin.close(udp)
    }
    Darwin.close(client)
} else {
    check("the client can reach the server", false)
}

// the settings survive a round trip
let stored = LocalProxySettings.fromDictionary(settings.toDictionary())
check("the settings survive the trip", stored == settings)
check("the port is kept", stored.port == 45871)
check("the upstream is kept", stored.upstream == .direct)

// the rules of the app: a client on the network has no program, so a rule
// that names one is not about it
let rules = LocalProxyRules.upstream(
    rules: [LocalProxyRule(action: "DIRECT", targetHosts: [], targetPorts: [], hasProgram: true, enabled: true, protocolMode: "BOTH")],
    target: LocalProxyTarget(host: "example.com", port: 80), proxies: [])
check("a rule with a program is skipped", rules == .direct)

let blocked = LocalProxyRules.upstream(
    rules: [LocalProxyRule(action: "BLOCK", targetHosts: ["*.example.com"], targetPorts: [], hasProgram: false, enabled: true, protocolMode: "BOTH")],
    target: LocalProxyTarget(host: "www.example.com", port: 80), proxies: [])
check("a rule that names a host blocks the traffic", blocked == .blocked)

let allowed = LocalProxyRules.upstream(
    rules: [LocalProxyRule(action: "DIRECT", targetHosts: ["*.example.com"], targetPorts: [], hasProgram: false, enabled: true, protocolMode: "BOTH")],
    target: LocalProxyTarget(host: "www.example.com", port: 80), proxies: [])
check("a rule that names a host matches the traffic", allowed == .direct)

let other = LocalProxyRules.upstream(
    rules: [LocalProxyRule(action: "BLOCK", targetHosts: ["*.example.com"], targetPorts: [], hasProgram: false, enabled: true, protocolMode: "BOTH")],
    target: LocalProxyTarget(host: "www.other.com", port: 80), proxies: [])
check("a rule that names another host does not match", other == .direct)

// the patterns of the rules
check("a host pattern with a star matches", LocalProxyRule.host("*.example.com", matches: "www.example.com"))
check("a host pattern with a star does not match the other one", !LocalProxyRule.host("*.example.com", matches: "www.other.com"))
check("a plain host matches itself", LocalProxyRule.host("example.com", matches: "example.com"))
check("a port range matches", LocalProxyRule.port("8000-9000", matches: 8443))
check("a port range does not match the other one", !LocalProxyRule.port("8000-9000", matches: 7000))
check("a single port matches", LocalProxyRule.port("443", matches: 443))

// the targets of the http client
check("an url is read", LocalProxyTarget.parse(url: "http://example.com/x") == LocalProxyTarget(host: "example.com", port: 80))
check("an url with a port is read", LocalProxyTarget.parse(url: "http://example.com:8080/x") == LocalProxyTarget(host: "example.com", port: 8080))
check("a connect line is read", LocalProxyTarget.parse(hostPort: "example.com:443") == LocalProxyTarget(host: "example.com", port: 443))

server.stop()
echo.stop()

print(fails == 0 ? "local proxy tests: ALL PASS" : "local proxy tests: \(fails) FAILED")
exit(fails == 0 ? 0 : 1)
