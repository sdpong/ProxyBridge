import Foundation

// The tests of the gateway mode: the language between the app and the
// helper, and the rules the helper puts into the packet filter.
//
// These are the parts that can be checked without a root and without a
// network: the rest of the gateway mode needs a machine that is really the
// gateway of a network, and that is a test a person runs by hand.

func check(_ condition: Bool, _ what: String) {
    if condition {
        print("  ok   \(what)")
    } else {
        print("  FAIL \(what)")
        exit(1)
    }
}

// ---------------------------------------------------------------- the language

print("gateway protocol tests:")

// a question goes out as one line, and the line ends with a newline
let request = GatewayProtocol.Request.enable(interface: "en0", redirectPort: 18081)
guard let encoded = GatewayProtocol.encode(request) else {
    print("  FAIL the question could not be written")
    exit(1)
}
check(encoded.last == 0x0A, "a question ends with a newline")
check(!encoded.dropLast().contains(0x0A), "a question is one line")

// the question comes back the way it went out
guard let decoded = GatewayProtocol.decodeRequest(encoded) else {
    print("  FAIL the question could not be read back")
    exit(1)
}
check(decoded == request, "a question comes back the way it went out")
check(decoded.command == .enable, "the command of the question is kept")
check(decoded.interface == "en0", "the interface of the question is kept")
check(decoded.redirectPort == 18081, "the port of the question is kept")

// the question of where a connection was going keeps all four numbers
let lookup = GatewayProtocol.Request.lookup(clientAddress: "192.168.254.140",
                                             clientPort: 54321,
                                             destinationAddress: "192.168.254.205",
                                             destinationPort: 18081)
guard let lookupData = GatewayProtocol.encode(lookup),
      let lookupBack = GatewayProtocol.decodeRequest(lookupData) else {
    print("  FAIL the question of a lookup could not be written")
    exit(1)
}
check(lookupBack.clientAddress == "192.168.254.140", "the address of the client is kept")
check(lookupBack.clientPort == 54321, "the port of the client is kept")
check(lookupBack.destinationAddress == "192.168.254.205", "the address of the destination is kept")
check(lookupBack.destinationPort == 18081, "the port of the destination is kept")
check(lookupBack.command == .lookup, "the command of a lookup is kept")
check(lookupBack.transport == "TCP", "a question about a connection says tcp")

// the question of a datagram says udp
let datagram = GatewayProtocol.Request.lookup(clientAddress: "192.168.254.140",
                                               clientPort: 54321,
                                               destinationAddress: "192.168.254.205",
                                               destinationPort: 18081,
                                               transport: "UDP")
guard let datagramData = GatewayProtocol.encode(datagram),
      let datagramBack = GatewayProtocol.decodeRequest(datagramData) else {
    print("  FAIL the question of a datagram could not be written")
    exit(1)
}
check(datagramBack.transport == "UDP", "a question about a datagram says udp")

// the address the traffic is redirected to goes with the question of turning
// the gateway on
let withAddress = GatewayProtocol.Request.enable(interface: "en0", redirectPort: 18081,
                                                  redirectAddress: "192.168.254.205",
                                                  proxyHosts: ["1.2.3.4", "proxy.example.com"])
guard let withAddressData = GatewayProtocol.encode(withAddress),
      let withAddressBack = GatewayProtocol.decodeRequest(withAddressData) else {
    print("  FAIL the question of turning on could not be written")
    exit(1)
}
check(withAddressBack.redirectAddress == "192.168.254.205", "the address of the redirect is kept")
check(withAddressBack.proxyHosts?.count == 2, "the addresses of the proxies are kept")

// an answer comes back the way it went out
let response = GatewayProtocol.Response.success(message: "The gateway is on.", version: "1")
guard let responseData = GatewayProtocol.encode(response),
      let responseBack = GatewayProtocol.decodeResponse(responseData) else {
    print("  FAIL the answer could not be written")
    exit(1)
}
check(responseBack == response, "an answer comes back the way it went out")
check(responseBack.ok, "an answer that says it worked says so")

