import Foundation

// The rules of the packet filter, and the forwarding of the machine.
//
// This is the part of the helper that needs root, and the part that changes
// the machine. Everything here is written so that the machine can be put back
// the way it was: the rules of the machine are read from the file the system
// itself reads, and that file is what goes back when the gateway is turned
// off.
//
// What the rules do, and why each of them is there:
//
//   - the traffic that comes in from the network is redirected to a port of
//     this machine, where the app is listening. That is the whole point of
//     the gateway mode.
//   - the traffic of this machine itself is not redirected, or the machine
//     would take its own traffic in and send it out again, for ever.
//   - the machine is turned into a router for the traffic that is not
//     redirected, and the address of the clients is kept, so that the way
//     back comes through this machine.
//
// The rules go into the translation part of the ruleset, which has to come
// before the filtering part: the filter refuses a file where a rule of the
// filtering part comes before a rule of the translation part. That is why
// they are put in front of the first filtering rule and not at the end of
// the file.
//
// Nothing else may come after the first filtering rule either. The filter
// keeps the part of the ruleset it is reading, and it refuses a rule that
// belongs to an earlier part once it has moved on: an "rdr-anchor" or a
// "nat-anchor" that is written after the filtering rules is refused with
// "Rules must be in order: options, normalization, queueing, translation,
// filtering". That is what the anchor of the gateway used to do, and it
// stopped the gateway mode from ever coming up on a Mac whose own rules
// have a filtering rule in them - which is every Mac.
//
// The anchor of the gateway is therefore gone. It was written a second time
// into an anchor of its own because it was not written down anywhere which
// of the two ways macOS takes the rules of the translation part. macOS
// takes them where they are written, and the anchor protected nothing: it
// was declared in the same file as the rules next to it, so it lived exactly
// as long as they did.

enum GatewayFilter {

    // Why something did not work.
    //
    // The reason is a word that can be shown to the person in front of the
    // window, so it is kept as a value and not as a number.
    struct Failure: Error {
        let reason: String
        init(_ reason: String) { self.reason = reason }
    }

    // MARK: - the rules

    // The rules of the gateway, for one interface.
    //
    // The interface is the one the traffic of the network comes in through,
    // the address is the address of this machine on it, and the subnet is the
    // network the clients are on.
    struct Rules: Equatable {
        let interface: String
        // the address of this machine on that interface. The traffic of the
        // network is redirected to it, and not to the loopback: the answer
        // of the filter has to come from the same place the traffic was sent
        // to, or the kernel does not recognise it as the answer of the
        // traffic it redirected.
        let address: String
        let subnet: String
        let redirectPort: Int
        // every address of this machine. The traffic of this machine is not
        // redirected, whichever address it goes out with, and a machine may
        // have more than one address on the network of the clients.
        let ownAddresses: [String]
        // the addresses of the proxies of the app. The traffic to a proxy
        // does not go through a proxy, or the proxy would be talking to
        // itself.
        let proxyAddresses: [String]

        init(interface: String,
             address: String,
             subnet: String,
             redirectPort: Int,
             ownAddresses: [String] = [],
             proxyAddresses: [String] = []) {
            self.interface = interface
            self.address = address
            self.subnet = subnet
            self.redirectPort = redirectPort
            self.ownAddresses = ownAddresses
            self.proxyAddresses = proxyAddresses
        }

        // The addresses of this machine that the rules name.
        //
        // The address of the interface is the first one, and it is always
        // there even when the list of the other addresses is empty.
        private var guardedAddresses: [String] {
            var seen = Set<String>()
            var out: [String] = []
            for candidate in [address] + ownAddresses where !candidate.isEmpty {
                if seen.insert(candidate).inserted { out.append(candidate) }
            }
            return out
        }

