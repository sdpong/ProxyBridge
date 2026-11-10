import Foundation

// Whether the network of the machine is there.
//
// The traffic of the machine is only taken over when the network is up: a
// tunnel that is put up before that carries nothing, and the machine behind
// it has no network at all.
//
// The question is asked of the system and not guessed: the default route
// says that there is somewhere to send a packet to, and an address says that
// the machine is on a network.
enum NetworkReadiness {
    /// how long the app waits for the network, in seconds
    ///
    /// The wait is not long: a machine whose network never comes up would
    /// otherwise never start the proxy.
    static let waitLimit: TimeInterval = 60

    /// whether the machine has a network now
    static func isUp() -> Bool {
        if hasADefaultRoute() { return true }
        return hasAnAddress()
    }

    /// whether there is a default route
    ///
    /// This is the honest answer: it says that there is somewhere to send a
    /// packet to.
    static func hasADefaultRoute() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/route")
        process.arguments = ["-n", "get", "default"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// whether the machine has an address
    ///
    /// A machine that has an address but no default route is on a network
    /// that does not reach the internet. It is still a network, and the
    /// tunnel can be put up on it.
    static func hasAnAddress() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
        process.arguments = ["--nwi"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return false
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.contains("address")
    }
}
