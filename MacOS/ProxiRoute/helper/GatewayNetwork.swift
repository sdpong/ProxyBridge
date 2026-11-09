import Foundation

// The addresses of this machine, in the form the rules of the filter want.
//
// The rules say "the traffic from this network" and "the traffic of this
// machine", and both of those are read from the interface itself. Reading
// them at the moment the gateway is turned on means the rules always
// describe the network as it is then, and not as it was when the app was
// written.

enum GatewayNetwork {

    // What is known about one interface.
    struct Info {
        // the address of this machine on that interface
        let address: String
        // the network the clients are on, e.g. "192.168.254.0/24"
        let subnet: String
    }

    // What the interface looks like right now.
    //
    // The address and the mask are read from the system, and the network is
    // made of them: the address of the machine with the bits of the mask
    // that are set. That is the network the clients are on.
    static func info(interface: String) -> Info? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }

        var address: String?
        var mask: String?

        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = current {
            let ifa = entry.pointee
            let name = String(cString: ifa.ifa_name)
            if name == interface, ifa.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                address = host(of: ifa.ifa_addr)
                if let netmask = ifa.ifa_netmask {
                    mask = host(of: netmask)
                }
            }
            current = ifa.ifa_next
        }

        guard let address, let mask else { return nil }
        guard let subnet = subnet(address: address, mask: mask) else { return nil }
        return Info(address: address, subnet: subnet)
    }

    // The text of an address.
    private static func host(of address: UnsafeMutablePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let length = socklen_t(address.pointee.sa_len)
        let ok = withUnsafePointer(to: address.pointee) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                getnameinfo(generic, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            }
        }
        guard ok == 0 else { return nil }
        return String(cString: host)
    }

    // The network of an address and a mask.
    //
    // "192.168.254.205" and "255.255.255.0" make "192.168.254.0/24".
    static func subnet(address: String, mask: String) -> String? {
        guard let addressValue = number(address), let maskValue = number(mask) else { return nil }
        let network = addressValue & maskValue

        // the number of the bits that are not the mask
        var bits = 0
        var bit = UInt32(maskValue)
        while bit != 0 {
            if bit & 1 == 1 { bits += 1 }
            bit >>= 1
        }
        // a mask that is not one of the usual ones still has a number of bits
        // that is the number of ones in it, and the text says how many bits
        // are the network
        return "\(text(network))/\(bits)"
    }

    // The number of an address, in the order of the network.
    //
    // It is the number the kernel keeps the address in: the four bytes as
    // they are on the wire, so 192.168.254.205 is the number whose first
    // byte is 192. The text of a number is the other way around, and the
    // two are not the same number read the other way.
    static func number(_ address: String) -> UInt32? {
        var storage = in_addr()
        guard inet_pton(AF_INET, address, &storage) == 1 else { return nil }
        return UInt32(storage.s_addr)
    }

    // The text of a number that is in the order of the network.
    static func text(_ value: UInt32) -> String {
        var storage = in_addr(s_addr: in_addr_t(value))
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &storage, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
            return "0.0.0.0"
        }
        return String(cString: buffer)
    }
}
