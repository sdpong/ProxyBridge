import Foundation

// The tests of the installation of the helper of the gateway mode.
//
// The scripts of the installation are run as root, so the text of them is
// checked here: the things they have to do, and the one thing they must
// never do.
//
// The one thing they must never do is turn the filter of the machine off.
// The switch of the filter belongs to the person who owns the machine: the
// helper puts rules in and takes them out, but it never touches the switch,
// so that installing ProxiRoute cannot break what the machine had.

func check(_ condition: Bool, _ what: String) {
    if condition {
        print("  ok   \(what)")
    } else {
        print("  FAIL \(what)")
        exit(1)
    }
}

// ---------------------------------------------------------------- the words

print("gateway installer tests:")

// a path with a quote in it does not break the words of the shell
check(GatewayInstaller.shellQuoted("/Applications/ProxiRoute.app") == "'/Applications/ProxiRoute.app'",
      "a path is put in single quotes")
check(GatewayInstaller.shellQuoted("/Applications/It's ProxiRoute.app") == "'/Applications/It'\\''s ProxiRoute.app'",
      "a quote inside a path is closed, escaped and opened again")

// a command with a quote in it does not break the words of AppleScript
check(GatewayInstaller.appleQuoted("echo \"hi\"") == "\"echo \\\"hi\\\"\"",
      "the quotes inside a command are escaped")
check(GatewayInstaller.appleQuoted("a\\b") == "\"a\\\\b\"",
      "the backslashes inside a command are doubled")

// ---------------------------------------------------------------- the installation

print("gateway install script tests:")

let install = GatewayInstaller.installScript(appPath: "/Applications/ProxiRoute.app")

// the helper and its daemon are put in place, with the ownership the system
// expects of a program of root
check(install.contains("cp -f \"$SRC_TOOLS\" \"$TOOLS\""), "the helper is copied into the privileged helper tools")
check(install.contains("chown root:wheel \"$TOOLS\""), "the helper belongs to root")
check(install.contains("chmod 755 \"$TOOLS\""), "the helper may be run by the system")
check(install.contains("cp -f \"$SRC_DAEMON\" \"$DAEMON\""), "the daemon is copied into the launch daemons")
check(install.contains("chmod 644 \"$DAEMON\""), "the daemon is a text file")
check(install.contains("launchctl bootstrap system \"$DAEMON\""), "the daemon is registered with the system")

// the app the helper comes from is the one that is asked for
check(install.contains("APP='/Applications/ProxiRoute.app'"), "the app the helper comes from is the one that is named")

// the machine is put back before the helper comes in: a helper of an earlier
// version may have left rules behind
let restore = install.range(of: "pfctl -f /etc/pf.conf")
let register = install.range(of: "launchctl bootstrap")
check(restore != nil, "the rules of the machine go back before the helper comes in")
check(register != nil, "the daemon is registered")
if let restore = restore, let register = register {
    check(restore.lowerBound < register.lowerBound,
          "the rules of the machine go back before the daemon is registered")
}

// the filter of the machine is never turned off
check(!install.contains("pfctl -d"), "the installation never turns the filter of the machine off")

// the installation says so when the helper did not come up
check(install.contains("if [ ! -S \"/var/run/$NAME.sock\" ]"), "the installation checks that the helper came up")

// ---------------------------------------------------------------- the removal

print("gateway uninstall script tests:")

let uninstall = GatewayInstaller.uninstallScript()

// the helper and its daemon go away
check(uninstall.contains("rm -f \"$TOOLS\""), "the helper is taken out of the machine")
check(uninstall.contains("rm -f \"$DAEMON\""), "the daemon is taken out of the system")
check(uninstall.contains("rm -f \"/var/run/$NAME.sock\""), "the socket of the helper is taken away")

// the machine goes back the way it was
check(uninstall.contains("pfctl -f /etc/pf.conf"), "the rules of the machine go back")
check(uninstall.contains("sysctl -w net.inet.ip.forwarding=0"), "the forwarding of the machine goes off")

// the filter of the machine is never turned off
check(!uninstall.contains("pfctl -d"), "the removal never turns the filter of the machine off")

// the removal says so when the helper is still there
check(uninstall.contains("if [ -f \"$TOOLS\" ] || [ -f \"$DAEMON\" ]"), "the removal checks that the helper is gone")

// the daemon goes out of the system before the helper is taken away: a helper
// that is still running would put the rules back while they are being taken
// away
let bootout = uninstall.range(of: "launchctl bootout")
let remove = uninstall.range(of: "rm -f \"$TOOLS\"")
check(bootout != nil, "the daemon goes out of the system")
check(remove != nil, "the helper is taken out")
if let bootout = bootout, let remove = remove {
    check(bootout.lowerBound < remove.lowerBound,
          "the daemon goes out of the system before the helper is taken away")
}

print("gateway installer tests: ALL PASS")
