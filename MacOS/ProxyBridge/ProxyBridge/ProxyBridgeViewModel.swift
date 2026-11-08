import Foundation
import NetworkExtension
import SystemExtensions
import Combine
import AppKit

class ProxyBridgeViewModel: NSObject, ObservableObject {
    @Published var connections: [ConnectionLog] = []
    @Published var activityLogs: [ActivityLog] = []
    @Published var isProxyActive = false
    @Published var isTrafficLoggingEnabled = true
    // the system DNS proxy lets the extension learn which names belong to which addresses, which
    // host name rules and "send hostname" need. per profile, on by default
    @Published var isDNSEnabled = true
    // set once the extension is installed, the DNS entry is only touched after that
    private var extensionReady = false
    // the tunnel start is watched: macOS can stop it again at once without saying why (#282)
    private var tunnelStartPending = false
    private var tunnelWatchdog: DispatchWorkItem?
    private var tunnelFailureObserver: NSObjectProtocol?
    private var tunnelRepairTried = false
    // the timer that asks the system again whether the extension has been approved
    private var approvalWatchTimer: Timer?
    private var approvalWatchAttempts = 0
    private let approvalWatchInterval = 20.0
    private let approvalWatchLimit = 45
    
    var tunnelSession: NETunnelProviderSession?
    private var logTimer: Timer?
    // the live connections are polled on their own timer: they are not a log, they are what the
    // user terminates a hanging connection from
    private var flowTimer: Timer?
    @Published private(set) var liveFlows: [LiveFlow] = []
    // The traffic per proxy: one row for every proxy the traffic went through.
    @Published private(set) var proxyTraffic: [ProxyTraffic] = []
    // Whether a connection can be closed by hand. It needs the message channel, which is closed
    // for a build that is not signed by a developer.
    @Published private(set) var canTerminateFlows = false
    @Published private(set) var proxyConfigs: [ProxyConfig] = []
    @Published private(set) var profiles: [String] = []
    @Published private(set) var activeProfile: String = "Default"
    // what the last import had to leave out, shown to the user once
    @Published var lastImportNotes: [String] = []
    // The health of the proxies the chains walk through, as the extension
    // reported it. The key is the label of the proxy, e.g. "SOCKS5 127.0.0.1:9991":
    // false means the proxy does not answer and is skipped.
    @Published private(set) var chainHealth: [String: Bool] = [:]
    // Bumped every time the DNS settings window is opened.
    //
    // The window is reused when it is opened again, and a SwiftUI view that
    // stays in a window does not get its onAppear called a second time. Without
    // this the window would show what was typed the last time it was open, even
    // when the settings were changed somewhere else in the meantime.
    @Published private(set) var dnsSettingsOpenCount = 0

    func noteDNSSettingsOpened() {
        dnsSettingsOpenCount += 1
    }
    // macOS asks the user to approve the system extension once. Until that happens
    // nothing can be proxied, so the GUI says where the switch is and opens the pane.
    @Published var needsExtensionApproval = false
    // set when the extension that answered the handshake is not this build: an
    // older ProxyBridge is still registered and the system bound the tunnel to it.
    // Then the rules and the proxies never arrive and nothing is proxied, so the
    // window has to say why instead of showing an empty list.
    @Published private(set) var extensionProblem: String? = nil
    // The long form of the notice, when there is one. The bar itself says
    // what the problem is in one line, and this is what the "Details" button
    // shows.
    @Published private(set) var extensionProblemDetails: String? = nil
    // Whether the notice in the window is a standing condition - something
    // that is true from the first launch until the app is signed - rather
    // than something that happened. A standing condition can be pushed away
    // for good; an event can not.
    private var extensionProblemIsStanding = false
    // where a pushed-away standing notice is remembered
    private static let standingNoticeDismissedKey = "standingExtensionNoticeDismissed"
    // what the notice in the window offers. Not every problem has a command:
    // the one that says the extension does not answer at all is fixed by a
    // signature, not by a command in a terminal.
    enum ExtensionProblemAction {
        case none
        case copyRemoveCommand
    }
    @Published private(set) var extensionProblemAction: ExtensionProblemAction = .none

    // Whether the extension answers over the provider channel.
    //
    // The system checks that channel against the app's signature, so a build
    // that is not signed by a developer gets no message through it. That decides
    // how a change reaches the running extension: over the channel, or with a
    // restart of the tunnel.
    private var providerChannelAvailable = false

    // The flows the extension reported in the unified log, by id.
    private var loggedFlows: [UInt64: LoggedFlow] = [:]
    // The ids of the flows that are open right now.
    private var liveFlowIds: Set<UInt64> = []
    // How many connections went through each proxy.
    private var proxyConnections: [String: Int] = [:]
    // The flows the extension reported over the message channel. They say more than the ones
    // from the log, so they win when they are there.
    private var providerFlows: [LiveFlow] = []
    // The totals the extension counted itself, by proxy.
    //
    // They are the numbers the table shows. The app cannot count them on its own: it only
    // sees what the unified log hands it, and a flow that opened and closed before the app
    // started is gone from the log by the time the app looks.
    private var extensionTotals: [(proxy: String, up: Int64, down: Int64, connections: Int)] = []

    // The version of the message protocol between the app and the extension. It has
    // to match AppProxyProvider.protocolAPI on the extension side.
    private let extensionProtocolAPI = ExtensionHandshake.protocolAPI
    
    private let maxLogEntries = 500
    // trim back to this when the cap is hit, so we don't shift on every entry
    private let trimToEntries = 400
    // How often the extension is asked for its log over the message channel.
    // That is the way a build that is signed by a developer reads it; a build
    // that is not signed follows the unified log instead.
    private let logPollingInterval = 1.0
    private let flowPollingInterval = 1.0
    private let extensionIdentifier = "com.sdpong.proxybridge.extension"
    private let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
    private var connectionIdCounter: Int = 0
    private var activityIdCounter: Int = 0
    
    struct ProxyConfig: Identifiable, Codable {
        let id: String
        var name: String
        let type: String
        let host: String
        let port: Int
        let username: String?
        let password: String?
        // same as the windows app: true = the proxy gets the host name the app resolved
        // (socks5h / CONNECT host:port), false = it gets the ip. per proxy, on by default
        var sendDomain: Bool
        // tell the proxy server which application the traffic comes from, so a server
        // that routes by application can do it. off by default: a server that does not
        // know about it ignores what is sent
        var sendAppId: Bool

        // name is optional, show type and host:port either way
        var displayName: String {
            let server = "\(type.uppercased()) \(host):\(port)"
            return name.isEmpty ? server : "\(name) = \(server)"
        }

        init(id: String = UUID().uuidString, name: String = "", type: String, host: String, port: Int, username: String?, password: String?, sendDomain: Bool = true, sendAppId: Bool = false) {
            self.sendDomain = sendDomain
            self.sendAppId = sendAppId
            self.id = id
            self.name = name
            self.type = type
            self.host = host
            self.port = port
            self.username = username
            self.password = password
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decode(String.self, forKey: .id)
            self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            self.type = try c.decode(String.self, forKey: .type)
            self.host = try c.decode(String.self, forKey: .host)
            self.port = try c.decode(Int.self, forKey: .port)
            self.username = try c.decodeIfPresent(String.self, forKey: .username)
            self.password = try c.decodeIfPresent(String.self, forKey: .password)
            // proxies saved before this option existed behave like the windows default
            self.sendDomain = try c.decodeIfPresent(Bool.self, forKey: .sendDomain) ?? true
            // the application id is a new thing: a proxy that was saved before it
            // existed sends nothing
            self.sendAppId = try c.decodeIfPresent(Bool.self, forKey: .sendAppId) ?? false
        }
    }
    
    struct ConnectionLog: Identifiable {
        let id: Int
        let timestamp: String
        let connectionProtocol: String
        let process: String
        let destination: String
        let port: String
        let proxy: String
    }
    
    struct ActivityLog: Identifiable {
        let id: Int
        let timestamp: String
        let level: String
        let message: String
    }

    // A flow that is proxied right now. The extension reports the ones that are open, so the
    // app can list them and terminate one that hangs.
    struct LiveFlow: Identifiable {
        let id: UInt64
        let protocolName: String
        let process: String
        let destination: String
        let port: Int
        let proxy: String
        let bytesUp: Int64
        let bytesDown: Int64
        let age: TimeInterval
        let idle: TimeInterval
    }

    // What one proxy carried: how many connections went through it and how many bytes it carried.
    // One row for every proxy the traffic went through, the way Proxifier shows what a proxy did.
    struct ProxyTraffic: Identifiable {
        let id: String
        let proxy: String
        let connections: Int
        let bytesUp: Int64
        let bytesDown: Int64
        // Whether the bytes are known at all. The bytes of a direct connection are not: macOS
        // hands those flows straight back to the system, so the extension never sees them.
        let bytesKnown: Bool
    }

    // A flow the extension reported in the unified log.
    private struct LoggedFlow {
        let id: UInt64
        let proto: String
        let process: String
        let destination: String
        let port: Int
        let proxy: String
        let startedAt: Date
        var lastActivity: Date
        var bytesUp: Int64 = 0
        var bytesDown: Int64 = 0
        // whether the flow has ended. an ended flow is only kept until the totals of the
        // extension have arrived: after that they are the numbers that are shown, and a
        // flow that is over has no reason to be held on to.
        var ended = false
    }

    // when every window is hidden or minimized there's no point polling logs
    private var isWindowVisible = true

