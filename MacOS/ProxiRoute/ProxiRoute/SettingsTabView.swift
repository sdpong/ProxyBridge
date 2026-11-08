import SwiftUI
import AppKit

// The settings of the app, in the window.
//
// Everything that used to live in the menus of the menu bar is here: the
// running mode, the routing options, the proxy server, the language and the
// switches of the app itself. The menu bar keeps what belongs to the
// documents - the profiles - and the help.
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

    // the switches of the app itself
    @AppStorage("closeToMenuBar") private var closeToMenuBar = false
    @AppStorage("keepProxyRunningInBackground") private var keepProxyRunningInBackground = true
    @State private var runAtStartup = LoginItem.isEnabled

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                modeCard
                // the routing options and the proxy server are two halves of
                // the same choice, so only the one that is in use is shown
                if viewModel.runtimeMode == .route {
                    routeCard
                }
                if viewModel.runtimeMode == .server {
                    serverCard
                }
                loggingCard
                languageCard
                applicationCard
                extensionCard
                windowsCard
            }
            .padding(16)
        }
    }

    // MARK: - the running mode

    private var modeCard: some View {
        card(icon: "switch.2", title: L10n.t("Running Mode")) {
            Form {
                Section {
                    Picker(L10n.t("Running Mode"), selection: modeBinding) {
                        Text(L10n.t("Do Not Take Over")).tag(RuntimeMode.off)
                        Text(L10n.t("Route Mode")).tag(RuntimeMode.route)
                        Text(L10n.t("Proxy Server")).tag(RuntimeMode.server)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    Text(modeDescription)
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider()

                    HStack {
                        Text(L10n.t("The Traffic of This Machine"))
                        Spacer()
                        Text(viewModel.isProxyActive ? L10n.t("Proxied") : L10n.t("Not Proxied"))
                            .foregroundColor(viewModel.isProxyActive ? .green : .secondary)
                    }

                    HStack {
                        Text(L10n.t("Proxy Server"))
                        Spacer()
                        Text(viewModel.localProxyRunning ? L10n.t("Running") : L10n.t("Not Running"))
                            .foregroundColor(viewModel.localProxyRunning ? .green : .secondary)
                    }
                } header: {
                    Text(L10n.t("Running Mode"))
                } footer: {
                    Text(L10n.t("The route mode and the proxy server cannot be on at the same time. Both of them make this machine work, and the processor pays for both."))
                }
            }
            .formStyle(.grouped)
        }
    }

    // What the mode means, in one line. The mode is the choice, and the
    // person has to know what the choice does before it is made.
    private var modeDescription: String {
        switch viewModel.runtimeMode {
        case .off:
            return L10n.t("Nothing is taken over. The extension is stopped and no port is open, so this machine costs nothing.")
        case .route:
            return L10n.t("The traffic of this machine goes out through the extension. The rules decide, and the global mode is the answer for the traffic no rule names.")
        case .server:
            return L10n.t("The proxy server waits for the clients of the network. The traffic of this machine is left alone, so this machine does not pay for it.")
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
        card(icon: "arrow.triangle.branch", title: L10n.t("Routing")) {
            RouteSettingsForm(settings: $route, viewModel: viewModel)
            cardFooter {
                Button(L10n.t("Save")) {
                    viewModel.updateRouteSettings(route)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - the proxy server

    private var serverCard: some View {
        card(icon: "server.rack", title: L10n.t("Proxy Server")) {
            LocalProxyServerForm(settings: $localProxy, viewModel: viewModel)
            cardFooter {
                Button(L10n.t("Save")) {
                    viewModel.updateLocalProxySettings(localProxy)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - logging and dns

    private var loggingCard: some View {
        card(icon: "text.alignleft", title: L10n.t("Logging and DNS")) {
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
                } header: {
                    Text(L10n.t("Logging and DNS"))
                }
            }
            .formStyle(.grouped)
        }
    }

    // MARK: - the language

    private var languageCard: some View {
        card(icon: "globe", title: L10n.t("Language")) {
            Form {
                Section {
                    Picker(L10n.t("Language"), selection: languageBinding) {
                        ForEach(L10n.Language.allCases) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                    .labelsHidden()

                    Text(L10n.t("The menus macOS draws itself (Edit, Window, Help) change to the new language the next time ProxiRoute starts."))
                        .font(.caption)
                        .foregroundColor(.secondary)
                } header: {
                    Text(L10n.t("Language"))
                }
            }
            .formStyle(.grouped)
        }
    }

    private var languageBinding: Binding<L10n.Language> {
        Binding(
            get: { LocalizationManager.shared.language },
            set: { LocalizationManager.shared.language = $0 }
        )
    }

    // MARK: - the app itself

    private var applicationCard: some View {
        card(icon: "app.badge", title: L10n.t("Application")) {
            Form {
                Section {
                    Toggle(L10n.t("Close to Menu Bar"), isOn: $closeToMenuBar)

                    Toggle(L10n.t("Keep Proxy Running in Background"), isOn: $keepProxyRunningInBackground)

                    Toggle(L10n.t("Run at Startup"), isOn: Binding(
                        get: { runAtStartup },
                        set: {
                            runAtStartup = $0
                            LoginItem.setEnabled($0)
                        }
                    ))
                } header: {
                    Text(L10n.t("Application"))
                } footer: {
                    Text(L10n.t("Closing the window does not stop the proxy. The app stays in the background and the tunnel keeps running until it is stopped here or the app is quit."))
                }
            }
            .formStyle(.grouped)
        }
    }

    // MARK: - the system extension

    private var extensionCard: some View {
        card(icon: "puzzlepiece.extension", title: L10n.t("System Extension")) {
            Form {
                Section {
                    Button(L10n.t("Approve ProxiRoute in System Settings...")) {
                        NSApp.sendAction(#selector(AppDelegate.openSystemSettingsForExtension), to: nil, from: nil)
                    }

                    Button(L10n.t("Take Out Older ProxiRoute Extensions...")) {
                        NSApp.sendAction(#selector(AppDelegate.takeOutOlderExtensions), to: nil, from: nil)
                    }
                } header: {
                    Text(L10n.t("System Extension"))
                } footer: {
                    Text(L10n.t("macOS asks for the approval of the system extension once. Until it is given, no traffic can be proxied."))
                }
            }
            .formStyle(.grouped)
        }
    }

    // MARK: - the windows that stay windows

    // The rules, the proxy list, the chains and the DNS settings are tables
    // and a table of this size does not belong in a tab of the main window.
    // They keep their own windows, and this card is the way to them.
    private var windowsCard: some View {
        card(icon: "macwindow", title: L10n.t("More Windows")) {
            Form {
                Section {
                    HStack {
                        Button(L10n.t("Proxy Settings...")) {
                            NSApp.sendAction(#selector(AppDelegate.openProxySettings), to: nil, from: nil)
                        }
                        Button(L10n.t("Proxy Rules...")) {
                            NSApp.sendAction(#selector(AppDelegate.openProxyRules), to: nil, from: nil)
                        }
                    }

                    HStack {
                        Button(L10n.t("Proxy Chains...")) {
                            NSApp.sendAction(#selector(AppDelegate.openProxyChains), to: nil, from: nil)
                        }
                        Button(L10n.t("DNS Settings...")) {
                            NSApp.sendAction(#selector(AppDelegate.openDNSSettings), to: nil, from: nil)
                        }
                    }
                } header: {
                    Text(L10n.t("More Windows"))
                }
            }
            .formStyle(.grouped)
        }
    }

    // MARK: - the pieces of the layout

    // One card of the settings. The title says what is in it, so that a
    // long page can be read without reading all of it.
    private func card<Content: View>(icon: String, title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundColor(.accentColor)
                Text(title)
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            content()
        }
        .background(Color(NSColor.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.25)))
    }

    // The row of buttons under a card.
    private func cardFooter<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack {
            Spacer()
            content()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor))
    }
}
