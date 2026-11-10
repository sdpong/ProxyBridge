import Foundation

// Waiting for the upstream that runs on this machine.
//
// The order in which the things on a Mac start is not something a person can
// set. The login items all start at the same moment, and the system does not
// say which one comes first, so an app that needs another app to be ready
// cannot count on being started after it.
//
// The way out of it is to wait. The proxies that the rules of this app point
// to are looked at, and the ones that run on this machine - Clash Meta on
// 127.0.0.1, for example - are waited for before the traffic of this machine
// is taken over.
//
// Taking the traffic over before the upstream is there is worse than not
// taking it over at all: every connection of the machine would go to a port
// that nothing answers on, and the machine would be without a network.
//
// The list of what to wait for is written into a small file, and a launch
// agent reads it at every login. The agent starts the app when the port
// answers, so the app itself comes up right behind the upstream.
//
// This file holds the parts that are pure: what a local host is, what the
// file says, what the script says and what the agent says. The code that
// waits and the code that installs the agent are in the files next to it.

/// An upstream proxy that the rules of the app point to.
struct UpstreamEndpoint: Hashable {
    let host: String
    let port: Int

    /// the way it is written in the log and in the file
    var text: String { "\(host):\(port)" }
}

enum UpstreamWait {
    /// the file that tells the waiting script what to wait for
    static let waitFileName = "wait-for.txt"
    /// the script that starts the app at the login
    ///
    /// The name of the script of the build before this one: it is taken away
    /// when the agent is put in place, so that nothing of it is left behind.
    static let oldScriptName = "start-after-upstream.sh"
    /// the script that starts the app at the login
    static let scriptName = "start-at-login.sh"
    /// the file that says whether the app should start at all
    static let startFlagName = "start-at-login.txt"
    /// the file that says that the app was already started in this session
    ///
    /// The agent comes back every 20 seconds until the app is there (see
    /// agentRetryInterval). When the person closes the app afterwards, the
    /// agent must not bring it back: closing it means that the proxy is
    /// wanted no more. The marker is what says so, and it carries the
    /// session of the login - the time the console was logged in - so that
    /// it is of no use at the next login.
    static let sessionMarkerName = "agent-started.txt"
    /// the label of the launch agent that runs the script at every login
    static let agentLabel = "com.sdpong.proxiroute.launch"
    /// the bundle id of the app
    static let bundleIdentifier = "com.sdpong.ProxiRoute"
    /// the name of the process of the app, as it is written in the terminal
    static let processName = "ProxiRoute"
    /// the environment variable that tells the app that the agent started it,
    /// and that it should stay out of the way instead of showing its window
    static let startHiddenVariable = "PROXIRoute_START_HIDDEN"
    /// the environment variable that carries the login session of the machine
    ///
    /// The script of the agent reads it out of the system - the time the
    /// console was logged in - and hands it to the app, which writes it into
    /// the marker. The next run of the script compares the marker with the
    /// session of the machine: the same session means that the agent already
    /// started the app and that the person closed it again, and a different
    /// one means that this is a new login.
    static let sessionVariable = "PROXIRoute_SESSION"
    /// how long the script waits for the network of the machine, in seconds
    ///
    /// The network of the machine comes up a moment after the login: the
    /// Wi-Fi has to associate and the addresses have to be handed out. An app
    /// that is started before that is an app that starts into a machine
    /// without a network, and the tunnel it puts up cannot carry anything.
    ///
    /// The wait is not long: a machine whose network never comes up would
    /// otherwise never start the proxy.
    static let scriptNetworkLimit = 120
    /// how often the agent comes back, in seconds
    ///
    /// The agent is started by the system at every login, but the system does
    /// not always run it: for the first seconds of the login the domain of the
    /// user is in the on-demand-only mode, and the job that is pending there
    /// can be dropped. It was measured on this machine: the job was spawned
    /// at 11:18:50 and the script never ran - nothing was written down and
    /// the app was not there until it was started by hand.
    ///
    /// So the agent comes back every 20 seconds. The script is quick when
    /// there is nothing to do: it sees that the app is running, or that the
    /// agent already started it in this session, and it is gone again.
    ///
    /// The interval does not fight the app that is running: launchd skips an
    /// interval while the job is running ("If the job is running during an
    /// interval firing, that interval firing will likewise be missed").
    static let agentRetryInterval = 20

