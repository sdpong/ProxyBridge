import Foundation

// The routing options: the switches that sit above the rules. They travel
// from the app to the extension as a dictionary, and a dictionary that comes
// from an older build has none of the keys - then the defaults have to hold.

func expect(_ condition: Bool, _ message: String) {
    if !condition {
        print("FAIL: \(message)")
        exit(1)
    }
}

// the defaults: the rules decide, the system picks the way out, udp may use a proxy
let defaults = RouteOptions()
expect(!defaults.globalMode, "the global mode is off by default")
expect(defaults.globalProxyId == "DIRECT", "the global proxy is direct by default")
expect(defaults.outboundInterface.isEmpty, "the interface is left to the system by default")
expect(defaults.proxyUDP, "udp may use a proxy by default")

// a dictionary that has nothing in it is the same as the defaults
let empty = RouteOptions.fromDictionary([:])
expect(empty == defaults, "an empty dictionary gives the defaults")

// the round trip: what the app writes is what the extension reads
let dict: [String: Any] = [
    "globalMode": true,
    "globalProxyId": "108",
    "outboundInterface": "wifi",
    "proxyUDP": false
]
let read = RouteOptions.fromDictionary(dict)
expect(read.globalMode, "the global mode survives the trip")
expect(read.globalProxyId == "108", "the global proxy survives the trip")
expect(read.outboundInterface == "wifi", "the interface survives the trip")
expect(!read.proxyUDP, "the udp switch survives the trip")

// the dictionary the extension writes back is the one the app wrote
let back = read.toDictionary()
expect(back["globalMode"] as? Bool == true, "the global mode comes back")
expect(back["globalProxyId"] as? String == "108", "the global proxy comes back")
expect(back["outboundInterface"] as? String == "wifi", "the interface comes back")
expect(back["proxyUDP"] as? Bool == false, "the udp switch comes back")

// a key that is not there keeps the default, and does not make the rest vanish
let partial = RouteOptions.fromDictionary(["globalMode": true])
expect(partial.globalMode, "the global mode is read")
expect(partial.globalProxyId == "DIRECT", "a missing proxy keeps the default")
expect(partial.outboundInterface.isEmpty, "a missing interface keeps the default")
expect(partial.proxyUDP, "a missing udp switch keeps the default")

print("route tests passed")
