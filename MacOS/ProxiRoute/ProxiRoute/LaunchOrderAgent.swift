import Foundation

// The launch agent that starts the app at the login.
//
// macOS has no order for the login items: they all start at the same moment,
// and nothing in the system settings says which one comes first. A launch
// agent is the way to bring an order back. It runs at every login and starts
// the app right away, so that the proxy of the machine is up before the
// browsers and before the other apps that use the network.
//
// The upstream proxy on this machine - Clash Meta, for example - is not waited
// for here: the app waits for that on its own, before it takes the traffic of
// the machine over, and it knows the rules and the proxies. The agent only
// writes the order down, so that it can be seen afterwards.
//
// It is an agent of the user and not of the system: it lives in the folder of
// the launch agents of the user, so it needs no password and no root, and it
// goes away when the user throws it out.
//
// The agent is the launcher of the app when it is on, so the app does not
// register itself as a login item at the same time: two launchers would
// start the app twice, and the one that waits for the upstream would be the
// one that loses.

enum LaunchOrderAgent {

    /// whether the agent is wanted
    ///
    /// The agent is the mechanism behind the one switch that starts the app at
    /// the login, so the answer is the answer of that switch.
    ///
    /// It is the same answer and not one of its own: the window asks the same
    /// question, and the two have to be given the same answer.
    static var isEnabled: Bool { LoginItem.isEnabled }

    /// Turns the agent on or off.
    ///
    /// The answer is given back in words, because the person has to know
    /// whether the machine was changed or not.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String {
        return LoginItem.setEnabled(enabled)
    }

    /// Makes the machine match the switch.
    ///
    /// The switch is the truth: the agent is in place when it is on, and gone
    /// when it is off. And the app is a login item when there is no agent to
    /// start it - the two are never both there, or the app would be started
    /// twice at the login.
    ///
    /// This is done at every start of the app, so that a switch that was
    /// turned somewhere else - by hand, or by an older version of the app -
    /// does not leave a machine in a state that nobody asked for.
    static func sync() {
        _ = LoginItem.applyToSystem(LoginItem.isEnabled)
    }

    /// Whether the agent is in place.
    static var isInstalled: Bool {
        let manager = FileManager.default
        return manager.fileExists(atPath: UpstreamWait.agentPlistURL().path)
            && manager.fileExists(atPath: UpstreamWait.scriptURL().path)
    }

    // MARK: - installing

    /// Puts the agent in place and tells launchd about it.
    static func install() throws {
        let manager = FileManager.default
        let home = FileManager.default.homeDirectoryForCurrentUser

        // the folders the agent needs. The folder of the log has to be there
        // before the agent is loaded: launchd opens the files of the log
        // before it runs the script, and it fails when the folder is not
        // there yet.
        try manager.createDirectory(at: UpstreamWait.supportFolderURL(home: home),
                                    withIntermediateDirectories: true)
        try manager.createDirectory(at: home.appendingPathComponent("Library/LaunchAgents"),
                                    withIntermediateDirectories: true)
        try manager.createDirectory(at: home.appendingPathComponent("Library/Logs/ProxiRoute"),
                                    withIntermediateDirectories: true)

        // the script that starts the app at the login
        let script = UpstreamWait.scriptText(home: home)
        try script.write(to: UpstreamWait.scriptURL(home: home), atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o755],
                                   ofItemAtPath: UpstreamWait.scriptURL(home: home).path)
        // the script of the build before this one is taken away, so that
        // nothing of it is left behind
        try? manager.removeItem(at: UpstreamWait.supportFolderURL(home: home)
            .appendingPathComponent(UpstreamWait.oldScriptName))

        // the agent itself
        let plist = UpstreamWait.agentDictionary(home: home)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let plistURL = UpstreamWait.agentPlistURL(home: home)

        // The agent is only taken out and put in again when the file really
        // changed.
        //
        // The app puts the agent in place at every start of the app, and the
        // agent is what starts the app: taking the agent out takes the app
        // with it when the app is the program of the agent. So an agent that
        // is already the one that is wanted is left alone.
        //
        // A file that is not there yet, or one that is not the one that is
        // wanted, is written and the agent is loaded again: launchd does not
        // load a second one under the same name, so the one that is there is
        // taken out first.
        let existing = (try? Data(contentsOf: plistURL)) ?? Data()
        if existing != data {
            try data.write(to: plistURL, options: .atomic)
            _ = runLaunchctl(["bootout", "gui/\(getuid())/\(UpstreamWait.agentLabel)"])
        }
        if existing != data || !isLoaded() {
            _ = runLaunchctl(["enable", "gui/\(getuid())/\(UpstreamWait.agentLabel)"])
            let result = runLaunchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
            if result.status != 0 {
                let reason = result.errorText.isEmpty ? "launchctl said nothing" : result.errorText
                throw NSError(domain: "com.sdpong.ProxiRoute.launchAgent", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: reason])
            }
        }
    }

    /// Takes the agent out.
    ///
    /// The files go as well, so that nothing of it is left behind. The login
    /// items of the system are not touched: the app is the one that registers
    /// itself there, and it does that on its own.
    static func uninstall() {
        let manager = FileManager.default
        _ = runLaunchctl(["bootout", "gui/\(getuid())/\(UpstreamWait.agentLabel)"])
        var urls = [UpstreamWait.agentPlistURL(), UpstreamWait.scriptURL()]
        urls.append(UpstreamWait.supportFolderURL().appendingPathComponent(UpstreamWait.oldScriptName))
        for url in urls {
            try? manager.removeItem(at: url)
        }
    }

    // MARK: - whether the app should start at the login

    /// Writes down whether the app should start when the machine starts.
    ///
    /// The script of the agent reads this file. The switch in the window of
    /// the app is the truth, and the file is what the script can read before
    /// the app of this build is running.
    @discardableResult
    static func writeStartFlag(_ enabled: Bool) -> Bool {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: UpstreamWait.supportFolderURL(),
                                        withIntermediateDirectories: true)
            try (enabled ? "1" : "0").write(to: UpstreamWait.startFlagURL(), atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    // MARK: - the list of what to wait for

    /// Writes the list of the upstream that the agent has to wait for.
    ///
    /// The file is written every time the proxies or the rules change, so the
    /// agent of the next login waits for the upstream of then and not for the
    /// one of today.
    @discardableResult
    static func writeWaitFile(for endpoints: [UpstreamEndpoint]) -> Bool {
        let manager = FileManager.default
        let url = UpstreamWait.waitFileURL()
        do {
            try manager.createDirectory(at: UpstreamWait.supportFolderURL(),
                                        withIntermediateDirectories: true)
            let text = UpstreamWait.waitFileText(endpoints)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    // MARK: - launchctl

    /// Whether launchd knows the agent.
    ///
    /// The file of the agent can be the one that is wanted while the agent
    /// itself is not loaded - after the agent was taken out by hand, for
    /// example. The file is then of no use on its own: the agent has to be
    /// there.
    static func isLoaded() -> Bool {
        return runLaunchctl(["print", "gui/\(getuid())/\(UpstreamWait.agentLabel)"]).status == 0
    }

    /// The answer of launchctl: what it said and whether it was happy.
    private struct LaunchctlResult {
        let status: Int32
        let errorText: String
    }

    private static func runLaunchctl(_ arguments: [String]) -> LaunchctlResult {
        // launchctl says what went wrong on its error output.
        guard let answer = ToolRunner.run("/bin/launchctl", arguments, capture: .error) else {
            return LaunchctlResult(status: -1, errorText: "launchctl could not be started.")
        }
        return LaunchctlResult(status: answer.status,
                               errorText: answer.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
