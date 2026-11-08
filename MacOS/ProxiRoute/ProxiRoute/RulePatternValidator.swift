import Foundation
import NetworkExtension

// The rule editor lets the user type a list of programs, or a list of hosts,
// one entry per line. What they type is checked here, so that the editor can
// mark the entries that cannot work: a host that is in the list twice, two ip
// ranges that cover the same addresses, a range that is written backwards.
//
// The syntax understood here is the syntax the network extension matches
// with (see extension/AppProxyProvider.swift), so a rule that passes this
// check behaves the same way there. Where the extension is more forgiving than
// this file, the difference is a note in docs/FORK-NOTES.md.

// what is wrong with an entry
enum RulePatternProblem {
    case duplicate        // the same entry is in the list more than once
    case redundant        // another entry of the same list already covers it
    case overlappingIP    // two ip ranges cover the same addresses
    case invalidIPPattern // not an address the matcher can read
    case unsupportedCIDR  // cidr is not a syntax the matcher knows

    var message: String {
        switch self {
        case .duplicate: return "is in the list more than once"
        case .redundant: return "is already covered by another entry"
        case .overlappingIP: return "overlaps another ip range"
        case .invalidIPPattern: return "is not an address the matcher can read"
        case .unsupportedCIDR: return "uses cidr, which the matcher does not know"
        }
    }
}

// one entry of the list the user typed, and where it sits in that text
struct RulePatternEntry {
    let text: String          // the entry itself, without the spaces around it
    let range: NSRange        // where it sits in the text the user typed
    var problems: [RulePatternProblem] = []
    var notes: [String] = []

    var hasProblem: Bool { !problems.isEmpty }

    // one line that says what is wrong with this entry
    var summary: String {
        var parts = problems.map { $0.message }
        parts.append(contentsOf: notes)
        return parts.joined(separator: ", ")
    }
}

// an ip range, as a pair of addresses. a wildcard pattern becomes the range
// it covers, so that two patterns can be compared with each other.
struct RuleIPInterval {
    let family: Int      // 4 for ipv4, 16 for ipv6
    let lower: [UInt8]
    let upper: [UInt8]

    func overlaps(_ other: RuleIPInterval) -> Bool {
        guard family == other.family else { return false }
        return RulePatternValidator.compareBytes(lower, other.upper) <= 0
            && RulePatternValidator.compareBytes(other.lower, upper) <= 0
    }
}

enum RulePatternValidator {

    // hosts are separated by ; and by spaces, a host name has no space in it
    static let hostSeparators: CharacterSet = {
        var set = CharacterSet(charactersIn: ";")
        set.formUnion(.whitespacesAndNewlines)
        return set
    }()

    // a program name can have spaces in it ("Google Chrome Helper"), so only
    // ; , and the line breaks separate them
    static let programSeparators: CharacterSet = {
        var set = CharacterSet(charactersIn: ";,")
        set.formUnion(.newlines)
        return set
    }()

    // MARK: - splitting the text into entries

    // splits what the user typed into the entries a rule is made of
    //
    // keepRangesTogether keeps "10.0.0.1 - 10.0.0.254" in one piece: a space
    // around the dash belongs to the range, it does not separate two entries.
    static func entries(_ text: String, separators: CharacterSet, keepRangesTogether: Bool = false) -> [RulePatternEntry] {
        let ns = text as NSString
        var out: [RulePatternEntry] = []
        var start = 0
        while start < ns.length {
            var end = start
            while end < ns.length {
                let ch = ns.substring(with: NSRange(location: end, length: 1))
                guard let scalar = ch.unicodeScalars.first else { break }
                if separators.contains(scalar) {
                    if keepRangesTogether {
                        // a space next to a dash belongs to the range
                        let previous = end > start ? ns.substring(with: NSRange(location: end - 1, length: 1)) : ""
                        let next = end + 1 < ns.length ? ns.substring(with: NSRange(location: end + 1, length: 1)) : ""
                        if previous == "-" || next == "-" {
                            end += 1
                            continue
                        }
                    }
                    break
                }
                end += 1
            }
            // the spaces around an entry are not part of it
            var first = start
            var last = end
            while first < last, isSpace(ns, first) { first += 1 }
            while last > first, isSpace(ns, last - 1) { last -= 1 }
            if last > first {
                out.append(RulePatternEntry(
                    text: ns.substring(with: NSRange(location: first, length: last - first)),
                    range: NSRange(location: first, length: last - first)
                ))
            }
            start = end + 1
        }
        return out
    }