    override init() {
        super.init()
        // both arrays are capped at maxLogEntries, reserve up front so a busy
        // session doesn't keep reallocating the backing storage as it fills
        connections.reserveCapacity(maxLogEntries)
        activityLogs.reserveCapacity(maxLogEntries)
        loadTrafficLoggingSetting()
        loadDNSSetting()
        loadProfiles()
        loadProxyConfig()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(occlusionChanged),
            name: NSApplication.didChangeOcclusionStateNotification,
            object: nil
        )
        installAndStartProxy()
    }

    @objc private func occlusionChanged() {
        isWindowVisible = NSApp.occlusionState.contains(.visible)
        updatePollingState()
    }

    // single place that decides whether the poll timer should be running
    private func updatePollingState() {
        if isTrafficLoggingEnabled && tunnelSession != nil && isWindowVisible {
            startLogPollingTimer()
        } else {
            stopLogPollingTimer()
        }
        // the live connections are not a log, so they are polled whenever the tunnel runs
        if tunnelSession != nil && isWindowVisible {
            startFlowPollingTimer()
        } else {
            stopFlowPollingTimer()
        }
    }

    private func stopLogPollingTimer() {
        DispatchQueue.main.async { [weak self] in
            self?.logTimer?.invalidate()
            self?.logTimer = nil
        }
    }

    private func stopFlowPollingTimer() {
        DispatchQueue.main.async { [weak self] in
            self?.flowTimer?.invalidate()
            self?.flowTimer = nil
        }
    }
    
    private func loadTrafficLoggingSetting() {
        isTrafficLoggingEnabled = UserDefaults.standard.object(forKey: "trafficLoggingEnabled") as? Bool ?? true
    }
    
    func toggleTrafficLogging() {
        isTrafficLoggingEnabled.toggle()
        UserDefaults.standard.set(isTrafficLoggingEnabled, forKey: "trafficLoggingEnabled")
        sendTrafficLoggingToExtension(isTrafficLoggingEnabled)
        updatePollingState()
    }
    
    private func loadDNSSetting() {
        isDNSEnabled = UserDefaults.standard.object(forKey: "dnsEnabled") as? Bool ?? true
        loadDNSPolicySetting()
    }

    func toggleDNS() {
        isDNSEnabled.toggle()
        UserDefaults.standard.set(isDNSEnabled, forKey: "dnsEnabled")
        applyDNSProxy()
    }

    // the DNS policy decides which names may become a proxy destination, which
    // resolver answers them and whether the proxy server resolves them itself
    @Published var dnsPolicy = DNSPolicySettings()

    private func loadDNSPolicySetting() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: "dnsPolicy"),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            dnsPolicy = DNSPolicySettings.fromDictionary(dict)
        } else {
            dnsPolicy = DNSPolicySettings()
        }
    }

    // saves the policy and hands it to the extension, which publishes it where
    // the DNS proxy provider can see it
    func updateDNSPolicy(_ policy: DNSPolicySettings) {
        dnsPolicy = policy
        let d = UserDefaults.standard
        if let data = try? JSONSerialization.data(withJSONObject: policy.toDictionary()) {
            d.set(data, forKey: "dnsPolicy")
            // the profile carries a copy of its own. without this the profile
            // keeps the policy it had, and the settings look like they were
            // never saved: the exported profile has the old policy in it and
            // switching away and back throws the change away
            d.set(data, forKey: profileDNSPolicyKey(activeProfile))
        }
        sendDNSPolicyToExtension()
        addLog("INFO", L10n.f("DNS settings saved: %@", policy.summary))
    }

    // the policy as it is stored right now.
    //
    // The window reads this instead of the copy in memory: the window is reused
    // when it is opened again, and a window that shows an old copy would save
    // that old copy back over the settings that were changed in the meantime.
    func storedDNSPolicy() -> DNSPolicySettings {
        let d = UserDefaults.standard
        if let data = d.data(forKey: "dnsPolicy"),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return DNSPolicySettings.fromDictionary(dict)
        }
        return dnsPolicy
    }

    // what the DNS proxy is doing, read from the log the extension writes.
    //
    // The message channel is not an option: it is checked against the app's
    // signature and a build that is not signed by a developer gets no message
    // through it. The log is what is left, and it is where the window gets the
    // numbers from.
    func readDNSStatus(completion: @escaping (DNSStatus?) -> Void) {
        UnifiedLogBacklog.read(seconds: 180) { lines in
            completion(DNSStatus.newest(in: lines))
        }
    }

    // whether the system has the DNS proxy entry turned on. nil means the
    // system would not say.
    func readDNSProxyEntry(completion: @escaping (Bool?) -> Void) {
        let manager = NEDNSProxyManager.shared()
        manager.loadFromPreferences { error in
            guard error == nil else {
                completion(nil)
                return
            }
            completion(manager.isEnabled)
        }
    }

    private func sendDNSPolicyToExtension() {
        guard let session = tunnelSession else { return }
        let message: [String: Any] = [
            "action": "setDNSPolicy",
            "policy": dnsPolicy.toDictionary()
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        try? session.sendProviderMessage(data) { _ in }
    }

    private func sendTrafficLoggingToExtension(_ enabled: Bool) {
        guard let session = tunnelSession else { return }
        
        let message: [String: Any] = [
            "action": "setTrafficLogging",
            "enabled": enabled
        ]
        
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        
        try? session.sendProviderMessage(data) { _ in }
    }
    
    private func loadProxyConfig() {
        if let data = UserDefaults.standard.data(forKey: "proxyConfigs"),
           let configs = try? JSONDecoder().decode([ProxyConfig].self, from: data) {
            proxyConfigs = configs
        } else {
            proxyConfigs = []
        }
        loadChains()
    }

    // the proxy chains: an ordered list of proxies a connection walks through
    @Published var chains: [ProxyChain] = []

    // the type of every proxy, by id, so a chain can be checked against it
    var proxyTypesById: [String: String] {
        var out: [String: String] = [:]
        for config in proxyConfigs { out[config.id] = config.type.lowercased() }
        return out
    }

    private func loadChains() {
        chains = ProxyChain.list(from: UserDefaults.standard.data(forKey: "chains"))
    }

    // MARK: - Profiles
    //
    // a profile bundles the proxy configs + rules. the live "proxyConfigs" and
    // "proxyRules" UserDefaults keys always hold the active profile so the rest
    // of the app and the extension keep reading them unchanged. switching just
    // snapshots the current profile and swaps in another one's data.

    private func profileConfigsKey(_ name: String) -> String { "profile.\(name).proxyConfigs" }
    private func profileRulesKey(_ name: String) -> String { "profile.\(name).proxyRules" }
    private func profileLoggingKey(_ name: String) -> String { "profile.\(name).trafficLoggingEnabled" }
    private func profileCloseKey(_ name: String) -> String { "profile.\(name).closeToMenuBar" }
    private func profileStartupKey(_ name: String) -> String { "profile.\(name).runAtStartup" }
    private func profileDNSKey(_ name: String) -> String { "profile.\(name).dnsEnabled" }
    private func profileDNSPolicyKey(_ name: String) -> String { "profile.\(name).dnsPolicy" }
    private func profileChainsKey(_ name: String) -> String { "profile.\(name).chains" }

    private func loadProfiles() {
        let d = UserDefaults.standard
        var names = d.stringArray(forKey: "profiles") ?? []
        if names.isEmpty {
            // first run, seed a Default profile from whatever is already stored
            names = ["Default"]
            d.set(names, forKey: "profiles")
            d.set("Default", forKey: "activeProfile")
            flushWorkingSet(to: "Default")
        }
        profiles = names
        activeProfile = d.string(forKey: "activeProfile") ?? names.first ?? "Default"
    }

    // copy the live working keys into a profile's snapshot
    private func flushWorkingSet(to name: String) {
        let d = UserDefaults.standard
        d.set(d.data(forKey: "proxyConfigs"), forKey: profileConfigsKey(name))
        d.set(d.array(forKey: "proxyRules"), forKey: profileRulesKey(name))
        d.set(isTrafficLoggingEnabled, forKey: profileLoggingKey(name))
        d.set(d.bool(forKey: "closeToMenuBar"), forKey: profileCloseKey(name))
        d.set(d.bool(forKey: "runAtStartup"), forKey: profileStartupKey(name))
        d.set(isDNSEnabled, forKey: profileDNSKey(name))
        d.set(d.data(forKey: "dnsPolicy"), forKey: profileDNSPolicyKey(name))
        d.set(d.data(forKey: "chains"), forKey: profileChainsKey(name))
    }

    // load a profile's snapshot into the live working keys
    private func loadWorkingSet(from name: String) {
        let d = UserDefaults.standard
        if let data = d.data(forKey: profileConfigsKey(name)) {
            d.set(data, forKey: "proxyConfigs")
        } else {
            d.removeObject(forKey: "proxyConfigs")
        }
        d.set(d.array(forKey: profileRulesKey(name)) ?? [], forKey: "proxyRules")
        // traffic logging is per profile, default on when the snapshot has none
        d.set(d.object(forKey: profileLoggingKey(name)) as? Bool ?? true, forKey: "trafficLoggingEnabled")
        // window + startup behaviour are per profile too, default off
        d.set(d.object(forKey: profileCloseKey(name)) as? Bool ?? false, forKey: "closeToMenuBar")
        d.set(d.object(forKey: profileStartupKey(name)) as? Bool ?? false, forKey: "runAtStartup")
        // DNS is on by default, also for profiles saved before the setting existed
        d.set(d.object(forKey: profileDNSKey(name)) as? Bool ?? true, forKey: "dnsEnabled")
        // the DNS policy is per profile too, a profile saved before the setting
        // existed keeps the default policy
        if let policyData = d.data(forKey: profileDNSPolicyKey(name)) {
            d.set(policyData, forKey: "dnsPolicy")
        } else {
            d.removeObject(forKey: "dnsPolicy")
        }
        // the chains are per profile too
        if let chainsData = d.data(forKey: profileChainsKey(name)) {
            d.set(chainsData, forKey: "chains")
        } else {
            d.removeObject(forKey: "chains")
        }
    }

    // reload in-memory state from the working keys and push it to the extension
    private func applyActiveProfile() {
        loadProxyConfig()
        loadTrafficLoggingSetting()
        loadDNSSetting()
        // window-close behaviour is read live from the key, only startup needs applying
        LoginItem.applyToSystem(UserDefaults.standard.bool(forKey: "runAtStartup"))
        if tunnelSession != nil {
            deliverChangeToExtension()
            sendTrafficLoggingToExtension(isTrafficLoggingEnabled)
            sendDNSPolicyToExtension()
        }
        applyDNSProxy()
        updatePollingState()
    }

    func switchProfile(to name: String) {
        guard name != activeProfile, profiles.contains(name) else { return }
        flushWorkingSet(to: activeProfile)
        loadWorkingSet(from: name)
        activeProfile = name
        UserDefaults.standard.set(name, forKey: "activeProfile")
        applyActiveProfile()
    }

    func createProfile(_ rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !profiles.contains(name) else { return }
        // new profiles start empty
        UserDefaults.standard.removeObject(forKey: profileConfigsKey(name))
        UserDefaults.standard.set([[String: Any]](), forKey: profileRulesKey(name))
        profiles.append(name)
        UserDefaults.standard.set(profiles, forKey: "profiles")
        switchProfile(to: name)
    }

    func renameProfile(_ old: String, to rawNew: String) {
        let new = rawNew.trimmingCharacters(in: .whitespaces)
        guard !new.isEmpty, profiles.contains(old), !profiles.contains(new) else { return }
        let d = UserDefaults.standard
        // make sure the active profile's snapshot is current before moving it
        if old == activeProfile { flushWorkingSet(to: old) }
        d.set(d.data(forKey: profileConfigsKey(old)), forKey: profileConfigsKey(new))
        d.set(d.array(forKey: profileRulesKey(old)), forKey: profileRulesKey(new))
        d.set(d.object(forKey: profileLoggingKey(old)), forKey: profileLoggingKey(new))
        d.set(d.object(forKey: profileCloseKey(old)), forKey: profileCloseKey(new))
        d.set(d.object(forKey: profileStartupKey(old)), forKey: profileStartupKey(new))
        d.set(d.object(forKey: profileDNSKey(old)), forKey: profileDNSKey(new))
        d.set(d.data(forKey: profileDNSPolicyKey(old)), forKey: profileDNSPolicyKey(new))
        d.set(d.data(forKey: profileChainsKey(old)), forKey: profileChainsKey(new))
        d.removeObject(forKey: profileConfigsKey(old))
        d.removeObject(forKey: profileRulesKey(old))
        d.removeObject(forKey: profileLoggingKey(old))
        d.removeObject(forKey: profileCloseKey(old))
        d.removeObject(forKey: profileStartupKey(old))
        d.removeObject(forKey: profileDNSKey(old))
        d.removeObject(forKey: profileDNSPolicyKey(old))
        d.removeObject(forKey: profileChainsKey(old))
        if let i = profiles.firstIndex(of: old) { profiles[i] = new }
        d.set(profiles, forKey: "profiles")
        if activeProfile == old {
            activeProfile = new
            d.set(new, forKey: "activeProfile")
        }
    }

    func deleteProfile(_ name: String) {
        guard profiles.count > 1, profiles.contains(name) else { return }
        // can't delete the one we're on, move to another first
        if name == activeProfile, let other = profiles.first(where: { $0 != name }) {
            switchProfile(to: other)
        }
        let d = UserDefaults.standard
        d.removeObject(forKey: profileConfigsKey(name))
        d.removeObject(forKey: profileRulesKey(name))
        d.removeObject(forKey: profileLoggingKey(name))
        d.removeObject(forKey: profileCloseKey(name))
        d.removeObject(forKey: profileStartupKey(name))
        d.removeObject(forKey: profileDNSKey(name))
        d.removeObject(forKey: profileDNSPolicyKey(name))
        d.removeObject(forKey: profileChainsKey(name))
        profiles.removeAll { $0 == name }
        d.set(profiles, forKey: "profiles")
    }

    // build a portable .pbprofile json for a profile
    func exportProfileData(_ name: String) -> Data? {
        guard profiles.contains(name) else { return nil }
        // make sure the active profile's snapshot reflects the latest edits
        if name == activeProfile { flushWorkingSet(to: name) }
        let d = UserDefaults.standard
        let configsJSON = d.data(forKey: profileConfigsKey(name))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? []
        let dict: [String: Any] = [
            "name": name,
            "trafficLoggingEnabled": d.object(forKey: profileLoggingKey(name)) as? Bool ?? true,
            "closeToMenuBar": d.object(forKey: profileCloseKey(name)) as? Bool ?? false,
            "runAtStartup": d.object(forKey: profileStartupKey(name)) as? Bool ?? false,
            "dnsEnabled": d.object(forKey: profileDNSKey(name)) as? Bool ?? true,
            "dnsPolicy": d.data(forKey: profileDNSPolicyKey(name))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? dnsPolicy.toDictionary(),
            "proxyConfigs": configsJSON,
            "proxyRules": d.array(forKey: profileRulesKey(name)) ?? [],
            // the chains go out in the current shape, so an exported profile
            // is read the same way whatever build wrote the snapshot
            "proxyChains": ProxyChain.list(from: d.data(forKey: profileChainsKey(name)))
                .map { ["id": $0.id, "name": $0.name, "proxies": $0.proxyIds] }
        ]
        return try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
    }

    // create a new profile from a .pbprofile json (or a Proxifier .ppx) and switch to it
    @discardableResult
    func importProfile(from data: Data, name: String? = nil) -> Bool {
        // a Proxifier profile is xml, not json: it is converted first
        var payload = data
        if PPXImporter.looksLikePPX(data) {
            guard let imported = PPXImporter.parse(data, name: name ?? "Proxifier") else { return false }
            lastImportNotes = imported.warnings
            guard let converted = try? JSONSerialization.data(withJSONObject: imported.profile) else { return false }
            payload = converted
        } else {
            lastImportNotes = []
        }
        guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return false }
        var base = (obj["name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? "Imported"
        if base.isEmpty { base = "Imported" }
        let name = uniqueProfileName(base)

        let d = UserDefaults.standard
        // re-encode the configs array back to the Data form we store, ids are kept
        // so each rule's action still points at the right proxy config
        if let configsJSON = obj["proxyConfigs"],
           let configsData = try? JSONSerialization.data(withJSONObject: configsJSON) {
            d.set(configsData, forKey: profileConfigsKey(name))
        } else {
            d.removeObject(forKey: profileConfigsKey(name))
        }
        d.set(obj["proxyRules"] as? [[String: Any]] ?? [], forKey: profileRulesKey(name))
        d.set(obj["trafficLoggingEnabled"] as? Bool ?? true, forKey: profileLoggingKey(name))
        d.set(obj["closeToMenuBar"] as? Bool ?? false, forKey: profileCloseKey(name))
        d.set(obj["runAtStartup"] as? Bool ?? false, forKey: profileStartupKey(name))
        d.set(obj["dnsEnabled"] as? Bool ?? true, forKey: profileDNSKey(name))
        // the policy travels with the profile, a profile without one keeps the default
        if let policyDict = obj["dnsPolicy"] as? [String: Any],
           let policyData = try? JSONSerialization.data(withJSONObject: policyDict) {
            d.set(policyData, forKey: profileDNSPolicyKey(name))
        }
        // the chains travel with the profile. they are read through the decoder and
        // written back in the current shape, so a profile that came in with the
        // hops under another key keeps its hops.
        if let chainsJSON = obj["proxyChains"] as? [[String: Any]] {
            let chains = chainsJSON.map { chain in
                ProxyChain(id: chain["id"] as? String ?? UUID().uuidString,
                           name: chain["name"] as? String ?? "",
                           proxyIds: ProxyChain.hops(from: chain))
            }
            if let chainsData = try? JSONEncoder().encode(chains) {
                d.set(chainsData, forKey: profileChainsKey(name))
            }
        }

        profiles.append(name)
        d.set(profiles, forKey: "profiles")
        switchProfile(to: name)
        return true
    }

    private func uniqueProfileName(_ base: String) -> String {
        if !profiles.contains(base) { return base }
        var i = 2
        while profiles.contains("\(base) (\(i))") { i += 1 }
        return "\(base) (\(i))"
    }

    private func saveProxyConfigs() {
        if let data = try? JSONEncoder().encode(proxyConfigs) {
            UserDefaults.standard.set(data, forKey: "proxyConfigs")
        }
    }

    func addProxyConfig(_ config: ProxyConfig) {
        proxyConfigs.append(config)
        saveProxyConfigs()
        deliverChangeToExtension()
    }

    func updateProxyConfig(_ config: ProxyConfig) {
        if let index = proxyConfigs.firstIndex(where: { $0.id == config.id }) {
            proxyConfigs[index] = config
            saveProxyConfigs()
            deliverChangeToExtension()
        }
    }

    // MARK: - Proxy chains

    private func saveChains() {
        if let data = try? JSONEncoder().encode(chains) {
            UserDefaults.standard.set(data, forKey: "chains")
        }
    }

    func addChain(_ chain: ProxyChain) {
        chains.append(chain)
        saveChains()
        pushChainsToExtension()
    }

    func updateChain(_ chain: ProxyChain) {
        if let index = chains.firstIndex(where: { $0.id == chain.id }) {
            chains[index] = chain
            saveChains()
            pushChainsToExtension()
        }
    }

    // a chain that is removed leaves the rules that used it on DIRECT, so they
    // do not silently go direct anyway
    func removeChain(_ chain: ProxyChain) {
        if var saved = UserDefaults.standard.array(forKey: "proxyRules") as? [[String: Any]] {
            var changed = false
            for i in saved.indices where (saved[i]["action"] as? String) == chain.action {
                saved[i]["action"] = "DIRECT"
                changed = true
            }
            if changed {
                UserDefaults.standard.set(saved, forKey: "proxyRules")
                deliverChangeToExtension()
            }
        }
        chains.removeAll { $0.id == chain.id }
        saveChains()
        pushChainsToExtension()
    }

    // how many rules point at this chain
    func rulesUsingChain(id: String) -> Int {
        let saved = UserDefaults.standard.array(forKey: "proxyRules") as? [[String: Any]] ?? []
        return saved.filter { ($0["action"] as? String) == ProxyChain.actionPrefix + id }.count
    }

    private func pushChainsToExtension() {
        deliverChangeToExtension()
    }

    func rulesUsingProxy(id: String) -> Int {
        let saved = UserDefaults.standard.array(forKey: "proxyRules") as? [[String: Any]] ?? []
        return saved.filter { ($0["action"] as? String) == id }.count
    }

    func removeProxyConfig(_ config: ProxyConfig) {
        // reset any rules pointing to this config to DIRECT so they don't silently go direct anyway
        if var saved = UserDefaults.standard.array(forKey: "proxyRules") as? [[String: Any]] {
            var changed = false
            for i in saved.indices where (saved[i]["action"] as? String) == config.id {
                saved[i]["action"] = "DIRECT"
                changed = true
            }
            if changed {
                UserDefaults.standard.set(saved, forKey: "proxyRules")
                deliverChangeToExtension()
            }
        }
        proxyConfigs.removeAll { $0.id == config.id }
        saveProxyConfigs()
        deliverChangeToExtension()
    }
    
    private func installAndStartProxy() {
        // Stop our own tunnel first so macOS replaces the running extension binary with
        // the newly installed one instead of reusing the old cached process. Only the
        // configurations this app wrote are touched: another app's tunnel (the upstream
        // release, the user's own Proxifier) must keep running.
        NETransparentProxyManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self = self else { return }

            let ours = NetworkConfigOwner.ourManagers(managers ?? [])
            if let existing = ours.first,
               let session = existing.connection as? NETunnelProviderSession,
               session.status != .disconnected && session.status != .invalid {
                session.stopTunnel()
                // Brief pause to let the old extension fully terminate
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    self.submitExtensionActivationRequest()
                }
            } else {
                self.submitExtensionActivationRequest()
            }
        }
        // Put the network configuration into the system right away, even when the
        // extension is not approved yet. It shows up in System Settings > Network >
        // VPN & Filters, and switching it on is what approves the extension - so the
        // user gets the switch where they look for it instead of having to find the
        // extension in another pane.
        ensureNetworkConfiguration()
    }
    
    private func submitExtensionActivationRequest() {
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: extensionIdentifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }
    
    // Writes this app's network configuration. Only the configurations this app wrote
    // are reused or changed: the other ones in the list belong to other builds of
    // ProxyBridge and to other proxy apps; taking them over would switch the user's
    // own proxy off.
    private func ensureNetworkConfiguration(completion: ((NETransparentProxyManager) -> Void)? = nil) {
        NETransparentProxyManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self = self else { return }

            if let error = error {
                self.addLog("ERROR", L10n.f("Failed to load managers: %@", error.localizedDescription))
                return
            }

            let ours = NetworkConfigOwner.ourManagers(managers ?? [])
            if ours.count > 1 {
                // More than one configuration of this app is in the system: an
                // earlier build wrote one under a different app bundle id and it
                // was never removed. The one that belongs to an app that is not
                // installed can never start, and macOS shows them all with the
                // same name, so the person cannot tell which one is in use. All
                // of them go and one new one is written.
                self.addLog("INFO", L10n.f("Found %@ saved network configurations of this app. Removing the old ones and writing a single new one.", "\(ours.count)"))
                NetworkConfigOwner.clearAll(ours) {
                    self.writeNetworkConfiguration(completion: completion)
                }
                return
            }
            self.writeNetworkConfiguration(managers: ours, completion: completion)
        }
    }

    private func writeNetworkConfiguration(managers: [NETransparentProxyManager] = [], completion: ((NETransparentProxyManager) -> Void)? = nil) {
        let manager = managers.first ?? NETransparentProxyManager()
        manager.localizedDescription = NetworkConfigOwner.configDescription
        manager.isEnabled = true

        let providerProtocol = NETunnelProviderProtocol()
        providerProtocol.providerBundleIdentifier = self.extensionIdentifier
        providerProtocol.serverAddress = "ProxyBridge"
        NetworkConfigOwner.mark(providerProtocol)
        manager.protocolConfiguration = providerProtocol

        manager.saveToPreferences { saveError in
            DispatchQueue.main.async {
                if let saveError = saveError {
                    self.addLog("ERROR", L10n.f("Failed to save preferences: %@", saveError.localizedDescription))
                    return
                }
                completion?(manager)
            }
        }
    }
    
    // The rules and the proxy list, in the shape the extension reads them.
    private func tunnelStartOptions() -> [String: Any]? {
        let proxies: [[String: Any]] = proxyConfigs.map { config in
            var dict: [String: Any] = [
                "id": config.id,
                "proxyType": config.type,
                "proxyHost": config.host,
                "proxyPort": config.port,
                "sendDomainToProxy": config.sendDomain,
                "sendAppIdToProxy": config.sendAppId
            ]
            if let u = config.username { dict["proxyUsername"] = u }
            if let p = config.password { dict["proxyPassword"] = p }
            return dict
        }
        let chains: [[String: Any]] = chains.map { chain in
            ["id": chain.id, "name": chain.name, "proxies": chain.proxyIds]
        }
        let rules = UserDefaults.standard.array(forKey: "proxyRules") as? [[String: Any]] ?? []
        var payload: [String: Any] = [
            "version": 1,
            "proxies": proxies,
            "chains": chains,
            "rules": RuleManager.rulePayload(rules)
        ]
        // the DNS policy as well: the rules that name a host need the map that the
        // DNS proxy builds with it, and the policy is what tells the DNS proxy how
        let policy = dnsPolicy.toDictionary()
        if !policy.isEmpty { payload["dnsPolicy"] = policy }
        return ["proxybridge": payload]
    }

    func startProxy() {
        ensureNetworkConfiguration { manager in
            self.addLog("INFO", L10n.t("Configuration saved"))
            self.reloadAndStartTunnel(manager: manager)
        }
    }

    // makes the system DNS proxy entry match the profile's Enable DNS setting. on: the extension sees
    // the dns answers and can build the ip -> name map used by host name rules and "send hostname".
    // off: the entry is switched off so macOS sends dns the normal way and another tool can use the
    // one dns proxy slot macOS has. only our own entry is ever changed.
    //
    // The entry is written again on every start, even when it already says what we want.
    // macOS records the code signature of the extension in the saved configuration, and an
    // ad-hoc build gets a new signature every time it is made. A configuration that still
    // points at an older build is ignored by the system: the dns proxy provider is never
    // started, the ip -> name map stays empty, and every host name rule misses.
    func applyDNSProxy(attempt: Int = 0) {
        guard extensionReady else { return }
        let enable = isDNSEnabled
        let manager = NEDNSProxyManager.shared()
        manager.loadFromPreferences { [weak self] loadError in
            guard let self = self else { return }
            let ours = manager.providerProtocol?.providerBundleIdentifier == self.extensionIdentifier
            if enable {
                let proto = NEDNSProxyProviderProtocol()
                proto.providerBundleIdentifier = self.extensionIdentifier
                manager.providerProtocol = proto
                manager.localizedDescription = "ProxyBridge DNS"
                manager.isEnabled = true
                manager.saveToPreferences { error in
                    DispatchQueue.main.async {
                        if let error = error {
                            // The system refuses the configuration while the
                            // extension is still waiting for its approval, and it
                            // says so with a bare "permission denied". It is a state
                            // that passes, so it is worth a few tries: without the
                            // dns proxy there is no ip -> name map, and every rule
                            // that names a host misses.
                            if attempt < 5 {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                    self.applyDNSProxy(attempt: attempt + 1)
                                }
                                return
                            }
                            self.addLog("ERROR", L10n.f("DNS proxy setup failed: %@. Host name rules and send hostname will not work.", error.localizedDescription))
                        } else {
                            self.addLog("INFO", L10n.t("DNS proxy enabled"))
                        }
                    }
                }
            } else {
                let note = L10n.t("DNS proxy is off (Enable DNS in the Proxy menu). Host name rules and send hostname do not work.")
                guard loadError == nil, ours, manager.isEnabled else {
                    DispatchQueue.main.async { self.addLog("INFO", note) }
                    return
                }
                manager.isEnabled = false
                manager.saveToPreferences { error in
                    DispatchQueue.main.async {
                        if let error = error {
                            self.addLog("ERROR", L10n.f("Could not switch the DNS proxy off: %@", error.localizedDescription))
                        } else {
                            self.addLog("INFO", note)
                        }
                    }
                }
            }
        }
    }

    // macOS can turn the DNS proxy entry off by itself.
    //
    // The entry keeps the code signature of the extension it was written for,
    // and an ad-hoc build has a new signature every time it is made. The system
    // then refuses the entry, says so in its own log ("the configuration was
    // disabled") and the DNS proxy stops. Nothing else notices: the ip -> name
    // map stays empty, so the proxy server is given an address where a name was
    // meant, and a site that only answers to a name cannot be reached.
    //
    // So the entry is looked at from time to time while the tunnel runs, and it
    // is written again when it is off.
    private func ensureDNSProxyEntry() {
        guard isDNSEnabled, tunnelSession != nil else { return }
        let now = Date()
        guard now.timeIntervalSince(lastDNSCheckAt) > dnsCheckInterval else { return }
        lastDNSCheckAt = now

        NEDNSProxyManager.shared().loadFromPreferences { [weak self] error in
            guard let self = self, error == nil else { return }
            let manager = NEDNSProxyManager.shared()
            let ours = manager.providerProtocol?.providerBundleIdentifier == self.extensionIdentifier
            guard !manager.isEnabled || !ours else { return }
            DispatchQueue.main.async {
                self.addLog("INFO", L10n.t("The DNS proxy entry was off in the system. It is being written again, so host names are known again."))
                self.applyDNSProxy()
            }
        }
    }

    // when the entry was looked at the last time, and how often
    private var lastDNSCheckAt = Date.distantPast
    private let dnsCheckInterval: TimeInterval = 30

    // the timer that keeps an eye on the DNS proxy entry
    private var dnsCheckTimer: Timer?

    private func startDNSCheckTimer() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard self.dnsCheckTimer == nil else { return }
            self.dnsCheckTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                self?.ensureDNSProxyEntry()
            }
        }
    }

    private func stopDNSCheckTimer() {
        DispatchQueue.main.async { [weak self] in
            self?.dnsCheckTimer?.invalidate()
            self?.dnsCheckTimer = nil
        }
    }

    private func reloadAndStartTunnel(manager: NETransparentProxyManager) {
        manager.loadFromPreferences { [weak self] loadError in
            guard let self = self else { return }

            if let loadError = loadError {
                self.addLog("ERROR", L10n.f("Failed to reload preferences: %@", loadError.localizedDescription))
                return
            }

            guard let session = manager.connection as? NETunnelProviderSession else { return }

            // register before startTunnel so we can't miss a fast .connected transition
            // remove the observer the moment it fires in oneshot to avoid configuring twice
            var observer: NSObjectProtocol?
            observer = NotificationCenter.default.addObserver(
                forName: .NEVPNStatusDidChange,
                object: session,
                queue: .main
            ) { [weak self] _ in
                guard let self = self, session.status == .connected else { return }
                if let obs = observer { NotificationCenter.default.removeObserver(obs) }
                observer = nil

                self.setupLogPolling(session: session)
                if !self.proxyConfigs.isEmpty {
                    self.sendProxyConfigsToExtension(session: session)
                }
                
                RuleManager.loadRulesFromUserDefaults(session: session) { success, count in
                    if success && count > 0 {
                        self.addLog("INFO", L10n.f("Loaded %@ rule(s) from local storage", "\(count)"))
                    }
                }
            }

            do {
                DispatchQueue.main.async { self.watchTunnelStart(session: session) }
                // The rules and the proxy list go with the start of the tunnel. The
                // system hands them to the extension, and they never touch a file:
                // the provider channel is the normal way, but the system checks that
                // channel against the app's signature, and a build that is not signed
                // by a developer never gets a message through. Then the extension has
                // no rules at all and proxies nothing.
                try session.startTunnel(options: self.tunnelStartOptions())
                DispatchQueue.main.async {
                    self.isProxyActive = true
                    self.addLog("INFO", L10n.t("Proxy tunnel started"))
                }
            } catch {
                if let obs = observer { NotificationCenter.default.removeObserver(obs) }
                observer = nil
                DispatchQueue.main.async { self.tunnelStartPending = false }
                self.addLog("ERROR", L10n.f("Failed to start tunnel: %@", error.localizedDescription))
            }
        }
    }

    // a start that macOS stops again at once, or that never finishes, is reported with the reason macOS
    // recorded. the first time, the saved network configuration is removed and created again, a bad one
    // is the usual cause. the second time the user gets the steps to do by hand.
    private func watchTunnelStart(session: NETunnelProviderSession) {
        tunnelStartPending = true
        tunnelWatchdog?.cancel()
        if let old = tunnelFailureObserver { NotificationCenter.default.removeObserver(old) }
        var sawConnecting = false
        tunnelFailureObserver = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: session, queue: .main) { [weak self] _ in
            guard let self = self, self.tunnelStartPending else { return }
            switch session.status {
            case .connecting:
                sawConnecting = true
            case .connected:
                self.tunnelStartPending = false
                self.tunnelWatchdog?.cancel()
            case .disconnected, .invalid:
                if sawConnecting { self.tunnelStartFailed(session: session, why: L10n.t("The tunnel stopped before it was ready")) }
            default:
                break
            }
        }
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self = self, self.tunnelStartPending, session.status != .connected else { return }
            self.tunnelStartFailed(session: session, why: L10n.t("The tunnel did not start in 30 seconds"))
        }
        tunnelWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: watchdog)
    }

    private func tunnelStartFailed(session: NETunnelProviderSession, why: String) {
        guard tunnelStartPending else { return }
        tunnelStartPending = false
        tunnelWatchdog?.cancel()
        isProxyActive = false
        TunnelRepair.lastDisconnectReason(session) { [weak self] reason in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.addLog("ERROR", L10n.f("%@. macOS says: %@", why, reason))
                // macOS bound the tunnel to an extension whose app is gone. Say so and
                // give the command that takes it out; retrying the configuration would
                // not help, the system would bind it to the same extension again.
                if ExtensionDiagnosis.isMissingProviderApp(reason: reason) {
                    self.extensionProblem = ExtensionDiagnosis.missingProviderAppExplanation
                    self.extensionProblemDetails = nil
                    self.extensionProblemIsStanding = false
                    self.extensionProblemAction = .copyRemoveCommand
                    self.addLog("ERROR", ExtensionDiagnosis.missingProviderAppExplanation)
                    self.addLog("ERROR", L10n.f("Command: %@", ExtensionDiagnosis.removeOldExtensionsCommand))
                    return
                }
                if self.tunnelRepairTried {
                    self.addLog("ERROR", L10n.t("Remove the ProxyBridge entries in System Settings, Network, restart the Mac and open ProxyBridge again. If it still fails, report it with the output of: systemextensionsctl list"))
                    return
                }
                self.tunnelRepairTried = true
                self.addLog("INFO", L10n.t("Removing the saved network configuration and creating a new one. macOS may ask you to allow it again"))
                TunnelRepair.removeSavedConfigurations(extensionIdentifier: self.extensionIdentifier) { summary in
                    DispatchQueue.main.async {
                        self.addLog("INFO", summary)
                        self.startProxy()
                        self.applyDNSProxy()
                    }
                }
            }
        }
    }
    
    // The completion is called when the tunnel is down. A caller that starts a
    // tunnel again waits for it, so the two do not run into each other.
    func stopProxy(completion: (() -> Void)? = nil) {
        stopDNSCheckTimer()
        guard let session = tunnelSession else {
            isProxyActive = false
            logTimer?.invalidate()
            logTimer = nil
            completion?()
            return
        }

        clearExtensionMemory(session: session) { [weak self] in
            guard let self = self else {
                completion?()
                return
            }

            NETransparentProxyManager.loadAllFromPreferences { managers, error in
                if let manager = managers?.first {
                    (manager.connection as? NETunnelProviderSession)?.stopTunnel()
                    self.isProxyActive = false
                    self.logTimer?.invalidate()
                    self.logTimer = nil
                    self.tunnelSession = nil
                    self.addLog("INFO", L10n.t("Proxy stopped and extension memory cleared"))
                }
                completion?()
            }
        }
    }
    
    private func clearExtensionMemory(session: NETunnelProviderSession, completion: @escaping () -> Void) {
        // clearing rules fixes #51 where rules stayed active after the app closed
        RuleManager.clearRules(session: session) { success, message in
            let clearConfigMessage: [String: Any] = [
                "action": "clearConfig"
            ]

            guard let data = try? JSONSerialization.data(withJSONObject: clearConfigMessage) else {
                completion()
                return
            }

            do {
                try session.sendProviderMessage(data) { _ in
                    completion()
                }
            } catch {
                // The message could not be sent at all: the system checks this
                // channel against the app's signature, and a build that is not
                // signed by a developer is refused. The tunnel still has to be
                // stopped, so the caller is called either way.
                completion()
            }
        }
    }
    
    private func setupLogPolling(session: NETunnelProviderSession) {
        tunnelSession = session
        sendTrafficLoggingToExtension(isTrafficLoggingEnabled)
        updatePollingState()
        handshakeWithExtension(session: session)
        // the dns proxy entry can be turned off by the system while the tunnel
        // runs, and then no host name is known any more
        startDNSCheckTimer()
        // the extension writes what it does to the unified log, and a build
        // that is not signed by a developer reads it back from there
        startUnifiedLogTail()
    }
    
    // Asks the extension that the tunnel is connected to which one it is.
    //
    // macOS keeps every registered version of a system extension under the same
    // bundle id. When an older ProxyBridge is still registered, the system may bind
    // the tunnel to that one instead of this build. The old one speaks an older
    // protocol: it ignores the rules and the proxies, so nothing is proxied and the
    // window shows an empty list without saying why. The handshake is what turns
    // that silence into an explanation.
    private func handshakeWithExtension(session: NETunnelProviderSession, attempt: Int = 0) {
        let message = ["action": "getInfo"]
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        do {
            try session.sendProviderMessage(data) { [weak self] response in
                self?.handleHandshakeResponse(response, session: session, attempt: attempt)
            }
        } catch {
            // the message could not even be sent: the tunnel is not up
            scheduleHandshakeRetry(session: session, attempt: attempt)
        }
    }
    
    private func handleHandshakeResponse(_ response: Data?, session: NETunnelProviderSession, attempt: Int) {
        DispatchQueue.main.async {
            switch ExtensionHandshake.verdict(response: response) {
            case .ok(let api, let version):
                self.providerChannelAvailable = true
                self.canTerminateFlows = true
                self.extensionProblem = nil
                self.extensionProblemDetails = nil
                self.extensionProblemIsStanding = false
                self.addLog("INFO", L10n.f("Extension handshake ok (protocol %@, version %@)", "\(api)", "\(version)"))
            case .mismatch(let api):
                self.providerChannelAvailable = false
                self.canTerminateFlows = false
                self.reportExtensionMismatch(api: api)
            case .noAnswer:
                // the extension may simply not be ready yet, so try a few more
                // times before calling it a mismatch
                self.scheduleHandshakeRetry(session: session, attempt: attempt)
            }
        }
    }
    
    // the extension needs a moment to answer right after the tunnel comes up, so
    // a missing answer is not proof of a mismatch. try again a few times first.
    private func scheduleHandshakeRetry(session: NETunnelProviderSession, attempt: Int) {
        guard attempt < 3 else {
            // Nothing answered at all. That is not the same thing as "another
            // build answered": the system checks the provider channel against the
            // app's signature, and a build that is not signed by a developer gets
            // no message through it. Saying "another extension answered" here
            // sends the person off to delete extensions that are not the problem.
            providerChannelAvailable = false
            canTerminateFlows = false
            reportExtensionUnreachable()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.handshakeWithExtension(session: session, attempt: attempt + 1)
        }
    }

    // The tunnel is up, but the extension on the other end is not this build.
    // Only for an answer that says so.
    private func reportExtensionMismatch(api: Int? = nil) {
        let detail = api.map { " (it speaks protocol \($0))" } ?? ""
        extensionProblem = L10n.f("The system bound the tunnel to another, older ProxyBridge extension%@. That one does not understand this version's rules, so nothing is proxied. Take it out with the command below, then switch ProxyBridge on in System Settings > General > Login Items & Extensions > Network Extensions.", detail)
        extensionProblemDetails = nil
        extensionProblemIsStanding = false
        extensionProblemAction = .copyRemoveCommand
        addLog("ERROR", L10n.f("The extension that answered is not this build%@. The rules and the proxies never reach it, so no connection is proxied. Take the older extension out and approve this one.", detail))
    }

    // The extension did not answer at all. The traffic is proxied, but the window
    // cannot show it, and the reason is the signature - not an extension that has
    // to be deleted. There is no command for that, so the notice has no button.
    private func reportExtensionUnreachable() {
        let signed = ExtensionDiagnosis.hasDeveloperSignature()
        extensionProblemDetails = ExtensionDiagnosis.extensionUnreachableExplanation(hasDeveloperSignature: signed).joined(separator: " ")
        if signed {
            // A build with a team id is refused by nothing, so an extension that
            // does not answer is an extension that is not this build. That one
            // has to be taken out, and there is a command for it.
            extensionProblem = ExtensionDiagnosis.extensionUnreachableSummary(hasDeveloperSignature: true)
            extensionProblemAction = .copyRemoveCommand
            addLog("ERROR", L10n.t("The extension does not answer over the provider channel. The tunnel is up, so the extension on the other end is not this build. Take the older extension out and approve this one."))
        } else {
            // A build that is not signed by a developer never gets a message
            // through, and it never will: this is a standing condition and not
            // something that happened. So the bar says what it is in one line,
            // the rest is one click away, and being pushed away is remembered -
            // otherwise it is back on every launch and the person learns to
            // read past it.
            extensionProblemAction = .none
            extensionProblemIsStanding = true
            if UserDefaults.standard.bool(forKey: Self.standingNoticeDismissedKey) {
                extensionProblem = nil
                extensionProblemDetails = nil
            } else {
                extensionProblem = ExtensionDiagnosis.extensionUnreachableSummary(hasDeveloperSignature: false)
            }
            addLog("ERROR", L10n.t("The extension does not answer over the provider channel: this build is not signed by a developer, and macOS does not let it talk to its own system extension. The traffic is proxied all the same, and the connections and their traffic are read from the system log. What is lost: the switches the extension reads while it runs, and closing a connection by hand."))
        }
    }
    
    private func startLogPollingTimer() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // already running, don't reset the cadence
            guard self.logTimer == nil else { return }
            self.logTimer = Timer.scheduledTimer(
                withTimeInterval: self.logPollingInterval,
                repeats: true
            ) { [weak self] _ in
                self?.pollLogs()
            }
        }
    }
    
    private func pollLogs() {
        guard let session = tunnelSession else { return }

        // The message channel is one way to read the log. It only works for a
        // build that is signed by a developer, and asking costs a signature
        // check every second, so it is asked only when it works. A build that
        // is not signed reads the log by following it instead.
        guard providerChannelAvailable else { return }

        let message = ["action": "getLogs"]
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }

        try? session.sendProviderMessage(data) { [weak self] response in
            guard let self = self,
                  let responseData = response,
                  let logs = try? JSONSerialization.jsonObject(with: responseData) as? [[String: String]],
                  !logs.isEmpty else {
                return
            }

            // build the batch first, then touch the published arrays once each
            // so a busy second is one ui update instead of a hundred
            DispatchQueue.main.async {
                var newConnections: [ConnectionLog] = []
                var newActivity: [ActivityLog] = []
                for log in logs {
                    if log["type"] == "connection" {
                        if let c = self.makeConnectionLog(log) { newConnections.append(c) }
                    } else {
                        if let a = self.makeActivityLog(log) { newActivity.append(a) }
                    }
                }
                self.appendConnections(newConnections)
                self.appendActivity(newActivity)
            }
        }
    }

    // The tool that follows the unified log, while the window is open.
    private var unifiedLogTail: UnifiedLogTail?

    // Starts following the unified log.
    //
    // The extension writes every decision it made there, and a build that is
    // not signed by a developer has no other way to read them back. Following
    // the log is cheap - the tool waits for the entries - and the lines come
    // in as they happen.
    private func startUnifiedLogTail() {
        guard unifiedLogTail == nil else { return }
        let tail = UnifiedLogTail()
        tail.onLines = { [weak self] lines in
            DispatchQueue.main.async {
                self?.append(lines)
            }
        }
        tail.onFailure = { [weak self] reason in
            DispatchQueue.main.async {
                self?.addLog("ERROR", ExtensionLogReader.unreadableReason(reason))
            }
        }
        unifiedLogTail = tail

        // the minute before the tool starts, so the list is not empty when the
        // window opens. The tail follows the log from now on.
        UnifiedLogBacklog.read(seconds: 60) { [weak self] lines in
            DispatchQueue.main.async {
                self?.append(lines)
                self?.unifiedLogTail?.start()
            }
        }
    }

    // Puts the lines of the unified log into the lists.
    private func append(_ lines: [ExtensionLogReader.Line]) {
        guard !lines.isEmpty else { return }
        var newConnections: [ConnectionLog] = []
        var newActivity: [ActivityLog] = []
        var trafficChanged = false
        for line in lines {
            if let connection = line.connection {
                if let c = makeConnectionLog(connection, date: line.date) { newConnections.append(c) }
                // every connection that was decided counts towards the proxy it went through
                proxyConnections[connection.proxy, default: 0] += 1
                trafficChanged = true
            } else if let flow = line.flowEvent {
                // the traffic of the open flows. the extension counts the bytes of every flow it
                // proxies and writes them to the log, because the channel that used to carry them
                // is closed for a build that is not signed by a developer
                apply(flow, date: line.date)
                trafficChanged = true
            } else if let health = line.chainHealth {
                // the extension says which hop of a chain does not answer, and
                // when it answers again
                chainHealth[health.label] = health.alive
            } else if let totals = line.proxyTotals {
                // the totals the extension counted itself. they are the numbers the table shows
                extensionTotals = totals
                trafficChanged = true
            } else {
                if let a = makeActivityLog(line) { newActivity.append(a) }
            }
        }
        appendConnections(newConnections)
        appendActivity(newActivity)
        if trafficChanged { publishTraffic() }
    }

    // Takes one line about the traffic of the flows into the books.
    private func apply(_ event: ExtensionLogReader.FlowEvent, date: Date) {
        switch event {
        case .open(let id, let proto, let process, let destination, let port, let proxy):
            // the flow may already be known from the log that was read when the window opened
            let flow = freshFlow(id: id, proto: proto, process: process, destination: destination,
                                 port: port, proxy: proxy, known: loggedFlows[id], date: date)
            loggedFlows[id] = flow
            liveFlowIds.insert(id)
        case .bytes(let rows):
            // the extension writes the flows that are open, so this line replaces the list of
            // them: a flow that is not in it any more is gone
            liveFlowIds = Set(rows.map { $0.id })
            for row in rows {
                guard var flow = loggedFlows[row.id] else { continue }
                if row.up != flow.bytesUp || row.down != flow.bytesDown { flow.lastActivity = date }
                flow.bytesUp = row.up
                flow.bytesDown = row.down
                loggedFlows[row.id] = flow
            }
        case .live(let id, let proto, let process, let destination, let port, let proxy, let up, let down):
            // a flow that is open right now, with everything about it.
            //
            // This is the line that makes a flow that was already open when the window was
            // opened show up: the line about the flow opening is long gone from the log by
            // then, and without this one the flow would have no name, no destination and no
            // proxy, and nothing could be shown for it.
            var flow = freshFlow(id: id, proto: proto, process: process, destination: destination,
                                 port: port, proxy: proxy, known: loggedFlows[id], date: date)
            if up != flow.bytesUp || down != flow.bytesDown { flow.lastActivity = date }
            flow.bytesUp = up
            flow.bytesDown = down
            loggedFlows[id] = flow
            liveFlowIds.insert(id)
        case .end(let id, let up, let down):
            liveFlowIds.remove(id)
            guard var flow = loggedFlows[id] else { return }
            // the last line of a flow carries the bytes it really moved
            flow.bytesUp = up
            flow.bytesDown = down
            flow.ended = true
            loggedFlows[id] = flow
        }
    }

    // The flow a line is about, with what is known about it.
    //
    // A flow that ended and is back is a new one: the ids start over with every
    // tunnel, so the log can hold a line about an old flow and a line about a new
    // one with the same id. The old one is dropped then, or the new flow would
    // carry the age and the bytes of the old one.
    private func freshFlow(id: UInt64, proto: String, process: String, destination: String,
                           port: String, proxy: String, known: LoggedFlow?, date: Date) -> LoggedFlow {
        if let known, !known.ended { return known }
        return LoggedFlow(id: id, proto: proto, process: process, destination: destination,
                          port: Int(port) ?? 0, proxy: proxy, startedAt: date, lastActivity: date)
    }

    // Builds the table: one row for every proxy the traffic went through.
    private func publishTraffic() {
        // The window is redrawn from what is published, and the log brings several
        // lines a second. Putting them out as they come would redraw the window
        // for every line of them.
        let now = Date()
        if now.timeIntervalSince(lastTrafficPublish) < Self.trafficPublishInterval {
            // too soon: the numbers go out with the next round
            trafficPublishPending = true
            scheduleTrafficPublish()
            return
        }
        lastTrafficPublish = now
        trafficPublishPending = false

        var rows: [ProxyTraffic] = []

        if !extensionTotals.isEmpty {
            // the numbers the extension counted itself. they are the ones that are right: the
            // app only knows the flows that were in the log, and a flow that ended before the
            // app started is not in it any more
            for total in extensionTotals {
                // a blocked connection moves no traffic and is not a proxy, so it has no row
                guard total.proxy != "BLOCK" else { continue }
                rows.append(ProxyTraffic(
                    id: total.proxy,
                    proxy: total.proxy,
                    connections: total.connections,
                    bytesUp: total.up,
                    bytesDown: total.down,
                    // the bytes of a direct connection are never seen: macOS hands those flows back
                    // to the system, so the extension is not the one carrying them
                    bytesKnown: total.proxy != "Direct"
                ))
            }
            // the flows that are over are not needed any more: the totals above hold what they
            // carried, and a window that is open for days would otherwise hold every flow that
            // ever went through the machine
            loggedFlows = loggedFlows.filter { !$0.value.ended || liveFlowIds.contains($0.key) }
        } else {
            // nothing came from the extension yet: the numbers the app counted itself are
            // shown until they do
            var up: [String: Int64] = [:]
            var down: [String: Int64] = [:]
            for flow in loggedFlows.values {
                up[flow.proxy, default: 0] += flow.bytesUp
                down[flow.proxy, default: 0] += flow.bytesDown
            }

            var names = Set(proxyConnections.keys)
            names.formUnion(up.keys)
            for name in names {
                guard name != "BLOCK" else { continue }
                rows.append(ProxyTraffic(
                    id: name,
                    proxy: name,
                    connections: proxyConnections[name] ?? 0,
                    bytesUp: up[name] ?? 0,
                    bytesDown: down[name] ?? 0,
                    bytesKnown: name != "Direct"
                ))
            }
        }
        // the busiest proxy first, the same way Proxifier puts the traffic it moved on top
        rows.sort { lhs, rhs in
            if lhs.connections != rhs.connections { return lhs.connections > rhs.connections }
            let left = lhs.bytesUp + lhs.bytesDown
            let right = rhs.bytesUp + rhs.bytesDown
            if left != right { return left > right }
            return lhs.proxy < rhs.proxy
        }
        proxyTraffic = rows
        publishLiveFlows()
    }

    // How often the numbers of the window are put out at the earliest. The log
    // brings lines every second, and a window that is redrawn for every one of
    // them costs more than the reading of the log does.
    private static let trafficPublishInterval: TimeInterval = 0.5
    private var lastTrafficPublish = Date.distantPast
    // whether numbers that came in while the window was redrawing are still to go out
    private var trafficPublishPending = false
    // whether the numbers that are waiting are already booked to go out
    private var trafficPublishScheduled = false

    // Puts out the numbers that had to wait.
    private func scheduleTrafficPublish() {
        guard !trafficPublishScheduled else { return }
        trafficPublishScheduled = true
        let wait = max(0.05, Self.trafficPublishInterval - Date().timeIntervalSince(lastTrafficPublish))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self = self else { return }
            self.trafficPublishScheduled = false
            guard self.trafficPublishPending else { return }
            self.trafficPublishPending = false
            self.publishTraffic()
        }
    }

    // The flows that are open right now.
    private func publishLiveFlows() {
        guard providerFlows.isEmpty else {
            liveFlows = providerFlows
            return
        }
        let now = Date()
        liveFlows = liveFlowIds.compactMap { id -> LiveFlow? in
            guard let flow = loggedFlows[id] else { return nil }
            return LiveFlow(
                id: flow.id,
                protocolName: flow.proto,
                process: flow.process,
                destination: flow.destination,
                port: flow.port,
                proxy: flow.proxy,
                bytesUp: flow.bytesUp,
                bytesDown: flow.bytesDown,
                age: now.timeIntervalSince(flow.startedAt),
                idle: now.timeIntervalSince(flow.lastActivity)
            )
        }
        .sorted { $0.id > $1.id }
    }

    private func startFlowPollingTimer() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // already running, don't reset the cadence
            guard self.flowTimer == nil else { return }
            self.flowTimer = Timer.scheduledTimer(
                withTimeInterval: self.flowPollingInterval,
                repeats: true
            ) { [weak self] _ in
                self?.pollFlows()
            }
        }
    }

    // Asks the extension which flows are proxied right now. The list is replaced, not merged:
    // a flow that is gone from the extension is gone.
    private func pollFlows() {
        // The list comes over the message channel, and the system checks that
        // channel against the app's signature. A build that is not signed by a
        // developer gets no answer - and asking costs a signature check every
        // second, on the thread that draws the window.
        guard providerChannelAvailable else { return }
        guard let session = tunnelSession else { return }

        let message = ["action": "getFlows"]
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }

        try? session.sendProviderMessage(data) { [weak self] response in
            guard let self = self,
                  let responseData = response,
                  let rows = try? JSONSerialization.jsonObject(with: responseData) as? [[String: Any]] else {
                return
            }

            let flows = rows.compactMap { row -> LiveFlow? in
                guard let id = (row["id"] as? NSNumber)?.uint64Value else { return nil }
                return LiveFlow(
                    id: id,
                    protocolName: row["protocol"] as? String ?? "",
                    process: row["process"] as? String ?? "",
                    destination: row["destination"] as? String ?? "",
                    port: (row["port"] as? NSNumber)?.intValue ?? 0,
                    proxy: row["proxy"] as? String ?? "",
                    bytesUp: (row["up"] as? NSNumber)?.int64Value ?? 0,
                    bytesDown: (row["down"] as? NSNumber)?.int64Value ?? 0,
                    age: (row["age"] as? NSNumber)?.doubleValue ?? 0,
                    idle: (row["idle"] as? NSNumber)?.doubleValue ?? 0
                )
            }

            DispatchQueue.main.async {
                // the flows from the channel are the better ones, so they are kept apart and
                // used as soon as there are any
                self.providerFlows = flows
                self.publishLiveFlows()
            }
        }
    }

    // Terminates one live connection: the relay is torn down, so the application sees its
    // connection die instead of waiting for a proxy that stopped answering.
    func killFlow(id: UInt64) {
        guard let session = tunnelSession else { return }

        let message: [String: Any] = ["action": "killFlow", "id": id]
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }

        try? session.sendProviderMessage(data) { [weak self] _ in
            // the flow is gone, so pull a fresh list right away
            DispatchQueue.main.async {
                self?.pollFlows()
            }
        }
    }

    // Terminates every live connection of one process.
    func killFlows(process: String) {
        for flow in liveFlows where flow.process == process {
            killFlow(id: flow.id)
        }
    }

    private func appendConnections(_ items: [ConnectionLog]) {
        guard !items.isEmpty else { return }
        connections.append(contentsOf: items)
        if connections.count > maxLogEntries {
            connections.removeFirst(connections.count - trimToEntries)
        }
    }

    private func appendActivity(_ items: [ActivityLog]) {
        guard !items.isEmpty else { return }
        activityLogs.append(contentsOf: items)
        if activityLogs.count > maxLogEntries {
            activityLogs.removeFirst(activityLogs.count - trimToEntries)
        }
    }

    private func makeConnectionLog(_ log: [String: String]) -> ConnectionLog? {
        guard isTrafficLoggingEnabled else { return nil }

        guard let proto = log["protocol"],
              let process = log["process"],
              let dest = log["destination"],
              let port = log["port"],
              let proxy = log["proxy"] else {
            return nil
        }

        connectionIdCounter &+= 1
        return ConnectionLog(
            id: connectionIdCounter,
            timestamp: getCurrentTimestamp(),
            connectionProtocol: proto,
            process: process,
            destination: dest,
            port: port,
            proxy: proxy
        )
    }

    private func makeActivityLog(_ log: [String: String]) -> ActivityLog? {
        guard let timestamp = log["timestamp"],
              let level = log["level"],
              let message = log["message"] else {
            return nil
        }

        activityIdCounter &+= 1
        return ActivityLog(
            id: activityIdCounter,
            timestamp: timestamp,
            level: level,
            message: message
        )
    }

    // The same, for a line that came out of the unified log.
    private func makeConnectionLog(_ connection: ExtensionLogReader.Connection, date: Date? = nil) -> ConnectionLog? {
        guard isTrafficLoggingEnabled else { return nil }

        connectionIdCounter &+= 1
        return ConnectionLog(
            id: connectionIdCounter,
            // the line knows when it was written, and a line that came from the
            // backlog says so - the time it was read is not the same thing
            timestamp: date.map { timestampFormatter.string(from: $0) } ?? getCurrentTimestamp(),
            connectionProtocol: connection.proto,
            process: connection.process,
            destination: connection.destination,
            port: connection.port,
            proxy: connection.proxy
        )
    }

    // The same, for a line that came out of the unified log.
    private func makeActivityLog(_ line: ExtensionLogReader.Line) -> ActivityLog? {
        // the state of the dns proxy is not an event. it is written every few
        // seconds, and it has its own place: the dns settings window
        guard !line.text.hasPrefix("DNSStatus ") else { return nil }
        activityIdCounter &+= 1
        return ActivityLog(
            id: activityIdCounter,
            // the line knows when it was written
            timestamp: timestampFormatter.string(from: line.date),
            level: line.level,
            message: line.text
        )
    }

    // The tunnel that was restarted to pick up a change, and the work item that
    // waits before it happens.
    private var pendingRestart: DispatchWorkItem?

    // A change to the rules, the proxies or the chains has to reach the running
    // extension.
    //
    // The message channel is how that is done, and the system checks it against
    // the app's signature: a build that is not signed by a developer gets no
    // message through it, and the change the person made in the window would
    // silently do nothing.
    //
    // The tunnel start options carry the same thing, and the system hands those
    // over without the check. So when the channel is closed the tunnel is
    // restarted instead: the change lands, and the open connections drop.
    private func deliverChangeToExtension() {
        guard let session = tunnelSession else { return }
        if providerChannelAvailable {
            sendProxyConfigsToExtension(session: session)
            RuleManager.resyncRules(session: session) { _, _ in }
            return
        }
        scheduleTunnelRestart()
    }

    // The restart is a moment of nothing, and a person who edits three rules in
    // a row should not see three tunnels come and go. So the changes are gathered
    // for a moment and the tunnel is restarted once, with all of them in it.
    private func scheduleTunnelRestart() {
        pendingRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.pendingRestart = nil
            self.restartTunnelNow()
        }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    private func restartTunnelNow() {
        addLog("INFO", L10n.t("The extension did not answer, so the tunnel is restarted to pick up the change."))

        // the same path the on/off switch uses: it stops the tunnel, clears what
        // the extension has, and starts it again with the configuration of now.
        // the start waits for the stop to be through: a tunnel that is started
        // while the old one is still going down is a tunnel that stays down.
        stopProxy { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.startProxy()
            }
        }
    }

    func sendProxyConfigsToExtension(session: NETunnelProviderSession) {
        let configsArray: [[String: Any]] = proxyConfigs.map { config in
            var dict: [String: Any] = [
                "id": config.id,
                "proxyType": config.type,
                "proxyHost": config.host,
                "proxyPort": config.port,
                "sendDomainToProxy": config.sendDomain,
                "sendAppIdToProxy": config.sendAppId
            ]
            if let u = config.username { dict["proxyUsername"] = u }
            if let p = config.password { dict["proxyPassword"] = p }
            return dict
        }
        // the chains go with the proxies: a chain is an ordered list of proxy ids
        let chainsArray: [[String: Any]] = chains.map { chain in
            ["id": chain.id, "name": chain.name, "proxies": chain.proxyIds]
        }
        let message: [String: Any] = ["action": "setProxyConfigs", "configs": configsArray, "chains": chainsArray]
        guard let data = try? JSONSerialization.data(withJSONObject: message) else {
            addLog("ERROR", L10n.t("Failed to encode proxy configs"))
            return
        }
        try? session.sendProviderMessage(data) { [weak self] response in
            if let responseData = response,
               let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
               let status = json["status"] as? String, status == "ok" {
                DispatchQueue.main.async {
                    self?.addLog("INFO", L10n.f("Proxy configs sent: %@ config(s)", "\(self?.proxyConfigs.count ?? 0)"))
                }
            }
        }
    }
    
    // The user pushed the notice away for this session. The problem stays in the
    // activity log, and Settings still has the way to act on it.
    func dismissExtensionProblem() {
        // A standing condition is remembered as pushed away: it is true from
        // the first launch until the app is signed, and a notice that comes
        // back on every launch is a notice the person learns to read past.
        if extensionProblemIsStanding {
            UserDefaults.standard.set(true, forKey: Self.standingNoticeDismissedKey)
        }
        extensionProblem = nil
        extensionProblemDetails = nil
        extensionProblemAction = .none
        extensionProblemIsStanding = false
        needsExtensionApproval = false
    }
    
    func clearConnections() {
        connections.removeAll()
    }
    
    func clearActivityLogs() {
        activityLogs.removeAll()
    }
    
    private func addLog(_ level: String, _ message: String) {
        activityIdCounter &+= 1
        let log = ActivityLog(
            id: activityIdCounter,
            timestamp: getCurrentTimestamp(),
            level: level,
            message: message
        )
        appendActivity([log])
    }
    
    private func getCurrentTimestamp() -> String {
        return timestampFormatter.string(from: Date())
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        logTimer?.invalidate()
        stopApprovalWatch()
        // the tool that follows the log is a process of its own: it goes when
        // the app goes
        unifiedLogTail?.stop()
        stopProxy()
    }
}

