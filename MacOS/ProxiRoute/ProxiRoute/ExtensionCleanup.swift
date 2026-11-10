import Foundation

// Taking the old records of the system extension out of the system.
//
// The problem this exists for:
//
//   macOS keeps every registered version of a system extension under the same
//   bundle id, and every registration is a separate record. Asking for the
//   extension again does not update the record that is there: it makes a new
//   one, and the old one is marked "terminated waiting to uninstall on
//   reboot". The records pile up, and the network configuration of the app -
//   which carries the code signature of the extension of the day it was
//   written - ends up bound to a record that is on its way out.
//
//   macOS then says "the VPN app used by this configuration is not
//   installed" (NEVPNConnectionErrorDomain 14), nothing is proxied, and the
//   window tells the person to run a command in the Terminal.
//
//   That command does not need a password.
//
//   The script that ships with the app used to say it needed root, and the
//   notice in the window said the same. Both were wrong: "systemextensionsctl
//   uninstall" takes the records out as the user who runs it. It was
//   measured on this machine - the command answers "Success" and exits with
//   0, and the records are gone from the system, without a password and
//   without root.
//
//   So the app does it itself, when it sees that the tunnel is bound to a
//   record that is not the one in use. The person is not asked to type
//   anything, and the machine is fixed by the app that has the problem.
enum ExtensionCleanup {

    // the tool of the system that takes a record out
    static let toolPath = "/usr/bin/systemextensionsctl"

    // the bundle ids that belong to this project.
    //
    // The extension of this app is one of them, and the older ones are the
    // ones that were used before the app was renamed. A machine that ran an
    // older build still has those records, and the system may bind the
    // tunnel to one of them.
    static let bundleIdentifiers = [
        "com.sdpong.proxiroute.extension",
        "com.sdpong.proxybridge.extension",
        "com.interceptsuite.ProxyBridge.fork",
        "com.interceptsuite.ProxyBridge.extension",
    ]

    // The answer of the tool: how many records it took out.
    struct Result {
        var removed = 0
        var failed = 0
        var message = ""
    }

    // Takes the records of this project out of the system.
    //
    // It does not need root and it does not ask for a password: the tool of
    // the system answers the user who runs it. The records that are marked
    // "terminated waiting to uninstall on reboot" are gone from the system
    // right away, and the ones that were in use go at the next restart of the
    // machine - which is what the system does with them, and not something
    // this app can change.
    @discardableResult
    static func removeOldRecords(bundleIdentifiers: [String] = ExtensionCleanup.bundleIdentifiers,
                                 toolPath: String = ExtensionCleanup.toolPath) -> Result {
        var result = Result()
        for bundle in bundleIdentifiers {
            // the team id of an ad-hoc record is a dash. The tool wants the
            // team id of the record, and the dash is what it takes for a
            // build that is not signed by a developer.
            //
            // The records of the other bundles of the project may be signed
            // by a developer, so their team id is read out of the list of the
            // system first, and the dash is used when there is none.
            for team in teamIdentifiers(for: bundle) {
                let answer = run([toolPath, "uninstall", team, bundle], toolPath: toolPath)
                if answer.status == 0 {
                    result.removed += 1
                } else {
                    result.failed += 1
                    result.message += answer.text
                }
            }
        }
        return result
    }

    // The team ids of the records of one bundle id.
    //
    // It is read out of the list of the system, so that a record that was
    // made by a build signed by a developer is taken out with its own team
    // id and not with the dash.
    static func teamIdentifiers(for bundle: String,
                                listPath: String = "/usr/bin/systemextensionsctl",
                                run: (String) -> String = { path in
                                    listOutput(at: path)
                                }) -> [String] {
        let answer = run(listPath)
        var teams: [String] = []
        for line in answer.split(separator: "\n") {
            guard line.contains(bundle) else { continue }
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            // the team id is the third column. a dash is written for a build
            // that is not signed by a developer.
            guard columns.count > 2 else { continue }
            var team = columns[2].trimmingCharacters(in: .whitespaces)
            if team.hasPrefix("teamID(") { team = String(team.dropFirst(6).dropLast()) }
            if team.isEmpty { team = "-" }
            if !teams.contains(team) { teams.append(team) }
        }
        return teams
    }

    // The list of the system extensions, as the tool of the system prints it.
    private static func listOutput(at path: String) -> String {
        run([path, "list"], toolPath: path).text
    }

    // The answer of a command: what it said and whether it was happy.
    private struct Answer {
        var status: Int32
        var text: String
    }

    private static func run(_ arguments: [String], toolPath: String) -> Answer {
        guard FileManager.default.isExecutableFile(atPath: toolPath) else {
            return Answer(status: -1, text: "\(toolPath) is not there")
        }
        // The two outputs of the tool come from one pipe: a tool that fills
        // the pipe of one of them while the other one is full waits for
        // ever, and nobody is here to read them one after the other.
        guard let answer = ToolRunner.run(toolPath, Array(arguments.dropFirst())) else {
            return Answer(status: -1, text: "The tool could not be started.")
        }
        return Answer(status: answer.status,
                      text: answer.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
