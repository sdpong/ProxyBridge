import Foundation

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
// The App Sandbox is what stands in the way. logd does not serve the system
// scope to a sandboxed process, and /usr/bin/log says the same thing
// ("Cannot run while sandboxed"). So this only works in a build without the
// sandbox - which is what a build that is not going to the App Store wants.
//
// The log is read with the tool macOS ships for it, and not with OSLogStore.
// A store is a snapshot: it shows the log as it was when the store was made,
// and a store that is kept shows the log as of that moment forever. The tool
// follows the log as it grows, and it waits for the entries instead of walking
// the log over and over, so following it costs about a tenth of a percent of
// a core.
enum ExtensionLogReader {
    /// The subsystem the extension writes its lines under.
    static let subsystem = "com.interceptsuite.ProxyBridge.extension"

    /// The tool that reads the log. It is in every macOS.
    static let toolPath = "/usr/bin/log"

    /// Whether this build can read the unified log at all.
    ///
    /// The tool says it when it cannot: in a build that is sandboxed it
    /// refuses to run at all ("log: Cannot run while sandboxed"). So the
    /// question is put to the tool.
    static func canRead() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: toolPath)
        process.arguments = [
            "show",
            "--last", "1s",
            "--style", "compact",
            "--predicate", "subsystem == \"\(subsystem)\""
        ]
        let errors = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if String(decoding: message, as: UTF8.self).contains("sandboxed") { return false }
        return process.terminationStatus == 0
    }

    /// The reason the unified log cannot be read, in words.
    ///
    /// The tool says why it will not run, and the one reason that matters is
    /// the sandbox: a build that is sandboxed can not read the log at all, and
    /// no setting of the app changes that.
    static func unreadableReason(_ raw: String) -> String {
        if raw.lowercased().contains("sandboxed") {
            return "This build cannot read the unified log. The App Sandbox is what stops it: logd does not serve the system scope to a sandboxed process, and /usr/bin/log refuses to run in one at all. A build that is not sandboxed reads it without trouble."
        }
        return "The unified log cannot be read: \(raw)"
    }

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

    // One line of "log stream --style compact":
    //
    //   2026-11-07 15:54:32.627 Df com.sdpong.proxybridge.extension[32915:5e4ee] [com.interceptsuite.ProxyBridge.extension:provider] Connection UDP ...
    //
    // The header has six parts and the message is the sixth, whatever the
    // message holds. The two lines the tool writes before the first entry do
    // not have six parts and are not lines of the log.
    static func parseCompact(_ raw: String) -> Line? {
        let parts = raw.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
        guard parts.count == 6 else { return nil }
        guard let date = compactFormatter.date(from: "\(parts[0]) \(parts[1])") else { return nil }
        // the tool writes the level in two letters: "Ee" is an error, the rest
        // is what the extension writes its notes as
        let level = parts[2] == "Ee" ? "ERROR" : "INFO"
        let text = String(parts[5])
        return Line(date: date, text: text, connection: parse(text), level: level)
    }

    // The stamp of a compact line. It is read on one thread at a time - the
    // thread that reads the tool's output - and it is never changed.
    private static let compactFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()
}

// Follows the unified log and hands over the lines as they come.
//
// The tool is started once and left running: it waits for the entries and
// costs almost nothing that way. Reading the log by walking it over and over
// instead costs about half a second every time and shows a stale picture.
final class UnifiedLogTail {
    private let process = Process()
    private let output = Pipe()
    private let errors = Pipe()
    private var buffer = Data()
    private var stopped = false

    /// The line that was read.
    var onLine: ((ExtensionLogReader.Line) -> Void)?

    /// The tool could not run, or it stopped.
    var onFailure: ((String) -> Void)?

    /// Starts following the log.
    func start() {
        process.executableURL = URL(fileURLWithPath: ExtensionLogReader.toolPath)
        process.arguments = [
            "stream",
            "--style", "compact",
            "--predicate", "subsystem == \"\(ExtensionLogReader.subsystem)\""
        ]
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice

        // the tool writes why it cannot run to its error output, and in a
        // sandboxed build that is the whole answer: "Cannot run while sandboxed"
        let errorPipe = errors.fileHandleForReading
        Thread.detachNewThread {
            let text = errorPipe.readDataToEndOfFile()
            let message = String(decoding: text, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !message.isEmpty { self.onFailure?(message) }
        }

        process.terminationHandler = { [weak self] finished in
            guard let self = self else { return }
            if !self.stopped {
                self.onFailure?("The tool that reads the unified log stopped (status \(finished.terminationStatus)).")
            }
        }

        do {
            try process.run()
        } catch {
            onFailure?("The tool that reads the unified log could not be started: \(error.localizedDescription)")
            return
        }

        // the output is read on a thread of its own: a read that waits for
        // the next line must not wait on the thread that draws the window
        let pipe = output.fileHandleForReading
        Thread.detachNewThread {
            while true {
                let data = pipe.readData(ofLength: 64 * 1024)
                if data.isEmpty { break }
                self.consume(data)
            }
        }
    }

    /// Stops following the log.
    func stop() {
        stopped = true
        if process.isRunning { process.terminate() }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        let pieces = buffer.split(separator: 0x0A, omittingEmptySubsequences: false)
        guard let last = pieces.last else { return }
        buffer = Data(last)
        for piece in pieces.dropLast() {
            let raw = String(decoding: piece, as: UTF8.self)
            guard let line = ExtensionLogReader.parseCompact(raw) else { continue }
            onLine?(line)
        }
    }
}

// Reads the lines of the last while-seconds, once.
//
// The tail starts with the log as it is now, so a window that opens shows
// nothing until the next connection. This is what fills it with the minute
// before, so the list starts with something in it.
enum UnifiedLogBacklog {
    static func read(seconds: Int, completion: @escaping ([ExtensionLogReader.Line]) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ExtensionLogReader.toolPath)
        process.arguments = [
            "show",
            "--last", "\(seconds)s",
            "--style", "compact",
            "--predicate", "subsystem == \"\(ExtensionLogReader.subsystem)\""
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        Thread.detachNewThread {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let text = String(decoding: data, as: UTF8.self)
            let lines = text.split(separator: "\n").compactMap { ExtensionLogReader.parseCompact(String($0)) }
            completion(lines)
        }

        do {
            try process.run()
        } catch {
            completion([])
        }
    }
}
