import Foundation

// What the DNS proxy is doing, read back from the unified log.
//
// The extension writes one line like this while it runs:
//   DNSStatus running queries 12 answers 11 names 7 last api.dia.es -> 0.0.0.56
//
// The log is the only channel a build that is not signed by a developer has: the
// message channel between the app and its own extension is checked against the
// app's signature, and an ad-hoc build gets no message through it.
struct DNSStatus: Equatable {
    // whether the DNS proxy is running
    var running: Bool = false
    // how many queries it took
    var queries: Int = 0
    // how many answers it got back
    var answers: Int = 0
    // how many different names those answers were for
    var names: Int = 0
    // the last name it saw, and the addresses it got for it
    var lastName: String = ""
    var lastAddresses: String = ""

    // the status line of a provider that has not answered anything yet
    static let empty = DNSStatus()

    // reads one line of the log
    static func parse(_ text: String) -> DNSStatus? {
        guard text.hasPrefix("DNSStatus ") else { return nil }
        var words = text.dropFirst("DNSStatus ".count).split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard !words.isEmpty else { return nil }

        var status = DNSStatus()
        status.running = words.removeFirst() == "running"

        var index = 0
        while index < words.count {
            switch words[index] {
            case "queries":
                if index + 1 < words.count { status.queries = Int(words[index + 1]) ?? 0 }
            case "answers":
                if index + 1 < words.count { status.answers = Int(words[index + 1]) ?? 0 }
            case "names":
                if index + 1 < words.count { status.names = Int(words[index + 1]) ?? 0 }
            case "last":
                // what is left is "<name> -> <addresses>"
                if index + 1 < words.count { status.lastName = words[index + 1] }
                var rest = index + 2
                if rest < words.count, words[rest] == "->" { rest += 1 }
                if rest < words.count { status.lastAddresses = words[rest...].joined(separator: " ") }
                index = words.count
                continue
            default:
                break
            }
            index += 1
        }

        if status.lastName == "none" { status.lastName = "" }
        if status.lastAddresses == "none" { status.lastAddresses = "" }
        return status
    }

    // the newest status out of a list of log lines. the log is in the order it
    // was written, so the last one that says anything is the newest
    static func newest(in lines: [ExtensionLogReader.Line]) -> DNSStatus? {
        var found: DNSStatus?
        for line in lines {
            guard let status = parse(line.text) else { continue }
            found = status
        }
        return found
    }

    // one line that says what this means, in words
    var summary: String {
        if !running {
            return "The DNS proxy is not running."
        }
        var text = "The DNS proxy is running. \(queries) queries, \(answers) answers, \(names) names."
        if !lastName.isEmpty {
            text += " Last answer: \(lastName) -> \(lastAddresses)."
        }
        return text
    }
}
