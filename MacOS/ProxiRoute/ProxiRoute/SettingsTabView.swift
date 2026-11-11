import SwiftUI
import AppKit

// The settings of the app, in the window.
//
// The running mode, the routing options and the proxy server are here: they
// decide what the app does with the traffic. The things that are about the
// app itself - the language, the switches of the app, the system extension
// and the way to the windows with the rules - have a page of their own, the
// options tab.
//
// The reason is that a menu is a place for the things that are done, not for
// the things that are set. Everything here is a setting, and a setting that
// is three menus deep is a setting nobody changes.
struct SettingsTabView: View {
    // the language of the app: the strings are read through it, so a change of
    // the language redraws the window
    @ObservedObject private var loc = LocalizationManager.shared
    @ObservedObject var viewModel: ProxiRouteViewModel

    // The drafts of the forms. They are written into the app with the button
    // of their own card, so that a number that is typed does not reach the
    // extension on every key stroke.
    @State private var route = RouteSettings.load()
    @State private var localProxy = LocalProxySettings.load()

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                modeCard
                // the gateway mode has a card of its own: the switch that
                // turns it on, the helper that has to be there for it, and
                // the routing options that say where the traffic goes when
                // this machine is the gateway of the network. The other modes
                // use the defaults.
                if viewModel.runtimeMode == .gateway {
                    gatewayCard
                }
                // the proxy server is the service for the clients of the
                // network, so it is only of use in its own mode
                if viewModel.runtimeMode == .server {
                    serverCard
                }
                loggingCard
            }
            .padding(16)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - the running mode

    // The card says what the modes are: the traffic of this machine is taken
    // over in every one of them, and the mode says what is added on top of it
    // for the other terminals of the network.
    //
    // There is no row for the traffic of this machine any more: it is taken
    // over in every mode, so a row that says the same thing under every
    // option is noise. The line at the end of the row of the tabs says
    // whether it is running.
    private var modeCard: some View {
        SettingsCard(icon: "switch.2", title: L10n.t("Running Mode")) {
            Form {
                Section {
                    Picker(L10n.t("Running Mode"), selection: modeBinding) {
                        Text(L10n.t("Local")).tag(RuntimeMode.local)
                        Text(L10n.t("Gateway")).tag(RuntimeMode.gateway)
                        Text(L10n.t("Proxy Server")).tag(RuntimeMode.server)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    Text(modeDescription)
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    // The gateway mode is meant for the other terminals of
                    // the network. The card below says whether the helper of
                    // the gateway mode is there, and whether the gateway is
                    // on, so that the person is not left waiting for a
                    // traffic that never comes.
                    if viewModel.runtimeMode == .gateway {
                        Text(L10n.t("This machine is the gateway of the network: the other terminals reach it through the interface below, and their traffic goes out by the rules of the app."))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // The server is the only thing that is on in one mode and
                    // off in the others, so it is the only state a row is
                    // still worth here.
                    HStack {
                        Text(L10n.t("Proxy Server"))
                        Spacer()
                        Text(viewModel.localProxyRunning ? L10n.t("Running") : L10n.t("Not Running"))
                            .foregroundColor(viewModel.localProxyRunning ? .green : .secondary)
                    }
                } footer: {
                    Text(L10n.t("Every mode takes the traffic of this machine over. The gateway mode adds the gateway of the network, and the proxy server mode adds the server for the clients."))
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity)
        }
    }

    // What the mode means, in one line. The mode is the choice, and the
    // person has to know what the choice does before it is made.
    private var modeDescription: String {
        switch viewModel.runtimeMode {
        case .local:
            return L10n.t("The traffic of this machine goes through the proxy, and the rules decide where it goes. Nothing else is done here.")
        case .gateway:
            return L10n.t("The traffic of this machine goes through the proxy, and this machine is the gateway of the network: the traffic of the other terminals goes through it.")
        case .server:
            return L10n.t("The traffic of this machine goes through the proxy, and the proxy server waits for the clients of the network. The processor of the machine pays for both.")
        }
    }

    // The mode is applied right away: it decides what the app does, and a
    // setting that waits for a button would be a setting that is out of step
    // with what the app is doing.
    private var modeBinding: Binding<RuntimeMode> {
        Binding(
            get: { viewModel.runtimeMode },
            set: { viewModel.applyRuntimeMode($0) }
        )
    }

    // MARK: - the gateway

    // The gateway mode: the switch that turns it on, the interface the other
    // terminals reach this machine through, the helper that has to be there
    // for it, and the routing options that say where the traffic goes.
    //
    // The helper is a program of root that the app installs by itself, with
    // the password of an administrator. The card says when it is not there,
    // because without it the traffic of the network has nowhere to go, and
    // the reason has to be in words.
    private var gatewayCard: some View {
        SettingsCard(icon: "network", title: L10n.t("Gateway")) {
            Form {
                // The helper of the gateway mode is a program of root, and
                // putting it in place needs the password of an administrator.
                // The app asks macOS for that privilege, the way every other
                // installer does, so that the person does not have to type a
                // command in a terminal.
                //
                // It is the first thing in the card, because it is the thing a
                // person looks for: without the helper the gateway mode does
                // nothing at all, and the buttons that put it in place were
                // below the fold, where a person does not find them.
                Section {
                    HStack {
                        Text(L10n.t("Helper of the Gateway Mode"))
                        Spacer()
                        Text(helperStateText)
                            .foregroundColor(helperIsInstalled ? .green : .secondary)
                    }

                    HStack {
                        Button(L10n.t("Install")) {
                            viewModel.gateway.installHelper()
                        }
                        // the helper is already there: there is nothing to
                        // install, and the button says so
                        .disabled(helperIsInstalled || viewModel.gateway.isInstalling)

                        if helperIsInstalled {
                            Button(L10n.t("Uninstall")) {
                                viewModel.gateway.uninstallHelper()
                            }
                        }
                    }
                    .disabled(viewModel.gateway.isInstalling)

                    if viewModel.gateway.isInstalling {
                        Text(L10n.t("The password of an administrator is asked for. The installation waits for it."))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !viewModel.gateway.helperMessage.isEmpty {
                        Text(viewModel.gateway.helperMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } footer: {
                    Text(L10n.t("The helper is a program of root: it loads the rules of the packet filter, turns the forwarding of the machine on, and asks the kernel where a redirected connection was going. Installing it needs the password of an administrator; taking it out puts the machine back the way it was."))
                }

                Section {
                    Toggle(L10n.t("Turn the gateway on"), isOn: Binding(
                        get: { viewModel.gateway.isEnabled },
                        set: { viewModel.gateway.isEnabled = $0 }
                    ))
                    // The helper is the program of root that does the part of
                    // the gateway mode that needs root. Without it there is
                    // nobody to ask, so the switch is not offered.
                    .disabled(!viewModel.gateway.canTurnOn)

                    if !viewModel.gateway.canTurnOn {
                        Text(L10n.t("The helper of the gateway mode has to be installed before the gateway can be turned on."))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Picker(L10n.t("Interface"), selection: Binding(
                        get: { viewModel.gateway.interface },
                        set: { viewModel.gateway.interface = $0 }
                    )) {
                        Text(L10n.t("Choose")).tag("")
                        ForEach(gatewayInterfaces, id: \.name) { entry in
                            // the kind is said as well: "en0" says nothing to
                            // the person in front of the window, "en0 - Wi-Fi"
                            // says which network the other terminals reach
                            // this machine through
                            Text("\(entry.name) - \(gatewayKindLabel(entry.kind))").tag(entry.name)
                        }
                    }
                    // the network card is only of use when the gateway can be
                    // turned on at all
                    .disabled(!viewModel.gateway.canTurnOn)

                    HStack {
                        Text(L10n.t("Status"))
                        Spacer()
                        Text(viewModel.gateway.isRunning ? L10n.t("Running") : L10n.t("Not Running"))
                            .foregroundColor(viewModel.gateway.isRunning ? .green : .secondary)
                    }

                    // How much of the traffic of the network has gone through
                    // this machine. It is the one number that says whether
                    // the gateway mode does anything at all.
                    HStack {
                        Text(L10n.t("Connections Carried"))
                        Spacer()
                        Text("\(viewModel.gateway.carriedConnections)")
                            .foregroundColor(.secondary)
                    }

                    if !viewModel.gateway.status.isEmpty {
                        Text(viewModel.gateway.status)
                            .font(.caption)
                            .foregroundColor(viewModel.gateway.isRunning ? .secondary : .orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // What the rules cover for the traffic of the network.
                    //
                    // The rules are written for the traffic of this machine,
                    // and the traffic of the network is not that traffic: a
                    // client has no program, so a rule that names one is
                    // never about it. The card says so when the rules leave
                    // the traffic of the network uncovered, because a person
                    // who watches the dns of a phone go somewhere else should
                    // know that no rule said so.
                    if let notice = gatewayCoverageNotice {
                        Text(notice)
                            .font(.caption)
                            .foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // The dns of the clients.
                    //
                    // The gateway mode takes the dns of the clients over: the
                    // names they look up are learned from it, and a rule that
                    // names a host can then match their traffic. A client that
                    // asks the router of its own network for a name never
                    // comes through this machine, so the card says where the
                    // dns of the clients has to point.
                    if let notice = gatewayDNSNotice {
                        Text(notice)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } footer: {
                    Text(L10n.t("The other terminals of the network point at this machine as their gateway. Their traffic goes out by the rules of the app, the same rules as the traffic of this machine, except that a rule naming a program does not apply to them: they have no program."))
                }

                // The routing options: they say where the traffic goes when
                // this machine is the gateway of the network. They are the
                // sections of the form of the routing window, put in here so
                // that the gateway of the network has one place and not two.
                RouteSettingsSections(settings: $route, viewModel: viewModel).sections()
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity)
            .onAppear {
                // the helper may have been taken away while the window was
                // closed, so the card asks before it shows anything
                viewModel.gateway.refreshHelperState()
            }
            SettingsCardFooter {
                Button(L10n.t("Save")) {
                    viewModel.updateRouteSettings(route)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // The interfaces the other terminals could reach this machine through.
    private var gatewayInterfaces: [(name: String, kind: String)] {
        return InterfaceList.shared.entries.map { (name: $0.name, kind: $0.kind) }
    }

    // What the card says about the rules and the traffic of the network.
    //
    // It says nothing when the rules cover the traffic. It says something
    // when they do not, and the thing it says is the one that matters: the
    // datagrams of the clients are not covered by a rule, and the traffic of
    // the network is not covered at all.
    private var gatewayCoverageNotice: String? {
        let report = viewModel.gatewayCoverage
        return GatewayCoverage.noRulesNotice(report)
            ?? GatewayCoverage.udpNotice(report)
            ?? GatewayCoverage.proxyNotice(viewModel.gatewayGlobalProxy)
    }

    // What the card says about the dns of the clients.
    //
    // The names the clients look up are learned from the dns that goes
    // through this machine, and a rule that names a host can only match a
    // traffic that has a name. The card says where the dns of the clients
    // has to point, because a client that asks the router of its own network
    // for a name never comes through here.
    private var gatewayDNSNotice: String? {
        let name = viewModel.gateway.interface.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let address = LocalAddresses.address(ofInterface: name) ?? ""
        return L10n.f("The DNS of the clients is taken over: the names they look up are learned from it, so that the rules that name a host can match their traffic. Point the DNS of the clients at this machine (%@) or at a resolver outside their own network - a client that asks the router of its own network never comes through here.", address)
    }

    // What kind of network card a name is.
    private func gatewayKindLabel(_ kind: String) -> String {
        switch kind {
        case "wifi": return L10n.t("Wi-Fi")
        case "ethernet": return L10n.t("Wired")
        default: return L10n.t("Other")
        }
    }

    // Whether the helper of the gateway mode is on the machine.
    private var helperIsInstalled: Bool {
        return viewModel.gateway.helperState.isInstalled
    }

    // What the card says about the helper.
    //
    // A helper that is there but does not answer is a different thing from a
    // helper that is not there: the first one is broken, the second one is
    // not installed yet, and the person has to know which one it is.
    private var helperStateText: String {
        switch viewModel.gateway.helperState {
        case .notInstalled:
            return L10n.t("Not Installed")
        case .installed:
            return L10n.t("Installed, Not Running")
        case .running:
            return L10n.t("Installed")
        }
    }

    // MARK: - the proxy server

    private var serverCard: some View {
        SettingsCard(icon: "server.rack", title: L10n.t("Proxy Server")) {
            LocalProxyServerForm(settings: $localProxy, viewModel: viewModel)
            SettingsCardFooter {
                Button(L10n.t("Save")) {
                    viewModel.updateLocalProxySettings(localProxy)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - logging and dns

    private var loggingCard: some View {
        SettingsCard(icon: "text.alignleft", title: L10n.t("Logging and DNS")) {
            Form {
                Section {
                    Toggle(L10n.t("Enable Traffic Logging"), isOn: Binding(
                        get: { viewModel.isTrafficLoggingEnabled },
                        set: { _ in viewModel.toggleTrafficLogging() }
                    ))

                    Toggle(L10n.t("Enable DNS"), isOn: Binding(
                        get: { viewModel.isDNSEnabled },
                        set: { _ in viewModel.toggleDNS() }
                    ))

                    Text(L10n.t("The DNS proxy lets ProxiRoute learn which name belongs to which address. Host name rules and \"send hostname\" need it. Without it another program can use the one DNS proxy slot of macOS."))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity)
        }
    }
}
