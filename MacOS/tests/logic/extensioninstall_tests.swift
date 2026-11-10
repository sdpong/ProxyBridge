import Foundation

// Whether the signature of this build carries a team id.
//
// The app does not decide anything with this answer: the extension is asked
// for in every case, and the system is the one that decides whether it takes
// it. What the answer is for is the notice in the window, and for telling the
// two reasons of a silent system apart.
//
// A build signed by a developer has a team id. A build signed ad hoc has
// none.
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

// a build with a team id has one
check("a build with a team id has one",
      ExtensionDiagnosis.hasTeamIdentifier("B8HN38M7A7"))
check("a build with a team id has one, whatever the team is",
      ExtensionDiagnosis.hasTeamIdentifier("TEAMID1234"))

// a build without a team id has none
check("a build without a team id has none",
      !ExtensionDiagnosis.hasTeamIdentifier(nil))
check("a build with an empty team id has none",
      !ExtensionDiagnosis.hasTeamIdentifier(""))

// the probe reads the team id of the running code
//
// The test binary is ad-hoc signed - it is built by swiftc and signed with a
// signature that has no team - so the probe has to say that there is none. If
// this ever runs from a signed build, the assertion is about the probe and
// not about the environment: a team id is either there or it is not, and an
// empty one is not a team id.
let team = ExtensionDiagnosis.teamIdentifier()
check("the probe never returns an empty team id", !(team?.isEmpty ?? false))
check("the probe and the decision agree",
      ExtensionDiagnosis.hasTeamIdentifier(team) == (team != nil))

// The extension is not asked for again when it is already in the system.
//
// Asking again does not update the record that is there: macOS makes a new
// one and the old one goes on its way out, and the network configuration of
// the app can end up bound to the record that goes. Then macOS says "the VPN
// app used by this configuration is not installed" and nothing is proxied.
func readAppFile(_ name: String) -> String {
    let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PROXIRoute_APP"] ?? "")
        .appendingPathComponent(name)
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}
let viewModelSource = readAppFile("ProxiRouteViewModel.swift")
check("the app asks macOS for the extension through one place",
      viewModelSource.contains("func requestExtensionIfNeeded()"))
check("the app looks at what the system has before it asks for the extension",
      viewModelSource.contains("InstalledExtension.query"))
check("the app still asks macOS for the extension when it is not there",
      viewModelSource.contains("submitExtensionActivationRequest()"))

// The tunnel is repaired by itself when macOS bound it to an extension that
// is gone. The person is only asked to run a command when that did not work.
check("the saved network configuration is removed and written again",
      viewModelSource.contains("TunnelRepair.removeSavedConfigurations(extensionIdentifier: self.extensionIdentifier)"))
check("the repair of the configuration is tried before the person is asked",
      viewModelSource.contains("if !self.tunnelRepairTried {"))

// The extension that is installed is not replaced when it is this build's.
//
// With the developer mode of the system turned on, macOS asks the app on
// every request whether the extension that is installed may be replaced. The
// app used to say yes every time, and every start of the app installed a new
// copy and marked the previous one as "terminated waiting to uninstall on
// reboot". The records piled up, and the tunnel of the app was bound to a
// record that was on its way out.
check("the extension that is installed is replaced only when it is another build",
      viewModelSource.contains("if existing.bundleVersion == ext.bundleVersion"))
check("the extension of this build is not replaced by itself",
      viewModelSource.contains("return .cancel"))
check("the cancellation of the app is not treated as a failure",
      viewModelSource.contains("OSSystemExtensionError.requestCanceled"))

// The command that takes the old records out does not ask for a password.
//
// "systemextensionsctl uninstall" answers the user who runs it. That was
// measured on this machine: the command answers "Success", exits with 0, and
// the records are gone from the system, without a password and without root.
// The old command asked for one, and the old script refused to run without
// one - which sent people to an administrator for something the app can do by
// itself.
let removalCommand = ExtensionDiagnosis.removeOldExtensionsCommand
check("the command that takes the old records out does not ask for a password",
      !removalCommand.contains("sudo"))
