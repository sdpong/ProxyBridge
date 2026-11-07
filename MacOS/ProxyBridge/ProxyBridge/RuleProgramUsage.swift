import Foundation

// The programs another rule already names. The picker uses this to show what
// is taken, so that a program is not put in two rules by accident.
struct UsedProcessPatterns {
    var patterns: Set<String> = []
    var ownerByPattern: [String: String] = [:]

    var isEmpty: Bool { patterns.isEmpty }
}

enum RuleProgramUsage {

    // the patterns of every rule but the one being edited
    static func usedPatterns(
        rules: [(id: String, name: String, processNames: String)],
        excluding id: String
    ) -> UsedProcessPatterns {
        var used = UsedProcessPatterns()
        for rule in rules where rule.id != id {
            let entries = RulePatternValidator.entries(rule.processNames, separators: RulePatternValidator.programSeparators)
            for entry in entries {
                let key = entry.text.lowercased()
                // a rule that matches every program does not take a name away
                // from the other rules, otherwise nothing could be picked at all
                if key == "*" { continue }
                used.patterns.insert(key)
                if used.ownerByPattern[key] == nil {
                    used.ownerByPattern[key] = rule.name.isEmpty ? "another rule" : rule.name
                }
            }
        }
        return used
    }

    // the pattern of another rule that already names this program
    static func matchingPattern(processName: String, bundleId: String?, used: UsedProcessPatterns) -> String? {
        let name = processName.lowercased()
        let bundle = bundleId?.lowercased()
        for pattern in used.patterns.sorted() {
            if pattern == name { return pattern }
            if let bundle = bundle, pattern == bundle { return pattern }
            if pattern.contains("*") {
                if RulePatternValidator.globMatch(pattern, name) { return pattern }
                if let bundle = bundle, RulePatternValidator.globMatch(pattern, bundle) { return pattern }
            }
        }
        return nil
    }

    // is this program already named by another rule?
    static func isUsed(processName: String, bundleId: String?, used: UsedProcessPatterns) -> Bool {
        return matchingPattern(processName: processName, bundleId: bundleId, used: used) != nil
    }
}
