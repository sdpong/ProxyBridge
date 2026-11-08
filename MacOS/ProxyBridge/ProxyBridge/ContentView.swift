import SwiftUI
import AppKit

struct ContentView: View {
    // the language of the app: the strings are read through it, so a change of
    // the language redraws the window
    @ObservedObject private var loc = LocalizationManager.shared
    @ObservedObject var viewModel: ProxyBridgeViewModel
    @State private var selectedTab = 0
    @State private var activitySearchText = ""
    // whether the long form of the notice is shown
    @State private var showNoticeDetails = false

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            noticeBanner
            tabSelector
            Divider()
            contentView
        }
        .frame(minWidth: 800, minHeight: 600)
    }
    
    // A notice the user has to act on: the system extension still waits for the
    // one-time approval, or the system bound the tunnel to an older extension.
    // It is a banner and not a dialog: a dialog on every launch is worse than the
    // problem it describes.
    @ViewBuilder
    private var noticeBanner: some View {
        if let problem = viewModel.extensionProblem {
            // The button depends on the problem: only a problem that a command
            // can fix offers one. The extension that does not answer at all is
            // fixed by a signature, and a command in a terminal would be a lie.
            switch viewModel.extensionProblemAction {
            case .copyRemoveCommand:
                noticeBar(
                    icon: "exclamationmark.triangle.fill",
                    text: problem,
                    actionTitle: L10n.t("Copy the command"),
                    action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(ExtensionDiagnosis.removeOldExtensionsCommand, forType: .string)
                    },
                    dismiss: { viewModel.dismissExtensionProblem() }
                )
            case .none:
                noticeBar(
                    icon: "exclamationmark.triangle.fill",
                    text: problem,
                    details: viewModel.extensionProblemDetails,
                    actionTitle: nil,
                    action: {},
                    dismiss: { viewModel.dismissExtensionProblem() }
                )
            }
        } else if viewModel.needsExtensionApproval {
            noticeBar(
                icon: "lock.shield.fill",
                text: "macOS has to approve ProxyBridge once, and until it does no traffic can be proxied. Look in System Settings > General > Login Items & Extensions > Network Extensions (on macOS 26 and later: Network > VPN & Filters) and switch ProxyBridge on. If ProxyBridge is not listed there, this build did not pass the system's signature check and needs a build signed with a Developer ID.",
                actionTitle: "Open System Settings",
                action: openSystemSettings,
                dismiss: { viewModel.dismissExtensionProblem() }
            )
        }
    }

    // The notice can be pushed away for this session. The problem stays in the activity
    // log, and the menu has the way to act on it, so hiding it does not hide it for good.
    // actionTitle is optional: a notice that explains a problem nobody can fix
    // with a command has no button to offer.
    //
    // details is optional too: a notice that is a standing condition says what it
    // is in one line and keeps the long form one click away. Five lines of text
    // about something that is true on every launch is a third of the window.
    private func noticeBar(icon: String, text: String, details: String? = nil, actionTitle: String?, action: @escaping () -> Void, dismiss: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: icon)
                    .foregroundColor(Color.orange)
                Text(text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if details != nil {
                    Button(showNoticeDetails ? L10n.t("Hide details") : L10n.t("Details")) {
                        showNoticeDetails.toggle()
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(Color.orange)
                }
                if let actionTitle = actionTitle {
                    Button(actionTitle, action: action)
                }
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .foregroundColor(Color.orange)
                }
                .buttonStyle(.plain)
                .help(L10n.t("Hide this notice for now"))
            }
            if let details = details, showNoticeDetails {
                Text(details)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 26)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }
    
    private func openSystemSettings() {
        // the pane with the network extension switches (macOS 13 and later keep them
        // inside Login Items & Extensions)
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    private var tabSelector: some View {
        HStack(spacing: 0) {
            TabButton(title: L10n.t("Statistics"), isSelected: selectedTab == 0) {
                selectedTab = 0
            }
            TabButton(title: L10n.t("Live Connections"), isSelected: selectedTab == 1) {
                selectedTab = 1
            }
            TabButton(title: L10n.t("Activity Logs"), isSelected: selectedTab == 2) {
                selectedTab = 2
            }
            Spacer()
        }
        .frame(height: 40)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var contentView: some View {
        Group {
            switch selectedTab {
            case 0:
                ProxyTrafficView(rows: viewModel.proxyTraffic)
            case 1:
                LiveConnectionsView(
                    flows: viewModel.liveFlows,
                    canTerminate: viewModel.canTerminateFlows,
                    onKill: viewModel.killFlow,
                    onKillProcess: viewModel.killFlows
                )
            default:
                ActivityLogsView(
                    logs: filteredActivityLogs,
                    searchText: $activitySearchText,
                    onClear: viewModel.clearActivityLogs
                )
            }
        }
    }

    private var filteredActivityLogs: [ProxyBridgeViewModel.ActivityLog] {
        let q = activitySearchText
        if q.isEmpty {
            return viewModel.activityLogs
        }
        return viewModel.activityLogs.filter {
            $0.timestamp.localizedCaseInsensitiveContains(q) ||
            $0.level.localizedCaseInsensitiveContains(q) ||
            $0.message.localizedCaseInsensitiveContains(q)
        }
    }
}

struct TabButton: View {
    // the language of the app: the strings are read through it, so a change of
    // the language redraws the window
    @ObservedObject private var loc = LocalizationManager.shared
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(isSelected ? Color.blue.opacity(0.2) : Color.clear)
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}

// The traffic of every proxy the traffic went through: one row for each, the way Proxifier
// shows what a proxy carried.
//
// One row per proxy and not one row per connection: a program that opens a hundred
// connections goes out as a single line, and the direct connections are one line as well.
// The bytes of a direct connection are not shown, because macOS hands those flows straight
// back to the system and the extension never gets to see them.
struct ProxyTrafficView: View {
    // the language of the app: the strings are read through it, so a change of
    // the language redraws the window
    @ObservedObject private var loc = LocalizationManager.shared
    let rows: [ProxyBridgeViewModel.ProxyTraffic]

    var body: some View {
        Group {
            if rows.isEmpty {
                emptyState
            } else {
                table
            }
        }
    }

    private var table: some View {
        Table(rows) {
            TableColumn(L10n.t("Proxy")) { row in
                Text(row.proxy)
                    .foregroundColor(row.proxy == "Direct" ? .secondary : .primary)
            }
            .width(min: 150, ideal: 260)

            TableColumn(L10n.t("Connections")) { row in
                Text("\(row.connections)")
            }
            .width(90)

            TableColumn(L10n.t("Sent")) { row in
                Text(row.bytesKnown ? TrafficFormat.bytes(row.bytesUp) : L10n.t("not seen"))
                    .foregroundColor(row.bytesKnown ? .primary : .secondary)
            }
            .width(90)

            TableColumn(L10n.t("Received")) { row in
                Text(row.bytesKnown ? TrafficFormat.bytes(row.bytesDown) : L10n.t("not seen"))
                    .foregroundColor(row.bytesKnown ? .primary : .secondary)
            }
            .width(90)

            TableColumn(L10n.t("Total")) { row in
                Text(row.bytesKnown ? TrafficFormat.bytes(row.bytesUp + row.bytesDown) : L10n.t("not seen"))
                    .foregroundColor(row.bytesKnown ? .primary : .secondary)
            }
            .width(90)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 44))
                .foregroundColor(.gray)
            Text(L10n.t("No traffic yet"))
                .font(.title3)
                .foregroundColor(.gray)
            Text(L10n.t("Every proxy the traffic goes through gets a line here"))
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// The numbers in the tables, the way the system writes them.
enum TrafficFormat {
    static func bytes(_ count: Int64) -> String {
        // The formatter writes "Zero KB" for nothing, which reads like a fault.
        // A connection that has not moved a byte has moved no bytes.
        if count <= 0 { return "0 B" }
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: count)
    }

    // m:ss, or h:mm:ss once it runs past an hour
    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        if s >= 3600 {
            return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
        }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// The connections that are proxied right now. A channel that stops carrying traffic is a
// channel that hangs, so the list shows how long each one has been quiet and lets the user
// close it by hand instead of waiting for the proxy to time out.
//
// Closing one by hand needs the message channel between the app and the extension, and the
// system checks that channel against the app's signature. A build that is not signed by a
// developer can list the connections but not close them.
struct LiveConnectionsView: View {
    // the language of the app: the strings are read through it, so a change of
    // the language redraws the window
    @ObservedObject private var loc = LocalizationManager.shared
    let flows: [ProxyBridgeViewModel.LiveFlow]
    let canTerminate: Bool
    let onKill: (UInt64) -> Void
    let onKillProcess: (String) -> Void
    @State private var selection: UInt64?

    var body: some View {
        Group {
            if flows.isEmpty {
                emptyState
            } else {
                table
            }
        }
    }

    private var table: some View {
        Table(flows, selection: $selection) {
            TableColumn(L10n.t("Application")) { flow in
                Text(flow.process.isEmpty ? "unknown" : flow.process)
            }
            .width(min: 110, ideal: 150)

            TableColumn(L10n.t("Destination")) { flow in
                Text(flow.port > 0 ? "\(flow.destination):\(flow.port)" : flow.destination)
            }
            .width(min: 150, ideal: 220)

            TableColumn(L10n.t("Proto")) { flow in
                Text(flow.protocolName)
            }
            .width(48)

            TableColumn(L10n.t("Proxy")) { flow in
                Text(flow.proxy)
            }
            .width(min: 130, ideal: 180)

            TableColumn(L10n.t("Sent")) { flow in
                Text(TrafficFormat.bytes(flow.bytesUp))
            }
            .width(70)

            TableColumn(L10n.t("Received")) { flow in
                Text(TrafficFormat.bytes(flow.bytesDown))
            }
            .width(70)

            TableColumn(L10n.t("Idle")) { flow in
                Text(TrafficFormat.duration(flow.idle))
                    .foregroundColor(flow.idle >= 30 ? .orange : .primary)
            }
            .width(60)
        }
        .contextMenu {
            Button(L10n.t("Terminate connection")) {
                if let id = selection { onKill(id) }
            }
            .disabled(selection == nil || !canTerminate)

            Button(L10n.t("Terminate all connections of this process")) {
                if let process = selectedProcess { onKillProcess(process) }
            }
            .disabled(selectedProcess == nil || !canTerminate)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 44))
                .foregroundColor(.gray)
            Text(L10n.t("No active connections"))
                .font(.title3)
                .foregroundColor(.gray)
            Text(L10n.t("Connections that are proxied show up here"))
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var selectedProcess: String? {
        guard let id = selection else { return nil }
        return flows.first(where: { $0.id == id })?.process
    }
}

struct ActivityLogsView: View {    let logs: [ProxyBridgeViewModel.ActivityLog]
    @Binding var searchText: String
    let onClear: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            LogTextView(text: logsText)
        }
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.gray)
            TextField(L10n.t("Search logs..."), text: $searchText)
                .textFieldStyle(.plain)
            Spacer()
            Button(L10n.t("Clear"), action: onClear)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var logsText: NSAttributedString {
        let out = NSMutableAttributedString()
        for log in logs {
            out.append(LogText.seg("[\(log.timestamp)] ", .secondaryLabelColor))
            out.append(LogText.seg("[\(log.level)] ", log.level == "ERROR" ? .systemRed : .systemBlue))
            out.append(LogText.seg(log.message, .labelColor))
            out.append(LogText.seg("\n", .labelColor))
        }
        return out
    }
}

