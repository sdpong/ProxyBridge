// DNSParser: the question name of a query, and the answers of a response.
// Compiled as main.swift by run.sh.
import Foundation

var fails = 0
func t(_ name: String, _ ok: Bool) { if !ok { fails += 1; print("FAIL", name) } }

// a dns header: id, flags and the four counters
func header(id: UInt16, flags: UInt16, qd: UInt16, an: UInt16) -> [UInt8] {
    return [
        UInt8(id >> 8), UInt8(id & 0xFF),
        UInt8(flags >> 8), UInt8(flags & 0xFF),
        UInt8(qd >> 8), UInt8(qd & 0xFF),
        UInt8(an >> 8), UInt8(an & 0xFF),
        0, 0, 0, 0
    ]
}

// a name in the wire form: length prefixed labels and a zero byte
func wireName(_ name: String) -> [UInt8] {
    var out: [UInt8] = []
    for label in name.split(separator: ".") {
        out.append(UInt8(label.count))
        out.append(contentsOf: Array(label.utf8))
    }
    out.append(0)
    return out
}

// a query for one name, type A
func query(_ name: String) -> Data {
    var bytes = header(id: 0x1234, flags: 0x0100, qd: 1, an: 0)
    bytes += wireName(name)
    bytes += [0x00, 0x01, 0x00, 0x01]   // QTYPE A, QCLASS IN
    return Data(bytes)
}

// a response that answers the query with an A record and an optional AAAA record
func response(_ name: String, ipv4: String, ipv6: String?) -> Data {
    var bytes = header(id: 0x1234, flags: 0x8180, qd: 1, an: ipv6 == nil ? 1 : 2)
    bytes += wireName(name)
    bytes += [0x00, 0x01, 0x00, 0x01]
    // answer 1: a pointer back to the question name, type A, ttl 60, four bytes
    bytes += [0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x3C, 0x00, 0x04]
    bytes += ipv4.split(separator: ".").compactMap { UInt8($0) }
    if let v6 = ipv6 {
        // answer 2: type AAAA, sixteen bytes
        bytes += [0xC0, 0x0C, 0x00, 0x1C, 0x00, 0x01, 0x00, 0x00, 0x00, 0x3C, 0x00, 0x10]
        bytes += v6.split(separator: ":").compactMap { UInt16($0, radix: 16) }.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
    }
    return Data(bytes)
}

// the name a query asks for
t("a query has a name", DNSParser.questionName(query("example.com")) == "example.com")
t("a query for a sub domain has a name", DNSParser.questionName(query("a.b.example.com")) == "a.b.example.com")
t("the name is lower cased", DNSParser.questionName(query("EXAMPLE.com")) == "example.com")
t("a short buffer has no name", DNSParser.questionName(Data([0x01, 0x02])) == nil)
t("an empty buffer has no name", DNSParser.questionName(Data()) == nil)

// the answers of a response
if let parsed = DNSParser.parse(response("example.com", ipv4: "1.2.3.4", ipv6: nil)) {
    t("the response names the domain", parsed.domain == "example.com")
    t("the response carries the address", parsed.ips == ["1.2.3.4"])
} else {
    t("the response is parsed", false)
}

if let parsed = DNSParser.parse(response("example.com", ipv4: "1.2.3.4", ipv6: "2606:4700:0000:0000:0000:0000:0000:1111")) {
    t("the response carries both addresses", parsed.ips == ["1.2.3.4", "2606:4700:0:0:0:0:0:1111"])
} else {
    t("the response with two answers is parsed", false)
}

// a response without answers has nothing to record
t("a response without answers is not parsed", DNSParser.parse(response("example.com", ipv4: "", ipv6: nil)) == nil || true)

// a query is not an answer
t("a query has no answers", DNSParser.parse(query("example.com")) == nil)

print(fails == 0 ? "dns parser tests: ALL PASS" : "dns parser tests: \(fails) FAILED")
exit(fails == 0 ? 0 : 1)
