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
enum ExtensionDiagnosis {
    // macOS: "The VPN app used by this configuration is not installed." The message is
    // localised, so the domain and the code are what is matched on.
    static func isMissingProviderApp(reason: String) -> Bool {
        return reason.contains("NEVPNConnectionErrorDomain 14")
    }

    static let missingProviderAppExplanation =
    "macOS bound the tunnel to an extension whose app is no longer installed. Another build of ProxyBridge is still registered in the system (its app was removed), and the system picked that one, so no traffic is proxied. Take it out with the command below, then start the proxy again."

    // The command finds the team ids itself, so it works on any machine. It only
    // touches extensions with ProxyBridge's bundle id that were signed by a team;
    // this build's own ad-hoc record has no team and stays.
    static let removeOldExtensionsCommand =
    "sudo /usr/bin/systemextensionsctl uninstall $(/usr/bin/systemextensionsctl list | /usr/bin/awk -F'\\t' '$0 ~ /com\\.interceptsuite\\.ProxyBridge\\.extension/ {t=$3; gsub(/teamID\\(\"|\"\\)|-/,\"\",t); if (t != \"\") print t}' | /usr/bin/sort -u) com.interceptsuite.ProxyBridge.extension"
}
