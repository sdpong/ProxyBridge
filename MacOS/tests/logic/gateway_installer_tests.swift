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

// the old daemon is gone before the new one is registered.
//
// The command that takes a daemon out returns before the system has finished
// with it, and a new daemon put in at that moment is refused with "Bootstrap
// failed: 5: Input/output error" - the system saying that it is busy. So the
// system is asked whether the old one is gone, and the answer is waited for.
let bootoutOfTheOld = install.range(of: "launchctl bootout")
let askAboutTheDaemon = install.range(of: "launchctl print \"system/$NAME\"")
check(bootoutOfTheOld != nil, "the daemon of an earlier version is taken out")
check(askAboutTheDaemon != nil, "the installation asks the system whether the daemon is gone")
if let bootoutOfTheOld = bootoutOfTheOld, let askAboutTheDaemon = askAboutTheDaemon {
    check(bootoutOfTheOld.lowerBound < askAboutTheDaemon.lowerBound,
          "the old daemon is taken out before the system is asked about it")
}

// the system is asked again when it refuses
check(install.contains("while [ $i -lt 6 ]"), "the installation asks the system again")
check(install.contains("if ! /bin/launchctl print \"system/$NAME\""),
      "the installation says so when the daemon did not come up")

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


// ---------------------------------------------------------------- the bundle

print("gateway helper bundle tests:")

// The helper travels inside the app bundle until the installer puts it where
// it belongs, and two paths take it from there: the install button of the app
// and the postinstall script of the package. A bundle without the helper in it
// cannot install the helper at all, so the bundle that ships has to carry it.
//
// The bundle is signed, and the signature covers the helper inside it. A
// second copy of the helper put into a signed bundle breaks the signature,
// and the system refuses to run an app with a broken signature. So the
// package takes the helper that is already in the bundle, and does not build
// another one.

let appFolder = scriptsFolder.deletingLastPathComponent()   // ProxiRoute

func readAt(_ url: URL) -> String {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
    return text
}

let buildScript = readAt(appFolder.appendingPathComponent("build.sh"))
let embedScript = readScript("embed-helper.sh")

check(!embedScript.isEmpty, "there is a script that puts the helper into the bundle")
check(embedScript.contains("\"$APP/Contents/Helpers/$HELPER_NAME\""),
      "the helper goes into the helpers folder of the bundle")
check(embedScript.contains("\"$APP/Contents/Resources/$HELPER_NAME.plist\""),
      "the daemon goes into the resources of the bundle")
check(embedScript.contains("adhoc-sign.sh"),
      "the bundle is signed again after the helper is put into it")
check(embedScript.contains("codesign --verify"),
      "the bundle is checked after the helper is put into it")

check(buildScript.contains("BUNDLED_HELPER=\"$APP_PATH/Contents/Helpers/$HELPER_NAME\""),
      "the package knows the helper that is inside the bundle")
check(buildScript.contains("if [ -x \"$BUNDLED_HELPER\" ]"),
      "the package uses the helper that is already inside the bundle")
check(buildScript.contains("BUNDLED_DAEMON=\"$APP_PATH/Contents/Resources/$HELPER_NAME.plist\""),
      "the package knows the daemon that is inside the bundle")
check(buildScript.contains("cp -f \"$HELPER_PATH\" \"$SCRIPT_DIR/build/component/Library/PrivilegedHelperTools/$HELPER_NAME\""),
      "the helper of the bundle goes into the payload of the package")
check(buildScript.contains("if [ \"$HELPER_PATH\" = \"$SCRIPT_DIR/output/$HELPER_NAME\" ]"),
      "the package only deletes the helper it built itself, never the one in the bundle")

// the install button of the app takes the helper out of those same two places
check(install.contains("SRC_TOOLS=\"$APP/Contents/Helpers/$NAME\""),
      "the app takes the helper out of the helpers folder of the bundle")
check(install.contains("SRC_DAEMON=\"$APP/Contents/Resources/$NAME.plist\""),
      "the app takes the daemon out of the resources of the bundle")


// ---------------------------------------------------------------- the switch

print("gateway switch tests:")

// The gateway mode needs the helper: it is the program of root that loads the
// rules of the filter and turns the forwarding of the machine on. Without it
// there is nobody to ask, so the switch is not offered at all.
check(!GatewayInstaller.canTurnOn(.notInstalled), "the gateway cannot be turned on without the helper")
check(GatewayInstaller.canTurnOn(.installed), "the gateway can be turned on when the helper is there")
check(GatewayInstaller.canTurnOn(.running), "the gateway can be turned on when the helper is running")

// A remembered "on" is only kept while the helper is on the machine. A switch
// that fails at every start of the app is a switch the person in front of it
// cannot get out of.
check(GatewayInstaller.initialGatewayState(stored: true, state: .running),
      "a remembered on is kept while the helper is there")
check(GatewayInstaller.initialGatewayState(stored: true, state: .installed),
      "a remembered on is kept while the helper is there")
check(!GatewayInstaller.initialGatewayState(stored: true, state: .notInstalled),
      "a remembered on is dropped when the helper is gone")
check(!GatewayInstaller.initialGatewayState(stored: false, state: .running),
      "a remembered off stays off")

print("gateway installer tests: ALL PASS")