// a refusal is a refusal
let refusal = GatewayProtocol.Response.failure(message: "The filter refused these rules.")
guard let refusalData = GatewayProtocol.encode(refusal),
      let refusalBack = GatewayProtocol.decodeResponse(refusalData) else {
    print("  FAIL the refusal could not be written")
    exit(1)
}
check(!refusalBack.ok, "a refusal does not say it worked")
check(refusalBack.message == "The filter refused these rules.", "the reason of a refusal is kept")

// something that is not a question is not read as one
check(GatewayProtocol.decodeRequest(Data("not json at all".utf8)) == nil,
      "something that is not a question is not read as one")

// the names of the commands are the words of the language, and they are the
// same on both sides
check(GatewayProtocol.Command.enable.rawValue == "enable", "the command of turning on is 'enable'")
check(GatewayProtocol.Command.disable.rawValue == "disable", "the command of turning off is 'disable'")
check(GatewayProtocol.Command.status.rawValue == "status", "the command of asking is 'status'")
check(GatewayProtocol.Command.lookup.rawValue == "lookup", "the command of asking where a connection was going is 'lookup'")

// ---------------------------------------------------------------- the rules

print("gateway filter tests:")

// the rules of the gateway say what they have to say
let rules = GatewayFilter.Rules(interface: "en0",
                                address: "192.168.254.205",
                                subnet: "192.168.254.0/24",
                                redirectPort: 18081,
                                ownAddresses: ["192.168.254.205", "192.168.254.206"],
                                proxyAddresses: ["1.2.3.4"])
let text = rules.text
check(text.contains("rdr pass on en0 proto tcp from 192.168.254.0/24 to any -> 192.168.254.205 port 18081"),
      "the traffic of the network is redirected to the app")
check(text.contains("rdr pass on en0 proto udp from 192.168.254.0/24 to any -> 192.168.254.205 port 18081"),
      "the datagrams of the network are redirected to the app as well")
check(text.contains("no rdr on en0 from 192.168.254.205 to any"),
      "the traffic of this machine is not redirected")
check(text.contains("no nat on en0 from 192.168.254.205 to any"),
      "the traffic of this machine is not translated either")
check(text.contains("no rdr on en0 from 192.168.254.206 to any"),
      "the traffic of this machine is not redirected from any of its addresses")
check(text.contains("no rdr on en0 to 192.168.254.205"),
      "the traffic that is meant for this machine is not redirected")
check(text.contains("no rdr on en0 from 192.168.254.0/24 to 1.2.3.4"),
      "the traffic to a proxy does not go through a proxy")
check(text.contains("nat on en0 from 192.168.254.0/24 to any -> (en0)"),
      "the clients keep their own address on the way out")

// The dns of the clients is taken in, even when it is meant for this
// machine: a client may use this machine as its resolver, and then the
// query comes to the address of this machine
check(text.contains("rdr pass on en0 proto udp from 192.168.254.0/24 to any port 53 -> 192.168.254.205 port 18081"),
      "the dns of the clients is redirected to the app")
check(text.contains("rdr pass on en0 proto tcp from 192.168.254.0/24 to any port 53 -> 192.168.254.205 port 18081"),
      "the dns of the clients is redirected to the app over tcp as well")

// the dns rule comes after the rule that keeps the traffic of this machine
// out of the redirect: the machine must not ask itself for a name
let dnsRule = text.range(of: "rdr pass on en0 proto udp from 192.168.254.0/24 to any port 53")
let ownTraffic = text.range(of: "no rdr on en0 from 192.168.254.205 to any")
check(dnsRule != nil && ownTraffic != nil, "the dns rule and the rule of this machine are there")
if let dnsRule = dnsRule, let ownTraffic = ownTraffic {
    check(ownTraffic.lowerBound < dnsRule.lowerBound,
          "the rule that keeps this machine's traffic out comes before the rule of the dns")
}

