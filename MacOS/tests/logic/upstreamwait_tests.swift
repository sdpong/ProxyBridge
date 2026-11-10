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

// ---------------------------------------------------------------- the order of the endpoints

// The endpoint that the most rules use comes first: the start of the proxy
// waits for that one and not for all of them.
let ordered = UpstreamWait.orderedLocalEndpoints([
    (endpoint: UpstreamEndpoint(host: "127.0.0.1", port: 7991), rules: 3),
    (endpoint: UpstreamEndpoint(host: "127.0.0.1", port: 9991), rules: 13),
    (endpoint: UpstreamEndpoint(host: "example.com", port: 443), rules: 20),
    (endpoint: UpstreamEndpoint(host: "127.0.0.1", port: 1080), rules: 1)
])
check(ordered.count == 3, "only the upstream of this machine is waited for")
check(ordered.first == UpstreamEndpoint(host: "127.0.0.1", port: 9991),
      "the upstream that carries the most rules comes first")
check(ordered.last == UpstreamEndpoint(host: "127.0.0.1", port: 1080),
      "the upstream that carries the least comes last")
check(!ordered.contains(UpstreamEndpoint(host: "example.com", port: 443)),
      "a proxy somewhere else is not waited for")

// The same proxy twice is waited for once.
let orderedTwice = UpstreamWait.orderedLocalEndpoints([
    (endpoint: UpstreamEndpoint(host: "127.0.0.1", port: 9991), rules: 13),
    (endpoint: UpstreamEndpoint(host: "127.0.0.1", port: 9991), rules: 13)
])
check(orderedTwice.count == 1, "the same proxy is not waited for twice")

// The ones with the same number of rules keep the order they came in.
let orderedTie = UpstreamWait.orderedLocalEndpoints([
    (endpoint: UpstreamEndpoint(host: "127.0.0.1", port: 1111), rules: 2),
    (endpoint: UpstreamEndpoint(host: "127.0.0.1", port: 2222), rules: 2)
])
check(orderedTie.first == UpstreamEndpoint(host: "127.0.0.1", port: 1111),
      "the ones with the same number of rules keep their order")

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
check(script.contains(UpstreamWait.startFlagURL(home: URL(fileURLWithPath: "/Users/tester")).path),
      "the script reads the file that says whether the app should start at all")
check(script.contains(UpstreamWait.sessionMarkerURL(home: URL(fileURLWithPath: "/Users/tester")).path),
      "the script reads the marker that says the app was already started")
check(script.contains("pgrep -x \"ProxiRoute\""), "the script does not start a second copy of the app")
check(script.contains("open -g"), "the app is started through the system when the binary is not there")
check(script.hasPrefix("#!/bin/sh"), "the script is a shell script")

// The order that was asked for: the network of the machine is there before
// the app is started, and the app is started right away - not through the
// queue of the login items, where it came up seconds after everything else.
let waitForNetwork = script.range(of: "route -n get default")
let startTheApp = script.range(of: "\"$APP_BINARY\" &")
check(waitForNetwork != nil && startTheApp != nil
        && waitForNetwork!.lowerBound < startTheApp!.lowerBound,
      "the app is started after the network of the machine is there")
check(!script.contains("nc -z"), "the script does not hold the app back for a port")

// The app goes into a group of its own, so that the agent cannot take it
// down with it. The app puts the agent in place again when it starts, and
// an agent that is taken out takes the app with it when the app is its
// program. That was measured on this machine.
check(script.contains("set -m"), "the app goes into a group of its own")
check(script.contains("while kill -0 \"$APP_PID\""), "the agent stays until the app is gone")

// The session of the login is read out of the system and handed over to
// the app, and the app writes it into the marker. The marker of a session
// that is over is of no use.
check(script.contains("/usr/bin/who"), "the session of the login is read out of the system")
check(script.contains("export PROXIRoute_SESSION"), "the session of the login is handed over to the app")
check(script.contains("[ \"$MARKED\" = \"$SESSION\" ]"), "the marker is compared with the session")

// ---------------------------------------------------------------- the agent

