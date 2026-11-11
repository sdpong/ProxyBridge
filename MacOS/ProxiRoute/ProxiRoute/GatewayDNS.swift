import Foundation

// The dns of the clients of the gateway.
//
// A client of the network asks a resolver for a name and gets an address
// back. Its traffic comes into the gateway as that address and nothing else:
// the client says nothing about the name it wanted, and the filter does not
// know it either. A rule that names a host has therefore nothing to match
// against, and the gateway mode would answer every flow of the network the
// same way.
//
// The answer of the resolver is the one place where the name and the address
// are said together. The gateway mode reads that answer as it goes by, and
// remembers which address belonged to which name. The traffic that comes
// later is then matched against the name as well as against the address, and
// the proxy server is asked for the name - so that the proxy server on the
// other side of the world is the one that resolves it, and the traffic of
// the client looks like it comes from there.
//
// The map is the one the dns proxy of the extension fills. The two live in
// two processes, and each one has a map of its own.
enum GatewayDNS {

    // The port a query for a name goes to.
    static let port = 53

    // How long the name of an address is worth.
    //
    // The name of an address is the name of that address for as long as the
    // answer that said it is fresh. Five minutes, the same age the windows
    // app gives a name.
    static let nameMaxAge: TimeInterval = 300

    // Whether a flow is a flow of dns.
    static func isDNS(port: Int) -> Bool {
        return port == GatewayDNS.port
    }

    // The names an address is known by, the freshest first.
    //
    // The freshest name says how fresh the rest are: they were said by
    // answers that came in around the same time. A name that is not fresh
    // any more is of no use, and it is worse than no name at all - a proxy
    // server asked for a name that means something else by now would take
    // the traffic to the wrong place.
    static func names(for address: String) -> [String] {
        guard !address.isEmpty else { return [] }
        let known = DNSMapStore.shared.domains(forIP: address)
        guard !known.isEmpty else { return [] }
        guard DNSMapStore.shared.latestDomain(forIP: address, maxAge: GatewayDNS.nameMaxAge) != nil else {
            return []
        }
        return known.filter { DNSMapStore.isSafeHostname($0) }
    }

    // The name the proxy server is asked for.
    //
    // It is the freshest name of the address, and it is the only one: the
    // others are there for the rules to match against, and a proxy server
    // asked for one of them might well answer with a different place.
    static func proxyName(for address: String) -> String? {
        guard !address.isEmpty else { return nil }
        return DNSMapStore.shared.latestDomain(forIP: address, maxAge: GatewayDNS.nameMaxAge)
    }

    // A dns answer comes back: the name and the addresses it stands for.
    //
    // The answer is remembered, because it is the only place the name is
    // said. A resolver that says nothing useful - an answer with no
    // address in it - is not remembered.
    @discardableResult
    static func record(answer: Data) -> (domain: String, ips: [String])? {
        guard let parsed = DNSParser.parse(answer) else { return nil }
        DNSMapStore.shared.record(domain: parsed.domain, ips: parsed.ips)
        GatewayDNS.say("\(parsed.domain) is \(parsed.ips.joined(separator: ", "))")
        return parsed
    }

    // What the log says about the names that were learned.
    //
    // A person who watches a phone and wonders why a rule did not match it
    // has to see whether the name of the place was ever learned at all.
    static var logHandler: ((String, String) -> Void)?

    // How many names are said out loud.
    //
    // The names come and go with every answer, and the log of the app is
    // not a place for all of them.
    private static let sayLimit = 50
    private static var said = 0
    private static let sayLock = NSLock()

    private static func say(_ message: String) {
        sayLock.lock()
        let count = said
        said += 1
        sayLock.unlock()
        guard count < GatewayDNS.sayLimit else { return }
        logHandler?("The name of a place of the network was learned: \(message)", "INFO")
    }

    // The resolver of this machine.
    //
    // A client that asks this machine for a name cannot be answered by this
    // machine: the query would come back to where it started, for ever. The
    // resolver of the system is asked instead, and it is the one the machine
    // itself uses.
    static func systemResolver() -> String? {
        return GatewayDNS.resolvers().first
    }

    // The resolvers the system was given.
    //
    // The file of the system is the one that says it. The system does not
    // read that file for its own resolving - it asks scutil for that - but
    // the file holds the same addresses, and anybody may read it.
    static func resolvers() -> [String] {
        guard let text = try? String(contentsOfFile: GatewayDNS.resolvConfPath, encoding: .utf8) else {
            return []
        }
        return GatewayDNS.resolvers(in: text)
    }

    // The resolvers a file of the system names.
    //
    // The file says one resolver per line, and the line says the word and
    // the address. The rest of the file is about other things.
    static func resolvers(in text: String) -> [String] {
        var out: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("nameserver") else { continue }
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            let address = String(parts[1])
            guard !address.isEmpty, !out.contains(address) else { continue }
            out.append(address)
        }
        return out
    }

    // Where the system says its resolvers are.
    static let resolvConfPath = "/etc/resolv.conf"
}
