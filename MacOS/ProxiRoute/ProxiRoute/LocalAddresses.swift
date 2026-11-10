import Foundation

// The addresses of this machine.
//
// The server can listen on one of them, and then it is only reachable
// through the network that address belongs to. That is how a Mac that is
// plugged in and also on a wireless network offers its proxy on the wired
// side only.
enum LocalAddresses {

    struct Entry: Identifiable {
        let address: String
        let name: String
        var id: String { address }
    }

    // every address that is of use: the ones of the interfaces that are up,
    // and not the loopback
    static func all() -> [Entry] {
        var out: [Entry] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return out }
        defer { freeifaddrs(pointer) }

        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = current {
            let ifa = entry.pointee
            let family = ifa.ifa_addr.pointee.sa_family
            if family == UInt8(AF_INET) {
                var address = ifa.ifa_addr.pointee
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(&address, socklen_t(ifa.ifa_addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let text = String(cString: host)
                    if text != "127.0.0.1" {
                        let name = String(cString: ifa.ifa_name)
                        out.append(Entry(address: text, name: name))
                    }
                }
            }
            current = ifa.ifa_next
        }
        return out
    }

    // the address of one interface
    //
    // The gateway mode needs the address of the card it is the gateway of:
    // the traffic of the network is redirected to that address, and not to
    // the loopback. The answer of the filter has to come from the same
    // place the traffic was sent to, or the kernel does not recognise it as
    // the answer of the traffic it redirected.
    static func address(ofInterface name: String) -> String? {
        return all().first(where: { $0.name == name })?.address
    }
}