check("the command that takes the old records out is the one of the system",
      removalCommand.contains("systemextensionsctl") || removalCommand.contains("remove-old-extensions"))

// the script that ships with the app says the same thing
let scriptSource = readAppFile("../scripts/remove-old-extensions.sh")
check("the script does not insist on root", !scriptSource.contains("This needs root"))
check("the script does not tell the reader to use sudo", !scriptSource.contains("sudo $0"))

// The old records are not touched on every start.
//
// Taking a record out of the system takes the record that is in use with it:
// the tool of the system cannot take out one record of a bundle id, only all
// of them. So cleaning up on every start would be a new record and a new
// configuration every time - the pile-up that is being fixed here.
let startupFunction = viewModelSource.components(separatedBy: "private func requestExtensionIfNeeded()").last?
    .components(separatedBy: "private func submitExtensionActivationRequest()").first ?? ""
check("the records are not taken out on every start of the app",
      !startupFunction.contains("ExtensionCleanup.removeOldRecords"))
check("the app still asks macOS for the extension when it is not there",
      startupFunction.contains("submitExtensionActivationRequest()"))
check("the app starts the tunnel when the extension is already there",
      startupFunction.contains("self.startProxy()"))

// The repair path is the one that takes the records out, and it installs the
// extension again right after.
let repairFunction = viewModelSource.components(separatedBy: "private func tunnelStartFailed").last?
    .components(separatedBy: "func stopProxy(completion:").first ?? ""
check("the repair takes the old records out of the system",
      repairFunction.contains("ExtensionCleanup.removeOldRecords()"))
check("the repair writes the network configuration again",
      repairFunction.contains("TunnelRepair.removeSavedConfigurations(extensionIdentifier: self.extensionIdentifier)"))
check("the repair installs the extension again",
      repairFunction.contains("self.installAndStartProxy()"))
check("the repair is tried once", repairFunction.contains("if !self.tunnelRepairTried {"))

// After a cleanup the extension has to go into the system again, so the
// answer to "may it be replaced" is yes.
check("after a cleanup the extension goes into the system again",
      viewModelSource.contains("if extensionCleanedUp {"))
check("after a cleanup the answer is to replace it",
      viewModelSource.contains("extensionCleanedUp = false\n            return .replace"))

// The notice about a build without a team id says what is known
//
// The texts are checked in english: the key of a translation is the english
// text itself, and a string that has no translation stays english. So the
// notice is asked for in english first, and then in chinese, and the two are
// compared.
L10n.language = .english
let summary = ExtensionDiagnosis.unsignedBuildSummary()
check("the summary names the signature", summary.contains("not signed by a developer"))
check("the summary says what to look at when the tunnel does not come up",
      summary.contains("tunnel"))
let explanation = ExtensionDiagnosis.unsignedBuildExplanation()
check("the explanation has paragraphs", explanation.count >= 3)
check("the explanation says what it costs",
      explanation.contains { $0.contains("What that costs") })
check("the explanation says what works anyway",
      explanation.contains { $0.contains("proxy server") })
check("the explanation says what it takes",
      explanation.contains { $0.contains("Developer ID") })

// the notice does not claim that the extension cannot run
//
// The extension of this app does run on this machine, ad-hoc signature and
// all: the unified log of the 8th of November shows it working, asking for
// its container every few seconds and answering the app. So the notice says
// what the signature is, and it does not say that the extension is refused.
check("the summary does not say that the extension cannot run",
      !summary.contains("will not run"))
check("the explanation does not say that the extension cannot run",
      !explanation.contains { $0.contains("do not answer at all") })

// every text of the notice is translated
L10n.language = .chinese
check("the summary is translated", ExtensionDiagnosis.unsignedBuildSummary() != summary)
for paragraph in explanation {
    check("a paragraph of the explanation is translated",
          !ExtensionDiagnosis.unsignedBuildExplanation().contains(paragraph))
}

if fails > 0 {
    print("\(fails) check(s) failed")
    exit(1)
}
print("all checks passed")
