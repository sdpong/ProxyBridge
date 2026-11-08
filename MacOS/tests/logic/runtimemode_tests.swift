import Foundation

// The running mode: what the app does with the traffic of this machine.
//
// The traffic of this machine is taken over in every mode - that is what the
// app does. The modes differ in the service they add for the other terminals
// of the network, and an app that was written before the modes existed keeps
// doing what it was doing.
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

// every mode takes the traffic of this machine over
for mode in RuntimeMode.allCases {
    check("the mode \(mode.rawValue) takes the traffic of this machine over",
          mode.takesOverLocalTraffic)
}

// the service for the other terminals is what the modes differ in
check("the local mode runs no service for the other terminals",
      !RuntimeMode.local.runsLocalProxyServer && !RuntimeMode.local.runsGateway)
check("the gateway mode runs the gateway and not the server",
      RuntimeMode.gateway.runsGateway && !RuntimeMode.gateway.runsLocalProxyServer)
check("the server mode runs the server and not the gateway",
      RuntimeMode.server.runsLocalProxyServer && !RuntimeMode.server.runsGateway)

// the mode survives the trip through the settings
for mode in RuntimeMode.allCases {
    check("the mode \(mode.rawValue) survives the trip", RuntimeMode(rawValue: mode.rawValue) == mode)
}
check("a word that is not a mode is not a mode", RuntimeMode(rawValue: "nothing") == nil)

// an app that was written before the modes existed keeps doing what it did
check("an app without the proxy server was in the local mode",
      RuntimeModeStore.modeBeforeModesExisted(localProxyWasEnabled: false) == .local)
check("an app with the proxy server was in the server mode",
      RuntimeModeStore.modeBeforeModesExisted(localProxyWasEnabled: true) == .server)

print(fails == 0 ? "runtime mode tests: ALL PASS" : "runtime mode tests: \(fails) FAILED")
exit(fails == 0 ? 0 : 1)
