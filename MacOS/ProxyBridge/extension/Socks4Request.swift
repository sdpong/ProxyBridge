import Foundation
import Network

// SOCKS4 and SOCKS4a.
//
// SOCKS4 is older than SOCKS5 and much simpler: there is no method
// negotiation, only a user id in the request. SOCKS4a is the same, with the
// name of the host sent after the user id, for the case where the client
// cannot resolve the name itself.
//
// The request is built here, away from the network code, so it can be tested.
enum Socks4Request {
    // the reply codes
    static let granted: UInt8 = 90
    static let rejected: UInt8 = 91

    // builds the request for a destination. returns nil when the destination
    // cannot be asked for: socks4 has no ipv6, and the name of a socks4a
    // request has to fit in a length of one byte.
    static func build(destination: String, port: UInt16, username: String?) -> Data? {
        var request = Data()
        request.append(0x04)          // VN
        request.append(0x01)          // CD = CONNECT
        request.append(UInt8(port >> 8))
        request.append(UInt8(port & 0xFF))

        var host: [UInt8]? = nil
        if let ip = IPv4Address(destination) {
            request.append(contentsOf: ip.rawValue)
        } else if IPv6Address(destination) != nil {
            // socks4 has no ipv6
            return nil
        } else {
            // socks4a: the address says "a name follows"
            request.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
            let bytes = Array(destination.utf8)
            guard !bytes.isEmpty, bytes.count <= 255 else { return nil }
            host = bytes
        }

        // the user id, an empty one is allowed
        let user = Array((username ?? "").utf8)
        guard user.count <= 255 else { return nil }
        request.append(contentsOf: user)
        request.append(0x00)

        if let host = host {
            request.append(contentsOf: host)
            request.append(0x00)
        }
        return request
    }

    // the reply is always eight bytes, the code is the second one
    static func replyCode(_ data: Data) -> UInt8? {
        guard data.count >= 2 else { return nil }
        return data[1]
    }

    static func isGranted(_ data: Data) -> Bool {
        return replyCode(data) == granted
    }

    // what the proxy said, for the log
    static func reason(_ data: Data) -> String {
        guard let code = replyCode(data) else { return "the reply was too short" }
        switch code {
        case granted: return "granted"
        case rejected: return "rejected"
        default: return "unknown code \(code)"
        }
    }
}
