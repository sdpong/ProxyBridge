import SwiftUI

struct ProxySettingsView: View {
    // the language of the app: the strings are read through it, so a change of
    // the language redraws the window
    @ObservedObject private var loc = LocalizationManager.shared
    @ObservedObject var viewModel: ProxiRouteViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var showAddProxy = false
    @State private var editingConfig: ProxiRouteViewModel.ProxyConfig?
    @State private var deletingConfig: ProxiRouteViewModel.ProxyConfig?
    @State private var checkingConfig: ProxiRouteViewModel.ProxyConfig?
    @State private var affectedRulesCount = 0

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            listContent
            Divider()
            footerButtons
        }
        .frame(minWidth: 880, idealWidth: 880, maxWidth: .infinity, minHeight: 440, idealHeight: 480, maxHeight: .infinity)
        .alert(L10n.t("Delete Proxy?"), isPresented: Binding(
            get: { deletingConfig != nil },
            set: { if !$0 { deletingConfig = nil } }
        )) {
            Button(L10n.t("Delete"), role: .destructive) {
                if let c = deletingConfig { viewModel.removeProxyConfig(c) }
                deletingConfig = nil
            }
            Button(L10n.t("Cancel"), role: .cancel) { deletingConfig = nil }
        } message: {
            if affectedRulesCount > 0 {
                Text(L10n.f("%@ rule(s) use this proxy and will be set to Direct.", "\(affectedRulesCount)"))
            } else {
                Text(L10n.t("This proxy will be permanently removed."))
            }
        }
        .sheet(isPresented: $showAddProxy) {
            ProxyConfigEditorView(viewModel: viewModel, existing: nil)
        }
        .sheet(item: $editingConfig) { config in
            ProxyConfigEditorView(viewModel: viewModel, existing: config)
        }
        .sheet(item: $checkingConfig) { config in
            ProxyCheckerView(config: config)
        }
    }

    private var headerView: some View {
        HStack {
            Image(systemName: "network")
                .font(.title2)
                .foregroundColor(.accentColor)
            Text(L10n.t("Proxy Settings"))
                .font(.title2)
                .fontWeight(.semibold)
            Spacer()
            Button(action: { showAddProxy = true }) {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                    Text(L10n.t("Add"))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }

    @ViewBuilder
    private var listContent: some View {
        if viewModel.proxyConfigs.isEmpty {
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: "network.slash")
                    .font(.system(size: 48))
                    .foregroundColor(.gray)
                Text(L10n.t("No proxy servers configured"))
                    .font(.title3)
                    .foregroundColor(.gray)
                Text(L10n.t("Click 'Add' to configure your first proxy server"))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer()
        } else {
            Table(viewModel.proxyConfigs) {
                TableColumn(L10n.t("Name")) { config in
                    Text(config.name.isEmpty ? "=" : config.name)
                        .foregroundColor(config.name.isEmpty ? .secondary : .primary)
                }
                .width(140)

                TableColumn(L10n.t("Type")) { config in
                    Text(config.type.uppercased())
                        .foregroundColor(typeColor(config.type))
                        .fontWeight(.semibold)
                }
                .width(70)

                TableColumn(L10n.t("Server")) { config in
                    // build the string first, interpolating an Int into a Text
                    // literal would add a locale grouping separator (1,080)
                    Text(verbatim: "\(config.host):\(String(config.port))")
                        .fontDesign(.monospaced)
                }
                .width(min: 180, ideal: 220, max: .infinity)

                TableColumn(L10n.t("Auth")) { config in
                    if config.username != nil {
                        Image(systemName: "lock.fill").foregroundColor(.secondary)
                    } else {
                        Text("-").foregroundColor(.secondary)
                    }
                }
                .width(40)

                TableColumn(L10n.t("Test")) { config in
                    Button(action: { checkingConfig = config }) {
                        Label(L10n.t("Test"), systemImage: "bolt.horizontal")
                    }
                    .buttonStyle(.borderless)
                }
                .width(min: 60, ideal: 80)

                TableColumn("") { config in
                    HStack(spacing: 12) {
                        Button(action: { editingConfig = config }) {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                        .foregroundColor(.blue)
                        .help(L10n.t("Edit"))

                        Button(action: { confirmDelete(config) }) {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .foregroundColor(.red)
                        .help(L10n.t("Delete"))
                    }
                }
                .width(60)
            }
            .padding()
        }
    }

    private var footerButtons: some View {
        HStack {
            Spacer()
            Button(L10n.t("Done")) { dismiss() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func confirmDelete(_ config: ProxiRouteViewModel.ProxyConfig) {
        affectedRulesCount = viewModel.rulesUsingProxy(id: config.id)
        deletingConfig = config
    }

    private func typeColor(_ type: String) -> Color {
        type.lowercased() == "socks5" ? .cyan : .orange
    }
}

struct ProxyConfigEditorView: View {
    // the language of the app: the strings are read through it, so a change of
    // the language redraws the window
    @ObservedObject private var loc = LocalizationManager.shared
    @ObservedObject var viewModel: ProxiRouteViewModel
    var existing: ProxiRouteViewModel.ProxyConfig?
    @Environment(\.dismiss) private var dismiss

    @State private var configName = ""
    @State private var proxyType = "socks5"
    @State private var proxyHost = ""
    @State private var proxyPort = ""
    @State private var username = ""
    @State private var password = ""
    @State private var sendDomain = true
    @State private var sendAppId = false
    @State private var validationError = ""

    private let proxyTypes = ["http", "socks5", "socks4"]
    private var isSaveDisabled: Bool {
        proxyHost.isEmpty || proxyPort.isEmpty || !validationError.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "network")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                Text(existing == nil ? L10n.t("Add Proxy") : L10n.t("Edit Proxy"))
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            Form {
                Section {
                    formTextField(label: L10n.t("Name"), placeholder: L10n.t("Optional, e.g. Home SOCKS"), text: $configName)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text(L10n.t("Proxy Type")).fontWeight(.medium); Text("*").foregroundColor(.red) }
                        Picker(L10n.t("Select proxy type"), selection: $proxyType) {
                            ForEach(proxyTypes, id: \.self) { type in
                                Text(type.uppercased()).tag(type)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    .padding(.vertical, 8)

                    formTextField(label: L10n.t("Proxy IP/Domain"), placeholder: "127.0.0.1 or proxy.example.com", text: $proxyHost, required: true)
                        .onChange(of: proxyHost) { _ in validateInputs() }
                    formTextField(label: L10n.t("Proxy Port"), placeholder: "1080", text: $proxyPort, required: true)
                        .onChange(of: proxyPort) { _ in validateInputs() }
                    formTextField(label: L10n.t("Username"), placeholder: L10n.t("Leave empty if no auth"), text: $username)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.t("Password")).fontWeight(.medium)
                        SecureField(L10n.t("Leave empty if no auth"), text: $password)
                            .textFieldStyle(.roundedBorder)
                    }
                    .padding(.vertical, 8)

                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(L10n.t("Let proxy resolve DNS (send hostname)"), isOn: $sendDomain)
                        Text(L10n.t("On: the proxy gets the host name the app looked up. Off: it gets the IP address. Turn it off for a proxy that can't resolve the names your Mac can."))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(L10n.t("Host names are only sent when Enable DNS is on in the Proxy menu."))
                            .font(.caption)
                            .foregroundColor(viewModel.isDNSEnabled ? .secondary : .orange)
                    }
                    .padding(.vertical, 8)

                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(L10n.t("Send the application name to the proxy server"), isOn: $sendAppId)
                        Text(L10n.t("The proxy server is told which application the traffic comes from, so it can route by application. HTTP proxies get it in a header, SOCKS proxies in the user name field."))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(L10n.t("A SOCKS5 proxy that needs a user name of its own keeps it: there is only one user name field."))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(L10n.t("A rule that names no program says to the proxy that the traffic is ProxiRoute's own: the bundle id of the extension is the name it sees. A proxy that routes by program can then send that traffic its own way."))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 8)

                    if !validationError.isEmpty {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
                            Text(validationError).font(.caption).foregroundColor(.red)
                        }
                        .padding(.top, 4)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack(spacing: 12) {
                Spacer()
                Button(L10n.t("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.t("Save")) { save(); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaveDisabled)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
        }
        .frame(width: 500, height: 700)
        .onAppear {
            if let e = existing {
                configName = e.name
                proxyType = e.type
                proxyHost = e.host
                proxyPort = String(e.port)
                username = e.username ?? ""
                password = e.password ?? ""
                sendDomain = e.sendDomain
                sendAppId = e.sendAppId
            }
            validateInputs()
        }
    }

    @ViewBuilder
    private func formTextField(label: String, placeholder: String, text: Binding<String>, required: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label).fontWeight(.medium)
                if required { Text("*").foregroundColor(.red) }
            }
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
        }
        .padding(.vertical, 8)
    }

    private func validateInputs() {
        if !proxyHost.isEmpty {
            let validCharsIPv6 = CharacterSet(charactersIn: "0123456789abcdefABCDEF:")
            let isIPv6 = proxyHost.rangeOfCharacter(from: validCharsIPv6.inverted) == nil && proxyHost.contains(":")
            let ipv4Parts = proxyHost.split(separator: ".")
            let isIPv4 = ipv4Parts.count == 4 && ipv4Parts.allSatisfy { Int($0).map { $0 >= 0 && $0 <= 255 } ?? false }
            let domainPattern = "^([a-zA-Z0-9]([a-zA-Z0-9\\-]{0,61}[a-zA-Z0-9])?\\.)*[a-zA-Z0-9]([a-zA-Z0-9\\-]{0,61}[a-zA-Z0-9])?$"
            let isDomain = NSPredicate(format: "SELF MATCHES %@", domainPattern).evaluate(with: proxyHost) || proxyHost == "localhost"
            if !isIPv4 && !isIPv6 && !isDomain {
                validationError = L10n.t("Invalid proxy IP/domain")
                return
            }
        }
        if !proxyPort.isEmpty {
            if let port = Int(proxyPort) {
                if port < 1 || port > 65535 {
                    validationError = L10n.t("Port must be between 1 and 65535")
                    return
                }
            } else {
                validationError = L10n.t("Port must be a valid number")
                return
            }
        }
        validationError = ""
    }

    private func save() {
        guard let port = Int(proxyPort) else { return }
        let config = ProxiRouteViewModel.ProxyConfig(
            id: existing?.id ?? UUID().uuidString,
            name: configName.trimmingCharacters(in: .whitespaces),
            type: proxyType,
            host: proxyHost,
            port: port,
            username: username.isEmpty ? nil : username,
            password: password.isEmpty ? nil : password,
            sendDomain: sendDomain,
            sendAppId: sendAppId
        )
        if existing != nil {
            viewModel.updateProxyConfig(config)
        } else {
            viewModel.addProxyConfig(config)
        }
    }
}
