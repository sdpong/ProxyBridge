import Foundation
import Network
import NetworkExtension

// The connection to an upstream proxy.
//
// The extension used to talk to the proxy with NWTCPConnection. The
// NetworkExtension framework still has it, but it is the wrapper of the
// nw_connection_t that came before the Network framework, and it is hidden
// in Swift 6. It also cannot say which interface the connection has to leave
// through: that is a property of NWParameters, and only the modern
// NWConnection takes them.
//
// So the two are put behind one small protocol. The relay code needs three
// things from a connection - write bytes, read bytes, give up - and it does
// not care which one it got.
//
// The connection that is bound to an interface is the modern one. The plain
// one is the old wrapper, kept for the case where the user did not ask for
// an interface: it is the connection the extension has always made, and
// changing it would change the behaviour of every existing setup.
protocol UpstreamConnection: AnyObject {
    func write(_ data: Data, completion: @escaping (Error?) -> Void)
    func readMinimumLength(_ minimum: Int, maximumLength: Int, completion: @escaping (Data?, Error?) -> Void)
    // the writing side is closed, the reading side stays open
    func writeClose()
    func cancel()
}

// MARK: - the old wrapper

extension NWTCPConnection: UpstreamConnection {
    func write(_ data: Data, completion: @escaping (Error?) -> Void) {
        write(data, completionHandler: completion)
    }

    func readMinimumLength(_ minimum: Int, maximumLength: Int, completion: @escaping (Data?, Error?) -> Void) {
        readMinimumLength(minimum, maximumLength: maximumLength, completionHandler: completion)
    }
}

// MARK: - the connection that knows its interface

// An NWConnection that leaves through the interface the user picked.
//
// NWConnection refuses to send or to receive before it is ready, and the
// handshake code writes and reads right away, so both are held back until
// the connection is up. The order is kept: what was written first is
// written first.
final class BoundUpstreamConnection: UpstreamConnection {

    private let connection: NWConnection
    private let lock = NSLock()
    private var isReady = false
    private var isDone = false
    private var failure: Error?
    private var queuedWrites: [(Data, (Error?) -> Void)] = []
    private var queuedRead: ((Int, Int, (Data?, Error?) -> Void))?

    init(host: String, port: String, interface: NWInterface?, queue: DispatchQueue) {
        // The endpoint is built here and not handed in: the old wrapper and
        // the modern connection want two different kinds of endpoint, and the
        // extension has the old one in its hands.
        let endpointPort = Network.NWEndpoint.Port(rawValue: UInt16(port) ?? 0) ?? Network.NWEndpoint.Port(rawValue: 0)!
        let endpoint = Network.NWEndpoint.hostPort(host: Network.NWEndpoint.Host(host), port: endpointPort)
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // no interface asked for: the system picks the route, the way it
        // always did
        if let interface = interface {
            parameters.requiredInterface = interface
        }
        connection = NWConnection(to: endpoint, using: parameters)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.becameReady()
            case .failed(let error):
                self?.failed(with: error)
            case .cancelled:
                self?.failed(with: nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func write(_ data: Data, completion: @escaping (Error?) -> Void) {
        lock.lock()
        if isDone {
            let error = failure
            lock.unlock()
            completion(error)
            return
        }
        if !isReady {
            queuedWrites.append((data, completion))
            lock.unlock()
            return
        }
        lock.unlock()
        sendNow(data, completion: completion)
    }

    func readMinimumLength(_ minimum: Int, maximumLength: Int, completion: @escaping (Data?, Error?) -> Void) {
        lock.lock()
        if isDone {
            let error = failure
            lock.unlock()
            completion(nil, error)
            return
        }
        if !isReady {
            // only one read is ever outstanding: the relay code asks for the
            // next one when the current one is answered
            queuedRead = (minimum, maximumLength, completion)
            lock.unlock()
            return
        }
        lock.unlock()
        receiveNow(minimum, maximumLength: maximumLength, completion: completion)
    }

    // The writing side is closed: the peer sees the end of the stream, and
    // the reading side stays open for the answer that is still to come.
    func writeClose() {
        connection.send(content: nil, completion: .contentProcessed { _ in })
    }

    func cancel() {
        lock.lock()
        isDone = true
        isReady = false
        let writes = queuedWrites
        queuedWrites = []
        let read = queuedRead
        queuedRead = nil
        lock.unlock()

        for (_, completion) in writes { completion(nil) }
        read?.2(nil, nil)
        connection.cancel()
    }

    // MARK: the two halves

    private func becameReady() {
        lock.lock()
        if isDone { lock.unlock(); return }
        isReady = true
        let writes = queuedWrites
        queuedWrites = []
        let read = queuedRead
        queuedRead = nil
        lock.unlock()

        for (data, completion) in writes {
            sendNow(data, completion: completion)
        }
        if let read = read {
            receiveNow(read.0, maximumLength: read.1, completion: read.2)
        }
    }

    private func failed(with error: Error?) {
        lock.lock()
        if isDone { lock.unlock(); return }
        isDone = true
        isReady = false
        failure = error
        let writes = queuedWrites
        queuedWrites = []
        let read = queuedRead
        queuedRead = nil
        lock.unlock()

        for (_, completion) in writes { completion(error) }
        read?.2(nil, error)
        connection.cancel()
    }

    private func sendNow(_ data: Data, completion: @escaping (Error?) -> Void) {
        connection.send(content: data, completion: .contentProcessed { error in
            completion(error)
        })
    }

    private func receiveNow(_ minimum: Int, maximumLength: Int, completion: @escaping (Data?, Error?) -> Void) {
        connection.receive(minimumIncompleteLength: minimum, maximumLength: maximumLength) { data, _, isComplete, error in
            if let error = error {
                completion(nil, error)
            } else if isComplete, data == nil {
                // the peer closed the connection: that is not an error, it is
                // the end of the stream
                completion(nil, nil)
            } else {
                completion(data, nil)
            }
        }
    }
}
