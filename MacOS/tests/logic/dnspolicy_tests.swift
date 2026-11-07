// DNSPolicy: the three resolution modes, the exclusion list, the resolver choice,
// the leak protection switch and the wire form. Compiled as main.swift by run.sh.
import Foundation

var fails = 0
func t(_ name: String, _ ok: Bool) { if !ok { fails += 1; print("FAIL", name) } }

// the default policy: the system resolver answers and nothing is excluded
var policy = DNSPolicy()
t("the default mode is system", policy.mode == .system)
t("nothing is excluded by default", !policy.isExcluded("example.com"))
t("there is no preferred resolver by default", policy.preferredResolver == nil)

// system mode: the system resolver answers
switch policy.decision(for: "example.com") {
case .forward(let resolver): t("system mode uses the system resolver", resolver == nil)
default: t("system mode uses the system resolver", false)
}

// local mode with a configured resolver asks that resolver
policy.mode = .local
policy.upstreamResolvers = ["1.1.1.1", "8.8.8.8"]
switch policy.decision(for: "example.com") {
case .forward(let resolver): t("local mode asks the first configured resolver", resolver == "1.1.1.1")
default: t("local mode asks the first configured resolver", false)
}

// remote mode asks the same resolver, but the proxy server resolves the name
policy.mode = .remote
switch policy.decision(for: "example.com") {
case .forward(let resolver): t("remote mode asks the configured resolver", resolver == "1.1.1.1")
default: t("remote mode asks the configured resolver", false)
}
t("remote mode hands the name to the proxy", policy.addressing(for: "example.com") == .hostname)

// a resolver that cannot be read is skipped, the next one is used
policy.upstreamResolvers = ["1.1.1.1:abc", "8.8.8.8"]
t("a broken resolver is skipped", policy.preferredResolver == "8.8.8.8")
policy.upstreamResolvers = ["1.1.1.1:abc"]
t("a list of broken resolvers has none", policy.preferredResolver == nil)

// what the transparent proxy gets differs per mode
policy.mode = .local
t("local mode hands the address to the proxy", policy.addressing(for: "example.com") == .address)
policy.mode = .system
t("system mode leaves the choice to the rule", policy.addressing(for: "example.com") == nil)

// the exclusion list
policy = DNSPolicy()
policy.excludedDomains = ["example.com", "*.internal.corp"]
t("an excluded name is excluded", policy.isExcluded("example.com"))
t("the exclusion list is not case sensitive", policy.isExcluded("EXAMPLE.COM"))
t("a trailing dot does not hide the name", policy.isExcluded("example.com."))
t("an unrelated name is not excluded", !policy.isExcluded("other.test"))
t("a wildcard in the list works", policy.isExcluded("host.internal.corp"))
switch policy.decision(for: "example.com") {
case .excluded: t("an excluded name is not forwarded", true)
default: t("an excluded name is not forwarded", false)
}
t("an excluded name goes to the proxy as an address", policy.addressing(for: "example.com") == .address)

// a wildcard only covers the names below it
policy = DNSPolicy()
policy.excludedDomains = ["*.example.com"]
t("a wildcard covers a subdomain", policy.isExcluded("www.example.com"))
t("a wildcard covers a deep subdomain", policy.isExcluded("a.b.example.com"))
t("a wildcard does not cover the apex", !policy.isExcluded("example.com"))
t("a wildcard does not cover a different name", !policy.isExcluded("example.org"))
t("a wildcard does not cover a name that only ends the same", !policy.isExcluded("notexample.com"))

// a bare name covers only itself
policy = DNSPolicy()
policy.excludedDomains = ["example.com"]
t("a bare name covers only itself", policy.isExcluded("example.com") && !policy.isExcluded("www.example.com"))

// the star pattern covers everything
policy = DNSPolicy()
policy.excludedDomains = ["*"]
t("the star covers everything", policy.isExcluded("example.com") && policy.isExcluded("a.b.c.test"))

// an empty pattern excludes nothing
policy = DNSPolicy()
policy.excludedDomains = ["", "   "]
t("an empty pattern excludes nothing", !policy.isExcluded("example.com"))

// the leak protection switch makes the proxy server resolve the name. it does
// not change where the query goes: the query is still answered by the resolver
// of this mac
policy = DNSPolicy()
policy.leakProtection = true
switch policy.decision(for: "example.com") {
case .forward: t("leak protection does not change where the query goes", true)
default: t("leak protection does not change where the query goes", false)
}
policy.excludedDomains = ["example.com"]
switch policy.decision(for: "example.com") {
case .excluded: t("an excluded name wins over leak protection", true)
default: t("an excluded name wins over leak protection", false)
}

// leak protection forces the name, whatever the mode says
policy = DNSPolicy()
policy.leakProtection = true
policy.mode = .local
t("leak protection makes the proxy resolve the name", policy.addressing(for: "example.com") == .hostname)
policy.mode = .system
t("leak protection wins over the system mode", policy.addressing(for: "example.com") == .hostname)
policy.excludedDomains = ["example.com"]
t("an excluded name still goes as an address", policy.addressing(for: "example.com") == .address)

