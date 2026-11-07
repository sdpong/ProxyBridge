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

if failures > 0 {
    print("extension log tests: \(failures) FAILED")
    exit(1)
}
print("extension log tests: ALL PASS")
