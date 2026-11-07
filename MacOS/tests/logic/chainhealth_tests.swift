// ChainHealth: which hops of a chain are walked through, and when they are probed.
// Compiled as main.swift by run.sh.
import Foundation

var fails = 0
func t(_ name: String, _ ok: Bool) { if !ok { fails += 1; print("FAIL", name) } }

let first = ChainHealth.Hop(id: "a", host: "10.0.0.1", port: 1080, type: "socks5")
let second = ChainHealth.Hop(id: "b", host: "10.0.0.2", port: 1080, type: "socks5")
let third = ChainHealth.Hop(id: "c", host: "10.0.0.3", port: 8080, type: "http")
let hops = [first, second, third]

// a hop that answers is used
t("a hop that was never probed is used",
  ChainHealth.usable(hops, state: [:]) == hops)
// a hop that does not answer is skipped, the rest of the chain is not
let withDown = ChainHealth.usable(hops, state: ["b": .unreachable])
t("the hop that does not answer is skipped", withDown == [first, third])
t("the order is kept", withDown.map { $0.id } == ["a", "c"])
// a hop that answers is used
t("a hop that answers is used",
  ChainHealth.usable(hops, state: ["a": .healthy, "b": .healthy, "c": .healthy]) == hops)
// every hop down: the chain is tried as it is, so the user sees the failure of
// the proxy instead of a silent direct connection
let allDown = ChainHealth.usable(hops, state: ["a": .unreachable, "b": .unreachable, "c": .unreachable])
t("a chain with every hop down is still tried", allDown == hops)

// the state a probe leads to
t("a hop that answers is healthy", ChainHealth.state(alive: true) == .healthy)
t("a hop that does not answer is unreachable", ChainHealth.state(alive: false) == .unreachable)

// when a hop is probed
let now = Date(timeIntervalSince1970: 1_000_000)
t("a hop that was never probed is due", ChainHealth.due(hops, lastProbe: [:], now: now) == hops)
t("a hop that was just probed is not due",
  ChainHealth.due(hops, lastProbe: ["a": now, "b": now, "c": now], now: now).isEmpty)
// ten minutes later it is due again
let tenMinutes = now.addingTimeInterval(600)
t("a hop is due after ten minutes",
  ChainHealth.due(hops, lastProbe: ["a": now, "b": now, "c": now], now: tenMinutes) == hops)
// a minute later it is not
let oneMinute = now.addingTimeInterval(60)
t("a hop is not due after a minute",
  ChainHealth.due(hops, lastProbe: ["a": now, "b": now, "c": now], now: oneMinute).isEmpty)
// only the hop that is due is due: "b" was probed ten minutes ago, the others
// were probed five minutes ago
let mixed = ChainHealth.due(hops, lastProbe: ["a": now.addingTimeInterval(300), "b": now, "c": now.addingTimeInterval(300)], now: tenMinutes)
t("only the hop that is due is due", mixed.map { $0.id } == ["b"])

// the interval is ten minutes
t("the interval is ten minutes", ChainHealth.probeInterval == 600)

// the name of a hop
t("the name of a hop says what it is", first.label == "SOCKS5 10.0.0.1:1080")
t("the name of an http hop says what it is", third.label == "HTTP 10.0.0.3:8080")

print(fails == 0 ? "chain health tests: ALL PASS" : "chain health tests: \(fails) FAILED")
exit(fails == 0 ? 0 : 1)
