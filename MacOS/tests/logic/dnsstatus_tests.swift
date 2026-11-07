// DNSStatusLine: the line the extension writes about the DNS proxy, and the way
// the app reads it back. Compiled as main.swift by run.sh.
import Foundation

var fails = 0
func t(_ name: String, _ ok: Bool) { if !ok { fails += 1; print("FAIL", name) } }

// what the extension writes
let line = DNSStatusWriter.make(running: true,
                              queries: 12,
                              answers: 11,
                              names: 7,
                              lastName: "api.dia.es",
                              lastAddresses: "0.0.0.56")
t("the line starts with the tag", line.hasPrefix("DNSStatus "))
t("the line says it is running", line.contains("running"))

// what the app reads back
guard let status = DNSStatus.parse(line) else {
    t("the line is read back", false)
    exit(1)
}
t("the line is read back", true)
t("the state comes back", status.running)
t("the number of queries comes back", status.queries == 12)
t("the number of answers comes back", status.answers == 11)
t("the number of names comes back", status.names == 7)
t("the last name comes back", status.lastName == "api.dia.es")
t("the last addresses come back", status.lastAddresses == "0.0.0.56")

// a provider that has not answered anything yet
let empty = DNSStatusWriter.make(running: true,
                               queries: 0,
                               answers: 0,
                               names: 0,
                               lastName: "",
                               lastAddresses: "")
guard let emptyStatus = DNSStatus.parse(empty) else {
    t("an empty status is read back", false)
    exit(1)
}
t("an empty status is read back", true)
t("an empty status has no name", emptyStatus.lastName.isEmpty)
t("an empty status has no addresses", emptyStatus.lastAddresses.isEmpty)

// a provider that stopped
let stopped = DNSStatusWriter.make(running: false,
                                 queries: 3,
                                 answers: 2,
                                 names: 1,
                                 lastName: "api.dia.es",
                                 lastAddresses: "0.0.0.56")
guard let stoppedStatus = DNSStatus.parse(stopped) else {
    t("a stopped status is read back", false)
    exit(1)
}
t("a stopped status is read back", true)
t("a stopped status says so", stoppedStatus.running == false)

// an ipv6 answer has colons in it, the line must survive it
let six = DNSStatusWriter.make(running: true,
                              queries: 1,
                              answers: 1,
                              names: 1,
                              lastName: "api.dia.es",
                              lastAddresses: "fd00:696e::ffff:0:38")
guard let sixStatus = DNSStatus.parse(six) else {
    t("an ipv6 answer is read back", false)
    exit(1)
}
t("an ipv6 answer is read back", sixStatus.lastAddresses == "fd00:696e::ffff:0:38")

// a line that is not a status line is not read as one
t("another line is not a status", DNSStatus.parse("Connection TCP Dia -> 0.0.0.56:443 via SOCKS5 127.0.0.1:9991 (rule 16)") == nil)
t("an empty line is not a status", DNSStatus.parse("") == nil)

// the newest status out of a list of log lines
let lines = [
    ExtensionLogReader.Line(date: Date(), text: "DNSStatus running queries 1 answers 1 names 1 last a.test -> 1.1.1.1", connection: nil, flowEvent: nil, proxyTotals: nil, level: "INFO"),
    ExtensionLogReader.Line(date: Date(), text: "DNSStatus running queries 9 answers 8 names 4 last b.test -> 2.2.2.2", connection: nil, flowEvent: nil, proxyTotals: nil, level: "INFO")
]
guard let newest = DNSStatus.newest(in: lines) else {
    t("the newest status is found", false)
    exit(1)
}
t("the newest status is found", newest.queries == 9 && newest.lastName == "b.test")
t("a list without a status gives nothing", DNSStatus.newest(in: []) == nil)

print(fails == 0 ? "dns status tests: ALL PASS" : "dns status tests: \(fails) FAILED")
exit(fails == 0 ? 0 : 1)
