import Foundation
import Darwin

// The flow of the datagrams of one client.
//
// A datagram of the network is one flow of one client: everything a client
// sends from one port is one flow, and the flow is kept until it has been
// quiet for a while.
//
// The flow keeps the way out open and carries the datagrams both ways. The
// way out is either a socket of its own - the traffic goes straight out - or
// the association of a socks5 proxy: one connection that asks for it, and
// one socket that the datagrams go through.
//
// One flow has an association of its own, and not one association for many
// flows: the answer of the proxy comes back to the socket the datagram went
// out of, and a socket that is shared by two flows cannot say which of them
// an answer belongs to. The price is one connection to the proxy for every
// flow of the network, and the flows are given up when they are quiet.
final class GatewayUDPSession {

    // Where the datagrams of the client come from, and the key of the flow.
    let clientAddress: sockaddr_in
    let key: String

    // The socket the datagrams of the client come in on.
    //
    // The answer goes back out of the same socket, and the filter rewrites
    // its address on the way: the client sees the answer from the place it
    // was asking, and not from this machine.
    private let listenFD: Int32

    // The way out of the flow.
    private var upstreamSocket: Int32 = -1
    // the connection that holds the association of the proxy open
    private var controlSocket: Int32 = -1
    // where the datagrams have to go, when they go through a proxy
    private var relayAddress = sockaddr_in()
    // the header that says which destination a datagram of the association is
    // for
    private var header = Data()
    // whether the datagrams carry that header
    private var carriesHeader = false

    // The datagrams that are waiting to go out.
    private var pending: [Data] = []
    private let lock = NSLock()

    // The pipe that says "there is something to do".
    private var wakeRead: Int32 = -1
    private var wakeWrite: Int32 = -1

    // whether the flow is still here
    private var closed = false
    // when the flow was last heard from
    private var lastActivity = Date()

    // The question of where the datagrams were going and where they go now.
    //
    // It is asked on the thread of the flow, so that the thread that takes
    // the datagrams in is never held up by a handshake that takes a moment.
    let planner: (String, Int) -> Plan?

    // What is said when the flow is over.
    //
    // The flow takes itself out of the place it is kept: a flow that is
    // quiet for a while is a flow that is over, and a flow that stays in the
    // place it is kept is a flow that is kept for ever.
    var onEnded: ((String) -> Void)?

    // What the flow does with the datagrams of the client.
    struct Plan {
        // where the datagrams were going before the filter redirected them
        let target: FlowTarget
        // where they go now
        let upstream: RuleUpstream
        // why they do not go where the rule said, when that is so
        let note: String?
    }

    // How long a flow may say nothing before it is given up.
    //
    // A flow of udp has no closing: a phone that stops using a socket does
    // not say so, and the only sign that a flow is over is the silence. The
    // time is long enough for a call that has a pause in it, and short
    // enough that the machine is not left with the flows of everybody who
    // ever was on the network.
    static let idleTimeout: TimeInterval = 300

    // The most flows of the network that are kept at the same time.
    //
    // Every flow has a socket and a connection of its own, and a network with
    // many terminals has many flows. The cap is there so that a machine that
    // is the gateway of a big network does not end up with a flow for every
    // datagram that ever came in.
    static let flowLimit = 512

    // MARK: - the making

    init(clientAddress: sockaddr_in, listenFD: Int32, planner: @escaping (String, Int) -> Plan?) {
        self.clientAddress = clientAddress
        self.key = GatewayUDPSession.key(for: clientAddress)
        self.listenFD = listenFD
        self.planner = planner
        var fds: [Int32] = [0, 0]
        if pipe(&fds) == 0 {
            // the ends of the pipe do not wait: the thread that takes the
            // datagrams in must not be held up by a full pipe
            var flags = fcntl(fds[0], F_GETFL, 0)
            _ = fcntl(fds[0], F_SETFL, flags | O_NONBLOCK)
            flags = fcntl(fds[1], F_GETFL, 0)
            _ = fcntl(fds[1], F_SETFL, flags | O_NONBLOCK)
            wakeRead = fds[0]
            wakeWrite = fds[1]
        }
    }

    // The key of a flow.
    //
    // The address and the port of the client are what tell one flow from
    // another: a client that sends from one port to many places is one flow,
    // and a client that sends from many ports is many flows.
    static func key(for address: sockaddr_in) -> String {
        let host = GatewayDataPlane.text(of: address)
        return "\(host):\(Int(UInt16(bigEndian: address.sin_port)))"
    }

    // MARK: - the life of the flow

    // Starts the thread of the flow.
    func start() {
        let thread = Thread { [weak self] in
            self?.loop()
        }
        thread.stackSize = 512 * 1024
        thread.start()
    }

    // Gives the flow up.
    //
    // The socket of the way out and the connection of the association are
    // closed, and the flow is not heard from any more.
    func close() {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()

        if upstreamSocket >= 0 {
            Darwin.close(upstreamSocket)
            upstreamSocket = -1
        }
        if controlSocket >= 0 {
            Darwin.close(controlSocket)
            controlSocket = -1
        }
        if wakeRead >= 0 {
            Darwin.close(wakeRead)
            wakeRead = -1
        }
        if wakeWrite >= 0 {
            Darwin.close(wakeWrite)
            wakeWrite = -1
        }
    }

