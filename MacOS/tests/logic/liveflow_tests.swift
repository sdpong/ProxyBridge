import Foundation

// LiveFlowRegistry is what the app's live connections list is built on: it keeps the flows that
// are proxied right now, counts their bytes and lets one of them be terminated.

var fails = 0
func t(_ name: String, _ ok: Bool) { if !ok { fails += 1; print("FAIL \(name)") } }

let registry = LiveFlowRegistry()

// an empty registry lists nothing
t("an empty registry has no flows", registry.snapshot().isEmpty && registry.count() == 0)

// registering hands out an id and the flow shows up with what was given
var teardowns = 0
let id1 = registry.register(proto: "TCP", process: "curl", destination: "example.com", port: 443, proxy: "SOCKS5 127.0.0.1:1080") {
    teardowns += 1
}
t("a registered flow gets an id", id1 != 0)
t("a registered flow is listed", registry.count() == 1 && registry.snapshot().count == 1)
if let f = registry.snapshot().first {
    t("the flow keeps its protocol", f.proto == "TCP")
    t("the flow keeps its process", f.process == "curl")
    t("the flow keeps its destination", f.destination == "example.com")
    t("the flow keeps its port", f.port == 443)
    t("the flow keeps its proxy", f.proxy == "SOCKS5 127.0.0.1:1080")
    t("a new flow has moved no bytes", f.bytesUp == 0 && f.bytesDown == 0)
} else {
    t("the flow is listed", false)
}

// every flow gets its own id
let id2 = registry.register(proto: "UDP", process: "game", destination: "unknown", port: 0, proxy: "SOCKS5 127.0.0.1:1080") { teardowns += 1 }
t("ids are unique", id1 != id2)
t("both flows are listed", registry.count() == 2)

// the newest flow comes first
let ordered = registry.snapshot()
t("the newest flow is first", ordered.first?.id == id2)

// bytes are counted per direction
registry.note(id: id1, up: 100, down: 250)
if let f = registry.snapshot().first(where: { $0.id == id1 }) {
    t("the bytes are counted", f.bytesUp == 100 && f.bytesDown == 250)
} else {
    t("the flow is still listed", false)
}

// a note without bytes is not activity: an open but quiet flow keeps its idle time
let quiet = registry.snapshot().first(where: { $0.id == id1 })!
registry.note(id: id1)
t("a note without bytes changes nothing", registry.snapshot().first(where: { $0.id == id1 })?.lastActivity == quiet.lastActivity)

// the idle time is the time since the last traffic
let later = quiet.lastActivity.addingTimeInterval(42)
t("the idle time is the time since the last traffic", quiet.idleSeconds(now: later) == 42)
t("the age is the time since the flow started", quiet.ageSeconds(now: quiet.startedAt.addingTimeInterval(7)) == 7)

// a udp flow learns its destination when the first datagram arrives
registry.setDestination("1.2.3.4", for: id2)
t("the destination can be set later", registry.snapshot().first(where: { $0.id == id2 })?.destination == "1.2.3.4")

// terminating runs the teardown and drops the flow
t("terminating a flow works", registry.terminate(id: id1))
t("the teardown ran once", teardowns == 1)
t("the terminated flow is gone", registry.count() == 1 && registry.snapshot().first?.id == id2)

// the same flow cannot be terminated twice
t("terminating twice fails", !registry.terminate(id: id1))
t("the teardown did not run again", teardowns == 1)

// terminating a flow that does not exist fails
t("terminating an unknown flow fails", !registry.terminate(id: 9999))

// removing a flow that ended on its own does not tear anything down
registry.remove(id: id2)
t("a removed flow is gone", registry.count() == 0)
t("removing does not tear down", teardowns == 1)

// removeAll drops everything
registry.register(proto: "TCP", process: "a", destination: "b", port: 1, proxy: "c") { teardowns += 1 }
registry.register(proto: "TCP", process: "d", destination: "e", port: 2, proxy: "f") { teardowns += 1 }
t("two flows are listed", registry.count() == 2)
registry.removeAll()
t("removeAll drops every flow", registry.count() == 0 && registry.snapshot().isEmpty)
t("removeAll does not tear down", teardowns == 1)

if fails == 0 { print("liveflow_tests: OK") } else { print("liveflow_tests: \(fails) failure(s)"); exit(1) }
