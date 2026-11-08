import Foundation

// The DNS policy as the user configures it.
//
// The extension has the same model (extension/DNSPolicy.swift). This is the
// app's copy: it turns into the dictionary that goes over the wire, and the
// extension turns it back into its own model. The wire form is deliberately
// plain so an older extension can still read a newer app's policy.
struct DNSPolicySettings: Equatable {
    enum Mode: String, CaseIterable, Identifiable {
        // the system's resolver answers
        case system
        // a resolver on this machine answers, the proxy server gets the address
        case local
        // the proxy server resolves the name itself
        case remote

        var id: String { rawValue }

        var title: String {
            switch self {
            case .system: return L10n.t("System")
            case .local: return L10n.t("Local")
            case .remote: return L10n.t("Remote")
            }
        }

        var detail: String {
            switch self {
            case .system:
                return L10n.t("macOS answers the name with the resolver it was given. The proxy server is given the name only when the proxy's own setting says so, otherwise it gets the address.")
            case .local:
                return L10n.t("A resolver on this Mac answers, and the proxy server is always given the address. The proxy server never resolves a name.")
            case .remote:
                return L10n.t("The proxy server resolves the name itself. The answer from this Mac is only used to start the connection, so the site is reached even when the local answer is wrong or is an address that only means something here.")
            }
        }

        // what the proxy server is given for a name in this mode
        var serverGets: String {
            switch self {
            case .system: return L10n.t("the address, unless the proxy's own setting asks for the name")
            case .local: return L10n.t("the address")
            case .remote: return L10n.t("the name")
            }
        }
    }

    var mode: Mode = .system
    // names that must never become a proxy destination
    var excludedDomains: [String] = []
    // resolvers to ask, in order
    var upstreamResolvers: [String] = []
    // when there is no configured resolver, use the one the system hands out
    var autoDetectUpstream: Bool = true
    // the proxy server always gets the name, whatever its own setting says
    var leakProtection: Bool = false

    func toDictionary() -> [String: Any] {
        return [
            "mode": mode.rawValue,
            "excludedDomains": excludedDomains,
            "upstreamResolvers": upstreamResolvers,
            "autoDetectUpstream": autoDetectUpstream,
            "leakProtection": leakProtection
        ]
    }

    static func fromDictionary(_ dict: [String: Any]) -> DNSPolicySettings {
        var settings = DNSPolicySettings()
        if let raw = dict["mode"] as? String, let parsed = Mode(rawValue: raw) {
            settings.mode = parsed
        }
        if let list = dict["excludedDomains"] as? [String] {
            settings.excludedDomains = list
        }
        if let list = dict["upstreamResolvers"] as? [String] {
            settings.upstreamResolvers = list
        }
        if let flag = dict["autoDetectUpstream"] as? Bool {
            settings.autoDetectUpstream = flag
        }
        if let flag = dict["leakProtection"] as? Bool {
            settings.leakProtection = flag
        }
        return settings
    }

    // the lines the user typed, one per line, cleaned up
    static func parseList(_ text: String) -> [String] {
        return text
            .split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func formatList(_ list: [String]) -> String {
        return list.joined(separator: "\n")
    }

    // one line that says what the policy is, for the log and for the window
    var summary: String {
        var parts = [L10n.f("resolution %@", mode.title)]
        if leakProtection { parts.append(L10n.t("leak protection on")) }
        if !upstreamResolvers.isEmpty {
            parts.append(L10n.f("resolvers %@", upstreamResolvers.joined(separator: ", ")))
        } else {
            parts.append(L10n.t("the resolver of the system"))
        }
        if !excludedDomains.isEmpty {
            parts.append(L10n.f("%@ excluded name(s)", "\(excludedDomains.count)"))
        }
        return parts.joined(separator: ", ")
    }
}
