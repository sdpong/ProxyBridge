import Foundation
import SystemExtensions

// Whether the app asks macOS for its system extension again.
//
// The rule: it asks when the extension of this build is not in the system,
// and it does not ask when it is.
//
// Why it matters: asking again does not update the record that is already
// there. macOS makes a new one, under a new folder in
// /Library/SystemExtensions, and the old one is marked "terminated waiting
// to uninstall on reboot". The records pile up, and the network
// configuration of the app can end up bound to one that is on its way out,
// so macOS says "the VPN app used by this configuration is not installed" and
// nothing is proxied.
//
// The state comes from macOS itself, through the request that asks for the
// properties of the installed extensions. That request changes nothing.
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

// The answer of macOS is turned into the answer of the app.
//
// The turning is what the app relies on, so it is what is checked here. The
// properties of macOS are read-only, so the judgement about a record is
// what is checked, and the answer of the app is built out of it.
func information(current: Int, stale: Int, total: Int) -> InstalledExtension.Information {
    var information = InstalledExtension.Information()
    information.isCurrent = current > 0
    information.hasStaleRecord = stale > 0
    information.recordCount = total
    return information
}

// the extension of this build is in the system and in use: no request
let onlyCurrent = information(current: 1, stale: 0, total: 1)
check("the extension of this build is in use: no request is needed",
      !onlyCurrent.needsActivationRequest)
check("the extension of this build is in use: it is the current one",
      onlyCurrent.isCurrent)
check("the extension of this build is in use: there is no old record",
      !onlyCurrent.hasStaleRecord)

// the extension is not in the system: the request is made
let missing = information(current: 0, stale: 0, total: 0)
check("the extension is not in the system: the request is made",
      missing.needsActivationRequest)

// the extension is there but it is on its way out: the request is made
let uninstalling = information(current: 0, stale: 1, total: 1)
check("the extension is on its way out: the request is made",
      uninstalling.needsActivationRequest)
check("the extension is on its way out: it is an old record",
      uninstalling.hasStaleRecord)

// this build is in use and an old record is on its way out: no request
let both = information(current: 1, stale: 1, total: 2)
check("this build is in use and an old record is there: no request is needed",
      !both.needsActivationRequest)
check("this build is in use and an old record is there: the old record is seen",
      both.hasStaleRecord)
check("this build is in use and an old record is there: both are counted",
      both.recordCount == 2)

// the bundle id of the extension is the one the system knows
check("the bundle id of the extension is the one of the system",
      InstalledExtension.bundleIdentifier == "com.sdpong.proxiroute.extension")

// The judgement about a record of macOS.
//
// A record that is in use is enabled, is not waiting for the approval of the
// person and is not on its way out.
check("the record of the system is read as the one that is in use",
      InstalledExtension.isInUse(enabled: true, awaitingApproval: false, uninstalling: false))
check("a record that waits for the approval is not the one that is in use",
      !InstalledExtension.isInUse(enabled: true, awaitingApproval: true, uninstalling: false))
check("a record that is on its way out is not the one that is in use",
      !InstalledExtension.isInUse(enabled: false, awaitingApproval: false, uninstalling: true))
check("a record that is not enabled is not the one that is in use",
      !InstalledExtension.isInUse(enabled: false, awaitingApproval: false, uninstalling: false))

// The request, after the old records have been taken out of the system.
//
// This is the rule that was missing: taking the records out takes the record
// that is in use with them, because the tool of the system cannot take out
// one record of a bundle id, only all of them. So after a cleanup the
// extension is not in the system any more, and asking for it again is what
// puts it back. Skipping that ask is what left the app with no extension at
// all and no tunnel.
check("after a cleanup the extension is asked for again, even when it was in use",
      InstalledExtension.needsActivationRequest(isCurrent: true, hasStaleRecord: true, didCleanUp: true))
check("after a cleanup the extension is asked for again, even when nothing was stale",
      InstalledExtension.needsActivationRequest(isCurrent: true, hasStaleRecord: false, didCleanUp: true))
check("without a cleanup the extension that is in use is not asked for again",
      !InstalledExtension.needsActivationRequest(isCurrent: true, hasStaleRecord: false, didCleanUp: false))
check("without a cleanup an extension that is not there is asked for",
      InstalledExtension.needsActivationRequest(isCurrent: false, hasStaleRecord: false, didCleanUp: false))
check("without a cleanup a record on its way out does not make the app ask",
      !InstalledExtension.needsActivationRequest(isCurrent: true, hasStaleRecord: true, didCleanUp: false))

if fails == 0 {
    print("installed extension tests: ALL PASS")
} else {
    print("installed extension tests: \(fails) FAILED")
    exit(1)
}
