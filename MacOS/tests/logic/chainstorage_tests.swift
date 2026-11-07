// How a proxy chain is written down and read back.
//
// The hops of a chain travel as json between the app, the command line and the
// extension. The key they travel under is "proxies", but a build of the app
// wrote "proxyIds" instead, and a chain saved that way was read back with no
// hops at all. The chain then looked empty, the extension was handed a chain
// with nothing to walk through and dropped it, so the chain never ran.
//
// Compiled as main.swift by run.sh.
import Foundation

var fails = 0
func t(_ name: String, _ ok: Bool) { if !ok { fails += 1; print("FAIL", name) } }

func json(_ text: String) -> Data { Data(text.utf8) }

// the shape the Proxifier import writes, and the shape the command line reads
let imported = json(#"[{"name":"office","id":"126","proxies":["125"]}]"#)
let importedChains = ProxyChain.list(from: imported)
t("an imported chain is read", importedChains.count == 1)
t("an imported chain keeps its hops", importedChains.first?.proxyIds == ["125"])
t("an imported chain keeps its name", importedChains.first?.name == "office")
t("an imported chain keeps its id", importedChains.first?.id == "126")

// the shape a build of the app wrote
let legacy = json(#"[{"name":"office","id":"126","proxyIds":["125"]}]"#)
let legacyChains = ProxyChain.list(from: legacy)
t("a chain saved by the old build keeps its hops", legacyChains.first?.proxyIds == ["125"])
t("a chain saved by the old build keeps its id", legacyChains.first?.id == "126")

// what the app writes now
let encoded = try? JSONEncoder().encode([ProxyChain(id: "126", name: "office", proxyIds: ["125"])])
let encodedText = encoded.flatMap { String(data: $0, encoding: .utf8) } ?? ""
t("the hops are written under the key the extension reads",
  encodedText.contains(#""proxies":["125"]"#))
t("the old key is not written any more", !encodedText.contains("proxyIds"))

// a chain that goes out and comes back keeps its hops
let roundTrip = encoded.flatMap { ProxyChain.list(from: $0).first?.proxyIds } ?? []
t("a chain survives the round trip", roundTrip == ["125"])

// a chain with no hops is still a chain
t("a chain without hops reads as one", ProxyChain.list(from: json(#"[{"id":"1","name":"x"}]"#)).count == 1)
t("a chain without hops has none", ProxyChain.list(from: json(#"[{"id":"1","name":"x"}]"#)).first?.proxyIds == [])

// broken json is not a chain list, it is no chain list
t("broken json gives no chains", ProxyChain.list(from: json("not json")).isEmpty)
t("no data gives no chains", ProxyChain.list(from: nil).isEmpty)

// a chain that was read as a plain object, which is how the command line and
// the import hand them over
t("an object with the hops under proxies has them", ProxyChain.hops(from: ["proxies": ["a", "b"]]) == ["a", "b"])
t("an object with the hops under proxyIds has them", ProxyChain.hops(from: ["proxyIds": ["a", "b"]]) == ["a", "b"])
t("an object with no hops has none", ProxyChain.hops(from: [:]).isEmpty)

print(fails == 0 ? "chain storage tests: ALL PASS" : "chain storage tests: \(fails) FAILED")
exit(fails == 0 ? 0 : 1)
