import Foundation
import Network

// A udp socket that talks to one address directly, without a proxy.
//
// The traffic of the local network does not belong to a proxy on the internet:
// the answer has to come back through the proxy, and a server that is not there
// does not answer at all.
//
// The socket is a plain udp socket of its own, so it is not tied to the flow
// of the application: the flow is carried by the extension, and this is the
// other end of it.
final class DirectUDPSession {

    let host: String
    let port: UInt16

    private let connection: NWConnection
    private let queue: DispatchQueue

    init(host: String, port: UInt16, queue: DispatchQueue) {
        self.host = host
        self.port = port
        self.queue = queue
        self.connection = NWConnection(host: NWEndpoint.Host(host),
                                       port: NWEndpoint.Port(rawValue: port) ?? .any,
                                       using: .udp)
    }

    func start() {
        connection.start(queue: queue)
    }

    // Sends one datagram to the address.
    func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        connection.send(content: data, completion: .contentProcessed { error in
            completion(error)
        })
    }

    // Waits for the answer. The caller has to call it again for the next one.
    func receive(_ handler: @escaping (Data?, Error?) -> Void) {
        connection.receiveMessage { data, _, _, error in
            handler(data, error)
        }
    }

    func cancel() {
        connection.cancel()
    }
}
