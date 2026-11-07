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
    @Published private(set) var proxyConfigs: [ProxyConfig] = []
    @Published private(set) var profiles: [String] = []
    @Published private(set) var activeProfile: String = "Default"
    // what the last import had to leave out, shown to the user once
    @Published var lastImportNotes: [String] = []
    // macOS asks the user to approve the system extension once. Until that happens
    // nothing can be proxied, so the GUI says where the switch is and opens the pane.
    @Published var needsExtensionApproval = false
    // set when the extension that answered the handshake is not this build: an
    // older ProxyBridge is still registered and the system bound the tunnel to it.
    // Then the rules and the proxies never arrive and nothing is proxied, so the
    // window has to say why instead of showing an empty list.
    @Published private(set) var extensionProblem: String? = nil
    // what the notice in the window offers. Not every problem has a command:
    // the one that says the extension does not answer at all is fixed by a
    // signature, not by a command in a terminal.
    enum ExtensionProblemAction {
        case none
        case copyRemoveCommand
    }
    @Published private(set) var extensionProblemAction: ExtensionProblemAction = .none
    
    // The version of the message protocol between the app and the extension. It has
    // to match AppProxyProvider.protocolAPI on the extension side.
    private let extensionProtocolAPI = ExtensionHandshake.protocolAPI
    
    private let maxLogEntries = 500
    // trim back to this when the cap is hit, so we don't shift on every entry
    private let trimToEntries = 400
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

        // name is optional, show type and host:port either way
        var displayName: String {
            let server = "\(type.uppercased()) \(host):\(port)"
            return name.isEmpty ? server : "\(name) = \(server)"
        }

        init(id: String = UUID().uuidString, name: String = "", type: String, host: String, port: Int, username: String?, password: String?, sendDomain: Bool = true) {
            self.sendDomain = sendDomain
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
        }
        sendDNSPolicyToExtension()
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
        if let data = UserDefaults.standard.data(forKey: "chains"),
           let saved = try? JSONDecoder().decode([ProxyChain].self, from: data) {
            chains = saved
        } else {
            chains = []
        }
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
        if let session = tunnelSession {
            sendProxyConfigsToExtension(session: session)
            RuleManager.resyncRules(session: session) { _, _ in }
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
            "proxyChains": d.data(forKey: profileChainsKey(name))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? []
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
        // the chains travel with the profile
        if let chainsJSON = obj["proxyChains"],
           let chainsData = try? JSONSerialization.data(withJSONObject: chainsJSON) {
            d.set(chainsData, forKey: profileChainsKey(name))
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
        if let session = tunnelSession {
            sendProxyConfigsToExtension(session: session)
        }
    }

    func updateProxyConfig(_ config: ProxyConfig) {
        if let index = proxyConfigs.firstIndex(where: { $0.id == config.id }) {
            proxyConfigs[index] = config
            saveProxyConfigs()
            if let session = tunnelSession {
                sendProxyConfigsToExtension(session: session)
            }
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
                if let session = tunnelSession {
                    RuleManager.resyncRules(session: session) { _, _ in }
                }
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
        if let session = tunnelSession {
            sendProxyConfigsToExtension(session: session)
        }
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
                if let session = tunnelSession {
                    RuleManager.resyncRules(session: session) { _, _ in }
                }
            }
        }
        proxyConfigs.removeAll { $0.id == config.id }
        saveProxyConfigs()
        if let session = tunnelSession {
            sendProxyConfigsToExtension(session: session)
        }
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
                self.addLog("ERROR", "Failed to load managers: \(error.localizedDescription)")
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
                self.addLog("INFO", "Found \(ours.count) saved network configurations of this app. Removing the old ones and writing a single new one.")
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
                    self.addLog("ERROR", "Failed to save preferences: \(saveError.localizedDescription)")
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
                "sendDomainToProxy": config.sendDomain
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
            self.addLog("INFO", "Configuration saved")
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
    func applyDNSProxy() {
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
                            self.addLog("ERROR", "DNS proxy setup failed: \(error.localizedDescription)")
                        } else {
                            self.addLog("INFO", "DNS proxy enabled")
                        }
                    }
                }
            } else {
                let note = "DNS proxy is off (Enable DNS in the Proxy menu). Host name rules and send hostname do not work."
                guard loadError == nil, ours, manager.isEnabled else {
                    DispatchQueue.main.async { self.addLog("INFO", note) }
                    return
                }
                manager.isEnabled = false
                manager.saveToPreferences { error in
                    DispatchQueue.main.async {
                        if let error = error {
                            self.addLog("ERROR", "Could not switch the DNS proxy off: \(error.localizedDescription)")
                        } else {
                            self.addLog("INFO", note)
                        }
                    }
                }
            }
        }
    }

    private func reloadAndStartTunnel(manager: NETransparentProxyManager) {
        manager.loadFromPreferences { [weak self] loadError in
            guard let self = self else { return }

            if let loadError = loadError {
                self.addLog("ERROR", "Failed to reload preferences: \(loadError.localizedDescription)")
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
                        self.addLog("INFO", "Loaded \(count) rule(s) from local storage")
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
                    self.addLog("INFO", "Proxy tunnel started")
                }
            } catch {
                if let obs = observer { NotificationCenter.default.removeObserver(obs) }
                observer = nil
                DispatchQueue.main.async { self.tunnelStartPending = false }
                self.addLog("ERROR", "Failed to start tunnel: \(error.localizedDescription)")
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
                if sawConnecting { self.tunnelStartFailed(session: session, why: "The tunnel stopped before it was ready") }
            default:
                break
            }
        }
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self = self, self.tunnelStartPending, session.status != .connected else { return }
            self.tunnelStartFailed(session: session, why: "The tunnel did not start in 30 seconds")
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
                self.addLog("ERROR", "\(why). macOS says: \(reason)")
                // macOS bound the tunnel to an extension whose app is gone. Say so and
                // give the command that takes it out; retrying the configuration would
                // not help, the system would bind it to the same extension again.
                if ExtensionDiagnosis.isMissingProviderApp(reason: reason) {
                    self.extensionProblem = ExtensionDiagnosis.missingProviderAppExplanation
                    self.extensionProblemAction = .copyRemoveCommand
                    self.addLog("ERROR", ExtensionDiagnosis.missingProviderAppExplanation)
                    self.addLog("ERROR", "Command: \(ExtensionDiagnosis.removeOldExtensionsCommand)")
                    return
                }
                if self.tunnelRepairTried {
                    self.addLog("ERROR", "Remove the ProxyBridge entries in System Settings, Network, restart the Mac and open ProxyBridge again. If it still fails, report it with the output of: systemextensionsctl list")
                    return
                }
                self.tunnelRepairTried = true
                self.addLog("INFO", "Removing the saved network configuration and creating a new one. macOS may ask you to allow it again")
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
    
    func stopProxy() {
        guard let session = tunnelSession else {
            isProxyActive = false
            logTimer?.invalidate()
            logTimer = nil
            return
        }
        
        clearExtensionMemory(session: session) { [weak self] in
            guard let self = self else { return }
            
            NETransparentProxyManager.loadAllFromPreferences { managers, error in
                if let manager = managers?.first {
                    (manager.connection as? NETunnelProviderSession)?.stopTunnel()
                    self.isProxyActive = false
                    self.logTimer?.invalidate()
                    self.logTimer = nil
                    self.tunnelSession = nil
                    self.addLog("INFO", "Proxy stopped and extension memory cleared")
                }
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
            
            try? session.sendProviderMessage(data) { _ in
                completion()
            }
        }
    }
    
    private func setupLogPolling(session: NETunnelProviderSession) {
        tunnelSession = session
        sendTrafficLoggingToExtension(isTrafficLoggingEnabled)
        updatePollingState()
        handshakeWithExtension(session: session)
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
                self.extensionProblem = nil
                self.addLog("INFO", "Extension handshake ok (protocol \(api), version \(version))")
            case .mismatch(let api):
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
        extensionProblem = "The system bound the tunnel to another, older ProxyBridge extension\(detail). That one does not understand this version's rules, so nothing is proxied. Take it out with the command below, then switch ProxyBridge on in System Settings > General > Login Items & Extensions > Network Extensions."
        extensionProblemAction = .copyRemoveCommand
        addLog("ERROR", "The extension that answered is not this build\(detail). The rules and the proxies never reach it, so no connection is proxied. Take the older extension out and approve this one.")
    }

    // The extension did not answer at all. The traffic is proxied, but the window
    // cannot show it, and the reason is the signature - not an extension that has
    // to be deleted. There is no command for that, so the notice has no button.
    private func reportExtensionUnreachable() {
        let signed = ExtensionDiagnosis.hasDeveloperSignature()
        extensionProblem = ExtensionDiagnosis.extensionUnreachableExplanation(hasDeveloperSignature: signed).joined(separator: " ")
        if signed {
            // A build with a team id is refused by nothing, so an extension that
            // does not answer is an extension that is not this build. That one
            // has to be taken out, and there is a command for it.
            extensionProblemAction = .copyRemoveCommand
            addLog("ERROR", "The extension does not answer over the provider channel. The tunnel is up, so the extension on the other end is not this build. Take the older extension out and approve this one.")
        } else {
            extensionProblemAction = .none
            addLog("ERROR", "The extension does not answer over the provider channel: this build is not signed by a developer, and macOS does not let it talk to its own system extension. The traffic is proxied (the rules went with the start of the tunnel), but this window cannot read the connection list back.")
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
                self.liveFlows = flows
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

    func sendProxyConfigsToExtension(session: NETunnelProviderSession) {
        let configsArray: [[String: Any]] = proxyConfigs.map { config in
            var dict: [String: Any] = [
                "id": config.id,
                "proxyType": config.type,
                "proxyHost": config.host,
                "proxyPort": config.port,
                "sendDomainToProxy": config.sendDomain
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
            addLog("ERROR", "Failed to encode proxy configs")
            return
        }
        try? session.sendProviderMessage(data) { [weak self] response in
            if let responseData = response,
               let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
               let status = json["status"] as? String, status == "ok" {
                DispatchQueue.main.async {
                    self?.addLog("INFO", "Proxy configs sent: \(self?.proxyConfigs.count ?? 0) config(s)")
                }
            }
        }
    }
    
    // The user pushed the notice away for this session. The problem stays in the
    // activity log, and Settings still has the way to act on it.
    func dismissExtensionProblem() {
        extensionProblem = nil
        extensionProblemAction = .none
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
        stopProxy()
    }
}

extension ProxyBridgeViewModel: OSSystemExtensionRequestDelegate {
    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        DispatchQueue.main.async {
            self.addLog("INFO", "Extension installed successfully")
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
            self.addLog("ERROR", "Extension failed: \(error.localizedDescription)")
            // The message on its own does not say what to do. An unsigned build has no
            // entitlements at all, and macOS will not install a system extension from
            // such an app, so say that plainly.
            if error.localizedDescription.lowercased().contains("entitlement") {
                self.addLog("ERROR", "macOS does not install the system extension from a build that is not signed. Use a signed build, or build from source: the build script signs the app for you.")
            }
        }
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        DispatchQueue.main.async {
            self.needsExtensionApproval = true
            self.addLog("INFO", "macOS wants you to approve ProxyBridge once. Open System Settings > General > Login Items & Extensions > Network Extensions (on macOS 26 and later: Network > VPN & Filters) and switch ProxyBridge on. Until that is done, no traffic can be proxied.")
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
