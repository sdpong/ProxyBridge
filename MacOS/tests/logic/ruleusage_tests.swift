// What the other rules name, and how the picker and the editor use that.
// Compiled as main.swift by run.sh.
import Foundation

var fails = 0
func t(_ name: String, _ got: Bool, _ expected: Bool) { if got != expected { fails += 1; print("FAIL", name) } }
func eq<T: Equatable>(_ name: String, _ got: T, _ expected: T) { if got != expected { fails += 1; print("FAIL", name) } }

// MARK: - the index of what the other rules name

let sources = [
    RuleNameSource(id: "1", name: "work", entries: "curl; Safari", enabled: true),
    RuleNameSource(id: "2", name: "play", entries: "*chrome*", enabled: true),
    RuleNameSource(id: "3", name: "all", entries: "*", enabled: true),
    RuleNameSource(id: "4", name: "old", entries: "Firefox; example.com", enabled: false)
]

let index = RuleNameIndexBuilder.build(sources, separators: RulePatternValidator.programSeparators)

t("the name of a rule that is in effect is taken", index.enabledEntries.contains("curl"), true)
t("the name of another rule that is in effect is taken", index.enabledEntries.contains("safari"), true)
t("a wildcard of a rule that is in effect is taken", index.enabledEntries.contains("*chrome*"), true)
t("a rule that matches everything does not take a name", index.enabledEntries.contains("*"), false)
t("a rule that is switched off takes nothing away", index.enabledEntries.contains("firefox"), false)
t("but the name is remembered", index.disabledEntries.contains("firefox"), true)
eq("the owner of a name is the rule it came from", index.enabledOwner["curl"], "work")
eq("the owner of a name of a rule that is off", index.disabledOwner["firefox"], "old")

let withoutOne = RuleNameIndexBuilder.build(sources,
                                            separators: RulePatternValidator.programSeparators,
                                            excluding: "1")
t("the rule the editor is showing is left out", withoutOne.enabledEntries.contains("curl"), false)
t("the other rules are still there", withoutOne.enabledEntries.contains("*chrome*"), true)

// MARK: - a program another rule names

