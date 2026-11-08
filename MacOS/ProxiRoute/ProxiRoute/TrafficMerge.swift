import Foundation

// The traffic of the window when the proxy server runs.
//
// This machine is a client of its own proxy as well: the traffic of the
// machine goes through the tunnel, and the traffic of the clients of the
// network goes through the proxy server. Both leave the machine by the
// proxies of the rules, so the table says per source and per proxy what it
// carried.
enum TrafficMerge {
    // Where the traffic comes from.
    //
    // The traffic of the machine and the traffic of the clients of the
    // network are counted apart: they are told apart by the address of the
    // client, because a client on the network has no program.
    enum Source: Hashable {
        // the traffic of this machine, carried by the tunnel
        case machine
        // the traffic of a client of the network, carried by the proxy server.
        // the address is what can be said about it.
        case client(String)

        // the source of the traffic of this machine
        static let thisMachine = Source.machine

        // whether the source is the machine itself
        var isMachine: Bool { self == .machine }

        // the address of the client, or nothing for the machine
        var clientAddress: String? {
            if case .client(let address) = self { return address }
            return nil
        }

        // the name of the source in a row of its own: two rows of the table
        // are told apart by it
        var key: String {
            if let address = clientAddress { return "client:\(address)" }
            return "machine"
        }

        // the sources in the order they are shown: the machine first, and the
        // clients of the network after it, by address
        static func ordered(_ sources: [Source]) -> [Source] {
            var seen: [Source] = []
            for source in sources where !seen.contains(source) {
                seen.append(source)
            }
            return seen.sorted { lhs, rhs in
                if lhs.isMachine != rhs.isMachine { return lhs.isMachine }
                return (lhs.clientAddress ?? "") < (rhs.clientAddress ?? "")
            }
        }
    }

    // What one proxy carried for one source.
    struct Total {
        let source: Source
        let proxy: String
        let connections: Int
        let bytesUp: Int64
        let bytesDown: Int64
        // Whether the bytes are known at all. The bytes of a direct
        // connection of the machine are not: macOS hands those flows straight
        // back to the system, so the extension never sees them. The server
        // relays a direct connection itself, so it knows its bytes.
        let bytesKnown: Bool

        init(source: Source, proxy: String, connections: Int, bytesUp: Int64, bytesDown: Int64,
             bytesKnown: Bool = true) {
            self.source = source
            self.proxy = proxy
            self.connections = connections
            self.bytesUp = bytesUp
            self.bytesDown = bytesDown
            self.bytesKnown = bytesKnown
        }
    }

    // The rows of the table: the traffic of the machine and the traffic of the
    // clients of the network, one row per source and proxy.
    //
    // A blocked connection moves no traffic and is not a proxy, so it has no
    // row - the same as in the other modes.
    static func rows(machine: [Total], clients: [Total]) -> [Total] {
        var merged: [Source: [String: Total]] = [:]

        for total in machine + clients {
            var byProxy = merged[total.source] ?? [:]
            let row = byProxy[total.proxy]
            byProxy[total.proxy] = Total(
                source: total.source,
                proxy: total.proxy,
                connections: (row?.connections ?? 0) + total.connections,
                bytesUp: (row?.bytesUp ?? 0) + total.bytesUp,
                bytesDown: (row?.bytesDown ?? 0) + total.bytesDown,
                // the bytes are only known when every part of them was seen:
                // one part that was not seen makes the whole row unknown
                bytesKnown: (row?.bytesKnown ?? true) && total.bytesKnown
            )
            merged[total.source] = byProxy
        }

        var out: [Total] = []
        for source in Source.ordered(Array(merged.keys)) {
            guard let byProxy = merged[source] else { continue }
            for total in byProxy.values where total.proxy != "BLOCK" {
                out.append(total)
            }
        }
        return out
    }
}
