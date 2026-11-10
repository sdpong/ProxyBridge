import Foundation

// The tests of the lists of the person.
//
// The proxies and the rules of the person are in the settings of the app,
// and they were gone on the 10th of November 2026.
//
// What happened, in the order of the code:
//
//   1. the list of the profiles was not in the settings any more. The app
//      made a profile called Default and made it the profile that is
//      active.
//   2. the working keys - the copy of the lists that the app works with -
//      were emptied, because the profile that was loaded has no lists of its
//      own.
//   3. the empty working keys were written back into the profile that was
//      active, and the lists of the person were gone.
//
// The steps 2 and 3 are what is tested here: the lists of a profile are only
// written back when they are the lists of that profile, and the lists of the
// profile that is active are put back into the working keys when the working
// keys do not hold them.

func check(_ condition: Bool, _ what: String) {
    if condition {
        print("  ok   \(what)")
    } else {
        print("  FAIL \(what)")
        exit(1)
    }
}

print("profile safety tests:")

let appDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PROXIRoute_APP"] ?? "")
let viewModel = (try? String(contentsOf: appDir.appendingPathComponent("ProxiRouteViewModel.swift"),
                              encoding: .utf8)) ?? ""

check(!viewModel.isEmpty, "the source of the view model is there")

// The lists of a profile are written back only when they are the lists of
// that profile.
check(viewModel.contains("private var workingSetProfile: String"),
      "the app knows which profile the working keys came from")
check(viewModel.contains("if workingSetProfile == name {"),
      "the lists are written back only into the profile they came from")

// The lists of the profile that is active are put back into the working keys
// when the working keys do not hold them.
check(viewModel.contains("restoreWorkingListsIfTheyAreMissing()"),
      "the lists of the profile that is active are put back when they are missing")
check(viewModel.contains("private func restoreWorkingListsIfTheyAreMissing()"),
      "the helper that puts the lists back is there")
check(viewModel.contains("profileNamesInTheSettings()"),
      "the list of the profiles is made from the profiles that are there")

// The list of the profiles is not lost when the key of the list is gone.
check(viewModel.contains("var names = d.stringArray(forKey: \"profiles\") ?? []"),
      "the list of the profiles is read")
let readList = viewModel.range(of: "var names = d.stringArray(forKey: \"profiles\") ?? []")
check(readList != nil, "the list of the profiles is read from the settings")
if let readList = readList {
    let after = viewModel[readList.upperBound...].prefix(900)
    check(after.contains("profileNamesInTheSettings()"),
          "the list of the profiles is made from the profiles that are there when the key is gone")
    check(!after.contains("d.set(\"Default\", forKey: \"activeProfile\")\n            flushWorkingSet"),
          "the profile that is active is not thrown away without a word")
}

// The profile that is active is not one that the app made up.
check(viewModel.contains("names.contains(stored)"),
      "the profile that was active is kept when it is in the list")

print("profile safety tests: ALL PASS")
