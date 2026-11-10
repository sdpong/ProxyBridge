import Foundation
import Darwin
import Network

// The handshake with the proxy.
//
// The rules that say where the traffic goes are in ProxyRuleEngine.swift:
// the model of a rule, of a flow and of a proxy lives there, so that the
// helper of the gateway mode reads them the same way.

// MARK: - the handshake with the proxy

// The proxy handshake, on top of the socket that reaches it.
//
// The socket is already open when the handshake starts: the dialer made it,
// and the answer of the proxy says whether the target may be reached.
enum LocalProxyDialer {

    static func handshake(fd: Int32, through endpoint: ProxyEndpoint, target: FlowTarget) -> Bool {
        switch endpoint.type.lowercased() {
        case "socks5":
            return socks5(fd: fd, endpoint: endpoint, target: target)
        case "socks4":
            return socks4(fd: fd, endpoint: endpoint, target: target)
        case "http", "https":
            return httpConnect(fd: fd, endpoint: endpoint, target: target)
        default:
            return false
        }
    }

    private static func socks5(fd: Int32, endpoint: ProxyEndpoint, target: FlowTarget) -> Bool {
        guard socks5Greeting(fd: fd, endpoint: endpoint) else { return false }
        return socks5Request(fd: fd, target: target)
    }

    // The greeting of a socks5 proxy.
    //
    // The proxy says which ways of saying who it is it takes, and the way of
    // the user name and the password is taken when it asks for it. The
    // greeting of an association of udp is the same as the greeting of a
    // connection.
    static func socks5Greeting(fd: Int32, endpoint: ProxyEndpoint) -> Bool {
        let hasAuth = endpoint.username != nil && endpoint.password != nil
        var greeting = Data([0x05, hasAuth ? 0x02 : 0x01])
        greeting.append(hasAuth ? 0x02 : 0x00)
        guard LocalProxySocket.sendAll(fd, greeting) else { return false }
        guard let answer = LocalProxySocket.recvExact(fd, 2), answer.count == 2, answer[0] == 0x05 else {
            return false
        }
        if answer[1] == 0x02 {
            guard socks5Auth(fd: fd, endpoint: endpoint) else { return false }
        } else if answer[1] != 0x00 {
            return false
        }
        return true
    }

    private static func socks5Auth(fd: Int32, endpoint: ProxyEndpoint) -> Bool {
        let user = Array((endpoint.username ?? "").utf8)
        let pass = Array((endpoint.password ?? "").utf8)
        guard user.count <= 255, pass.count <= 255 else { return false }
        var request = Data([0x01, UInt8(user.count)])
        request.append(contentsOf: user)
        request.append(UInt8(pass.count))
        request.append(contentsOf: pass)
        guard LocalProxySocket.sendAll(fd, request) else { return false }
        guard let answer = LocalProxySocket.recvExact(fd, 2), answer.count == 2 else { return false }
        return answer[1] == 0x00
    }

    private static func socks5Request(fd: Int32, target: FlowTarget) -> Bool {
        var request = Data([0x05, 0x01, 0x00])
        if let ipv4 = IPv4Address(target.proxyHost) {
            request.append(0x01)
            request.append(contentsOf: ipv4.rawValue)
        } else {
            request.append(0x03)
            let name = Array(target.proxyHost.utf8)
            guard name.count <= 255 else { return false }
            request.append(UInt8(name.count))
            request.append(contentsOf: name)
        }
        request.append(UInt8((target.port >> 8) & 0xFF))
        request.append(UInt8(target.port & 0xFF))
        guard LocalProxySocket.sendAll(fd, request) else { return false }
        return socks5Reply(fd: fd) != nil
    }

    // The answer of a socks5 proxy: the address it says.
    //
    // The address may be a number, a name or a number of the sixth version,
    // and how long it is is only known after the kind of it has been read.
    // The answer of a proxy that says it did not work says nothing else: the
    // reason of the refusal is in the second byte, and the caller says it in
    // its own words.
    static func socks5Reply(fd: Int32) -> (host: String, port: Int)? {
        guard let head = LocalProxySocket.recvExact(fd, 4), head.count == 4 else { return nil }
        guard head[1] == 0x00 else { return nil }
        switch head[3] {
        case 0x01:
            guard let body = LocalProxySocket.recvExact(fd, 6), body.count == 6 else { return nil }
            return (addressText(Array(body[0..<4])), portText(Array(body[4..<6])))
        case 0x04:
            guard let body = LocalProxySocket.recvExact(fd, 18), body.count == 18 else { return nil }
            return (addressText(Array(body[0..<16])), portText(Array(body[16..<18])))
        case 0x03:
            guard let length = LocalProxySocket.recvExact(fd, 1), let count = length.first else { return nil }
            guard let body = LocalProxySocket.recvExact(fd, Int(count) + 2),
                  body.count == Int(count) + 2 else { return nil }
            return (String(decoding: body[0..<(body.count - 2)], as: UTF8.self),
                    portText(Array(body[(body.count - 2)...])))
        default:
            return nil
        }
    }

    // The text of an address of the answer of a socks5 proxy.
    private static func addressText(_ bytes: [UInt8]) -> String {
        if bytes.count == 4 {
            return bytes.map { String($0) }.joined(separator: ".")
        }
        if bytes.count == 16 {
            let groups = stride(from: 0, to: 16, by: 2).map { index -> String in
                let value = (UInt16(bytes[index]) << 8) | UInt16(bytes[index + 1])
                return String(value, radix: 16)
            }
            return groups.joined(separator: ":")
        }
        return ""
    }

    // The number of a port of the answer of a socks5 proxy.
    private static func portText(_ bytes: [UInt8]) -> Int {
        guard bytes.count >= 2 else { return 0 }
        return (Int(bytes[0]) << 8) | Int(bytes[1])
    }

