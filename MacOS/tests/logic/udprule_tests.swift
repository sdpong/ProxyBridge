// The rule that takes the udp of a program (AppProxyProvider.udpRuleChoice).
//
// The case that matters: a browser that prefers QUIC sends its sign-in over
// udp/443. When the rules of that program say "TCP" only, no rule takes the
// udp, the traffic goes around the proxy, and the site answers the sign-in
// with a cloudflare error while every other request of the same program works.
//
// Compiled as main.swift by run.sh.

import Foundation

var fails = 0
func t(_ name: String, _ got: Bool, _ expected: Bool) {
    if got != expected { fails += 1; print("FAIL", name) }
}

func r(_ id: UInt32,
       _ processes: String,
       _ hosts: String = "",
       _ ports: String = "*",
       _ proto: RuleProtocol = .tcp,
       _ action: String = "DIRECT",
       _ enabled: Bool = true) -> (rule: ProxyRule, matcher: ProxyRule.Matcher) {
    let rule = ProxyRule(ruleId: id, processNames: processes, targetHosts: hosts,
                         targetPorts: ports, ruleProtocol: proto, action: action, enabled: enabled)
    return (rule, ProxyRule.Matcher(rule))
}

func choose(_ rules: [(rule: ProxyRule, matcher: ProxyRule.Matcher)],
            _ bundleId: String = "company.thebrowser.dia",
            _ processName: String? = "Dia",
            canCarryUDP: @escaping (ProxyRule) -> Bool = { _ in true })
    -> (rule: ProxyRule, matcher: ProxyRule.Matcher, isFallback: Bool)? {
    AppProxyProvider.udpRuleChoice(rules: rules, bundleId: bundleId, processName: processName,
                                   canCarryUDP: canCarryUDP)
}

// the program that says "Dia goes through that proxy" in tcp only
let diaTCP = r(1, "Dia;company.thebrowser.dia", "*", "*", .tcp, "108")

// 1. the rule that names the udp of the program wins
let withUDP = choose([r(2, "Dia", "*", "*", .udp, "117"), diaTCP])
t("the rule that names the udp wins", withUDP?.rule.ruleId == 2, true)
t("the rule that names the udp is not a fallback", withUDP?.isFallback == false, true)

// 2. a rule that says both is a rule about the udp as well
let withBoth = choose([r(3, "Dia", "*", "*", .both, "117"), diaTCP])
t("a rule that says both names the udp", withBoth?.rule.ruleId == 3, true)
t("a rule that says both is not a fallback", withBoth?.isFallback == false, true)

// 3. the case of the sign-in: only the tcp of the program is named
let fallback = choose([diaTCP])
t("the tcp of the program takes its udp", fallback?.rule.ruleId == 1, true)
t("the log says that the udp follows the tcp", fallback?.isFallback == true, true)

// 4. the rule of the program wins over the rule that names everything
let programBeatsWildcard = choose([r(4, "", "*", "*", .both, "117"), diaTCP])
t("the rule of the program wins over the wildcard", programBeatsWildcard?.rule.ruleId == 1, true)
t("the wildcard is not a fallback", programBeatsWildcard?.isFallback == true, true)

// 5. the rule that names everything takes the udp of a program without a rule
let wildcard = choose([r(5, "", "*", "*", .both, "117")])
t("the wildcard takes the udp", wildcard?.rule.ruleId == 5, true)
t("the wildcard is not a fallback", wildcard?.isFallback == false, true)

// 6. a rule that names everything and only the tcp does not take the udp
let tcpWildcard = choose([r(6, "", "*", "*", .tcp, "DIRECT")])
t("a tcp wildcard does not take the udp", tcpWildcard == nil, true)

// 7. a rule of another program does not take the udp of this program
let otherProgram = choose([r(7, "Safari;com.apple.Safari", "*", "*", .both, "117")])
t("the rule of another program does not take the udp", otherProgram == nil, true)

// 8. a disabled rule is not used
let disabled = choose([r(8, "Dia", "*", "*", .both, "117", false)])
t("a disabled rule is not used", disabled == nil, true)

