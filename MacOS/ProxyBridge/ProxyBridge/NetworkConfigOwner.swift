import Foundation
import NetworkExtension

// Which transparent proxy configurations belong to this app.
//
// macOS keeps the transparent proxy configurations of every app in one list, and
// they all carry the same provider bundle id: another build of ProxyBridge (the
// upstream release, or an older build of this one) looks exactly like ours.
//
// Without a marker the app takes over the configurations of other apps: it stops
// their tunnel when it starts and deletes them when its own tunnel fails. The user
// then finds their own proxy switched off - and the switch in System Settings has
// to be turned on again every time.
//
// The marker goes into the provider configuration, which is the one part of the
// protocol this app is allowed to write.
enum NetworkConfigOwner {
    static let key = "owner"
    static let value = "sdpong.ProxyBridge.fork"
    // the name shows in System Settings > Network > VPN & Filters. It says which
    // build it belongs to, so two configurations of ProxyBridge can be told apart,
    // and it is short enough not to be cut off there.
    static let configDescription = "ProxyBridge (fork)"

    static func mark(_ proto: NETunnelProviderProtocol) {
        proto.providerConfiguration = [key: value]
    }

    // true only for the configurations this app wrote. The marker is what says so,
    // not the provider bundle id: the id of the extension changed once, and a
    // configuration that was written before that still belongs to this app and has
    // to be updated instead of duplicated.
    static func isOurs(_ manager: NETransparentProxyManager) -> Bool {
        guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol else { return false }
        return proto.providerConfiguration?[key] as? String == value
    }

    static func ourManagers(_ managers: [NETransparentProxyManager]) -> [NETransparentProxyManager] {
        managers.filter { isOurs($0) }
    }

    // More than one configuration of this app can be in the system at the same
    // time: an earlier build wrote one under a different app bundle id, and it
    // was never removed. macOS shows every one of them in System Settings >
    // Network > VPN & Filters, so the list fills up with copies of the same
    // name and the person cannot tell which one is in use.
    //
    // A configuration belongs to the app that wrote it, and only that app can
    // start it: a configuration that belongs to an app that is not installed
    // any more is dead ("the VPN app used by this configuration is not
    // installed") and can only be removed and written again. macOS does not
    // say which app owns a configuration, so when there is more than one, all
    // of them go and one new one is written.
    //
    // One new configuration is written anyway, so the code signature macOS
    // records for it is the one of the extension that is installed now.
    static func clearAll(_ managers: [NETransparentProxyManager], completion: @escaping () -> Void) {
        guard !managers.isEmpty else { completion(); return }
        let group = DispatchGroup()
        for manager in managers {
            group.enter()
            manager.removeFromPreferences { _ in group.leave() }
        }
        group.notify(queue: .main) { completion() }
    }
}
