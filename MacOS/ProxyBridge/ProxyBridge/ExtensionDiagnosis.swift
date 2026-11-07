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
    // The rules and the proxy list travel to the extension over the provider channel,
    // and through the container that the app and the extension share. The system
    // checks both against the app's signature. A build that is not signed by a
    // developer - an ad-hoc signature has no team id - is refused by the system, and
    // then nothing reaches the extension: the tunnel is up, the extension runs, and it
    // has no rules at all, so every connection goes direct and the list of connections
    // stays empty.
    //
    // These two probes say which of the doors is shut, so the reason can be said out
    // loud instead of leaving the person with an empty window.

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
}
