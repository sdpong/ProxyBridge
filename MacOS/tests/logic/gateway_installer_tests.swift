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

// ---------------------------------------------------------------- the one place

print("gateway installer path tests:")

// The helper of the gateway mode lives in exactly two places on the machine,
// and every path into the gateway mode uses those same two: the package puts
// them there, the app puts them there with its own install button, and every
// way of taking it away takes them away from exactly these two.
//
// Why it matters: the receipt of the package only knows about the files that
// are in the payload of the package. A file that a script copies into
// /Library afterwards is not in the receipt, so taking the package away
// leaves a program of root behind, still running and still holding the
// machine changed.

let toolsPath = "/Library/PrivilegedHelperTools/com.sdpong.proxiroute.helper"
let daemonPath = "/Library/LaunchDaemons/com.sdpong.proxiroute.helper.plist"

check(GatewayInstaller.helperPath == toolsPath, "the helper lives in the privileged helper tools")
check(GatewayInstaller.daemonPath == daemonPath, "the daemon lives in the launch daemons")

// the install script of the app puts them in those places
check(install.contains("TOOLS=\"\(toolsPath)\"") || install.contains("TOOLS=\"/Library/PrivilegedHelperTools/$NAME\""),
      "the installation puts the helper in the privileged helper tools")
check(install.contains("DAEMON=\"\(daemonPath)\"") || install.contains("DAEMON=\"/Library/LaunchDaemons/$NAME.plist\""),
      "the installation puts the daemon in the launch daemons")

// and the removal takes them away from exactly those places
check(uninstall.contains("TOOLS=\"/Library/PrivilegedHelperTools/$NAME\""),
      "the removal knows where the helper is")
check(uninstall.contains("DAEMON=\"/Library/LaunchDaemons/$NAME.plist\""),
      "the removal knows where the daemon is")
check(uninstall.contains("rm -f \"$TOOLS\""), "the removal takes the helper away from that place")
check(uninstall.contains("rm -f \"$DAEMON\""), "the removal takes the daemon away from that place")

// the scripts of the package use the same two places
//
// The folder of the scripts is given by the environment, because the test is
// compiled in a temporary folder: a path derived from the place of this file
// would point at the temporary folder and nowhere else.
let scriptsFolder: URL
if let fromEnvironment = ProcessInfo.processInfo.environment["PROXIRoute_SCRIPTS"] {
    scriptsFolder = URL(fileURLWithPath: fromEnvironment)
} else {
    scriptsFolder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // logic
        .deletingLastPathComponent()   // tests
        .deletingLastPathComponent()   // ProxiRoute
        .appendingPathComponent("scripts")
}

func readScript(_ name: String) -> String {
    let url = scriptsFolder.appendingPathComponent(name)
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
    return text
}

let postinstall = readScript("postinstall")
let removeScript = readScript("remove-gateway-helper.sh")

check(postinstall.contains("HELPER_TOOLS=\"/Library/PrivilegedHelperTools/$HELPER_NAME\""),
      "the package installs the helper in the privileged helper tools")
check(postinstall.contains("HELPER_DAEMON=\"/Library/LaunchDaemons/$HELPER_NAME.plist\""),
      "the package installs the daemon in the launch daemons")
check(removeScript.contains("HELPER_TOOLS=\"/Library/PrivilegedHelperTools/$HELPER_NAME\""),
      "the removal script knows where the helper is")
check(removeScript.contains("HELPER_DAEMON=\"/Library/LaunchDaemons/$HELPER_NAME.plist\""),
      "the removal script knows where the daemon is")

// the daemon of the system starts the helper from that place, so the place
// has to be the one the package puts it in
let daemonPlist = readScript("com.sdpong.proxiroute.helper.plist")
check(daemonPlist.contains("<string>\(toolsPath)</string>"),
      "the daemon starts the helper from the place it is installed in")

print("gateway installer tests: ALL PASS")
