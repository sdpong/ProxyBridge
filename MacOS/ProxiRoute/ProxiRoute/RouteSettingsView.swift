import SwiftUI

// The switches that sit above the rules.
//
// Everything here changes the way the whole machine goes out, not the way one
// program goes out. The rules are in their own window.
struct RouteSettingsView: View {
    @ObservedObject private var loc = LocalizationManager.shared
    @ObservedObject var viewModel: ProxiRouteViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var settings = RouteSettings.load()

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            RouteSettingsForm(settings: $settings, viewModel: viewModel)
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
            Text(L10n.t("Gateway"))
                .font(.title2)
                .fontWeight(.semibold)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
}

// The form of the routing options.
//
// It is a form of its own and not a part of a bigger one, so that it can sit
// in the settings of the window as well as in the window of its own. The
// settings it works on are handed in, and whoever owns them decides when they
// are written.
struct RouteSettingsForm: View {
    @ObservedObject private var loc = LocalizationManager.shared
    @Binding var settings: RouteSettings
    @ObservedObject var viewModel: ProxiRouteViewModel

    var body: some View {
        Form {
            RouteSettingsSections(settings: $settings, viewModel: viewModel).sections()
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity)
    }
}

// The sections of the routing options.
//
// They are a piece of code of their own, and not a form, because they have to
// sit in two forms: the form of the window of their own, and the form of the
// card of the gateway mode. A form inside a form is a form the system does
// not like, so the sections are handed to the form that wants them and the
// form decides what they look like.
struct RouteSettingsSections: View {
    @ObservedObject private var loc = LocalizationManager.shared
    @Binding var settings: RouteSettings
    @ObservedObject var viewModel: ProxiRouteViewModel

    @StateObject private var interfaces = InterfaceList.shared

    // The body is the sections as well: the form that wants them asks for
    // them by name, so that they are its own children and not a view inside
    // a cell.
    var body: some View {
        sections()
    }

    // The sections themselves.
    @ViewBuilder
    func sections() -> some View {
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

                Text(L10n.t("The traffic that no rule names goes through this proxy. A rule that names a program still decides."))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text(L10n.t("The Way Out"))
        }

        Section {
            Toggle(L10n.t("Send UDP Through a Proxy"), isOn: $settings.proxyUDP)

            Text(L10n.t("Only a SOCKS5 proxy can carry UDP. When this is off, UDP always goes out directly."))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(L10n.t("Keep Local Traffic Local"), isOn: $settings.localNetworkDirect)

            Text(L10n.t("The addresses of this network and of this machine go out directly. A proxy on the internet cannot answer for a server here, and a program that asks the nameserver of your router would wait for an answer that never comes."))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text(L10n.t("DNS Forwarding"))
                Spacer()
                Text(viewModel.isDNSEnabled ? L10n.t("On") : L10n.t("Off"))
                    .foregroundColor(.secondary)
            }

            Text(L10n.t("DNS forwarding is in the DNS settings. With it on, the answers are seen, and the rules can name a host name."))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text(L10n.t("UDP and DNS"))
        }
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
