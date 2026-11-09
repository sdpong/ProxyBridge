import Foundation

// The tests of the wait for the upstream.
//
// macOS starts all the login items at the same moment, so the order in which
// the app and the proxy it points to come up cannot be set anywhere. These
// tests keep the two things that make the order:
//   - the app knows which of its upstream proxies run on this machine, and
//     waits for them before it takes the traffic over,
//   - the launch agent that starts the app when the upstream is ready says
//     what it waits for, and it is put in place as the agent of the user.
//
// The tests also keep the probe honest: a port that nothing listens on has to
// be answered with "not ready", and a port that does has to be answered with
// "ready".

func check(_ condition: Bool, _ what: String) {
    if condition {
        print("  ok   \(what)")
    } else {
        print("  FAIL \(what)")
        exit(1)
    }
}

print("upstream wait tests:")

// ---------------------------------------------------------------- the hosts of this machine

check(UpstreamWait.isLocalHost("127.0.0.1"), "127.0.0.1 is this machine")
check(UpstreamWait.isLocalHost("127.0.0.53"), "the whole 127.0.0.0/8 is this machine")
check(UpstreamWait.isLocalHost("localhost"), "localhost is this machine")
check(UpstreamWait.isLocalHost("LOCALHOST"), "the name of the host does not matter")
check(UpstreamWait.isLocalHost("::1"), "::1 is this machine")
check(UpstreamWait.isLocalHost(" 127.0.0.1 "), "the spaces around the host are not a problem")

check(!UpstreamWait.isLocalHost("1.2.3.4"), "a number somewhere else is not this machine")
check(!UpstreamWait.isLocalHost("example.com"), "a name somewhere else is not this machine")
check(!UpstreamWait.isLocalHost("127.0.0.1.5"), "something that looks like it is not this machine")
check(!UpstreamWait.isLocalHost("127.0.0.256"), "an address that cannot exist is not this machine")
check(!UpstreamWait.isLocalHost(""), "nothing is not this machine")
check(!UpstreamWait.isLocalHost("1127.0.0.1"), "a name that starts like one is not this machine")

// ---------------------------------------------------------------- the list of the endpoints

let endpoints = [
    UpstreamEndpoint(host: "127.0.0.1", port: 9991),
    UpstreamEndpoint(host: "example.com", port: 443),
    UpstreamEndpoint(host: "localhost", port: 1080),
    UpstreamEndpoint(host: "127.0.0.1", port: 9991)
]
let local = UpstreamWait.localEndpoints(endpoints)
check(local.count == 2, "only the upstream of this machine is waited for")
check(local.contains(UpstreamEndpoint(host: "127.0.0.1", port: 9991)), "the proxy of Clash Meta is in the list")
check(local.contains(UpstreamEndpoint(host: "localhost", port: 1080)), "a proxy that is called localhost is in the list")
check(!local.contains(UpstreamEndpoint(host: "example.com", port: 443)), "a proxy somewhere else is not waited for")
check(local.filter { $0 == UpstreamEndpoint(host: "127.0.0.1", port: 9991) }.count == 1,
      "the same proxy is not waited for twice")

// ---------------------------------------------------------------- the file

let text = UpstreamWait.waitFileText(local)
check(text == "127.0.0.1 9991\nlocalhost 1080\n", "the file says the host and the port of every one")
check(UpstreamWait.endpoints(fromWaitFile: text) == local, "the file says what it was given")

check(UpstreamWait.endpoints(fromWaitFile: "").isEmpty, "an empty file waits for nothing")
check(UpstreamWait.endpoints(fromWaitFile: "127.0.0.1\n").isEmpty, "a line without a port is skipped")
check(UpstreamWait.endpoints(fromWaitFile: "127.0.0.1 zero\n").isEmpty, "a port that is not a number is skipped")
check(UpstreamWait.endpoints(fromWaitFile: "127.0.0.1 99999\n").isEmpty, "a port that cannot exist is skipped")
check(UpstreamWait.endpoints(fromWaitFile: "127.0.0.1 9991\n\n127.0.0.1 9992\n").count == 2,
      "an empty line in the middle is skipped")

// ---------------------------------------------------------------- the script

let script = UpstreamWait.scriptText(home: URL(fileURLWithPath: "/Users/tester"))
check(script.contains(UpstreamWait.waitFileURL(home: URL(fileURLWithPath: "/Users/tester")).path),
      "the script reads the file that says what to wait for")
check(script.contains(UpstreamWait.startFlagURL(home: URL(fileURLWithPath: "/Users/tester")).path),
      "the script reads the file that says whether the app should start at all")