let agent = UpstreamWait.agentDictionary(home: URL(fileURLWithPath: "/Users/tester"))
check(agent["Label"] as? String == "com.sdpong.proxiroute.launch", "the agent has a name of its own")
check(agent["RunAtLoad"] as? Bool == true, "the agent runs at every login")
// The system does not always run the agent at the login: the domain of the
// user is in the on-demand-only mode for the first seconds of the login,
// and the job that is pending there can be dropped. It was measured on this
// machine: the job was spawned and the script never ran. So the agent comes
// back until the app is there.
check(agent["StartInterval"] as? Int == 20, "the agent comes back until the app is there")
check((agent["ProgramArguments"] as? [String])?.first == "/bin/sh", "the agent runs a shell script")
check((agent["EnvironmentVariables"] as? [String: String])?["PROXIRoute_START_HIDDEN"] == "1",
      "the agent tells the app to stay out of the way")
check(UpstreamWait.agentPlistURL(home: URL(fileURLWithPath: "/Users/tester")).path
        == "/Users/tester/Library/LaunchAgents/com.sdpong.proxiroute.launch.plist",
      "the agent is an agent of the user")

// ---------------------------------------------------------------- the switch behind the agent

// There is one answer to "does the app start at the login", and not two.
//
// The window asks the question, the launch agent asks it, and the script of
// the agent reads what it was told. When the two answers drift apart, the
// window says one thing and the machine does the other - which is what the
// two switches that never did anything were: one of them wrote the file the
// script reads, the other one was the one the window showed.
func readAppFile(_ name: String) -> String {
    let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PROXIRoute_APP"] ?? "")
        .appendingPathComponent(name)
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}
let guiSource = readAppFile("ProxiRouteGUI.swift")
let agentSource = readAppFile("LaunchOrderAgent.swift")
check(guiSource.contains("static let enabledKey = \"runAtStartup\""),
      "the switch of the login has a key of its own")
check(guiSource.contains("UserDefaults.standard.register(defaults: [enabledKey: true])"),
      "the switch of the login is on until it is turned off")
check(agentSource.contains("static var isEnabled: Bool { LoginItem.isEnabled }"),
      "the agent asks the switch of the window, and not for an answer of its own")
check(!agentSource.contains("register(defaults:"),
      "the agent does not keep an answer of its own any more")

// The switch of the login belongs to the app and not to a profile.
//
// The profile that was active held the answer from the day it was saved,
// every start of the app wrote that answer over the switch, and the person
// who had just turned the switch on found it off again the next morning.
// The launch agent starts the app and the app then loads the profile that is
// active: the profile cannot decide whether the app should be there at all.
let viewModelSource = readAppFile("ProxiRouteViewModel.swift")
let loadWorkingSet = viewModelSource.components(separatedBy: "private func loadWorkingSet(from name: String)").last?
    .components(separatedBy: "private func applyActiveProfile()").first ?? ""
check(!loadWorkingSet.contains("forKey: \"runAtStartup\""),
      "a profile does not write over the switch of the login")
check(viewModelSource.contains("LoginItem.applyToSystem(LoginItem.isEnabled)"),
      "the machine is told what the switch of the app says")

// ---------------------------------------------------------------- the session of the login

// The session is what tells this login from the next one. The agent of the
// launch reads it out of the system and hands it over in the environment,
// and the app reads it out of the system again when it is started by hand.
// Both have to give the same answer, or the marker means nothing.
setenv("PROXIRoute_SESSION", "Nov 10 11:18", 1)
check(UpstreamWait.currentSession() == "Nov 10 11:18", "the session of the agent is used")
unsetenv("PROXIRoute_SESSION")
check(UpstreamWait.currentSession() == UpstreamWait.consoleSession(),
      "the session of the login is the same answer either way")

// The marker carries the session, so that it is of no use at the next login.
let markerHome = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("proxiroute-marker-test")
check(UpstreamWait.writeSessionMarker(session: "Nov 10 11:18", home: markerHome),
      "the marker is written")
let markerText = (try? String(contentsOf: UpstreamWait.sessionMarkerURL(home: markerHome),
                              encoding: .utf8)) ?? ""
