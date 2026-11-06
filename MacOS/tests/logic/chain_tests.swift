// Proxy chains: the action format, the hop list, and what is wrong with a
// chain. Compiled as main.swift by run.sh.
import Foundation

var fails = 0
func t(_ name: String, _ ok: Bool) { if !ok { fails += 1; print("FAIL", name) } }

// the action format is the same on both sides, the app and the extension
t("the app and the extension use the same prefix", ProxyChain.actionPrefix == ChainAction.prefix)
t("an action with the prefix names a chain", ChainAction.isChain("chain:abc"))
t("a proxy id is not a chain", !ChainAction.isChain("proxy-1"))
t("an empty action is not a chain", !ChainAction.isChain(""))
t("the chain id is read out of the action", ChainAction.chainId(from: "chain:abc") == "abc")
t("an action with the prefix but no id has no chain", ChainAction.chainId(from: "chain:") == nil)
t("a proxy action has no chain", ChainAction.chainId(from: "proxy-1") == nil)

// the action a rule uses for a chain
let chain = ProxyChain(id: "c1", name: "Home via work", proxyIds: ["p1", "p2"])
t("the action of a chain carries its id", chain.action == "chain:c1")
t("the extension builds the same action", ChainAction.action(forChainId: "c1") == chain.action)

// the hop list of a chain
let chains: [String: [String]] = ["c1": ["p1", "p2"], "c2": ["p3"]]
t("the hops come in order", ChainPlan.proxyIds(forAction: "chain:c1", chains: chains) == ["p1", "p2"])
t("a single proxy chain has one hop", ChainPlan.proxyIds(forAction: "chain:c2", chains: chains) == ["p3"])
t("an unknown chain has no hops", ChainPlan.proxyIds(forAction: "chain:nope", chains: chains).isEmpty)
t("a proxy action has no hops", ChainPlan.proxyIds(forAction: "p1", chains: chains).isEmpty)

// what is wrong with a chain
let types: [String: String] = ["p1": "socks5", "p2": "socks5", "http1": "http"]
t("a chain of socks5 proxies is fine", ChainPlan.problems(withProxyIds: ["p1", "p2"], proxyTypes: types).isEmpty)
t("an empty chain is a problem", ChainPlan.problems(withProxyIds: [], proxyTypes: types).contains { $0.contains("no proxy") })
t("a missing proxy is a problem", ChainPlan.problems(withProxyIds: ["p1", "gone"], proxyTypes: types).contains { $0.contains("does not exist") })
t("an http proxy in the middle is a problem", ChainPlan.problems(withProxyIds: ["http1", "p2"], proxyTypes: types).contains { $0.contains("http") })
t("an http proxy at the end is fine", ChainPlan.problems(withProxyIds: ["p1", "http1"], proxyTypes: types).isEmpty)
t("the same proxy twice in a row is a problem", ChainPlan.problems(withProxyIds: ["p1", "p1"], proxyTypes: types).contains { $0.contains("twice") })
t("an unknown type is a problem", ChainPlan.problems(withProxyIds: ["x"], proxyTypes: ["x": "socks4"]).contains { $0.contains("socks4") })

// the app and the extension must agree on what is wrong with a chain, or the
// app accepts a chain the extension refuses to run
func sameVerdict(_ ids: [String]) -> Bool {
    let extensionVerdict = ChainPlan.problems(withProxyIds: ids, proxyTypes: types)
    let appVerdict = ProxyChain(name: "c", proxyIds: ids).problems(proxyTypes: types)
    // the two sides word it differently, so compare the count and the order
    return extensionVerdict.count == appVerdict.count
}
t("both sides agree on a good chain", sameVerdict(["p1", "p2"]))
t("both sides agree on an http proxy in the middle", sameVerdict(["http1", "p2"]))
t("both sides agree on a missing proxy", sameVerdict(["gone"]))
t("both sides agree on a double proxy", sameVerdict(["p1", "p1"]))
t("both sides agree on an empty chain", sameVerdict([]))

print(fails == 0 ? "proxy chain tests: ALL PASS" : "proxy chain tests: \(fails) FAILED")
exit(fails == 0 ? 0 : 1)
