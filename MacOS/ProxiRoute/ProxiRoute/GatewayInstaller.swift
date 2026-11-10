import Foundation

// The installation of the helper of the gateway mode.
//
// The helper is a program of root, and putting it in place needs root. The
// app cannot be that program: an app that is signed ad hoc has no identity
// the system would trust to run something as root - SMJobBless needs a
// Developer ID and a team, and a fork has neither. So the app asks macOS for
// the privilege the way every other installer does: with the dialog of the
// administrator, which asks for the password of a person who is one.
//
// The scripts that do the work are written here, in the program, and not as
// files of their own. A file that lies next to the program can be changed by
// anybody who can write in the folder of the app, and a file that is changed
// and then run as root is root. The text of the script is in the signed
// program, so what runs is what was signed.
//
// The two scripts do the same things as the scripts of the package
// (scripts/postinstall and scripts/remove-gateway-helper.sh): the package is
// the way in without the app, and the app is the way in without the package.
enum GatewayInstaller {

    // Where the helper of the gateway mode lives on the machine.
    static let helperPath = "/Library/PrivilegedHelperTools/com.sdpong.proxiroute.helper"
    static let daemonPath = "/Library/LaunchDaemons/com.sdpong.proxiroute.helper.plist"

    // The name of the helper, the same in the launch daemon and in the log.
    static let helperName = "com.sdpong.proxiroute.helper"

    // Whether the helper is on the machine.
    enum State: Equatable {
        // there is no helper
        case notInstalled
        // the helper is there, but it does not answer
        case installed
        // the helper is there and it answers
        case running

        // whether the helper is on the machine at all
        var isInstalled: Bool { self != .notInstalled }
    }

    // What an installation did.
    struct Result {
        let ok: Bool
        let message: String
    }

    // Whether the helper is on the machine, and whether it answers.
    //
    // The file is looked at first: the folder of the privileged helper tools
    // can be read by anybody, so the answer does not need root. The answer of
    // the helper itself says whether the daemon is running.
    static func state() -> State {
        guard FileManager.default.fileExists(atPath: helperPath) else { return .notInstalled }
        // the daemon is what starts the helper: a helper without its daemon
        // is a helper that does not come back when the machine starts
        guard FileManager.default.fileExists(atPath: daemonPath) else { return .installed }
        return GatewayHelperClient.status().ok ? .running : .installed
    }

    // Whether the gateway mode can be turned on at all.
    //
    // The gateway mode needs the helper: it is the program of root that loads
    // the rules of the filter and turns the forwarding of the machine on.
    // Without it there is nobody to ask, so the switch is not offered.
    static func canTurnOn(_ state: State) -> Bool {
        return state.isInstalled
    }

    // The state the switch of the gateway mode starts in.
    //
    // A machine that was the gateway of its network stays that way when the
    // app is opened again - but only while the helper is there. A remembered
    // "on" without the helper is a switch that fails at every start of the
    // app, and there is nothing the person in front of it can do about it, so
    // it starts off.
    static func initialGatewayState(stored: Bool, state: State) -> Bool {
        return stored && state.isInstalled
    }

    // Puts the helper in place and starts it.
    //
    // The path of the app is needed: the helper travels inside the bundle
    // until the installer puts it where it belongs.
    static func install(appPath: String, completion: @escaping (Result) -> Void) {
        run(installScript(appPath: appPath), completion: completion)
    }

    // Takes the helper out of the machine and puts the machine back.
    static func uninstall(completion: @escaping (Result) -> Void) {
        run(uninstallScript(), completion: completion)
    }

    // MARK: - the scripts

