import Foundation
import Darwin

// The part of the gateway mode that runs in the app.
//
// The helper of root does the three things that need root. This is the other
// half: the traffic of the network comes in here as connections, and this is
// where the bytes are carried.
//
// One connection goes like this:
//
//   1. the rules of the packet filter have redirected it, so it comes to the
//      port this program listens on;
//   2. the program asks the helper where the connection was going before it
//      was redirected. The client of the network says nothing about it, so
//      the kernel is the only one that knows, and the kernel only lets root
//      read it - which is why the question goes to the helper;
//   3. the rules of the app decide where the connection goes. They are the
//      rules of this machine, with one difference: a rule that names a
//      program is not about the traffic of a client, because a client of the
//      network has no program;
//   4. the program opens the connection to the far side and carries the
//      bytes both ways.
//
// The bytes are carried at the level of the bytes and not of the packets. The
// filter gives the reply of the client the address the client wanted to see,
// so the client never learns that its connection went through this machine.
final class GatewayDataPlane {

    // The port the redirected traffic comes in on.
    //
    // It is a port of the loopback: the filter sends the traffic of the
    // network there, and nothing else has to be able to reach it.
    static let redirectPort = 18081

    // How long a connection may say nothing before it is given up.
    //
    // A connection that is idle for a long time is a connection that is not
    // carrying anything, and a machine that is the gateway of a network may
    // have many of them.
    static let idleTimeout: TimeInterval = 300

    // Why the plane could not start.
    //
    // The reason is a word that can be shown to the person in front of the
    // window, so it is kept as a value and not as a number.
    struct Failure: Error {
        let reason: String
        init(_ reason: String) { self.reason = reason }
    }

    // What the plane does with one connection.
    //
    // It is kept away from the sockets, because this is the part that has to
    // be right: it is the place where the rules of the app are read.
    struct Plan: Equatable {
        // where the connection was going before it was redirected
        let target: FlowTarget
        // where it goes now
        let upstream: RuleUpstream
        // why it does not go where the rule said, when that is so
        let note: String?
    }

    // The decision for one connection.
    //
    // The address is the one the connection was going to, and there is no
    // name: the client of the network resolved the name by itself, and the
    // filter does not say what the name was. A rule that names a host is
    // therefore matched against the address, and the rules that want the name
    // will get it when the dns of the clients is taken over as well.
    static func plan(rules: [EngineRule],
                     proxies: [ProxyEndpoint],
                     chains: [String: [String]],
                     originalAddress: String,
                     originalPort: Int) -> Plan {
        let target = FlowTarget(address: originalAddress, port: originalPort, transport: .tcp)
        let decision = ProxyRuleEngine.decide(rules: rules, target: target,
                                              proxies: proxies, chains: chains)
        return Plan(target: target, upstream: decision.upstream, note: decision.note)
    }

    // What the app knows about the traffic that goes through here.
    //
    // The rules are read by the threads of the connections, and they are
    // written by the window, so they have a lock of their own.
    private let stateLock = NSLock()
    private var rules: [EngineRule] = []
    private var proxies: [ProxyEndpoint] = []
    private var chains: [String: [String]] = [:]

    // The socket that waits for the traffic.
    private var listenFD: Int32 = -1
    private var running = false

    // What the traffic has carried so far.
    private var connectionCount = 0
    private var bytesUp: Int64 = 0
    private var bytesDown: Int64 = 0

    // The lines of the log.
    var logHandler: ((String, String) -> Void)?

    // The question of where a connection was going.
    //
    // The helper answers it, because the kernel only lets root read the
    // states of the filter. A test can put another answerer here, so that the
    // part of the plane that does not need a machine can be checked.
    var lookupHandler: ((String, Int, String, Int) -> GatewayProtocol.Response)?

    // MARK: - the rules

    // The rules of the app, as the engine reads them.
    //
    // They are given again every time the gateway is turned on, because the
    // rules of the app may have been changed since the last time.
    func update(rules newRules: [EngineRule],
                proxies newProxies: [ProxyEndpoint],
                chains newChains: [String: [String]]) {
        stateLock.lock()
        rules = newRules
        proxies = newProxies
        chains = newChains
        stateLock.unlock()
    }

    // The rules as they are right now.
    private func snapshot() -> ([EngineRule], [ProxyEndpoint], [String: [String]]) {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (rules, proxies, chains)
    }

    // MARK: - what the traffic has carried

    // How many connections have been carried, and how much they carried.
    var statistics: (connections: Int, up: Int64, down: Int64) {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (connectionCount, bytesUp, bytesDown)
    }

    // MARK: - the life of the plane

