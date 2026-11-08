import Foundation
import Darwin
import Network

// The udp half of a socks5 udp association.
//
// A client that wants udp opens an association over tcp, and the server
// answers with the address and the port its datagrams have to go to. From
// then on the datagrams are wrapped in a small header that says where they
// are going, and they come back the same way.
//
// One socket per target: a client that talks to three servers has three of
// them, and each one knows its own way back.
final class UDPRelay {

    private var fd: Int32 = -1
    private var thread: Thread?
    private let stateLock = NSLock()
    private var closed = false
    // one socket per target, by "host:port"
    private var targets: [String: Int32] = [:]
    private var targetInfo: [String: (host: String, port: Int)] = [:]
    // where the datagrams of the client come from
    private var clientAddress = sockaddr_in6()
    private var clientLength = socklen_t(MemoryLayout<sockaddr_in6>.size)
    private var hasClient = false

    private let server: LocalProxyServer

    // the port the datagrams have to go to
    private(set) var port: Int = 0

    private init(server: LocalProxyServer) {
        self.server = server
    }

    static func start(server: LocalProxyServer) -> UDPRelay? {
        let udpSocket = socket(AF_INET6, SOCK_DGRAM, 0)
        guard udpSocket >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(udpSocket, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(udpSocket, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        var no: Int32 = 0
        setsockopt(udpSocket, IPPROTO_IPV6, IPV6_V6ONLY, &no, socklen_t(MemoryLayout<Int32>.size))

        var local = sockaddr_in6()
        local.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        local.sin6_family = sa_family_t(AF_INET6)
        local.sin6_port = 0
        local.sin6_addr = in6addr_any
        let bound = withUnsafePointer(to: &local) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.bind(udpSocket, generic, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard bound == 0 else {
            Darwin.close(udpSocket)
            return nil
        }

        var localAddress = sockaddr_in6()
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        _ = withUnsafeMutablePointer(to: &localAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                getsockname(udpSocket, generic, &length)
            }
        }

        let relay = UDPRelay(server: server)
        relay.fd = udpSocket
        relay.port = Int(UInt16(bigEndian: localAddress.sin6_port))
        relay.thread = Thread { relay.loop() }
        relay.thread?.stackSize = 512 * 1024
        relay.thread?.start()
        return relay
    }

    func close() {
        stateLock.lock()
        if closed {
            stateLock.unlock()
            return
        }
        closed = true
        let sockets = targets
        targets.removeAll()
        stateLock.unlock()
        for target in sockets.values {
            Darwin.close(target)
        }
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    // The loop: the datagrams of the client come in on one socket, and every
    // target has a socket of its own.
    private func loop() {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            stateLock.lock()
            if closed {
                stateLock.unlock()
                return
            }
            let sockets = targets
            stateLock.unlock()

            var fds: [pollfd] = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0)]
            for (_, socket) in sockets.sorted(by: { $0.key < $1.key }) {
                fds.append(pollfd(fd: socket, events: Int16(POLLIN), revents: 0))
            }

            let ready = poll(&fds, nfds_t(fds.count), 1000)
            if ready < 0 {
                if errno == EINTR { continue }
                return
            }
            if ready == 0 { continue }

            if fds[0].revents & Int16(POLLIN) != 0 {
                var from = sockaddr_in6()
                var fromLength = socklen_t(MemoryLayout<sockaddr_in6>.size)
                let n = withUnsafeMutablePointer(to: &from) { pointer -> Int in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                        recvfrom(fd, &buffer, buffer.count, 0, generic, &fromLength)
                    }
                }
                if n > 0 {
                    stateLock.lock()
                    clientAddress = from
                    clientLength = fromLength
                    hasClient = true
                    stateLock.unlock()
                    handle(datagram: Data(buffer[0..<n]))
                }
            }

            // the answers of the targets
            for index in 1..<max(1, fds.count) where fds[index].revents & Int16(POLLIN) != 0 {
                let socket = fds[index].fd
                let n = recv(socket, &buffer, buffer.count, 0)
                if n > 0 {
                    sendBack(payload: Data(buffer[0..<n]), socket: socket)
                }
            }
        }
    }

    // The header of a socks5 udp datagram: RSV RSV FRAG ATYP ADDR PORT DATA
    private func handle(datagram: Data) {
        guard datagram.count >= 5 else { return }
        let addressType = datagram[3]
        var host = ""
        var port = 0
        var offset = 4

        switch addressType {
        case 0x01:
            guard datagram.count >= 4 + 4 + 2 else { return }
            host = datagram[4..<8].map { String($0) }.joined(separator: ".")
            port = (Int(datagram[8]) << 8) | Int(datagram[9])
            offset = 10
        case 0x03:
            guard datagram.count >= 5 else { return }
            let length = Int(datagram[4])
            guard datagram.count >= 5 + length + 2 else { return }
            host = String(decoding: datagram[5..<(5 + length)], as: UTF8.self)
            let portOffset = 5 + length
            port = (Int(datagram[portOffset]) << 8) | Int(datagram[portOffset + 1])
            offset = portOffset + 2
        case 0x04:
            guard datagram.count >= 4 + 16 + 2 else { return }
            host = textualIPv6(datagram.subdata(in: 4..<20))
            port = (Int(datagram[20]) << 8) | Int(datagram[21])
            offset = 22
        default:
            return
        }

        guard datagram.count > offset else { return }
        let payload = datagram.subdata(in: offset..<datagram.count)
        let key = "\(host):\(port)"

        let socket = socketFor(host: host, port: port, key: key)
        guard let socket = socket else { return }
        _ = LocalProxySocket.sendAll(socket, payload)
    }

    // The socket of a target, made when it is needed for the first time.
    private func socketFor(host: String, port: Int, key: String) -> Int32? {
        stateLock.lock()
        if let existing = targets[key] {
            stateLock.unlock()
            return existing
        }
        stateLock.unlock()

        guard let socket = LocalProxySocket.connectUDP(host: host, port: port) else {
            server.log("The datagrams for \(key) have nowhere to go", level: "ERROR")
            return nil
        }
        stateLock.lock()
        if let existing = targets[key] {
            stateLock.unlock()
            Darwin.close(socket)
            return existing
        }
        targets[key] = socket
        targetInfo[key] = (host, port)
        stateLock.unlock()
        return socket
    }

    // The answer goes back to the client, in the same header.
    private func sendBack(payload: Data, socket: Int32) {
        stateLock.lock()
        guard hasClient else {
            stateLock.unlock()
            return
        }
        let client = clientAddress
        let length = clientLength
        var info: (host: String, port: Int)?
        for (key, value) in targetInfo where targets[key] == socket {
            info = value
            break
        }
        stateLock.unlock()
        guard let info = info else { return }

        var datagram = Data([0x00, 0x00, 0x00])
        if let ipv4 = IPv4Address(info.host) {
            datagram.append(0x01)
            datagram.append(contentsOf: ipv4.rawValue)
        } else {
            datagram.append(0x03)
            let name = Array(info.host.utf8)
            datagram.append(UInt8(name.count))
            datagram.append(contentsOf: name)
        }
        datagram.append(UInt8((info.port >> 8) & 0xFF))
        datagram.append(UInt8(info.port & 0xFF))
        datagram.append(payload)

        var to = client
        _ = withUnsafePointer(to: &to) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                datagram.withUnsafeBytes { raw in
                    sendto(fd, raw.baseAddress, raw.count, 0, generic, length)
                }
            }
        }
    }
}
