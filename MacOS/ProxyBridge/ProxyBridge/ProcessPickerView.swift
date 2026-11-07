import SwiftUI

// The program picker: the programs that are running on this Mac, so a rule can
// be built from what is actually running instead of typed from memory.
//
// The list comes from the kernel's process table. The app sandbox blocks
// proc_listpids, so the enumerator reads the table with sysctl instead, which
// the sandbox allows. System daemons are in the list too, they are programs
// like any other.
struct ProcessPickerView: View {
    // the language of the app: the strings are read through it, so a change of
    // the language redraws the window
    @ObservedObject private var loc = LocalizationManager.shared
    // what the rule ends up matching on. the matcher compares a pattern with a
    // slash in it against the full path, a plain pattern against the executable
    // name, and the bundle id is matched as well.
    enum ValueMode: String, CaseIterable, Identifiable {
        case name = "Name"
        case bundleId = "Bundle ID"
        case path = "Full path"

        var id: String { rawValue }

        func value(for process: RunningProcess) -> String {
            switch self {
            case .name: return process.ruleValueByName
            case .bundleId: return process.ruleValueByBundleId
            case .path: return process.ruleValueByPath
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    // what the other rules name. the rules that are in effect take a program
    // away, the rules that are switched off only bring a warning.
    var used: RuleNameIndex = RuleNameIndex()
    // the entries of the rule being edited. a program that is already in it is
    // not shown at all, there is nothing to add.
    var currentEntries: Set<String> = []
    var onAdd: ([String]) -> Void

    @State private var processes: [RunningProcess] = []
    @State private var search = ""
    @State private var selection: Set<Int32> = []
    @State private var valueMode: ValueMode = .name
    @State private var onlyMine = true
    @State private var notice: RuleNotice?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            controls
            Divider()
            list
            Divider()
            footer
        }
        .frame(minWidth: 760, idealWidth: 760, maxWidth: .infinity, minHeight: 520, idealHeight: 560, maxHeight: .infinity)
        .onAppear(perform: reload)
        .alert(notice?.title ?? "", isPresented: Binding(
            get: { notice != nil },
            set: { if !$0 { notice = nil } }
        )) {
            Button(L10n.t("OK"), role: .cancel) { notice = nil }
        } message: {
            Text(notice?.message ?? "")
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "app.badge")
                .font(.title2)
                .foregroundColor(.accentColor)
            Text(L10n.t("Choose Programs"))
                .font(.title2)
                .fontWeight(.semibold)
            Spacer()
            Text(L10n.f("%@ program(s) running", "\(processes.count)"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField(L10n.t("Search by name, bundle id or path"), text: $search)
                    .textFieldStyle(.roundedBorder)
                Button {
                    reload()
                } label: {
                    Label(L10n.t("Refresh"), systemImage: "arrow.clockwise")
                }
            }

            HStack(spacing: 16) {
                Picker(L10n.t("Add"), selection: $valueMode) {
                    ForEach(ValueMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)

                Toggle(L10n.t("Only my programs"), isOn: $onlyMine)

                Spacer()
            }
        }
        .padding()
    }

    private var list: some View {
        Group {
            if filtered.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text(emptyText)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filtered, selection: selectionBinding) { process in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            // the field that will be added comes first and in
                            // full size, the other two are context
                            ForEach(Array(fields(for: process).enumerated()), id: \.offset) { _, field in
                                Text(field.text)
                                    .font(field.primary ? .body : .caption)
                                    .fontWeight(field.primary ? .medium : .regular)
                                    .foregroundColor(field.primary ? .primary : .secondary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                        }
                        Spacer()
                        if let owner = enabledOwner(for: process) {
                            // the rule that already names this program
                            Label(owner, systemImage: "exclamationmark.triangle.fill")
                                .labelStyle(.titleAndIcon)
                                .font(.caption)
                                .foregroundColor(.orange)
                                .lineLimit(1)
                        } else if let owner = disabledOwner(for: process) {
                            // the rule names it too, but it is switched off, so
                            // it takes nothing away
                            Label(L10n.f("%@ (off)", owner), systemImage: "pause.circle")
                                .labelStyle(.titleAndIcon)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        Text("\(process.pid)")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                    .tag(process.pid)
                    .listRowBackground(isTaken(process) ? Color.yellow.opacity(0.22) : Color.clear)
                    .help(rowHelp(for: process))
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(footerText)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Button(L10n.t("Cancel")) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(L10n.t("Add to Rule")) {
                let picked = filtered.filter { selection.contains($0.pid) && !isTaken($0) }
                let values = picked.map { valueMode.value(for: $0) }.filter { !$0.isEmpty }
                // keep the order of the list and drop duplicates
                var seen = Set<String>()
                onAdd(values.filter { seen.insert($0).inserted })
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(selection.isEmpty)
        }
        .padding()
    }

    // the fields of a program, the one that will be added first
    private func fields(for process: RunningProcess) -> [(text: String, primary: Bool)] {
        let name = process.name
        let bundleId = process.bundleId ?? ""
        let path = process.path
        let byMode: [ValueMode: String] = [.name: name, .bundleId: bundleId, .path: path]
        var out: [(text: String, primary: Bool)] = []
        for mode in ValueMode.allCases {
            guard let text = byMode[mode], !text.isEmpty else { continue }
            out.append((text, mode == valueMode))
        }
        return out
    }

    private var emptyText: String {
        if !search.isEmpty { return "Nothing matches \"\(search)\"." }
        if !currentEntries.isEmpty {
            return "Every program that matches is already in this rule."
        }
        return "No programs found."
    }

    private var footerText: String {
        if !used.enabledEntries.isEmpty {
            return "Programs in yellow are named by a rule that is in effect and cannot be picked."
        }
        if selection.isEmpty {
            return "Pick one or more programs. A rule matches a program by its name or its bundle id."
        }
        return "\(selection.count) program(s) picked."
    }

    private func rowHelp(for process: RunningProcess) -> String {
        if let owner = enabledOwner(for: process) {
            return "Already named by \"\(owner)\", which is in effect"
        }
        if let owner = disabledOwner(for: process) {
            return "Also named by \"\(owner)\", which is switched off"
        }
        return ""
    }

    // a program that a rule that is in effect already names
    private func isTaken(_ process: RunningProcess) -> Bool {
        return enabledOwner(for: process) != nil
    }

    // the rule that is in effect that already names this program
    private func enabledOwner(for process: RunningProcess) -> String? {
        guard let pattern = RuleProgramUsage.enabledPattern(process, index: used) else { return nil }
        return RuleProgramUsage.owner(of: pattern, index: used, enabled: true)
    }

    // the rule that is switched off that names this program
    private func disabledOwner(for process: RunningProcess) -> String? {
        guard let pattern = RuleProgramUsage.disabledPattern(process, index: used) else { return nil }
        return RuleProgramUsage.owner(of: pattern, index: used, enabled: false)
    }

    // a program that another rule already names cannot be picked, so it is
    // taken out of the selection as soon as it is made
    private var selectionBinding: Binding<Set<Int32>> {
        Binding(
            get: { selection },
            set: { newValue in
                let added = newValue.subtracting(selection)
                selection = newValue.filter { pid in
                    guard let process = processes.first(where: { $0.pid == pid }) else { return false }
                    return !isTaken(process)
                }
                // a program a rule that is switched off names is free to pick,
                // but the user should know that it is named twice
                if let notice = noticeFor(added) { self.notice = notice }
            }
        )
    }

    // the warning for the programs that were picked just now
    private func noticeFor(_ pids: Set<Int32>) -> RuleNotice? {
        var lines: [String] = []
        for pid in pids.sorted() {
            guard let process = processes.first(where: { $0.pid == pid }) else { continue }
            guard let owner = disabledOwner(for: process) else { continue }
            lines.append("\"\(process.name)\" is also named by the rule \"\(owner)\", which is switched off. It can still be added.")
        }
        guard !lines.isEmpty else { return nil }
        return RuleNotice(title: "Also named by a rule that is off",
                          message: lines.joined(separator: "\n\n"))
    }

    private var filtered: [RunningProcess] {
        var list = processes
        if onlyMine {
            let mine = getuid()
            list = list.filter { $0.uid == mine }
        }
        // a program the rule being edited already names is not shown: there is
        // nothing to add and it only takes up room
        list = list.filter { !RuleProgramUsage.isInCurrentRule($0, current: currentEntries) }
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !needle.isEmpty {
            list = list.filter { process in
                process.name.lowercased().contains(needle)
                    || (process.bundleId?.lowercased().contains(needle) ?? false)
                    || process.path.lowercased().contains(needle)
            }
        }
        return list
    }

    private func reload() {
        let all = ProcessEnumerator.all()
        processes = all
        // a program that is gone by the time the user picks it must not stay
        // in the selection
        let alive = Set(all.map { $0.pid })
        selection = selection.filter { alive.contains($0) }
    }
}
