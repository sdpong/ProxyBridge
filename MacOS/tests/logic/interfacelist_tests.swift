import Foundation

// The list of the network cards of the machine.
//
// The system can say the same card more than once: on a Mac with a wireless
// network the monitor of the paths names en0 twice, once for the network and
// once for the radio behind it. A list that says the same name twice is a
// picker with the same choice in it twice, and SwiftUI does not say which of
// the two is meant.
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

// the wireless card of a Mac is said twice
let saidTwice: [(name: String, kind: String)] = [("en0", "wifi"), ("en0", "wifi")]
check("the same card said twice is one card",
      InterfaceList.entries(from: saidTwice).count == 1)
check("the card said twice keeps its name",
      InterfaceList.entries(from: saidTwice).first?.name == "en0")
check("the card said twice keeps its kind",
      InterfaceList.entries(from: saidTwice).first?.kind == "wifi")

// no name is said twice, so the ids of the list are the names and they are
// not the same name twice
let mixed: [(name: String, kind: String)] = [("en0", "wifi"), ("en0", "wifi"), ("en1", "ethernet")]
let entries = InterfaceList.entries(from: mixed)
check("the list has no name twice",
      Set(entries.map { $0.name }).count == entries.count)
check("the ids of the list are the names",
      Set(entries.map { $0.id }).count == entries.count)
check("the ids of the list are the names of the cards",
      entries.map { $0.id } == entries.map { $0.name })

// the cards that are there stay
check("a card said once stays", InterfaceList.entries(from: [("en3", "ethernet")]).count == 1)
check("the name of the card is kept",
      InterfaceList.entries(from: [("en3", "ethernet")]).first?.name == "en3")
check("the kind of the card is kept",
      InterfaceList.entries(from: [("en3", "ethernet")]).first?.kind == "ethernet")

// the loopback is not a network card
check("the loopback is left out",
      InterfaceList.entries(from: [("lo0", "loopback")]).isEmpty)
check("the loopback does not hide the other cards",
      InterfaceList.entries(from: [("lo0", "loopback"), ("en0", "wifi")]).count == 1)

print(fails == 0 ? "interface list tests: ALL PASS" : "interface list tests: \(fails) FAILED")
exit(fails == 0 ? 0 : 1)
