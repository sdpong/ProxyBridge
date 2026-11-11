import Foundation
import Darwin

// The greeting of a proxy gets a limit of time.
//
// The timeout of the connection was taken off before the greeting, so a proxy
// that takes the connection and says nothing kept the flow of the client
// waiting for ever. The greeting has to fail instead, and it has to fail
// quickly.
//
// The proxy of this test does the worst thing a proxy can do: it takes the
// connection and says nothing at all.
//
// Compiled as main.swift by run.sh.

var fails = 0
func check(_ name: String, _ ok: Bool) {
    if ok {
        print("  ok   \(name)")
    } else {
        fails += 1
        print("FAIL \(name)")
    }
}

// A proxy that takes the connection and says nothing.
final class SilentProxy {
    let port: Int
    private let fd: Int32

    init() {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = 0
        local.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        withUnsafePointer(to: &local) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                _ = bind(listener, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        _ = listen(listener, 16)
        var named = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &named) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                _ = getsockname(listener, generic, &length)
            }
        }
        fd = listener
        port = Int(UInt16(bigEndian: named.sin_port))

        let thread = Thread { [weak self] in
            guard let self = self else { return }
            // The connections that are taken are kept open and are never
            // answered: the client waits for the greeting, and the greeting
            // has to give up by itself.
            var kept: [Int32] = []
            while true {
                let client = accept(self.fd, nil, nil)
                if client < 0 { continue }
                kept.append(client)
            }
        }
        thread.start()
    }
}

// A proxy that says what it is, and then nothing more.
final class PoliteProxy {
    let port: Int
    private let fd: Int32

    init() {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = 0
        local.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        withUnsafePointer(to: &local) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                _ = bind(listener, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        _ = listen(listener, 16)
        var named = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &named) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                _ = getsockname(listener, generic, &length)
            }
        }
        fd = listener
        port = Int(UInt16(bigEndian: named.sin_port))

        let thread = Thread { [weak self] in
            guard let self = self else { return }
            while true {
                let client = accept(self.fd, nil, nil)
                if client < 0 { continue }
                // A chain of proxies asks for a second greeting on the same
                // connection: the first proxy is asked to reach the second
                // one, and the second one is asked over that tunnel.
                while true {
                    // the greeting: the version, the number of the ways, and
                    // the ways themselves
                    var head = [UInt8](repeating: 0, count: 2)
                    if read(client, &head, head.count) <= 0 { break }
                    let ways = Int(head[1])
                    var methods = [UInt8](repeating: 0, count: max(0, ways))
                    if !methods.isEmpty { _ = read(client, &methods, methods.count) }
                    var answer: [UInt8] = [0x05, 0x00]
                    _ = write(client, answer, answer.count)
                    // the request: the version, the command, the reserved, the
                    // kind of the address, the address and the port
                    var request = [UInt8](repeating: 0, count: 10)
                    let read2 = read(client, &request, request.count)
                    if read2 <= 0 { break }
                    var reply: [UInt8] = [0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1, 0, 80]
                    _ = write(client, reply, reply.count)
                }
                close(client)
            }
        }
        thread.start()
    }
}

// A proxy that writes down the greeting it was given.
final class RecordingProxy {
    let port: Int
    private let fd: Int32
    private(set) var greeting: Data = Data()

    init() {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = 0
        local.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        withUnsafePointer(to: &local) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                _ = bind(listener, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        _ = listen(listener, 16)
        var named = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &named) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                _ = getsockname(listener, generic, &length)
            }
        }
        fd = listener
        port = Int(UInt16(bigEndian: named.sin_port))

        let thread = Thread { [weak self] in
            guard let self = self else { return }
            while true {
                let client = accept(self.fd, nil, nil)
                if client < 0 { continue }
                var head = [UInt8](repeating: 0, count: 2)
                let n = read(client, &head, head.count)
                guard n == 2 else { close(client); continue }
                let ways = Int(head[1])
                var methods = [UInt8](repeating: 0, count: max(0, ways))
                if !methods.isEmpty { _ = read(client, &methods, methods.count) }
                self.greeting = Data([head[0], head[1]] + methods)
                var answer: [UInt8] = [0x05, 0x00]
                _ = write(client, answer, answer.count)
                var request = [UInt8](repeating: 0, count: 10)
                _ = read(client, &request, request.count)
                var reply: [UInt8] = [0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1, 0, 80]
                _ = write(client, reply, reply.count)
                var scratch = [UInt8](repeating: 0, count: 64)
                while read(client, &scratch, scratch.count) > 0 {}
                close(client)
            }
        }
        thread.start()
    }
}

