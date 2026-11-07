import Foundation
import Darwin
import Network

// The sockets the app uses to talk to a proxy server.
//
// The app talks to the proxies itself when the user asks it to test one. The
// helpers live here so that the test of a proxy and the test of a chain speak
// the same language, and so that the protocol details stay in one place.
//
// The traffic of the app itself is never proxied, so a test reaches the proxy
// directly and says something about the proxy alone.
enum ProxySocket {

    // MARK: - the plain connection

    // Connects to host:port (v4/v6/hostname). Returns the socket and the time
    // the connect took, in milliseconds.
    static func open(host: String, port: Int, timeout: Int = 5) -> (Int32, Double)? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM

        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0 else { return nil }
        defer { freeaddrinfo(result) }

        let start = Date()
        var candidate = result
        while let addr = candidate {
            let fd = socket(addr.pointee.ai_family, addr.pointee.ai_socktype, addr.pointee.ai_protocol)
            if fd >= 0 {
                var tv = timeval(tv_sec: timeout, tv_usec: 0)
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                if connect(fd, addr.pointee.ai_addr, addr.pointee.ai_addrlen) == 0 {
                    return (fd, Date().timeIntervalSince(start) * 1000)
                }
                Darwin.close(fd)
            }
            candidate = addr.pointee.ai_next
        }
        return nil
    }

    static func sendAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty else { return true }
        return bytes.withUnsafeBytes { raw -> Bool in
            var sent = 0
            let base = raw.baseAddress!
            while sent < bytes.count {
                let n = send(fd, base + sent, bytes.count - sent, 0)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }

    static func recvBytes(_ fd: Int32, _ maxLen: Int) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: maxLen)
        let n = Darwin.recv(fd, &buf, maxLen, 0)
        return n > 0 ? Array(buf[0..<n]) : []
    }

    // Reads exactly n bytes, nil on a timeout or a closed socket.
    static func recvExact(_ fd: Int32, _ n: Int) -> [UInt8]? {
        var out = [UInt8]()
        while out.count < n {
            var buf = [UInt8](repeating: 0, count: n - out.count)
            let r = Darwin.recv(fd, &buf, n - out.count, 0)
            if r <= 0 { return nil }
            out.append(contentsOf: buf)
        }
        return out
    }

    // MARK: - SOCKS5

    // The greeting and, when the server asks for it, the authentication.
    static func socks5Handshake(_ fd: Int32, username: String?, password: String?) -> Bool {
        let hasAuth = (username != nil && password != nil)
        let greeting: [UInt8] = hasAuth ? [0x05, 0x02, 0x00, 0x02] : [0x05, 0x01, 0x00]
        guard sendAll(fd, greeting), let resp = recvExact(fd, 2), resp[0] == 0x05 else { return false }

        if resp[1] == 0x00 { return true }
        if resp[1] == 0x02 {
            let user = Array((username ?? "").utf8)
            let pass = Array((password ?? "").utf8)
            guard user.count <= 255, pass.count <= 255 else { return false }
            var req: [UInt8] = [0x01, UInt8(user.count)]
            req += user
            req.append(UInt8(pass.count))
            req += pass
            guard sendAll(fd, req), let ar = recvExact(fd, 2), ar[1] == 0x00 else { return false }
            return true
        }
        return false
    }

    // MARK: - SOCKS4

    // SOCKS4 and SOCKS4a: there is no method negotiation, only a user id in
    // the request, and the name of the host follows the user id for socks4a.
    static func socks4Connect(_ fd: Int32, host: String, port: Int, username: String?) -> (Bool, String) {
        var request: [UInt8] = [0x04, 0x01, UInt8(port >> 8), UInt8(port & 0xFF)]
        var isName = false
        if let ip = IPv4Address(host) {
            request.append(contentsOf: ip.rawValue)
        } else {
            // the address says "a name follows"
            request.append(contentsOf: [0, 0, 0, 1])
            isName = true
        }
        let user = Array((username ?? "").utf8)
        guard user.count <= 255 else { return (false, "the user id is too long") }
        request.append(contentsOf: user)
        request.append(0)
        if isName {
            let name = Array(host.utf8)
            guard !name.isEmpty, name.count <= 255 else { return (false, "the host name cannot be sent") }
            request.append(contentsOf: name)
            request.append(0)
        }
        guard sendAll(fd, request) else { return (false, "the request could not be sent") }
        guard let reply = recvExact(fd, 8), reply.count == 8 else { return (false, "the reply was too short") }
        if reply[1] == 90 { return (true, "granted") }
        if reply[1] == 91 { return (false, "rejected") }
        return (false, "unknown reply code \(reply[1])")
    }

    // MARK: - HTTP CONNECT

    static func httpConnect(_ fd: Int32, host: String, port: Int, username: String?, password: String?) -> (Bool, String) {
        let target = host.contains(":") ? "[\(host)]" : host
        var req = "CONNECT \(target):\(port) HTTP/1.1\r\nHost: \(target):\(port)\r\n"
        if let u = username, let p = password {
            let cred = Data("\(u):\(p)".utf8).base64EncodedString()
            req += "Proxy-Authorization: Basic \(cred)\r\n"
        }
        req += "\r\n"
        guard sendAll(fd, Array(req.utf8)) else { return (false, "write failed") }
        let response = String(bytes: recvBytes(fd, 1024), encoding: .utf8) ?? ""
        let firstLine = response.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).first.map(String.init) ?? "no response"
        return (response.contains(" 200"), firstLine)
    }

    // MARK: - the answers

    static func hex(_ b: UInt8) -> String { String(format: "%02x", b) }

    // What a SOCKS5 reply code says.
    static func socksReason(_ rep: UInt8) -> String {
        switch rep {
        case 0x01: return "general failure"
        case 0x02: return "not allowed by ruleset"
        case 0x03: return "network unreachable"
        case 0x04: return "host unreachable"
        case 0x05: return "connection refused"
        case 0x06: return "TTL expired"
        case 0x07: return "command not supported"
        case 0x08: return "address type not supported"
        default: return "unknown"
        }
    }
}
