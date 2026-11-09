import Foundation

// The launch agent that starts the app when the upstream is ready.
//
// macOS has no order for the login items: they all start at the same moment,
// and nothing in the system settings says which one comes first. A launch
// agent is the way to bring an order back. It runs at every login, waits for
// the upstream proxy on this machine - Clash Meta, for example - and starts
// the app when the port answers.
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

    /// the key that says whether the agent is wanted
    static let enabledKey = "startAfterUpstream"

    /// whether the agent is wanted
    ///
    /// The agent is wanted from the start: the order of the start is the thing
    /// a proxy on this machine needs, and a person who wants a proxy does not
    /// want to look for a switch for it. When the agent cannot be put in
    /// place, the switch turns itself off and the app stays a login item, so
    /// that the proxy still comes up at the login.
    static var isEnabled: Bool {
        UserDefaults.standard.register(defaults: [enabledKey: true])
        return UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// Turns the agent on or off.
    ///
    /// The answer is given back in words, because the person has to know
    /// whether the machine was changed or not.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String {
        UserDefaults.standard.set(enabled, forKey: enabledKey)
        if enabled {
            do {
                try install()
                // The agent is the launcher now, so the app must not be a login
                // item as well. It is taken out right away and not at the next
                // start of the app: the app is started by hand most of the
                // time, and the next login would come before that.
                LoginItem.applyToSystem(LoginItem.isEnabled)
                return L10n.t("ProxiRoute will be started by macOS when the upstream proxy is ready.")
            } catch {
                UserDefaults.standard.set(false, forKey: enabledKey)
                // The agent could not be put in place, so the app has to be a
                // login item again, or the proxy would not come up at all.
                LoginItem.applyToSystem(LoginItem.isEnabled)
                return L10n.f("The launch agent could not be installed: %@", error.localizedDescription)
            }
        }
        uninstall()
        // The agent is gone, so the app goes back to being a login item - if
        // the person wants it to be one. Without this the app would stay out
        // of the login items until it is started by hand once, and a person
        // who quits it and restarts the machine would find no proxy.
        LoginItem.applyToSystem(LoginItem.isEnabled)
        return L10n.t("ProxiRoute will be started by macOS at the same time as the other login items again.")
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

        // the script that waits and starts the app
        let script = UpstreamWait.scriptText(home: home)
        try script.write(to: UpstreamWait.scriptURL(home: home), atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o755],
                                   ofItemAtPath: UpstreamWait.scriptURL(home: home).path)

        // the agent itself
        let plist = UpstreamWait.agentDictionary(home: home)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: UpstreamWait.agentPlistURL(home: home), options: .atomic)

        // tell launchd about it. The agent that is already there is taken out
        // first, because launchd does not load a second one under the same
        // name.
        _ = runLaunchctl(["bootout", "gui/\(getuid())/\(UpstreamWait.agentLabel)"])
        _ = runLaunchctl(["enable", "gui/\(getuid())/\(UpstreamWait.agentLabel)"])
        let result = runLaunchctl(["bootstrap", "gui/\(getuid())", UpstreamWait.agentPlistURL(home: home).path])
        if result.status != 0 {
            let reason = result.errorText.isEmpty ? "launchctl said nothing" : result.errorText
            throw NSError(domain: "com.sdpong.ProxiRoute.launchAgent", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: reason])
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
        for url in [UpstreamWait.agentPlistURL(), UpstreamWait.scriptURL()] {
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

    /// The answer of launchctl: what it said and whether it was happy.
    private struct LaunchctlResult {
        let status: Int32
        let errorText: String
    }

    private static func runLaunchctl(_ arguments: [String]) -> LaunchctlResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()
        do {
            try process.run()
        } catch {
            return LaunchctlResult(status: -1, errorText: error.localizedDescription)
        }
        let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        return LaunchctlResult(status: process.terminationStatus,
                               errorText: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
