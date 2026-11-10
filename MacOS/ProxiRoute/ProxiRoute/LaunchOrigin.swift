import Foundation

// How the app came up.
//
// The three ways it can come up want three different things:
//
//   - the launch agent starts it and nobody is looking: it stays in the
//     menu bar, the window stays closed, and the traffic of the machine is
//     taken over
//   - macOS starts it at the login, in the wave of the login: the same
//     thing, and it comes up together with the browsers and the other apps
//     that use the network
//   - the person opens it: the window comes up and stays
enum LaunchOrigin {
    case byAgent
    case atTheLogin
    case byHand

    // Decides how the app was started.
    //
    // The key of macOS that says whether a launch is the default one is not
    // of use here. It says the opposite of what the books say on this
    // machine (macOS 27.2), and it was measured three ways on the 10th of
    // November 2026:
    //
    //   - the login item of macOS started the app (loginwindow, "perform
    //     Autolaunch") and the key said TRUE
    //   - the app was opened with "open -a" and the key said FALSE
    //   - the binary was run from a terminal and the key said FALSE
    //
    // So a build that asks that key decides the opposite of what it should
    // in every case: the app hides itself when the person opened it, and it
    // shows a dock icon when macOS started it at the login.
    //
    // What is of use is the launch agent, which says so with an environment
    // variable, and the marker of the session: the app writes down the
    // session it was started in, and a launch in a session that has no
    // marker yet is the launch of the login.
    static func detect() -> LaunchOrigin {
        if ProcessInfo.processInfo.environment[UpstreamWait.startHiddenVariable] == "1" {
            return .byAgent
        }
        if !UpstreamWait.startedInThisSession() {
            return .atTheLogin
        }
        return .byHand
    }

    // Whether the app has to come up in the menu bar with no window.
    //
    // The launch of the login and the launch of the agent are both made for
    // the proxy of the machine and not for a person, so both of them come up
    // in the menu bar. A person who opens the app wants to see it.
    var comesUpInTheMenuBar: Bool {
        return self != .byHand
    }

    // What is written into the log of the login.
    var description: String {
        switch self {
        case .byAgent: return "by the agent"
        case .atTheLogin: return "at the login"
        case .byHand: return "by hand"
        }
    }
}
