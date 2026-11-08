import Foundation

// What ProxiRoute does with the traffic of this machine.
//
// Two things are possible and they pull in opposite directions: the
// transparent proxy takes every connection of this machine over and sends it
// out, and the proxy server waits for the other machines of the network to
// come to it. Both at the same time means the extension carries every flow of
// this machine and the server relays the flows of the whole network, and the
// CPU of the machine pays for both.
//
// So the mode is one choice, and the other two are off.
//
//   off    - nothing is taken over. The tunnel is stopped and no port is open.
//   route  - the traffic of this machine goes out through the extension. The
//            rules decide, and the global mode is the answer for the traffic
//            no rule names.
//   server - the proxy server waits for the clients of the network. The
//            traffic of this machine is left alone, so this machine does not
//            pay for it.
enum RuntimeMode: String, CaseIterable, Identifiable {
    case off
    case route
    case server

    var id: String { rawValue }

    // whether the extension takes the traffic of this machine over
    var takesOverLocalTraffic: Bool { self == .route }

    // whether the proxy server of the app listens for the clients
    var runsLocalProxyServer: Bool { self == .server }

    // Whether the two things can be on at the same time. They cannot: one
    // mode is one of them, and the other one is off.
    var isExclusive: Bool { true }
}

// Where the mode is kept.
//
// It is a property of the machine and not of the profile: the same machine
// either takes its own traffic over or it does not, and that does not change
// when another profile is chosen.
enum RuntimeModeStore {
    static let storageKey = "runtimeMode"

    // The mode that was chosen, or the one that fits what was running before.
    //
    // An app that was written before the mode existed either ran the tunnel or
    // ran the proxy server, and never both: the server was a new thing and the
    // tunnel was there from the beginning. The old setting says which of the
    // two was in use, and the mode is taken from it. That way an app that is
    // updated keeps doing what it was doing.
    static func load(localProxyWasEnabled: Bool) -> RuntimeMode {
        if let raw = UserDefaults.standard.string(forKey: storageKey),
           let mode = RuntimeMode(rawValue: raw) {
            return mode
        }
        return modeBeforeModesExisted(localProxyWasEnabled: localProxyWasEnabled)
    }

    // The mode that fits an app that was written before the modes existed.
    //
    // The proxy server was the newer of the two, and it was never on together
    // with the tunnel, so the old setting of the server says which of the two
    // was in use.
    static func modeBeforeModesExisted(localProxyWasEnabled: Bool) -> RuntimeMode {
        return localProxyWasEnabled ? .server : .route
    }

    static func save(_ mode: RuntimeMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: storageKey)
    }
}
