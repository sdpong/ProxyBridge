import SwiftUI

// The proxy server that runs inside ProxiRoute.
//
// The other half of what the app does: the extension sends the traffic of
// this machine out, and this server lets the other machines of the network
// send their traffic out through this one.
struct LocalProxyServerView: View {
    @ObservedObject private var loc = LocalizationManager.shared
    @ObservedObject var viewModel: ProxiRouteViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var settings = LocalProxySettings.load()

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            LocalProxyServerForm(settings: $settings, viewModel: viewModel)
            Divider()
            footerView
        }
        .frame(minWidth: 640, idealWidth: 640, maxWidth: .infinity, minHeight: 460, idealHeight: 520, maxHeight: .infinity)
    }

    private var headerView: some View {
        HStack {
            Image(systemName: "server.rack")
                .font(.title2)
                .foregroundColor(.accentColor)
            Text(L10n.t("Proxy Server"))
                .font(.title2)
                .fontWeight(.semibold)
            Spacer()
            if viewModel.localProxyRunning {
                Text(L10n.t("Running"))
                    .foregroundColor(.green)
            }
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
                viewModel.updateLocalProxySettings(settings)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// The form of the proxy server.
//
// Whether the server listens is not decided here. The running mode decides
// it: the gateway mode and the proxy server cannot be on at the same time, and
// the mode is the one switch. So the form only says what the server would do,
// and the state line says what it does now.
struct LocalProxyServerForm: View {
    @ObservedObject private var loc = LocalizationManager.shared
    @Binding var settings: LocalProxySettings
    @ObservedObject var viewModel: ProxiRouteViewModel

    @State private var addresses = LocalAddresses.all()

    var body: some View {
        Form {
            Section {
                HStack {
                    Text(L10n.t("State"))
                    Spacer()
                    if viewModel.localProxyRunning {
                        Text(L10n.t("Running"))
                            .foregroundColor(.green)
                    } else {
                        Text(L10n.t("Not Running"))
                            .foregroundColor(.secondary)
                    }
                }

                if viewModel.runtimeMode != .server {
                    Text(L10n.t("The server listens when the running mode is Proxy Server. The gateway mode and the proxy server cannot be on at the same time."))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Picker(L10n.t("Speaks"), selection: $settings.protocolMode) {
                    Text("SOCKS5").tag(LocalProxySettings.Mode.socks5)
                    Text("HTTP").tag(LocalProxySettings.Mode.http)
                    Text(L10n.t("SOCKS5 and HTTP")).tag(LocalProxySettings.Mode.both)
                }

                Toggle(L10n.t("Carry UDP"), isOn: $settings.udpEnabled)
                    .disabled(!settings.protocolMode.speaksSOCKS5)
            } header: {
                Text(L10n.t("The Server"))
            } footer: {
                Text(L10n.t("UDP needs a SOCKS5 association, so it needs SOCKS5. The server has no password: everyone who can reach the port can use it."))
            }

            Section {
                Picker(L10n.t("Listen Address"), selection: $settings.listenAddress) {
                    Text(L10n.t("Every Address")).tag("")
                    ForEach(addresses) { entry in
                        Text("\(entry.address) (\(entry.name))").tag(entry.address)
                    }
                }

                Picker(L10n.t("Listen Interface"), selection: $settings.listenInterface) {
                    Text(L10n.t("Every Interface")).tag("")
                    Text(L10n.t("Wi-Fi")).tag("wifi")
                    Text(L10n.t("Wired")).tag("ethernet")
                }

                HStack {
                    Text(L10n.t("Port"))
                    Spacer()
                    TextField("8888", value: $settings.port, format: .number)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                }
            } header: {
                Text(L10n.t("Where It Listens"))
            } footer: {
                Text(L10n.t("A port that another program is using is reported with the name of that program."))
            }

            Section {
                Picker(L10n.t("The Traffic Goes"), selection: upstreamBinding) {
                    Text(L10n.t("Straight Out")).tag("direct")
                    Text(L10n.t("By the Rules")).tag("rules")
                    ForEach(viewModel.proxyConfigs) { config in
                        Text(config.displayName).tag("proxy:\(config.id)")
                    }
                }
            } header: {
                Text(L10n.t("The Way Out"))
            } footer: {
                Text(L10n.t("By the rules: a client on the network has no program, so only the rules that name a host or a port can match."))
            }

            Section {
                HStack {
                    Text(L10n.t("Most Connections"))
                    Spacer()
                    TextField("64", value: $settings.maxConnections, format: .number)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                }

                HStack {
                    Text(L10n.t("Close Quiet Connections After"))
                    Spacer()
                    TextField("300", value: $settings.idleTimeout, format: .number)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                    Text(L10n.t("seconds"))
                        .foregroundColor(.secondary)
                }
            } header: {
                Text(L10n.t("Limits"))
            } footer: {
                Text(L10n.t("A connection that carries nothing for that many seconds is closed, so a client that goes away does not stay in the list."))
            }

            if !viewModel.localProxyStatus.isEmpty {
                Section {
                    Text(viewModel.localProxyStatus)
                        .font(.callout)
                        .foregroundColor(viewModel.localProxyRunning ? .secondary : .red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity)
    }

    // the upstream is a picker of three kinds, so it is kept in one string
    private var upstreamBinding: Binding<String> {
        Binding(
            get: {
                switch settings.upstream {
                case .direct: return "direct"
                case .rules: return "rules"
                case .proxy(let id): return "proxy:\(id)"
                }
            },
            set: { value in
                if value == "direct" {
                    settings.upstream = .direct
                } else if value == "rules" {
                    settings.upstream = .rules
                } else if value.hasPrefix("proxy:") {
                    settings.upstream = .proxy(String(value.dropFirst("proxy:".count)))
                }
            }
        )
    }
}