// and it comes before the rule that keeps the traffic meant for this
// machine out of the redirect: a query that is meant for this machine is
// still a query of a client
let meantForThisMachine = text.range(of: "no rdr on en0 to 192.168.254.205")
check(meantForThisMachine != nil, "the rule of the traffic meant for this machine is there")
if let dnsRule = dnsRule, let meantForThisMachine = meantForThisMachine {
    check(dnsRule.lowerBound < meantForThisMachine.lowerBound,
          "the rule of the dns comes before the rule of the traffic meant for this machine")
}

// the traffic is redirected to the address of the machine and not to the
// loopback: the answer of the filter has to come from the same place the
// traffic was sent to
check(!text.contains("-> 127.0.0.1 port"),
      "the traffic is not redirected to the loopback")

// the rule that keeps the traffic of this machine out of the redirect comes
// before the rule that redirects: the filter takes the first rule that fits
let noRdr = text.range(of: "no rdr on en0")
let rdr = text.range(of: "rdr pass on en0")
check(noRdr != nil && rdr != nil, "both rules are there")
if let noRdr = noRdr, let rdr = rdr {
    check(noRdr.lowerBound < rdr.lowerBound,
          "the rule that keeps this machine's traffic out comes first")
}

// the rules of the gateway go into the translation part of the ruleset,
// which has to come before the filtering part
let base = """
scrub-anchor "com.apple/*"
nat-anchor "com.apple/*"
rdr-anchor "com.apple/*"
dummynet-anchor "com.apple/*"
anchor "com.apple/*"
load anchor "com.apple" from "/etc/pf.anchors/com.apple"
"""
let merged = GatewayFilter.mergedRules(base: base, gateway: rules)
let lines = merged.components(separatedBy: "\n")
let indexOfRdr = lines.firstIndex { $0.hasPrefix("rdr pass on en0") }
let indexOfAnchor = lines.firstIndex { $0.hasPrefix("anchor \"com.apple") }
check(indexOfRdr != nil, "the rules of the gateway are in the merged rules")
check(indexOfAnchor != nil, "the filtering rule of the machine is in the merged rules")
if let indexOfRdr = indexOfRdr, let indexOfAnchor = indexOfAnchor {
    check(indexOfRdr < indexOfAnchor,
          "the rules of the gateway come before the first filtering rule")
}

// the options of the filter come in front of everything
//
// They belong to the first part of the ruleset, and the filter refuses a
// file in which they come later: "set timeout" in the middle of the file is
// refused with "Rules must be in order: options, normalization, queueing,
// translation, filtering".
let firstLine = lines.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
check(firstLine == "set timeout udp.multiple 300",
      "the options of the filter are the first thing in the file")
let indexOfOptions = lines.firstIndex { $0.hasPrefix("set timeout") }
let indexOfScrub = lines.firstIndex { $0.hasPrefix("scrub-anchor") }
check(indexOfOptions != nil, "the options of the filter are in the merged rules")
if let indexOfOptions = indexOfOptions, let indexOfScrub = indexOfScrub {
    check(indexOfOptions < indexOfScrub,
          "the options of the filter come before the rules of the machine")
}

// the rules of the machine are all still there
for line in ["scrub-anchor \"com.apple/*\"", "nat-anchor \"com.apple/*\"",
             "rdr-anchor \"com.apple/*\"", "dummynet-anchor \"com.apple/*\"",
             "anchor \"com.apple/*\""] {
    check(merged.contains(line), "the rule '\(line)' of the machine is still there")
}

