// A Proxifier profile (.ppx) and the import into a ProxyBridge profile.
//
// The same fixture and the same cases are in Windows/tests/test_ppx.c, so the two
// platforms cannot drift apart: the same file has to mean the same thing on both.
import Foundation

var fails = 0
func t(_ name: String, _ ok: Bool) { if !ok { fails += 1; print("FAIL", name) } }

// the profile Proxifier writes. it has one proxy of every kind, a chain with a
// switched off hop, and one rule of every action.
let sample = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<ProxifierProfile version="101" platform="MacOSX" product_id="2" product_minver="200">
    <Options>
        <Resolve>
            <AutoModeDetection enabled="false"/>
            <ViaProxy enabled="true">
                <TryLocalDnsFirst enabled="false"/>
            </ViaProxy>
            <ExclusionList ExcludeSimpleHostnames="false" ExcludeLocalhost="true" ExcludeSelfHostname="true" ExcludeLocalDomain="true">localhost;%ComputerName%;*.local;
</ExclusionList>
        </Resolve>
        <Encryption mode="disabled"/>
        <HttpProxiesSupport enabled="true"/>
    </Options>
    <ProxyList>
        <Proxy id="101" type="SOCKS5">
            <Address>127.0.0.1</Address>
            <Port>1080</Port>
            <Options>0</Options>
        </Proxy>
        <Proxy id="102" type="HTTP">
            <Address>10.0.0.2</Address>
            <Port>8080</Port>
            <Options>0</Options>
        </Proxy>
        <Proxy id="103" type="SOCKS4">
            <Address>10.0.0.3</Address>
            <Port>1080</Port>
            <Options>0</Options>
        </Proxy>
        <Proxy id="104" type="SOCKS4A">
            <Address>10.0.0.4</Address>
            <Port>1080</Port>
            <Options>0</Options>
        </Proxy>
        <Proxy id="105" type="HTTPS">
            <Address>10.0.0.5</Address>
            <Port>443</Port>
            <Options>0</Options>
        </Proxy>
        <Proxy id="106" type="SOCKS5">
            <Address>10.0.0.6</Address>
            <Port>1080</Port>
            <Options>0</Options>
            <Authentication enabled="true">
                <Username>alice</Username>
                <Password>secret</Password>
            </Authentication>
        </Proxy>
        <Proxy id="107" type="CARRIER-PIGEON">
            <Address>10.0.0.7</Address>
            <Port>1080</Port>
            <Options>0</Options>
        </Proxy>
        <Proxy id="108" type="SOCKS5">
            <Label>work</Label>
            <Address>10.0.0.8</Address>
            <Port>1080</Port>
            <Options>0</Options>
        </Proxy>
    </ProxyList>
    <ChainList>
        <Chain id="126">
            <Name>office</Name>
            <Proxy enabled="false">103</Proxy>
            <Proxy enabled="true">104</Proxy>
            <Proxy enabled="true">101</Proxy>
        </Chain>
        <Chain id="127">
            <Name>empty</Name>
            <Proxy enabled="false">103</Proxy>
        </Chain>
    </ChainList>
    <RuleList>
        <Rule enabled="true">
            <Name>direct rule</Name>
            <Targets>*.example.com; 10.0.0.0/8 </Targets>
            <Action type="Direct"/>
        </Rule>
        <Rule enabled="false">
            <Name>proxy rule</Name>
            <Applications>"WeChat.app"; com.tencent.xinWeChat; ”QQ.app"; "QQ"; com.tencent.qq; </Applications>
            <Ports>80;443</Ports>
            <Action type="Proxy">101</Action>
        </Rule>
        <Rule enabled="true">
            <Name>chain rule</Name>
            <Action type="Chain">126</Action>
        </Rule>
        <Rule enabled="true">
            <Name>block rule</Name>
            <Action type="Block"/>
        </Rule>
        <Rule enabled="true">
            <Name>dangling</Name>
            <Action type="Proxy">999</Action>
        </Rule>
        <Rule enabled="true">
            <Name>empty chain rule</Name>
            <Action type="Chain">127</Action>
        </Rule>
    </RuleList>