// builds the colored, monospaced segments shared by both log views
enum LogText {
    static let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

    static func seg(_ string: String, _ color: NSColor) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.foregroundColor: color, .font: font])
    }
}

// read-only NSTextView so the whole log behaves like a text area, multi-row
// drag select, select all and copy all work like any text box
struct LogTextView: NSViewRepresentable {
    let text: NSAttributedString

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = false
            textView.textContainerInset = NSSize(width: 8, height: 8)
            textView.font = LogText.font
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              let storage = textView.textStorage else { return }

        // nothing changed, leave the current selection and scroll position alone
        if storage.string == text.string { return }

        // keep the user's selection if it still fits (holds while not trimming),
        // otherwise stick to the bottom so new lines stay in view
        let previousSelection = textView.selectedRanges
        let wasAtBottom = isScrolledToBottom(scrollView)

        storage.setAttributedString(text)

        let length = (text.string as NSString).length
        let validSelection = previousSelection.filter { value in
            let r = value.rangeValue
            return r.location + r.length <= length
        }

        if let sel = validSelection.first, sel.rangeValue.length > 0 {
            textView.selectedRanges = validSelection
        } else if wasAtBottom {
            textView.scrollToEndOfDocument(nil)
        }
    }

    private func isScrolledToBottom(_ scrollView: NSScrollView) -> Bool {
        let docHeight = scrollView.documentView?.bounds.height ?? 0
        let visible = scrollView.contentView.bounds
        return visible.maxY >= docHeight - 24
    }
}