    // MARK: - the association of udp

    // The association of udp of a socks5 proxy.
    //
    // A socks5 proxy carries udp in an association: one tcp control connection
    // that asks for it, and one udp socket that the datagrams go through. The
    // address of the real destination travels in the header of every
    // datagram, so one association can carry the datagrams of many
    // destinations.
    //
    // The control connection has to stay open: a proxy that sees it closed
    // takes the association away.
    struct UDPAssociation {
        // the socket the datagrams go out of
        let socket: Int32
        // the connection that holds the association open
        let control: Int32
        // where the datagrams have to go
        let host: String
        let port: Int
    }

    // The association of udp of a socks5 proxy.
    //
    // The proxy says where its relay is, and the datagrams go there. The
    // request carries no address of its own: the proxy does not need one,
    // and the address the datagrams come from is the one it remembers.
    static func udpAssociate(endpoint: ProxyEndpoint) -> UDPAssociation? {
        guard endpoint.type.lowercased() == "socks5" else { return nil }

        let result = LocalProxySocket.connect(host: endpoint.host, port: endpoint.port, timeout: 15)
        guard let control = result.fd else { return nil }
        LocalProxySocket.clearTimeout(control)

        guard socks5Greeting(fd: control, endpoint: endpoint) else {
            Darwin.close(control)
            return nil
        }

        let request = Data([0x05, 0x03, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
        guard LocalProxySocket.sendAll(control, request) else {
            Darwin.close(control)
            return nil
        }

        guard let relay = socks5Reply(fd: control), relay.port != 0 else {
            Darwin.close(control)
            return nil
        }
        // many proxies answer with the address that means "the place you
        // reached me at", and the relay is there
        let host = (relay.host == "0.0.0.0" || relay.host == "::" || relay.host.isEmpty)
            ? endpoint.host
            : relay.host

        // the socket of the datagrams
        guard let socket = LocalProxySocket.bindUDP() else {
            Darwin.close(control)
            return nil
        }

        return UDPAssociation(socket: socket, control: control, host: host, port: relay.port)
    }

    // The header of a socks5 datagram: RSV RSV FRAG ATYP ADDR PORT DATA
    //
    // The address of the real destination is in it, and the header is what
    // says which destination a datagram is for.
    static func udpHeader(host: String, port: Int) -> Data {
        var header = Data([0x00, 0x00, 0x00])
        if let ipv4 = IPv4Address(host) {
            header.append(0x01)
            header.append(contentsOf: ipv4.rawValue)
        } else if let ipv6 = IPv6Address(host) {
            header.append(0x04)
            header.append(contentsOf: ipv6.rawValue)
        } else {
            let name = Array(host.utf8)
            header.append(0x03)
            header.append(UInt8(name.count))
            header.append(contentsOf: name)
        }
        header.append(UInt8((port >> 8) & 0xFF))
        header.append(UInt8(port & 0xFF))
        return header
    }

    // A datagram of a socks5 proxy without its header.
    //
    // The answer of the proxy carries the address the datagram came from, and
    // the part that is behind the header is the datagram itself.
    static func stripUDPHeader(_ datagram: Data) -> Data? {
        guard datagram.count >= 4 else { return nil }
        switch datagram[3] {
        case 0x01:
            guard datagram.count >= 10 else { return nil }
            return datagram.subdata(in: 10..<datagram.count)
        case 0x04:
            guard datagram.count >= 22 else { return nil }
            return datagram.subdata(in: 22..<datagram.count)
        case 0x03:
            guard datagram.count >= 5 else { return nil }
            let offset = 5 + Int(datagram[4]) + 2
            guard datagram.count >= offset else { return nil }
            return datagram.subdata(in: offset..<datagram.count)
        default:
            return nil
        }
    }

    private static func socks4(fd: Int32, endpoint: ProxyEndpoint, target: FlowTarget) -> Bool {
        var request = Data([0x04, 0x01])
        request.append(UInt8((target.port >> 8) & 0xFF))
        request.append(UInt8(target.port & 0xFF))
        let isAddress = IPv4Address(target.proxyHost) != nil
        if let ipv4 = IPv4Address(target.proxyHost) {
            request.append(contentsOf: ipv4.rawValue)
        } else {
            request.append(contentsOf: [0, 0, 0, 1])
        }
        let user = Array((endpoint.username ?? "").utf8)
        guard user.count <= 255 else { return false }
        request.append(contentsOf: user)
        request.append(0)
        if !isAddress {
            let name = Array(target.proxyHost.utf8)
            guard name.count <= 255 else { return false }
            request.append(contentsOf: name)
            request.append(0)
        }
        guard LocalProxySocket.sendAll(fd, request) else { return false }
        guard let answer = LocalProxySocket.recvExact(fd, 8), answer.count == 8 else { return false }
        return answer[1] == 90
    }

    private static func httpConnect(fd: Int32, endpoint: ProxyEndpoint, target: FlowTarget) -> Bool {
        let host = target.proxyHost.contains(":") ? "[\(target.proxyHost)]" : target.proxyHost
        var request = "CONNECT \(host):\(target.port) HTTP/1.1\r\nHost: \(host):\(target.port)\r\n"
        if let user = endpoint.username, let password = endpoint.password {
            let credentials = Data("\(user):\(password)".utf8).base64EncodedString()
            request += "Proxy-Authorization: Basic \(credentials)\r\n"
        }
        request += "\r\n"
        guard LocalProxySocket.sendAll(fd, Data(request.utf8)) else { return false }
        guard let head = LocalProxySocket.recvUntil(fd, Data("\r\n\r\n".utf8)) else { return false }
        return String(decoding: head, as: UTF8.self).contains(" 200")
    }
}
