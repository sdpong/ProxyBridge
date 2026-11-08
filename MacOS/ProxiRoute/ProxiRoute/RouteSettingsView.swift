import SwiftUI

// The switches that sit above the rules.
//
// Everything here changes the way the whole machine goes out, not the way one
// program goes out. The rules are in their own window.
struct RouteSettingsView: View {
    @ObservedObject private var loc = LocalizationManager.shared
    @ObservedObject var viewModel: ProxiRouteViewModel
    @Environment(\.dismiss) private var dismiss

    @StateObject private var interfaces = InterfaceList.shared
    @State private var settings = RouteSettings.load()

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            formView
            Divider()
            footerView
        }
        .frame(minWidth: 620, idealWidth: 620, maxWidth: .infinity, minHeight: 380, idealHeight: 420, maxHeight: .infinity)
    }

    private var headerView: some View {
        HStack {
            Image(systemName: "arrow.triangle.branch")
                .font(.title2)
                .foregroundColor(.accentColor)
            Text(L10n.t("Routing"))
                .font(.title2)
                .fontWeight(.semibold)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var formView: some View {
        Form {
            Section {
                Toggle(L10n.t("Global Mode"), isOn: $settings.globalMode)

                if settings.globalMode {
                    Picker(L10n.t("Everything Goes Through"), selection: $settings.globalProxyId) {
                        Text("DIRECT").tag("DIRECT")
                        ForEach(viewModel.proxyConfigs) { config in
                            Text(config.displayName).tag(config.id)
                        }
                    }
                    .disabled(viewModel.proxyConfigs.isEmpty)

                    Text(L10n.t("The rules are not looked at while the global mode is on."))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text(L10n.t("Where the Traffic Goes"))
            }

            Section {
                Picker(L10n.t("Outgoing Interface"), selection: $settings.outboundInterface) {
                    Text(L10n.t("Automatic")).tag("")
                    ForEach(interfaceChoices, id: \.self) { kind in
                        Text(interfaceLabel(kind)).tag(kind)
                    }
                }

                Text(L10n.t("The traffic to the proxy leaves through this interface. A Mac that is plugged in and also on a wireless network sends it the way you say here."))
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text(L10n.t("The Way Out"))
            }

            Section {
                Toggle(L10n.t("Send UDP Through a Proxy"), isOn: $settings.proxyUDP)

                Text(L10n.t("Only a SOCKS5 proxy can carry UDP. When this is off, UDP always goes out directly."))
                    .font(.caption)
                    .foregroundColor(.secondary)

                Divider()

                HStack {
                    Text(L10n.t("DNS Forwarding"))
                    Spacer()
                    Text(viewModel.isDNSEnabled ? L10n.t("On") : L10n.t("Off"))
                        .foregroundColor(.secondary)
                }

                Text(L10n.t("DNS forwarding is in the DNS settings. With it on, the answers are seen, and the rules can name a host name."))
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text(L10n.t("UDP and DNS"))
            }
        }
        .formStyle(.grouped)
    }

    private var footerView: some View {
        HStack {
            Spacer()
            Button(L10n.t("Cancel")) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button(L10n.t("Save")) {
                viewModel.updateRouteSettings(settings)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // The kinds of the interfaces that are of use right now. The loopback is
    // left out: binding the traffic to it means that the traffic goes nowhere.
    private var interfaceChoices: [String] {
        var seen: [String] = []
        for entry in interfaces.interfaces where !seen.contains(entry.kind) {
            seen.append(entry.kind)
        }
        return seen
    }

    private func interfaceLabel(_ kind: String) -> String {
        switch kind {
        case "wifi": return L10n.t("Wi-Fi")
        case "ethernet": return L10n.t("Wired")
        default: return L10n.t("Other")
        }
    }
}