</ProxifierProfile>
"""

func parse(_ xml: String) -> PPXImport? {
    return PPXImporter.parse(Data(xml.utf8), name: "Proxifier")
}

// ── the file is recognised ────────────────────────────────────────────────────

t("a proxifier file is recognised", PPXImporter.looksLikePPX(Data(sample.utf8)))
t("a json profile is not a proxifier file", !PPXImporter.looksLikePPX(Data("{\"a\":1}".utf8)))
t("something that is not xml at all is not a proxifier file", parse("not xml") == nil)
t("a json document is not read as a proxifier file", parse("{\"a\":1}") == nil)

// ── the proxies ───────────────────────────────────────────────────────────────

guard let imported = parse(sample) else { fatalError("the sample profile was not read") }
let profile = imported.profile
let configs = profile["proxyConfigs"] as? [[String: Any]] ?? []
let rules = profile["proxyRules"] as? [[String: Any]] ?? []
let chains = profile["proxyChains"] as? [[String: Any]] ?? []
let policy = profile["dnsPolicy"] as? [String: Any] ?? [:]

func config(_ host: String) -> [String: Any]? { return configs.first { ($0["host"] as? String) == host } }

t("the proxies are imported", configs.count == 7)
t("a socks5 proxy stays a socks5 proxy", config("127.0.0.1")?["type"] as? String == "socks5")
t("an http proxy stays an http proxy", config("10.0.0.2")?["type"] as? String == "http")
t("a socks4 proxy stays a socks4 proxy", config("10.0.0.3")?["type"] as? String == "socks4")
t("a socks4a proxy is a socks4 proxy that sends the name", config("10.0.0.4")?["type"] as? String == "socks4" && config("10.0.0.4")?["sendDomain"] as? Bool == true)
t("a socks4 proxy does not send the name", config("10.0.0.3")?["sendDomain"] as? Bool == false)
t("an https proxy is an http proxy", config("10.0.0.5")?["type"] as? String == "http")
t("a proxy of an unknown type is left out", config("10.0.0.7") == nil)
t("the port is imported", config("127.0.0.1")?["port"] as? Int == 1080)
t("the credentials are imported", config("10.0.0.6")?["username"] as? String == "alice" && config("10.0.0.6")?["password"] as? String == "secret")
t("a proxy without credentials has none", config("127.0.0.1")?["username"] == nil)
t("the label becomes the name", config("10.0.0.8")?["name"] as? String == "work")
t("an unknown type is reported", imported.warnings.contains { $0.contains("CARRIER-PIGEON") })

// ── the chains ────────────────────────────────────────────────────────────────

t("the chains are imported", chains.count == 1)
let chain = chains.first ?? [:]
t("the chain keeps its name", chain["name"] as? String == "office")
let hops = chain["proxies"] as? [String] ?? []
t("a hop that is switched off is not walked", hops.count == 2)
t("the hops keep their order", hops.first == "104" && hops.last == "101")
t("a chain without a hop that is on is left out", !chains.contains { ($0["name"] as? String) == "empty" })
t("the empty chain is reported", imported.warnings.contains { $0.contains("empty") })

// ── the rules ─────────────────────────────────────────────────────────────────

t("the rules are imported", rules.count == 6)
t("the rules keep their order", (rules.first?["name"] as? String) == "direct rule" && (rules.last?["name"] as? String) == "empty chain rule")
t("a direct rule stays direct", rules[0]["action"] as? String == "DIRECT")
t("a block rule stays block", rules[3]["action"] as? String == "BLOCK")
t("a proxy rule points at the proxy", rules[1]["action"] as? String == "101")
t("a chain rule points at the chain", rules[2]["action"] as? String == "chain:126")
t("a rule that names a proxy that is not there goes direct", rules[4]["action"] as? String == "DIRECT")
t("a rule that names a chain that was left out goes direct", rules[5]["action"] as? String == "DIRECT")
t("the dangling rule is reported", imported.warnings.contains { $0.contains("999") })
t("the rule that names the empty chain is reported", imported.warnings.contains { $0.contains("127") })
t("a rule that is switched off stays switched off", rules[1]["enabled"] as? Bool == false)
t("a rule that is on stays on", rules[0]["enabled"] as? Bool == true)
t("proxifier proxies tcp only", rules.allSatisfy { ($0["protocol"] as? String) == "TCP" })
t("the applications lose their quotes and the .app suffix", rules[1]["processNames"] as? String == "WeChat;com.tencent.xinWeChat;QQ;com.tencent.qq")
t("the targets are trimmed and kept in one list", rules[0]["targetHosts"] as? String == "*.example.com;10.0.0.0/8")
t("the ports are imported", rules[1]["targetPorts"] as? String == "80;443")
t("a rule without targets has none", rules[2]["targetHosts"] as? String == "")

// ── the name resolution settings ──────────────────────────────────────────────

t("the proxy resolves the name", policy["mode"] as? String == "remote")
t("the name never leaks to the local resolver", policy["leakProtection"] as? Bool == true)
let excluded = policy["excludedDomains"] as? [String] ?? []
t("localhost is excluded", excluded.contains("localhost"))
t("the local domain is excluded", excluded.contains("*.local"))
t("the name of this Mac is excluded", excluded.contains(ProcessInfo.processInfo.hostName))
t("the proxifier constant is not kept", !excluded.contains("%ComputerName%"))

// the same file with the proxy resolving turned off
var localSample = sample
localSample = localSample.replacingOccurrences(of: "<ViaProxy enabled=\"true\">", with: "<ViaProxy enabled=\"false\">")
if let localImport = parse(localSample) {
    let localPolicy = localImport.profile["dnsPolicy"] as? [String: Any] ?? [:]
    t("without the proxy resolving, this machine does", localPolicy["mode"] as? String == "local")
    t("without the proxy resolving there is no leak protection", localPolicy["leakProtection"] as? Bool != true)
} else { t("the file with the proxy resolving turned off was not read", false) }

// and with the automatic detection on
var autoSample = sample
autoSample = autoSample.replacingOccurrences(of: "<AutoModeDetection enabled=\"false\"/>", with: "<AutoModeDetection enabled=\"true\"/>")
if let autoImport = parse(autoSample) {
    let autoPolicy = autoImport.profile["dnsPolicy"] as? [String: Any] ?? [:]
    t("with the automatic detection the policy is the default", autoPolicy["mode"] as? String == "system")
    t("the automatic detection is reported", autoImport.warnings.contains { $0.contains("automatically") })
} else { t("the file with the automatic detection was not read", false) }

// ── the file is not a profile at all ──────────────────────────────────────────

t("a file with another root is refused", PPXImporter.parse(Data("<Other/>".utf8)) == nil)
t("an empty file is refused", PPXImporter.parse(Data().count == 0 ? Data("<x/>".utf8) : Data()) == nil)

// a profile with nothing in it is still a profile
if let empty = parse("<ProxifierProfile/>") {
    let emptyConfigs = empty.profile["proxyConfigs"] as? [[String: Any]] ?? []
    let emptyRules = empty.profile["proxyRules"] as? [[String: Any]] ?? []
    t("a profile with nothing in it is read", emptyConfigs.isEmpty && emptyRules.isEmpty)
} else { t("a profile with nothing in it was not read", false) }

print(fails == 0 ? "proxifier profile tests: ALL PASS" : "proxifier profile tests: \(fails) FAILED")
exit(fails == 0 ? 0 : 1)