    // MARK: - the hosts of this machine

    /// Whether the host is on this machine.
    ///
    /// A proxy on this machine is not ready when the machine starts: it is
    /// ready when the other app is up. A proxy somewhere else is ready as
    /// soon as the network is, and there is nothing to wait for.
    static func isLocalHost(_ host: String) -> Bool {
        let text = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.isEmpty { return false }
        // the names that always mean this machine
        if text == "localhost" || text == "localhost.localdomain" { return true }
        if text == "::1" || text == "[::1]" { return true }
        // the address that means every address, including this machine
        if text == "0.0.0.0" || text == "::" { return true }
        // 127.0.0.0/8 is this machine and nothing else
        if text.hasPrefix("127.") {
            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            if parts.count == 4,
               parts.allSatisfy({ part in
                   guard let number = Int(part) else { return false }
                   return number >= 0 && number <= 255
               }) {
                return true
            }
        }
        return false
    }

    /// The endpoints that are on this machine, each one only once.
    static func localEndpoints(_ endpoints: [UpstreamEndpoint]) -> [UpstreamEndpoint] {
        var seen = Set<UpstreamEndpoint>()
        var out: [UpstreamEndpoint] = []
        for endpoint in endpoints where isLocalHost(endpoint.host) {
            if seen.insert(endpoint).inserted {
                out.append(endpoint)
            }
        }
        return out
    }

    /// The endpoints of this machine, in the order of how much they carry.
    ///
    /// Only the ones that run on this machine are waited for, and each one of
    /// them only once. The one that the most rules use comes first: the
    /// start of the proxy waits for that one, and an upstream that carries
    /// three rules out of twenty-six does not hold up the whole proxy
    /// because it is not up yet.
    ///
    /// The ones with the same number of rules keep the order they came in.
    static func orderedLocalEndpoints(_ usage: [(endpoint: UpstreamEndpoint, rules: Int)]) -> [UpstreamEndpoint] {
        var seen = Set<UpstreamEndpoint>()
        var kept: [(endpoint: UpstreamEndpoint, rules: Int)] = []
        for item in usage where isLocalHost(item.endpoint.host) {
            guard seen.insert(item.endpoint).inserted else { continue }
            kept.append(item)
        }
        let numbered = kept.enumerated().map {
            (rules: $0.element.rules, order: $0.offset, endpoint: $0.element.endpoint)
        }
        return numbered.sorted { left, right in
            if left.rules != right.rules { return left.rules > right.rules }
            return left.order < right.order
        }.map { $0.endpoint }
    }

    // MARK: - the file

    /// What the file says: one line for every endpoint, the host and the port.
    static func waitFileText(_ endpoints: [UpstreamEndpoint]) -> String {
        guard !endpoints.isEmpty else { return "" }
        return endpoints.map { "\($0.host) \($0.port)" }.joined(separator: "\n") + "\n"
    }

