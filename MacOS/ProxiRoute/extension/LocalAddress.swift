import Foundation

// The addresses that belong to this machine or to the network it is in.
//
// A client that hands the traffic of the local network to a proxy on the
// internet is doing something nobody asked for: the answer has to come back
// through the proxy, and a server that is not there does not answer at all.
// The nameserver of the local router is the case that bites: every program
// that asks it waits for an answer that never comes, asks again, and the
// machine ends up busy with traffic that goes nowhere.
//
// The rules still decide. This is what the global mode falls back to when no
// rule names the traffic, and the user can turn it off.
//
// The addresses are read by hand and not with Network.framework, so this file
// can be tested without a network around it.
enum LocalAddress {

    // Whether the host is on this machine or in the network it is in.
    static func isLocal(_ host: String) -> Bool {
        let lower = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.isEmpty { return false }
        // the name of this machine
        if lower == "localhost" || lower.hasSuffix(".localhost") { return true }
        // the names of the local network, the way mDNS and the like use them
        if lower.hasSuffix(".local") { return true }
        if let bytes = ipv4Bytes(lower) { return isLocalIPv4(bytes) }
        if let bytes = ipv6Bytes(lower) { return isLocalIPv6(bytes) }
        return false
    }

    // 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16,
    // 172.16.0.0/12 and 192.168.0.0/16
    static func isLocalIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        switch bytes[0] {
        case 0: return true
        case 10: return true
        case 100: return bytes[1] >= 64 && bytes[1] <= 127
        case 127: return true
        case 169: return bytes[1] == 254
        case 172: return bytes[1] >= 16 && bytes[1] <= 31
        case 192: return bytes[1] == 168
        default: return false
        }
    }

    // ::1, ::, fc00::/7, fe80::/10 and the ipv4 that is written in one
    static func isLocalIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        // an ipv4 address in an ipv6 one: ::ffff:192.168.0.1
        if bytes[10] == 0xff && bytes[11] == 0xff {
            return isLocalIPv4(Array(bytes[12..<16]))
        }
        // :: and ::1
        if bytes[0..<15].allSatisfy({ $0 == 0 }) && (bytes[15] == 0 || bytes[15] == 1) {
            return true
        }
        // the ipv4 compatible form: ::192.168.0.1
        if bytes[0..<12].allSatisfy({ $0 == 0 }) {
            return isLocalIPv4(Array(bytes[12..<16]))
        }
        // fc00::/7, the addresses that are not routed on the internet
        if (bytes[0] & 0xfe) == 0xfc { return true }
        // fe80::/10, the addresses of the link itself
        if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80 { return true }
        return false
    }

    // 192.168.0.1 -> [192, 168, 0, 1]
    static func ipv4Bytes(_ text: String) -> [UInt8]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var bytes: [UInt8] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = UInt8(part) else { return nil }
            bytes.append(value)
        }
        return bytes
    }

    // ::1 -> sixteen bytes, the way an ipv6 address is written
    static func ipv6Bytes(_ text: String) -> [UInt8]? {
        guard text.contains(":") else { return nil }
        var components = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        var embeddedIPv4: [UInt8]?

        // an ipv4 address at the end: ::ffff:192.168.0.1
        if let last = components.last, last.contains(".") {
            guard let bytes = ipv4Bytes(last) else { return nil }
            embeddedIPv4 = bytes
            components.removeLast()
        }

        let joined = components.joined(separator: ":")
        let halves = joined.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }

        func parse(_ part: String) -> [UInt16]? {
            if part.isEmpty { return [] }
            var out: [UInt16] = []
            for piece in part.split(separator: ":", omittingEmptySubsequences: false) {
                guard !piece.isEmpty, piece.count <= 4,
                      let value = UInt16(piece, radix: 16) else { return nil }
                out.append(value)
            }
            return out
        }

        var groups: [UInt16]
        if halves.count == 2 {
            guard let left = parse(halves[0]), let right = parse(halves[1]) else { return nil }
            // the ipv4 takes the place of the last two groups
            let fill = 8 - left.count - right.count - (embeddedIPv4 != nil ? 2 : 0)
            guard fill >= 0 else { return nil }
            groups = left + [UInt16](repeating: 0, count: fill) + right
        } else {
            guard let all = parse(halves[0]) else { return nil }
            groups = all
        }
        if embeddedIPv4 != nil {
            guard groups.count == 6 else { return nil }
            groups.append(contentsOf: [0, 0])
        }
        guard groups.count == 8 else { return nil }

        var bytes: [UInt8] = []
        for group in groups {
            bytes.append(UInt8((group >> 8) & 0xff))
            bytes.append(UInt8(group & 0xff))
        }
        if let v4 = embeddedIPv4 {
            bytes.replaceSubrange(12..<16, with: v4)
        }
        return bytes
    }
}
