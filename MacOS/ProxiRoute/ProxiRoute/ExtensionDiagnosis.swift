import Foundation
import Security

// Recognising the failure macOS reports when the tunnel is bound to an extension
// whose app is no longer installed.
//
// macOS keeps every registered version of a system extension under the same bundle
// id. When another build of ProxiRoute is still registered - and its app was
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

    static let missingProviderAppExplanation = L10n.t("macOS bound the tunnel to an extension whose app is no longer installed. Another build of ProxiRoute is still registered in the system (its app was removed), and the system picked that one, so no traffic is proxied. Copy the command and run it in the Terminal to take the old extension out, then start the proxy again. macOS finishes the removal at the next restart.")

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
    // ProxiRoute bundle id that is registered and uses the right team id for
    // each. When the script is not in the bundle the command falls back to the
    // one line that removes the records of this build.
    static var removeOldExtensionsCommand: String {
        if let script = Bundle.main.url(forResource: "remove-old-extensions", withExtension: "sh")?.path {
            return "sudo \(script)"
        }
        return "sudo /usr/bin/systemextensionsctl uninstall - com.sdpong.proxiroute.extension"
    }

    // ---- can the app reach its own extension at all? ----
    //
    // The rules and the proxy list travel to the extension in two ways: over the
    // provider channel, and with the configuration the tunnel is started with.
    //
    // The system checks the provider channel against the app's signature. A build
    // that is not signed by a developer - an ad-hoc signature has no team id - is
    // refused by the system, and then the app hears nothing back: the tunnel is
    // up, the extension runs and proxies the traffic, but the app cannot change
    // anything while the tunnel runs.
    //
    // These two probes say which of the doors is shut, so the reason can be said
    // out loud instead of leaving the person with an empty window.

    // the container the app and the extension share
    static let appGroupIdentifier = "group.com.sdpong.ProxiRoute"

    // Can the app write into the shared container? The system refuses this for a
    // build whose signature has no team id, and writes the reason in the system log:
    // "Group containers identifiers should be prefixed by requestor's team ID".
    static func sharedContainerReachable() -> Bool {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else { return false }
        let probe = url.appendingPathComponent("proxiroute-probe")
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

    // ---- can this build run a network extension at all? ----
    //
    // A build signed by a developer carries a team id. An ad-hoc signature
    // carries none, and that is what decides everything:
    //
    //   - the network extension APIs of macOS only answer an app that has a
    //     team id. An ad-hoc build calls NETransparentProxyManager and the
    //     callback is never called - not an error, nothing at all - so the
    //     tunnel configuration is never written and no traffic is proxied.
    //   - the restricted entitlements of the build - the ones that install a
    //     system extension and that run a network extension - are not
    //     validated without a provisioning profile, so the extension
    //     registers and is then refused.
    //
    // The team id is read from the running code, so it says what macOS sees
    // and not what the build script hoped for.
    static func teamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess,
              let code = code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode = staticCode else { return nil }
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return nil }
        guard let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
              !team.isEmpty else { return nil }
        return team
    }

    // Whether the signature of this build carries a team id.
    //
    // The app does not decide anything with this: it is what the notice in
    // the window says, and what the two reasons of a silent system are told
    // apart by. The extension is asked for in both cases - the system is the
    // one that decides whether it takes it.
    static func hasTeamIdentifier(_ teamIdentifier: String?) -> Bool {
        guard let team = teamIdentifier else { return false }
        return !team.isEmpty
    }

    // The one line that says what the notice is about.
    //
    // The explanation itself is three paragraphs, and it is true from the first
    // launch of an unsigned build until the app is signed. Putting all of it in
    // the window took a third of the window every time the app opened, so the
    // bar says what it is in one line and the rest is one click away.
    static func extensionUnreachableSummary(hasDeveloperSignature: Bool) -> String {
        if hasDeveloperSignature {
            return L10n.t("The extension does not answer. The tunnel is up, so the extension on the other end is not this build.")
        }
        return L10n.t("This build is not signed by a developer, so the switches the extension reads while it runs are not available. The traffic is proxied all the same, and the connections and their traffic come from the system log.")
    }

    // The extension does not answer at all.
    //
    // This is not the same thing as "another build answered": here nothing came
    // back. The system checks the channel between the app and its own system
    // extension against the app's signature, and a build that is not signed by a
    // developer gets no message through it.
    //
    // What still works: the rules and the proxy list went with the start of the
    // tunnel, so the traffic is proxied - including the proxies that need a
    // password. The connections, their traffic and the activity log are read from
    // the unified log, where the extension writes every decision it made and the
    // traffic of the open flows.
    //
    // What does not work: the switches the extension reads while it runs, and
    // closing a connection by hand.
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
                L10n.t("The extension does not answer. The tunnel is up, so the extension on the other end is not this build. Take the old record out with the command below, then start the proxy again.")
            ]
        }
        return [
            L10n.t("The extension does not answer over the provider channel. macOS checks that channel against the app's signature, and a build that is not signed by a developer gets no message through it."),
            L10n.t("What that costs: the switches the extension reads while it runs, and closing a connection by hand. Everything else is read from the unified log instead: the extension writes every decision it made there, and it writes the traffic of the open flows there as well, so the connections, their traffic and the activity log are all there. The traffic itself is proxied either way: the rules, the proxies and the passwords went with the start of the tunnel."),
            L10n.t("Sign the app with a Developer ID certificate to get the running switches and the hand-made disconnects as well.")
        ]
    }

    // ---- this build has no team id ----
    //
    // The one line that says what the notice is about, and the long form that
    // says what is known and what is not.
    //
    // What is known: the signature of this build carries no team id, and
    // macOS ties a lot to the team id - the restricted entitlements of a
    // network extension among them. What is not known: whether the system
    // will take this build. It does take it here - the extension of the app
    // runs and answers - so the notice says what the signature is and stops
    // there. It is the tunnel that says whether it worked.
    static func unsignedBuildSummary() -> String {
        return L10n.t("This build is not signed by a developer, so its signature carries no team id. macOS ties a lot to that team id, so this is the first thing to look at when the tunnel does not come up.")
    }

    static func unsignedBuildExplanation() -> [String] {
        return [
            L10n.t("The signature of this build has no team id: it is signed ad hoc. macOS asks for the team id for the restricted entitlements of a network extension, so a build without one can be refused where a build with one is not."),
            L10n.t("What that costs, when it costs anything: the tunnel may not come up, and the switches the extension reads while it runs may not be available. The rules, the proxies and the chains are all here either way, and the proxy server of the app does not need the extension at all."),
            L10n.t("A build signed with a Developer ID certificate and a provisioning profile that carries the network extension entitlement does not have this problem. That needs a paid developer membership: the free Personal Team supports neither network extensions nor system extensions.")
        ]
    }
}
