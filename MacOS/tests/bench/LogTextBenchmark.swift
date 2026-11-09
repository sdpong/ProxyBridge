// The benchmark of the text of the log.
//
// The log of the window is shown in a text view, and the text of it is a
// colored text: a colored piece for the time of the line, one for its level,
// one for its message and one for the line break.
//
// It used to be built again from the beginning every time the log grew, and
// that is what the window spent most of its time on: the log holds five
// hundred lines, and every line that arrived threw away two thousand little
// objects and made them again. The extension writes hundreds of lines a
// second on a busy machine.
//
// The measurement is the time it takes to put a hundred lines on the screen
// with a log of five hundred lines - once the way it was done, and once the
// way it is done now.
//
// The time is the thing that matters here, and not the memory: the objects
// are autoreleased, so they are handed back to the pool and the size of the
// process does not grow by them. They are made so fast, though, that the
// pool cannot keep up, and that is what makes the memory of the window grow.
//
// Run it:  swiftc -O LogTextBenchmark.swift -o /tmp/logbench && /tmp/logbench

import Foundation
import AppKit

// One line of the log, the way the app holds it.
struct ActivityLog {
    let id: Int
    let timestamp: String
    let level: String
    let message: String
}

// The text of the log.
enum LogText {
    static let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

    static func seg(_ string: String, _ color: NSColor) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.foregroundColor: color, .font: font])
    }

    // The whole text, built from all the lines.
    static func make(_ logs: [ActivityLog]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for log in logs {
            out.append(seg("[\(log.timestamp)] ", .secondaryLabelColor))
            out.append(seg("[\(log.level)] ", log.level == "ERROR" ? .systemRed : .systemBlue))
            out.append(seg(log.message, .labelColor))
            out.append(seg("\n", .labelColor))
        }
        return out
    }
}

/// How many lines the log holds.
let logSize = 500
/// How many lines arrive while the window is watched.
let arrivals = 100

func makeLogs(_ n: Int) -> [ActivityLog] {
    (0..<n).map { i in
        ActivityLog(
            id: i,
            timestamp: "2026-11-09 20:00:00.000",
            level: "INFO",
            message: "Connection TCP Codex (Aperitif) -> 104.18.37.228:443 via Direct (rule 26)"
        )
    }
}

func measure(_ name: String, _ body: () -> Void) -> Double {
    let start = Date()
    body()
    let ms = Date().timeIntervalSince(start) * 1000
    print(String(format: "  %-34@ %8.1f ms", name as NSString, ms))
    return ms
}

let logs = makeLogs(logSize)
print("log lines: \(logSize), arrivals: \(arrivals)")

// the way it was done: the whole text is built again every time
let old = measure("the whole text built again") {
    for _ in 0..<arrivals {
        autoreleasepool { _ = LogText.make(logs).length }
    }
}

// the way it is done now: only the new lines are added
let new = measure("only the new lines added") {
    let storage = NSMutableAttributedString()
    storage.append(LogText.make(logs))
    for _ in 0..<arrivals {
        autoreleasepool { storage.append(LogText.make([logs[0]])) }
    }
}

print()
print(String(format: "  the new way is %.0f times faster", old / max(new, 0.001)))
if old / max(new, 0.001) < 10 {
    print("  WARNING: the difference is smaller than it should be.")
    exit(1)
}
print("  ok")
