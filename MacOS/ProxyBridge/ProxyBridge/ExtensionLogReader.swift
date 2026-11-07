import Foundation
import OSLog

// What the system extension wrote, read back from the unified log.
//
// The app and the extension are two processes, and the message channel between
// them is checked against the app's signature: a build that is not signed by a
// developer gets no message through it, so the window stays empty even though
// the traffic is proxied.
//
// The unified log is the way around it. The extension writes every decision
// there - "Connection TCP ... via SOCKS5 (rule 3)" is one of those lines - and
// a process that is not sandboxed can read them back.
//
// The App Sandbox is what stands in the way. logd refuses to serve the system
// scope to a sandboxed process, and the /usr/bin/log tool says the same thing
// ("Cannot run while sandboxed"). So this only works in a build without the
// sandbox - which is what a build that is not going to the App Store wants.
enum ExtensionLogReader {
    /// The subsystem the extension writes its lines under.
    static let subsystem = "com.interceptsuite.ProxyBridge.extension"

    /// One line the extension wrote.
    struct Line {
        let date: Date
        let text: String
        /// The connection this line describes, when it describes one.
        let connection: Connection?
        /// "ERROR" when the extension wrote it as an error, "INFO" otherwise.
        let level: String
    }

    /// A connection the extension reported.
    struct Connection {
        let proto: String
        let process: String
        let destination: String
        let port: String
        let proxy: String
        /// The number of the rule that decided it, when the line says so.
        let rule: Int?
    }

    // Can this build read the log at all?
    //
    // The answer is no for a sandboxed build, and the reason is the sandbox
    // itself and not a missing permission: there is no way to ask for it.
    static func isReadable() -> Bool {
        guard #available(macOS 12.0, *) else { return false }
        do {
            _ = try OSLogStore(scope: .system)
            return true
        } catch {
            return false
        }
    }

    // The lines the extension wrote after a point in time, newest first.
    //
    // A nil "since" reads everything, which is a lot on a busy machine: the
    // caller keeps a cursor instead.
    static func lines(since: Date?) -> [Line] {
        guard #available(macOS 12.0, *) else { return [] }
        do {
            let store = try OSLogStore(scope: .system)
            let predicate = NSPredicate(format: "subsystem == %@", subsystem)
            let entries: [OSLogEntry]
            if let since = since {
                entries = Array(try store.getEntries(at: store.position(date: since), matching: predicate))
            } else {
                entries = Array(try store.getEntries(matching: predicate))
            }
            return entries.reversed().map { entry in
                let text = entry.composedMessage
                // the extension writes its errors as errors and the rest as notes;
                // the level is what tells them apart
                let level = (entry as? OSLogEntryLog).map {
                    $0.level.rawValue >= OSLogEntryLog.Level.error.rawValue ? "ERROR" : "INFO"
                } ?? "INFO"
                return Line(date: entry.date, text: text, connection: parse(text), level: level)
            }
        } catch {
            return []
        }
    }

    // Reads a connection out of one of the extension's lines.
    //
    // The extension writes:
    //   Connection TCP MiniMax Code Helper -> agent.minimax.cn:443 via Direct (rule 26)
    //   Connection TCP WeChat -> 240e:978:d04:3001::1d:80 via SOCKS5 127.0.0.1:9991 (rule 3)
    static func parse(_ text: String) -> Connection? {
        guard text.hasPrefix("Connection ") else { return nil }
        let body = String(text.dropFirst("Connection ".count))
        guard let arrow = body.range(of: " -> ") else { return nil }
        let left = String(body[body.startIndex..<arrow.lowerBound])
        let right = String(body[arrow.upperBound...])

        // the protocol is the first word and the process name is the rest: it
        // can have spaces in it ("MiniMax Code Helper")
        let leftParts = left.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard leftParts.count == 2, !leftParts[1].isEmpty else { return nil }
        let proto = String(leftParts[0])
        let process = String(leftParts[1])

        // the host and the port, and the host can be an ipv6 address, which
        // has colons in it: the port is after the last one
        guard let via = right.range(of: " via ", options: .backwards) else { return nil }
        let hostAndPort = String(right[right.startIndex..<via.lowerBound])
        var proxy = String(right[via.upperBound...])

        // the rule number sits in brackets at the end of the proxy name
        var rule: Int?
        if proxy.hasSuffix(")"), let open = proxy.lastIndex(of: "(") {
            let inside = String(proxy[proxy.index(after: open)..<proxy.index(before: proxy.endIndex)])
            if inside.hasPrefix("rule "), let number = Int(inside.dropFirst("rule ".count)) {
                rule = number
                proxy = String(proxy[proxy.startIndex..<open]).trimmingCharacters(in: .whitespaces)
            }
        }

        guard let colon = hostAndPort.lastIndex(of: ":") else { return nil }
        let destination = String(hostAndPort[hostAndPort.startIndex..<colon])
        let port = String(hostAndPort[hostAndPort.index(after: colon)...])
        guard !destination.isEmpty, !port.isEmpty else { return nil }

        return Connection(proto: proto, process: process, destination: destination, port: port, proxy: proxy, rule: rule)
    }
}