    private static func isSpace(_ ns: NSString, _ index: Int) -> Bool {
        let ch = ns.substring(with: NSRange(location: index, length: 1))
        guard let scalar = ch.unicodeScalars.first else { return false }
        return scalar.properties.isWhitespace
    }

    // the form a rule is stored in: the entries in one line, separated by ;
    static func storedForm(_ text: String, separators: CharacterSet, keepRangesTogether: Bool = false) -> String {
        return entries(text, separators: separators, keepRangesTogether: keepRangesTogether)
            .map { $0.text }
            .joined(separator: "; ")
    }

    // the form the editor shows: the entries, one per line
    static func displayForm(_ stored: String, separators: CharacterSet, keepRangesTogether: Bool = false) -> String {
        return entries(stored, separators: separators, keepRangesTogether: keepRangesTogether)
            .map { $0.text }
            .joined(separator: "\n")
    }

    // MARK: - the checks

    // checks the hosts the user typed
    static func checkHosts(_ text: String) -> [RulePatternEntry] {
        var entries = entries(text, separators: hostSeparators, keepRangesTogether: true)
        markDuplicates(&entries)
        markCoveredHosts(&entries)
        markIPProblems(&entries)
        return entries
    }

    // checks the program names the user typed. only a name that is in the list
    // twice is wrong here: a wildcard in the same list may well be meant to
    // catch something the plain name does not.
    static func checkPrograms(_ text: String) -> [RulePatternEntry] {
        var entries = entries(text, separators: programSeparators)
        markDuplicates(&entries)
        return entries
    }

    // the same entry twice
    private static func markDuplicates(_ entries: inout [RulePatternEntry]) {
        var byText: [String: [Int]] = [:]
        for (index, entry) in entries.enumerated() {
            byText[entry.text.lowercased(), default: []].append(index)
        }
        for indexes in byText.values where indexes.count > 1 {
            for index in indexes {
                entries[index].problems.append(.duplicate)
            }
        }
    }

    // an entry that another entry of the same list already covers, e.g. the
    // name of a host under a wildcard that is also in the list
    private static func markCoveredHosts(_ entries: inout [RulePatternEntry]) {
        let count = entries.count
        guard count > 1 else { return }
        for i in 0..<count {
            let a = entries[i].text.lowercased()
            guard isDomain(a) else { continue }
            for j in 0..<count where j != i {
                let b = entries[j].text.lowercased()
                guard a != b, isDomain(b) else { continue }
                if domainCovers(b, a) {
                    entries[i].problems.append(.redundant)
                    entries[i].notes.append("covered by \"\(entries[j].text)\"")
                    break
                }
            }
        }
    }

    // an address that is not written the way the matcher reads it, and two
    // ranges that cover the same addresses
    private static func markIPProblems(_ entries: inout [RulePatternEntry]) {
        var intervals: [Int: RuleIPInterval] = [:]
        for (index, entry) in entries.enumerated() {
            switch parseHostPattern(entry.text) {
            case .ip(let interval):
                intervals[index] = interval
            case .cidr:
                entries[index].problems.append(.unsupportedCIDR)
                entries[index].notes.append("write \(cidrAsRange(entry.text) ?? entry.text) instead")
            case .invalid(let reason):
                entries[index].problems.append(.invalidIPPattern)
                entries[index].notes.append(reason)
            case .domain:
                break
            }
        }

        let keys = intervals.keys.sorted()
        for i in 0..<keys.count {
            for j in (i + 1)..<keys.count {
                let a = intervals[keys[i]]!
                let b = intervals[keys[j]]!
                guard a.overlaps(b) else { continue }
                entries[keys[i]].problems.append(.overlappingIP)
                entries[keys[i]].notes.append("covers the same addresses as \"\(entries[keys[j]].text)\"")
                entries[keys[j]].problems.append(.overlappingIP)
                entries[keys[j]].notes.append("covers the same addresses as \"\(entries[keys[i]].text)\"")
            }
        }
    }

