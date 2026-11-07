import Foundation
import Network

// Whether a proxy of a chain is there.
//
// The probe is a plain connection from the extension. The traffic of the
// extension itself is never proxied, so the probe reaches the proxy directly
// and says something about the proxy alone.
//
// It lives in a file of its own because the network framework and the network
// extension framework both have an endpoint type, and only one of them can be
// imported where the other is used.
enum ChainHealthProbe {

    // How long a probe may take before the hop counts as down.
    static let timeout: TimeInterval = 8

    // Asks the hop whether it is there.
    //
    // The answer is given once, no matter how many ways the probe ends.
    static func probe(_ hop: ChainHealth.Hop, answer: @escaping (Bool) -> Void) {
        let box = Box(answer: answer)
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: hop.port)) else {
            box.once { answer(false) }
            return
        }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(hop.host), port: port)
        let connection = NWConnection(to: endpoint, using: .tcp)

        // a proxy that accepts the connection and then says nothing is not alive
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + timeout, repeating: .never)
        timer.setEventHandler {
            box.once {
                connection.cancel()
                answer(false)
            }
        }
        timer.resume()

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                timer.cancel()
                if hop.type.lowercased() == "socks5" {
                    probeSOCKS5Greeting(hop: hop, connection: connection, box: box)
                } else {
                    box.once {
                        connection.cancel()
                        answer(true)
                    }
                }
            case .failed:
                timer.cancel()
                box.once {
                    connection.cancel()
                    answer(false)
                }
            default:
                break
            }
        }
        connection.start(queue: DispatchQueue.global(qos: .utility))
    }

    // The smallest thing that says "this is a socks5 server": the greeting and
    // the two bytes that answer it.
    private static func probeSOCKS5Greeting(hop: ChainHealth.Hop, connection: NWConnection, box: Box) {
        connection.send(content: Data([0x05, 0x01, 0x00]), completion: .contentProcessed { error in
            if error != nil {
                box.once {
                    connection.cancel()
                    box.answer(false)
                }
                return
            }
            connection.receive(minimumIncompleteLength: 2, maximumLength: 2) { data, _, _, error in
                box.once {
                    connection.cancel()
                    let alive = (error == nil && data?.count == 2 && data?[0] == 0x05)
                    box.answer(alive)
                }
            }
        })
    }

    // A probe has one answer. The first one counts, the later ones are ignored.
    private final class Box {
        let answer: (Bool) -> Void
        private let lock = NSLock()
        private var done = false

        init(answer: @escaping (Bool) -> Void) {
            self.answer = answer
        }

        func once(_ body: () -> Void) {
            lock.lock()
            defer { lock.unlock() }
            if done { return }
            done = true
            body()
        }
    }
}
