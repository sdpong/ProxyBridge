// handshake tests: what the app makes of the answer the extension gives when it
// asks who it is. The decision is what turns "nothing is proxied" into a reason.
//
// It also checks that the app and the extension agree on the protocol number:
// if they drift, the app would report a mismatch on a perfectly good extension.

import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) {
    if ok { print("  ok   \(what)") } else { failures += 1; print("  FAIL \(what)") }
}

func json(_ object: [String: Any]) -> Data {
    (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
}

// the extension answers with its api number and its version
let good = json(["status": "ok", "api": ExtensionHandshake.protocolAPI, "version": "4.1.2", "pid": 42])
check(ExtensionHandshake.verdict(response: good) == .ok(api: ExtensionHandshake.protocolAPI, version: "4.1.2"),
      "the extension of this build is accepted")

// an older build answers with another api number: it is another extension
let older = json(["status": "ok", "api": 1, "version": "3.2.0", "pid": 7])
check(ExtensionHandshake.verdict(response: older) == .mismatch(api: 1),
      "an extension with another api is a mismatch")

// a newer build answers with a higher api number: also a mismatch
let newer = json(["status": "ok", "api": ExtensionHandshake.protocolAPI + 1, "version": "9.9.9"])
check(ExtensionHandshake.verdict(response: newer) == .mismatch(api: ExtensionHandshake.protocolAPI + 1),
      "an extension with a newer api is a mismatch")

// no answer at all: the extension is not up, or it is too old to know the action
check(ExtensionHandshake.verdict(response: nil) == .noAnswer,
      "no answer is no answer")

// an answer that is not the handshake: an old extension ignores the action and
// answers with nothing, or with something else entirely
check(ExtensionHandshake.verdict(response: json(["status": "ok"])) == .noAnswer,
      "an answer without an api number is no answer")
check(ExtensionHandshake.verdict(response: Data()) == .noAnswer,
      "an empty answer is no answer")
check(ExtensionHandshake.verdict(response: Data([0xff, 0xfe])) == .noAnswer,
      "garbage is no answer")

// the version is optional: an extension that does not report one is still ours
let noVersion = json(["status": "ok", "api": ExtensionHandshake.protocolAPI])
check(ExtensionHandshake.verdict(response: noVersion) == .ok(api: ExtensionHandshake.protocolAPI, version: "?"),
      "a missing version does not make it a mismatch")

// the app and the extension have to agree on the number
check(AppProxyProvider.protocolAPI == ExtensionHandshake.protocolAPI,
      "the app and the extension speak the same protocol (\(ExtensionHandshake.protocolAPI))")

if failures > 0 {
    print("handshake tests: \(failures) FAILED")
    exit(1)
}
print("handshake tests: ALL PASS")
