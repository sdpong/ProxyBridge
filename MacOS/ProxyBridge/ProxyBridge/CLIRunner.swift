import Foundation
import AppKit
import NetworkExtension
import SystemExtensions

// the command line mode of the app: the same executable as the GUI, started with options
// (see main.swift). it does what the GUI does to get traffic redirected, without a window:
// activate the system extension, set up the tunnel, send the profile, and clean up on exit.
enum CLI {
    static let bundleIdentifier = "com.interceptsuite.ProxyBridge"
    static let extensionIdentifier = "com.sdpong.proxybridge.extension"
    static let maxProfileBytes = 4 * 1024 * 1024
    static var runner: CLIRunner?
    private static var lockDescriptor: Int32 = -1
    private static var outputClosed = false

    // prints a line. when the reader of our output went away (piped into `head`, closed
    // terminal) we stop cleanly instead of dying on SIGPIPE with the rules still active
    static func say(_ text: String) {
        guard !outputClosed else { return }
        if fputs(text + "\n", stdout) == EOF || fflush(stdout) != 0 {
            outputClosed = true
            runner?.stopFromOutside(reason: nil)
        }
    }

    static func warn(_ text: String) {
        FileHandle.standardError.write(Data(("warning: " + text + "\n").utf8))
    }

    static func fail(_ text: String, code: Int32 = 1) -> Never {
        FileHandle.standardError.write(Data(("ERROR: " + CLIText.lines(text) + "\n").utf8))
        exit(code)
    }

    // Prints what the system extension writes, and keeps printing the new lines.
    //
    // The extension writes its decisions to the unified log. Reading them back
    // needs a build that is not sandboxed: logd does not serve the system scope
    // to a sandboxed process, and the /usr/bin/log tool refuses to run in one
    // at all ("Cannot run while sandboxed").
    private static func followExtensionLog() -> Never {
        say("Reading what the system extension writes (\(ExtensionLogReader.subsystem)). Press Ctrl+C to stop.")
        say("")
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")

        // the minute before, so a run that starts while traffic is flowing
        // shows something, and then the tool follows the log as it grows
        UnifiedLogBacklog.read(seconds: 60) { lines in
            for line in lines {
                // the lines about the traffic of the flows are the bookkeeping of the app and
                // the extension, not something to read: they come every second
                guard line.flowEvent == nil, line.proxyTotals == nil else { continue }
                say("[\(formatter.string(from: line.date))] \(CLIText.safe(line.text))")
            }
            let tail = UnifiedLogTail()
            tail.onLines = { lines in
                for line in lines {
                    // the lines about the traffic of the flows are the bookkeeping of the app
                    // and the extension, not something to read: they come every second
                    guard line.flowEvent == nil, line.proxyTotals == nil else { continue }
                    say("[\(formatter.string(from: line.date))] \(CLIText.safe(line.text))")
                }
            }
            tail.onFailure = { reason in
                CLI.warn(ExtensionLogReader.unreadableReason(reason))
            }
            tail.start()
        }
        // the tail runs until the process is stopped
        dispatchMain()
    }