func endpoint(_ name: String, _ port: Int) -> ProxyEndpoint {
    // A proxy of the person has no name and no password, and that is
    // nothing and not an empty text: a proxy with an empty name is a proxy
    // with a name.
    return ProxyEndpoint(id: name, name: name, type: "socks5", host: "127.0.0.1", port: port,
                         username: nil, password: nil)
}

// The greeting says what it says
//
// The number of the ways of saying who it is and the ways themselves have to
// agree, or the proxy waits for a way that never comes.
//
// The place the client wants to reach is said before anything else: a value
// that is read before it is set holds nothing, and reading it is a crash
// that has nothing to do with the thing the test is about.
let target = FlowTarget(host: "example.com", port: 443)

let recorder = RecordingProxy()
_ = LocalProxyDialer.connectAndGreet(
    endpoint: ProxyEndpoint(id: "recorded", name: "recorded", type: "socks5",
                            host: "127.0.0.1", port: recorder.port,
                            username: nil, password: nil),
    target: target, timeout: 5)
let withoutName = Array(recorder.greeting)
check("the greeting of a proxy without a name offers the way without a name",
      withoutName.count >= 3 && withoutName[0] == 0x05 && withoutName[1] == 0x01 && withoutName[2] == 0x00)
print("       the greeting without a name: \(withoutName)")

let recorder2 = RecordingProxy()
_ = LocalProxyDialer.connectAndGreet(
    endpoint: ProxyEndpoint(id: "recorded", name: "recorded", type: "socks5",
                            host: "127.0.0.1", port: recorder2.port,
                            username: "user", password: "secret"),
    target: target, timeout: 5)
let withName = Array(recorder2.greeting)
check("the greeting of a proxy with a name says how many ways there are",
      withName.count >= 4 && withName[0] == 0x05 && withName[1] == 2)
check("the ways of the greeting are the two that are said",
      withName.count >= 4 && withName[2] == 0x00 && withName[3] == 0x02)
print("       the greeting with a name: \(withName)")

// A proxy that says nothing: the greeting gives up instead of waiting
let silent = SilentProxy()
let silentEndpoint = endpoint("silent", silent.port)

var began = Date()
let silentTCP = LocalProxyDialer.connectAndGreet(endpoint: silentEndpoint, target: target, timeout: 2)
let tcpSeconds = Date().timeIntervalSince(began)
check("a proxy that says nothing does not get a connection", silentTCP == nil)
check("the greeting gives up in a moment", tcpSeconds < 8)
print("       the greeting of a silent proxy gave up after \(String(format: "%.1f", tcpSeconds)) seconds")

began = Date()
let silentUDP = LocalProxyDialer.udpAssociate(endpoint: silentEndpoint, timeout: 2)
let udpSeconds = Date().timeIntervalSince(began)
check("a proxy that says nothing does not get an association", silentUDP == nil)
check("the greeting of an association gives up in a moment", udpSeconds < 8)
print("       the greeting of an association gave up after \(String(format: "%.1f", udpSeconds)) seconds")

// A proxy that answers: the connection is made
let polite = PoliteProxy()
let politeEndpoint = endpoint("polite", polite.port)
began = Date()
let politeTCP = LocalProxyDialer.connectAndGreet(endpoint: politeEndpoint, target: target, timeout: 5)
check("a proxy that answers gets a connection", politeTCP != nil)
check("the connection is not slow", Date().timeIntervalSince(began) < 5)
if let fd = politeTCP {
    Darwin.close(fd)
}

// The chain of proxies is the same story
let silentChain = LocalProxyDialer.connectAndGreetChain(
    hops: [silentEndpoint, politeEndpoint], target: target, timeout: 2)
check("a chain with a proxy that says nothing does not get a connection", silentChain == nil)

let politeChain = LocalProxyDialer.connectAndGreetChain(
    hops: [politeEndpoint, politeEndpoint], target: target, timeout: 5)
check("a chain of proxies that answer gets a connection", politeChain != nil)
if let fd = politeChain {
    Darwin.close(fd)
}

if fails > 0 {
    print("\(fails) check(s) failed")
    exit(1)
}
print("all checks passed")
