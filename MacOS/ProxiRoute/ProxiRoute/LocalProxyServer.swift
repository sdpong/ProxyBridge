import Foundation
import Darwin

// The proxy server that runs inside ProxiRoute.
//
// The extension sends the traffic of this machine out. This server does the
// other half: it lets the other machines of the network send their traffic
// out through this one, by talking SOCKS5 or HTTP to them.
//
// It runs in the app and not in the extension. The extension is the one that
// is allowed to touch the traffic of the machine, and a server that other
// machines talk to has to be an ordinary program.
//
// The sockets are the app's own, so that the server can listen on one
// address and on one network card. See LocalProxySocket for why.
final class LocalProxyServer {

    // what happened when the server was started
    enum StartResult {
        case started(String)      // the address it listens on
        case failed(String)       // why it did not start
    }

    private let stateLock = NSLock()
    private var listenFD: Int32 = -1
    private var running = false
    private var settings = LocalProxySettings.default
    // how many clients are connected right now
    private var clientCount = 0
    // how many connections have been accepted, for the log
    private var acceptedCount = 0

    // the proxy list of the app, for the upstream that names one
    var proxyConfigs: [LocalProxyEndpoint] = []
    // the rules of the app, for the upstream that follows them
    var rules: [LocalProxyRule] = []

    // MARK: - the life of the server

    func start(settings newSettings: LocalProxySettings, completion: @escaping (StartResult) -> Void) {
        stop()
        stateLock.lock()
        settings = newSettings
        stateLock.unlock()

        // The network card, when one is named. The kind is what is stored
        // ("wifi"), the name of the interface is what the socket needs, and
        // the name changes when the network changes.
        var interfaceName: String? = nil
        if !newSettings.listenInterface.isEmpty {
            interfaceName = LocalProxyServer.interfaceName(ofKind: newSettings.listenInterface)
            if interfaceName == nil {
                log("The interface \(newSettings.listenInterface) is not there, the server listens on every address")
            }
        }

        let address = newSettings.listenAddress.isEmpty ? "::" : newSettings.listenAddress
        let result = LocalProxySocket.listen(address: address, port: newSettings.port, interfaceName: interfaceName)
        guard let fd = result.fd else {
            let reason = result.reason ?? "The socket could not be made."
            // the reason is in the log as well: the status line of the window
            // is only there while the window is open
            log("The proxy server did not start: \(reason)", level: "ERROR")
            if reason == "in use" {
                // the port is the usual reason. the person wants to know who
                // has it, not that something went wrong.
                if let owner = PortOwner.listener(ofPort: newSettings.port) {
                    completion(.failed("The port \(newSettings.port) is taken by \(owner)."))
                } else {
                    completion(.failed("The port \(newSettings.port) is taken by another program."))
                }
            } else {
                completion(.failed(reason))
            }
            return
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

        let shown = newSettings.listenAddress.isEmpty ? "every address" : newSettings.listenAddress
        log("The proxy server listens on \(shown):\(newSettings.port)")
        completion(.started("\(shown):\(newSettings.port)"))
    }

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

    // how many clients are connected right now
    var connectionCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return clientCount
    }

    // MARK: - accepting

