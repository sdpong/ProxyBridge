import Foundation

// What ProxiRoute does, in the three modes.
//
// The traffic of this machine is taken over in every mode: that is what the
// app does, and it is what the person expects of it. The modes differ in the
// service they add on top of it, for the other terminals of the network.
//
//   local   - the traffic of this machine, and nothing else.
//   gateway - the traffic of this machine, and this machine is the gateway of
//              the network: the traffic of the other terminals goes through it.
//   server  - the traffic of this machine, and the proxy server waits for the
//              clients of the network.
//
// The tunnel and the server are on at the same time in the server mode: the
// server relays the traffic of the clients, and the tunnel carries the
// traffic of this machine. The processor of the machine pays for both, which
// is why the server is a mode and not a switch of its own.
enum RuntimeMode: String, CaseIterable, Identifiable {
    case local
    case gateway
    case server

    var id: String { rawValue }

    // Whether the extension takes the traffic of this machine over. It always
    // does: the modes are about the service for the other terminals.
    var takesOverLocalTraffic: Bool { true }

    // Whether the proxy server of the app listens for the clients.
    var runsLocalProxyServer: Bool { self == .server }

    // Whether this machine is the gateway of the network.
    var runsGateway: Bool { self == .gateway }
}

// Where the mode is kept.
//
// It is a property of the machine and not of the profile: the same machine
// either serves the clients of the network or it does not, and that does not
// change when another profile is chosen.
enum RuntimeModeStore {
    static let storageKey = "runtimeMode"

    // The mode that was chosen, or the one that fits what was running before.
    //
    // The mode was called "off", "route" and "server" before it had the names
    // it has now. A stored name is read as the mode it grew into, so an app
    // that is updated keeps the mode it was in.
    static func load(localProxyWasEnabled: Bool) -> RuntimeMode {
        if let raw = UserDefaults.standard.string(forKey: storageKey) {
            switch raw {
            case "off":
                return .local
            case "route":
                return .gateway
            case "server":
                return .server
            default:
                break
            }
            if let mode = RuntimeMode(rawValue: raw) {
                return mode
            }
        }
        return modeBeforeModesExisted(localProxyWasEnabled: localProxyWasEnabled)
    }

    // The mode that fits an app that was written before the modes existed.
    //
    // Such an app either ran the tunnel or ran the proxy server, and never
    // both. The tunnel alone is the local mode now: the server was the newer
    // of the two, and it is a service on top of the tunnel.
    static func modeBeforeModesExisted(localProxyWasEnabled: Bool) -> RuntimeMode {
        return localProxyWasEnabled ? .server : .local
    }

    static func save(_ mode: RuntimeMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: storageKey)
    }
}
