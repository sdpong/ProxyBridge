import Foundation

// The traffic of the window when the proxy server runs.
//
// This machine is a client of its own proxy as well: the traffic of the
// machine goes through the tunnel, and the traffic of the clients of the
// network goes through the proxy server. Both leave the machine by the
// proxies of the rules, so the table says per proxy what it carried for both
// kinds of traffic.
enum TrafficMerge {
    // What one proxy carried.
    struct Total {
        let proxy: String
        let connections: Int
        let bytesUp: Int64
        let bytesDown: Int64
        // Whether the bytes are known at all. The bytes of a direct
        // connection of the machine are not: macOS hands those flows straight
        // back to the system, so the extension never sees them. The server
        // relays a direct connection itself, so it knows its bytes.
        let bytesKnown: Bool

        init(proxy: String, connections: Int, bytesUp: Int64, bytesDown: Int64, bytesKnown: Bool = true) {
            self.proxy = proxy
            self.connections = connections
            self.bytesUp = bytesUp
            self.bytesDown = bytesDown
            self.bytesKnown = bytesKnown
        }
    }

    // The rows of the table: the traffic of the machine and the traffic of the
    // clients of the network, counted together per proxy.
    //
    // A blocked connection moves no traffic and is not a proxy, so it has no
    // row - the same as in the other modes.
    static func rows(machine: [Total], clients: [Total]) -> [Total] {
        var merged: [String: Total] = [:]

        for total in machine + clients {
            let row = merged[total.proxy]
            merged[total.proxy] = Total(
                proxy: total.proxy,
                connections: (row?.connections ?? 0) + total.connections,
                bytesUp: (row?.bytesUp ?? 0) + total.bytesUp,
                bytesDown: (row?.bytesDown ?? 0) + total.bytesDown,
                // the bytes are only known when every part of them was seen:
                // one part that was not seen makes the whole row unknown
                bytesKnown: (row?.bytesKnown ?? true) && total.bytesKnown
            )
        }

        return merged.values.filter { $0.proxy != "BLOCK" }
    }
}