    private var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    // How long the flow has been quiet.
    func idleTime() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return Date().timeIntervalSince(lastActivity)
    }

    // MARK: - the datagrams of the client

    // A datagram of the client comes in.
    //
    // It is put in the line and the flow is woken up: the way out may not be
    // open yet, and the datagram waits for it.
    func enqueue(_ payload: Data) {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        pending.append(payload)
        lastActivity = Date()
        let write = wakeWrite
        lock.unlock()

        guard write >= 0 else { return }
        var byte: UInt8 = 1
        withUnsafeBytes(of: &byte) { raw in
            guard let base = raw.baseAddress else { return }
            _ = Darwin.write(write, base, 1)
        }
    }

    // MARK: - the thread of the flow

    private func loop() {
        // the way out is opened on the thread of the flow: the handshake of
        // an association of a proxy takes a moment, and the thread that
        // takes the datagrams in must not wait for it
        var opened = false
        var buffer = [UInt8](repeating: 0, count: 65535)

        while !isClosed {
            var fds = [pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)]
            if upstreamSocket >= 0 {
                fds.append(pollfd(fd: upstreamSocket, events: Int16(POLLIN), revents: 0))
            }
            let ready = poll(&fds, nfds_t(fds.count), 500)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 {
                // a flow of udp is over when it is quiet
                if idleTime() > GatewayUDPSession.idleTimeout { break }
                continue
            }

            if fds[0].revents & Int16(POLLIN) != 0 {
                if !opened {
                    opened = open()
                    if !opened {
                        // the way out could not be opened: the datagrams of
                        // this flow have nowhere to go
                        break
                    }
                    continue
                }
                sendPending()
            }

            if fds.count > 1, fds[1].revents & Int16(POLLIN) != 0 {
                receive(buffer: &buffer)
            }
        }
        close()
        // the flow takes itself out of the place it is kept
        onEnded?(key)
    }

    // The way out of the flow.
    //
    // Where the datagrams were going is asked of the kernel, and the rules of
    // the app say where they go now.
    private func open() -> Bool {
        let host = GatewayDataPlane.text(of: clientAddress)
        let port = Int(UInt16(bigEndian: clientAddress.sin_port))
        guard let plan = planner(host, port) else { return false }

        switch plan.upstream {
        case .blocked:
            // a rule blocks the traffic: the datagrams are dropped, and the
            // flow is not opened
            return false
        case .direct:
            guard let socket = LocalProxySocket.connectUDP(host: plan.target.proxyHost,
                                                           port: plan.target.port) else {
                return false
            }
            upstreamSocket = socket
            return true
        case .proxy(let endpoint):
            guard let association = LocalProxyDialer.udpAssociate(endpoint: endpoint) else {
                return false
            }
            upstreamSocket = association.socket
            controlSocket = association.control
            relayAddress = GatewayUDPSession.address(host: association.host, port: association.port)
            header = LocalProxyDialer.udpHeader(host: plan.target.proxyHost, port: plan.target.port)
            carriesHeader = true
            return true
        case .chain:
            // a chain cannot carry a datagram, and the engine has already said
            // so: the traffic goes straight out
            guard let socket = LocalProxySocket.connectUDP(host: plan.target.proxyHost,
                                                           port: plan.target.port) else {
                return false
            }
            upstreamSocket = socket
            return true
        }
    }

    // The datagrams that are waiting go out.
    private func sendPending() {
        // the pipe is emptied first: it says that there is something to do,
        // and not how much of it there is
        var scratch = [UInt8](repeating: 0, count: 64)
        _ = Darwin.read(wakeRead, &scratch, scratch.count)

        lock.lock()
        let queue = pending
        pending.removeAll()
        lock.unlock()

        for payload in queue {
            sendUpstream(payload)
        }
    }

    // One datagram goes out.
    private func sendUpstream(_ payload: Data) {
        guard upstreamSocket >= 0 else { return }
        if carriesHeader {
            var datagram = header
            datagram.append(payload)
            var to = relayAddress
            datagram.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                _ = withUnsafePointer(to: &to) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                        Darwin.sendto(upstreamSocket, base, raw.count, 0, generic,
                                      socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        } else {
            payload.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                _ = Darwin.send(upstreamSocket, base, raw.count, 0)
            }
        }
    }

    // The answer of the other side comes in.
    private func receive(buffer: inout [UInt8]) {
        var from = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let count = withUnsafeMutablePointer(to: &from) { pointer -> Int in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.recvfrom(upstreamSocket, &buffer, buffer.count, 0, generic, &length)
            }
        }
        guard count > 0 else { return }

        var payload = Data(buffer[0..<count])
        if carriesHeader {
            guard let bare = LocalProxyDialer.stripUDPHeader(payload) else {
                return
            }
            payload = bare
        }
        sendBack(payload)
    }

    // The answer goes back to the client.
    //
    // It goes out of the socket the datagram came in on, and the filter
    // rewrites its address on the way: the client sees the answer from the
    // place it was asking, and not from this machine.
    private func sendBack(_ payload: Data) {
        lock.lock()
        lastActivity = Date()
        lock.unlock()

        var to = clientAddress
        payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = withUnsafePointer(to: &to) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                    Darwin.sendto(listenFD, base, raw.count, 0, generic,
                                  socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    // The address of a place, as the sockets say it.
    //
    // The proxy may say the relay by name and not by number, and a name that
    // is not looked up would be the address of nobody.
    static func address(host: String, port: Int) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(clamping: port)).bigEndian

        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_flags = AI_NUMERICSERV
        var result: UnsafeMutablePointer<addrinfo>?
        if getaddrinfo(host, String(port), &hints, &result) == 0, let first = result {
            var candidate: UnsafeMutablePointer<addrinfo>? = first
            while let entry = candidate {
                if entry.pointee.ai_addr.pointee.sa_family == sa_family_t(AF_INET) {
                    var storage = entry.pointee.ai_addr.pointee
                    withUnsafeMutablePointer(to: &storage) { pointer in
                        pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { generic in
                            address.sin_addr = generic.pointee.sin_addr
                        }
                    }
                    break
                }
                candidate = entry.pointee.ai_next
            }
            freeaddrinfo(result)
        }
        return address
    }
}
