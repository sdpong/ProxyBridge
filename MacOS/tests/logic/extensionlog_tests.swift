// extension log tests: what the app makes of the lines the system extension
// writes to the unified log.
//
// The extension writes one line per connection it handled, and a build that is
// not signed by a developer reads that log back instead of asking the extension
// over the message channel. So the parsing of that line decides what the window
// shows - a line that is read wrong is a connection that is shown wrong.

import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) {
    if ok { print("  ok   \(what)") } else { failures += 1; print("  FAIL \(what)") }
}

// the common case: a host name, a rule number
let simple = ExtensionLogReader.parse("Connection TCP WeChat -> 240e:978:d04:3001::1d:80 via Direct (rule 3)")
check(simple?.proto == "TCP", "the protocol is read")
check(simple?.process == "WeChat", "the process is read")
check(simple?.destination == "240e:978:d04:3001::1d", "an ipv6 destination keeps its colons")
check(simple?.port == "80", "the port is read")
check(simple?.proxy == "Direct", "the proxy is read")
check(simple?.rule == 3, "the rule number is read")

// a process name with spaces in it
let spaced = ExtensionLogReader.parse("Connection TCP MiniMax Code Helper -> agent.minimax.cn:443 via Direct (rule 26)")
check(spaced?.process == "MiniMax Code Helper", "a process name with spaces is read whole")
check(spaced?.destination == "agent.minimax.cn", "the destination is read")
check(spaced?.port == "443", "the port is read")
check(spaced?.rule == 26, "the rule number is read")

// a proxy with a host and a port in its name, and no rule number
let proxy = ExtensionLogReader.parse("Connection TCP Python -> github.com:443 via SOCKS5 127.0.0.1:9991")
check(proxy?.proxy == "SOCKS5 127.0.0.1:9991", "a proxy with an address is read whole")
check(proxy?.rule == nil, "no rule number means no rule number")
check(proxy?.destination == "github.com", "the destination is read")

// a host name that is only a host name and no port at all: not a connection
check(ExtensionLogReader.parse("Connection TCP Python -> github.com via Direct") == nil,
      "a line without a port is not a connection")

// the other lines of the extension are not connections
check(ExtensionLogReader.parse("Tunnel starting") == nil, "a note is not a connection")
check(ExtensionLogReader.parse("Flow #2300 from com.openai.codex.helper") == nil, "a flow line is not a connection")
check(ExtensionLogReader.parse("") == nil, "an empty line is not a connection")

// the rule number is optional and comes off the proxy name
let noRule = ExtensionLogReader.parse("Connection UDP Game -> 8.8.4.4:53 via Direct")
check(noRule?.proxy == "Direct", "the proxy keeps its name when there is no rule")
check(noRule?.rule == nil, "no rule number means no rule number")

// the line the tool that reads the log writes, and the parsing of it
//
// 2026-11-07 15:54:32.627 Df com.sdpong.proxybridge.extension[32915:5e4ee] [com.interceptsuite.ProxyBridge.extension:provider] Connection UDP MiniMax Code Helper -> unknown:unknown via Direct
let compact = ExtensionLogReader.parseCompact("2026-11-07 15:54:32.627 Df com.sdpong.proxybridge.extension[32915:5e4ee] [com.interceptsuite.ProxyBridge.extension:provider] Connection UDP MiniMax Code Helper -> unknown:unknown via Direct")
check(compact != nil, "a line of the tool is read")
check(compact?.level == "INFO", "a note is not an error")
check(compact?.text == "Connection UDP MiniMax Code Helper -> unknown:unknown via Direct",
      "the message is read whole")
check(compact?.connection?.process == "MiniMax Code Helper", "the connection in it is read")
check(compact?.connection?.proto == "UDP", "the protocol in it is read")

// an error the extension wrote comes with its own mark
let errorLine = ExtensionLogReader.parseCompact("2026-11-07 15:54:33.001 Ee com.sdpong.proxybridge.extension[32915:5e4ee] [com.interceptsuite.ProxyBridge.extension:provider] Tunnel stopping: stopped by the user (1)")
check(errorLine?.level == "ERROR", "an error is an error")
check(errorLine?.connection == nil, "an error is not a connection")

