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

    // The command finds the team ids itself, so it works on any machine. It only
    // touches extensions with ProxyBridge's bundle id that were signed by a team;
    // this build's own ad-hoc record has no team and stays.
    static let removeOldExtensionsCommand =
    "sudo /usr/bin/systemextensionsctl uninstall $(/usr/bin/systemextensionsctl list | /usr/bin/awk -F'\\t' '$0 ~ /com\\.interceptsuite\\.ProxyBridge\\.extension/ {t=$3; gsub(/teamID\\(\"|\"\\)|-/,\"\",t); if (t != \"\") print t}' | /usr/bin/sort -u) com.interceptsuite.ProxyBridge.extension"

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
