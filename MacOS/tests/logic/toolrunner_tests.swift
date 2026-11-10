import Foundation
import Darwin

// The runner of the tools, and the descriptors it keeps.
//
// The file handle of Foundation does not close its descriptor when it is let
// go of, so a pipe that is left alone keeps its two descriptors for ever.
// The app asks the system questions in a loop while it waits for the
// network, and the helper of the gateway mode asks the kernel every few
// seconds - so both of them run out of descriptors. A program that cannot
// open a file cannot write the rules of the gateway any more, and the
// gateway mode stops working without saying a word.
//
// The number of the descriptors of this program is counted before and after
// a hundred runs of a tool. The number must not grow.
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

// A box of text that is safe to fill from another thread.
final class Box {
    private let lock = NSLock()
    private var value = ""
    func put(_ text: String) {
        lock.lock()
        value = text
        lock.unlock()
    }
    func get() -> String {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

// What a tool says
let hello = ToolRunner.run("/bin/echo", ["hello"])
check("the tool runs", hello != nil)
check("the tool says what it was told to say", hello?.text.contains("hello") == true)
check("the tool that worked is happy", hello?.succeeded == true)

// A tool that did not work
let failed = ToolRunner.run("/bin/sh", ["-c", "exit 3"])
check("a tool that failed is not happy", failed?.succeeded == false)
check("the code of the tool is the code of the tool", failed?.status == 3)

// A tool that is not there at all
check("a tool that is not there is nothing",
      ToolRunner.run("/no/such/tool/at/all", []) == nil)

// The two outputs of a tool
let two = ToolRunner.run("/bin/sh", ["-c", "echo out; echo err >&2"], capture: .output)
check("the ordinary output is kept", two?.text.contains("out") == true)
check("the error output is not kept when it was not asked for", two?.text.contains("err") == false)

let errors = ToolRunner.run("/bin/sh", ["-c", "echo out; echo err >&2"], capture: .error)
check("the error output is kept when it was asked for", errors?.text.contains("err") == true)
check("the ordinary output is not kept when it was not asked for", errors?.text.contains("out") == false)

let both = ToolRunner.run("/bin/sh", ["-c", "echo out; echo err >&2"], capture: .both)
check("both of them are kept when both were asked for",
      both?.text.contains("out") == true && both?.text.contains("err") == true)

// The descriptors of this program
//
// The tool is run once before the counting: the first run of anything opens
// things that stay open, and that is not a leak.
_ = ToolRunner.run("/bin/echo", ["warm up"])
let before = openDescriptorCount()
for _ in 0..<100 {
    _ = ToolRunner.run("/bin/echo", ["a line that is long enough to fill a little of the pipe"])
}
let after = openDescriptorCount()
check("the descriptors do not grow when a tool runs again and again", after - before <= 2)
print("       the descriptors went from \(before) to \(after)")

// A tool that says a lot does not block
//
// The tool fills the pipe and waits for the reader. A runner that reads one
// of the two outputs and forgets the other would wait for ever here, so the
// wait is watched from the side.
let loud = Box()
let loudDone = DispatchSemaphore(value: 0)
DispatchQueue.global(qos: .userInitiated).async {
    let answer = ToolRunner.run("/bin/sh", [
        "-c",
        "yes hello | head -c 400000; yes error | head -c 400000 >&2"
    ], capture: .both)
    loud.put(answer?.text ?? "")
    loudDone.signal()
}
let loudFinished = loudDone.wait(timeout: .now() + 30)
check("a tool that says a lot is heard and does not block", loudFinished == .success)
check("all of it is heard", loud.get().utf8.count > 700000)

if fails > 0 {
    print("\(fails) check(s) failed")
    exit(1)
}
print("all checks passed")