extension ProxyBridgeViewModel: OSSystemExtensionRequestDelegate {
    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        DispatchQueue.main.async {
            self.addLog("INFO", L10n.t("Extension installed successfully"))
            self.extensionReady = true
            // the switch in System Settings is on now, the notice has nothing to say
            self.needsExtensionApproval = false
            self.stopApprovalWatch()
            self.startProxy()
            self.applyDNSProxy()
        }
    }
    
    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        DispatchQueue.main.async {
            self.addLog("ERROR", L10n.f("Extension failed: %@", error.localizedDescription))
            // The message on its own does not say what to do. An unsigned build has no
            // entitlements at all, and macOS will not install a system extension from
            // such an app, so say that plainly.
            if error.localizedDescription.lowercased().contains("entitlement") {
                self.addLog("ERROR", L10n.t("macOS does not install the system extension from a build that is not signed. Use a signed build, or build from source: the build script signs the app for you."))
            }
        }
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        DispatchQueue.main.async {
            self.needsExtensionApproval = true
            self.addLog("INFO", L10n.t("macOS wants you to approve ProxyBridge once. Open System Settings > General > Login Items & Extensions > Network Extensions (on macOS 26 and later: Network > VPN & Filters) and switch ProxyBridge on. Until that is done, no traffic can be proxied."))
            // The user approves the extension in System Settings, not in this app, so
            // the app cannot know when it happens. Asking again is how it finds out:
            // once the switch is on, the request succeeds and the proxy starts. That
            // way the user does not have to restart the app after approving.
            self.startApprovalWatch()
        }
    }

    // Asks the system again and again whether the extension is approved now. It stops
    // when the request succeeds, or when it has asked often enough.
    private func startApprovalWatch() {
        guard approvalWatchTimer == nil else { return }
        approvalWatchAttempts = 0
        let timer = Timer.scheduledTimer(withTimeInterval: approvalWatchInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.approvalWatchAttempts += 1
            if self.approvalWatchAttempts > approvalWatchLimit {
                self.stopApprovalWatch()
                return
            }
            self.submitExtensionActivationRequest()
        }
        approvalWatchTimer = timer
    }

    private func stopApprovalWatch() {
        approvalWatchTimer?.invalidate()
        approvalWatchTimer = nil
    }
    
    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties, withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        print("Replacing existing extension")
        return .replace
    }
}
