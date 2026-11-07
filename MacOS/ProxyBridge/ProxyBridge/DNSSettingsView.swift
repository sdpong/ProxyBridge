import SwiftUI

// The DNS policy window: who resolves a name, which names are excluded, which
// resolver answers, and whether the proxy server is the one that resolves.
//
// It is a window of its own and not a sheet, so it has to close itself. That is
// also why the two buttons at the bottom do what they say: Cancel throws the
// changes away and closes the window, Save writes them, hands them to the
// extension and closes the window.
//
// The window also shows what the DNS proxy is doing right now. Without that,
// a setting that changes nothing on screen looks like a setting that is broken.
struct DNSSettingsView: View {
    // the language of the app: the strings are read through it, so a change of
    // the language redraws the window
    @ObservedObject private var loc = LocalizationManager.shared
    @ObservedObject var viewModel: ProxyBridgeViewModel

    @State private var mode: DNSPolicySettings.Mode = .system
    @State private var excludedText = ""
    @State private var resolversText = ""
    @State private var autoDetect = true
    @State private var leakProtection = false
    @State private var status: DNSStatus?
    @State private var entryEnabled: Bool?
    @State private var savedNote: String?

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()

            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker(L10n.t("Resolution"), selection: $mode) {
                            ForEach(DNSPolicySettings.Mode.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        Text(mode.detail)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Divider()
                        Text(L10n.t("What the three settings mean"))
                            .font(.caption)
                            .fontWeight(.medium)
                        modeList
                    }
                    .padding(.vertical, 8)
                }

                Section {
                    Toggle(L10n.t("Leak protection (proxy server always resolves)"), isOn: $leakProtection)
                    Text(L10n.t("The proxy server is always given the host name, whatever its own setting says. The address this Mac resolved can then never be the address the proxy connects to. The query itself still goes to the resolver of this Mac, so this is not a way to hide the names that are looked up."))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.t("Excluded domains")).fontWeight(.medium)
                        Text(L10n.t("One per line. An excluded name is answered by the resolver of this Mac and never becomes a proxy destination. Use *.example.com for everything below a domain."))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextEditor(text: $excludedText)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(height: 80)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(Color.secondary.opacity(0.3))
                            )
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.t("Upstream resolvers")).fontWeight(.medium)
                        Text(L10n.t("One per line, for example 1.1.1.1 or 8.8.8.8:53. The first one that can be read answers every name that is not excluded."))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextEditor(text: $resolversText)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(height: 60)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(Color.secondary.opacity(0.3))
                            )
                    }
                    .padding(.vertical, 4)

                    Toggle(L10n.t("Detect the system resolver automatically"), isOn: $autoDetect)
                    Text(L10n.t("With this off and no resolver listed above, the resolver of this Mac answers. With this on, the resolver of this Mac is used when the list above is empty. It does not decide whether DNS is watched: the DNS proxy always takes the queries, so that the names of the addresses are known."))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        statusView
                    }
                    .padding(.vertical, 4)
                }
            }
            .formStyle(.grouped)

            Divider()
            footerButtons
        }
        .frame(minWidth: 660, idealWidth: 660, maxWidth: .infinity, minHeight: 660, idealHeight: 660, maxHeight: .infinity)
        // the window is reused when it is opened again, so the fields are filled
        // from the stored settings every time the window comes up
        .onAppear(perform: load)
        .onChange(of: viewModel.dnsSettingsOpenCount) { _ in load() }
    }

    private var headerView: some View {
        HStack {
            Image(systemName: "network")
                .font(.title2)
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.t("DNS Settings"))
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(L10n.f("Profile: %@", viewModel.activeProfile))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }

    // the three settings, and what each of them means
    private var modeList: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(DNSPolicySettings.Mode.allCases) { option in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: option == mode ? "largecircle.fill.circle" : "circle")
                        .foregroundColor(option == mode ? .accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(option.title)
                            .fontWeight(option == mode ? .semibold : .regular)
                        Text(option.serverGets)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    // what the DNS proxy is doing right now
    private var statusView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: statusIcon)
                    .foregroundColor(statusColor)
                Text(statusTitle)
                    .fontWeight(.medium)
                Spacer()
                Button(L10n.t("Refresh")) { refreshStatus() }
                    .buttonStyle(.link)
            }
            Text(statusDetail)
                .font(.caption)
                .foregroundColor(.secondary)
            if let entryEnabled, !entryEnabled {
                Text(L10n.t("The DNS proxy entry is off in the system. ProxyBridge writes it again while the tunnel runs, but the names of the addresses are unknown until then."))
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
    }

    private var statusIcon: String {
        guard let status else { return "questionmark.circle" }
        return status.running ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private var statusColor: Color {
        guard let status else { return .secondary }
        return status.running ? .green : .orange
    }

    private var statusTitle: String {
        guard let status else { return "The state of the DNS proxy is not known yet." }
        return status.running ? "The DNS proxy is running." : "The DNS proxy is not running."
    }

    private var statusDetail: String {
        guard let status else {
            return "ProxyBridge looks in the log of the system extension for it. The window shows it as soon as the extension has written something."
        }
        var text = "\(status.queries) queries, \(status.answers) answers, \(status.names) names known."
        if !status.lastName.isEmpty {
            text += " Last answer: \(status.lastName) -> \(status.lastAddresses)."
        }
        return text
    }

    private var footerButtons: some View {
        HStack(spacing: 12) {
            if let savedNote {
                Text(savedNote)
                    .font(.caption)
                    .foregroundColor(.green)
            }
            Spacer()
            Button(L10n.t("Cancel")) { cancel() }
                .keyboardShortcut(.cancelAction)
            Button(L10n.t("Save")) { save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    // fills the window with the settings that are stored right now
    private func load() {
        let policy = viewModel.storedDNSPolicy()
        mode = policy.mode
        excludedText = DNSPolicySettings.formatList(policy.excludedDomains)
        resolversText = DNSPolicySettings.formatList(policy.upstreamResolvers)
        autoDetect = policy.autoDetectUpstream
        leakProtection = policy.leakProtection
        refreshStatus()
    }

    // throws the changes away and closes the window
    private func cancel() {
        load()
        closeWindow()
    }

    // writes the settings, hands them to the extension and closes the window
    private func save() {
        var policy = viewModel.storedDNSPolicy()
        policy.mode = mode
        policy.excludedDomains = DNSPolicySettings.parseList(excludedText)
        policy.upstreamResolvers = DNSPolicySettings.parseList(resolversText)
        policy.autoDetectUpstream = autoDetect
        policy.leakProtection = leakProtection
        viewModel.updateDNSPolicy(policy)
        savedNote = "Saved: \(policy.summary)"
        // the note is there long enough to be read, then the window goes away
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { closeWindow() }
    }

    private func refreshStatus() {
        viewModel.readDNSStatus { status in
            DispatchQueue.main.async { self.status = status }
        }
        viewModel.readDNSProxyEntry { enabled in
            DispatchQueue.main.async { self.entryEnabled = enabled }
        }
    }

    // the window is a window of its own, so it closes itself
    private func closeWindow() {
        for window in NSApplication.shared.windows where window.title == "DNS Settings" {
            window.close()
            return
        }
    }
}
