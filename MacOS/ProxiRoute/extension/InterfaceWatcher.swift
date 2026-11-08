import Foundation
import Network

// The interfaces of this machine, and the one the traffic has to leave through.
//
// "Bind to Wi-Fi" or "bind to the wired connection" is a real question when
// a Mac is plugged in and connected to a wireless network at the same time:
// the system picks the route, and the user may want the other one.
//
// The interface a connection is bound to is an NWInterface, and the only way
// to get one is to ask the path monitor what it sees. So the extension runs
// its own monitor and remembers the list.
final class InterfaceWatcher {

    static let shared = InterfaceWatcher()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.sdpong.proxiroute.interfaces")
    private let lock = NSLock()
    private var interfaces: [NWInterface] = []
    private var started = false

    private init() {}

    // Starts watching. The first answer takes a moment to arrive, so the
    // caller has to live with an empty list for a short while.
    func start() {
        lock.lock()
        if started {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()

        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            self.lock.lock()
            self.interfaces = path.availableInterfaces
            self.lock.unlock()
        }
        monitor.start(queue: queue)
    }

    // The interface with this name, if the machine still has it.
    func interface(named name: String) -> NWInterface? {
        guard !name.isEmpty else { return nil }
        lock.lock()
        let found = interfaces.first { $0.name == name }
        lock.unlock()
        return found
    }

    // The interface of this kind, when the name is gone. A Mac that was
    // plugged in yesterday had en1, and today en1 is a Thunderbolt bridge
    // and the wired connection is en5. The kind still says what it is.
    func interface(ofKind kind: String) -> NWInterface? {
        guard !kind.isEmpty else { return nil }
        lock.lock()
        let list = interfaces
        lock.unlock()
        return list.first { InterfaceWatcher.kind(of: $0) == kind }
    }

    // The kinds of the interfaces that are of use right now, for the app to
    // show. The loopback is left out: binding the traffic to it means that
    // the traffic goes nowhere.
    static func kinds() -> [String: String] {
        var out: [String: String] = [:]
        for interface in shared.currentInterfaces {
            let kind = kind(of: interface)
            guard kind != "loopback" else { continue }
            if out[kind] == nil { out[kind] = interface.name }
        }
        return out
    }

    var currentInterfaces: [NWInterface] {
        lock.lock()
        defer { lock.unlock() }
        return interfaces
    }

    // "wifi", "ethernet", "loopback" or "other". The names are the ones the
    // app shows and the ones it stores, so that they stay the same on every
    // machine.
    static func kind(of interface: NWInterface) -> String {
        switch interface.type {
        case .wifi: return "wifi"
        case .wiredEthernet: return "ethernet"
        case .loopback: return "loopback"
        default: return "other"
        }
    }
}
