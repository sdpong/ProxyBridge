// L10n: the translations of the app.
//
// The test also goes through the sources of the app: every string the windows
// ask for has to be in the table, or it stays English without anyone noticing.
// Compiled as main.swift by run.sh.
import Foundation

var fails = 0
func t(_ name: String, _ ok: Bool) { if !ok { fails += 1; print("FAIL", name) } }

// english is english
t("english is the text itself", L10n.translate("Save", language: .english) == "Save")
// chinese is the translation
t("chinese is the translation", L10n.translate("Save", language: .chinese) == "保存")
// a string that has no translation is shown as it is written
t("a string without a translation stays as it is",
  L10n.translate("a string nobody translated", language: .chinese) == "a string nobody translated")

// a name in a text
t("a name goes where the %@ is",
  L10n.formatted("Delete \"%@\"", arguments: ["Default"], language: .chinese) == "删除「Default」")
t("a name in english stays as it is",
  L10n.formatted("Delete \"%@\"", arguments: ["Default"], language: .english) == "Delete \"Default\"")
// several names go in order
t("the names go in order",
  L10n.formatted("%@ rule(s) use this chain and will be set to Direct.", arguments: ["3"], language: .english) == "3 rule(s) use this chain and will be set to Direct.")
// every name goes into its own placeholder
let threeNames = "%@ proxy server(s), %@ rule(s) and %@ chain(s) were imported.\n\nSome Proxifier settings have no counterpart in ProxiRoute. Here is what was done with them:"
t("each name goes into its own placeholder",
  L10n.formatted(threeNames, arguments: ["2", "26", "1"], language: .english)
    == "2 proxy server(s), 26 rule(s) and 1 chain(s) were imported.\n\nSome Proxifier settings have no counterpart in ProxiRoute. Here is what was done with them:")
t("each name goes into its own placeholder in chinese too",
  L10n.formatted(threeNames, arguments: ["2", "26", "1"], language: .chinese)
    == "已导入 2 个代理服务器、26 条规则和 1 条代理链。\n\nProxifier 的部分设置在 ProxiRoute 里没有对应项，处理情况如下：")
// more names than placeholders do not crash
t("a name without a place is ignored",
  L10n.formatted("%@ of %@", arguments: ["1", "2", "3"], language: .english) == "1 of 2")
// fewer names than placeholders leave the rest as they are
t("a place without a name stays as it is",
  L10n.formatted("%@ of %@", arguments: ["1"], language: .english) == "1 of %@")

// every translation is a text of its own
for (key, value) in L10n.translations {
    t("the translation of \"\(key)\" is not empty", !value.isEmpty)
    t("the translation of \"\(key)\" is not the text itself", value != key)
}

// the strings the windows ask for are all in the table
// the sources are found through L10n.swift, which knows where it was compiled
// from: the test itself is copied to a temporary folder before it is run
let appDir = L10n.sourcesDirectory

func literals(in text: String, after marker: String) -> [String] {
    var out: [String] = []
    var rest = text
    while let range = rest.range(of: marker) {
        rest = String(rest[range.upperBound...])
        guard rest.first == "\"" else { continue }
        // read the string literal, escapes and all
        var out2 = ""
        var escaped = false
        for ch in rest.dropFirst() {
            if escaped {
                out2.append(ch == "n" ? "\n" : ch == "t" ? "\t" : ch)
                escaped = false
                continue
            }
            if ch == "\\" { escaped = true; continue }
            if ch == "\"" { break }
            out2.append(ch)
        }
        out.append(out2)
    }
    return out
}

var used: Set<String> = []
var filesRead = 0
if let entries = try? FileManager.default.contentsOfDirectory(atPath: appDir.path) {
    for entry in entries where entry.hasSuffix(".swift") {
        let path = appDir.appendingPathComponent(entry)
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { continue }
        filesRead += 1
        for key in literals(in: text, after: "L10n.t(") + literals(in: text, after: "L10n.f(") {
            used.insert(key)
            t("the text \"\(key)\" is in the table", L10n.translations[key] != nil)
        }
    }
}
t("the sources were read", filesRead > 0)
t("the windows ask for texts", !used.isEmpty)

// the table has no text that nobody asks for
let unused = Set(L10n.translations.keys).subtracting(used)
if !unused.isEmpty {
    print("note: these translations are not used by the windows: " + unused.sorted().joined(separator: ", "))
}

print(fails == 0 ? "l10n tests: ALL PASS" : "l10n tests: \(fails) FAILED")
exit(fails == 0 ? 0 : 1)
