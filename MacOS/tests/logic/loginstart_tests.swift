import Foundation

// The tests of the start at the login.
//
// The person asked for the proxy of the machine to be there as soon as the
// network of the system is up, and to be there before the other apps that
// use the network.
//
// What was measured on this machine at the login of 13:29:
//
//   - the launch agent of the app was spawned at 13:29:46 - in the middle of
//     the wave of the login - and launchd held it there for 74 seconds: the
//     identity of the process was resolved and the first run of the agent
//     was checked, and only then was the script let go.
//   - the app was up at 13:31:29. Every other app of the wave - Ollama at
//     13:29:47, Clash Meta at 13:29:48, Raycast at 13:29:49 - was up long
//     before it.
//
// So the app is a login item of macOS now, and the launch agent is the
// second hand: it waits for the network and it starts the app when the
// login item did not.
//
// These tests keep three things that are easy to break:
//   - only one instance of the app runs at a time, because two launchers can
//     start it at the same moment,
//   - the menus of the app work even when the app came up without a window,
//   - the order of the start is written down in one log.

func check(_ condition: Bool, _ what: String) {
    if condition {
        print("  ok   \(what)")
    } else {
        print("  FAIL \(what)")
        exit(1)
    }
}

print("login start tests:")

// ---------------------------------------------------------------- one app at a time

// The lock of the test is the lock of the test: the app that is running on
// the machine has a lock of its own, and the test does not touch it.
let lockHome = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("proxiroute-lock-test")
// the folder of the lock is the one of the app, under the home of the test
try? FileManager.default.createDirectory(at: UpstreamWait.supportFolderURL(home: lockHome),
                                        withIntermediateDirectories: true)

// Another process takes the lock: the app gives up and knows who has it.
//
// The lock of a process that is gone is free again - the kernel gives it
// back - and that is what is checked here: a program of its own takes the
// lock first, and the app can take it again when that program is gone.
let lockPath = UpstreamWait.supportFolderURL(home: lockHome).appendingPathComponent("app.lock").path
let helperLines = [
    "import fcntl, os, sys, time",
    "handle = open(sys.argv[1], \"r+\") if os.path.exists(sys.argv[1]) else open(sys.argv[1], \"w+\")",
    "fcntl.flock(handle, fcntl.LOCK_EX)",
    "handle.seek(0); handle.truncate(); handle.write(str(os.getpid())); handle.flush()",
    "time.sleep(30)"
]
let helper = helperLines.joined(separator: "\n") + "\n"
let helperPath = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("proxiroute-lock-helper.py")
if (try? helper.write(to: helperPath, atomically: true, encoding: .utf8)) != nil {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [helperPath.path, lockPath]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    if (try? process.run()) != nil {
        // The other program takes the lock and keeps it for a moment.
        //
        // The test waits for the other program to say that it has the lock
        // instead of waiting for a fixed time and hoping. The other program
        // is a program of its own, and on a machine that is busy it takes a
        // moment to come up: a test that waits for a fixed time fails on a
        // busy machine and passes on a quiet one, and it says nothing about
        // the app.
        //
        // The other program writes its number into the file of the lock only
        // after it has the lock, so the number is the sign that it is there.
        var waited = 0.0
        while waited < 15.0, InstanceLock.otherInstance(home: lockHome) == nil {
            Thread.sleep(forTimeInterval: 0.1)
            waited += 0.1
        }
        check(InstanceLock.otherInstance(home: lockHome) != nil,
              "the other program has the lock")
        check(!InstanceLock.acquire(home: lockHome), "the app gives up when another app has the lock")
        check(InstanceLock.otherInstance(home: lockHome) != nil, "the instance that holds the lock is known")
        // the other program lets the lock go, and the kernel gives it back
        process.terminate()
        process.waitUntilExit()
        check(InstanceLock.acquire(home: lockHome), "the lock of a process that is gone is free again")
    }
    try? FileManager.default.removeItem(at: helperPath)
}

