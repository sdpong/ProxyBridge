import Foundation

// LiveFlowRegistry keeps the flows that are being proxied right now, so the app can list them
// and terminate one of them.
//
// The registry knows nothing about how a flow is torn down: the owner hands in a closure. That
// keeps this file free of NetworkExtension types (so it can be tested on its own) and keeps the
// teardown next to the relay that owns the sockets.
final class LiveFlowRegistry {

    // A snapshot of one live flow, safe to hand to another thread.
    struct Snapshot {
        let id: UInt64
        let proto: String
        let process: String
        let destination: String
        let port: UInt16
        let proxy: String
        let startedAt: Date
        let bytesUp: Int64
        let bytesDown: Int64
        let lastActivity: Date

        // how long the flow carried no traffic. a growing number is a channel that is stuck.
        func idleSeconds(now: Date = Date()) -> TimeInterval { now.timeIntervalSince(lastActivity) }
        // how long the flow has been running
        func ageSeconds(now: Date = Date()) -> TimeInterval { now.timeIntervalSince(startedAt) }
    }

    typealias Teardown = () -> Void

    private final class Entry {
        let id: UInt64
        let proto: String
        let process: String
        var destination: String
        var port: UInt16
        let proxy: String
        let startedAt: Date
        var bytesUp: Int64 = 0
        var bytesDown: Int64 = 0
        var lastActivity: Date

        init(id: UInt64, proto: String, process: String, destination: String, port: UInt16, proxy: String) {
            self.id = id
            self.proto = proto
            self.process = process
            self.destination = destination
            self.port = port
            self.proxy = proxy
            self.startedAt = Date()
            self.lastActivity = startedAt
        }
    }

    private var entries: [UInt64: Entry] = [:]
    private var teardowns: [UInt64: Teardown] = [:]
    private var nextId: UInt64 = 1
    private let lock = NSLock()

    // Registers a flow and returns the id the app addresses it with.
    @discardableResult
    func register(proto: String, process: String, destination: String, port: UInt16, proxy: String, teardown: @escaping Teardown) -> UInt64 {
        lock.lock()
        let id = nextId
        nextId += 1
        entries[id] = Entry(id: id, proto: proto, process: process, destination: destination, port: port, proxy: proxy)
        teardowns[id] = teardown
        lock.unlock()
        return id
    }

    // The live flows, newest first.
    func snapshot() -> [Snapshot] {
        lock.lock()
        defer { lock.unlock() }
        return entries.values
            .sorted { $0.startedAt > $1.startedAt }
            .map {
                Snapshot(id: $0.id, proto: $0.proto, process: $0.process, destination: $0.destination,
                         port: $0.port, proxy: $0.proxy, startedAt: $0.startedAt,
                         bytesUp: $0.bytesUp, bytesDown: $0.bytesDown, lastActivity: $0.lastActivity)
            }
    }

    // Counts the bytes a flow carried. Only real bytes count as activity, so a flow that stays
    // open but quiet still shows how long it has been idle.
    func note(id: UInt64, up: Int64 = 0, down: Int64 = 0) {
        guard up > 0 || down > 0 else { return }
        lock.lock()
        if let e = entries[id] {
            e.bytesUp += up
            e.bytesDown += down
            e.lastActivity = Date()
        }
        lock.unlock()
    }

    // The destination of a udp flow is only known once its first datagram arrives.
    func setDestination(_ destination: String, for id: UInt64) {
        lock.lock()
        entries[id]?.destination = destination
        lock.unlock()
    }

    // The destination of a udp flow and the port it goes to. Both are known
    // together, and the port is part of the row the app shows.
    func setDestination(_ destination: String, port: UInt16, for id: UInt64) {
        lock.lock()
        entries[id]?.destination = destination
        entries[id]?.port = port
        lock.unlock()
    }

    // Terminates a flow: the entry is gone and the teardown has run. False when there is no such
    // flow, so the same flow cannot be terminated twice.
    @discardableResult
    func terminate(id: UInt64) -> Bool {
        lock.lock()
        let teardown = teardowns.removeValue(forKey: id)
        entries.removeValue(forKey: id)
        lock.unlock()
        guard let teardown = teardown else { return false }
        teardown()
        return true
    }

    // Drops a flow that ended on its own. The snapshot it had is returned so the caller can
    // report how many bytes the flow carried before it went.
    @discardableResult
    func remove(id: UInt64) -> Snapshot? {
        lock.lock()
        let entry = entries.removeValue(forKey: id)
        teardowns.removeValue(forKey: id)
        lock.unlock()
        return entry.map { snapshot(of: $0) }
    }

    @discardableResult
    func removeAll() -> [Snapshot] {
        lock.lock()
        let all = entries.values.map { snapshot(of: $0) }
        entries.removeAll()
        teardowns.removeAll()
        lock.unlock()
        return all
    }

    // The flow as it is right now, with the bytes it carried so far.
    func snapshot(id: UInt64) -> Snapshot? {
        lock.lock()
        let entry = entries[id]
        lock.unlock()
        return entry.map { snapshot(of: $0) }
    }

    private func snapshot(of entry: Entry) -> Snapshot {
        Snapshot(id: entry.id, proto: entry.proto, process: entry.process, destination: entry.destination,
                 port: entry.port, proxy: entry.proxy, startedAt: entry.startedAt,
                 bytesUp: entry.bytesUp, bytesDown: entry.bytesDown, lastActivity: entry.lastActivity)
    }

    func count() -> Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }
}
