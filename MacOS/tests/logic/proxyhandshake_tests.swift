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
                    // the greeting: the version and the way of saying who it is
                    var greeting = [UInt8](repeating: 0, count: 3)
                    let read1 = read(client, &greeting, greeting.count)
                    if read1 <= 0 { break }
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

func endpoint(_ name: String, _ port: Int) -> ProxyEndpoint {
    return ProxyEndpoint(id: name, name: name, type: "socks5", host: "127.0.0.1", port: port,
                         username: "", password: "")
}

// A proxy that says nothing: the greeting gives up instead of waiting
let silent = SilentProxy()
let silentEndpoint = endpoint("silent", silent.port)
let target = FlowTarget(host: "example.com", port: 443)

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
