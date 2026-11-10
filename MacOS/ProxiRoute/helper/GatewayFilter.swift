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
        let address: String
        let subnet: String
        let redirectPort: Int

        // The rules themselves.
        //
        // The order matters: the rule that keeps the traffic of this machine
        // out of the redirect comes first, because the rule that redirects
        // would otherwise catch it too.
        var text: String {
            return """
            # The traffic of this machine is not redirected, or the machine
            # would take its own traffic in and send it out again.
            no rdr on \(interface) from \(address) to any
            no nat on \(interface) from \(address) to any
            # The traffic that comes in from the network is redirected to the
            # app, which takes it in and sends it on by the rules.
            rdr pass on \(interface) proto tcp from \(subnet) to any -> 127.0.0.1 port \(redirectPort)
            # The clients keep their own address on the way out, so that the
            # way back comes through this machine.
            nat on \(interface) from \(subnet) to any -> (\(interface))
            """
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
    static func mergedRules(base: String, gateway: Rules) -> String {
        let ours = gateway.text
        var out: [String] = []
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
        guard let result = run("/sbin/pfctl", ["-s", "info"]) else { return false }
        return result.output.contains("Status: Enabled")
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
        guard let result = run("/usr/sbin/sysctl", ["-n", "net.inet.ip.forwarding"]) else { return false }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
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
        let check = run("/sbin/pfctl", ["-n", "-f", gatewayRulesPath])
        if let check, check.wasRefused {
            return .failure(Failure("The filter would not take these rules: \(check.output)"))
        }

        // the rules go in
        let load = run("/sbin/pfctl", ["-f", gatewayRulesPath])
        if let load, load.wasRefused {
            return .failure(Failure("The filter refused these rules: \(load.output)"))
        }

        // the filter has to be on for the rules to do anything
        if !filterEnabled() {
            let enableFilter = run("/sbin/pfctl", ["-E"])
            if let enableFilter, enableFilter.wasRefused {
                // the filter could not be turned on: the rules are in place
                // but nothing is going through them
                return .failure(Failure("The filter could not be turned on: \(enableFilter.output)"))
            }
            // the gateway mode turned the filter on, so it is the one that has
            // to turn it off again
            filterEnabledByTheGateway = true
        }

        // and the machine has to forward
        let forward = run("/usr/sbin/sysctl", ["-w", "net.inet.ip.forwarding=1"])
        if let forward, forward.wasRefused {
            // the rules are in place and the traffic of the network is
            // taken in, but it is not forwarded anywhere: the machine is
            // not a router, so the traffic goes nowhere
            return .failure(Failure("The forwarding of the machine could not be turned on: \(forward.output)"))
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
        _ = run("/sbin/pfctl", ["-f", baseRulesPath])

        // the forwarding goes off, unless something else turned it on
        // in the meantime
        if forwardingEnabled() {
            _ = run("/usr/sbin/sysctl", ["-w", "net.inet.ip.forwarding=0"])
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
                _ = run("/sbin/pfctl", ["-d"])
            }
        }

        return .success("The gateway is off.")
    }

    // MARK: - running things

    // What a tool said, and whether it worked.
    //
    // The exit code of pfctl is 0 even when the filter refused what it was
    // given: it says the reason on the error output and returns 0 all the
    // same. So both are looked at, and the reason is kept.
    struct ToolResult {
        let output: String
        let succeeded: Bool

        // whether the output says that the filter refused something
        var wasRefused: Bool {
            return output.contains("pf rules not loaded")
                || output.contains("Syntax error")
                || output.contains("Permission denied")
                || output.contains("Operation not permitted")
        }
    }

    // Runs a tool and gives back what it said.
    //
    // The tool is run with its full path, because the helper runs with a
    // small PATH and the paths of the tools are known.
    static func run(_ path: String, _ arguments: [String]) -> ToolResult? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        return ToolResult(output: output, succeeded: process.terminationStatus == 0)
    }
}
