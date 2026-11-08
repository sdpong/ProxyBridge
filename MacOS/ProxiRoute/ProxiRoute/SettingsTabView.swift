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
                // the routing options say where the traffic of this machine
                // goes, and it is taken over in every mode
                routeCard
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
                    // the network. The forwarding of them is not there yet,
                    // and the card says so instead of letting the person
                    // wait for a traffic that never comes.
                    if viewModel.runtimeMode == .gateway {
                        Text(L10n.t("Today only the traffic of this machine is taken over. The forwarding of the other terminals of the network is not there yet."))
                            .font(.caption)
                            .foregroundColor(.orange)
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

    // MARK: - the routing options

    private var routeCard: some View {
        SettingsCard(icon: "arrow.triangle.branch", title: L10n.t("Routing")) {
            RouteSettingsForm(settings: $route, viewModel: viewModel)
            SettingsCardFooter {
                Button(L10n.t("Save")) {
                    viewModel.updateRouteSettings(route)
                }
                .keyboardShortcut(.defaultAction)
            }
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
