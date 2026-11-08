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
            let list = path.availableInterfaces.compactMap { interface -> Entry? in
                let kind = InterfaceList.kind(of: interface)
                guard kind != "loopback" else { return nil }
                return Entry(name: interface.name, kind: kind)
            }
            DispatchQueue.main.async {
                self?.entries = list
                // the proxy server binds its listener to one of them
                self?.onChange?(list.map { (kind: $0.kind, name: $0.name) })
            }
        }
        monitor.start(queue: queue)
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
