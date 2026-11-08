import Foundation
import Network
import Combine

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

// The interfaces of this machine.
//
// The user wants to say "the traffic goes out through the wired connection"
// and not "through en3", because the number of an interface changes when a
// cable is pulled and a thunderbolt bridge takes its place. The kind is the
// stable thing, so it is what is stored, and the name is only used to show
// which one it is right now.
@MainActor
final class InterfaceList: ObservableObject {

    @Published private(set) var interfaces: [(name: String, kind: String)] = []

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.sdpong.proxiroute.app.interfaces")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let list = path.availableInterfaces.compactMap { interface -> (String, String)? in
                let kind = InterfaceList.kind(of: interface)
                guard kind != "loopback" else { return nil }
                return (interface.name, kind)
            }
            DispatchQueue.main.async {
                self?.interfaces = list
            }
        }
        monitor.start(queue: queue)
    }

    nonisolated static func kind(of interface: NWInterface) -> String {
        switch interface.type {
        case .wifi: return "wifi"
        case .wiredEthernet: return "ethernet"
        case .loopback: return "loopback"
        default: return "other"
        }
    }

    // The name of the first interface of this kind, for the text that says
    // what the choice is.
    func name(ofKind kind: String) -> String? {
        interfaces.first { $0.kind == kind }?.name
    }

    // The kinds that are there, without the loopback and without the ones
    // that are of no use (a bridge, a virtual interface).
    var kinds: [String] {
        var seen: [String] = []
        for entry in interfaces where !seen.contains(entry.kind) {
            seen.append(entry.kind)
        }
        return seen
    }
}