    // The script that puts the helper in place.
    //
    // The order is the one of the removal, backwards: the machine goes back
    // the way it was first, then the old daemon is taken out of the system,
    // then the new one is put in and started. A helper of an earlier version
    // that left rules behind would otherwise keep the traffic of the network
    // being redirected to a port where nobody listens.
    static func installScript(appPath: String) -> String {
        return """
        APP=\(shellQuoted(appPath))
        NAME="\(helperName)"
        TOOLS="/Library/PrivilegedHelperTools/$NAME"
        DAEMON="/Library/LaunchDaemons/$NAME.plist"
        SRC_TOOLS="$APP/Contents/Helpers/$NAME"
        SRC_DAEMON="$APP/Contents/Resources/$NAME.plist"

        if [ ! -f "$SRC_TOOLS" ]; then
            echo "The app does not have the helper of the gateway mode in it."
            exit 1
        fi
        if [ ! -f "$SRC_DAEMON" ]; then
            echo "The app does not have the daemon of the helper in it."
            exit 1
        fi

        # The machine goes back the way it was before the helper comes in.
        # The switch of the filter itself is left alone: it was not ours to
        # begin with.
        /sbin/pfctl -f /etc/pf.conf >/dev/null 2>&1 || true
        /usr/sbin/sysctl -w net.inet.ip.forwarding=0 >/dev/null 2>&1 || true
        rm -f /var/run/com.sdpong.proxiroute.pf.rules /var/run/com.sdpong.proxiroute.pf.anchor

        # The daemon of an earlier version is taken out of the system first: it
        # is still running, and it holds the old socket.
        /bin/launchctl bootout "system/$NAME" >/dev/null 2>&1 || /bin/launchctl unload "$DAEMON" >/dev/null 2>&1 || true

        # The daemon is gone only when the system says so. The command that
        # takes it out returns before the system has finished with it, and a
        # new one put in at that moment is refused with "Bootstrap failed: 5:
        # Input/output error" - which is a way of saying that the system is
        # busy. So the system is asked, and the answer is waited for.
        i=0
        while [ $i -lt 30 ]; do
            if ! /bin/launchctl print "system/$NAME" >/dev/null 2>&1; then break; fi
            sleep 0.2
            i=$((i + 1))
        done

        # A helper that the system does not know about may still be running,
        # and it still holds the socket.
        #
        # The command above takes the daemon out of the system, and a daemon
        # that is not in the system is not found: a helper that something
        # started outside of the system keeps running, and the socket with
        # it. A new daemon cannot bind a socket that is taken, so it comes up
        # and falls over again, and the app talks to the old helper - which
        # is a helper of an earlier version, or a helper that cannot do what
        # it is asked to do. It is taken away, and the socket with it.
        if [ -S "/var/run/$NAME.sock" ]; then
            /usr/bin/pkill -f "$TOOLS" >/dev/null 2>&1 || true
            sleep 0.5
            rm -f "/var/run/$NAME.sock"
        fi

        mkdir -p /Library/PrivilegedHelperTools /Library/LaunchDaemons
        cp -f "$SRC_TOOLS" "$TOOLS" || { echo "The helper could not be copied."; exit 1; }
        chown root:wheel "$TOOLS" || { echo "The ownership of the helper could not be set."; exit 1; }
        chmod 755 "$TOOLS"
        cp -f "$SRC_DAEMON" "$DAEMON" || { echo "The daemon could not be copied."; exit 1; }
        chown root:wheel "$DAEMON" || { echo "The ownership of the daemon could not be set."; exit 1; }
        chmod 644 "$DAEMON"

        # The daemon is registered with the system, and the socket is waited
        # for: the app asks the helper right after the installation, and a
        # helper that is not up yet would say that it is not there.
        # The daemon is registered with the system. The system says "Input
        # output error" when it is asked twice in a row, so it is asked again
        # a few times before it is given up on.
        i=0
        while [ $i -lt 6 ]; do
            if /bin/launchctl bootstrap system "$DAEMON" >/dev/null 2>&1; then break; fi
            sleep 0.5
            i=$((i + 1))
        done
        if ! /bin/launchctl print "system/$NAME" >/dev/null 2>&1; then
            echo "The daemon of the helper could not be started."
            exit 1
        fi
        i=0
        while [ $i -lt 25 ]; do
            if [ -S "/var/run/$NAME.sock" ]; then break; fi
            sleep 0.2
            i=$((i + 1))
        done

        # The helper has to be really there: a daemon that is registered but
        # does not come up is not a helper, and the app would say that it is
        # not installed.
        if [ ! -S "/var/run/$NAME.sock" ]; then
            echo "The daemon of the helper was registered, but the helper did not come up."
            exit 1
        fi
        echo "The helper of the gateway mode is installed."
        """
    }

