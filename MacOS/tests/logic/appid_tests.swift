// ProxyAppIdentity: what the proxy server is told about the application the
// traffic comes from.
// Compiled as main.swift by run.sh.
import Foundation

var fails = 0
func t(_ name: String, _ ok: Bool) { if !ok { fails += 1; print("FAIL", name) } }

let payload = ProxyAppIdentity.Payload(bundleId: "com.example.app", processName: "Example")

// the value that is sent: the bundle id identifies the app on every system
t("the bundle id is the value", payload.value == "com.example.app")
t("a payload without a bundle id falls back to the process name",
  ProxyAppIdentity.Payload(bundleId: "", processName: "Example").value == "Example")
t("an empty payload is empty", ProxyAppIdentity.Payload(bundleId: "", processName: "").isEmpty)
t("a payload with a bundle id is not empty", !payload.isEmpty)

// the http headers
t("no payload means no header", ProxyAppIdentity.httpHeaderLines(for: nil).isEmpty)
t("an empty payload means no header", ProxyAppIdentity.httpHeaderLines(for: ProxyAppIdentity.Payload(bundleId: "", processName: "")).isEmpty)
let lines = ProxyAppIdentity.httpHeaderLines(for: payload)
t("there is a header for the bundle id", lines.contains("ProxyBridge-App-Id: com.example.app"))
t("there is a header for the process name", lines.contains("ProxyBridge-Process: Example"))
t("there are two headers", lines.count == 2)

// a header value may not end the header
t("a line break in a name is removed", ProxyAppIdentity.headerSafe("Dia\r\nInjected: yes") == "Dia  Injected: yes")
t("a name is trimmed", ProxyAppIdentity.headerSafe("  Dia  ") == "Dia")
let injected = ProxyAppIdentity.httpHeaderLines(for: ProxyAppIdentity.Payload(bundleId: "a\r\nX: y", processName: ""))
t("no header value carries a line break", !injected.contains { $0.contains("\r") || $0.contains("\n") })

// the socks5 greeting
// the user/password method has to be offered on its own: a server that prefers
// "no authentication" would pick that one and the name would never arrive
t("the name alone offers only the user/password method",
  ProxyAppIdentity.socks5GreetingMethods(sendAppId: true, hasCredentials: false) == [0x02])
t("without the name only the plain method is offered",
  ProxyAppIdentity.socks5GreetingMethods(sendAppId: false, hasCredentials: false) == [0x00])
t("credentials offer both methods",
  ProxyAppIdentity.socks5GreetingMethods(sendAppId: false, hasCredentials: true) == [0x00, 0x02])
t("credentials win over the name",
  ProxyAppIdentity.socks5GreetingMethods(sendAppId: true, hasCredentials: true) == [0x00, 0x02])

// the socks5 credentials
let creds = ProxyAppIdentity.socks5Credentials(payload: payload, username: "bob", password: "secret")
t("the configured credentials are used", creds?.username == "bob" && creds?.password == "secret")
let idCreds = ProxyAppIdentity.socks5Credentials(payload: payload, username: nil, password: nil)
t("the name is used when there are no credentials", idCreds?.username == "com.example.app")
t("the password is not empty", idCreds?.password == "com.example.app")
t("an empty user name is not a credential",
  ProxyAppIdentity.socks5Credentials(payload: payload, username: "", password: "x")?.username == "com.example.app")
t("without a name and without credentials there is nothing to send",
  ProxyAppIdentity.socks5Credentials(payload: nil, username: nil, password: nil) == nil)
t("an empty payload sends nothing",
  ProxyAppIdentity.socks5Credentials(payload: ProxyAppIdentity.Payload(bundleId: "", processName: ""), username: nil, password: nil) == nil)

// the socks4 user id
t("the configured user id is used", ProxyAppIdentity.socks4UserId(payload: payload, username: "bob") == "bob")
t("the name is used when there is no user id", ProxyAppIdentity.socks4UserId(payload: payload, username: nil) == "com.example.app")
t("an empty user id is no user id", ProxyAppIdentity.socks4UserId(payload: payload, username: "") == "com.example.app")
t("without a name there is no user id", ProxyAppIdentity.socks4UserId(payload: nil, username: nil) == nil)

// what the rule that matched decides
let bridge = "com.sdpong.proxybridge.extension"

// a rule that names the program tells the proxy which program it is
let withFilter = ProxyAppIdentity.payload(bundleId: "com.example.app",
                                          processName: "Example",
                                          ruleHasProcessFilter: true,
                                          proxyBridgeBundleId: bridge)
t("a rule with a program filter names the program", withFilter.bundleId == "com.example.app")
t("a rule with a program filter keeps the name of the program", withFilter.processName == "Example")
t("a rule with a program filter sends the program", withFilter.value == "com.example.app")

// a rule that names no program says that the traffic is ProxyBridge's own
let withoutFilter = ProxyAppIdentity.payload(bundleId: "com.example.app",
                                             processName: "Example",
                                             ruleHasProcessFilter: false,
                                             proxyBridgeBundleId: bridge)
t("a rule without a program filter names ProxyBridge", withoutFilter.bundleId == bridge)
t("a rule without a program filter sends the name of ProxyBridge", withoutFilter.value == bridge)
t("a rule without a program filter sends no program name", withoutFilter.processName.isEmpty)
t("a rule without a program filter is not empty", !withoutFilter.isEmpty)

// the header of the virtual name
let virtualLines = ProxyAppIdentity.httpHeaderLines(for: withoutFilter)
t("the virtual name is in the header", virtualLines.contains("ProxyBridge-App-Id: \(bridge)"))
t("the virtual name is the only header", virtualLines.count == 1)

// the socks5 user name of the virtual name
let virtualCreds = ProxyAppIdentity.socks5Credentials(payload: withoutFilter, username: nil, password: nil)
t("the virtual name is the socks5 user name", virtualCreds?.username == bridge)

print(fails == 0 ? "appid tests: ALL PASS" : "appid tests: \(fails) FAILED")
exit(fails == 0 ? 0 : 1)