check(markerText == "Nov 10 11:18", "the marker carries the session of the login")
check(!UpstreamWait.writeSessionMarker(session: "   ", home: markerHome),
      "a marker without a session is not written")
try? FileManager.default.removeItem(at: markerHome)

// The app writes the marker a moment after it comes up: an app that dies in
// its first seconds has not really come up, and the agent has to try again.
check(readAppFile("ProxiRouteGUI.swift")
        .contains("UpstreamWait.writeSessionMarker(session: UpstreamWait.currentSession())"),
      "the app writes down that it was started in this session")

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
check(viewModel.contains("UpstreamWait.orderedLocalEndpoints(usage)"), "the upstream of this machine are picked out")
check(viewModel.contains("counts[action, default: 0] += 1"), "the rules that use every proxy are counted")
check(viewModel.contains("counts[id, default: 0] += 1"), "the rules that use a chain are counted as well")
check(viewModel.contains("refreshUpstreamWaitFile()"), "the file of the agent is written when the proxies change")
check(read("ProxyRulesView.swift").contains("viewModel.refreshUpstreamWaitFile()"),
      "the file of the agent is written when the rules change")
check(viewModel.contains("LaunchOrderAgent.writeWaitFile(for:"), "the file of the agent is written")

let agentFile = read("LaunchOrderAgent.swift")
check(agentFile.contains("func install() throws"), "the agent can be put in place")
check(agentFile.contains("func uninstall()"), "the agent can be taken out")
check(agentFile.contains("bootstrap"), "the agent is told to launchd")
check(agentFile.contains("func writeStartFlag"), "the file that says whether to start at the login is written")

// The login item follows the switch right away.
//
// There is one switch now: the agent is the launcher of the app while it is in
// place, so the app must not be a login item of macOS as well. And when the
// agent cannot be put in place, the app has to become a login item - otherwise
// a person who restarts the machine finds no proxy, and the app is only
// started by hand.
check(agentFile.contains("LoginItem.applyToSystem(LoginItem.isEnabled)"),
      "the login item follows the switch right away")
check(agentFile.contains("func sync()"), "the machine is made to match the switch")
check(read("ProxiRouteGUI.swift").contains("LaunchOrderAgent.sync()"),
      "the machine is made to match the switch at every start")
check(agentFile.contains("func writeWaitFile"), "the file that says what to wait for is written")
check(agentFile.contains("UpstreamWait.oldScriptName"), "the script of the build before this one is taken away")

// There is one switch for the start at the login, and it is the agent.
//
// Two switches were there before, and both of them did nothing: the login
// item of macOS was taken out of the system while the agent was in place, so
// the first switch changed nothing at all, and the second one - the agent -
// was not asked for the flag that says whether the app should start.
let gui = read("ProxiRouteGUI.swift")
let options = read("OptionsTabView.swift")
check(options.components(separatedBy: "Start ProxiRoute at the login").count - 1 == 1,
      "there is one switch for the start at the login")
check(!options.contains("Run at Startup"),
      "the switch that did nothing is gone")
check(!options.contains("startAfterUpstream"),
      "the second key of the start at the login is gone")
check(gui.contains("static let enabledKey = \"runAtStartup\""),
      "the switch of the start at the login is the one that is in the profile")
check(gui.contains("LaunchOrderAgent.writeStartFlag(enabled)"),
      "the flag that says whether to start at the login is written with the switch")
check(gui.contains("removeSystemLoginItem()"),
      "the app is taken out of the login items of macOS when the agent is the launcher")
check(gui.contains("addSystemLoginItem()"),
      "the app goes into the login items of macOS when the agent cannot be put in place")

// The wait ends with the upstream that carries the most: an upstream that is
// not up must not hold up the whole proxy.
check(read("UpstreamReadiness.swift").contains("let mostUsed = endpoints[0]"),
      "the wait is for the upstream that carries the most")
check(read("UpstreamReadiness.swift").contains("if ready.contains(mostUsed) { break }"),
      "the wait ends as soon as that one answers")

print("upstream wait tests: ALL PASS")