    private func acceptLoop() {
        while isRunning {
            stateLock.lock()
            let fd = listenFD
            let overLimit = clientCount >= settings.maxConnections
            stateLock.unlock()
            if fd < 0 { break }

            var address = sockaddr_in6()
            var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
            let client = withUnsafeMutablePointer(to: &address) { pointer -> Int32 in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                    Darwin.accept(fd, generic, &length)
                }
            }
            if client < 0 {
                if errno == EINTR { continue }
                break
            }
            if overLimit {
                // Too many clients. The oldest one would be the one to go, but
                // a queue of waiters costs more than it is worth.
                log("A client was turned away, there are already \(settings.maxConnections) connections")
                Darwin.close(client)
                continue
            }

            stateLock.lock()
            clientCount += 1
            acceptedCount += 1
            let number = acceptedCount
            stateLock.unlock()

            // The log is sampled: a server that is used by a lot of clients
            // would write a line per connection and fill the log with noise.
            if number <= 10 || number % 50 == 0 {
                log("A client connected (\(number) so far)")
            }

            let thread = Thread { [weak self] in
                self?.handle(client: client)
            }
            thread.stackSize = 512 * 1024
            thread.start()
        }
    }

    private func clientLeft() {
        stateLock.lock()
        clientCount = max(0, clientCount - 1)
        stateLock.unlock()
    }

    // MARK: - one client

    private func handle(client fd: Int32) {
        defer {
            Darwin.close(fd)
            clientLeft()
        }
        // the handshake may take a while: a client that connects and says
        // nothing is given up after half a minute
        LocalProxySocket.setTimeout(fd, 30)

        guard let first = LocalProxySocket.recvExact(fd, 1), let byte = first.first else {
            return
        }
        if byte == 0x05 {
            handleSOCKS5(fd: fd)
        } else {
            handleHTTP(fd: fd, first: byte)
        }
    }

    // MARK: socks5

    private func handleSOCKS5(fd: Int32) {
        // the version byte was read already. what is left is the number of
        // the methods and the methods themselves.
        guard let head = LocalProxySocket.recvExact(fd, 1), head.count == 1 else { return }
        let methodCount = Int(head[0])
        guard methodCount > 0, LocalProxySocket.recvExact(fd, methodCount) != nil else { return }
        // no authentication: the server is for the network around it
        guard LocalProxySocket.sendAll(fd, Data([0x05, 0x00])) else { return }

        // the request has a version of its own: VER CMD RSV ATYP
        guard let request = LocalProxySocket.recvExact(fd, 4), request.count == 4 else { return }
        let command = request[1]
        let addressType = request[3]

        guard let target = readAddress(fd: fd, type: addressType) else {
            _ = LocalProxySocket.sendAll(fd, Data([0x05, 0x08, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
            return
        }

        switch command {
        case 0x01:
            connect(fd: fd, target: target)
        case 0x03:
            udpAssociate(fd: fd)
        default:
            _ = LocalProxySocket.sendAll(fd, Data([0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
        }
    }

    // the address of a socks5 request: an ip, or a name with its length
    private func readAddress(fd: Int32, type: UInt8) -> LocalProxyTarget? {
        switch type {
        case 0x01:
            guard let ip = LocalProxySocket.recvExact(fd, 4), ip.count == 4,
                  let port = LocalProxySocket.recvExact(fd, 2), port.count == 2 else { return nil }
            let host = ip.map { String($0) }.joined(separator: ".")
            return LocalProxyTarget(host: host, port: (Int(port[0]) << 8) | Int(port[1]))
        case 0x03:
            guard let length = LocalProxySocket.recvExact(fd, 1), let count = length.first,
                  let name = LocalProxySocket.recvExact(fd, Int(count)),
                  let port = LocalProxySocket.recvExact(fd, 2), port.count == 2 else { return nil }
            return LocalProxyTarget(host: String(decoding: name, as: UTF8.self),
                                    port: (Int(port[0]) << 8) | Int(port[1]))
        case 0x04:
            guard let ip = LocalProxySocket.recvExact(fd, 16), ip.count == 16,
                  let port = LocalProxySocket.recvExact(fd, 2), port.count == 2 else { return nil }
            return LocalProxyTarget(host: textualIPv6(ip), port: (Int(port[0]) << 8) | Int(port[1]))
        default:
            return nil
        }
    }

    // The answer of the server: the code, and the port it is bound to. The
    // port is the one of the udp relay when the client asked for udp.
    private func reply(fd: Int32, code: UInt8, port: Int = 0) {
        var answer = Data([0x05, code, 0x00, 0x01, 0, 0, 0, 0])
        answer.append(UInt8((port >> 8) & 0xFF))
        answer.append(UInt8(port & 0xFF))
        _ = LocalProxySocket.sendAll(fd, answer)
    }

    // MARK: http

    private func handleHTTP(fd: Int32, first: UInt8) {
        guard let head = LocalProxySocket.recvUntil(fd, Data("\r\n\r\n".utf8)) else { return }
        var text = String(decoding: [first] + head, as: UTF8.self)
        // the head that was read is the request, and it goes on to the far
        // side as it is
        var request = Data([first])
        request.append(head)

        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return }
        let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return }
        let method = parts[0].uppercased()
        let url = parts[1]

        if method == "CONNECT" {
            guard let target = LocalProxyTarget.parse(hostPort: url) else {
                _ = LocalProxySocket.sendAll(fd, Data("HTTP/1.1 400 Bad Request\r\n\r\n".utf8))
                return
            }
            connect(fd: fd, target: target, http: true)
            return
        }

        // a plain request: the url says where it goes
        guard let target = LocalProxyTarget.parse(url: url) else {
            _ = LocalProxySocket.sendAll(fd, Data("HTTP/1.1 400 Bad Request\r\n\r\n".utf8))
            return
        }
        // the choice reads the settings on its own: locking here as well
        // would be a lock inside a lock, and the second one would wait for
        // ever
        let upstream = upstreamChoice(for: target)
        guard let upstreamFD = dial(upstream, target: target) else {
            _ = LocalProxySocket.sendAll(fd, Data("HTTP/1.1 502 Bad Gateway\r\n\r\n".utf8))
            return
        }
        guard LocalProxySocket.sendAll(upstreamFD, request) else {
            Darwin.close(upstreamFD)
            return
        }
        // no answer of its own: the client gets the answer of the far side,
        // which is relayed to it
        relay(client: fd, upstream: upstreamFD)
    }

    // MARK: the way out

    private func connect(fd: Int32, target: LocalProxyTarget, http: Bool = false) {
        // the choice reads the settings on its own: locking here as well
        // would be a lock inside a lock, and the second one would wait for
        // ever
        let upstream = upstreamChoice(for: target)

        switch upstream {
        case .blocked:
            if http {
                _ = LocalProxySocket.sendAll(fd, Data("HTTP/1.1 403 Forbidden\r\n\r\n".utf8))
            } else {
                reply(fd: fd, code: 0x02)
            }
            return
        default:
            break
        }

        guard let upstreamFD = dial(upstream, target: target) else {
            if http {
                _ = LocalProxySocket.sendAll(fd, Data("HTTP/1.1 502 Bad Gateway\r\n\r\n".utf8))
            } else {
                reply(fd: fd, code: 0x05)
            }
            log("The connection to \(target.text) failed", level: "ERROR")
            return
        }
        if http {
            _ = LocalProxySocket.sendAll(fd, Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
        } else {
            reply(fd: fd, code: 0x00)
        }
        relay(client: fd, upstream: upstreamFD)
    }

    // The upstream is decided by the setting: straight out, through one of
    // the proxies of the app, or through the rules of the app.
    private func upstreamChoice(for target: LocalProxyTarget) -> LocalProxyUpstream {
        stateLock.lock()
        let mode = settings.upstream
        let proxies = proxyConfigs
        let allRules = rules
        stateLock.unlock()

        switch mode {
        case .direct:
            return .direct
        case .proxy(let id):
            guard let config = proxies.first(where: { $0.id == id }) else {
                log("The proxy \(id) is not in the list, the traffic goes straight out", level: "WARN")
                return .direct
            }
            return .proxy(config)
        case .rules:
            return LocalProxyRules.upstream(rules: allRules, target: target, proxies: proxies)
        }
    }

    // The connection to the far side: straight out, or through a proxy.
    private func dial(_ upstream: LocalProxyUpstream, target: LocalProxyTarget) -> Int32? {
        switch upstream {
        case .blocked:
            return nil
        case .direct:
            let result = LocalProxySocket.connect(host: target.host, port: target.port, timeout: 15)
            return result.fd
        case .proxy(let endpoint):
            let result = LocalProxySocket.connect(host: endpoint.host, port: endpoint.port, timeout: 15)
            guard let fd = result.fd else { return nil }
            LocalProxySocket.clearTimeout(fd)
            let ok = LocalProxyDialer.handshake(fd: fd, through: endpoint, target: target)
            if !ok {
                Darwin.close(fd)
                return nil
            }
            return fd
        }
    }

    // MARK: the relay

    // The traffic goes both ways until one of the sides stops. The idle
    // time is the limit of the wait: a client that goes away without
    // closing the connection does not stay in the list for ever.
    private func relay(client fd: Int32, upstream upstreamFD: Int32) {
        defer { Darwin.close(upstreamFD) }
        LocalProxySocket.clearTimeout(fd)
        LocalProxySocket.clearTimeout(upstreamFD)

        var lastActivity = Date()
        let idle = Double(settings.idleTimeout)
        var fds = [
            pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
            pollfd(fd: upstreamFD, events: Int16(POLLIN), revents: 0)
        ]

        while isRunning {
            fds[0].revents = 0
            fds[1].revents = 0
            let ready = poll(&fds, 2, 1000)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 {
                if Date().timeIntervalSince(lastActivity) > idle { break }
                continue
            }
            if fds[0].revents & Int16(POLLIN) != 0 {
                guard let data = readSome(fd) else { break }
                guard LocalProxySocket.sendAll(upstreamFD, data) else { break }
                lastActivity = Date()
            } else if fds[0].revents & (Int16(POLLHUP) | Int16(POLLERR)) != 0 {
                break
            }
            if fds[1].revents & Int16(POLLIN) != 0 {
                guard let data = readSome(upstreamFD) else { break }
                guard LocalProxySocket.sendAll(fd, data) else { break }
                lastActivity = Date()
            } else if fds[1].revents & (Int16(POLLHUP) | Int16(POLLERR)) != 0 {
                break
            }
        }
    }

    private func readSome(_ fd: Int32) -> Data? {
        var buffer = [UInt8](repeating: 0, count: 65536)
        let r = recv(fd, &buffer, buffer.count, 0)
        if r > 0 { return Data(buffer[0..<r]) }
        return nil
    }

    // MARK: the udp association

    // A client that wants udp opens an association over tcp and is told the
    // address its datagrams have to go to. The datagrams themselves are
    // carried by the relay.
    private func udpAssociate(fd: Int32) {
        stateLock.lock()
        let udpEnabled = settings.udpEnabled
        stateLock.unlock()
        guard udpEnabled else {
            reply(fd: fd, code: 0x07)
            log("A client asked for udp, but udp is off")
            return
        }
        guard let relay = UDPRelay.start(server: self) else {
            reply(fd: fd, code: 0x07)
            return
        }
        reply(fd: fd, code: 0x00, port: relay.port)
        log("A client opened a udp association on port \(relay.port)")

        // the tcp connection stays open as long as the client wants it
        var buffer = [UInt8](repeating: 0, count: 1)
        while isRunning {
            let r = recv(fd, &buffer, 1, 0)
            if r <= 0 { break }
        }
        relay.close()
    }

    // MARK: what the log says

    var logHandler: ((String, String) -> Void)?

    func log(_ message: String, level: String = "INFO") {
        logHandler?(message, level)
    }

    // MARK: the interface to listen on

    // The name of the interface of this kind, right now. The kind is what
    // is stored ("wifi"), the name is what the socket needs.
    private static let interfacesLock = NSLock()
    private static var interfaceNames: [String: String] = [:]

    static func setInterfaces(_ list: [(kind: String, name: String)]) {
        interfacesLock.lock()
        var store: [String: String] = [:]
        for entry in list where store[entry.kind] == nil {
            store[entry.kind] = entry.name
        }
        interfaceNames = store
        interfacesLock.unlock()
    }

    static func interfaceName(ofKind kind: String) -> String? {
        interfacesLock.lock()
        defer { interfacesLock.unlock() }
        return interfaceNames[kind]
    }
}

// The text of an ipv6 address, out of the sixteen bytes of one.
func textualIPv6(_ bytes: Data) -> String {
    var groups: [String] = []
    for index in stride(from: 0, to: bytes.count, by: 2) {
        let high = Int(bytes[index])
        let low = Int(bytes[index + 1])
        groups.append(String(format: "%x", (high << 8) | low))
    }
    return groups.joined(separator: ":")
}
