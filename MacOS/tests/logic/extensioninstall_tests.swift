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

// the notice about a build without a team id says what is known
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
