import Foundation

// The programs the other rules already name, and the ones the rule being
// edited has already. The picker uses this to show what is taken, so that a
// program does not end up in two rules by accident.
enum RuleProgramUsage {

    // the entries of the rule being edited, lowercased, for the exact match
    // that hides a program from the picker
    static func exactEntries(_ text: String) -> Set<String> {
        Set(RulePatternValidator.entries(text, separators: RulePatternValidator.programSeparators)
            .map { $0.text.lowercased() })
    }

    // the three things a rule can name a program by: the executable name, the
    // bundle id and the full path
    static func identityValues(_ process: RunningProcess) -> [String] {
        var values = [process.name]
        if let bundleId = process.bundleId, !bundleId.isEmpty { values.append(bundleId) }
        if !process.path.isEmpty { values.append(process.path) }
        return values
    }

    // Is this program already in the list of the rule being edited? The match
    // is exact, on the name, the bundle id or the full path. A wildcard in the
    // rule does not hide the program: it still catches it at the matcher, so
    // the user may well want to name it plainly as well.
    static func isInCurrentRule(_ process: RunningProcess, current: Set<String>) -> Bool {
        guard !current.isEmpty else { return false }
        for value in identityValues(process) {
            if current.contains(value.lowercased()) { return true }
        }
        return false
    }

    // the pattern of a rule that is in effect that already names this program
    static func enabledPattern(_ process: RunningProcess, index: RuleNameIndex) -> String? {
        return RulePatternMatch.programPattern(name: process.name,
                                               bundleId: process.bundleId ?? "",
                                               path: process.path,
                                               entries: index.enabledEntries)
    }

    // the pattern of a rule that is switched off that names this program
    static func disabledPattern(_ process: RunningProcess, index: RuleNameIndex) -> String? {
        return RulePatternMatch.programPattern(name: process.name,
                                               bundleId: process.bundleId ?? "",
                                               path: process.path,
                                               entries: index.disabledEntries)
    }

    // the rule that names an entry, for the badge next to it
    static func owner(of pattern: String, index: RuleNameIndex, enabled: Bool) -> String? {
        if enabled { return index.enabledOwner[pattern] }
        return index.disabledOwner[pattern]
    }
}