    // MARK: - reading a host as an address

    enum ParsedHost {
        case ip(RuleIPInterval)
        case cidr
        case invalid(String)
        case domain
    }

    // reads one entry of the host list: an address, a range, or a name
    static func parseHostPattern(_ text: String) -> ParsedHost {
        if text.contains("/") {
            if isCIDR(text) { return .cidr }
            return .invalid("not an address the matcher can read")
        }

        if text.contains("-") {
            // a range. a name can hold a dash too, so the two ends have to be
            // addresses before the entry is taken for a range
            let parts = text.components(separatedBy: "-")
            if parts.count == 2 {
                let low = literalBytes(parts[0].trimmingCharacters(in: .whitespaces))
                let high = literalBytes(parts[1].trimmingCharacters(in: .whitespaces))
                if let low = low, let high = high {
                    if low.count != high.count {
                        return .invalid("the two ends of the range are not the same kind of address")
                    }
                    if compareBytes(low, high) > 0 {
                        return .invalid("the range starts after it ends")
                    }
                    return .ip(RuleIPInterval(family: low.count, lower: low, upper: high))
                }
            }
            if looksLikeAddress(text) { return .invalid("not an address range the matcher can read") }
            return .domain
        }

        if text.contains(":") {
            if let bytes = literalBytes(text) {
                return .ip(RuleIPInterval(family: bytes.count, lower: bytes, upper: bytes))
            }
            if let interval = parseV6Wildcard(text) {
                return .ip(interval)
            }
            return .invalid("not an ipv6 address the matcher can read")
        }

        if let interval = parseV4Wildcard(text) {
            return .ip(interval)
        }
        if looksLikeAddress(text) { return .invalid("not an address the matcher can read") }
        return .domain
    }

    // the raw bytes of an address, nil when the text is not one
    static func literalBytes(_ text: String) -> [UInt8]? {
        if let v4 = IPv4Address(text) { return Array(v4.rawValue) }
        if let v6 = IPv6Address(text) { return Array(v6.rawValue) }
        return nil
    }

    // 192.168.1.7 and 192.168.1.* are both read by the matcher
    static func parseV4Wildcard(_ text: String) -> RuleIPInterval? {
        let parts = text.components(separatedBy: ".")
        guard parts.count == 4 else { return nil }
        var lower: [UInt8] = []
        var upper: [UInt8] = []
        for part in parts {
            if part == "*" {
                lower.append(0)
                upper.append(255)
                continue
            }
            // the matcher compares the octets as text, so "01" is not "1"
            guard let value = UInt8(part), String(value) == part else { return nil }
            lower.append(value)
            upper.append(value)
        }
        return RuleIPInterval(family: 4, lower: lower, upper: upper)
    }

    // 2001:db8:* is read by the matcher, 2001:db8::* is not
    static func parseV6Wildcard(_ text: String) -> RuleIPInterval? {
        guard text.hasSuffix("*") else { return nil }
        var groups = String(text.dropLast()).components(separatedBy: ":")
        if groups.last == "" { groups.removeLast() }
        guard !groups.isEmpty, groups.count <= 8 else { return nil }
        var values: [UInt16] = []
        for group in groups {
            guard !group.isEmpty, group.count <= 4, let value = UInt16(group, radix: 16) else { return nil }
            values.append(value)
        }
        var lower: [UInt8] = []
        var upper: [UInt8] = []
        for value in values {
            lower.append(UInt8(truncatingIfNeeded: value >> 8))
            lower.append(UInt8(truncatingIfNeeded: value & 0xff))
            upper.append(UInt8(truncatingIfNeeded: value >> 8))
            upper.append(UInt8(truncatingIfNeeded: value & 0xff))
        }
        for _ in 0..<(8 - values.count) {
            lower.append(contentsOf: [0, 0])
            upper.append(contentsOf: [0xff, 0xff])
        }
        return RuleIPInterval(family: 16, lower: lower, upper: upper)
    }