    /// The endpoints that are in the file.
    ///
    /// A line that says nothing usable is skipped and not guessed at: the file
    /// is written by the app, but a person can change it, and a wrong port
    /// would make the app wait for something that is never there.
    static func endpoints(fromWaitFile text: String) -> [UpstreamEndpoint] {
        var out: [UpstreamEndpoint] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2,
                  let port = Int(parts[1]),
                  port > 0, port < 65536 else { continue }
            let host = String(parts[0]).trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty else { continue }
            out.append(UpstreamEndpoint(host: host, port: port))
        }
        return out
    }

    // MARK: - the places of the files

    /// the folder of the app in the home of the user
    static func supportFolderURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        return home.appendingPathComponent("Library/Application Support/ProxiRoute")
    }

    /// the file that tells the script what to wait for
    static func waitFileURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        return supportFolderURL(home: home).appendingPathComponent(waitFileName)
    }

    /// the script that starts the app when the upstream is ready
    static func scriptURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        return supportFolderURL(home: home).appendingPathComponent(scriptName)
    }

    /// the agent that runs the script at every login
    static func agentPlistURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        return home.appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    /// the file that says whether the app should start at the login
    static func startFlagURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        return supportFolderURL(home: home).appendingPathComponent(startFlagName)
    }

    /// what the marker says when the person closed the app
    ///
    /// The marker carries the session of the login, and this is what is put
    /// behind it when the app is closed by the person: the agent reads it and
    /// leaves the app alone.
    static let quitSuffix = "|quit"

    /// the file that says that the agent already started the app in this session
    static func sessionMarkerURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        return supportFolderURL(home: home).appendingPathComponent(sessionMarkerName)
    }

    /// Writes down that the agent started the app in this session.
    ///
    /// The agent comes back every 20 seconds until the app is there, and the
    /// person may close the app afterwards. Closing it means that the proxy
    /// is wanted no more, so the agent must not bring it back.
    ///
    /// The session is what the script of the agent handed over. It is the
    /// time the console was logged in, and it is what tells this login from
    /// the next one: the marker of a session that is over is of no use.
    /// Writes down that the app was started in this session.
    ///
    /// The agent comes back every 20 seconds until the app is there, and the
    /// person may close the app afterwards. Closing it means that the proxy
    /// is wanted no more, so the agent must not bring it back.
    ///
    /// The session is what the script of the agent handed over. It is the
    /// time the console was logged in, and it is what tells this login from
    /// the next one: the marker of a session that is over is of no use.
    ///
    /// The marker says two things, and the difference between them is what
    /// the agent needs:
    ///
    ///   - the app was started in this session. The agent starts it again
    ///     when it is not there: an app that died is a proxy that is not
    ///     there, and the person did not ask for that.
    ///   - the app was closed by the person (the quit suffix). The agent
    ///     leaves it alone: closing it means that the proxy is wanted no
    ///     more.
    @discardableResult
    static func writeSessionMarker(session: String,
                                   quit: Bool = false,
                                   home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let manager = FileManager.default
        let session = session.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !session.isEmpty else { return false }
        let text = quit ? session + quitSuffix : session
        do {
            try manager.createDirectory(at: supportFolderURL(home: home),
                                        withIntermediateDirectories: true)
            try text.write(to: sessionMarkerURL(home: home), atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// The session of the login, as the agent of the launch found it.
    ///
    /// The script of the agent reads it out of the system - the time the
    /// console was logged in - and hands it over in the environment. The app
    /// writes it into the marker, so that the next run of the script knows
    /// that this session has been served already.
    ///
    /// When the app is started by hand there is no agent and no environment
    /// variable, and the session is read out of the system again. Both give
    /// the same answer, and the marker means the same thing either way.
    static func currentSession() -> String {
        let given = ProcessInfo.processInfo.environment[sessionVariable]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !given.isEmpty { return given }
        return consoleSession()
    }

    /// The time the console was logged in, as the system writes it.
    ///
    /// The line of the console user of "who" is the one that is wanted: it
    /// says when this login began, and the system writes it the same way
    /// every time it is asked. A machine that was not logged in yet has no
    /// console user, and then there is no session to tell.
    static func consoleSession() -> String {
        guard let output = outputOfWho() else { return "" }
        for line in output.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 5, parts[1] == "console" else { continue }
            return parts[2...4].joined(separator: " ")
        }
        return ""
    }

    /// The output of "who", or nothing when it cannot be run.
    private static func outputOfWho() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/who")
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// what the script writes down
    static func logURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        return home.appendingPathComponent("Library/Logs/ProxiRoute/start-at-login.log")
    }

    // MARK: - the script

    /// The script that starts the app at the login.
    ///
    /// It is a plain shell script and not a program of the app: it has to run
    /// at every login, before the app is there, and it has to run even when
    /// the app of this build is not installed any more.
    ///
    /// The script starts the app and does not wait for anything. The order
    /// that a person asked for is this: the proxy of the machine comes up
    /// before the browsers and before the other apps that use the network.
    /// The upstream proxy on this machine - Clash Meta, for example - is a
    /// thing of its own: the app waits for it before it takes the traffic
    /// over, and that wait is inside the app, where the rules are known.
    static func scriptText(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                           appPath: String = "/Applications/ProxiRoute.app") -> String {
        let startFlag = startFlagURL(home: home).path
        let marker = sessionMarkerURL(home: home).path
        let log = logURL(home: home).path
        let logFolder = (log as NSString).deletingLastPathComponent
        let appBinary = (appPath as NSString).appendingPathComponent("Contents/MacOS/ProxiRoute")
        return """
        #!/bin/sh
        # Starts ProxiRoute at the login, before the browsers and the other
        # apps that use the network.
        #
        # macOS starts every login item at the same moment, and nothing in the
        # system settings says that one of them comes before another one. This
        # script is that order: the launch agent that runs it starts at the
        # login, and it starts the app as soon as the network of the machine
        # is there.
        #
        # The app does not take the traffic of the machine over before the
        # upstream proxy on this machine answers - it waits for that on its
        # own - so the machine keeps its network while the wait is on.
        #
        # The order is written down here, so that it can be seen afterwards:
        # the log of the agent and the log of the app are the same file.

        START_FLAG="\(startFlag)"
        MARKER="\(marker)"
        APP_PATH="\(appPath)"
        APP_BINARY="\(appBinary)"
        BUNDLE="\(bundleIdentifier)"
        LOG="\(log)"
        NETWORK_LIMIT=\(scriptNetworkLimit)

        mkdir -p "\(logFolder)" 2>/dev/null

        say() {
            echo "$(/bin/date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG" 2>/dev/null
        }

        say "the agent started"

        # Does the app want to start at all? The switch in the window of the
        # person says it, and the file is written by the app.
        if [ -f "$START_FLAG" ]; then
            read -r want < "$START_FLAG"
            if [ "$want" != "1" ]; then
                say "the app should not start at the login"
                exit 0
            fi
        else
            say "the file that says to start at the login is not there"
            exit 0
        fi

        # The session of the login.
        #
        # The time the console was logged in tells this login from the next
        # one, and the system writes it the same way every time it is asked.
        # It is handed over to the app, which writes it into the marker.
        SESSION=$(/usr/bin/who 2>/dev/null | /usr/bin/awk '$2 == "console" { print $3, $4, $5; exit }')

        # The app is already running. There is nothing to start.
        if pgrep -x "\(processName)" > /dev/null 2>&1; then
            say "the app is already running"
            exit 0
        fi

        # The person closed the app in this session. It is not started again:
        # closing it means that the proxy is wanted no more.
        #
        # An app that was started and that died is a different thing: the
        # marker of it says that it was started and not that it was closed,
        # and the agent starts it again - a proxy that is not there is a
        # proxy that the person asked for.
        if [ -n "$SESSION" ] && [ -f "$MARKER" ]; then
            MARKED=$(/bin/cat "$MARKER" 2>/dev/null)
            if [ "$MARKED" = "$SESSION|quit" ]; then
                say "the app was started in this session and was closed again"
                exit 0
            fi
        fi

        # The network of the machine has to be there before the app is
        # started.
        #
        # The network comes up a moment after the login: the Wi-Fi has to
        # associate and the addresses have to be handed out. An app that is
        # started before that is an app that starts into a machine without a
        # network, and the tunnel it puts up cannot carry anything.
        #
        # The wait is for the network of the system and not for the apps that
        # provide a network: Clash Meta, Tailscale and the others are a thing
        # of their own, and the order between them and ProxiRoute does not
        # matter.
        say "waiting for the network of the machine"
        DEADLINE=$(($(/bin/date +%s) + NETWORK_LIMIT))
        while :; do
            if /sbin/route -n get default > /dev/null 2>&1; then
                say "the network of the machine is up"
                break
            fi
            if /usr/sbin/scutil --nwi 2>/dev/null | /usr/bin/grep -q "address"; then
                say "the network of the machine is up (it has an address, no default route)"
                break
            fi
            if [ "$(/bin/date +%s)" -ge "$DEADLINE" ]; then
                say "the network of the machine did not come up in $NETWORK_LIMIT seconds, the app is started anyway"
                break
            fi
            /bin/sleep 0.25
        done

        # The app may have come up while we were waiting for the network.
        if pgrep -x "\(processName)" > /dev/null 2>&1; then
            say "the app is running now"
            exit 0
        fi

        # The app is started directly and not through "open".
        #
        # At the login the system is busy with the other login items, and
        # "open" puts the request in that queue: the app came up seconds
        # after everything else, and the traffic of the first minutes went
        # out without it. The binary is started here instead, so that the app
        # is there right away.
        if [ -x "$APP_BINARY" ]; then
            say "the app is started now"
            # The app goes into a group of its own ("set -m"), so that it is
            # not taken down with the agent.
            #
            # The app puts the agent in place again when it starts, and an
            # agent that is taken out takes the app with it when the app is
            # the program of the agent. The group of its own keeps the app
            # out of that. It was measured: without it the app is gone with
            # the agent, with it the app stays.
            set -m
            PROXIRoute_SESSION="$SESSION"
            export PROXIRoute_SESSION
            "$APP_BINARY" &
            APP_PID=$!
            set +m
            # The agent stays until the app is gone.
            #
            # A program that is only put in the background is killed when
            # the script is gone - that was measured - so the agent has to
            # be there to keep the app alive.
            while kill -0 "$APP_PID" 2>/dev/null; do
                /bin/sleep 2
            done
            say "the app is gone"
            exit 0
        fi

        # The binary is not there: the app is started through the system after
        # all. It is slower, but it is better than not starting at all.
        say "the binary of the app is not there, it is started through the system"
        if [ -d "$APP_PATH" ]; then
            open -g "$APP_PATH"
        else
            open -g -b "$BUNDLE"
        fi
        say "the app was started"

        """
    }

    // MARK: - the agent

    /// The agent that runs the script at every login.
    ///
    /// It is an agent of the user and not of the system: it lives in the
    /// folder of the launch agents of the user, so it needs no password and
    /// no root, and it goes away when the user throws it out.
    static func agentDictionary(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                appPath: String = "/Applications/ProxiRoute.app") -> [String: Any] {
        return [
            "Label": agentLabel,
            "ProgramArguments": ["/bin/sh", scriptURL(home: home).path],
            "RunAtLoad": true,
            // The system does not always run the agent at the login: the
            // domain of the user is in the on-demand-only mode for the first
            // seconds of the login, and the job that is pending there can be
            // dropped. It was measured on this machine: the job was spawned
            // and the script never ran. So the agent comes back until the app
            // is there - and launchd skips an interval while the job is
            // running, so the app that is running is never disturbed.
            "StartInterval": agentRetryInterval,
            "ProcessType": "Background",
            // the app is told that the agent started it, so that it stays in
            // the menu bar instead of showing its window right after the login
            "EnvironmentVariables": [startHiddenVariable: "1"],
            "WorkingDirectory": supportFolderURL(home: home).path,
            "StandardOutPath": logURL(home: home).path,
            "StandardErrorPath": logURL(home: home).path
        ]
    }
}
