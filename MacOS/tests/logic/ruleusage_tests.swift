// The programs the other rules already name, and how the picker uses that.
// Compiled as main.swift by run.sh.
import Foundation

var fails = 0
func t(_ name: String, _ got: Bool, _ expected: Bool) { if got != expected { fails += 1; print("FAIL", name) } }
func eq<T: Equatable>(_ name: String, _ got: T, _ expected: T) { if got != expected { fails += 1; print("FAIL", name) } }

// MARK: - the programs the other rules already name

let rules: [(id: String, name: String, processNames: String)] = [
    ("1", "work", "curl; Safari"),
    ("2", "play", "*chrome*"),
    ("3", "all", "*")
]

let used = RuleProgramUsage.usedPatterns(rules: rules, excluding: "9")
t("the name of a rule is taken", used.patterns.contains("curl"), true)
t("the name of another rule is taken", used.patterns.contains("safari"), true)
t("a wildcard is taken", used.patterns.contains("*chrome*"), true)
t("a rule that matches everything does not take a name", used.patterns.contains("*"), false)
t("the rule the editor is showing is left out",
  RuleProgramUsage.usedPatterns(rules: rules, excluding: "1").patterns.contains("curl"), false)
eq("the owner of a name is the rule it came from", used.ownerByPattern["curl"], "work")

eq("a program another rule names is used", RuleProgramUsage.isUsed(processName: "curl", bundleId: nil, used: used), true)
eq("the name is not case sensitive", RuleProgramUsage.isUsed(processName: "CURL", bundleId: nil, used: used), true)
eq("a program a wildcard catches is used", RuleProgramUsage.isUsed(processName: "Google Chrome", bundleId: nil, used: used), true)
eq("a program nobody names is free", RuleProgramUsage.isUsed(processName: "Firefox", bundleId: nil, used: used), false)
t("a bundle id another rule names is used",
  RuleProgramUsage.isUsed(processName: "Finder", bundleId: "com.apple.finder", used: UsedProcessPatterns(patterns: ["com.apple.finder"])), true)

if fails > 0 {
    print("\(fails) test(s) failed")
    exit(1)
}
print("rule usage tests passed")