        // The rules themselves.
        //
        // The order matters: the rule that keeps the traffic of this machine
        // out of the redirect comes first, because the rule that redirects
        // would otherwise catch it too.
        var text: String {
            var out = ""

            // The traffic of this machine is not redirected, or the machine
            // would take its own traffic in and send it out again.
            //
            // Every address of this machine gets a rule of its own: the
            // machine may have more than one address on this network - a
            // second card, or an address that was added by hand - and a rule
            // that names one of them leaves the others open.
            for own in guardedAddresses {
                out += "no rdr on \(interface) from \(own) to any\n"
                out += "no nat on \(interface) from \(own) to any\n"
            }

            // The dns of the clients is taken in as well, even when it is
            // meant for this machine.
            //
            // A client of the network may use this machine as its resolver,
            // and then the query comes to the address of this machine. The
            // rule that keeps the traffic meant for this machine out of the
            // redirect comes after this one, so that the query is taken in
            // and answered by the app: the name of a place is the only thing
            // that says which place it is, and without it the rules that
            // name a host cannot match the traffic of the clients.
            //
            // The traffic of this machine itself is not in this rule: it was
            // let go of above, or the machine would ask itself for a name
            // and wait for the answer for ever.
            out += "rdr pass on \(interface) proto udp from \(subnet) to any port 53 -> \(address) port \(redirectPort)\n"
            out += "rdr pass on \(interface) proto tcp from \(subnet) to any port 53 -> \(address) port \(redirectPort)\n"

            // The traffic that is meant for this machine is not redirected
            // either: a client that wants to reach a server that runs on this
            // machine has to be able to reach it.
            for own in guardedAddresses {
                out += "no rdr on \(interface) to \(own)\n"
            }

            // The traffic to a proxy does not go through a proxy, or the
            // proxy would be talking to itself.
            for proxy in proxyAddresses {
                out += "no rdr on \(interface) from \(subnet) to \(proxy)\n"
            }

            // The traffic that comes in from the network is redirected to the
            // app, which takes it in and sends it on by the rules.
            //
            // The two protocols are two rules and not one rule that names
            // both of them: the filter of macOS reads one protocol in a
            // rule, and a rule that says "proto { tcp, udp }" is not a rule
            // it reads.
            out += "rdr pass on \(interface) proto tcp from \(subnet) to any -> \(address) port \(redirectPort)\n"
            out += "rdr pass on \(interface) proto udp from \(subnet) to any -> \(address) port \(redirectPort)\n"

            // The clients keep their own address on the way out, so that the
            // way back comes through this machine.
            out += "nat on \(interface) from \(subnet) to any -> (\(interface))\n"
            return out
        }
    }

    // The file the rules of the machine are in.
    //
    // The system reads this file when it starts, and it is the file that
    // puts the machine back the way it was. It is not "pfctl -sr": that one
    // prints the filtering rules only, so the anchors of the translation
    // would be lost on the way.
    static let baseRulesPath = "/etc/pf.conf"

    // Where the rules of the gateway are written while they are in place.
    //
    // They have to be in a file, because the filter reads a file and not a
    // list of rules.
    static let gatewayRulesPath = "/var/run/com.sdpong.proxiroute.pf.rules"

    // The options of the filter.
    //
    // They belong to the first part of the ruleset, and the filter refuses a
    // file in which they come later: "set timeout" in the middle of the file
    // is refused with "Rules must be in order: options, normalization,
    // queueing, translation, filtering". So they go in front of everything,
    // and not next to the rules of the gateway.
    //
    // The times of udp in the filter are short: a state of udp that has had
    // one packet dies after thirty seconds, and a state that has had more
    // dies after a minute. A phone that talks over udp says something every
    // few seconds and is quiet in between, and a filter that forgets the
    // state of the udp in between cuts the talk in pieces.
    static let options = """
    set timeout udp.multiple 300
    set timeout udp.single 120
    """

    // The rules of the machine with the rules of the gateway put in.
    //
    // The rules of the gateway go in front of the first filtering rule of
    // the machine. If there is no filtering rule, they go at the end: the
    // filter will still take them, and the machine has no rule of its own
    // that they could be in the wrong order with.
    //
    // Nothing is added after the rules of the machine. The filter keeps the
    // part of the ruleset it is reading, and a rule of the translation part
    // that comes after a rule of the filtering part is refused.
    //
    // The options go in front of the rules of the machine as well, for the
    // reason that is written down with them.
    static func mergedRules(base: String, gateway: Rules) -> String {
        let ours = gateway.text
        var out: [String] = [options]
        var placed = false

        for line in base.components(separatedBy: .newlines) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if !placed && !text.isEmpty && !text.hasPrefix("#") {
                // the first rule of the filtering part: the rules of the
                // translation part have to come before it
                if text.hasPrefix("anchor ") || text.hasPrefix("pass ")
                    || text.hasPrefix("block ") || text.hasPrefix("match ") {
                    out.append(ours)
                    placed = true
                }
            }
            out.append(line)
        }
        if !placed {
            out.append(ours)
        }

