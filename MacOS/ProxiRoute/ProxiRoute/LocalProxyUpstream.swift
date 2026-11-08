import Foundation
import Darwin
import Network

// Where a client wants to go.
struct LocalProxyTarget: Equatable {
    let host: String
    let port: Int

    var text: String { "\(host):\(port)" }

    // "host:port", as an http CONNECT line says it
    static func parse(hostPort: String) -> LocalProxyTarget? {
        let text = hostPort.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        // an ipv6 address is written in brackets
        if text.hasPrefix("[") {
            guard let end = text.firstIndex(of: "]") else { return nil }
            let host = String(text[text.index(after: text.startIndex)..<end])
            let rest = text[text.index(after: end)...]
            let port = rest.hasPrefix(":") ? Int(rest.dropFirst()) : nil
            guard let port = port, port > 0, port < 65536 else { return nil }
            return LocalProxyTarget(host: host, port: port)
        }
        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let port = Int(parts[1]), port > 0, port < 65536 else { return nil }
        return LocalProxyTarget(host: String(parts[0]), port: port)
    }

    // an absolute url, as an http proxy receives it
    static func parse(url: String) -> LocalProxyTarget? {
        var rest = url
        var scheme = "http"
        if let range = rest.range(of: "://") {
            scheme = String(rest[rest.startIndex..<range.lowerBound]).lowercased()
            rest = String(rest[range.upperBound...])
        }
        // the part before the slash is the host
        let authority: String
        if let slash = rest.firstIndex(of: "/") {
            authority = String(rest[rest.startIndex..<slash])
        } else {
            authority = rest
        }
        // an url may leave the port out: then the scheme says which one it is
        if let target = parse(hostPort: authority) {
            return target
        }
        let host = authority.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard !host.isEmpty else { return nil }
        let port = scheme == "https" ? 443 : 80
        return LocalProxyTarget(host: host, port: port)
    }
}

// One proxy of the app, as the server needs it.
struct LocalProxyEndpoint: Equatable {
    let id: String
    let name: String
    let type: String
    let host: String
    let port: Int
    let username: String?
    let password: String?

    var label: String { "\(type.uppercased()) \(host):\(port)" }
}

// One rule of the app, as the server needs it.
struct LocalProxyRule {
    let action: String
    let targetHosts: [String]
    let targetPorts: [String]
    let hasProgram: Bool
    let enabled: Bool
    let protocolMode: String

    // A client on the network has no program, so a rule that names one
    // cannot be about it.
    func matches(_ target: LocalProxyTarget) -> Bool {
        guard enabled else { return false }
        if !targetHosts.isEmpty && !targetHosts.contains(where: { LocalProxyRule.host($0, matches: target.host) }) {
            return false
        }
        if !targetPorts.isEmpty && !targetPorts.contains(where: { LocalProxyRule.port($0, matches: target.port) }) {
            return false
        }
        return true
    }

    // a host pattern: "*.example.com", "example.com", "1.2.3.*"
    static func host(_ pattern: String, matches host: String) -> Bool {
        let pattern = pattern.trimmingCharacters(in: .whitespaces).lowercased()
        let host = host.lowercased()
        if pattern.isEmpty { return false }
        if !pattern.contains("*") { return pattern == host }
        // the pieces between the stars have to be there, in that order
        var rest = host
        var pieces = pattern.split(separator: "*", omittingEmptySubsequences: true).map(String.init)
        // a pattern that starts with a star may match anything before the
        // first piece
        if pattern.hasPrefix("*"), let first = pieces.first {
            guard let range = rest.range(of: first) else { return false }
            rest = String(rest[range.upperBound...])
            pieces.removeFirst()
        }
        for piece in pieces {
            guard let range = rest.range(of: piece) else { return false }
            rest = String(rest[range.upperBound...])
        }
        return true
    }

    // a port pattern: "80", "8000-9000", "*"
    static func port(_ pattern: String, matches port: Int) -> Bool {
        let pattern = pattern.trimmingCharacters(in: .whitespaces)
        if pattern.isEmpty || pattern == "*" { return true }
        if let dash = pattern.firstIndex(of: "-") {
            let low = Int(pattern[pattern.startIndex..<dash]) ?? -1
            let high = Int(pattern[pattern.index(after: dash)...]) ?? -1
            return port >= low && port <= high
        }
        return Int(pattern) == port
    }
}

// Where the traffic of a client goes.
enum LocalProxyUpstream: Equatable {
    case direct
    case proxy(LocalProxyEndpoint)
    case blocked
}

// MARK: - the handshake with the proxy

// The proxy handshake, on top of the socket that reaches it.
//
// The socket is already open when the handshake starts: the dialer made it,
// and the answer of the proxy says whether the target may be reached.
enum LocalProxyDialer {

    static func handshake(fd: Int32, through endpoint: LocalProxyEndpoint, target: LocalProxyTarget) -> Bool {
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

    private static func socks5(fd: Int32, endpoint: LocalProxyEndpoint, target: LocalProxyTarget) -> Bool {
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

    private static func socks5Auth(fd: Int32, endpoint: LocalProxyEndpoint) -> Bool {
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

    private static func socks5Request(fd: Int32, target: LocalProxyTarget) -> Bool {
        var request = Data([0x05, 0x01, 0x00])
        if let ipv4 = IPv4Address(target.host) {
            request.append(0x01)
            request.append(contentsOf: ipv4.rawValue)
        } else {
            request.append(0x03)
            let name = Array(target.host.utf8)
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

    private static func socks4(fd: Int32, endpoint: LocalProxyEndpoint, target: LocalProxyTarget) -> Bool {
        var request = Data([0x04, 0x01])
        request.append(UInt8((target.port >> 8) & 0xFF))
        request.append(UInt8(target.port & 0xFF))
        let isAddress = IPv4Address(target.host) != nil
        if let ipv4 = IPv4Address(target.host) {
            request.append(contentsOf: ipv4.rawValue)
        } else {
            request.append(contentsOf: [0, 0, 0, 1])
        }
        let user = Array((endpoint.username ?? "").utf8)
        guard user.count <= 255 else { return false }
        request.append(contentsOf: user)
        request.append(0)
        if !isAddress {
            let name = Array(target.host.utf8)
            guard name.count <= 255 else { return false }
            request.append(contentsOf: name)
            request.append(0)
        }
        guard LocalProxySocket.sendAll(fd, request) else { return false }
        guard let answer = LocalProxySocket.recvExact(fd, 8), answer.count == 8 else { return false }
        return answer[1] == 90
    }

    private static func httpConnect(fd: Int32, endpoint: LocalProxyEndpoint, target: LocalProxyTarget) -> Bool {
        let host = target.host.contains(":") ? "[\(target.host)]" : target.host
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

// MARK: - the rules of the app

// The upstream that follows the rules.
//
// A client on the network has no program, so a rule that names one is not
// about it and is skipped. The rules that name a host or a port are.
enum LocalProxyRules {

    static func upstream(rules: [LocalProxyRule], target: LocalProxyTarget, proxies: [LocalProxyEndpoint]) -> LocalProxyUpstream {
        for rule in rules {
            guard rule.enabled else { continue }
            if rule.hasProgram { continue }
            guard rule.matches(target) else { continue }
            switch rule.action {
            case "DIRECT":
                return .direct
            case "BLOCK":
                return .blocked
            default:
                if let endpoint = proxies.first(where: { $0.id == rule.action }) {
                    return .proxy(endpoint)
                }
                return .direct
            }
        }
        return .direct
    }
}
