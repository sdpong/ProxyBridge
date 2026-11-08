import SwiftUI

struct AboutView: View {
    // the language of the app: the strings are read through it, so a change of
    // the language redraws the window
    @ObservedObject private var loc = LocalizationManager.shared
    @Environment(\.dismiss) var dismiss

    // read from the bundle so the About window always shows the built version
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("ProxiRoute")
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.accentColor)

            Text(verbatim: L10n.f("Version %@", appVersion))
                .font(.system(size: 14))
                .foregroundColor(.secondary)

            Text(L10n.t("Universal proxy client for macOS applications"))
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 8)

            Text(L10n.t("Author: Sourav Kalal / InterceptSuite"))
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .padding(.top, 4)

            VStack(spacing: 12) {
                HStack {
                    Text(L10n.t("Website:"))
                        .foregroundColor(.secondary)
                    Link("interceptsuite.com", destination: URL(string: "https://interceptsuite.com")!)
                        .foregroundColor(.accentColor)
                }

                HStack {
                    Text(L10n.t("GitHub:"))
                        .foregroundColor(.secondary)
                    Link("github.com/sdpong/ProxyBridge", destination: URL(string: "https://github.com/sdpong/ProxyBridge")!)
                        .foregroundColor(.accentColor)
                }
            }
            .font(.system(size: 13))

            Text(L10n.t("License: MIT"))
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .padding(.top, 8)

            Button(L10n.t("Close")) {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .padding(.top, 12)
        }
        .padding(32)
        .frame(width: 400, height: 350)
    }
}
