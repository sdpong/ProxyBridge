import Foundation

// The settings of the proxy server, and what happens when they are read.
//
// The settings live in the preferences, and the preferences are a file that
// can be written by hand. A number that is written as text is still that
// number, and reading it as nothing would send the server back to its
// default port - to a port nobody asked for, while the preferences still
// say the other one.
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

// a number that is a number
check("a number is read", LocalProxySettings.number(18888) == 18888)
check("a number in a box is read", LocalProxySettings.number(NSNumber(value: 300)) == 300)

// a number that is text
check("a number written as text is read", LocalProxySettings.number("18888") == 18888)
check("a number written as text with spaces is read", LocalProxySettings.number(" 64 ") == 64)

// something that is not a number
check("text that is not a number is not read", LocalProxySettings.number("eighteen thousand") == nil)
check("nothing is not a number", LocalProxySettings.number(nil) == nil)
check("a list is not a number", LocalProxySettings.number([1, 2]) == nil)

// the port
check("a port is read", LocalProxySettings.port(18888) == 18888)
check("a port written as text is read", LocalProxySettings.port("18888") == 18888)
check("port zero is not a port", LocalProxySettings.port(0) == nil)
check("a port above the range is not a port", LocalProxySettings.port(70000) == nil)
check("a port that is not a number is not a port", LocalProxySettings.port("abc") == nil)

// the settings as a whole
let written = [
    "enabled": true,
    "protocolMode": "socks5",
    "listenAddress": "192.168.1.2",
    "listenInterface": "wifi",
    "port": "18888",
    "udpEnabled": true,
    "maxConnections": "16",
    "idleTimeout": "120",
    "upstream": "rules"
] as [String: Any]
let settings = LocalProxySettings.fromDictionary(written)
check("the port survives being written as text", settings.port == 18888)
check("the number of connections survives being written as text", settings.maxConnections == 16)
check("the idle timeout survives being written as text", settings.idleTimeout == 120)
check("the rest of the settings is read", settings.enabled && settings.udpEnabled)
check("the mode is read", settings.protocolMode == .socks5)
check("the address is read", settings.listenAddress == "192.168.1.2")
check("the interface is read", settings.listenInterface == "wifi")
check("the way out is read", settings.upstream == .rules)

// the same settings, written as numbers
var asNumbers = written
asNumbers["port"] = 18888
asNumbers["maxConnections"] = 16
asNumbers["idleTimeout"] = 120
let plain = LocalProxySettings.fromDictionary(asNumbers)
check("the port is read the same way", plain.port == 18888)
check("the number of connections is read the same way", plain.maxConnections == 16)
check("the idle timeout is read the same way", plain.idleTimeout == 120)

// the round trip: what the app writes is what it reads
var toSave = LocalProxySettings.default
toSave.port = 18888
toSave.maxConnections = 16
toSave.idleTimeout = 120
toSave.upstream = .proxy("abc")
let back = LocalProxySettings.fromDictionary(toSave.toDictionary())
check("the port survives the round trip", back.port == 18888)
check("the number of connections survives the round trip", back.maxConnections == 16)
check("the idle timeout survives the round trip", back.idleTimeout == 120)
check("the way out survives the round trip", back.upstream == .proxy("abc"))

// a port that is not a port falls back to the default
let broken = LocalProxySettings.fromDictionary(["port": "not a port"])
check("a port that is not a port falls back to the default", broken.port == 8888)

// the way out that names a proxy that is not there
let withoutProxy = LocalProxySettings.fromDictionary(["upstream": "proxy"])
check("the way out that names a proxy that is not there", withoutProxy.upstream == .proxy(""))

if fails > 0 {
    print("\(fails) check(s) failed")
    exit(1)
}
print("all checks passed")
