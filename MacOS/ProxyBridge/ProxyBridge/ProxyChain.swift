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
        name.isEmpty ? "Chain" : name
    }

    init(id: String = UUID().uuidString, name: String = "", proxyIds: [String] = []) {
        self.id = id
        self.name = name
        self.proxyIds = proxyIds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.proxyIds = try c.decodeIfPresent([String].self, forKey: .proxyIds) ?? []
    }
}

extension ProxyChain {
    // what is wrong with this chain, given the types of the proxies it names.
    // the extension checks the same things (ChainPlan in extension/ProxyChain.swift),
    // so a chain that the app accepts is one the extension can run.
    func problems(proxyTypes: [String: String]) -> [String] {
        var out: [String] = []
        if proxyIds.isEmpty {
            out.append("The chain has no proxy in it.")
            return out
        }
        for i in proxyIds.indices {
            let type = (proxyTypes[proxyIds[i]] ?? "").lowercased()
            if type.isEmpty {
                out.append("Proxy \(i + 1) of the chain does not exist.")
                continue
            }
            if type != "socks5" && type != "http" {
                out.append("Proxy \(i + 1) of the chain has the type '\(type)', it must be socks5 or http.")
                continue
            }
            // only the last hop may be an http proxy
            if type == "http" && i != proxyIds.count - 1 {
                out.append("Proxy \(i + 1) of the chain is an HTTP proxy. Only the last proxy of a chain may be one.")
            }
        }
        for i in 1..<proxyIds.count where proxyIds[i] == proxyIds[i - 1] {
            out.append("The same proxy is used twice in a row.")
            break
        }
        return out
    }
}