        return out.joined(separator: "\n") + "\n"
    }

    // MARK: - the filter

    // Is the filter on right now?
    static func filterEnabled() -> Bool {
        // pfctl says it in the first line: "Status: Enabled for 0 days ..."
        guard let result = ToolRunner.run("/sbin/pfctl", ["-s", "info"]) else { return false }
        return result.text.contains("Status: Enabled")
    }

    // Whether the filter was turned on by the gateway mode.
    //
    // The filter of the machine is a switch of its own: the machine may have
    // it on before the gateway mode comes up, and then it is not the gateway
    // mode that may turn it off again. The gateway mode turns it on only
    // when it was off, and it turns it off only when it was the one that
    // turned it on - so that the machine is the way it was.
    static var filterEnabledByTheGateway = false

    // Is the forwarding of the machine on right now?
    //
    // The filter does not forward packets between interfaces by itself: the
    // forwarding is a separate switch of the kernel. Both are needed for the
    // traffic of the network to pass through this machine.
    static func forwardingEnabled() -> Bool {
        guard let result = ToolRunner.run("/usr/sbin/sysctl", ["-n", "net.inet.ip.forwarding"]) else { return false }
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    // Put the rules of the gateway in place and turn the forwarding on.
    //
    // The file is checked before it is loaded: pfctl reads the file without
    // touching the filter when it is given -n. A file that the filter would
    // refuse is caught here, and the machine is left alone.
    static func enable(rules: Rules) -> Result<String, Failure> {
        guard let base = try? String(contentsOfFile: baseRulesPath, encoding: .utf8) else {
            return .failure(Failure("The rules of the machine are not at \(baseRulesPath)."))
        }

        let merged = mergedRules(base: base, gateway: rules)

        // the file is written to a temporary place first, and moved into place
        // in one step, so a rule set that is half written is never loaded
        let temporary = gatewayRulesPath + ".new"
        do {
            try merged.write(toFile: temporary, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(atPath: gatewayRulesPath)
            try FileManager.default.moveItem(atPath: temporary, toPath: gatewayRulesPath)
        } catch {
            return .failure(Failure("The rules of the gateway could not be written: \(error.localizedDescription)"))
        }

        // the file is checked before it is loaded
        let check = ToolRunner.run("/sbin/pfctl", ["-n", "-f", gatewayRulesPath])
        if let check, check.wasRefused {
            return .failure(Failure("The filter would not take these rules: \(check.text)"))
        }

        // the rules go in
        let load = ToolRunner.run("/sbin/pfctl", ["-f", gatewayRulesPath])
        if let load, load.wasRefused {
            return .failure(Failure("The filter refused these rules: \(load.text)"))
        }

        // the filter has to be on for the rules to do anything
        if !filterEnabled() {
            let enableFilter = ToolRunner.run("/sbin/pfctl", ["-E"])
            if let enableFilter, enableFilter.wasRefused {
                // the filter could not be turned on: the rules are in place
                // but nothing is going through them
                return .failure(Failure("The filter could not be turned on: \(enableFilter.text)"))
            }
            // the gateway mode turned the filter on, so it is the one that has
            // to turn it off again
            filterEnabledByTheGateway = true
        }

        // and the machine has to forward
        let forward = ToolRunner.run("/usr/sbin/sysctl", ["-w", "net.inet.ip.forwarding=1"])
        if let forward, forward.wasRefused {
            // the rules are in place and the traffic of the network is
            // taken in, but it is not forwarded anywhere: the machine is
            // not a router, so the traffic goes nowhere
            return .failure(Failure("The forwarding of the machine could not be turned on: \(forward.text)"))
        }

        return .success("The gateway is on.")
    }

    // Put the machine back the way it was.
    //
    // The rules of the machine go back first, and then the forwarding goes
    // off. The order is the other way round from turning it on: the traffic
    // of the network has to stop being taken in before the forwarding stops,
    // or there is a moment where the traffic of the network is forwarded but
    // not taken in, and it goes nowhere.
    static func disable() -> Result<String, Failure> {
        // the rules of the machine go back: that file is what the system
        // itself reads, so the machine is the way it was
        _ = ToolRunner.run("/sbin/pfctl", ["-f", baseRulesPath])

        // the forwarding goes off, unless something else turned it on
        // in the meantime
        if forwardingEnabled() {
            _ = ToolRunner.run("/usr/sbin/sysctl", ["-w", "net.inet.ip.forwarding=0"])
        }

        // the rules of the gateway are not needed any more
        try? FileManager.default.removeItem(atPath: gatewayRulesPath)

        // the filter goes off as well, if it is the gateway mode that turned
        // it on: a machine whose filter was off before the gateway mode came
        // up is a machine whose filter has to be off again when it goes.
        // The rules of the machine are back by now, so the filter has nothing
        // of ours left to do.
        if filterEnabledByTheGateway {
            filterEnabledByTheGateway = false
            if filterEnabled() {
                // "-d" is what turns the filter off. There is no "-X": the
                // tool says "option requires an argument" and the filter
                // stays on.
                _ = ToolRunner.run("/sbin/pfctl", ["-d"])
            }
        }

        return .success("The gateway is off.")
    }

    // MARK: - running things
}

// Whether the tool said that the filter refused something.
//
// The exit code of pfctl is 0 even when the filter refused what it was
// given: it says the reason on the error output and returns 0 all the
// same. So the text is looked at, and the reason is kept.
//
// The tool is run by the runner that the app uses as well, and that runner
// closes the pipes of the tool. The helper runs for days and it runs tools
// every few seconds, so a helper that keeps its pipes would run out of
// descriptors within the hour - and a helper that cannot open a file cannot
// write the rules of the gateway.
extension ToolRunner.Answer {
    var wasRefused: Bool {
        return text.contains("pf rules not loaded")
            || text.contains("Syntax error")
            || text.contains("Permission denied")
            || text.contains("Operation not permitted")
    }
}
