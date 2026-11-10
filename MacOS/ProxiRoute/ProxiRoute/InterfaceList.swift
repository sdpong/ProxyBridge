import Foundation
import Network
import Combine

// The interfaces of this machine.
//
// The user wants to say "the traffic goes out through the wired connection"
// and not "through en3", because the number of an interface changes when a
// cable is pulled and a thunderbolt bridge takes its place. The kind is the
// stable thing, so it is what is stored, and the name is only used to show
// which one it is right now.
@MainActor
final class InterfaceList: ObservableObject {

    // one for the whole app: the routing window and the proxy server both
    // need to know which interfaces are there
    static let shared = InterfaceList()

    // the interfaces of the machine, with the kind that stays the same when
    // the number of an interface changes
    struct Entry: Identifiable {
        let name: String
        let kind: String
        var id: String { name }
    }

    @Published private(set) var entries: [Entry] = []

    // who wants to know when the interfaces change. the proxy server binds
    // its listener to one of them.
    var onChange: (([(kind: String, name: String)]) -> Void)?

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.sdpong.proxiroute.app.interfaces")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let list = InterfaceList.entries(from: path.availableInterfaces)
            DispatchQueue.main.async {
                self?.entries = list
                // the proxy server binds its listener to one of them
                self?.onChange?(list.map { (kind: $0.kind, name: $0.name) })
            }
        }
        monitor.start(queue: queue)
    }

    // The interfaces of the machine, in the shape the monitor gives them.
    nonisolated static func entries(from interfaces: [NWInterface]) -> [Entry] {
        return entries(from: interfaces.map { (name: $0.name, kind: kind(of: $0)) })
    }

    // The interfaces of the machine, without the ones that are said twice.
    //
    // The system does say the same interface more than once: on a Mac with a
    // wireless network the monitor of the paths names en0 twice, once for the
    // network and once for the radio behind it. Two entries with the same name
    // are one interface as far as the app is concerned, and a list that says
    // the same name twice is a picker with the same choice in it twice - and
    // SwiftUI does not say which of the two is meant.
    nonisolated static func entries(from interfaces: [(name: String, kind: String)]) -> [Entry] {
        var seen = Set<String>()
        var list: [Entry] = []
        for interface in interfaces where interface.kind != "loopback" {
            guard seen.insert(interface.name).inserted else { continue }
            list.append(Entry(name: interface.name, kind: interface.kind))
        }
        return list
    }

    // the entries in the shape the old code used
    var interfaces: [(name: String, kind: String)] {
        entries.map { (name: $0.name, kind: $0.kind) }
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
