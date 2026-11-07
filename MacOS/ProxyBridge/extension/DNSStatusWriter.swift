import Foundation

// One line that says what the DNS proxy is doing right now.
//
// The app and the extension are two processes, and the message channel between
// them is checked against the app's signature: a build that is not signed by a
// developer gets no message through it. The unified log is what is left, and it
// is where the app reads everything else the extension says.
//
// The line is:
//   DNSStatus running queries 12 answers 11 names 7 last api.dia.es -> 0.0.0.56
enum DNSStatusWriter {
    static func make(running: Bool,
                     queries: Int,
                     answers: Int,
                     names: Int,
                     lastName: String,
                     lastAddresses: String) -> String {
        let name = lastName.isEmpty ? "none" : lastName
        let addresses = lastAddresses.isEmpty ? "none" : lastAddresses
        return "DNSStatus \(running ? "running" : "stopped") queries \(queries) answers \(answers) names \(names) last \(name) -> \(addresses)"
    }
}