    // the version of the app this executable belongs to. falls back to the bundle that
    // holds the real executable in case the process was started through a link
    static func version() -> String {
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String { return v }
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            let plist = exe.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
            if let d = NSDictionary(contentsOf: plist), let v = d["CFBundleShortVersionString"] as? String { return v }
        }
        return "unknown"
    }

    static func run(arguments: [String]) -> Never {
        // a closed pipe must not kill us: we want to clean up first (see say)
        signal(SIGPIPE, SIG_IGN)

        let options: CLIOptions
        switch CLIArguments.parse(arguments) {
        case .failure(let message): fail(message, code: 2)
        case .run(let o): options = o
        }

        if options.help { say(CLIArguments.usage); exit(0) }
        if options.version { say("ProxyBridge CLI \(version())"); exit(0) }
        if options.listProfiles { listProfiles(); exit(0) }
        if options.update { checkForUpdates() }

        // the log view only reads: it does not control the extension, so it does
        // not have to wait for the app to be closed
        if options.followLog {
            followExtensionLog()
        }

        // only one controller at a time: the GUI and the CLI would fight over the same tunnel
        if guiIsRunning() { fail("The ProxyBridge app is running. Quit it first, only one of them can control the extension at a time.") }
        guard takeLock() else { fail("Another ProxyBridge CLI is already running.") }

        // the diagnosis stands on its own: it needs the tunnel, not a profile
        if options.diagnose {
            let r = CLIRunner(profile: nil, verbose: 0, diagnoseOnly: true)
            runner = r
            r.start()
            RunLoop.main.run()
            exit(0)
        }

        guard let spec = options.profile else { fail("--profile is required. Use --help.", code: 2) }
        let profile: CLIProfile
        do { profile = try loadProfile(spec) } catch let e as CLIProfileError { fail(e.message) } catch { fail(error.localizedDescription) }

        let errors = CLIProfileLoader.errors(for: profile)
        if !errors.isEmpty { fail("The profile can't be used:\n  - " + errors.map { CLIText.safe($0) }.joined(separator: "\n  - ")) }

        for note in profile.notes { CLI.warn(CLIText.safe(note)) }
        for w in CLIProfileLoader.warnings(for: profile) { warn(CLIText.safe(w)) }
        let r = CLIRunner(profile: profile, verbose: options.verbose)
        runner = r
        r.start()
        RunLoop.main.run()
        exit(0)
    }

    private static func listProfiles() {
        let (names, active) = CLIProfileLoader.savedNames(read: CLIProfileLoader.appReader)
        if names.isEmpty { say("No saved profiles. Open the ProxyBridge app once to create the default one."); return }
        for n in names { say((n == active ? "* " : "  ") + CLIText.safe(n)) }
        say("(* = the profile the app currently uses)")
    }

    // standard input, with a limit so a huge or endless input can't use all the memory
    private static func readStandardInput() throws -> Data {
        if isatty(STDIN_FILENO) != 0 {
            throw CLIProfileError.invalid("--profile - reads the profile from standard input, but standard input is the terminal. Pipe a file in: cat file.pbprofile | proxybridge --profile -")
        }
        var data = Data()
        while true {
            let chunk = FileHandle.standardInput.availableData
            if chunk.isEmpty { return data }
            data.append(chunk)
            if data.count > maxProfileBytes { throw CLIProfileError.invalid("The profile is larger than \(maxProfileBytes / 1024 / 1024) MB.") }
        }
    }

    private static func loadProfile(_ spec: String) throws -> CLIProfile {
        if spec == "-" { return try CLIProfileLoader.parse(json: readStandardInput()) }
        if spec.contains("/") || spec.hasSuffix(".pbprofile") || spec.hasSuffix(".ppx") {
            // the app is sandboxed, so it can only read files that are in its own container
            let path = (spec as NSString).expandingTildeInPath
            guard let data = FileManager.default.contents(atPath: path), data.count <= maxProfileBytes else {
                throw CLIProfileError.invalid("Can't read '\(spec)'. The app is sandboxed and can't open files elsewhere. Use a saved profile name, or pipe the file in: cat \(spec) | proxybridge --profile -")
            }
            return try CLIProfileLoader.parse(json: data)
        }
        return try CLIProfileLoader.saved(named: spec, read: CLIProfileLoader.appReader)
    }

    private static func checkForUpdates() -> Never {
        Task {
            let info = await UpdateService().checkForUpdates()
            if let error = info.error { fail(error) }
            say("Installed: \(info.currentVersion)")
            say("Latest:    \(info.latestVersion)")
            if info.isUpdateAvailable {
                say("An update is available: \(CLIText.safe(info.downloadUrl ?? "see https://github.com/InterceptSuite/ProxyBridge/releases"))")
                if let notes = info.releaseNotesUrl { say("Release notes: \(CLIText.safe(notes))") }
            } else {
                say("You are up to date.")
            }
            exit(0)
        }
        RunLoop.main.run()
        exit(0)
    }

    private static func guiIsRunning() -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).contains { $0.processIdentifier != getpid() }
    }

    // a second CLI would clear the first one's rules when it stops
    private static func takeLock() -> Bool {
        let path = NSTemporaryDirectory() + "proxybridge-cli.lock"
        lockDescriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        return lockDescriptor >= 0 && flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0
    }
}

