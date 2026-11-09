import Foundation

// Whether the app should ask the system to install its system extension.
//
// A build signed by a developer has a team id, and the system recognises the
// copy of the extension it already has: asking for it on every start leaves
// nothing behind.
//
// A build signed ad hoc has no team id, and the system cannot tell that the
// copy it is being asked for is the one it already has. Every start of the app
// leaves another record behind - all of them the same extension, and all of
// them waiting to be taken out at the next restart. Measured on this machine:
// six records after six starts.
//
// A build without a team id cannot run a network extension anyway: macOS does
// not validate the restricted entitlements of an ad-hoc signature, and the
// network extension APIs of the app do not answer at all. So asking is not
// worth a record per start.
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

// a build with a team id asks the system to install the extension
check("a build with a team id installs the extension",
      ExtensionDiagnosis.shouldInstallSystemExtension(teamIdentifier: "B8HN38M7A7"))
check("a build with a team id installs the extension, whatever the team is",
      ExtensionDiagnosis.shouldInstallSystemExtension(teamIdentifier: "TEAMID1234"))

// a build without a team id does not
check("a build without a team id does not install the extension",
      !ExtensionDiagnosis.shouldInstallSystemExtension(teamIdentifier: nil))
check("a build with an empty team id does not install the extension",
      !ExtensionDiagnosis.shouldInstallSystemExtension(teamIdentifier: ""))

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
      ExtensionDiagnosis.shouldInstallSystemExtension(teamIdentifier: team) == (team != nil))

// the notice about an unsigned build says what is lost and what is not
//
// The texts are checked in english: the key of a translation is the english
// text itself, and a string that has no translation stays english. So the
// notice is asked for in english first, and then in chinese, and the two are
// compared.
L10n.language = .english
let summary = ExtensionDiagnosis.unsignedBuildSummary()
check("the summary names the signature", summary.contains("not signed by a developer"))
check("the summary says that nothing is proxied", summary.contains("Nothing is proxied"))
let explanation = ExtensionDiagnosis.unsignedBuildExplanation()
check("the explanation has paragraphs", explanation.count >= 3)
check("the explanation says what still works",
      explanation.contains { $0.contains("What still works") })
check("the explanation says what is lost",
      explanation.contains { $0.contains("What does not") })
check("the explanation says what it takes",
      explanation.contains { $0.contains("Developer ID") })

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