// a resolver is a host and a port
if let parsed = DNSPolicy.normalizeResolver("1.1.1.1") {
    t("a bare address gets the default port", parsed.host == "1.1.1.1" && parsed.port == 53)
} else {
    t("a bare address gets the default port", false)
}
if let parsed = DNSPolicy.normalizeResolver(" 8.8.8.8:5353 ") {
    t("an address with a port keeps it", parsed.host == "8.8.8.8" && parsed.port == 5353)
} else {
    t("an address with a port keeps it", false)
}
t("an empty resolver is nothing", DNSPolicy.normalizeResolver("  ") == nil)
t("a broken port is nothing", DNSPolicy.normalizeResolver("1.1.1.1:abc") == nil)
t("a port of zero is nothing", DNSPolicy.normalizeResolver("1.1.1.1:0") == nil)

// the wire form keeps everything
policy = DNSPolicy()
policy.mode = .remote
policy.excludedDomains = ["a.test", "*.b.test"]
policy.upstreamResolvers = ["9.9.9.9"]
policy.autoDetectUpstream = false
policy.leakProtection = true
let wire = policy.toDictionary()
let back = DNSPolicy.fromDictionary(wire)
t("the mode survives the wire", back.mode == .remote)
t("the exclusion list survives the wire", back.excludedDomains == ["a.test", "*.b.test"])
t("the resolvers survive the wire", back.upstreamResolvers == ["9.9.9.9"])
t("auto detect survives the wire", back.autoDetectUpstream == false)
t("leak protection survives the wire", back.leakProtection == true)

// an old app sends nothing: the extension keeps the defaults
let empty = DNSPolicy.fromDictionary([:])
t("an empty message keeps the default mode", empty.mode == .system)
t("an empty message keeps auto detect on", empty.autoDetectUpstream == true)
t("an empty message keeps leak protection off", empty.leakProtection == false)

// an unknown mode is ignored rather than crashing the extension
let odd = DNSPolicy.fromDictionary(["mode": "sideways"])
t("an unknown mode falls back to the default", odd.mode == .system)

// ---- the app and the extension must agree ------------------------------------
// The app writes the policy into the profile, the extension reads it back. If the two
// models drift apart the policy silently stops working, so every field is compared
// here, in every combination.
do {
    var app = DNSPolicySettings()
    app.mode = .remote
    app.excludedDomains = ["a.test", "*.b.test"]
    app.upstreamResolvers = ["9.9.9.9"]
    app.autoDetectUpstream = false
    app.leakProtection = true

    var ext = DNSPolicy()
    ext.mode = .remote
    ext.excludedDomains = ["a.test", "*.b.test"]
    ext.upstreamResolvers = ["9.9.9.9"]
    ext.autoDetectUpstream = false
    ext.leakProtection = true

    let appWire = app.toDictionary()
    let extWire = ext.toDictionary()
    t("the app and the extension write the same keys",
      Set(appWire.keys) == Set(extWire.keys))
    t("the app and the extension write the same mode", appWire["mode"] as? String == extWire["mode"] as? String)
    t("the app and the extension write the same exclusions",
      (appWire["excludedDomains"] as? [String]) == (extWire["excludedDomains"] as? [String]))
    t("the app and the extension write the same resolvers",
      (appWire["upstreamResolvers"] as? [String]) == (extWire["upstreamResolvers"] as? [String]))
    t("the app and the extension write the same auto detect flag",
      (appWire["autoDetectUpstream"] as? Bool) == (extWire["autoDetectUpstream"] as? Bool))
    t("the app and the extension write the same leak protection flag",
      (appWire["leakProtection"] as? Bool) == (extWire["leakProtection"] as? Bool))

    // what the app writes is what the extension reads back
    let back = DNSPolicy.fromDictionary(appWire)
    t("the extension reads the mode the app wrote", back.mode == .remote)
    t("the extension reads the exclusions the app wrote", back.excludedDomains == ["a.test", "*.b.test"])
    t("the extension reads the resolvers the app wrote", back.upstreamResolvers == ["9.9.9.9"])
    t("the extension reads the auto detect flag the app wrote", back.autoDetectUpstream == false)
    t("the extension reads the leak protection flag the app wrote", back.leakProtection == true)

    // every mode and flag combination must survive the trip
    for modeName in ["system", "local", "remote"] {
        for leak in [true, false] {
            for auto in [true, false] {
                var a = DNSPolicySettings()
                a.mode = DNSPolicySettings.Mode(rawValue: modeName)!
                a.leakProtection = leak
                a.autoDetectUpstream = auto
                a.excludedDomains = ["x.test"]
                a.upstreamResolvers = ["1.1.1.1"]
                let e = DNSPolicy.fromDictionary(a.toDictionary())
                t("the mode survives the trip (\(modeName))", e.mode.rawValue == modeName)
                t("the leak protection survives the trip (\(modeName))", e.leakProtection == leak)
                t("the auto detect flag survives the trip (\(modeName))", e.autoDetectUpstream == auto)
                t("the exclusions survive the trip (\(modeName))", e.excludedDomains == ["x.test"])
                t("the resolvers survive the trip (\(modeName))", e.upstreamResolvers == ["1.1.1.1"])
            }
        }
    }

    // the list the user typed survives the round trip through the app's own model
    t("the app keeps the names the user typed",
      DNSPolicySettings.parseList("a.test\n *.b.test \n\nc.test") == ["a.test", "*.b.test", "c.test"])
    t("the app writes the list back the way it reads it",
      DNSPolicySettings.formatList(["a.test", "*.b.test"]) == "a.test\n*.b.test")
}

print(fails == 0 ? "dns policy tests: ALL PASS" : "dns policy tests: \(fails) FAILED")
exit(fails == 0 ? 0 : 1)