final class CLIRunner: NSObject, OSSystemExtensionRequestDelegate {
    private let profile: CLIProfile?
    private let verbose: Int
    // --diagnose: no profile, no rules. the tunnel comes up and the app says whether
    // it can reach the extension at all, and why not when it cannot.
    private let diagnoseOnly: Bool
    private var manager: NETransparentProxyManager?
    private var session: NETunnelProviderSession?
    private var statusObserver: NSObjectProtocol?
    private var logTimer: Timer?
    private var polling = false
    private var signalSources: [DispatchSourceSignal] = []
    private var extensionActive = false
    private var started = false
    private var stopping = false

    // whether the extension answers over the provider channel. the system checks
    // that channel against the app's signature, so a build that is not signed by a
    // developer gets no message through it - and the log is read instead.
    private var providerChannelAvailable = false

    // The tool that follows the unified log, and the flag that says it runs.
    private var unifiedLogTail: UnifiedLogTail?
    private var unifiedLogStarted = false

    private lazy var timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    // a tunnel start that macOS stops again at once (#282) is retried once with a fresh configuration
    private var startAttempt = 0
    private var startFailureHandled = false
    private var repairTried = false
    private let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    init(profile: CLIProfile?, verbose: Int, diagnoseOnly: Bool = false) {
        self.profile = profile
        self.verbose = verbose
        self.diagnoseOnly = diagnoseOnly
        super.init()
    }