// the two lines the tool writes before the first entry are not lines of the log
check(ExtensionLogReader.parseCompact("Filtering the log data using \"subsystem == \\\"x\\\"\"") == nil,
      "the header of the tool is not a line")
check(ExtensionLogReader.parseCompact("Timestamp               Ty Process[PID:TID]") == nil,
      "the column header of the tool is not a line")

// an empty line is not a line either
check(ExtensionLogReader.parseCompact("") == nil, "an empty line is not a line")

// the traffic of the open flows
//
// The extension counts the bytes of every flow it proxies and writes them to the log,
// because the message channel that used to carry them is closed for a build that is not
// signed by a developer. Three kinds of line carry it: a flow that opened, the flows that
// are open right now, and a flow that closed.
if case .open(let id, let proto, let process, let destination, let port, let proxy)? = ExtensionLogReader.parseFlow("FlowOpen 42 TCP curl -> api.github.com:443 via SOCKS5 127.0.0.1:19998") {
    check(id == 42, "the id of the flow is read")
    check(proto == "TCP", "the protocol of the flow is read")
    check(process == "curl", "the process of the flow is read")
    check(destination == "api.github.com", "the destination of the flow is read")
    check(port == "443", "the port of the flow is read")
    check(proxy == "SOCKS5 127.0.0.1:19998", "the proxy of the flow is read whole")
} else {
    check(false, "a flow that opened is read")
}

// a process name with spaces in it, and an ipv6 destination
if case .open(let id, let proto, let process, let destination, let port, let proxy)? = ExtensionLogReader.parseFlow("FlowOpen 7 TCP MiniMax Code Helper -> 240e:978:d04:3001::1d:80 via Direct") {
    check(id == 7, "the id of the flow is read")
    check(process == "MiniMax Code Helper", "a process name with spaces is read whole")
    check(destination == "240e:978:d04:3001::1d", "an ipv6 destination keeps its colons")
    check(port == "80", "the port is read")
    check(proxy == "Direct", "the proxy is read")
} else {
    check(false, "a flow with a long process name is read")
}

if case .bytes(let rows)? = ExtensionLogReader.parseFlow("Flows 42:1234:5678 43:10:20") {
    check(rows.count == 2, "both flows are read")
    check(rows[0].id == 42 && rows[0].up == 1234 && rows[0].down == 5678, "the bytes of the first flow are read")
    check(rows[1].id == 43 && rows[1].up == 10 && rows[1].down == 20, "the bytes of the second flow are read")
} else {
    check(false, "the open flows are read")
}

if case .end(let id, let up, let down)? = ExtensionLogReader.parseFlow("FlowEnd 42 9876 65432") {
    check(id == 42, "the id of the closed flow is read")
    check(up == 9876, "the bytes it sent are read")
    check(down == 65432, "the bytes it received are read")
} else {
    check(false, "a closed flow is read")
}

// a flow that is open right now: the line that carries everything about it, so a
// flow that was already open when the window opened can be shown too
if case .live(let id, let proto, let process, let destination, let port, let proxy, let up, let down)? =
    ExtensionLogReader.parseFlow("FlowLive 474 TCP Tabbit Browser Helper -> chat-ws.x.com:443 via SOCKS5 127.0.0.1:9991 4420 5108") {
    check(id == 474, "the id of the open flow is read")
    check(proto == "TCP", "the protocol of the open flow is read")
    check(process == "Tabbit Browser Helper", "a process name with spaces is read whole")
    check(destination == "chat-ws.x.com", "the destination of the open flow is read")
    check(port == "443", "the port of the open flow is read")
    check(proxy == "SOCKS5 127.0.0.1:9991", "the proxy of the open flow is read whole")
    check(up == 4420, "the bytes it sent are read")
    check(down == 5108, "the bytes it received are read")
} else {
    check(false, "an open flow is read")
}

// the bytes are the last two words of the line, so a proxy name with a space in it
// does not throw the reading off
if case .live(let id, _, _, _, _, let proxy, let up, let down)? =
    ExtensionLogReader.parseFlow("FlowLive 7 TCP curl -> api.github.com:443 via SOCKS5 127.0.0.1:9991 10 20") {
    check(id == 7, "the id is read")
    check(proxy == "SOCKS5 127.0.0.1:9991", "the proxy is read whole")
    check(up == 10 && down == 20, "the bytes are read")
} else {
    check(false, "an open flow with a proxy name in it is read")
}