    // The script that takes the helper out of the machine.
    //
    // The order is the one of the installation, backwards: the daemon goes
    // out of the system first, then the machine goes back, and only then is
    // the helper taken away. A helper that is taken away while its rules are
    // in place leaves the traffic of the network being redirected to a port
    // where nobody listens, and that is a broken network.
    static func uninstallScript() -> String {
        return """
        NAME="\(helperName)"
        TOOLS="/Library/PrivilegedHelperTools/$NAME"
        DAEMON="/Library/LaunchDaemons/$NAME.plist"

        # The daemon goes out of the system first, so that it does not put the
        # rules back while they are being taken away.
        /bin/launchctl bootout "system/$NAME" >/dev/null 2>&1 || /bin/launchctl unload "$DAEMON" >/dev/null 2>&1 || true

        # A helper that the system does not know about is still running, and
        # it is still holding the socket. It is taken away as well: a helper
        # that is left behind answers the app while it is not there any more.
        /usr/bin/pkill -f "$TOOLS" >/dev/null 2>&1 || true
        sleep 0.5

        # The machine goes back the way it was: the rules of /etc/pf.conf are
        # the rules the system itself reads, and the forwarding goes off,
        # because the helper is the one that turned it on.
        /sbin/pfctl -f /etc/pf.conf >/dev/null 2>&1 || true
        /usr/sbin/sysctl -w net.inet.ip.forwarding=0 >/dev/null 2>&1 || true
        rm -f /var/run/com.sdpong.proxiroute.pf.rules /var/run/com.sdpong.proxiroute.pf.anchor

        rm -f "$TOOLS"
        rm -f "$DAEMON"
        rm -f "/var/run/$NAME.sock"

        # The helper has to be really gone: a file that could not be taken
        # away is a helper that is still there, and the app would say that it
        # is gone.
        if [ -f "$TOOLS" ] || [ -f "$DAEMON" ]; then
            echo "The helper of the gateway mode could not be taken out of the machine."
            exit 1
        fi

        echo "The helper of the gateway mode is gone and the rules of the machine are back."
        """
    }

    // MARK: - running it

    // Runs a command as root, with the dialog of the administrator.
    //
    // The answer comes back on the main queue: the window is what shows it.
    private static func run(_ command: String, completion: @escaping (Result) -> Void) {
        let script = "do shell script \(appleQuoted(command)) with administrator privileges"

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
            } catch {
                finish(completion, Result(ok: false,
                                          message: "The privilege could not be asked for: \(error.localizedDescription)"))
                return
            }
            // the dialog of the administrator is up until the password is
            // typed, so this waits for the person in front of the window
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""

            if process.terminationStatus == 0 {
                let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
                finish(completion, Result(ok: true, message: text.isEmpty ? "Done." : text))
            } else {
                finish(completion, Result(ok: false, message: reason(from: output)))
            }
        }
    }

    // The answer goes to the window.
    private static func finish(_ completion: @escaping (Result) -> Void, _ result: Result) {
        DispatchQueue.main.async {
            completion(result)
        }
    }

    // What the system said when it refused.
    //
    // The dialog of the administrator that was closed is not a failure of the
    // machine: it is a person who changed their mind, and it says so.
    private static func reason(from output: String) -> String {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("-128") || text.contains("User canceled") || text.contains("User cancelled") {
            return "The installation was cancelled."
        }
        if text.isEmpty {
            return "The installation did not work, and the system did not say why."
        }
        return text
    }

    // A text in the words of AppleScript.
    //
    // The text of the command is put in double quotes, so the double quotes
    // inside it are escaped, and the backslashes are doubled: what AppleScript
    // hands to the shell has to be the text that was written here.
    static func appleQuoted(_ text: String) -> String {
        var escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    // A text in the words of the shell.
    //
    // Single quotes keep everything as it is, and a single quote inside them
    // is closed, escaped and opened again.
    static func shellQuoted(_ text: String) -> String {
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