    func start() {
        installSignalHandlers()
        CLI.say("ProxyBridge CLI \(CLI.version())")
        CLI.say("Extension: activating...")
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: CLI.extensionIdentifier, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
        // the first run can wait for a person to approve the extension, but not forever
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in
            if let self = self, !self.extensionActive { self.fail("Timed out waiting for the extension. Approve it in System Settings > Privacy & Security and run the command again.") }
        }
    }

    // MARK: - extension

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        DispatchQueue.main.async {
            // an update that macOS finishes after a restart is not running yet
            if result == .willCompleteAfterReboot {
                self.fail("macOS will finish activating the system extension after a restart. Restart your Mac and run the command again.")
                return
            }
            self.extensionActive = true
            CLI.say("Extension: active")
            // the DNS entry is set up now, not after the tunnel is up. when the tunnel never starts, a DNS
            // proxy that was meant to be off must not stay on
            CLI.say(self.profile?.dnsEnabled == true ? "DNS proxy: on" : "DNS proxy: off (host name rules and send hostname do not work)")
            // the diagnosis has no profile, so it must not touch the DNS entry of the
            // profile that is in use
            if !self.diagnoseOnly {
                self.applyDNSProxy()
            }
            self.configureTunnel()
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        DispatchQueue.main.async { self.fail("The system extension could not be activated: \(error.localizedDescription)") }
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        CLI.say("Extension: waiting for your approval. Open System Settings > Privacy & Security and click Allow, then enter your password. This is needed once.")
    }

    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties, withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        return .replace
    }

    // MARK: - tunnel

    private func configureTunnel() {
        CLI.say("Network configuration: setting up (macOS asks you to allow it the first time)...")
        NETransparentProxyManager.loadAllFromPreferences { [weak self] managers, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let error = error { self.fail("Could not load the network configuration: \(error.localizedDescription)"); return }
                // only this app's own configuration is reused or changed: the other ones in
                // the list belong to other builds of ProxyBridge and to other proxy apps.
                let ours = NetworkConfigOwner.ourManagers(managers ?? [])
                if ours.count > 1 {
                    // more than one configuration of this app is in the system: an earlier
                    // build wrote one under a different app bundle id and it was never
                    // removed. The one that belongs to an app that is not installed can
                    // never start, and macOS shows them all with the same name. All of
                    // them go and one new one is written, which also gives the new one the
                    // code signature of the extension that is installed now.
                    CLI.say("Found \(ours.count) saved network configurations of this app. Removing the old ones and writing a single new one.")
                    NetworkConfigOwner.clearAll(ours) { self.writeTunnelConfiguration() }
                    return
                }
                self.writeTunnelConfiguration(managers: ours)
            }
        }
    }

    private func writeTunnelConfiguration(managers: [NETransparentProxyManager] = []) {
        let manager = managers.first ?? NETransparentProxyManager()
        manager.localizedDescription = NetworkConfigOwner.configDescription
        manager.isEnabled = true
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = CLI.extensionIdentifier
        proto.serverAddress = "ProxyBridge"
        NetworkConfigOwner.mark(proto)
        manager.protocolConfiguration = proto
        manager.saveToPreferences { saveError in
            DispatchQueue.main.async {
                if let saveError = saveError { self.fail("Could not save the network configuration: \(saveError.localizedDescription)"); return }
                manager.loadFromPreferences { loadError in
                    DispatchQueue.main.async {
                        if let loadError = loadError { self.fail("Could not reload the network configuration: \(loadError.localizedDescription)"); return }
                        self.startTunnel(manager)
                    }
                }
            }
        }
    }

    private func startTunnel(_ manager: NETransparentProxyManager) {
        self.manager = manager
        guard let session = manager.connection as? NETunnelProviderSession else { fail("The tunnel session is not available."); return }
        self.session = session
        if let old = statusObserver { NotificationCenter.default.removeObserver(old) }
        startAttempt += 1
        let attempt = startAttempt
        startFailureHandled = false
        var sawConnecting = false

        // watch the tunnel for as long as we run: it connects once, and if something else stops it
        // later (the app being opened, the extension crashing) nothing is redirected any more and
        // the user has to be told instead of being left with a CLI that looks fine
        statusObserver = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: session, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            switch session.status {
            case .connecting:
                sawConnecting = true
            case .connected:
                if !self.started { self.tunnelIsUp() }
            case .disconnected, .invalid:
                if self.started && !self.stopping {
                    self.fail("The tunnel was stopped by something else (is the ProxyBridge app running?). Nothing is being redirected any more.")
                } else if !self.started && sawConnecting {
                    self.startFailed(attempt: attempt, why: "The tunnel stopped before it was ready")
                }
            default: break
            }
        }

        if session.status == .connected { tunnelIsUp(); return }
        // The rules and the proxy list go with the start of the tunnel. The system
        // hands them to the extension, and they never touch a file: the provider
        // channel is the normal way, but the system checks that channel against the
        // app's signature, and a build that is not signed by a developer never gets a
        // message through. Then the extension has no rules at all and proxies nothing.
        do { try session.startTunnel(options: startOptions()) } catch { fail("Could not start the tunnel: \(error.localizedDescription)"); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.startFailed(attempt: attempt, why: "The tunnel did not start in 30 seconds")
        }
    }

    // the tunnel did not come up. say why (macOS keeps the reason of the last stop), then remove the saved
    // network configuration and try once more with a fresh one. a bad saved configuration is the usual cause.
    private func startFailed(attempt: Int, why: String) {
        guard attempt == startAttempt, !started, !stopping, !startFailureHandled, let session = session else { return }
        startFailureHandled = true
        TunnelRepair.lastDisconnectReason(session) { reason in
            DispatchQueue.main.async {
                CLI.warn("\(why). macOS says: \(CLIText.safe(reason))")
                // macOS bound the tunnel to an extension whose app is gone. The
                // configuration is fine, so creating a new one would not help: the
                // system would bind it to the same extension again.
                if ExtensionDiagnosis.isMissingProviderApp(reason: reason) {
                    CLI.warn(ExtensionDiagnosis.missingProviderAppExplanation)
                    CLI.warn("Command: \(ExtensionDiagnosis.removeOldExtensionsCommand)")
                    self.fail("The other ProxyBridge extension has to be taken out of the system before this one can be used.")
                    return
                }
                if self.repairTried {
                    self.fail("The tunnel still does not start. Remove the ProxyBridge entries in System Settings, Network, restart the Mac and run the command again. If it keeps failing, report it with the output of: systemextensionsctl list")
                    return
                }
                self.repairTried = true
                CLI.say("Removing the saved network configuration and creating a new one. macOS may ask you to allow it again.")
                TunnelRepair.removeSavedConfigurations(extensionIdentifier: CLI.extensionIdentifier) { summary in
                    DispatchQueue.main.async {
                        CLI.say(CLIText.safe(summary))
                        self.applyDNSProxy()
                        self.configureTunnel()
                    }
                }
            }
        }
    }

    // MARK: - profile

    // The rules and the proxy list, in the shape the extension reads them. They are
    // handed over when the tunnel starts, so they arrive even when the provider
    // channel does not open.
    private func startOptions() -> [String: Any]? {
        guard let profile = profile else { return nil }
        var payload: [String: Any] = [
            "version": 1,
            "proxies": proxyMessages(profile),
            "chains": chainMessages(profile),
            "rules": RuleManager.rulePayload(profile.rules)
        ]
        // the DNS policy as well: the rules that name a host need the map that the
        // DNS proxy builds with it, and the policy is what tells the DNS proxy how
        if let policy = profile.dnsPolicy, !policy.isEmpty { payload["dnsPolicy"] = policy }
        return ["proxybridge": payload]
    }

    // the tunnel is up. either the profile goes to the extension, or the app says
    // whether it can reach the extension at all (--diagnose)
    private func tunnelIsUp() {
        if diagnoseOnly {
            runDiagnosis()
            return
        }
        applyProfile()
    }

    // Says what is between the app and the extension.
    //
    // The rules and the proxy list travel to the extension in two ways: over the
    // provider channel, and with the configuration the tunnel is started with.
    // The system checks the provider channel against the app's signature. When
    // the app is not signed by a developer the system drops the message without
    // a word: the tunnel is up, the extension runs and proxies the traffic, but
    // the app cannot read the connection list back.
    //
    // This is the report that says so out loud, with the two things that can be
    // checked: the signature of the app, and whether the app group it declares can
    // be used at all.
    private func runDiagnosis() {
        CLI.say("")
        CLI.say("ProxyBridge diagnosis")
        CLI.say("  app: \(CLI.bundleIdentifier)")
        CLI.say("  extension: \(CLI.extensionIdentifier)")
        CLI.say("  signature: " + (ExtensionDiagnosis.hasDeveloperSignature()
            ? "signed by a developer (team id present)"
            : "ad-hoc (no team id) - the system refuses what is tied to a team"))
        CLI.say("  shared container: " + (ExtensionDiagnosis.sharedContainerReachable()
            ? "reachable"
            : "refused by the system (the app group needs the team id of the signature)"))
        CLI.say("  unified log: " + (ExtensionLogReader.canRead()
            ? "readable (the extension's decisions are read from there)"
            : "refused by the system (the app sandbox keeps logd from serving it)"))

        guard let session = session else {
            CLI.say("  extension channel: no tunnel to talk over")
            self.stop(code: 1)
            return
        }

        handshake(session: session, attempt: 0) { ok in
            if ok {
                CLI.say("  extension channel: the extension answers")
                CLI.say("")
                CLI.say("The app and the extension can talk to each other: the rules and the")
                CLI.say("proxy list will arrive, and the window shows the connections.")
            } else {
                CLI.say("  extension channel: the extension does not answer")
                CLI.say("")
                // the same explanation the window shows, from the same place
                let paragraphs = ExtensionDiagnosis.extensionUnreachableExplanation(
                    hasDeveloperSignature: ExtensionDiagnosis.hasDeveloperSignature())
                for paragraph in paragraphs {
                    for line in CLIText.wrap(paragraph) { CLI.say(line) }
                    CLI.say("")
                }
            }
            self.stop(code: ok ? 0 : 1)
        }
    }

    private func applyProfile() {
        guard let profile = profile else { return }
        guard !started, !stopping, let session = session else { return }
        started = true

        // first: who is on the other end of this tunnel? a tunnel can be up while the
        // extension behind it is another build, or does not answer at all. then every
        // rule and every proxy is dropped in silence and nothing is proxied. the
        // answer is what turns that silence into a reason.
        handshake(session: session) { ok in
            self.providerChannelAvailable = ok
            if !ok {
                // not fatal: the rules and the proxy list went with the start of
                // the tunnel, and the system hands those over without the check
                // that shuts the provider channel for a build that is not signed
                // by a developer
                CLI.warn("The extension does not answer over the provider channel. The rules and the proxy list went with the start of the tunnel instead.")
            }
            self.sendProfile(session: session, profile: profile, providerChannel: ok)
        }
    }

    private func sendProfile(session: NETunnelProviderSession, profile: CLIProfile, providerChannel: Bool) {
        // same messages, same order as the GUI: logging, proxies, the DNS policy, then the rules in one step
        send(["action": "setTrafficLogging", "enabled": verbose >= 2]) { _ in
            self.send(["action": "setProxyConfigs", "configs": self.proxyMessages(profile), "chains": self.chainMessages(profile)]) { _ in
                self.sendDNSPolicy(profile) { _ in
                    RuleManager.applyRulesReporting(session: session, rules: profile.rules) { _, count, answer in
                        if providerChannel {
                            CLI.say("Profile \"\(CLIText.safe(profile.name))\": \(profile.proxies.count) proxies, \(count) rules applied")
                            // the extension skips a rule it can't read, don't let that pass silently
                            if count < profile.rules.count {
                                let reason = answer?["message"] as? String
                                CLI.warn("\(profile.rules.count - count) rule(s) were rejected by the extension" + (reason.map { ": \($0)" } ?? ""))
                            }
                        } else {
                            // the extension never answered, so it cannot say how many
                            // rules it took. the rules went through the container, and
                            // the extension counts them there.
                            CLI.say("Profile \"\(CLIText.safe(profile.name))\": \(profile.proxies.count) proxies, \(profile.rules.count) rules handed to the extension with the start of the tunnel")
                        }
                        CLI.say("Redirecting traffic. Press Ctrl+C to stop.")
                        if self.verbose > 0 { self.startLogPolling() }
                    }
                }
            }
        }
    }

    // Asks the extension that the tunnel is connected to which one it is.
    //
    // macOS keeps every registered version of a system extension under the same bundle
    // id. An older one may answer, or answer with another protocol, and then the rules
    // and the proxies are ignored without a word. Same check the window does, so the
    // command line says the same thing the window says.
    private func handshake(session: NETunnelProviderSession, attempt: Int = 0, completion: @escaping (Bool) -> Void) {
        guard let data = try? JSONSerialization.data(withJSONObject: ["action": "getInfo"]) else { completion(false); return }
        do {
            try session.sendProviderMessage(data) { response in
                DispatchQueue.main.async {
                    switch ExtensionHandshake.verdict(response: response) {
                    case .ok(let api, let version):
                        CLI.say("Extension: protocol \(api), version \(version)")
                        completion(true)
                    case .mismatch(let api):
                        CLI.warn("The extension speaks protocol \(api), this build speaks \(ExtensionHandshake.protocolAPI). It is another build of ProxyBridge.")
                        completion(false)
                    case .noAnswer:
                        // the extension needs a moment to answer after the tunnel comes up
                        self.retryHandshake(session: session, attempt: attempt, completion: completion)
                    }
                }
            }
        } catch {
            DispatchQueue.main.async { self.retryHandshake(session: session, attempt: attempt, completion: completion) }
        }
    }

    private func retryHandshake(session: NETunnelProviderSession, attempt: Int, completion: @escaping (Bool) -> Void) {
        guard attempt < 10, !stopping else { completion(false); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { completion(false); return }
            self.handshake(session: session, attempt: attempt + 1, completion: completion)
        }
    }

    // the chains go with the proxies: a chain is an ordered list of proxy ids
    private func chainMessages(_ profile: CLIProfile) -> [[String: Any]] {
        return profile.chains.map { chain in
            [
                "id": chain["id"] as? String ?? "",
                "name": chain["name"] as? String ?? "",
                "proxies": chain["proxies"] as? [String] ?? []
            ]
        }
    }

    private func proxyMessages(_ profile: CLIProfile) -> [[String: Any]] {
        profile.proxies.map { p in
            var dict: [String: Any] = ["id": p.id, "proxyType": p.type, "proxyHost": p.host, "proxyPort": p.port, "sendDomainToProxy": p.sendDomain]
            if let u = p.username { dict["proxyUsername"] = u }
            if let pw = p.password { dict["proxyPassword"] = pw }
            return dict
        }
    }

    // The DNS provider is what makes domain rules and host names work, the GUI turns it on
    // too, and the profile's Enable DNS setting decides. Only our own entry is ever
    // switched off.
    //
    // The entry is written again on every start, even when it already says what we want.
    // macOS records the code signature of the extension in the saved configuration, and
    // an ad-hoc build gets a new signature every time it is made. A configuration that
    // still points at an older build is silently ignored: the system never starts the
    // dns proxy provider, no ip -> name map is built, and every host name rule misses.
    // Writing it again is what makes macOS look at the extension that is installed now.
    private func applyDNSProxy(attempt: Int = 0) {
        let dns = NEDNSProxyManager.shared()
        let wanted = profile?.dnsEnabled ?? false
        dns.loadFromPreferences { loadError in
            let ours = dns.providerProtocol?.providerBundleIdentifier == CLI.extensionIdentifier
            if !wanted {
                guard loadError == nil, ours, dns.isEnabled else { return }
                dns.isEnabled = false
                dns.saveToPreferences { error in
                    if let error = error { CLI.warn("Could not switch the DNS proxy off: \(error.localizedDescription)") }
                }
                return
            }
            let proto = NEDNSProxyProviderProtocol()
            proto.providerBundleIdentifier = CLI.extensionIdentifier
            dns.providerProtocol = proto
            dns.localizedDescription = "ProxyBridge DNS"
            dns.isEnabled = true
            dns.saveToPreferences { error in
                if let error = error {
                    // The system refuses the configuration while the extension is
                    // still waiting for its approval, and it says so with a bare
                    // "permission denied". It is a state that passes, so it is
                    // worth a few tries: without the dns proxy there is no ip ->
                    // name map, and every rule that names a host misses.
                    if attempt < 5 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            self.applyDNSProxy(attempt: attempt + 1)
                        }
                        return
                    }
                    CLI.warn("DNS proxy setup failed: \(error.localizedDescription). Host name rules and send hostname will not work.")
                }
            }
        }
    }

    // the DNS policy reaches the DNS proxy provider through the shared container,
    // the same way the GUI does it. a profile without a policy leaves the
    // extension on its default, so nothing is sent.
    private func sendDNSPolicy(_ profile: CLIProfile, completion: @escaping ([String: Any]?) -> Void) {
        guard let policy = profile.dnsPolicy, !policy.isEmpty else {
            completion(nil)
            return
        }
        send(["action": "setDNSPolicy", "policy": policy], completion: completion)
    }

    private func send(_ message: [String: Any], completion: (([String: Any]?) -> Void)? = nil) {
        guard let session = session, let data = try? JSONSerialization.data(withJSONObject: message) else { completion?(nil); return }
        let action = message["action"] as? String ?? "?"
        do {
            try session.sendProviderMessage(data) { response in
                let object = response.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
                DispatchQueue.main.async {
                    // an answer that says "error" is worth saying out loud: the
                    // extension understood the message and could not do it
                    if let status = object?["status"] as? String, status != "ok" {
                        CLI.warn("The extension could not \(action): \(object?["message"] as? String ?? "unknown reason")")
                    }
                    completion?(object)
                }
            }
        } catch {
            // the message could not even be sent: the tunnel is not really up
            CLI.warn("Could not send \"\(action)\" to the extension: \(error.localizedDescription)")
            DispatchQueue.main.async { completion?(nil) }
        }
    }

    // MARK: - logs

    private func startLogPolling() {
        logTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.pollLogs() }
    }

    // the extension answers with at most 100 entries and keeps 500, so when a burst fills an
    // answer, ask again straight away instead of waiting a second and losing the oldest lines.
    // never two requests at once.
    private func pollLogs() {
        // The extension writes every decision it made to the unified log, and a
        // build that is not signed by a developer cannot read it back over the
        // message channel. So the log is followed there instead.
        if !providerChannelAvailable {
            followUnifiedLog()
            return
        }
        guard !polling, !stopping, let session = session, let data = try? JSONSerialization.data(withJSONObject: ["action": "getLogs"]) else { return }
        polling = true
        do {
            try session.sendProviderMessage(data) { response in
                DispatchQueue.main.async {
                    self.polling = false
                    guard let response = response, let logs = (try? JSONSerialization.jsonObject(with: response)) as? [[String: String]] else { return }
                    self.print(logs)
                    if logs.count >= 100 { self.pollLogs() }
                }
            }
        } catch {
            polling = false
        }
    }

    // Follows the unified log and prints what the extension writes.
    //
    // The message channel is how a build that is signed by a developer reads
    // the log. A build that is not signed follows the unified log instead: the
    // extension writes every decision it made there.
    private func followUnifiedLog() {
        guard !stopping else { return }
        // the poll runs every second: the tool is started once and left alone
        guard !unifiedLogStarted else { return }
        unifiedLogStarted = true
        let show: (ExtensionLogReader.Line) -> Void = { [weak self] line in
            guard let self = self else { return }
            // the lines about the traffic of the flows are the bookkeeping of the app and the
            // extension, not something to read: they come every second
            guard line.flowEvent == nil, line.proxyTotals == nil else { return }
            let stamp = self.timestampFormatter.string(from: line.date)
            // the same split the message channel uses: the connections need the
            // loudest level, the rest is for the level that wants everything but
            // is too noisy for the one in between
            if line.connection != nil {
                guard self.verbose >= 2 else { return }
                CLI.say("[\(stamp)] " + CLIText.safe(line.text))
            } else {
                guard self.verbose == 1 || self.verbose == 3 else { return }
                CLI.say("[\(stamp)] [\(line.level)] " + CLIText.safe(line.text))
            }
        }

        // the minute before, so a run that starts while traffic is flowing
        // shows something, and then the tool follows the log as it grows
        UnifiedLogBacklog.read(seconds: 60) { [weak self] lines in
            guard let self = self, !self.stopping else { return }
            for line in lines { show(line) }
            let tail = UnifiedLogTail()
            tail.onLines = { lines in
                for line in lines { show(line) }
            }
            tail.onFailure = { reason in
                CLI.warn(ExtensionLogReader.unreadableReason(reason))
            }
            self.unifiedLogTail = tail
            tail.start()
        }
    }

    // one write per answer, not one per line. everything in an entry came from outside (process
    // names, DNS names, a proxy's reply), so it is made safe to show in a terminal first
    private func print(_ logs: [[String: String]]) {
        let now = clock.string(from: Date())
        var lines: [String] = []
        for log in logs {
            if log["type"] == "connection" {
                guard verbose >= 2 else { continue }
                lines.append("[\(now)] \(CLIText.safe(log["protocol"] ?? "?")) \(CLIText.safe(log["process"] ?? "?")) -> \(CLIText.safe(log["destination"] ?? "?")):\(CLIText.safe(log["port"] ?? "?")) via \(CLIText.safe(log["proxy"] ?? "?"))")
            } else {
                guard verbose == 1 || verbose == 3 else { continue }
                lines.append("[\(now)] [\(CLIText.safe(log["level"] ?? "INFO"))] \(CLIText.safe(log["message"] ?? ""))")
            }
        }
        if !lines.isEmpty { CLI.say(lines.joined(separator: "\n")) }
    }

    // MARK: - stopping

    // Ctrl+C, kill, and closing the Terminal window (SIGHUP) all clean up. SIGKILL can't be caught
    private func installSignalHandlers() {
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in self?.stop(code: 0) }
            source.resume()
            signalSources.append(source)
        }
    }

    // called when our output went away
    func stopFromOutside(reason: String?) {
        DispatchQueue.main.async { self.stop(code: 0) }
    }

    private func fail(_ message: String) {
        FileHandle.standardError.write(Data(("ERROR: " + CLIText.lines(message) + "\n").utf8))
        stop(code: 1)
    }

    // clear the rules and the proxies (so nothing keeps redirecting to a stopped tool), then stop the tunnel
    private func stop(code: Int32) {
        guard !stopping else { return }
        stopping = true
        logTimer?.invalidate()
        // the tool that follows the log is a process of its own: it goes with
        // the command
        unifiedLogTail?.stop()
        guard let session = session else { exit(code) }
        if !started {
            // stopped while still starting: the tunnel may be up already, don't leave it running
            session.stopTunnel()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(code) }
            return
        }
        CLI.say("Stopping...")
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { exit(code) }   // never hang if the extension doesn't answer
        RuleManager.clearRules(session: session) { _, _ in
            self.send(["action": "clearConfig"]) { _ in
                session.stopTunnel()
                CLI.say("Rules cleared, tunnel stopped.")
                exit(code)
            }
        }
    }
}
