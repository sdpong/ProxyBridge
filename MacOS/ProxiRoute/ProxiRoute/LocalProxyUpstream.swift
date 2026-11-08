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
        return socks5Request(fd: fd, target: target)
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

        guard let head = LocalProxySocket.recvExact(fd, 4), head.count == 4 else { return false }
        if head[1] != 0x00 { return false }
        let addressLength: Int
        switch head[3] {
        case 0x01: addressLength = 4
        case 0x04: addressLength = 16
        case 0x03:
            guard let length = LocalProxySocket.recvExact(fd, 1), let count = length.first else { return false }
            return LocalProxySocket.recvExact(fd, Int(count) + 2) != nil
        default:
            return false
        }
        return LocalProxySocket.recvExact(fd, addressLength + 2) != nil
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
