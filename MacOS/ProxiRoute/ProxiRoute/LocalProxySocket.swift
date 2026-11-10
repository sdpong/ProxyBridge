import Foundation
import Darwin
import Network

// The sockets of the proxy server.
//
// The server binds a socket of its own, because it has to be able to listen
// on one address and on one network card. The Network framework cannot bind
// a listener to an address - it answers "invalid argument" - and "only on
// the wired connection" is exactly what the user asks for when a Mac is
// plugged in and also on a wireless network.
//
// The sockets are blocking, and the relay waits on both of them with poll():
// one thread per connection, and no thread at all when nothing happens.
enum LocalProxySocket {

    // A socket that waits for something and gives up after the time.
    static func makeStream(timeout: TimeInterval) -> Int32? {
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        // a connection to a v4 address is served as well
        var no: Int32 = 0
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &no, socklen_t(MemoryLayout<Int32>.size))
        setTimeout(fd, timeout)
        return fd
    }

    static func setTimeout(_ fd: Int32, _ timeout: TimeInterval) {
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    static func clearTimeout(_ fd: Int32) {
        var tv = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    // The socket that listens.
    //
    // The address may be empty (every address), a v4 address or a v6 one.
    // The network card, when one is named, is bound with IP_BOUND_IF: the
    // socket is then only reachable through it.
    static func listen(address: String, port: Int, interfaceName: String?) -> (fd: Int32?, reason: String?) {
        // A v4 address gets a v4 socket: a v6 socket cannot be bound to the
        // mapped form of a v4 address ("::ffff:127.0.0.1"), it says that the
        // address cannot be assigned.
        let isV4 = !address.isEmpty && IPv4Address(address) != nil
        let family = isV4 ? AF_INET : AF_INET6

        let fd = socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else { return (nil, "The socket could not be made.") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        if family == AF_INET6 {
            // a connection to a v4 address is served as well
            var no: Int32 = 0
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &no, socklen_t(MemoryLayout<Int32>.size))
        }

        if let name = interfaceName, !name.isEmpty {
            let index = if_nametoindex(name)
            if index == 0 {
                Darwin.close(fd)
                return (nil, "The interface \(name) is not there.")
            }
            var value = index
            let option = family == AF_INET ? IP_BOUND_IF : IPV6_BOUND_IF
            let level = family == AF_INET ? IPPROTO_IP : IPPROTO_IPV6
            if setsockopt(fd, level, option, &value, socklen_t(MemoryLayout<UInt32>.size)) != 0 {
                Darwin.close(fd)
                return (nil, "The interface \(name) could not be bound.")
            }
        }

        var bound: Int32
        if isV4 {
            var local = sockaddr_in()
            local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            local.sin_family = sa_family_t(AF_INET)
            local.sin_port = in_port_t(UInt16(clamping: port)).bigEndian
            local.sin_addr = in_addr(s_addr: inet_addr(address))
            bound = withUnsafePointer(to: &local) { pointer -> Int32 in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                    Darwin.bind(fd, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        } else {
            var local = sockaddr_in6()
            // macOS wants the length of the address in the address itself
            local.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            local.sin6_family = sa_family_t(AF_INET6)
            local.sin6_port = in_port_t(UInt16(clamping: port)).bigEndian
            local.sin6_addr = in6addr_any
            if !address.isEmpty {
                guard let parsed = IPv6Address(address) else {
                    Darwin.close(fd)
                    return (nil, "\(address) is not an address of this machine.")
                }
                // the bytes of the address, not the shape of the value that
                // holds them
                parsed.rawValue.withUnsafeBytes { raw in
                    withUnsafeMutableBytes(of: &local.sin6_addr) { destination in
                        raw.copyBytes(to: destination)
                    }
                }
            }
            bound = withUnsafePointer(to: &local) { pointer -> Int32 in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                    Darwin.bind(fd, generic, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        }
        if bound != 0 {
            let code = errno
            Darwin.close(fd)
            if code == EADDRINUSE {
                return (nil, "in use")
            }
            return (nil, String(cString: strerror(code)))
        }

        if Darwin.listen(fd, 128) != 0 {
            let code = errno
            Darwin.close(fd)
            return (nil, String(cString: strerror(code)))
        }
        return (fd, nil)
    }

    // The socket that reaches a host.
    static func connect(host: String, port: Int, timeout: TimeInterval) -> (fd: Int32?, reason: String?) {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_flags = AI_NUMERICSERV

        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0 else {
            return (nil, "\(host) could not be looked up.")
        }
        defer { freeaddrinfo(result) }
        let first = result!

        var candidate: UnsafeMutablePointer<addrinfo>? = first
        while let addr = candidate {
            let fd = socket(addr.pointee.ai_family, addr.pointee.ai_socktype, addr.pointee.ai_protocol)
            if fd >= 0 {
                var yes: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
                setTimeout(fd, timeout)
                // The socket is not blocking while it connects: a connect to
                // an address that does not answer waits for a minute and a
                // half, and the person who asked for a connection should not
                // wait that long.
                var flags = fcntl(fd, F_GETFL, 0)
                _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
                // the address of the socket is a pointer: the sockaddr itself
                // is what is passed on
                let connected = addr.pointee.ai_addr.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                    Darwin.connect(fd, generic, addr.pointee.ai_addrlen)
                }
                if connected != 0, errno == EINPROGRESS {
                    var list = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    let ready = poll(&list, 1, Int32(timeout * 1000))
                    var failure: Int32 = 0
                    var length = socklen_t(MemoryLayout<Int32>.size)
                    _ = getsockopt(fd, SOL_SOCKET, SO_ERROR, &failure, &length)
                    if ready > 0, failure == 0 {
                        _ = fcntl(fd, F_SETFL, flags)
                        return (fd, nil)
                    }
                    Darwin.close(fd)
                    candidate = addr.pointee.ai_next
                    continue
                }
                if connected == 0 {
                    _ = fcntl(fd, F_SETFL, flags)
                    return (fd, nil)
                }
                let code = errno
                Darwin.close(fd)
                if candidate == first {
                    let reason = String(cString: strerror(code))
                    candidate = addr.pointee.ai_next
                    continue
                }
            }
            candidate = addr.pointee.ai_next
        }
        return (nil, "The connection to \(host):\(port) failed.")
    }

    // The socket that takes datagrams in.
    //
    // The address may be a v4 address, and the port is the port the
    // datagrams come in on. The socket is bound to the address and not to
    // every address of the machine: the datagrams of the network are
    // redirected to one address, and the answer of the filter has to come
    // from that same address, or the kernel does not recognise it.
    static func listenUDP(address: String, port: Int) -> (fd: Int32?, reason: String?) {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return (nil, "The socket could not be made.") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))

        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = in_port_t(UInt16(clamping: port)).bigEndian
        local.sin_addr = in_addr(s_addr: inet_addr(address))
        let bound = withUnsafePointer(to: &local) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.bind(fd, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bound != 0 {
            let code = errno
            Darwin.close(fd)
            if code == EADDRINUSE {
                return (nil, "in use")
            }
            return (nil, String(cString: strerror(code)))
        }
        return (fd, nil)
    }

    // The socket that carries the datagrams of a socks5 association.
    //
    // It is bound to every address of the machine and not to the loopback:
    // the proxy has to be able to reach it, and the proxy is not on this
    // machine. The address the datagrams go out with is chosen by the way
    // they are routed.
    static func bindUDP() -> Int32? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    // The socket that reaches a host with udp. The socket is connected, so
    // that only the datagrams of that host come in.
    static func connectUDP(host: String, port: Int) -> Int32? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_flags = AI_NUMERICSERV

        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0 else {
            return nil
        }
        defer { freeaddrinfo(result) }
        let first = result!

        var candidate: UnsafeMutablePointer<addrinfo>? = first
        while let addr = candidate {
            let fd = socket(addr.pointee.ai_family, addr.pointee.ai_socktype, addr.pointee.ai_protocol)
            if fd >= 0 {
                var yes: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
                // the address of the socket is a pointer: the sockaddr itself
                // is what is passed on
                let connected = addr.pointee.ai_addr.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                    Darwin.connect(fd, generic, addr.pointee.ai_addrlen)
                }
                if connected == 0 {
                    return fd
                }
                Darwin.close(fd)
            }
            candidate = addr.pointee.ai_next
        }
        return nil
    }

    // Writes everything, or says that it could not.
    static func sendAll(_ fd: Int32, _ data: Data) -> Bool {
        guard !data.isEmpty else { return true }
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            var sent = 0
            while sent < raw.count {
                let n = Darwin.send(fd, base.advanced(by: sent), raw.count - sent, 0)
                if n <= 0 {
                    if errno == EINTR { continue }
                    return false
                }
                sent += n
            }
            return true
        }
    }

    // Reads exactly n bytes, or nothing when the other side goes away.
    static func recvExact(_ fd: Int32, _ n: Int) -> Data? {
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: n)
        while out.count < n {
            let r = Darwin.recv(fd, &buffer, n - out.count, 0)
            if r > 0 {
                out.append(contentsOf: buffer[0..<r])
            } else if r == 0 {
                return nil
            } else {
                if errno == EINTR { continue }
                return nil
            }
        }
        return out
    }

    // Reads up to the marker, the marker included.
    static func recvUntil(_ fd: Int32, _ marker: Data, limit: Int = 65536) -> Data? {
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while out.count < limit {
            let r = Darwin.recv(fd, &buffer, buffer.count, 0)
            if r > 0 {
                out.append(contentsOf: buffer[0..<r])
                if let range = out.range(of: marker) {
                    return out.subdata(in: out.startIndex..<range.upperBound)
                }
            } else if r == 0 {
                return out.isEmpty ? nil : out
            } else {
                if errno == EINTR { continue }
                return out.isEmpty ? nil : out
            }
        }
        return nil
    }
}