    // a text that was meant to be an address. a name that starts with a digit
    // is still a name, so only a dotted number or a colon makes an address.
    static func looksLikeAddress(_ text: String) -> Bool {
        if text.contains(":") { return true }
        let parts = text.components(separatedBy: ".")
        guard parts.count > 1 else { return false }
        return parts.allSatisfy { part in
            part == "*" || (!part.isEmpty && part.allSatisfy { $0.isNumber })
        }
    }

    // 10.0.0.0/24, the form the matcher does not know
    static func isCIDR(_ text: String) -> Bool {
        let parts = text.components(separatedBy: "/")
        guard parts.count == 2, let bits = Int(parts[1]), bits >= 0, bits <= 128 else { return false }
        return literalBytes(parts[0]) != nil
    }

    // the range that holds the same addresses as a cidr, for the note
    static func cidrAsRange(_ text: String) -> String? {
        let parts = text.components(separatedBy: "/")
        guard parts.count == 2, let bits = Int(parts[1]), let bytes = literalBytes(parts[0]) else { return nil }
        guard bits < bytes.count * 8 else { return nil }
        let keep = bits / 8
        let rest = bits % 8
        var lower = bytes
        var upper = bytes
        for i in keep..<bytes.count {
            lower[i] = 0
            upper[i] = 255
        }
        if rest > 0 {
            let mask = UInt8(truncatingIfNeeded: (0xff << (8 - rest)) & 0xff)
            lower[keep] = bytes[keep] & mask
            upper[keep] = bytes[keep] | ~mask
        }
        return "\(formatAddress(lower))-\(formatAddress(upper))"
    }

    // the text of an address, in the shape the user writes it
    static func formatAddress(_ bytes: [UInt8]) -> String {
        if bytes.count == 4 {
            return bytes.map { String($0) }.joined(separator: ".")
        }
        guard bytes.count == 16 else { return "" }
        let groups = stride(from: 0, to: 16, by: 2).map { i -> String in
            let value = (UInt16(bytes[i]) << 8) | UInt16(bytes[i + 1])
            return String(value, radix: 16)
        }
        return groups.joined(separator: ":")
    }

    // MARK: - names

    // a host that is a name and not an address
    static func isDomain(_ text: String) -> Bool {
        if text == "*" { return false }
        switch parseHostPattern(text) {
        case .domain: return true
        case .ip, .cidr, .invalid: return false
        }
    }

    // does a pattern cover a name? the matcher reads a wildcard in the same
    // way, and *.example.com also covers example.com
    static func domainCovers(_ cover: String, _ other: String) -> Bool {
        guard cover.contains("*"), cover != "*", !other.contains("*") else { return false }
        if globMatch(cover, other) { return true }
        if cover.hasPrefix("*."), other == String(cover.dropFirst(2)) { return true }
        return false
    }

    // wildcard match, the way the matcher does it
    static func globMatch(_ pattern: String, _ text: String) -> Bool {
        let p = Array(pattern.lowercased())
        let t = Array(text.lowercased())
        var pi = 0
        var ti = 0
        var star = -1
        var mark = 0
        while ti < t.count {
            if pi < p.count, p[pi] == t[ti] {
                pi += 1
                ti += 1
            } else if pi < p.count, p[pi] == "*" {
                star = pi
                mark = ti
                pi += 1
            } else if star != -1 {
                pi = star + 1
                mark += 1
                ti = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    // compares two addresses
    static func compareBytes(_ a: [UInt8], _ b: [UInt8]) -> Int {
        for i in 0..<min(a.count, b.count) where a[i] != b[i] {
            return a[i] < b[i] ? -1 : 1
        }
        return 0
    }
}
