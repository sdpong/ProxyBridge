import Foundation

// Taking the old records of the system extension out of the system.
//
// The point of this: the records can be taken out without a password and
// without root. The script that ships with the app and the notice in the
// window both said that root was needed, and both were wrong.
//
// Compiled as main.swift by run.sh.

var fails = 0
func check(_ name: String, _ ok: Bool) {
    if ok {
        print("  ok   \(name)")
    } else {
        fails += 1
        print("FAIL \(name)")
    }
}

// the list of the system, as the tool prints it
let list = """
enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
*\t*\t-\tcom.sdpong.proxiroute.extension (4.1.2/8)\tProxiRoute 扩展\t[activated enabled]
\t\t-\tcom.sdpong.proxiroute.extension (4.1.2/8)\tProxiRoute 扩展\t[terminated waiting to uninstall on reboot]
*\t*\t287TTNZF8L\tio.nekohasekai.sfavt.system (1.12.0-beta.28/1)\tSFMExtension\t[activated enabled]
*\t*\tNXELXU5YLW\tcom.initex.proxifier.v3.macos.ProxifierExtension (3.15.0/3.15.0)\tProxifierExtension\t[activated enabled]
"""

// the team id of the records of the extension of this app
let teams = ExtensionCleanup.teamIdentifiers(for: "com.sdpong.proxiroute.extension",
                                             listPath: "systemextensionsctl",
                                             run: { _ in list })
check("the team id of an ad-hoc record is a dash", teams == ["-"])
check("the team id is found once", teams.count == 1)

// the team id of a record that was signed by a developer
let signedList = """
enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
*\t*\tB8HN38M7A7\tcom.sdpong.proxiroute.extension (4.1.2/8)\tProxiRoute\t[activated enabled]
"""
let signedTeams = ExtensionCleanup.teamIdentifiers(for: "com.sdpong.proxiroute.extension",
                                                    listPath: "systemextensionsctl",
                                                    run: { _ in signedList })
check("the team id of a signed record is the team of the record",
      signedTeams == ["B8HN38M7A7"])

// a record of another app is not ours
check("the records of the other apps are not ours",
      ExtensionCleanup.teamIdentifiers(for: "com.sdpong.proxiroute.extension",
                                       listPath: "systemextensionsctl",
                                       run: { _ in list }) == ["-"])
check("the records of an app that is not there have no team id",
      ExtensionCleanup.teamIdentifiers(for: "com.example.nothing",
                                       listPath: "systemextensionsctl",
                                       run: { _ in list }).isEmpty)

// the bundle ids of the project are the four of them
check("the project has four bundle ids", ExtensionCleanup.bundleIdentifiers.count == 4)
check("the extension of this app is one of them",
      ExtensionCleanup.bundleIdentifiers.contains("com.sdpong.proxiroute.extension"))
check("the older names are among them",
      ExtensionCleanup.bundleIdentifiers.contains("com.interceptsuite.ProxyBridge.extension"))

// the tool of the system is where it is
check("the tool of the system is where it is",
      ExtensionCleanup.toolPath == "/usr/bin/systemextensionsctl")

if fails == 0 {
    print("extension cleanup tests: ALL PASS")
} else {
    print("extension cleanup tests: \(fails) FAILED")
    exit(1)
}
