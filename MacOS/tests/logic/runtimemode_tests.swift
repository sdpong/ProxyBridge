import Foundation

// The running mode: what the app does with the traffic of this machine.
//
// The test is about the one thing that matters here. The route mode and the
// proxy server cannot be on at the same time - both of them make the machine
// work, and the processor pays for both - and an app that was written before
// the modes existed keeps doing what it was doing.
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

// there are three modes and not more
check("there are three modes", RuntimeMode.allCases.count == 3)

// the one thing that matters: not both at the same time
for mode in RuntimeMode.allCases {
    check("the mode \(mode.rawValue) never takes the traffic over and waits for the clients at once",
          !(mode.takesOverLocalTraffic && mode.runsLocalProxyServer))
}

check("the route mode takes the traffic of this machine over", RuntimeMode.route.takesOverLocalTraffic)
check("the route mode does not run the proxy server", !RuntimeMode.route.runsLocalProxyServer)
check("the server mode runs the proxy server", RuntimeMode.server.runsLocalProxyServer)
check("the server mode does not take the traffic of this machine over", !RuntimeMode.server.takesOverLocalTraffic)
check("the off mode does neither", !RuntimeMode.off.takesOverLocalTraffic && !RuntimeMode.off.runsLocalProxyServer)

// the mode survives the trip through the settings
for mode in RuntimeMode.allCases {
    check("the mode \(mode.rawValue) survives the trip", RuntimeMode(rawValue: mode.rawValue) == mode)
}
check("a word that is not a mode is not a mode", RuntimeMode(rawValue: "nothing") == nil)

// an app that was written before the modes existed keeps doing what it did
check("an app without the proxy server was in the route mode",
      RuntimeModeStore.modeBeforeModesExisted(localProxyWasEnabled: false) == .route)
check("an app with the proxy server was in the server mode",
      RuntimeModeStore.modeBeforeModesExisted(localProxyWasEnabled: true) == .server)

print(fails == 0 ? "runtime mode tests: ALL PASS" : "runtime mode tests: \(fails) FAILED")
exit(fails == 0 ? 0 : 1)
