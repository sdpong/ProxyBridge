import SwiftUI
import AppKit

// The options of the app itself.
//
// The language, the switches of the app, the system extension and the way to
// the windows that hold the tables. None of them changes with the running
// mode, and none of them has anything to do with the traffic: they are about
// the app, not about the network.
//
// They used to sit at the bottom of the settings, under the running mode and
// the routes. There they looked like part of the settings of the traffic, and
// the person who wanted to change the language had to walk past the routes
// to reach it. Now they have a page of their own, after the settings.
struct OptionsTabView: View {
    // the language of the app: the strings are read through it, so a change of
    // the language redraws the window
    @ObservedObject private var loc = LocalizationManager.shared

    // the switches of the app itself
    @AppStorage("closeToMenuBar") private var closeToMenuBar = false
    @AppStorage("keepProxyRunningInBackground") private var keepProxyRunningInBackground = true
    // whether macOS should start the app at the login, before the browsers
    @State private var runAtStartup = LoginItem.isEnabled
    // what the last change of that switch did, in words
    @State private var launchOrderNote = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                languageCard
                applicationCard
                extensionCard
                rulesCard
            }
            .padding(16)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - the language

    private var languageCard: some View {
        SettingsCard(icon: "globe", title: L10n.t("Language")) {
            Form {
                Section {
                    Picker(L10n.t("Language"), selection: languageBinding) {
                        ForEach(L10n.Language.allCases) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                    .labelsHidden()

                    Text(L10n.t("The menus that macOS draws itself (Window, Help) follow the language that is chosen here."))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity)
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
        SettingsCard(icon: "app.badge", title: L10n.t("Application")) {
            Form {
                Section {
                    Toggle(L10n.t("Close to Menu Bar"), isOn: $closeToMenuBar)

                    Toggle(L10n.t("Keep Proxy Running in Background"), isOn: $keepProxyRunningInBackground)

                    Toggle(L10n.t("Start ProxiRoute at the login"), isOn: Binding(
                        get: { runAtStartup },
                        set: {
                            runAtStartup = $0
                            launchOrderNote = LoginItem.setEnabled($0)
                        }
                    ))

                    if !launchOrderNote.isEmpty {
                        Text(launchOrderNote)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.t("Closing the window does not stop the proxy. The app stays in the background and the tunnel keeps running until it is stopped here or the app is quit."))
                        Text(L10n.t("macOS starts all the login items at the same moment, so the order cannot be set in the system settings. With this switch on, ProxiRoute is one of the login items: macOS starts it in the wave of the login - the wave of the browsers and the other apps that use the network - and the launch agent starts it again when it is not there. The traffic of the machine is taken over as soon as the network of the machine is there and the proxy on this machine - Clash Meta, for example - answers on its port."))
                    }
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - the system extension

    private var extensionCard: some View {
        SettingsCard(icon: "puzzlepiece.extension", title: L10n.t("System Extension")) {
            Form {
                Section {
                    Button(L10n.t("Approve ProxiRoute in System Settings...")) {
                        NSApp.sendAction(#selector(AppDelegate.openSystemSettingsForExtension), to: nil, from: nil)
                    }

                    Button(L10n.t("Take Out Older ProxiRoute Extensions...")) {
                        NSApp.sendAction(#selector(AppDelegate.takeOutOlderExtensions), to: nil, from: nil)
                    }
                } footer: {
                    Text(L10n.t("macOS asks for the approval of the system extension once. Until it is given, no traffic can be proxied."))
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - the rules and the tables

    // The rules, the proxy list, the chains and the DNS settings are tables
    // and a table of this size does not belong in a tab of the main window.
    // They keep their own windows, and this card is the way to them.
    //
    // The card was called "More Windows" before. That name said where the
    // things were and not what they were: the windows are the way to the
    // rules, and the rules are what the card is about.
    private var rulesCard: some View {
        SettingsCard(icon: "list.bullet.rectangle", title: L10n.t("Rule Setup")) {
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
                } footer: {
                    Text(L10n.t("The rules say which program goes through which proxy. They live in their own windows, because they are tables."))
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity)
        }
    }
}