let curl = RunningProcess(pid: 1, name: "curl", path: "/usr/bin/curl", bundleId: nil, uid: 0)
let chrome = RunningProcess(pid: 2, name: "Google Chrome", path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", bundleId: "com.google.Chrome", uid: 0)
let safari = RunningProcess(pid: 3, name: "Safari", path: "/Applications/Safari.app/Contents/MacOS/Safari", bundleId: "com.apple.Safari", uid: 0)
let firefox = RunningProcess(pid: 4, name: "Firefox", path: "/Applications/Firefox.app/Contents/MacOS/firefox", bundleId: "org.mozilla.firefox", uid: 0)

eq("a program a rule that is in effect names is taken",
   RuleProgramUsage.enabledPattern(curl, index: index), "curl")
eq("the name is not case sensitive",
   RuleProgramUsage.enabledPattern(RunningProcess(pid: 5, name: "CURL", path: "/usr/bin/curl", bundleId: nil, uid: 0), index: index), "curl")
eq("a program a wildcard catches is taken",
   RuleProgramUsage.enabledPattern(chrome, index: index), "*chrome*")
eq("a bundle id a rule names is taken",
   RuleProgramUsage.enabledPattern(safari, index: index), "safari")
eq("a program nobody names is free",
   RuleProgramUsage.enabledPattern(RunningProcess(pid: 6, name: "Preview", path: "/System/Applications/Preview.app/Contents/MacOS/Preview", bundleId: "com.apple.Preview", uid: 0), index: index), nil)
eq("a rule that is switched off does not take a program away",
   RuleProgramUsage.enabledPattern(firefox, index: index), nil)
eq("but the rule that is switched off is remembered",
   RuleProgramUsage.disabledPattern(firefox, index: index), "firefox")

// a rule that names the full path takes that program
let byPath = RuleNameIndexBuilder.build(
    [RuleNameSource(id: "9", name: "full", entries: "/usr/bin/curl", enabled: true)],
    separators: RulePatternValidator.programSeparators)
eq("a full path in a rule names the program",
   RuleProgramUsage.enabledPattern(curl, index: byPath), "/usr/bin/curl")

// MARK: - the programs the rule being edited already has

let current = RuleProgramUsage.exactEntries("curl; com.apple.Safari")

t("a program the rule already names is hidden",
  RuleProgramUsage.isInCurrentRule(curl, current: current), true)
t("the bundle id the rule already names hides the program",
  RuleProgramUsage.isInCurrentRule(safari, current: current), true)
t("a program the rule does not name is not hidden",
  RuleProgramUsage.isInCurrentRule(firefox, current: current), false)
t("a program nobody named is not hidden",
  RuleProgramUsage.isInCurrentRule(curl, current: []), false)

let byPathCurrent = RuleProgramUsage.exactEntries("/usr/bin/curl")
t("the full path the rule already names hides the program",
  RuleProgramUsage.isInCurrentRule(curl, current: byPathCurrent), true)

let byWildcard = RuleProgramUsage.exactEntries("*curl*")
t("a wildcard in the rule does not hide the program",
  RuleProgramUsage.isInCurrentRule(curl, current: byWildcard), false)

// MARK: - two rules naming the same thing

t("the same program is the same program",
  RulePatternMatch.sameProgram(pattern: "com.apple.Safari", entry: "com.apple.safari"), true)
t("a wildcard that catches the name is the same program",
  RulePatternMatch.sameProgram(pattern: "com.*", entry: "com.apple.Safari"), true)
t("the other way round is the same program too",
  RulePatternMatch.sameProgram(pattern: "com.apple.Safari", entry: "com.*"), true)
t("a rule that matches everything names nothing",
  RulePatternMatch.sameProgram(pattern: "*", entry: "Safari"), false)
t("two different programs are not the same program",
  RulePatternMatch.sameProgram(pattern: "curl", entry: "wget"), false)

t("the same host is the same host",
  RulePatternMatch.sameHost(pattern: "github.com", entry: "github.com"), true)
t("a wildcard covers the name it covers",
  RulePatternMatch.sameHost(pattern: "*.example.com", entry: "example.com"), true)
t("two different hosts are not the same host",
  RulePatternMatch.sameHost(pattern: "github.com", entry: "gitlab.com"), false)

// MARK: - the pattern of the other rule that names the entry

let hostIndex = RuleNameIndexBuilder.build(
    [RuleNameSource(id: "9", name: "web", entries: "github.com; *.example.com", enabled: true)],
    separators: RulePatternValidator.hostSeparators,
    keepRangesTogether: true)
eq("the host another rule names is found",
   RulePatternMatch.hostPattern(host: "github.com", entries: hostIndex.enabledEntries), "github.com")
eq("the host a wildcard covers is found",
   RulePatternMatch.hostPattern(host: "example.com", entries: hostIndex.enabledEntries), "*.example.com")
eq("a host nobody names is not found",
   RulePatternMatch.hostPattern(host: "gitlab.com", entries: hostIndex.enabledEntries), nil)

// MARK: - what a click in the editor lands on

let boxEntries = RulePatternValidator.entries("curl; *.zjtelecom.cn; example.com",
                                              separators: RulePatternValidator.programSeparators)
eq("the click lands on the entry it points at",
   RuleClickLookup.entry(at: 0, in: boxEntries)?.text, "curl")
eq("the click in the middle of an entry is still that entry",
   RuleClickLookup.entry(at: 3, in: boxEntries)?.text, "curl")
eq("the click lands on the entry after it",
   RuleClickLookup.entry(at: 7, in: boxEntries)?.text, "*.zjtelecom.cn")
eq("the click lands on the last entry",
   RuleClickLookup.entry(at: 30, in: boxEntries)?.text, "example.com")
eq("a click on the space between two entries is on nothing",
   RuleClickLookup.entry(at: 5, in: boxEntries)?.text, nil)
eq("a click past the end is on nothing",
   RuleClickLookup.entry(at: 500, in: boxEntries)?.text, nil)

let offIndex = RuleNameIndexBuilder.build(
    [RuleNameSource(id: "7", name: "spare", entries: "*.zjtelecom.cn", enabled: false)],
    separators: RulePatternValidator.programSeparators)
eq("the rule that is off that names the entry is found",
   RuleClickLookup.offOwner(for: boxEntries[1], names: offIndex, isHost: false), "spare")
eq("a rule that is off that names nothing else is not found",
   RuleClickLookup.offOwner(for: boxEntries[0], names: offIndex, isHost: false), nil)
eq("a rule that is in effect is not a warning",
   RuleClickLookup.offOwner(for: boxEntries[1], names: index, isHost: false), nil)

let offHostIndex = RuleNameIndexBuilder.build(
    [RuleNameSource(id: "8", name: "web", entries: "*.example.com", enabled: false)],
    separators: RulePatternValidator.hostSeparators,
    keepRangesTogether: true)
let hostEntries = RulePatternValidator.entries("example.com",
                                               separators: RulePatternValidator.hostSeparators,
                                               keepRangesTogether: true)
eq("the rule that is off that names the host is found",
   RuleClickLookup.offOwner(for: hostEntries[0], names: offHostIndex, isHost: true), "web")
eq("a host is not looked up as a program",
   RuleClickLookup.offOwner(for: hostEntries[0], names: offHostIndex, isHost: false), nil)

if fails > 0 {
    print("\(fails) test(s) failed")
    exit(1)
}
print("rule usage tests passed")