    // Starts to listen for the traffic of the network.
    //
    // The port has to be listened on before the rules of the filter are put
    // in place: a client whose connection is redirected to a port that nobody
    // listens on is a client with no internet at all.
    func start(port: Int = GatewayDataPlane.redirectPort) -> Result<String, Failure> {
        stop()

        let result = LocalProxySocket.listen(address: "127.0.0.1",
                                             port: port,
                                             interfaceName: nil)
        guard let fd = result.fd else {
            return .failure(Failure(result.reason ?? "The socket could not be made."))
        }

        stateLock.lock()
        listenFD = fd
        running = true
        stateLock.unlock()

        let thread = Thread { [weak self] in
            self?.acceptLoop()
        }
        thread.stackSize = 512 * 1024
        thread.start()

        return .success("The gateway is listening on 127.0.0.1:\(GatewayDataPlane.redirectPort).")
    }

    // Stops listening. The connections that are open are ended as well.
    func stop() {
        stateLock.lock()
        let wasRunning = running
        running = false
        let fd = listenFD
        listenFD = -1
        stateLock.unlock()

        if wasRunning, fd >= 0 {
            // the accept in the thread comes back with an error, and the
            // thread ends
            shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
    }

    private var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    // MARK: - accepting

    private func acceptLoop() {
        while isRunning {
            stateLock.lock()
            let fd = listenFD
            stateLock.unlock()
            if fd < 0 { break }

            var address = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &address) { pointer -> Int32 in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                    Darwin.accept(fd, generic, &length)
                }
            }
            if client < 0 {
                if errno == EINTR { continue }
                break
            }

            let thread = Thread { [weak self] in
                self?.handle(client: client)
            }
            thread.stackSize = 512 * 1024
            thread.start()
        }
    }

    // MARK: - one connection

    private func handle(client fd: Int32) {
        defer { Darwin.close(fd) }

        // A client that goes away while the bytes are being written must not
        // take the app down with a signal.
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))

        guard let peer = GatewayDataPlane.peer(of: fd) else { return }
        guard let local = GatewayDataPlane.local(of: fd) else { return }

        // Where the connection was going before it was redirected.
        //
        // The question names the two ends of the connection the way the
        // socket sees them: the client on one side, and the port of this
        // program on the other. That is the way the kernel keeps the state of
        // a redirected connection, and it is the way it gives the place back.
        let answer = askWhereItWasGoing(peer: peer, local: local)
        guard answer.ok,
              let originalAddress = answer.originalAddress,
              let originalPort = answer.originalPort else {
            let reason = answer.message ?? "the kernel did not say where the connection was going"
            log("The connection of \(peer.address) was closed: \(reason)", level: "ERROR")
            return
        }

        let (allRules, allProxies, allChains) = snapshot()
        let plan = GatewayDataPlane.plan(rules: allRules, proxies: allProxies, chains: allChains,
                                         originalAddress: originalAddress, originalPort: originalPort)
        if let note = plan.note {
            // the reason the traffic did not go where the rule said is worth
            // a line in the log: a rule that points at something that is not
            // there is a rule that does not do what it says
            log(note, level: "WARN")
        }

        switch plan.upstream {
        case .blocked:
            log("The connection of \(peer.address) to \(plan.target.text) was blocked by a rule", level: "INFO")
            return
        default:
            break
        }

        guard let upstreamFD = dial(plan.upstream, target: plan.target) else {
            log("The connection of \(peer.address) to \(plan.target.text) could not be made", level: "ERROR")
            return
        }

        stateLock.lock()
        connectionCount += 1
        stateLock.unlock()

        log("The connection of \(peer.address) to \(plan.target.text) goes \(description(of: plan.upstream))", level: "INFO")
        relay(client: fd, upstream: upstreamFD)
    }

    // The question to the helper.
    //
    // It is not private, because a test asks it as well: the question is
    // what the plane asks the kernel, and a question that is wrong is a
    // question that is wrong in one place only.
    func askWhereItWasGoing(peer: (address: String, port: Int),
                             local: (address: String, port: Int)) -> GatewayProtocol.Response {
        if let lookupHandler {
            return lookupHandler(peer.address, peer.port, local.address, local.port)
        }
        return GatewayHelperClient.lookup(clientAddress: peer.address, clientPort: peer.port,
                                          destinationAddress: local.address, destinationPort: local.port).response
    }

    // The way out.
    private func dial(_ upstream: RuleUpstream, target: FlowTarget) -> Int32? {
        switch upstream {
        case .blocked:
            return nil
        case .direct:
            let result = LocalProxySocket.connect(host: target.proxyHost, port: target.port, timeout: 15)
            return result.fd
        case .proxy(let endpoint):
            let result = LocalProxySocket.connect(host: endpoint.host, port: endpoint.port, timeout: 15)
            guard let fd = result.fd else { return nil }
            LocalProxySocket.clearTimeout(fd)
            if !LocalProxyDialer.handshake(fd: fd, through: endpoint, target: target) {
                Darwin.close(fd)
                return nil
            }
            return fd
        case .chain(let hops):
            return dialChain(hops, target: target)
        }
    }

    // A chain is walked through one proxy at a time: every proxy but the last
    // one is asked to reach the next one, and the last one is asked to reach
    // the place the client wanted to go.
    private func dialChain(_ hops: [ProxyEndpoint], target: FlowTarget) -> Int32? {
        guard let first = hops.first else { return nil }
        let result = LocalProxySocket.connect(host: first.host, port: first.port, timeout: 15)
        guard let fd = result.fd else { return nil }
        LocalProxySocket.clearTimeout(fd)
        for i in 0..<(hops.count - 1) {
            let next = hops[i + 1]
            if !LocalProxyDialer.handshake(fd: fd, through: hops[i],
                                          target: FlowTarget(host: next.host, port: next.port)) {
                Darwin.close(fd)
                return nil
            }
        }
        let last = hops[hops.count - 1]
        if !LocalProxyDialer.handshake(fd: fd, through: last, target: target) {
            Darwin.close(fd)
            return nil
        }
        return fd
    }

    // MARK: - the relay

    // The traffic goes both ways until one of the sides stops.
    //
    // The idle time is the limit of the wait: a client that goes away without
    // closing the connection does not stay open for ever.
    private func relay(client fd: Int32, upstream upstreamFD: Int32) {
        defer { Darwin.close(upstreamFD) }
        LocalProxySocket.clearTimeout(fd)
        LocalProxySocket.clearTimeout(upstreamFD)

        var fds = [
            pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
            pollfd(fd: upstreamFD, events: Int16(POLLIN), revents: 0)
        ]
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)

        while isRunning {
            fds[0].revents = 0
            fds[1].revents = 0
            let ready = poll(&fds, 2, Int32(GatewayDataPlane.idleTimeout * 1000))
            if ready <= 0 { break }

            for index in 0..<2 {
                guard fds[index].revents != 0 else { continue }
                let from = index == 0 ? fd : upstreamFD
                let to = index == 0 ? upstreamFD : fd

                let count = Darwin.recv(from, &buffer, buffer.count, 0)
                if count <= 0 {
                    if errno == EINTR { continue }
                    // one of the two sides is done: the other one is told that
                    // there will be no more, and the connection ends
                    Darwin.shutdown(to, SHUT_WR)
                    return
                }
                var sent = 0
                while sent < count {
                    let written = buffer.withUnsafeBytes { raw -> Int in
                        guard let base = raw.baseAddress else { return -1 }
                        return Darwin.send(to, base.advanced(by: sent), count - sent, 0)
                    }
                    if written <= 0 {
                        if errno == EINTR { continue }
                        return
                    }
                    sent += written
                }
                countBytes(up: index == 0 ? count : 0, down: index == 0 ? 0 : count)
            }
        }
    }

    private func countBytes(up: Int, down: Int) {
        stateLock.lock()
        bytesUp += Int64(up)
        bytesDown += Int64(down)
        stateLock.unlock()
    }

    // MARK: - the ends of a connection

    // The other end of a connection, as the socket sees it.
    static func peer(of fd: Int32) -> (address: String, port: Int)? {
        var storage = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &storage) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.getpeername(fd, generic, &length)
            }
        }
        guard ok == 0 else { return nil }
        return (text(of: storage), Int(UInt16(bigEndian: storage.sin_port)))
    }

    // This end of a connection, as the socket sees it.
    //
    // For a redirected connection this is the address and the port the filter
    // sent the traffic to, and they are the second half of the question of
    // where the connection was going.
    static func local(of fd: Int32) -> (address: String, port: Int)? {
        var storage = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &storage) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.getsockname(fd, generic, &length)
            }
        }
        guard ok == 0 else { return nil }
        return (text(of: storage), Int(UInt16(bigEndian: storage.sin_port)))
    }

    // The text of an address.
    private static func text(of address: sockaddr_in) -> String {
        var storage = address.sin_addr
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &storage, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
            return "0.0.0.0"
        }
        return String(cString: buffer)
    }

    // MARK: - the log

    private func log(_ message: String, level: String) {
        logHandler?(message, level)
    }

    // How the way out is told in the log.
    private func description(of upstream: RuleUpstream) -> String {
        switch upstream {
        case .direct:
            return "straight out"
        case .blocked:
            return "nowhere, a rule blocks it"
        case .proxy(let endpoint):
            return "through \(endpoint.label)"
        case .chain(let hops):
            let names = hops.map { $0.label }.joined(separator: " and then ")
            return "through \(names)"
        }
    }
}
