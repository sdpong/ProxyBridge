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

// the leak protection switch sends the query through the proxy
policy = DNSPolicy()
policy.leakProtection = true
switch policy.decision(for: "example.com") {
case .forwardThroughProxy: t("leak protection tunnels the query", true)
default: t("leak protection tunnels the query", false)
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

print(fails == 0 ? "dns policy tests: ALL PASS" : "dns policy tests: \(fails) FAILED")
exit(fails == 0 ? 0 : 1)
