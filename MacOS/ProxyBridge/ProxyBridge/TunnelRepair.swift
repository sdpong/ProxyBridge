import Foundation
import NetworkExtension

// What the app and the command line do when the tunnel does not start (issue #282): ask macOS why, and
// remove ProxyBridge's saved network configurations so the next attempt starts from a fresh one. A saved
// configuration can go bad, for example when it was first written while the extension was still waiting
// for approval, and macOS then stops the tunnel again at once, with no message of its own.
nonisolated enum TunnelRepair {
    static func describe(_ error: Error) -> String {
        let e = error as NSError
        return "\(e.localizedDescription) (\(e.domain) \(e.code))"
    }

    // the reason macOS recorded for the last time this tunnel stopped
    static func lastDisconnectReason(_ session: NETunnelProviderSession, completion: @escaping (String) -> Void) {
        session.fetchLastDisconnectError { error in
            completion(error.map(describe) ?? "no error was reported")
        }
    }

    // removes the transparent proxy configuration and the DNS proxy entry. only entries of this
    // app are ever touched: the configurations of other apps carry other provider bundle ids.
    //
    // The configurations of ProxyBridge itself are all removed, also the ones an older build
    // wrote: they carry the code signature hash of the extension binary of that day, and when
    // that binary is gone macOS refuses to start them ("the VPN app used by this configuration
    // is not installed"). This is the repair path, it only runs when the tunnel has already
    // failed, so a configuration that cannot start is worth throwing away.
    // the completion gets one line that says what was removed.
    static func removeSavedConfigurations(extensionIdentifier: String, completion: @escaping (String) -> Void) {
        var removed: [String] = []
        var problems: [String] = []
        let lock = NSLock()
        func note(_ text: String, problem: Bool) {
            lock.lock(); if problem { problems.append(text) } else { removed.append(text) }; lock.unlock()
        }

        NETransparentProxyManager.loadAllFromPreferences { managers, loadError in
            if let loadError = loadError { note("could not read the network configuration: \(describe(loadError))", problem: true) }
            let ours = (managers ?? []).filter {
                let proto = $0.protocolConfiguration as? NETunnelProviderProtocol
                // the provider id of this build, or a configuration this app wrote
                // earlier (the extension id changed once, and the old configuration
                // is still ours and still broken)
                if proto?.providerBundleIdentifier == extensionIdentifier { return true }
                return NetworkConfigOwner.isOurs($0)
            }
            let group = DispatchGroup()
            for manager in ours {
                group.enter()
                manager.removeFromPreferences { error in
                    if let error = error { note("could not remove the network configuration: \(describe(error))", problem: true) }
                    else { note("network configuration", problem: false) }
                    group.leave()
                }
            }
            group.enter()
            let dns = NEDNSProxyManager.shared()
            dns.loadFromPreferences { dnsLoadError in
                if dnsLoadError == nil, dns.providerProtocol?.providerBundleIdentifier == extensionIdentifier {
                    dns.removeFromPreferences { error in
                        if let error = error { note("could not remove the DNS proxy entry: \(describe(error))", problem: true) }
                        else { note(L10n.t("DNS proxy entry"), problem: false) }
                        group.leave()
                    }
                } else {
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                var text = removed.isEmpty ? L10n.t("Nothing to remove") : L10n.f("Removed the saved %@", removed.joined(separator: " and "))
                if !problems.isEmpty { text += L10n.f(". Problems: %@", problems.joined(separator: "; ")) }
                completion(text)
            }
        }
    }
}
