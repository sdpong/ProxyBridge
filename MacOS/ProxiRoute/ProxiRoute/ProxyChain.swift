import Foundation

// A proxy chain: the proxies a connection walks through, in order.
//
// A rule's action names a chain with a "chain:" prefix, so a chain and a
// proxy can never be mistaken for one another, no matter what a proxy or a
// chain is called. The extension has the same rule (ChainAction in
// extension/ProxyChain.swift).
struct ProxyChain: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    // the ids of the proxies, in the order they are walked through
    var proxyIds: [String]

    static let actionPrefix = "chain:"

    // the action a rule uses to point at this chain
    var action: String { ProxyChain.actionPrefix + id }

    var displayName: String {
        name.isEmpty ? L10n.t("Chain") : name
    }

    init(id: String = UUID().uuidString, name: String = "", proxyIds: [String] = []) {
        self.id = id
        self.name = name
        self.proxyIds = proxyIds
    }

    // The hops of a chain travel as json between the app, the command line and
    // the extension, and the key they travel under is "proxies": the Proxifier
    // import writes it, the command line reads it and the extension reads it.
    //
    // The app used to write "proxyIds" instead, and a profile saved that way
    // was read back with no hops at all: the chain looked empty, the extension
    // was given a chain with nothing to walk through and dropped it. Both keys
    // are read now, and "proxies" is the one that is written.
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case proxies
        case proxyIds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        if let hops = try c.decodeIfPresent([String].self, forKey: .proxies) {
            self.proxyIds = hops
        } else {
            self.proxyIds = try c.decodeIfPresent([String].self, forKey: .proxyIds) ?? []
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(proxyIds, forKey: .proxies)
    }

    // the hops of a chain that was read as a plain json object. the object can
    // come from a snapshot on disk, from an import or from the command line,
    // and each of them may spell the key its own way.
    static func hops(from object: [String: Any]) -> [String] {
        if let hops = object["proxies"] as? [String] { return hops }
        if let hops = object["proxyIds"] as? [String] { return hops }
        return []
    }

    // the chains of a snapshot, in the shape everything else reads
    static func list(from data: Data?) -> [ProxyChain] {
        guard let data, let chains = try? JSONDecoder().decode([ProxyChain].self, from: data) else { return [] }
        return chains
    }
}

extension ProxyChain {
    // what is wrong with this chain, given the types of the proxies it names.
    // the extension checks the same things (ChainPlan in extension/ProxyChain.swift),
    // so a chain that the app accepts is one the extension can run.
    func problems(proxyTypes: [String: String]) -> [String] {
        var out: [String] = []
        if proxyIds.isEmpty {
            out.append(L10n.t("The chain has no proxy in it."))
            return out
        }
        for i in proxyIds.indices {
            let type = (proxyTypes[proxyIds[i]] ?? "").lowercased()
            if type.isEmpty {
                out.append(L10n.f("Proxy %@ of the chain does not exist.", "\(i + 1)"))
                continue
            }
            if type != "socks5" && type != "socks4" && type != "http" {
                out.append(L10n.f("Proxy %@ of the chain has the type '%@', it must be socks5, socks4 or http.", "\(i + 1)", type))
                continue
            }
            // only the last hop may be an http proxy
            if type == "http" && i != proxyIds.count - 1 {
                out.append(L10n.f("Proxy %@ of the chain is an HTTP proxy. Only the last proxy of a chain may be one.", "\(i + 1)"))
            }
        }
        for i in 1..<proxyIds.count where proxyIds[i] == proxyIds[i - 1] {
            out.append(L10n.t("The same proxy is used twice in a row."))
            break
        }
        return out
    }
}
