import Foundation

// TrafficMerge: the traffic of the window when the proxy server runs.
//
// The traffic of this machine and the traffic of the clients of the network
// are counted together, per proxy.

var fails = 0
func t(_ name: String, _ ok: Bool) { if !ok { fails += 1; print("FAIL \(name)") } }

func total(_ proxy: String, _ connections: Int, _ up: Int64, _ down: Int64,
           known: Bool = true) -> TrafficMerge.Total {
    return TrafficMerge.Total(proxy: proxy, connections: connections,
                              bytesUp: up, bytesDown: down, bytesKnown: known)
}

// nothing at all gives no rows
let empty = TrafficMerge.rows(machine: [], clients: [])
t("no traffic gives no rows", empty.isEmpty)

// only the traffic of the machine
let machineOnly = TrafficMerge.rows(machine: [total("proxy1", 2, 100, 200)], clients: [])
t("the traffic of the machine gives a row", machineOnly.count == 1)
if let row = machineOnly.first {
    t("the row keeps the proxy", row.proxy == "proxy1")
    t("the row keeps the connections", row.connections == 2)
    t("the row keeps the bytes", row.bytesUp == 100 && row.bytesDown == 200)
    t("the bytes of a proxy are known", row.bytesKnown)
}

// only the traffic of the clients
let clientsOnly = TrafficMerge.rows(machine: [], clients: [total("proxy1", 3, 10, 20)])
t("the traffic of the clients gives a row", clientsOnly.count == 1)
if let row = clientsOnly.first {
    t("the row keeps the connections of the client", row.connections == 3)
    t("the row keeps the bytes of the client", row.bytesUp == 10 && row.bytesDown == 20)
}

// the same proxy for both: one row that carries both
let both = TrafficMerge.rows(machine: [total("proxy1", 2, 100, 200)],
                             clients: [total("proxy1", 3, 10, 20)])
t("one proxy of both kinds of traffic gives one row", both.count == 1)
if let row = both.first {
    t("the connections of both are counted", row.connections == 5)
    t("the bytes of both are counted", row.bytesUp == 110 && row.bytesDown == 220)
}

// different proxies keep their own rows
let twoProxies = TrafficMerge.rows(machine: [total("proxy1", 2, 100, 200)],
                                   clients: [total("proxy2", 3, 10, 20)])
t("two proxies give two rows", twoProxies.count == 2)
t("both proxies are there", Set(twoProxies.map { $0.proxy }) == ["proxy1", "proxy2"])

// a blocked connection moves no traffic and is not a proxy, so it has no row
let blocked = TrafficMerge.rows(machine: [total("BLOCK", 1, 0, 0)],
                                clients: [total("BLOCK", 2, 0, 0)])
t("a blocked connection has no row", blocked.isEmpty)

// the bytes of a direct connection of the machine are never seen
let directMachine = TrafficMerge.rows(machine: [total("Direct", 1, 0, 0, known: false)], clients: [])
t("the direct connection of the machine has a row", directMachine.count == 1)
t("the bytes of the direct connection of the machine are not known",
  directMachine.first?.bytesKnown == false)

// the server relays a direct connection itself, so it knows its bytes
let directServer = TrafficMerge.rows(machine: [], clients: [total("Direct", 1, 30, 40)])
t("the direct connection of the clients has a row", directServer.count == 1)
t("the bytes of the direct connection of the clients are known",
  directServer.first?.bytesKnown == true)

// one part that was not seen makes the whole row unknown
let directBoth = TrafficMerge.rows(machine: [total("Direct", 1, 0, 0, known: false)],
                                   clients: [total("Direct", 1, 30, 40)])
t("the direct connection of both has a row", directBoth.count == 1)
if let row = directBoth.first {
    t("the bytes of the direct connection of both are counted",
      row.bytesUp == 30 && row.bytesDown == 40)
    t("the bytes of the direct connection of both are not known", !row.bytesKnown)
}

// a proxy that is only a proxy keeps its bytes known
let knownProxyBoth = TrafficMerge.rows(machine: [total("proxy1", 1, 5, 5)],
                                       clients: [total("proxy1", 1, 5, 5)])
t("the bytes of a proxy of both kinds of traffic are known",
  knownProxyBoth.first?.bytesKnown == true)

if fails == 0 { print("trafficmerge_tests: OK") } else { print("trafficmerge_tests: \(fails) failure(s)"); exit(1) }
