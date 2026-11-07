// The rule editor's checks: a host that is in the list twice, two ip ranges
// that cover the same addresses, an address the matcher cannot read.
// Compiled as main.swift by run.sh.
import Foundation

var fails = 0
func t(_ name: String, _ got: Bool, _ expected: Bool) { if got != expected { fails += 1; print("FAIL", name) } }
func eq<T: Equatable>(_ name: String, _ got: T, _ expected: T) { if got != expected { fails += 1; print("FAIL", name) } }

// MARK: - splitting the text into entries

func hostEntries(_ text: String) -> [RulePatternEntry] {
    return RulePatternValidator.entries(text, separators: RulePatternValidator.hostSeparators, keepRangesTogether: true)
}
func programEntries(_ text: String) -> [RulePatternEntry] {
    return RulePatternValidator.entries(text, separators: RulePatternValidator.programSeparators)
}

eq("one line is one entry", hostEntries("github.com").count, 1)
eq("a line break separates entries", hostEntries("github.com\ngitlab.com").count, 2)
eq("a semicolon separates entries", hostEntries("github.com; gitlab.com").count, 2)
eq("a space separates hosts", hostEntries("github.com gitlab.com").count, 2)
eq("the spaces around an entry are not part of it", hostEntries("  github.com  ")[0].text, "github.com")
eq("an empty line is not an entry", hostEntries("github.com\n\ngitlab.com").count, 2)
eq("a space around the dash keeps the range in one piece", hostEntries("10.0.0.1 - 10.0.0.9").count, 1)
eq("the range keeps its spaces", hostEntries("10.0.0.1 - 10.0.0.9")[0].text, "10.0.0.1 - 10.0.0.9")
eq("a program name keeps its spaces", programEntries("Google Chrome Helper")[0].text, "Google Chrome Helper")
eq("programs are separated by a line break", programEntries("curl\nSafari").count, 2)
eq("programs are separated by a comma", programEntries("curl,Safari").count, 2)
eq("a program name is not split at a space", programEntries("Google Chrome Helper; curl").count, 2)

// MARK: - the same host twice

func hostProblems(_ text: String) -> [RulePatternEntry] {
    return RulePatternValidator.checkHosts(text)
}
func problemsOf(_ text: String, _ index: Int) -> [RulePatternProblem] {
    return hostProblems(text)[index].problems
}

t("a host that is twice is marked", problemsOf("github.com\ngithub.com", 0).contains(.duplicate), true)
t("both copies are marked", problemsOf("github.com\ngithub.com", 1).contains(.duplicate), true)
t("the same host in a different case is the same host", problemsOf("GitHub.com\ngithub.com", 0).contains(.duplicate), true)
t("two different hosts are not marked", problemsOf("github.com\ngitlab.com", 0).contains(.duplicate), false)
t("the catch-all twice is marked as a duplicate", problemsOf("*\n*", 0).contains(.duplicate), true)
t("a host that is not in the list is not marked", problemsOf("github.com", 0).contains(.duplicate), false)

// MARK: - a host that another host already covers

t("the apex is covered by the wildcard", problemsOf("*.github.com\ngithub.com", 1).contains(.redundant), true)
t("the wildcard is not covered by the apex", problemsOf("*.github.com\ngithub.com", 0).contains(.redundant), false)
t("a name is covered by a wildcard around it", problemsOf("*google*\ngoogle.com", 1).contains(.redundant), true)
t("the catch-all covers nothing that has to be marked", problemsOf("*\ngithub.com", 1).contains(.redundant), false)
t("two different names are not covered", problemsOf("github.com\ngitlab.com", 0).contains(.redundant), false)

// MARK: - two ip ranges that cover the same addresses

t("two ranges that overlap are marked", problemsOf("10.0.0.1-10.0.0.100\n10.0.0.50-10.0.0.200", 0).contains(.overlappingIP), true)
t("both ranges are marked", problemsOf("10.0.0.1-10.0.0.100\n10.0.0.50-10.0.0.200", 1).contains(.overlappingIP), true)
t("ranges that do not touch are not marked", problemsOf("10.0.0.1-10.0.0.100\n10.0.0.101-10.0.0.200", 0).contains(.overlappingIP), false)
t("an address inside a range is marked", problemsOf("10.0.0.1-10.0.0.100\n10.0.0.50", 0).contains(.overlappingIP), true)
t("an address inside a wildcard is marked", problemsOf("192.168.1.*\n192.168.1.7", 0).contains(.overlappingIP), true)
t("an address of another net is not marked", problemsOf("10.0.0.1-10.0.0.100\n192.168.1.7", 0).contains(.overlappingIP), false)
t("the same range twice is marked", problemsOf("10.0.0.1-10.0.0.100\n10.0.0.1-10.0.0.100", 0).contains(.overlappingIP), true)

// MARK: - addresses the matcher cannot read

t("a range that starts after it ends is marked", problemsOf("10.0.0.100-10.0.0.1", 0).contains(.invalidIPPattern), true)
t("cidr is marked", problemsOf("10.0.0.0/24", 0).contains(.unsupportedCIDR), true)
t("an address that is not one is marked", problemsOf("10.0.0.256", 0).contains(.invalidIPPattern), true)
t("a name that starts with a digit is a name", problemsOf("3com.com", 0).contains(.invalidIPPattern), false)
t("a name with a dash is a name", problemsOf("my-site.com", 0).contains(.invalidIPPattern), false)
t("an ipv6 prefix wildcard is read", problemsOf("2001:db8:*", 0).contains(.invalidIPPattern), false)
t("an ipv6 prefix with a shortcut is not read by the matcher", problemsOf("2001:db8::*", 0).contains(.invalidIPPattern), true)
t("an ipv6 range is read", problemsOf("fe80::1-fe80::ff", 0).contains(.invalidIPPattern), false)

// MARK: - programs

func programProblems(_ text: String) -> [RulePatternEntry] {
    return RulePatternValidator.checkPrograms(text)
}
t("a program that is twice is marked", programProblems("curl\ncurl")[0].problems.contains(.duplicate), true)
t("two programs are not marked", programProblems("curl\nSafari")[0].problems.contains(.duplicate), false)
t("a program name keeps its spaces in the check", programProblems("Google Chrome Helper\nGoogle Chrome Helper")[0].problems.contains(.duplicate), true)

// MARK: - the form a rule is stored in

eq("the stored form puts the entries in one line",
  RulePatternValidator.storedForm("github.com\ngitlab.com", separators: RulePatternValidator.hostSeparators, keepRangesTogether: true),
  "github.com; gitlab.com")
eq("the display form puts the entries on their own lines",
  RulePatternValidator.displayForm("github.com; gitlab.com", separators: RulePatternValidator.hostSeparators, keepRangesTogether: true),
  "github.com\ngitlab.com")
eq("the display form of a stored program list keeps the spaces in the names",
  RulePatternValidator.displayForm("Google Chrome Helper; curl", separators: RulePatternValidator.programSeparators),
  "Google Chrome Helper\ncurl")
eq("the stored form of a program list",
  RulePatternValidator.storedForm("curl\nSafari", separators: RulePatternValidator.programSeparators),
  "curl; Safari")

if fails > 0 {
    print("\(fails) test(s) failed")
    exit(1)
}
print("rule pattern tests passed")