// The app holds the lock now, and a second app does not get it.
check(!InstanceLock.acquire(home: lockHome), "a second app does not take the lock")
check(InstanceLock.otherInstance(home: lockHome) == nil, "the instance that holds the lock is this one")

// ---------------------------------------------------------------- the network of the machine

// The question is asked of the system: a default route says that there is
// somewhere to send a packet to, and an address says that the machine is on
// a network.
check(NetworkReadiness.waitLimit > 0, "the wait for the network is not empty")
let route = Process()
route.executableURL = URL(fileURLWithPath: "/sbin/route")
route.arguments = ["-n", "get", "default"]
route.standardOutput = Pipe()
route.standardError = Pipe()
try? route.run()
route.waitUntilExit()
check(NetworkReadiness.hasADefaultRoute() == (route.terminationStatus == 0),
      "the answer about the default route is the answer of the system")
check(NetworkReadiness.isUp() == (NetworkReadiness.hasADefaultRoute() || NetworkReadiness.hasAnAddress()),
      "the machine has a network when it has a route or an address")

// ---------------------------------------------------------------- the sources of the app

func readAppFile(_ name: String) -> String {
    let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PROXIRoute_APP"] ?? "")
        .appendingPathComponent(name)
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

let gui = readAppFile("ProxiRouteGUI.swift")
let main = readAppFile("main.swift")
let viewModel = readAppFile("ProxiRouteViewModel.swift")
let agent = readAppFile("LaunchOrderAgent.swift")

// The app is a login item of macOS and the launch agent is there as well.
//
// The login item is what starts the app in the wave of the login. The agent
// is the second hand: it waits for the network, and it starts the app when
// the login item did not.
check(gui.contains("addSystemLoginItem()"),
      "the app is a login item of macOS")
let loginItemAt = gui.range(of: "addSystemLoginItem()")
let agentAt = gui.range(of: "try LaunchOrderAgent.install()")
check(loginItemAt != nil && agentAt != nil && loginItemAt!.lowerBound < agentAt!.lowerBound,
      "the login item is put in place before the agent, and both of them are there")
check(gui.contains("removeSystemLoginItem()"),
      "the login item goes away when the switch is off")

// One app at a time. Two launchers can start the app at the same moment.
check(main.contains("InstanceLock.acquire()"),
      "the app takes the lock before it starts")
check(main.contains("InstanceLock.otherInstance()"),
      "the app that comes second brings the first one to the front")
check(readAppFile("InstanceLock.swift").contains("flock"),
      "the lock is a lock of the system, and a crash does not leave it behind")

// The menus of the app work even when the app came up without a window.
//
// The view model belongs to the app and not to the window: it was given to
// the app delegate when the window appeared, and a window that never appears
// leaves it empty. A menu item that unwraps it took the app down with it.
check(gui.contains("AppDelegate.viewModel = model"),
      "the view model belongs to the app from the start")
check(!gui.contains("AppDelegate.viewModel!"),
      "no menu item unwraps the view model without looking at it")
check(gui.contains("AppDelegate.openMainWindow"),
      "the window of swiftui can be asked for when there is none")
check(gui.contains("attach(to: view, triesLeft:"),
      "the window is looked for until it is there")

// The order of the start is in one log, and the app writes into it itself:
// it can be started by the login item of macOS, and then the agent does not
// know anything about it.
check(gui.contains("UpstreamWait.appendLoginLog"),
      "the app writes the order of the start into the log itself")
check(viewModel.contains("UpstreamWait.appendLoginLog"),
      "the tunnel that is up is written into the log as well")

// The noise of the agent goes into its own log: the log of the login is the
// order of the start, and it should be readable.
check(readAppFile("UpstreamWait.swift").contains("agentLogURL"),
      "the agent has a log of its own")

// The app waits for the network of the machine before it takes the traffic
// over: a tunnel that is put up on a machine without a network carries
// nothing.
check(viewModel.contains("startProxyWhenTheNetworkIsThere()"),
      "the proxy waits for the network of the machine")
check(viewModel.contains("NetworkReadiness.isUp()"),
      "the network is asked about, and not guessed")

// ---------------------------------------------------------------- how the app was started

// How the app was started is decided by the app itself.
//
// The key of macOS that says whether a launch is the default one is not of
// use: it says the opposite of what it should on this machine, and a build
// that asks it hides the app when the person opened it and puts a dock icon
// on it when macOS started it at the login. It was measured three ways on
// the 10th of November 2026:
//   - the login item of macOS started the app (loginwindow, "perform
//     Autolaunch") and the key said TRUE
//   - the app was opened with "open -a" and the key said FALSE
//   - the binary was run from a terminal and the key said FALSE
check(!gui.contains("NSApplication.launchIsDefaultUserInfoKey"),
      "the app does not ask macOS which launch it was")
let origin = readAppFile("LaunchOrigin.swift")
check(origin.contains("UpstreamWait.startedInThisSession()"),
      "the launch of the login is told apart by the session of the login")
check(origin.contains("UpstreamWait.startHiddenVariable"),
      "the launch of the agent is told apart by its environment variable")
check(origin.contains("comesUpInTheMenuBar"),
      "a launch that is made for the proxy comes up in the menu bar")
check(gui.contains("origin.comesUpInTheMenuBar"),
      "the app comes up in the menu bar when it was not opened by hand")

// The marker of the session says whether the app was already started in it.
let markerHome = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("proxiroute-session-test")
try? FileManager.default.createDirectory(at: UpstreamWait.supportFolderURL(home: markerHome),
                                        withIntermediateDirectories: true)
setenv(UpstreamWait.sessionVariable, "Nov 10 14:59", 1)
check(!UpstreamWait.startedInThisSession(home: markerHome),
      "a session without a marker is a session the app was not started in")
UpstreamWait.writeSessionMarker(session: "Nov 10 14:59", home: markerHome)
check(UpstreamWait.startedInThisSession(home: markerHome),
      "the marker of the session says that the app was started in it")
UpstreamWait.writeSessionMarker(session: "Nov 10 14:59", quit: true, home: markerHome)
check(UpstreamWait.startedInThisSession(home: markerHome),
      "a closed app is the same session: the person wants to see it again")
UpstreamWait.writeSessionMarker(session: "Nov 10 09:00", home: markerHome)
check(!UpstreamWait.startedInThisSession(home: markerHome),
      "the marker of another session is not this session")
try? FileManager.default.removeItem(at: markerHome)

// An "open" event that comes while the app is starting is not answered
// while it is starting.
//
// The login items of macOS are opened by loginwindow, and that comes with
// such an event. Answering it in the middle of the start changes the
// activation policy of the app while it is starting, and the window of
// swiftui is never made: the app comes up with no window at all, and there
// is nothing to bring it back with. That is what a person saw on the 10th
// of November 2026.
check(gui.contains("AppDelegate.launchIsOver"),
      "the app knows whether it is done starting")
check(gui.contains("AppDelegate.windowWantedAfterLaunch"),
      "an open event that comes during the start is remembered")

// The DNS proxy is written when the extension of this build is already in
// the system.
//
// It was not, and that is why the entry of ProxiRoute DNS was not in the
// settings of the system: the switch of the DNS proxy opens only in the
// branch where macOS was asked to install the extension, and that branch is
// not taken when the extension is already there - which is the case of
// every start after the first one. The traffic was proxied and the names
// were not known.
let alreadyThere = viewModel.range(of: "The system extension of this build is already installed.")
check(alreadyThere != nil, "the app asks the system about the extension")
if let alreadyThere = alreadyThere {
    let after = viewModel[alreadyThere.upperBound...].prefix(1500)
    check(after.contains("extensionReady = true"),
          "the app knows that the extension of this build is in the system")
    check(after.contains("applyDNSProxy()"),
          "the DNS proxy is written when the extension is already there")
}

try? FileManager.default.removeItem(at: lockHome)

print("login start tests: ALL PASS")
