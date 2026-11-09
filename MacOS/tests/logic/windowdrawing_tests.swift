import Foundation

// The tests of the way the window is drawn.
//
// The window was the place where the machine was spent. The extension writes a
// line for every connection it decides and a line for every flow, and a busy
// machine produces hundreds of them a second. Every one of them went on the
// screen as it came, and every one of them rebuilt the window.
//
// The fixes are in three places, and these tests keep them in place:
//
//   - the numbers of the tables are written with one formatter, not one per
//     cell (a ByteCountFormatter is a heavy object),
//   - the text of the log is built in the text view and only the new lines
//     are added to it,
//   - the lines of the log and the connections are gathered before they go on
//     the screen, and the tables of the traffic are only touched when a
//     number really moved.
//
// The tests read the text of the sources: the code that does the work is in
// the view and in the view model, and what matters is that the work stays out
// of the way of the drawing.

func check(_ condition: Bool, _ what: String) {
    if condition {
        print("  ok   \(what)")
    } else {
        print("  FAIL \(what)")
        exit(1)
    }
}

func read(_ path: String) -> String {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        print("  FAIL cannot read \(path)")
        exit(1)
    }
    return text
}

let app = ProcessInfo.processInfo.environment["PROXIRoute_APP"] ?? ""
let scripts = ProcessInfo.processInfo.environment["PROXIRoute_SCRIPTS"] ?? ""

print("window drawing tests:")

guard !app.isEmpty else {
    print("  FAIL the sources of the app are not known")
    exit(1)
}

let contentView = read((app as NSString).appendingPathComponent("ContentView.swift"))
let viewModel = read((app as NSString).appendingPathComponent("ProxiRouteViewModel.swift"))

// ---------------------------------------------------------------- the formatter

// One formatter for every cell of every table.
check(contentView.contains("private static let byteFormatter: ByteCountFormatter"),
      "the numbers of the tables are written with one formatter")
check(contentView.contains("byteFormatter.string(fromByteCount: count)"),
      "the formatter that is kept is the one that is used")

// A formatter that is made inside the function that writes the number is the
// thing that was wrong: it is made once per cell, and the tables are drawn
// every second.
let bytesFunction = contentView.components(separatedBy: "static func bytes")[1]
let bytesBody = String(bytesFunction.prefix(while: { $0 != "}" }))
check(!bytesBody.contains("ByteCountFormatter()"),
      "no formatter is made while the number is written")

// ---------------------------------------------------------------- the text of the log

// The text of the log is built in the text view, not in the body of the view.
check(contentView.contains("LogTextView(logs: logs)"),
      "the log is given to the text view as the lines it holds")
check(!contentView.contains("private var logsText: NSAttributedString"),
      "the body of the view does not build the text of the log")

// Only the new lines are added to the text that is already there.
check(contentView.contains("storage.append(LogText.make("),
      "the new lines of the log are added to the text that is there")
check(contentView.contains("storage.setAttributedString(LogText.make(logs))"),
      "the text of the log is written again when the log was trimmed")

// ---------------------------------------------------------------- the lines are gathered

// The lines of the log and the connections go on the screen together.
check(viewModel.contains("pendingActivity"),
      "the lines of the log wait before they go on the screen")
check(viewModel.contains("pendingConnections"),
      "the connections wait before they go on the screen")
check(viewModel.contains("scheduleActivityFlush"),
      "the lines of the log are put on the screen by a timer")
check(viewModel.contains("scheduleConnectionFlush"),
      "the connections are put on the screen by a timer")

// The lines are not put on the screen one by one any more.
check(!viewModel.contains("        appendActivity(newActivity)"),
      "the lines of the log are not put on the screen one by one")
check(!viewModel.contains("        appendConnections(newConnections)"),
      "the connections are not put on the screen one by one")

// The batch that comes over the provider channel goes on the screen as it is:
// it is one request with many lines in it, not one line at a time.
check(viewModel.contains("self.appendConnections(newConnections)"),
      "the batch of the provider channel goes on the screen as one batch")
check(viewModel.contains("self.appendActivity(newActivity)"),
      "the lines of the provider channel go on the screen as one batch")

// ---------------------------------------------------------------- the tables of the traffic

// The tables of the traffic are only touched when a number really moved.
check(viewModel.contains("func setProxyTraffic"),
      "the rows of the traffic are compared before they are published")
check(viewModel.contains("func setLiveFlows"),
      "the connections of the table are compared before they are published")
check(viewModel.contains("func sameAs(_ other: LiveFlow)"),
      "two connections can be told apart without drawing them")
check(viewModel.contains("func sameAs(_ other: ProxyTraffic)"),
      "two rows of the traffic can be told apart without drawing them")

// The comparison has to be used, not only written down.
check(viewModel.contains("setProxyTraffic(rows)"),
      "the rows of the traffic go out through the comparison")
check(viewModel.contains("setLiveFlows(machineFlows)"),
      "the connections go out through the comparison")

// ---------------------------------------------------------------- clearing

// Clearing the log clears the lines that are waiting too: they were written
// before the log was cleared, and putting them on the screen now would bring
// them back.
check(viewModel.contains("pendingActivity.removeAll()"),
      "clearing the log clears the lines that are waiting as well")

// ---------------------------------------------------------------- the tunnel

// The transparent proxy configuration is what the tunnel is, and the app
// writes it into the system. That needs a team id: without one the system
// does not even answer the call.
//
// Measured on this machine, with a build that is signed ad-hoc:
//
//     calling loadAllFromPreferences ...
//     NO CALLBACK within 10s
//
// Not an error - nothing happens at all. So the configuration is never
// written, the tunnel never shows up in System Settings, and there is no
// switch to turn on.
//
// The app has to say that, instead of showing an empty list with no reason
// given. These assertions keep the wording in place.
let viewModelSource = viewModel
check(viewModelSource.contains("extensionProblem"),
      "the app has something to say when the extension does not answer")
check(viewModelSource.contains("bound the tunnel to another, older ProxiRoute extension"),
      "the app says what happened when the tunnel is bound to an old extension")

print("window drawing tests: ok")
