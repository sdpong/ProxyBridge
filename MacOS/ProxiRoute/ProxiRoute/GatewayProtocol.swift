import Foundation

// The words between the app and the helper of the gateway mode.
//
// The helper runs as root and does the three things that need root: it loads
// the rules of the packet filter, it turns the forwarding of the machine on
// and off, and it asks the kernel where a redirected connection was going.
// The app does everything else: it takes the redirected connections in, asks
// the helper where each one was going, decides by the rules where it goes,
// and carries the bytes.
//
// The two sides are separate programs, so they need a language of their own.
// It is kept here, in a file of its own, because a language that is written
// twice is a language with two meanings: the app would ask for one thing and
// the helper would hear another, and the two would only meet at runtime.
//
// The wire is a unix socket, and every message is one line of JSON. A line
// is a whole message: the socket is a stream, and the reader waits for the
// newline that ends it. JSON is used because it is already in the app and it
// carries the names of the fields, so a message says what it is without a
// manual.
//
// The socket lives in /var/run, which is the place for the things that only
// exist while the machine is up. The helper makes it, with the mode that lets
// the people of the machine talk to it and nobody else.

enum GatewayProtocol {

    // Where the socket is.
    //
    // /var/run is emptied when the machine boots, and the helper makes the
    // socket again when it starts, so nothing of it is left over from the
    // last time.
    static let socketPath = "/var/run/com.sdpong.proxiroute.helper.sock"

    // The name of the environment variable that says where the socket is.
    //
    // It is only there for the test of the helper: the test runs it as an
    // ordinary person, and an ordinary person cannot make a socket in
    // /var/run. The helper that is installed always uses the place above.
    static let socketPathVariable = "PROXIROUTE_HELPER_SOCKET"

    // Where the socket is, right now.
    //
    // The environment has the last word, and it is only the test that sets
    // it.
    static var socketPathInUse: String {
        if let path = ProcessInfo.processInfo.environment[socketPathVariable], !path.isEmpty {
            return path
        }
        return socketPath
    }

    // The name of the helper, the same in the launch daemon and in the log.
    static let helperLabel = "com.sdpong.proxiroute.helper"

    // The bundle of the helper, the same in the launch daemon and in the
    // privileged helper tools folder.
    static let helperBundleIdentifier = "com.sdpong.proxiroute.helper"

    // What the app can ask the helper to do.
    //
    // The names of the commands are the words of the language, and they are
    // written down here so that both sides spell them the same way.
    enum Command: String, Codable {
        // Is the helper there, and what is it doing?
        case status
        // Turn the gateway on: load the rules of the filter and turn the
        // forwarding of the machine on.
        case enable
        // Turn the gateway off: put the rules of the machine back and turn
        // the forwarding off.
        case disable
        // Where was this connection going before it was redirected?
        case lookup
    }

    // What the app asks.
    //
    // The fields that a command does not need are left out.
    struct Request: Codable, Equatable {
        // which command
        var command: Command
        // the interface the traffic of the network comes in through
        var interface: String?
        // the port the redirected traffic is taken in on
        var redirectPort: Int?
        // the address the redirected traffic is taken in on
        //
        // The address of this machine on the interface, and not the loopback:
        // the answer of the filter has to come from the same place the
        // traffic was sent to, or the kernel does not recognise it.
        var redirectAddress: String?
        // the addresses of the proxies of the app
        //
        // The traffic to a proxy does not go through a proxy, or the proxy
        // would be talking to itself.
        var proxyHosts: [String]?
        // the address of the client that opened the connection
        var clientAddress: String?
        // the port the client opened the connection from
        var clientPort: Int?
        // the address the connection was going to before it was redirected
        var destinationAddress: String?
        // the port the connection was going to before it was redirected
        var destinationPort: Int?
        // the protocol of the flow: "TCP" or "UDP"
        var transport: String?

        // the question of where a connection was going
        static func lookup(clientAddress: String, clientPort: Int,
                           destinationAddress: String, destinationPort: Int,
                           transport: String = "TCP") -> Request {
            return Request(command: .lookup,
                           clientAddress: clientAddress,
                           clientPort: clientPort,
                           destinationAddress: destinationAddress,
                           destinationPort: destinationPort,
                           transport: transport)
        }

        // the question of turning the gateway on
        static func enable(interface: String, redirectPort: Int,
                           redirectAddress: String? = nil,
                           proxyHosts: [String] = []) -> Request {
            return Request(command: .enable, interface: interface, redirectPort: redirectPort,
                           redirectAddress: redirectAddress, proxyHosts: proxyHosts)
        }

        // the question of turning the gateway off
        static func disable() -> Request {
            return Request(command: .disable)
        }

        // the question of whether the helper is there
        static func status() -> Request {
            return Request(command: .status)
        }
    }

    // What the helper answers.
    //
    // Every answer says whether it worked. An answer that says "it worked"
    // without saying what happened is of no use to the person in front of the
    // window, so the answers carry words that can be shown.
    struct Response: Codable, Equatable {
        // did the command do what it was asked to do
        var ok: Bool
        // what happened, in words. empty when nothing needs saying.
        var message: String?
        // the version of the helper that answered
        var version: String?

        // is the gateway on right now
        var gatewayEnabled: Bool?
        // is the filter turned on
        var filterEnabled: Bool?
        // is the forwarding of the machine on
        var forwardingEnabled: Bool?
        // the interface the traffic comes in through
        var interface: String?
        // the port the redirected traffic is taken in on
        var redirectPort: Int?
        // the address the redirected traffic is taken in on
        var redirectAddress: String?
        // the address of the client, when the answer is about one connection
        var clientAddress: String?
        // where the connection was going before it was redirected
        var originalAddress: String?
        // the port the connection was going to before it was redirected
        var originalPort: Int?

        // an answer that says it worked
        static func success(message: String? = nil, version: String? = nil) -> Response {
            return Response(ok: true, message: message, version: version)
        }

        // an answer that says it did not work, and why
        static func failure(message: String) -> Response {
            return Response(ok: false, message: message)
        }
    }

    // The version of the language.
    //
    // It is in every answer, so that an app and a helper that do not know
    // each other can say so instead of talking past each other.
    static let version = "1"

    // The one line of a message.
    //
    // The line ends with a newline, and the line has no newline in the
    // middle: a message is one line, and the reader takes everything up to
    // the first newline it sees.
    static func encode(_ request: Request) -> Data? {
        let encoder = JSONEncoder()
        guard var data = try? encoder.encode(request) else { return nil }
        data.append(0x0A)
        return data
    }

    // The one line of an answer.
    static func encode(_ response: Response) -> Data? {
        let encoder = JSONEncoder()
        guard var data = try? encoder.encode(response) else { return nil }
        data.append(0x0A)
        return data
    }

    // What a line says.
    static func decodeRequest(_ data: Data) -> Request? {
        return try? JSONDecoder().decode(Request.self, from: data)
    }

    // What a line says.
    static func decodeResponse(_ data: Data) -> Response? {
        return try? JSONDecoder().decode(Response.self, from: data)
    }
}