check(script.contains("pgrep -x \"ProxiRoute\""), "the script does not start a second copy of the app")
check(script.contains("open -g"), "the app is started in the background, without a window in front")
check(script.contains("nc -z"), "the script asks the port of the upstream")
check(script.hasPrefix("#!/bin/sh"), "the script is a shell script")

// ---------------------------------------------------------------- the agent

let agent = UpstreamWait.agentDictionary(home: URL(fileURLWithPath: "/Users/tester"))
check(agent["Label"] as? String == "com.sdpong.proxiroute.launch", "the agent has a name of its own")
check(agent["RunAtLoad"] as? Bool == true, "the agent runs at every login")
check((agent["ProgramArguments"] as? [String])?.first == "/bin/sh", "the agent runs a shell script")
check((agent["EnvironmentVariables"] as? [String: String])?["PROXIRoute_START_HIDDEN"] == "1",
      "the agent tells the app to stay out of the way")
check(UpstreamWait.agentPlistURL(home: URL(fileURLWithPath: "/Users/tester")).path
        == "/Users/tester/Library/LaunchAgents/com.sdpong.proxiroute.launch.plist",
      "the agent is an agent of the user")

// ---------------------------------------------------------------- the probe

// A port that nothing listens on is not ready.
check(!UpstreamReadiness.canConnect(UpstreamEndpoint(host: "127.0.0.1", port: 1)),
      "a port that nothing listens on is not ready")

// A port that does listen is ready. The listener of the test is opened here,
// so the answer comes from a port that is really there.
let listener = socket(AF_INET, SOCK_STREAM, 0)
check(listener >= 0, "the test can open a listener")
var address = sockaddr_in()
address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
address.sin_family = sa_family_t(AF_INET)
address.sin_port = 0
address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
let bound = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
}
check(bound == 0, "the listener of the test is bound")
check(listen(listener, 4) == 0, "the listener of the test is listening")

var actual = sockaddr_in()
var length = socklen_t(MemoryLayout<sockaddr_in>.size)
let named = withUnsafeMutablePointer(to: &actual) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(listener, $0, &length)
    }
}
let port = Int(UInt16(bigEndian: actual.sin_port))
check(port > 0, "the listener of the test has a port")

check(UpstreamReadiness.canConnect(UpstreamEndpoint(host: "127.0.0.1", port: port)),
      "a port that something listens on is ready")
close(listener)

// ---------------------------------------------------------------- the app waits before it takes the traffic over

let appDir: URL
if let fromEnvironment = ProcessInfo.processInfo.environment["PROXIRoute_APP"] {
    appDir = URL(fileURLWithPath: fromEnvironment)
} else {
    appDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // logic
        .deletingLastPathComponent()   // tests
        .deletingLastPathComponent()   // ProxiRoute
        .appendingPathComponent("ProxiRoute")
}

func read(_ name: String) -> String {
    let path = appDir.appendingPathComponent(name)
    guard let text = try? String(contentsOf: path, encoding: .utf8) else {
        print("  FAIL cannot read \(name)")
        exit(1)
    }
    return text
}

let viewModel = read("ProxiRouteViewModel.swift")
check(viewModel.contains("func startProxy()"), "the app has a place where it starts the proxy")
check(viewModel.contains("UpstreamReadiness.wait(for: endpoints"), "the start waits for the upstream")
check(viewModel.contains("func localUpstreamEndpoints()"), "the app knows which upstream run on this machine")
check(viewModel.contains("UpstreamWait.localEndpoints(endpoints)"), "the upstream of this machine are picked out")
check(viewModel.contains("refreshUpstreamWaitFile()"), "the file of the agent is written when the proxies change")
check(viewModel.contains("LaunchOrderAgent.writeWaitFile(for:"), "the file of the agent is written")

let agentFile = read("LaunchOrderAgent.swift")
check(agentFile.contains("func install() throws"), "the agent can be put in place")
check(agentFile.contains("func uninstall()"), "the agent can be taken out")
check(agentFile.contains("bootstrap"), "the agent is told to launchd")
check(agentFile.contains("func writeStartFlag"), "the file that says whether to start at the login is written")

// The login item follows the switch right away.
//
// The agent is the launcher of the app while it is in place, so the app must
// not be a login item as well. And when the agent is taken out, the app has
// to become a login item again - otherwise a person who quits it and
// restarts the machine finds no proxy, and the app is only started by hand.
check(agentFile.contains("LoginItem.applyToSystem(LoginItem.isEnabled)"),
      "the login item follows the switch right away")
check(agentFile.contains("func sync()"), "the machine is made to match the switch")
check(read("ProxiRouteGUI.swift").contains("LaunchOrderAgent.sync()"),
      "the machine is made to match the switch at every start")
check(agentFile.contains("func writeWaitFile"), "the file that says what to wait for is written")

print("upstream wait tests: ALL PASS")