// a udp flow has no destination until its first datagram arrives
if case .live(let id, _, _, let destination, let port, _, _, _)? =
    ExtensionLogReader.parseFlow("FlowLive 9 UDP curl -> :443 via Direct 0 0") {
    check(id == 9, "the id of a flow without a destination is read")
    check(destination.isEmpty, "a flow without a destination has none")
    check(port == "443", "the port of a flow without a destination is read")
} else {
    check(false, "an open flow without a destination is read")
}

// a broken line is not read as something
check(ExtensionLogReader.parseFlow("FlowLive abc TCP curl -> host:443 via Direct 1 2") == nil,
      "an open flow without a number is not read")
check(ExtensionLogReader.parseFlow("FlowLive 42 TCP curl -> host:443 via Direct 1") == nil,
      "an open flow without both numbers is not read")
check(ExtensionLogReader.parseFlow("FlowLive 42 TCP curl -> host:443 via Direct x y") == nil,
      "an open flow with broken numbers is not read")

// the totals of every proxy: the numbers the extension counted itself
if let totals = ExtensionLogReader.parseProxyTotals("ProxyTotals SOCKS5 127.0.0.1:9991|827000|7080000|292;Direct|0|0|820") {
    check(totals.count == 2, "both proxies are read")
    check(totals[0].proxy == "SOCKS5 127.0.0.1:9991", "a proxy name with a space in it is read whole")
    check(totals[0].up == 827000, "the bytes it sent are read")
    check(totals[0].down == 7080000, "the bytes it received are read")
    check(totals[0].connections == 292, "the connections of the proxy are read")
    check(totals[1].proxy == "Direct", "the second proxy is read")
    check(totals[1].connections == 820, "the connections of the second proxy are read")
} else {
    check(false, "the totals of the proxies are read")
}

check(ExtensionLogReader.parseProxyTotals("ProxyTotals SOCKS5|1|x|2") == nil,
      "totals with broken numbers are not read")
check(ExtensionLogReader.parseProxyTotals("Connection TCP WeChat -> host:443 via Direct") == nil,
      "a connection is not a set of totals")
check(ExtensionLogReader.parseProxyTotals("ProxyTotals ") == nil,
      "totals without a proxy are not read")

// the totals are read out of the line of the tool as well
let totalsLine = ExtensionLogReader.parseCompact("2026-11-07 17:00:00.123 Df com.sdpong.proxybridge.extension[32915:5e4ee] [com.interceptsuite.ProxyBridge.extension:provider] ProxyTotals Direct|0|0|820")
check(totalsLine?.proxyTotals?.first?.connections == 820, "the totals of a line of the tool are read")
check(totalsLine?.flowEvent == nil, "a line of totals is not a flow")

// lines that are not about the traffic of the flows
check(ExtensionLogReader.parseFlow("Connection TCP WeChat -> unknown:unknown via Direct") == nil,
      "a connection is not a flow")
check(ExtensionLogReader.parseFlow("Flow #2300 from com.openai.codex.helper") == nil,
      "the flow counter is not a flow")
check(ExtensionLogReader.parseFlow("Tunnel starting") == nil, "a note is not a flow")

// a line that is broken is not read as something
check(ExtensionLogReader.parseFlow("FlowOpen abc TCP curl -> host:443 via Direct") == nil,
      "a flow without a number is not read")
check(ExtensionLogReader.parseFlow("FlowEnd 42 9876") == nil,
      "a closed flow without both numbers is not read")

// the traffic lines are read out of the line of the tool as well
let flowLine = ExtensionLogReader.parseCompact("2026-11-07 17:00:00.123 Df com.sdpong.proxybridge.extension[32915:5e4ee] [com.interceptsuite.ProxyBridge.extension:provider] Flows 42:1234:5678")
if case .bytes(let rows)? = flowLine?.flowEvent {
    check(rows.first?.id == 42, "the traffic of a line of the tool is read")
} else {
    check(false, "the traffic of a line of the tool is read")
}
check(flowLine?.connection == nil, "a traffic line is not a connection")

if failures > 0 {
    print("extension log tests: \(failures) FAILED")
    exit(1)
}
print("extension log tests: ALL PASS")
