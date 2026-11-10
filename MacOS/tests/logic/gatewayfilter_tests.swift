import Foundation
import Darwin

// The helper of the gateway mode, and the descriptors it keeps.
//
// The helper runs for days and it asks the kernel what the machine looks
// like every few seconds - the app asks it, and the answer comes from two
// tools. The file handle of Foundation does not close its descriptor when it
// is let go of, so a pipe that is left alone keeps its two descriptors for
// ever. The helper would run out of descriptors within the hour, and a
// helper that cannot open a file cannot write the rules of the gateway: the
// gateway mode would stop working without saying a word.
//
// This test asks the filter of the machine what it says, a hundred times,
// through the code of the helper itself, and counts the descriptors of this
// program before and after.
//
// The tools of the filter need root to say something, and this test has no
// root: the answer of the tools does not matter here. The pipes of the tools
// are made and closed whatever the tools say.
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

// The number of the descriptors this program has open.
func openDescriptorCount() -> Int {
    let limit = min(getdtablesize(), 4096)
    var count = 0
    for descriptor in 0..<limit {
        if fcntl(descriptor, F_GETFD) != -1 { count += 1 }
    }
    return count
}

// One round first: the first run of anything opens things that stay open,
// and that is not a leak.
_ = GatewayFilter.filterEnabled()
_ = GatewayFilter.forwardingEnabled()

let before = openDescriptorCount()
for _ in 0..<100 {
    _ = GatewayFilter.filterEnabled()
    _ = GatewayFilter.forwardingEnabled()
}
let after = openDescriptorCount()

check("the descriptors of the helper do not grow", after - before <= 2)
print("       the descriptors went from \(before) to \(after)")

if fails > 0 {
    print("\(fails) check(s) failed")
    exit(1)
}
print("all checks passed")
