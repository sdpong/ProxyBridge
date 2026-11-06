// ProcessEnumerator: the bundle id of a process path, and the list itself.
// Compiled as main.swift by run.sh.
import Foundation

var fails = 0
func t(_ name: String, _ ok: Bool) { if !ok { fails += 1; print("FAIL", name) } }

// the bundle id comes from the app bundle the process lives in
t("a normal app has a bundle id",
  ProcessEnumerator.bundleId(forProcessPath: "/Applications/Safari.app/Contents/MacOS/Safari") == "com.apple.Safari")
t("a system app has a bundle id",
  ProcessEnumerator.bundleId(forProcessPath: "/System/Applications/Calculator.app/Contents/MacOS/Calculator") == "com.apple.calculator")
t("a plain tool has no bundle id",
  ProcessEnumerator.bundleId(forProcessPath: "/bin/curl") == nil)
t("a framework helper has no bundle id",
  ProcessEnumerator.bundleId(forProcessPath: "/System/Library/Frameworks/CoreServices.framework/Versions/A/Support/mdworker_shared") == nil)
t("an empty path has no bundle id", ProcessEnumerator.bundleId(forProcessPath: "") == nil)

// the bundle a process lives in. a helper lives in its own bundle inside the
// outer one, and that inner bundle is the one that belongs to the process.
t("the app bundle of a normal app",
  ProcessEnumerator.appBundlePath(forProcessPath: "/Applications/Safari.app/Contents/MacOS/Safari") == "/Applications/Safari.app")
t("the innermost bundle of a nested app",
  ProcessEnumerator.appBundlePath(forProcessPath: "/Applications/Foo.app/Contents/PlugIns/Bar.app/Contents/MacOS/Bar") == "/Applications/Foo.app/Contents/PlugIns/Bar.app")
t("a tool has no bundle", ProcessEnumerator.appBundlePath(forProcessPath: "/bin/curl") == nil)
t("a framework helper has no bundle",
  ProcessEnumerator.appBundlePath(forProcessPath: "/System/Library/Frameworks/CoreServices.framework/Versions/A/Support/mdworker_shared") == nil)
t("an empty path has no bundle", ProcessEnumerator.appBundlePath(forProcessPath: "") == nil)

// the list of running processes
let all = ProcessEnumerator.all()
t("the machine has running programs", !all.isEmpty)
t("every process has a name", all.allSatisfy { !$0.name.isEmpty })
t("every process has an id", Set(all.map { $0.pid }).count == all.count)
t("the list is sorted by name", all.map { $0.name } == all.map { $0.name }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
t("the list has the programs of this user", ProcessEnumerator.owned(by: getuid()).allSatisfy { $0.uid == getuid() })
t("a path ends with the name", all.allSatisfy { $0.path.isEmpty || $0.path.hasSuffix($0.name) })

print(fails == 0 ? "process list tests: ALL PASS" : "process list tests: \(fails) FAILED")
exit(fails == 0 ? 0 : 1)
