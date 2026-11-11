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
    // The address is the one the connection was going to, and the names are
    // the ones that address is known by - the gateway mode learned them from
    // the dns of the clients. A rule that names a host is matched against
    // the names as well as against the address, and the proxy server is
    // asked for the name, so that the name is resolved where the proxy
    // server is and not here.
    static func plan(rules: [EngineRule],
                     proxies: [ProxyEndpoint],
                     chains: [String: [String]],
                     options: GatewayRouting.Options = GatewayRouting.Options(),
                     originalAddress: String,
                     originalPort: Int,
                     transport: FlowProtocol = .tcp,
                     names: [String] = []) -> Plan {
        let target = FlowTarget(name: names.first,
                                address: originalAddress,
                                aliases: Array(names.dropFirst()),
                                port: originalPort,
                                transport: transport)
        let decision = GatewayRouting.decide(rules: rules, proxies: proxies, chains: chains,
                                             options: options, target: target)
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
    // the switches above the rules
    private var options = GatewayRouting.Options()

    // The port the datagrams are taken in on.
    //
    // The port may be one the system gave, so it is asked of the socket.
    var datagramPort: Int {
        stateLock.lock()
        let fd = datagramFD
        stateLock.unlock()
        guard fd >= 0 else { return 0 }
        var storage = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &storage) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.getsockname(fd, generic, &length)
            }
        }
        guard ok == 0 else { return 0 }
        return Int(UInt16(bigEndian: storage.sin_port))
    }

    // The socket that waits for the traffic.
    private var listenFD: Int32 = -1
    // The socket that waits for the datagrams.
    private var datagramFD: Int32 = -1
    private var running = false

    // The flows of the datagrams, by the client they come from.
    //
    // A datagram of the network is one flow of one client: everything a
    // client sends from one port is one flow.
    private var udpSessions: [String: GatewayUDPSession] = [:]
    private let udpLock = NSLock()

    // The address the traffic of the network is redirected to.
    //
    // It is the address of this machine on the network of the clients, and
    // the kernel looks a flow up by it: the answer of the filter has to come
    // from the same place the traffic was sent to.
    private var redirectAddress: String = "127.0.0.1"
    // The port the traffic of the network is redirected to.
    private var redirectPort: Int = GatewayDataPlane.redirectPort

    // Every address of this machine.
    //
    // A client of the network may ask this machine for a name, and then the
    // query comes to an address of this machine. The query cannot be
    // answered by this machine - it would come back to where it started -
    // so it goes to a resolver of the system instead.
    private var ownAddresses: Set<String> = ["127.0.0.1"]

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
    var lookupHandler: ((String, Int, String, Int, String) -> GatewayProtocol.Response)?

    // MARK: - the rules

    // The rules of the app, as the engine reads them.
    //
    // They are given again every time the gateway is turned on, because the
    // rules of the app may have been changed since the last time.
    func update(rules newRules: [EngineRule],
                proxies newProxies: [ProxyEndpoint],
                chains newChains: [String: [String]],
                options newOptions: GatewayRouting.Options = GatewayRouting.Options()) {
        stateLock.lock()
        rules = newRules
        proxies = newProxies
        chains = newChains
        options = newOptions
        stateLock.unlock()
    }

    // The rules as they are right now.
    private func snapshot() -> ([EngineRule], [ProxyEndpoint], [String: [String]], GatewayRouting.Options) {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (rules, proxies, chains, options)
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
    //
    // The address is the address of this machine on the network of the
    // clients, and not the loopback. The filter sends the traffic of the
    // network to that address, and the answer of the filter comes back from
    // it: the answer has to come from the same place the traffic was sent
    // to, or the kernel does not recognise it as the answer of the traffic
    // it redirected, and the client sees the answer of somebody else.
    func start(port: Int = GatewayDataPlane.redirectPort,
               address: String = "127.0.0.1") -> Result<String, Failure> {
        stop()

        let result = LocalProxySocket.listen(address: address,
                                             port: port,
                                             interfaceName: nil)
        guard let fd = result.fd else {
            return .failure(Failure(result.reason ?? "The socket could not be made."))
        }

        // the datagrams come in on a socket of their own: a datagram is not a
        // connection, and a socket of connections cannot take one
        let datagrams = LocalProxySocket.listenUDP(address: address, port: port)
        guard let datagramFD = datagrams.fd else {
            Darwin.close(fd)
            return .failure(Failure(datagrams.reason ?? "The socket for the datagrams could not be made."))
        }

        stateLock.lock()
        listenFD = fd
        self.datagramFD = datagramFD
        redirectAddress = address
        redirectPort = port
        // The addresses of this machine are asked once and then kept: a
        // client that asks this machine for a name has to be told where the
        // query really goes, and the addresses of the machine do not change
        // while the gateway is on.
        ownAddresses = Set(LocalAddresses.all().map { $0.address } + ["127.0.0.1", address])
        running = true
        stateLock.unlock()

        let thread = Thread { [weak self] in
            self?.acceptLoop()
        }
        thread.stackSize = 512 * 1024
        thread.start()

        let datagramThread = Thread { [weak self] in
            self?.datagramLoop()
        }
        datagramThread.stackSize = 512 * 1024
        datagramThread.start()

        return .success("The gateway is listening on \(address):\(port).")
    }

    // Stops listening. The connections that are open are ended as well.
    func stop() {
        stateLock.lock()
        let wasRunning = running
        running = false
        let fd = listenFD
        let datagrams = datagramFD
        listenFD = -1
        datagramFD = -1
        stateLock.unlock()

        if wasRunning, fd >= 0 {
            // the accept in the thread comes back with an error, and the
            // thread ends
            shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
        if wasRunning, datagrams >= 0 {
            shutdown(datagrams, SHUT_RDWR)
            Darwin.close(datagrams)
        }

        // the flows of the datagrams go with the socket they came in on
        udpLock.lock()
        let sessions = udpSessions.values
        udpSessions.removeAll()
        udpLock.unlock()
        for session in sessions {
            session.close()
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

    // MARK: - the datagrams

    // The datagrams of the network come in here.
    //
    // A datagram is not a connection: it has no opening and no closing, and
    // the client says nothing about where it was going. The kernel is the
    // only one that knows, and it is asked once for every flow.
    private func datagramLoop() {
        var buffer = [UInt8](repeating: 0, count: 65535)
        while isRunning {
            stateLock.lock()
            let fd = datagramFD
            stateLock.unlock()
            if fd < 0 { break }

            var from = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &from) { pointer -> Int in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                    Darwin.recvfrom(fd, &buffer, buffer.count, 0, generic, &length)
                }
            }
            if count < 0 {
                if errno == EINTR { continue }
                break
            }
            if count == 0 { continue }

            handle(datagram: Data(buffer[0..<count]), from: from)
        }
    }

    // One datagram of the network.
    private func handle(datagram: Data, from client: sockaddr_in) {
        guard let session = session(for: client) else { return }
        session.enqueue(datagram)
    }

    // The flow of a client.
    //
    // The flow is made when the first datagram of the client comes in, and it
    // is kept until it has been quiet for a while. The flows that are quiet
    // are given up from time to time, and there is a cap on how many there
    // may be.
    private func session(for client: sockaddr_in) -> GatewayUDPSession? {
        let key = GatewayUDPSession.key(for: client)

        udpLock.lock()
        if let existing = udpSessions[key] {
            udpLock.unlock()
            return existing
        }
        udpLock.unlock()

        stateLock.lock()
        let fd = datagramFD
        let address = redirectAddress
        let port = redirectPort
        stateLock.unlock()
        guard fd >= 0 else { return nil }

        let made = GatewayUDPSession(clientAddress: client, listenFD: fd) { [weak self] host, clientPort in
            guard let self else { return nil }
            return self.planForDatagram(clientAddress: host, clientPort: clientPort,
                                        redirectAddress: address, redirectPort: port)
        }

        udpLock.lock()
        // two datagrams of the same client may come in at the same moment,
        // and there is one flow for both of them
        if let existing = udpSessions[key] {
            udpLock.unlock()
            made.close()
            return existing
        }
        let full = udpSessions.count >= GatewayUDPSession.flowLimit
        udpLock.unlock()

        if full {
            // the machine that is the gateway of a big network has many
            // flows, and the quiet ones are given up to make room
            log("There are already \(GatewayUDPSession.flowLimit) flows of datagrams: the quiet ones are given up",
                level: "WARN")
            giveUpQuietFlows()
        }

        udpLock.lock()
        if let existing = udpSessions[key] {
            udpLock.unlock()
            made.close()
            return existing
        }
        udpSessions[key] = made
        udpLock.unlock()

        // the flow takes itself out of the place it is kept when it is over
        made.onEnded = { [weak self] ended in
            guard let self else { return }
            self.udpLock.lock()
            self.udpSessions.removeValue(forKey: ended)
            self.udpLock.unlock()
        }

        made.start()
        return made
    }

    // Where the datagrams of a flow go.
    //
    // The kernel is asked where the datagram was going before the filter
    // redirected it, and the rules of the app say where it goes now.
    private func planForDatagram(clientAddress: String, clientPort: Int,
                                  redirectAddress: String, redirectPort: Int) -> GatewayUDPSession.Plan? {
        let answer = askWhereItWasGoing(peer: (clientAddress, clientPort),
                                        local: (redirectAddress, redirectPort),
                                        transport: "UDP")
        guard answer.ok,
              let originalAddress = answer.originalAddress,
              let originalPort = answer.originalPort else {
            let reason = answer.message ?? "the kernel did not say where the datagram was going"
            log("The datagrams of \(clientAddress) were dropped: \(reason)", level: "ERROR")
            return nil
        }

        // The query for a name that was meant for this machine goes to a
        // resolver of the system instead. It cannot be answered here: the
        // answer would come back to where the query started, and the client
        // would wait for ever.
        let destination = dnsDestination(for: originalAddress, port: originalPort)

        let (allRules, allProxies, allChains, allOptions) = snapshot()
        let plan = GatewayDataPlane.plan(rules: allRules, proxies: allProxies, chains: allChains,
                                         options: allOptions,
                                         originalAddress: destination, originalPort: originalPort,
                                         transport: .udp)
        if let note = plan.note {
            log(note, level: "WARN")
        }
        return GatewayUDPSession.Plan(target: plan.target, upstream: plan.upstream, note: plan.note)
    }

    // Where a query for a name really goes.
    //
    // A client of the network may use this machine as its resolver, and then
    // the query comes to an address of this machine. The answer cannot come
    // from here: it would come back to where the query started, and the
    // client would wait for ever. A resolver of the system is asked instead,
    // and it is the one the machine itself uses.
    private func dnsDestination(for address: String, port: Int) -> String {
        guard GatewayDNS.isDNS(port: port), isOwnAddress(address) else { return address }
        guard let resolver = GatewayDNS.systemResolver() else { return address }
        return resolver
    }

    // Whether the address is one of this machine.
    private func isOwnAddress(_ address: String) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return ownAddresses.contains(address)
    }

    // The flows that have been quiet for too long are given up.
    //
    // A flow of udp has no closing, so the silence is the only sign that it
    // is over.
    func giveUpQuietFlows() {
        udpLock.lock()
        let quiet = udpSessions.values.filter { $0.idleTime() > GatewayUDPSession.idleTimeout }
        for flow in quiet {
            udpSessions.removeValue(forKey: flow.key)
        }
        udpLock.unlock()
        for flow in quiet {
            flow.close()
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

        let (allRules, allProxies, allChains, allOptions) = snapshot()
        // The names the address is known by. They were learned from the dns
        // of the clients, and they are what a rule that names a host is
        // matched against.
        let names = GatewayDNS.names(for: originalAddress)
        // A query for a name that was meant for this machine goes to a
        // resolver of the system instead.
        let destination = dnsDestination(for: originalAddress, port: originalPort)
        let plan = GatewayDataPlane.plan(rules: allRules, proxies: allProxies, chains: allChains,
                                         options: allOptions,
                                         originalAddress: destination, originalPort: originalPort,
                                         names: names)
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
        relay(client: fd, upstream: upstreamFD, dns: GatewayDNS.isDNS(port: plan.target.port))
    }

    // The question to the helper.
    //
    // It is not private, because a test asks it as well: the question is
    // what the plane asks the kernel, and a question that is wrong is a
    // question that is wrong in one place only.
    func askWhereItWasGoing(peer: (address: String, port: Int),
                             local: (address: String, port: Int),
                             transport: String = "TCP") -> GatewayProtocol.Response {
        if let lookupHandler {
            return lookupHandler(peer.address, peer.port, local.address, local.port, transport)
        }
        return GatewayHelperClient.lookup(clientAddress: peer.address, clientPort: peer.port,
                                          destinationAddress: local.address, destinationPort: local.port,
                                          transport: transport).response
    }

    // The way out.
    private func dial(_ upstream: RuleUpstream, target: FlowTarget) -> Int32? {
        switch upstream {
        case .blocked:
            return nil
        case .direct:
            let result = LocalProxySocket.connect(host: target.directHost, port: target.port, timeout: 15)
            return result.fd
        case .proxy(let endpoint):
            return LocalProxyDialer.connectAndGreet(endpoint: endpoint, target: target)
        case .chain(let hops):
            return dialChain(hops, target: target)
        }
    }

    // A chain is walked through one proxy at a time: every proxy but the last
    // one is asked to reach the next one, and the last one is asked to reach
    // the place the client wanted to go.
    private func dialChain(_ hops: [ProxyEndpoint], target: FlowTarget) -> Int32? {
        return LocalProxyDialer.connectAndGreetChain(hops: hops, target: target)
    }

    // MARK: - the relay

    // The traffic goes both ways until one of the sides stops.
    //
    // The idle time is the limit of the wait: a client that goes away without
    // closing the connection does not stay open for ever.
    private func relay(client fd: Int32, upstream upstreamFD: Int32, dns: Bool = false) {
        defer { Darwin.close(upstreamFD) }
        LocalProxySocket.clearTimeout(fd)
        LocalProxySocket.clearTimeout(upstreamFD)

        var fds = [
            pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
            pollfd(fd: upstreamFD, events: Int16(POLLIN), revents: 0)
        ]
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)

        // The answer of a resolver, when the flow is a flow of dns.
        //
        // A resolver that is asked over tcp says how long the message is in
        // front of the message, and the message itself follows. The bytes go
        // to the client as they are, and the name is taken out of them on
        // the way: it is the only place the name is said.
        var dnsBuffer = Data()
        var dnsAnswerSeen = false

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
                if dns, index == 1, !dnsAnswerSeen {
                    dnsBuffer.append(contentsOf: buffer[0..<count])
                    if GatewayDataPlane.takeDNSAnswer(&dnsBuffer) {
                        dnsAnswerSeen = true
                    }
                }
                countBytes(up: index == 0 ? count : 0, down: index == 0 ? 0 : count)
            }
        }
    }

    // The name of a dns answer that came over tcp.
    //
    // The message says how long it is in front of it, and it is only read
    // when all of it has come. The name is remembered and the message is
    // left alone: the client is waiting for it.
    private static func takeDNSAnswer(_ buffer: inout Data) -> Bool {
        guard buffer.count >= 2 else { return false }
        let length = Int(buffer[buffer.startIndex]) << 8 | Int(buffer[buffer.startIndex + 1])
        guard length > 0, buffer.count >= length + 2 else { return false }
        let message = Data(buffer[(buffer.startIndex + 2)..<(buffer.startIndex + length + 2)])
        GatewayDNS.record(answer: message)
        return true
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
    static func text(of address: sockaddr_in) -> String {
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