// nothing of the translation part comes after the first filtering rule.
//
// The filter keeps the part of the ruleset it is reading, and it refuses a
// rule of the translation part once it has moved on to the filtering part:
// "Rules must be in order: options, normalization, queueing, translation,
// filtering". An anchor that is declared after the filtering rules of the
// machine is refused with exactly that, and the gateway mode never came up.
let firstFiltering = lines.firstIndex { line in
    let t = line.trimmingCharacters(in: .whitespaces)
    return t.hasPrefix("anchor ") || t.hasPrefix("pass ")
        || t.hasPrefix("block ") || t.hasPrefix("match ")
}
check(firstFiltering != nil, "the rules of the machine have a filtering rule")
if let firstFiltering = firstFiltering {
    let after = lines[firstFiltering...]
    let translationAfter = after.filter { line in
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("rdr ") || t.hasPrefix("nat ") || t.hasPrefix("no rdr ")
            || t.hasPrefix("no nat ") || t.hasPrefix("rdr-anchor ") || t.hasPrefix("nat-anchor ")
    }
    check(translationAfter.isEmpty,
          "no rule of the translation part comes after the filtering rules")
    check(!merged.contains("rdr-anchor \"com.sdpong.proxiroute"),
          "the gateway does not declare an anchor after the filtering rules")
    check(!merged.contains("load anchor \"com.sdpong.proxiroute"),
          "the gateway does not load an anchor that is not declared")
}

// the rules of the machine are the last thing in the file
let lastBaseLine = base.components(separatedBy: "\n").last { line in
    let t = line.trimmingCharacters(in: .whitespaces)
    return !t.isEmpty && !t.hasPrefix("#")
}
check(merged.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(lastBaseLine ?? ""),
      "the rules of the machine are the last thing in the file")

// a machine whose rules have no filtering rule at all still gets them
let bare = """
scrub-anchor "com.apple/*"
nat-anchor "com.apple/*"
"""
let bareMerged = GatewayFilter.mergedRules(base: bare, gateway: rules)
check(bareMerged.contains("rdr pass on en0"), "the rules of the gateway go in even without a filtering rule")

// the filter of the machine goes off again when the gateway mode is the one
// that turned it on
//
// The filter of the machine is a switch of its own: a machine that had it on
// before the gateway mode came up keeps it on. The gateway mode turns it off
// only when it was the one that turned it on, so that the machine is the way
// it was.
//
// The option that turns the filter off is "-d". There is no "-X": the tool
// says "option requires an argument" and the filter stays on.
let helperSource = (try? String(contentsOfFile: ProcessInfo.processInfo.environment["PROXIRoute_HELPER"] ?? "", encoding: .utf8)) ?? ""
check(!helperSource.isEmpty, "the source of the helper is there")
check(helperSource.contains("filterEnabledByTheGateway"),
      "the helper remembers that it turned the filter on")
check(helperSource.contains("[\"-d\"]"),
      "the filter of the machine is turned off with -d")
check(!helperSource.contains("[\"-X\"]"),
      "the filter of the machine is not turned off with -X")

// ---------------------------------------------------------------- the network

print("gateway network tests:")

// the network of an address and a mask
check(GatewayNetwork.subnet(address: "192.168.254.205", mask: "255.255.255.0") == "192.168.254.0/24",
      "the network of 192.168.254.205 with a 24 bit mask is 192.168.254.0/24")
check(GatewayNetwork.subnet(address: "10.1.2.3", mask: "255.255.0.0") == "10.1.0.0/16",
      "the network of 10.1.2.3 with a 16 bit mask is 10.1.0.0/16")
check(GatewayNetwork.subnet(address: "192.168.1.130", mask: "255.255.255.128") == "192.168.1.128/25",
      "the network of 192.168.1.130 with a 25 bit mask is 192.168.1.128/25")
check(GatewayNetwork.subnet(address: "not an address", mask: "255.255.255.0") == nil,
      "something that is not an address is not a network")

// the text of an address
check(GatewayNetwork.text(GatewayNetwork.number("192.168.254.140") ?? 0) == "192.168.254.140",
      "the text of an address is the address")

print("gateway tests: ALL PASS")
