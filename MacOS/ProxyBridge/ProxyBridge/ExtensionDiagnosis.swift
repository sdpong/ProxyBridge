import Foundation

// Recognising the failure macOS reports when the tunnel is bound to an extension
// whose app is no longer installed.
//
// macOS keeps every registered version of a system extension under the same bundle
// id. When another build of ProxyBridge is still registered - and its app was
// removed - the system binds the tunnel to that one, and then says
// "the VPN app used by this configuration is not installed"
// (NEVPNConnectionErrorDomain code 14). Nothing is proxied, and the reason is not
// obvious: the app looks fine, the extension is approved, and it even runs.
//
// The fix is to take the other extension out of the system. That needs root, so the
// command goes to the user instead of being run behind their back.
enum ExtensionDiagnosis {    // macOS: "The VPN app used by this configuration is not installed." The message is
    // localised, so the domain and the code are what is matched on.
    static func isMissingProviderApp(reason: String) -> Bool {
        return reason.contains("NEVPNConnectionErrorDomain 14")
    }

    static let missingProviderAppExplanation =
    "macOS bound the tunnel to an extension whose app is no longer installed. Another build of ProxyBridge is still registered in the system (its app was removed), and the system picked that one, so no traffic is proxied. Copy the command and run it in the Terminal to take the old extension out, then start the proxy again. macOS finishes the removal at the next restart."

    // The command that takes the old records out of the system.
    //
    // It has to work on a build that is not signed by a developer, and that is the
    // whole point: "systemextensionsctl uninstall" wants "<teamID> <bundleID>",
    // and the team id of an ad-hoc record is written as a dash. Leaving the team
    // id out (which is what the command used to do) makes the tool print its
    // usage and do nothing, so the person is left with the old extensions and no
    // way to get rid of them.
    //
    // The script that ships with the app does the whole job: it finds every
    // ProxyBridge bundle id that is registered and uses the right team id for
    // each. When the script is not in the bundle the command falls back to the
    // one line that removes the records of this build.
    static var removeOldExtensionsCommand: String {
        if let script = Bundle.main.url(forResource: "remove-old-extensions", withExtension: "sh")?.path {
            return "sudo \(script)"
        }
        return "sudo /usr/bin/systemextensionsctl uninstall - com.sdpong.proxybridge.extension"
    }

    // ---- can the app reach its own extension at all? ----
    //
    // The rules and the proxy list travel to the extension in two ways: over the
    // provider channel, and with the configuration the tunnel is started with.
    //
    // The system checks the provider channel against the app's signature. A build
    // that is not signed by a developer - an ad-hoc signature has no team id - is
    // refused by the system, and then the app hears nothing back: the tunnel is
    // up, the extension runs and proxies the traffic, but the window cannot show
    // the connections.
    //
    // These two probes say which of the doors is shut, so the reason can be said
    // out loud instead of leaving the person with an empty window.

    // the container the app and the extension share
    static let appGroupIdentifier = "group.com.interceptsuite.ProxyBridge"

    // Can the app write into the shared container? The system refuses this for a
    // build whose signature has no team id, and writes the reason in the system log:
    // "Group containers identifiers should be prefixed by requestor's team ID".
    static func sharedContainerReachable() -> Bool {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else { return false }
        let probe = url.appendingPathComponent("proxybridge-probe")
        defer { try? FileManager.default.removeItem(at: probe) }
        do {
            try Data("probe".utf8).write(to: probe)
            return (try? Data(contentsOf: probe)) == Data("probe".utf8)
        } catch {
            return false
        }
    }

    // Is the app signed by a developer? A build that is signed by a developer carries
    // a provisioning profile with the team id in it. An ad-hoc signature has none, and
    // the things that are tied to a team id are refused for it.
    static func hasDeveloperSignature() -> Bool {
        return Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") != nil
    }

    // The extension does not answer at all.
    //
    // This is not the same thing as "another build answered": here nothing came
    // back. The system checks the channel between the app and its own system
    // extension against the app's signature, and a build that is not signed by a
    // developer gets no message through it.
    //
    // What still works: the rules and the proxy list went with the start of the
    // tunnel, so the traffic is proxied. The connection list and the activity
    // log are read from the unified log, where the extension writes every
    // decision it made.
    //
    // What does not work: the list of open connections with their traffic, and
    // the proxies that need a password. Both need the provider channel.
    //
    // A build that IS signed by a developer is a different case: the tunnel is
    // up, so something is on the other end of it, and it does not answer, which
    // means it is not this build. That one is fixed by taking the old record out,
    // so it gets the command with it.
    //
    // The paragraphs are the single source of this explanation: the window shows
    // them as one text, the command line shows them as paragraphs.
    static func extensionUnreachableExplanation(hasDeveloperSignature: Bool) -> [String] {
        if hasDeveloperSignature {
            return [
                "The extension does not answer. The tunnel is up, so the extension on the other end is not this build. Take the old record out with the command below, then start the proxy again."
            ]
        }
        return [
            "The extension does not answer over the provider channel. macOS checks that channel against the app's signature, and a build that is not signed by a developer gets no message through it.",
            "What that costs: the list of open connections with their traffic, and the proxies that need a password. The connection list and the activity log are read from the unified log instead, where the extension writes every decision it made, so they are there. The traffic itself is proxied either way: the rules and the proxy list went with the start of the tunnel.",
            "Sign the app with a Developer ID certificate to get the open connections and the proxies with a password as well."
        ]
    }
}
