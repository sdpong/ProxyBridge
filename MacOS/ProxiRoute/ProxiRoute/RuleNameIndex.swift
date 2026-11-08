import Foundation

// What the other rules name.
//
// A rule that is in effect takes the name away: a program (or a host) that it
// already names cannot be put in a second rule, because the first rule that
// matches a flow takes the traffic and the other one looks busy while it does
// nothing. A rule that is switched off takes nothing away, it only deserves a
// warning, so the entries of the two kinds are kept apart.
struct RuleNameIndex {
    // the entries of the other rules that are in effect
    var enabledEntries: Set<String> = []
    // the entries of the other rules that are switched off
    var disabledEntries: Set<String> = []
    // which rule named an entry, so the badge can say so
    var enabledOwner: [String: String] = [:]
    var disabledOwner: [String: String] = [:]

    var isEmpty: Bool { enabledEntries.isEmpty && disabledEntries.isEmpty }
}

// One rule, as far as "what does it name" is concerned.
struct RuleNameSource {
    var id: String
    var name: String
    var entries: String
    var enabled: Bool
}

enum RuleNameIndexBuilder {
    // the entries of every rule but the one being edited, split by whether the
    // rule is in effect.
    //
    // "*" is left out on purpose: a rule that matches every program does not
    // take a name away from the other rules, otherwise nothing could be picked
    // at all once such a rule exists.
    static func build(_ sources: [RuleNameSource],
                      separators: CharacterSet,
                      keepRangesTogether: Bool = false,
                      excluding id: String = "") -> RuleNameIndex {
        var index = RuleNameIndex()
        for source in sources where source.id != id {
            let owner = source.name.isEmpty ? "another rule" : source.name
            let entries = RulePatternValidator.entries(source.entries,
                                                       separators: separators,
                                                       keepRangesTogether: keepRangesTogether)
            for entry in entries {
                let key = entry.text.lowercased()
                if key == "*" { continue }
                if source.enabled {
                    index.enabledEntries.insert(key)
                    if index.enabledOwner[key] == nil { index.enabledOwner[key] = owner }
                } else {
                    index.disabledEntries.insert(key)
                    if index.disabledOwner[key] == nil { index.disabledOwner[key] = owner }
                }
            }
        }
        return index
    }
}

// What the click in the editor lands on.
//
// The editor tells the app at which character the user pointed. The app has to
// work out which entry of the box that is, and whether a rule that is switched
// off already names it.
enum RuleClickLookup {
    // the entry the character sits in
    static func entry(at index: Int, in entries: [RulePatternEntry]) -> RulePatternEntry? {
        for entry in entries where NSLocationInRange(index, entry.range) {
            return entry
        }
        return nil
    }

    // the rule that is switched off and names this entry, if there is one
    static func offOwner(for entry: RulePatternEntry, names: RuleNameIndex, isHost: Bool) -> String? {
        let pattern = isHost
            ? RulePatternMatch.hostPattern(host: entry.text, entries: names.disabledEntries)
            : RulePatternMatch.programEntryPattern(entry: entry.text, entries: names.disabledEntries)
        guard let pattern = pattern else { return nil }
        return names.disabledOwner[pattern]
    }
}

// Whether a pattern of one rule names the same thing as an entry of another.
// The rules here are the ones the matcher in the extension uses, so that what
// the app says about a rule is what the extension does with it.
enum RulePatternMatch {

    // a program: a pattern with a slash in it is a full path, a pattern
    // without one is the executable name or the bundle id
    static func namesProgram(pattern: String, name: String, bundleId: String, path: String) -> Bool {
        let pattern = pattern.lowercased()
        if pattern == "*" { return false }
        if pattern.contains("/") || pattern.contains("\\") {
            guard !path.isEmpty else { return false }
            return RulePatternValidator.globMatch(pattern, path)
        }
        if RulePatternValidator.globMatch(pattern, name) { return true }
        if !bundleId.isEmpty && RulePatternValidator.globMatch(pattern, bundleId) { return true }
        return false
    }

    // a host: the same name, or a name a wildcard of the other rule covers
    static func sameHost(pattern: String, entry: String) -> Bool {
        let pattern = pattern.lowercased()
        let host = entry.lowercased()
        if pattern == "*" { return false }
        if pattern == host { return true }
        // "*.example.com" covers "example.com" as well, the matcher reads it
        // that way
        return RulePatternValidator.domainCovers(pattern, host)
    }

    // the entry of one rule and the pattern of another name the same program
    static func sameProgram(pattern: String, entry: String) -> Bool {
        let pattern = pattern.lowercased()
        let entry = entry.lowercased()
        if pattern == "*" || entry == "*" { return false }
        if pattern == entry { return true }
        // a wildcard that catches the plain name, in either direction
        if covers(pattern, entry) { return true }
        if covers(entry, pattern) { return true }
        return false
    }

    // does a wildcard catch a plain name? the plain glob of the matcher, so
    // "com.*" catches "com.apple.Safari" and "*.Safari" does not catch
    // "Safari"
    private static func covers(_ cover: String, _ other: String) -> Bool {
        guard cover.contains("*"), cover != "*", !other.contains("*") else { return false }
        return RulePatternValidator.globMatch(cover, other)
    }

    // the pattern of the index that names the program, if there is one
    static func programPattern(name: String,
                               bundleId: String,
                               path: String,
                               entries: Set<String>) -> String? {
        for pattern in entries.sorted() {
            if namesProgram(pattern: pattern, name: name, bundleId: bundleId, path: path) {
                return pattern
            }
        }
        return nil
    }

    // the pattern of the index that names the same host as the entry
    static func hostPattern(host: String, entries: Set<String>) -> String? {
        for pattern in entries.sorted() {
            if sameHost(pattern: pattern, entry: host) { return pattern }
        }
        return nil
    }

    // the pattern of the index that names the same program as the entry
    static func programEntryPattern(entry: String, entries: Set<String>) -> String? {
        for pattern in entries.sorted() {
            if sameProgram(pattern: pattern, entry: entry) { return pattern }
        }
        return nil
    }
}
