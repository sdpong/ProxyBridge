import Foundation

// A proxy chain: the proxies a connection walks through, in order.
//
// A rule's action names a chain with a "chain:" prefix, so a chain and a
// proxy can never be mistaken for one another, no matter what a proxy or a
// chain is called.
enum ChainAction {
    static let prefix = "chain:"

    static func isChain(_ action: String) -> Bool {
        return action.hasPrefix(prefix)
    }

    static func chainId(from action: String) -> String? {
        guard isChain(action) else { return nil }
        let id = String(action.dropFirst(prefix.count))
        return id.isEmpty ? nil : id
    }

    static func action(forChainId id: String) -> String {
        return prefix + id
    }
}

enum ChainPlan {
    // the proxy ids a chain walks through, in order. an unknown chain has no
    // hops, so the caller can say the chain is broken instead of quietly
    // sending the traffic somewhere else.
    static func proxyIds(forAction action: String, chains: [String: [String]]) -> [String] {
        guard let id = ChainAction.chainId(from: action) else { return [] }
        return chains[id] ?? []
    }

    // what is wrong with a chain of these proxies. the types are checked
    // because an http proxy cannot be a hop in the middle: it opens a tunnel
    // with a CONNECT, and the reply can leave bytes behind that the next
    // handshake would read as its own answer.
    static func problems(withProxyIds ids: [String], proxyTypes: [String: String]) -> [String] {
        var out: [String] = []
        if ids.isEmpty {
            out.append("the chain has no proxy in it")
            return out
        }
        for i in 0..<ids.count {
            let type = (proxyTypes[ids[i]] ?? "").lowercased()
            if type.isEmpty {
                out.append("proxy \(i + 1) of the chain does not exist")
                continue
            }
            if type != "socks5" && type != "http" {
                out.append("proxy \(i + 1) of the chain has the type '\(type)', it must be socks5 or http")
                continue
            }
            // only the last hop may be an http proxy
            if type == "http" && i != ids.count - 1 {
                out.append("proxy \(i + 1) of the chain is an http proxy, only the last proxy of a chain may be one")
            }
        }
        for i in 1..<ids.count where ids[i] == ids[i - 1] {
            out.append("the same proxy is used twice in a row")
            break
        }
        return out
    }
}
