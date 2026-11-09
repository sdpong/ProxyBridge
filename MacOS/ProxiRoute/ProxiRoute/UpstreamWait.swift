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
    /// the label of the launch agent that runs the script at every login
    static let agentLabel = "com.sdpong.proxiroute.launch"
    /// the bundle id of the app
    static let bundleIdentifier = "com.sdpong.ProxiRoute"
    /// the name of the process of the app, as it is written in the terminal
    static let processName = "ProxiRoute"
    /// the environment variable that tells the app that the agent started it,
    /// and that it should stay out of the way instead of showing its window
    static let startHiddenVariable = "PROXIRoute_START_HIDDEN"
    /// how long the script watches the upstream, in seconds
    ///
    /// The script does not hold the start of the app - the app starts at the
    /// login - it only writes down when the upstream answered, so that the
    /// order can be seen afterwards. The watch is over after a minute, because
    /// the order is only of interest right after the login.
    static let scriptWaitLimit = 60

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
        let waitFile = waitFileURL(home: home).path
        let startFlag = startFlagURL(home: home).path
        let log = logURL(home: home).path
        let logFolder = (log as NSString).deletingLastPathComponent
        return """
        #!/bin/sh
        # Starts ProxiRoute at the login, before the browsers and the other
        # apps that use the network.
        #
        # macOS starts every login item at the same moment, and nothing in the
        # system settings says that one of them comes before another one. This
        # script is that order: the launch agent that runs it starts at the
        # login, and it starts the app as soon as it is there.
        #
        # The app does not take the traffic of the machine over before the
        # upstream proxy on this machine answers - it waits for that on its
        # own - so the machine keeps its network while the wait is on.
        #
        # The list of what the app waits for is written by the app. It is used
        # here to write the order down, so that it can be seen afterwards.

        WAIT_FILE="\(waitFile)"
        START_FLAG="\(startFlag)"
        APP_PATH="\(appPath)"
        BUNDLE="\(bundleIdentifier)"
        LOG="\(log)"
        LIMIT=\(scriptWaitLimit)

        mkdir -p "\(logFolder)" 2>/dev/null

        say() {
            echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG" 2>/dev/null
        }

        say "the agent started"

        # Does the app want to start at all? The switch in the app of the
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

        # The app is already running. There is nothing to start.
        if pgrep -x "\(processName)" > /dev/null 2>&1; then
            say "the app is already running"
            exit 0
        fi

        say "starting the app"
        if [ -d "$APP_PATH" ]; then
            open -g "$APP_PATH"
        else
            open -g -b "$BUNDLE"
        fi
        say "the app was started"

        # The order is written down: the app is started, and the upstream of
        # this machine answers a moment later. The app waits for the upstream
        # by itself before it takes the traffic over.
        if [ -f "$WAIT_FILE" ]; then
            while read -r host port; do
                [ -z "$host" ] && continue
                DEADLINE=$(($(date +%s) + LIMIT))
                while :; do
                    if nc -z -G 1 "$host" "$port" > /dev/null 2>&1; then
                        say "the upstream $host:$port is ready"
                        break
                    fi
                    if [ "$(date +%s)" -ge "$DEADLINE" ]; then
                        say "the upstream $host:$port did not answer in $LIMIT seconds"
                        break
                    fi
                    sleep 0.5
                done
            done < "$WAIT_FILE"
        fi

        say "the agent is done"

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
