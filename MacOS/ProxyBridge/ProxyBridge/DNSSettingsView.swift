import SwiftUI

// The DNS policy window: who resolves a name, which names are excluded, which
// resolver answers, and whether the proxy server is the one that resolves.
struct DNSSettingsView: View {
    @ObservedObject var viewModel: ProxyBridgeViewModel

    @State private var mode: DNSPolicySettings.Mode = .system
    @State private var excludedText = ""
    @State private var resolversText = ""
    @State private var autoDetect = true
    @State private var leakProtection = false

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()

            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Resolution", selection: $mode) {
                            ForEach(DNSPolicySettings.Mode.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        Text(mode.detail)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 8)
                }

                Section {
                    Toggle("Leak protection (proxy server always resolves)", isOn: $leakProtection)
                    Text("The proxy server is always given the host name, whatever its own setting says. The address your Mac resolved can then never be the address the proxy connects to.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Excluded domains").fontWeight(.medium)
                        Text("One per line. An excluded name never becomes a proxy destination. Use *.example.com for everything below a domain.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextEditor(text: $excludedText)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(height: 90)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(Color.secondary.opacity(0.3))
                            )
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Upstream resolvers").fontWeight(.medium)
                        Text("One per line, for example 1.1.1.1 or 8.8.8.8:53. Leave empty to use the resolver the system hands out.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextEditor(text: $resolversText)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(height: 70)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(Color.secondary.opacity(0.3))
                            )
                    }
                    .padding(.vertical, 4)

                    Toggle("Detect the system resolver automatically", isOn: $autoDetect)
                    Text("With this off and no resolver listed above, ProxyBridge leaves DNS alone and macOS resolves it the normal way.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section {
                    HStack(spacing: 8) {
                        Image(systemName: viewModel.isDNSEnabled ? "info.circle" : "exclamationmark.triangle.fill")
                            .foregroundColor(viewModel.isDNSEnabled ? .secondary : .orange)
                        Text(viewModel.isDNSEnabled
                             ? "The system DNS proxy is on, so this policy is in effect."
                             : "Enable DNS is off in the Proxy menu, so this policy has no effect.")
                            .font(.caption)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            footerButtons
        }
        .frame(minWidth: 620, idealWidth: 620, maxWidth: .infinity, minHeight: 560, idealHeight: 560, maxHeight: .infinity)
        .onAppear(perform: loadFromViewModel)
    }

    private var headerView: some View {
        HStack {
            Image(systemName: "network")
                .font(.title2)
                .foregroundColor(.accentColor)
            Text("DNS Settings")
                .font(.title2)
                .fontWeight(.semibold)
            Spacer()
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var footerButtons: some View {
        HStack(spacing: 12) {
            Spacer()
            Button("Cancel") { loadFromViewModel() }
                .keyboardShortcut(.cancelAction)
            Button("Save") { save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private func loadFromViewModel() {
        let policy = viewModel.dnsPolicy
        mode = policy.mode
        excludedText = DNSPolicySettings.formatList(policy.excludedDomains)
        resolversText = DNSPolicySettings.formatList(policy.upstreamResolvers)
        autoDetect = policy.autoDetectUpstream
        leakProtection = policy.leakProtection
    }

    private func save() {
        var policy = viewModel.dnsPolicy
        policy.mode = mode
        policy.excludedDomains = DNSPolicySettings.parseList(excludedText)
        policy.upstreamResolvers = DNSPolicySettings.parseList(resolversText)
        policy.autoDetectUpstream = autoDetect
        policy.leakProtection = leakProtection
        viewModel.updateDNSPolicy(policy)
        loadFromViewModel()
    }
}
