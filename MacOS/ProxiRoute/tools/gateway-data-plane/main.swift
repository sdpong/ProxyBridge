import Foundation
import Darwin

// The data plane of the gateway mode, on its own, for a test by hand.
//
// This is the code of the app that carries the traffic of the network, built
// as a program of its own. It is the same file that the app uses - the file
// is compiled into this program as well - so that a test is a test of the
// thing that ships and not of a copy of it.
//
// Two ways of using it:
//
//   1. with the helper of the gateway mode running, it asks the helper where
//      every connection was going, the way the app does. This needs the
//      rules of the filter to be in place, and it needs a client of the
//      network: another machine.
//
//   2. with --original, it is told where every connection was going, and it
//      does not ask anybody. This needs nothing at all: the machine itself
//      can be the client. It is the way to check that the traffic is carried
//      from one end to the other.
//
// Usage:
//
//   gateway-data-plane [--port <port>] [--proxy <type>:<host>:<port>]
//                      [--original <host>:<port>]
//
//   --proxy     everything goes through this proxy (socks5, socks4 or http)
//   --original  every connection is pretended to have been going here

// ---------------------------------------------------------------- the words

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("gateway-data-plane: \(message)\n".utf8))
    exit(2)
}

// ---------------------------------------------------------------- the arguments

var port = GatewayDataPlane.redirectPort
var proxyEndpoint: ProxyEndpoint?
var original: (address: String, port: Int)?

var arguments = Array(CommandLine.arguments.dropFirst())
var index = 0
while index < arguments.count {
    let argument = arguments[index]
    switch argument {
    case "--port":
        index += 1
        guard index < arguments.count, let value = Int(arguments[index]), value > 0, value < 65536 else {
            fail("--port needs a port")
        }
        port = value
    case "--proxy":
        index += 1
        guard index < arguments.count else { fail("--proxy needs a proxy") }
        let parts = arguments[index].split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3, let proxyPort = Int(parts[2]) else {
            fail("--proxy wants <type>:<host>:<port>")
        }
        let type = parts[0].lowercased()
        guard type == "socks5" || type == "socks4" || type == "http" else {
            fail("--proxy wants socks5, socks4 or http")
        }
        proxyEndpoint = ProxyEndpoint(id: "test", name: "the proxy of the test", type: type,
                                     host: parts[1], port: proxyPort,
                                     username: nil, password: nil)
    case "--original":
        index += 1
        guard index < arguments.count else { fail("--original needs a place") }
        let parts = arguments[index].split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let originalPort = Int(parts[1]) else {
            fail("--original wants <host>:<port>")
        }
        original = (parts[0], originalPort)
    case "--help", "-h":
        print("""
        usage: gateway-data-plane [--port <port>] [--proxy <type>:<host>:<port>]
                                  [--original <host>:<port>]
        """)
        exit(0)
    default:
        fail("unknown argument: \(argument)")
    }
    index += 1
}

// ---------------------------------------------------------------- the plane

let plane = GatewayDataPlane()

if let original {
    // The place every connection is pretended to have been going. The plane
    // is asked as if the kernel had answered, so that the rest of the way is
    // the same way it is when the helper is there.
    plane.lookupHandler = { _, _, _, _ in
        var answer = GatewayProtocol.Response.success()
        answer.originalAddress = original.address
        answer.originalPort = original.port
        return answer
    }
}

plane.logHandler = { message, level in
    print("[\(level)] \(message)")
    fflush(stdout)
}

if let proxyEndpoint {
    plane.update(rules: [EngineRule(action: proxyEndpoint.id)],
                 proxies: [proxyEndpoint],
                 chains: [:])
} else {
    plane.update(rules: [], proxies: [], chains: [:])
}

// ---------------------------------------------------------------- the run

print("the data plane is listening on 127.0.0.1:\(port)")
if let original {
    print("every connection is pretended to have been going to \(original.address):\(original.port)")
}
if proxyEndpoint == nil {
    print("the traffic goes straight out")
} else {
    print("the traffic goes through \(proxyEndpoint!.label)")
}
fflush(stdout)

switch plane.start(port: port) {
case .failure(let failure):
    fail(failure.reason)
case .success:
    break
}

// The program runs until it is stopped.
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
while true {
    sleep(3600)
}
