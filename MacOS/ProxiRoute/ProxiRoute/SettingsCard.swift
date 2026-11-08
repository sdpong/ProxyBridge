import SwiftUI
import AppKit

// One card of the settings. The title says what is in it, so that a
// long page can be read without reading all of it.
//
// The card is shared by the two pages that hold the settings: the page that
// says what the app is doing (the settings tab) and the page that says how
// the app itself is set up (the options tab). They look the same, so they
// are the same piece of code.
struct SettingsCard<Content: View>: View {
    let icon: String
    let title: String
    private let content: () -> Content

    init(icon: String, title: String, @ViewBuilder content: @escaping () -> Content) {
        self.icon = icon
        self.title = title
        self.content = content
    }

    var body: some View {
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
        .frame(maxWidth: .infinity)
        .background(Color(NSColor.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.25)))
    }
}

// The row of buttons under a card.
struct SettingsCardFooter<Content: View>: View {
    private let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        HStack {
            Spacer()
            content()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor))
    }
}
