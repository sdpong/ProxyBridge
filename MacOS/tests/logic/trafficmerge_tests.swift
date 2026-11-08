import Foundation

// TrafficMerge: the traffic of the window when the proxy server runs.
//
// The traffic of this machine and the traffic of the clients of the network
// are counted apart: every source has a line of its own for every proxy the
// traffic went through.

var fails = 0
func t(_ name: String, _ ok: Bool) { if !ok { fails += 1; print("FAIL \(name)") } }

func total(_ source: TrafficMerge.Source, _ proxy: String, _ connections: Int,
           _ up: Int64, _ down: Int64, known: Bool = true) -> TrafficMerge.Total {
    return TrafficMerge.Total(source: source, proxy: proxy, connections: connections,
                              bytesUp: up, bytesDown: down, bytesKnown: known)
}

// nothing at all gives no rows
let empty = TrafficMerge.rows(machine: [], clients: [])
t("no traffic gives no rows", empty.isEmpty)

// only the traffic of the machine
let machineOnly = TrafficMerge.rows(machine: [total(.machine, "proxy1", 2, 100, 200)], clients: [])
t("the traffic of the machine gives a row", machineOnly.count == 1)
if let row = machineOnly.first {
    t("the row keeps the proxy", row.proxy == "proxy1")
    t("the row keeps the source", row.source == .machine)
    t("the row keeps the connections", row.connections == 2)
    t("the row keeps the bytes", row.bytesUp == 100 && row.bytesDown == 200)
    t("the bytes of a proxy are known", row.bytesKnown)
}

// only the traffic of the clients
let clientsOnly = TrafficMerge.rows(machine: [], clients: [total(.client("192.168.1.2"), "proxy1", 3, 10, 20)])
t("the traffic of the clients gives a row", clientsOnly.count == 1)
if let row = clientsOnly.first {
    t("the row keeps the client", row.source == .client("192.168.1.2"))
    t("the row keeps the connections of the client", row.connections == 3)
    t("the row keeps the bytes of the client", row.bytesUp == 10 && row.bytesDown == 20)
}

// the machine and a client through the same proxy: two rows, one for each
let both = TrafficMerge.rows(machine: [total(.machine, "proxy1", 2, 100, 200)],
                             clients: [total(.client("192.168.1.2"), "proxy1", 3, 10, 20)])
t("the machine and a client get a row each", both.count == 2)
if let machineRow = both.first(where: { $0.source.isMachine }) {
    t("the row of the machine keeps its own numbers", machineRow.connections == 2 && machineRow.bytesUp == 100)
}
if let clientRow = both.first(where: { !$0.source.isMachine }) {
    t("the row of the client keeps its own numbers", clientRow.connections == 3 && clientRow.bytesUp == 10)
}

// two clients through the same proxy: two rows, one for each client
let twoClients = TrafficMerge.rows(machine: [],
                                   clients: [total(.client("192.168.1.2"), "proxy1", 1, 10, 10),
                                             total(.client("192.168.1.3"), "proxy1", 2, 20, 20)])
t("two clients get a row each", twoClients.count == 2)
t("both clients are there",
  Set(twoClients.map { $0.source.clientAddress ?? "" }) == ["192.168.1.2", "192.168.1.3"])

// the same client through two proxies: two rows
let twoProxies = TrafficMerge.rows(machine: [total(.client("192.168.1.2"), "proxy1", 1, 10, 10),
                                              total(.client("192.168.1.2"), "proxy2", 2, 20, 20)], clients: [])
t("one client through two proxies gets two rows", twoProxies.count == 2)

// the same source and the same proxy twice: one row with both
let twice = TrafficMerge.rows(machine: [total(.machine, "proxy1", 2, 100, 200),
                                        total(.machine, "proxy1", 3, 10, 20)], clients: [])
t("the same source and proxy are counted together", twice.count == 1)
if let row = twice.first {
    t("the connections of both are counted", row.connections == 5)
    t("the bytes of both are counted", row.bytesUp == 110 && row.bytesDown == 220)
}

// a blocked connection moves no traffic and is not a proxy, so it has no row
let blocked = TrafficMerge.rows(machine: [total(.machine, "BLOCK", 1, 0, 0)],
                                clients: [total(.client("192.168.1.2"), "BLOCK", 2, 0, 0)])
t("a blocked connection has no row", blocked.isEmpty)

// the bytes of a direct connection of the machine are never seen
let directMachine = TrafficMerge.rows(machine: [total(.machine, "Direct", 1, 0, 0, known: false)], clients: [])
t("the direct connection of the machine has a row", directMachine.count == 1)
t("the bytes of the direct connection of the machine are not known",
  directMachine.first?.bytesKnown == false)

// the server relays a direct connection itself, so it knows its bytes
let directClient = TrafficMerge.rows(machine: [], clients: [total(.client("192.168.1.2"), "Direct", 1, 30, 40)])
t("the direct connection of the clients has a row", directClient.count == 1)
t("the bytes of the direct connection of the clients are known",
  directClient.first?.bytesKnown == true)

// one part that was not seen makes the whole row unknown
let directBoth = TrafficMerge.rows(machine: [total(.machine, "Direct", 1, 0, 0, known: false)],
                                   clients: [total(.client("192.168.1.2"), "Direct", 1, 30, 40)])
t("the direct connection of the machine and of a client get a row each", directBoth.count == 2)
if let machineRow = directBoth.first(where: { $0.source.isMachine }) {
    t("the bytes of the direct connection of the machine are not known", !machineRow.bytesKnown)
}
if let clientRow = directBoth.first(where: { !$0.source.isMachine }) {
    t("the bytes of the direct connection of the client are known", clientRow.bytesKnown)
    t("the bytes of the direct connection of the client are counted",
      clientRow.bytesUp == 30 && clientRow.bytesDown == 40)
}

// the order of the sources: the machine first, the clients by address
let ordered = TrafficMerge.Source.ordered([.client("192.168.1.3"), .machine, .client("192.168.1.2")])
t("the machine comes first", ordered.first == .machine)
t("the clients come by address", ordered.dropFirst().map { $0.clientAddress ?? "" } == ["192.168.1.2", "192.168.1.3"])

// a source that is told twice is only listed once
let once = TrafficMerge.Source.ordered([.machine, .machine, .client("192.168.1.2")])
t("a source is listed once", once.count == 2)

if fails == 0 { print("trafficmerge_tests: OK") } else { print("trafficmerge_tests: \(fails) failure(s)"); exit(1) }
