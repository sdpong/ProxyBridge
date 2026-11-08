import Foundation

// The health of the proxies a chain walks through.
//
// A chain is only as good as its weakest hop: when one of them is down, every
// connection that uses the chain fails, even though the other hops are fine.
// The extension probes the hops of every chain from time to time, skips the
// ones that do not answer, and puts them back when they answer again.
//
// The rules are kept apart from the sockets so that they can be tested.
enum ChainHealth {

    // What the last probe of a hop said.
    enum State: String {
        // nothing was probed yet
        case unknown
        // the hop answered
        case healthy
        // the hop did not answer
        case unreachable
    }

    // One proxy of a chain, as far as the health is concerned.
    struct Hop: Equatable {
        // the id of the proxy in the app, so the state can be remembered per proxy
        let id: String
        let host: String
        let port: Int
        // socks5, socks4 or http
        let type: String

        var label: String {
            return "\(type.uppercased()) \(host):\(port)"
        }
    }

    // How often the hops are probed.
    //
    // Ten minutes: a proxy that is down is usually down for a while, and a probe
    // every minute would only make noise.
    static let probeInterval: TimeInterval = 600

    // The hops a chain walks through, minus the ones that are known to be down.
    //
    // A hop that is only suspected to be down is still used: the state can be
    // old, and a chain that quietly drops a hop sends the traffic out of the
    // wrong place.
    static func usable(_ hops: [Hop], state: [String: State]) -> [Hop] {
        let up = hops.filter { state[$0.id] != .unreachable }
        // every hop is down: the chain is tried as it is, so the user sees the
        // failure of the proxy instead of a silent direct connection
        return up.isEmpty ? hops : up
    }

    // The hops whose probe is due.
    //
    // A hop that was never probed is due right away, so a chain that was just
    // set up does not wait ten minutes for its first answer.
    static func due(_ hops: [Hop], lastProbe: [String: Date], now: Date, interval: TimeInterval = probeInterval) -> [Hop] {
        return hops.filter { hop in
            guard let last = lastProbe[hop.id] else { return true }
            return now.timeIntervalSince(last) >= interval
        }
    }

    // The state a hop moves to when the probe says so.
    static func state(alive: Bool) -> State {
        return alive ? .healthy : .unreachable
    }
}