// 9. a rule with a host filter and no program filter cannot take the udp:
//    the destination of a udp flow is only known once the first datagram
//    arrives, so a rule about a host says nothing about the flow
let hostOnly = choose([r(9, "", "*.cloudflare.com", "*", .both, "117")])
t("a rule about a host does not take the udp", hostOnly == nil, true)

// 10. when the proxy of the rule cannot carry udp, the fallback is not used:
//     the udp keeps the way it went before
let chainRule = choose([r(10, "Dia", "*", "*", .tcp, "chain:126")], canCarryUDP: { _ in false })
t("a rule that cannot carry udp is not used as a fallback", chainRule == nil, true)

// 11. the rule of the program that says direct takes its udp as well
let directRule = choose([r(11, "Dia", "*", "*", .tcp, "DIRECT")])
t("a direct rule of the program takes its udp", directRule?.rule.ruleId == 11, true)
t("a direct rule of the program is a fallback", directRule?.isFallback == true, true)

// 12. the rule that names the udp is used even when the tcp of the program
//     comes first in the list
let order = choose([diaTCP, r(12, "Dia", "*", "*", .udp, "117")])
t("the rule that names the udp wins over the tcp of the same program", order?.rule.ruleId == 12, true)

// 13. the first rule of the program that can carry udp is the one that takes
//     the udp
let twoTCPRules = choose([r(13, "Dia", "*", "*", .tcp, "117"), r(14, "Dia", "*", "*", .tcp, "108")])
t("the first rule of the program takes the udp", twoTCPRules?.rule.ruleId == 13, true)

// 14. no rule at all: the global mode decides
t("no rule leaves the udp to the global mode", choose([]) == nil, true)

// 15. the quic of a program whose tcp goes through a proxy is stopped: the
//     quic is a second way out, and the proxy is not always told the name of
//     the destination, so the way out it takes is not the one the rule named
t("the quic of a program whose tcp goes through a proxy is stopped",
  AppProxyProvider.blocksQUIC(ruleProtocol: .tcp, tookTheUDPByFallback: true, action: "108"), true)
t("a chain is a proxy as well",
  AppProxyProvider.blocksQUIC(ruleProtocol: .tcp, tookTheUDPByFallback: true, action: "chain:126"), true)
t("an http proxy is a proxy as well",
  AppProxyProvider.blocksQUIC(ruleProtocol: .tcp, tookTheUDPByFallback: true, action: "117"), true)

// 16. a program that goes out directly goes out directly
t("a rule that sends the program out directly does not stop the quic",
  AppProxyProvider.blocksQUIC(ruleProtocol: .tcp, tookTheUDPByFallback: true, action: "DIRECT"), false)
t("a rule that blocks the program does not stop the quic",
  AppProxyProvider.blocksQUIC(ruleProtocol: .tcp, tookTheUDPByFallback: true, action: "BLOCK"), false)

// 17. a rule that speaks for the udp is not stopped
t("a rule that says udp keeps the quic",
  AppProxyProvider.blocksQUIC(ruleProtocol: .udp, tookTheUDPByFallback: false, action: "108"), false)
t("a rule that says both keeps the quic",
  AppProxyProvider.blocksQUIC(ruleProtocol: .both, tookTheUDPByFallback: false, action: "108"), false)
t("a rule that says both and took the udp keeps the quic",
  AppProxyProvider.blocksQUIC(ruleProtocol: .both, tookTheUDPByFallback: true, action: "108"), false)

// 18. the global mode has no rule of its own
t("the global mode does not stop the quic",
  AppProxyProvider.blocksQUIC(ruleProtocol: nil, tookTheUDPByFallback: false, action: "108"), false)
t("no rule at all does not stop the quic",
  AppProxyProvider.blocksQUIC(ruleProtocol: nil, tookTheUDPByFallback: true, action: nil), false)

print(fails == 0 ? "udp rule tests: ALL PASS" : "udp rule tests: \(fails) FAILED")
exit(fails == 0 ? 0 : 1)
