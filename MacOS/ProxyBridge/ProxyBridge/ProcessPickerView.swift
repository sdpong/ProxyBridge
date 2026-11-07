import SwiftUI

// The program picker: the programs that are running on this Mac, so a rule can
// be built from what is actually running instead of typed from memory.
//
// The list comes from the kernel's process table. The app sandbox blocks
// proc_listpids, so the enumerator reads the table with sysctl instead, which
// the sandbox allows. System daemons are in the list too, they are programs
// like any other.
struct ProcessPickerView: View {
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
    var onAdd: ([String]) -> Void
    // the programs the other rules already name. they are shown in yellow and
    // cannot be picked, so that a program does not end up in two rules.
    var used: UsedProcessPatterns = UsedProcessPatterns()

    @State private var processes: [RunningProcess] = []
    @State private var search = ""
    @State private var selection: Set<Int32> = []
    @State private var valueMode: ValueMode = .name
    @State private var onlyMine = true

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
    }

    private var header: some View {
        HStack {
            Image(systemName: "app.badge")
                .font(.title2)
                .foregroundColor(.accentColor)
            Text("Choose Programs")
                .font(.title2)
                .fontWeight(.semibold)
            Spacer()
            Text("\(processes.count) program(s) running")
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
                TextField("Search by name, bundle id or path", text: $search)
                    .textFieldStyle(.roundedBorder)
                Button {
                    reload()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }

            HStack(spacing: 16) {
                Picker("Add", selection: $valueMode) {
                    ForEach(ValueMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)

                Toggle("Only my programs", isOn: $onlyMine)

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
                    Text(search.isEmpty ? "No programs found." : "Nothing matches \"\(search)\".")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filtered, selection: selectionBinding) { process in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(process.name)
                                .font(.body)
                            if let bundleId = process.bundleId, !bundleId.isEmpty {
                                Text(bundleId)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            if !process.path.isEmpty {
                                Text(process.path)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                        }
                        Spacer()
                        if let owner = usedOwner(for: process) {
                            // the rule that already names this program
                            Label(owner, systemImage: "exclamationmark.triangle.fill")
                                .labelStyle(.titleAndIcon)
                                .font(.caption)
                                .foregroundColor(.orange)
                                .lineLimit(1)
                        }
                        Text("\(process.pid)")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                    .tag(process.pid)
                    .listRowBackground(isUsed(process) ? Color.yellow.opacity(0.22) : Color.clear)
                    .help(isUsed(process) ? "Already named by \"\(usedOwner(for: process) ?? "another rule")\"" : "")
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
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Add to Rule") {
                let picked = filtered.filter { selection.contains($0.pid) && !isUsed($0) }
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

    private var footerText: String {
        if !used.isEmpty {
            return "Programs in yellow are already named by another rule and cannot be picked."
        }
        return selection.isEmpty
            ? "Pick one or more programs. A rule matches a program by its name or its bundle id."
            : "\(selection.count) program(s) picked."
    }

    // a program that another rule already names
    private func isUsed(_ process: RunningProcess) -> Bool {
        return RuleProgramUsage.isUsed(processName: process.name, bundleId: process.bundleId, used: used)
    }

    // the rule that already names this program
    private func usedOwner(for process: RunningProcess) -> String? {
        guard let pattern = RuleProgramUsage.matchingPattern(processName: process.name, bundleId: process.bundleId, used: used) else {
            return nil
        }
        return used.ownerByPattern[pattern]
    }

    // a program that is already named by another rule cannot be picked, so it
    // is taken out of the selection as soon as it is made
    private var selectionBinding: Binding<Set<Int32>> {
        Binding(
            get: { selection },
            set: { newValue in
                selection = newValue.filter { pid in
                    guard let process = processes.first(where: { $0.pid == pid }) else { return false }
                    return !isUsed(process)
                }
            }
        )
    }

    private var filtered: [RunningProcess] {
        var list = processes
        if onlyMine {
            let mine = getuid()
            list = list.filter { $0.uid == mine }
        }
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
