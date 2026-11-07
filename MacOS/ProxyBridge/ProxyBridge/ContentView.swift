import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var viewModel: ProxyBridgeViewModel
    @State private var selectedTab = 0
    @State private var connectionSearchText = ""
    @State private var activitySearchText = ""
    // whether the long form of the notice is shown
    @State private var showNoticeDetails = false

    var body: some View {
        VStack(spacing: 0) {
            headerView
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
                    actionTitle: "Copy the command",
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
                    Button(showNoticeDetails ? "Hide details" : "Details") {
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
                .help("Hide this notice for now")
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

    private var headerView: some View {
        HStack {
            Text("ProxyBridge")
                .font(.headline)
                .padding(.leading)
            Spacer()
        }
        .frame(height: 44)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var tabSelector: some View {
        HStack(spacing: 0) {
            TabButton(title: "Connections", isSelected: selectedTab == 0) {
                selectedTab = 0
            }
            TabButton(title: "Live Connections", isSelected: selectedTab == 1) {
                selectedTab = 1
            }
            TabButton(title: "Activity Logs", isSelected: selectedTab == 2) {
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
                ConnectionsView(
                    connections: filteredConnections,
                    searchText: $connectionSearchText,
                    onClear: viewModel.clearConnections
                )
            case 1:
                LiveConnectionsView(
                    flows: viewModel.liveFlows,
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
    
    private var filteredConnections: [ProxyBridgeViewModel.ConnectionLog] {
        let q = connectionSearchText
        if q.isEmpty {
            return viewModel.connections
        }
        // match against every field so a search finds protocol, ip, port, process, proxy or time
        return viewModel.connections.filter {
            $0.timestamp.localizedCaseInsensitiveContains(q) ||
            $0.connectionProtocol.localizedCaseInsensitiveContains(q) ||
            $0.process.localizedCaseInsensitiveContains(q) ||
            $0.destination.localizedCaseInsensitiveContains(q) ||
            $0.port.localizedCaseInsensitiveContains(q) ||
            $0.proxy.localizedCaseInsensitiveContains(q)
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

struct ConnectionsView: View {
    let connections: [ProxyBridgeViewModel.ConnectionLog]
    @Binding var searchText: String
    let onClear: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            LogTextView(text: connectionsText)
        }
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.gray)
            TextField("Search connections...", text: $searchText)
                .textFieldStyle(.plain)
            Spacer()
            Button("Clear", action: onClear)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var connectionsText: NSAttributedString {
        let out = NSMutableAttributedString()
        for c in connections {
            out.append(LogText.seg("[\(c.timestamp)] ", .secondaryLabelColor))
            out.append(LogText.seg("[\(c.connectionProtocol)] ", .systemBlue))
            out.append(LogText.seg(c.process, .systemGreen))
            out.append(LogText.seg(" → ", .secondaryLabelColor))
            out.append(LogText.seg("\(c.destination):\(c.port)", .systemOrange))
            out.append(LogText.seg(" → ", .secondaryLabelColor))
            out.append(LogText.seg(c.proxy, c.proxy == "Direct" ? .secondaryLabelColor : .systemPurple))
            out.append(LogText.seg("\n", .labelColor))
        }
        return out
    }
}

// The connections that are proxied right now. A channel that stops carrying traffic is a
// channel that hangs, so the list shows how long each one has been quiet and lets the user
// close it by hand instead of waiting for the proxy to time out.
struct LiveConnectionsView: View {
    let flows: [ProxyBridgeViewModel.LiveFlow]
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
            TableColumn("Application") { flow in
                Text(flow.process.isEmpty ? "unknown" : flow.process)
            }
            .width(min: 110, ideal: 150)

            TableColumn("Destination") { flow in
                Text(flow.port > 0 ? "\(flow.destination):\(flow.port)" : flow.destination)
            }
            .width(min: 150, ideal: 220)

            TableColumn("Proto") { flow in
                Text(flow.protocolName)
            }
            .width(48)

            TableColumn("Proxy") { flow in
                Text(flow.proxy)
            }
            .width(min: 130, ideal: 180)

            TableColumn("Sent") { flow in
                Text(LiveConnectionsView.byteText(flow.bytesUp))
            }
            .width(70)

            TableColumn("Received") { flow in
                Text(LiveConnectionsView.byteText(flow.bytesDown))
            }
            .width(70)

            TableColumn("Idle") { flow in
                Text(LiveConnectionsView.durationText(flow.idle))
                    .foregroundColor(flow.idle >= 30 ? .orange : .primary)
            }
            .width(60)
        }
        .contextMenu {
            Button("Terminate connection") {
                if let id = selection { onKill(id) }
            }
            .disabled(selection == nil)

            Button("Terminate all connections of this process") {
                if let process = selectedProcess { onKillProcess(process) }
            }
            .disabled(selectedProcess == nil)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 44))
                .foregroundColor(.gray)
            Text("No active connections")
                .font(.title3)
                .foregroundColor(.gray)
            Text("Connections that are proxied show up here")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var selectedProcess: String? {
        guard let id = selection else { return nil }
        return flows.first(where: { $0.id == id })?.process
    }

    static func byteText(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }

    // m:ss, or h:mm:ss once it runs past an hour
    static func durationText(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        if s >= 3600 {
            return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
        }
        return String(format: "%d:%02d", s / 60, s % 60)
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
            TextField("Search logs...", text: $searchText)
                .textFieldStyle(.plain)
            Spacer()
            Button("Clear", action: onClear)
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
