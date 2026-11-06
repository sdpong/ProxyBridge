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
            case .system: return "System"
            case .local: return "Local"
            case .remote: return "Remote"
            }
        }

        var detail: String {
            switch self {
            case .system:
                return "The system resolver answers. The proxy server gets the host name only when its own setting says so."
            case .local:
                return "A resolver on this machine answers, and the proxy server is always given the address. It never resolves names."
            case .remote:
                return "The proxy server resolves the name, so the address it connects to does not depend on the local answer."
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
}
