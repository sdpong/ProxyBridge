import Foundation

// Minimal DNS message parser: pulls the queried name and its A/AAAA answers.
//
// It lives in its own file because it is pure packet work: it can be compiled
// and tested without NetworkExtension, which is what the logic tests do.

// Minimal DNS message parser: pulls the queried name and its A/AAAA answers.
enum DNSParser {
    static func parse(_ data: Data) -> (domain: String, ips: [String])? {
        let b = [UInt8](data)
        guard b.count >= 12 else { return nil }

        let qdCount = Int(b[4]) << 8 | Int(b[5])
        let anCount = Int(b[6]) << 8 | Int(b[7])
        guard qdCount >= 1 else { return nil }

        var i = 12
        guard let qname = readName(b, &i), i + 4 <= b.count else { return nil }
        i += 4 // QTYPE + QCLASS

        // skip any extra questions (rare)
        if qdCount > 1 {
            for _ in 1..<qdCount {
                guard skipName(b, &i), i + 4 <= b.count else { return nil }
                i += 4
            }
        }

        var ips: [String] = []
        for _ in 0..<anCount {
            guard skipName(b, &i), i + 10 <= b.count else { break }
            let type = Int(b[i]) << 8 | Int(b[i + 1])
            let rdlen = Int(b[i + 8]) << 8 | Int(b[i + 9])
            i += 10
            guard i + rdlen <= b.count else { break }

            if type == 1, rdlen == 4 {
                ips.append("\(b[i]).\(b[i + 1]).\(b[i + 2]).\(b[i + 3])")
            } else if type == 28, rdlen == 16 {
                var parts: [String] = []
                for k in stride(from: 0, to: 16, by: 2) {
                    parts.append(String(format: "%x", Int(b[i + k]) << 8 | Int(b[i + k + 1])))
                }
                ips.append(parts.joined(separator: ":"))
            }
            i += rdlen
        }

        return ips.isEmpty ? nil : (qname.lowercased(), ips)
    }

    // the name a query asks for. the DNS proxy needs it before the answer comes
    // back, to know which resolver the query belongs to and whether the name is
    // on the exclusion list.
    static func questionName(_ data: Data) -> String? {
        let b = [UInt8](data)
        guard b.count >= 12 else { return nil }

        let qdCount = Int(b[4]) << 8 | Int(b[5])
        guard qdCount >= 1 else { return nil }

        var i = 12
        guard let qname = readName(b, &i) else { return nil }
        return qname.lowercased()
    }

    // reads a name into a string, following compression pointers
    private static func readName(_ b: [UInt8], _ i: inout Int) -> String? {
        var labels: [String] = []
        var j = i
        var jumped = false
        var hops = 0
        while j < b.count {
            hops += 1
            if hops > 128 { return nil }
            let len = Int(b[j])
            if len == 0 {
                if !jumped { i = j + 1 }
                break
            }
            if len & 0xC0 == 0xC0 {
                guard j + 1 < b.count else { return nil }
                if !jumped { i = j + 2 }
                jumped = true
                j = (len & 0x3F) << 8 | Int(b[j + 1])
                continue
            }
            guard j + 1 + len <= b.count else { return nil }
            labels.append(String(bytes: b[(j + 1)..<(j + 1 + len)], encoding: .utf8) ?? "")
            j += 1 + len
        }
        return labels.joined(separator: ".")
    }

    // advances the offset past a name without decoding it
    private static func skipName(_ b: [UInt8], _ i: inout Int) -> Bool {
        var j = i
        while j < b.count {
            let len = Int(b[j])
            if len == 0 { i = j + 1; return true }
            if len & 0xC0 == 0xC0 { i = j + 2; return true }
            j += 1 + len
        }
        return false
    }
}
