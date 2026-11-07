import Foundation

// The answer the extension gives when the app asks who it is, and what the app
// makes of it.
//
// macOS keeps every registered version of a system extension under the same
// bundle id. When an older ProxyBridge is still registered, the system may bind
// the tunnel to that one instead of this build. The old one speaks an older
// protocol: it ignores the rules and the proxies, so nothing is proxied and the
// window shows an empty list without saying why. This is what turns that silence
// into an explanation.
//
// It is a plain function on purpose: the decision can be tested without a tunnel.

enum ExtensionHandshake {
    // The version of the message protocol this build speaks. The extension side
    // has the same number in AppProxyProvider.protocolAPI, and the tests check
    // that the two agree.
    static let protocolAPI = 2

    enum Verdict: Equatable {
        // the extension answered and speaks the same protocol
        case ok(api: Int, version: String)
        // the extension answered but speaks another protocol: it is another build
        case mismatch(api: Int)
        // the extension did not answer at all
        case noAnswer
    }

    static func verdict(response: Data?) -> Verdict {
        guard let response,
              let object = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
              let api = object["api"] as? Int else { return .noAnswer }
        if api != protocolAPI { return .mismatch(api: api) }
        return .ok(api: api, version: object["version"] as? String ?? "?")
    }
}
