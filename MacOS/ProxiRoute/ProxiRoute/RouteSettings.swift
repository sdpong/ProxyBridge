import Foundation

// The switches that sit above the rules.
//
// The rules say what a program, a host or a port does. These say what the
// whole machine does: everything goes one way (the global mode), the traffic
// leaves through this interface, and udp may or may not use a proxy.
//
// They are kept in the preferences of the app and not in the profile: they
// are a property of the machine, not of the rules.
struct RouteSettings: Equatable {

    // everything goes to this proxy, the rules are not looked at
    var globalMode = false
    // the proxy the global mode sends everything to. "DIRECT" is a proxy of
    // its own: it means everything goes out directly.
    var globalProxyId = "DIRECT"
    // the interface the traffic has to leave through: "wifi", "ethernet" or
    // the name of an interface ("en0"). empty means the system decides.
    var outboundInterface = ""
    // whether udp is allowed to go through a proxy
    var proxyUDP = true

    static let storageKey = "routeSettings"

    // The options as the extension reads them.
    func toDictionary() -> [String: Any] {
        return [
            "globalMode": globalMode,
            "globalProxyId": globalProxyId,
            "outboundInterface": outboundInterface,
            "proxyUDP": proxyUDP
        ]
    }

    // What is stored. A setting that was never written is the default: the
    // rules decide, the system picks the way out, and udp may use a proxy.
    static func load() -> RouteSettings {
        let defaults = UserDefaults.standard
        var settings = RouteSettings()
        if defaults.object(forKey: storageKey) != nil,
           let raw = defaults.dictionary(forKey: storageKey) {
            settings.globalMode = raw["globalMode"] as? Bool ?? false
            settings.globalProxyId = raw["globalProxyId"] as? String ?? "DIRECT"
            settings.outboundInterface = raw["outboundInterface"] as? String ?? ""
            settings.proxyUDP = raw["proxyUDP"] as? Bool ?? true
        }
        return settings
    }

    func save() {
        UserDefaults.standard.set(toDictionary(), forKey: RouteSettings.storageKey)
    }
}

