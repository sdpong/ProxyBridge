import SwiftUI
import NetworkExtension
import UniformTypeIdentifiers
import AppKit

// A message that pops up over the rules list or the rule editor. It only
// tells the user something, it never stops them.
struct RuleNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct ProxyRule: Identifiable, Codable {
    var localId: String
    var name: String
    let processNames: String
    let targetHosts: String
    let targetPorts: String
    let ruleProtocol: String
    let action: String
    var enabled: Bool

    // localId is the stable gui side identity, ruleId in the extension is not stable
    var id: String { localId }

    enum CodingKeys: String, CodingKey {
        case localId
        case name
        case processNames
        case targetHosts
        case targetPorts
        case ruleProtocol = "protocol"
        case action
        case enabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.localId = try c.decodeIfPresent(String.self, forKey: .localId) ?? UUID().uuidString
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.processNames = try c.decode(String.self, forKey: .processNames)
        self.targetHosts = try c.decode(String.self, forKey: .targetHosts)
        self.targetPorts = try c.decode(String.self, forKey: .targetPorts)
        self.ruleProtocol = try c.decode(String.self, forKey: .ruleProtocol)
        self.action = try c.decode(String.self, forKey: .action)
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // drop localId on export so imported rules get fresh ids
        try c.encode(name, forKey: .name)
        try c.encode(processNames, forKey: .processNames)
        try c.encode(targetHosts, forKey: .targetHosts)
        try c.encode(targetPorts, forKey: .targetPorts)
        try c.encode(ruleProtocol, forKey: .ruleProtocol)
        try c.encode(action, forKey: .action)
        try c.encode(enabled, forKey: .enabled)
    }

    init(localId: String = UUID().uuidString, name: String = "", processNames: String, targetHosts: String, targetPorts: String, ruleProtocol: String, action: String, enabled: Bool) {
        self.localId = localId
        self.name = name
        self.processNames = processNames
        self.targetHosts = targetHosts
        self.targetPorts = targetPorts
        self.ruleProtocol = ruleProtocol
        self.action = action
        self.enabled = enabled
    }

    // UserDefaults stores rules as plain dictionaries, these bridge to that
    init(dict: [String: Any]) {
        self.localId = dict["localId"] as? String ?? UUID().uuidString
        self.name = dict["name"] as? String ?? ""
        self.processNames = dict["processNames"] as? String ?? ""
        self.targetHosts = dict["targetHosts"] as? String ?? ""
        self.targetPorts = dict["targetPorts"] as? String ?? ""
        self.ruleProtocol = dict["protocol"] as? String ?? "BOTH"
        self.action = dict["action"] as? String ?? "DIRECT"
        self.enabled = dict["enabled"] as? Bool ?? true
    }

    func toDict() -> [String: Any] {
        return [
            "localId": localId,
            "name": name,
            "processNames": processNames,
            "targetHosts": targetHosts,
            "targetPorts": targetPorts,
            "protocol": ruleProtocol,
            "action": action,
            "enabled": enabled
        ]
    }
}

struct ProxyRulesView: View {
    // the language of the app: the strings are read through it, so a change of
    // the language redraws the window
    @ObservedObject private var loc = LocalizationManager.shared
    @ObservedObject var viewModel: ProxiRouteViewModel
    @State private var rules: [ProxyRule] = []
    @State private var selectedRuleIds: Set<String> = []
    @State private var showAddRule = false
    @State private var editingRule: ProxyRule?
    // a rule that was opened after a warning, and the warning itself
    @State private var pendingEdit: ProxyRule?
    @State private var notice: RuleNotice?
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.t("Proxy Rules"))
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Spacer()
                
                Button(action: { 
                    if selectedRuleIds.count == rules.count {
                        selectedRuleIds.removeAll()
                    } else {
                        selectedRuleIds = Set(rules.map { $0.id })
                    }
                }) {
                    HStack {
                        Image(systemName: selectedRuleIds.count == rules.count ? "checkmark.square" : "square")
                        Text(selectedRuleIds.count == rules.count ? L10n.t("Deselect All") : L10n.t("Select All"))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .disabled(rules.isEmpty)
                
                Button(action: { exportSelectedRules() }) {
                    HStack {
                        Image(systemName: "square.and.arrow.up")
                        Text(L10n.t("Export"))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .disabled(selectedRuleIds.isEmpty)
                
                Button(action: { importRulesFromFile() }) {
                    HStack {
                        Image(systemName: "square.and.arrow.down")
                        Text(L10n.t("Import"))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                
                Button(action: { showAddRule = true }) {
                    HStack {
                        Image(systemName: "plus")
                        Text(L10n.t("Add Rule"))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            
            if rules.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 48))
                        .foregroundColor(.gray)
                    Text(L10n.t("No rules configured"))
                        .font(.title3)
                        .foregroundColor(.gray)
                    Text(L10n.t("Click 'Add Rule' to create your first rule"))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else {
                Table(rules) {
                    TableColumn("") { rule in
                        Toggle("", isOn: Binding(
                            get: { selectedRuleIds.contains(rule.id) },
                            set: { isSelected in
                                if isSelected {
                                    selectedRuleIds.insert(rule.id)
                                } else {
                                    selectedRuleIds.remove(rule.id)
                                }
                            }
                        ))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                    }
                    .width(32)

                    TableColumn(L10n.t("On")) { rule in
                        Toggle("", isOn: binding(for: rule))
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                    .width(44)

                    TableColumn("") { rule in
                        HStack(spacing: 12) {
                            Button(action: { editRule(rule) }) {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.borderless)
                            .foregroundColor(.blue)
                            .help(L10n.t("Edit"))

                            Button(action: { deleteRule(rule) }) {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .foregroundColor(.red)
                            .help(L10n.t("Delete"))
                        }
                    }
                    .width(60)

                    TableColumn("SR") { rule in
                        let index = (rules.firstIndex(where: { $0.id == rule.id }) ?? 0) + 1
                        Text(verbatim: "\(index)")
                    }
                    .width(32)

                    TableColumn(L10n.t("Name")) { rule in
                        Text(rule.name.isEmpty ? "=" : rule.name)
                            .foregroundColor(rule.name.isEmpty ? .secondary : .primary)
                    }
                    .width(min: 90, ideal: 120)

                    TableColumn(L10n.t("Bundle ID")) { rule in
                        RuleEntryCell(stored: rule.processNames,
                                      separators: RulePatternValidator.programSeparators)
                    }
                    .width(min: 100, ideal: 140)

                    TableColumn(L10n.t("Target Hosts")) { rule in
                        RuleEntryCell(stored: rule.targetHosts,
                                      separators: RulePatternValidator.hostSeparators,
                                      keepRangesTogether: true)
                    }
                    .width(min: 100, ideal: 150)

                    TableColumn(L10n.t("Target Ports")) { rule in
                        Text(rule.targetPorts.isEmpty ? "Any" : rule.targetPorts)
                    }
                    .width(min: 70, ideal: 100)

                    TableColumn(L10n.t("Protocol")) { rule in
                        Text(rule.ruleProtocol)
                    }
                    .width(64)

                    TableColumn(L10n.t("Action")) { rule in
                        Text(actionDisplayName(rule.action))
                            .foregroundColor(actionColor(rule.action))
                            .fontWeight(.semibold)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .width(min: 120, ideal: 160)
                }
                .padding()
            }
        }
        .frame(minWidth: 900, minHeight: 500)
        .onAppear {
            loadRules()
        }
        // reload when the active profile changes so an open window isn't stale
        .onChange(of: viewModel.activeProfile) { _ in
            selectedRuleIds.removeAll()
            loadRules()
        }
        .sheet(isPresented: $showAddRule) {
            RuleEditorView(viewModel: viewModel, otherRules: rules, onCommit: { commitRule($0) })
        }
        .sheet(item: $editingRule) { rule in
            RuleEditorView(viewModel: viewModel,
                           existingRule: rule,
                           otherRules: rules.filter { $0.id != rule.id },
                           onCommit: { commitRule($0) })
        }
        .alert(notice?.title ?? "", isPresented: Binding(
            get: { notice != nil },
            set: { if !$0 { notice = nil } }
        )) {
            Button(L10n.t("Open")) {
                if let rule = pendingEdit { editingRule = rule }
                pendingEdit = nil
                notice = nil
            }
            Button(L10n.t("Cancel"), role: .cancel) {
                pendingEdit = nil
                notice = nil
            }
        } message: {
            Text(notice?.message ?? "")
        }
    }

    // A rule that is switched off and names the same thing as another rule is
    // worth a warning when it is opened, because the day it is switched on the
    // two rules fight over the same traffic. The warning does not stop the
    // user, the rule still opens.
    private func editRule(_ rule: ProxyRule) {
        guard !rule.enabled else {
            editingRule = rule
            return
        }
        let clashes = clashSummary(for: rule)
        guard !clashes.isEmpty else {
            editingRule = rule
            return
        }
        pendingEdit = rule
        notice = RuleNotice(title: L10n.t("Named twice"), message: clashes)
    }

    // what this rule names that another rule names as well
    private func clashSummary(for rule: ProxyRule) -> String {
        var parts: [String] = []
        for other in rules where other.id != rule.id {
            let programs = sharedEntries(rule.processNames,
                                         other.processNames,
                                         separators: RulePatternValidator.programSeparators,
                                         keepRangesTogether: false,
                                         isHost: false)
            let hosts = sharedEntries(rule.targetHosts,
                                      other.targetHosts,
                                      separators: RulePatternValidator.hostSeparators,
                                      keepRangesTogether: true,
                                      isHost: true)
            if programs.isEmpty && hosts.isEmpty { continue }
            var lines: [String] = []
            if !programs.isEmpty { lines.append(L10n.f("program(s): %@", programs.joined(separator: ", "))) }
            if !hosts.isEmpty { lines.append(L10n.f("host(s): %@", hosts.joined(separator: ", "))) }
            let name = other.name.isEmpty ? L10n.t("another rule") : other.name
            let state = other.enabled ? L10n.t("is in effect") : L10n.t("is switched off too")
            parts.append(L10n.f("The rule \"%@\" %@ and names the same:\n%@", name, state, lines.joined(separator: "\n")))
        }
        return parts.joined(separator: "\n\n")
    }

    // the entries of a and b that name the same thing
    private func sharedEntries(_ a: String,
                                _ b: String,
                                separators: CharacterSet,
                                keepRangesTogether: Bool,
                                isHost: Bool) -> [String] {
        let left = RulePatternValidator.entries(a, separators: separators, keepRangesTogether: keepRangesTogether)
        let right = RulePatternValidator.entries(b, separators: separators, keepRangesTogether: keepRangesTogether)
        var out: [String] = []
        for one in left {
            for two in right {
                let same = isHost
                    ? RulePatternMatch.sameHost(pattern: two.text, entry: one.text)
                    : RulePatternMatch.sameProgram(pattern: two.text, entry: one.text)
                if same && !out.contains(one.text) { out.append(one.text) }
            }
        }
        return out
    }
    
    private func binding(for rule: ProxyRule) -> Binding<Bool> {
        Binding(
            get: { rule.enabled },
            set: { newValue in
                toggleRule(rule, enabled: newValue)
            }
        )
    }
    
    private func actionColor(_ action: String) -> Color {
        switch action {
        case "BLOCK": return .red
        case "DIRECT": return .blue
        default: return .green  // any proxy config UUID
        }
    }

    private func actionDisplayName(_ action: String) -> String {
        switch action {
        case "DIRECT", "BLOCK": return action
        default:
            return viewModel.proxyConfigs.first(where: { $0.id == action })?.displayName ?? action
        }
    }
    
    // rules live in UserDefaults on the gui side, the extension is just a mirror
    private func loadRules() {
        let dicts = UserDefaults.standard.array(forKey: "proxyRules") as? [[String: Any]] ?? []
        rules = dicts.map { ProxyRule(dict: $0) }
    }

    // persist the current list and push it to the extension if the tunnel is up
    private func saveAndSync() {
        UserDefaults.standard.set(rules.map { $0.toDict() }, forKey: "proxyRules")
        if let session = viewModel.tunnelSession {
            RuleManager.resyncRules(session: session) { _, _ in }
        }
    }

    func commitRule(_ rule: ProxyRule) {
        if let index = rules.firstIndex(where: { $0.localId == rule.localId }) {
            rules[index] = rule
        } else {
            rules.append(rule)
        }
        saveAndSync()
    }

    private func deleteRule(_ rule: ProxyRule) {
        rules.removeAll { $0.localId == rule.localId }
        selectedRuleIds.remove(rule.localId)
        saveAndSync()
    }

    private func toggleRule(_ rule: ProxyRule, enabled: Bool) {
        guard let index = rules.firstIndex(where: { $0.localId == rule.localId }) else { return }
        rules[index].enabled = enabled
        saveAndSync()
    }
    
    private func getSelectedRules() -> [ProxyRule] {
        return rules.filter { selectedRuleIds.contains($0.id) }
    }
    
    private func exportSelectedRules() {
        guard !selectedRuleIds.isEmpty else { return }
        
        let selectedRules = getSelectedRules()
        
        let savePanel = NSSavePanel()
        savePanel.title = L10n.t("Export Proxy Rules")
        savePanel.message = L10n.t("Choose a location to save the selected rules")
        savePanel.nameFieldStringValue = "ProxiRoute-Rules.json"
        savePanel.allowedContentTypes = [.json]
        savePanel.canCreateDirectories = true
        
        let response = savePanel.runModal()
        guard response == .OK, let url = savePanel.url else { return }
        
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(selectedRules)
            try data.write(to: url)
        } catch {
            print(L10n.f("Export failed: %@", "\(error)"))
        }
    }
    
    private func importRulesFromFile() {
        let openPanel = NSOpenPanel()
        openPanel.title = L10n.t("Import Proxy Rules")
        openPanel.message = L10n.t("Choose a rules file to import")
        openPanel.allowedContentTypes = [.json]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        
        let response = openPanel.runModal()
        guard response == .OK, let url = openPanel.urls.first else { return }
        
        importRules(from: url)
    }
    
    private func importRules(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let importedRules = try JSONDecoder().decode([ProxyRule].self, from: data)
            // decode drops localId so each imported rule already has a fresh one
            rules.append(contentsOf: importedRules)
            saveAndSync()
        } catch {
            print(L10n.f("Failed to import rules: %@", "\(error)"))
        }
    }
}

struct RuleEditorView: View {
    // the language of the app: the strings are read through it, so a change of
    // the language redraws the window
    @ObservedObject private var loc = LocalizationManager.shared
    @ObservedObject var viewModel: ProxiRouteViewModel
    var existingRule: ProxyRule?
    // the rules other than the one being edited. the rules list knows them,
    // the editor only needs to know what they name.
    var otherRules: [ProxyRule] = []
    var onCommit: (ProxyRule) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var ruleName: String
    @State private var processNames: String
    @State private var targetHosts: String
    @State private var targetPorts: String
    @State private var selectedProtocol: String
    @State private var selectedAction: String
    @State private var showProcessPicker = false
    @State private var notice: RuleNotice?

    private var isEditMode: Bool { existingRule != nil }

    init(viewModel: ProxiRouteViewModel,
         existingRule: ProxyRule? = nil,
         otherRules: [ProxyRule] = [],
         onCommit: @escaping (ProxyRule) -> Void) {
        self.viewModel = viewModel
        self.existingRule = existingRule
        self.otherRules = otherRules
        self.onCommit = onCommit

        _ruleName = State(initialValue: existingRule?.name ?? "")
        // the rule is stored with the entries in one line, the editor shows
        // them one per line
        _processNames = State(initialValue: RulePatternValidator.displayForm(
            existingRule?.processNames ?? "*",
            separators: RulePatternValidator.programSeparators))
        _targetHosts = State(initialValue: RulePatternValidator.displayForm(
            existingRule?.targetHosts ?? "*",
            separators: RulePatternValidator.hostSeparators,
            keepRangesTogether: true))
        _targetPorts = State(initialValue: existingRule?.targetPorts ?? "*")
        _selectedProtocol = State(initialValue: existingRule?.ruleProtocol ?? "TCP")
        // default to first proxy config if there is one, otherwise direct
        let defaultAction = existingRule?.action ?? viewModel.proxyConfigs.first?.id ?? "DIRECT"
        _selectedAction = State(initialValue: defaultAction)
    }

    var body: some View {
        VStack(spacing: 20) {
            Text(isEditMode ? L10n.t("Edit Rule") : L10n.t("Add Rule"))
                .font(.title2)
                .fontWeight(.semibold)

            Form {
                Section {
                    formField(
                        label: L10n.t("Rule Name"),
                        placeholder: L10n.t("Optional, e.g. Work traffic"),
                        text: $ruleName,
                        hint: L10n.t("Shown in the rules list. Leave empty if you don't need one.")
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(L10n.t("Process / Bundle Identifier")).fontWeight(.medium)
                            Spacer()
                            Button {
                                showProcessPicker = true
                            } label: {
                                Label(L10n.t("Choose..."), systemImage: "app.badge")
                            }
                        }
                        PatternTextEditor(text: $processNames,
                                          highlights: problemRanges(processEntries),
                                          notes: usedRanges(processEntries, names: usedPrograms, isHost: false),
                                          isInvalid: !processEntries.filter({ $0.hasProblem }).isEmpty,
                                          onTextClick: { index in
                                              handleClick(index, entries: processEntries, names: usedPrograms, isHost: false)
                                          })
                            .frame(height: 96)
                        problemList(processEntries)
                        Text(L10n.t("Matches the bundle id or the process name, one per line. Examples: com.apple.Safari; curl; Google Chrome Helper; *chrome*; *"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.t("Target hosts")).fontWeight(.medium)
                        PatternTextEditor(text: $targetHosts,
                                          highlights: problemRanges(hostEntries),
                                          notes: usedRanges(hostEntries, names: usedHosts, isHost: true),
                                          isInvalid: !hostEntries.filter({ $0.hasProblem }).isEmpty,
                                          onTextClick: { index in
                                              handleClick(index, entries: hostEntries, names: usedHosts, isHost: true)
                                          })
                            .frame(height: 96)
                        problemList(hostEntries)
                        Text(L10n.t("One per line. IP: 127.0.0.1; 192.168.1.*; 10.0.0.1-10.0.0.254; ::1   Domain: github.com; *.github.com; *google*"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    HStack(spacing: 4) {
                        Image(systemName: viewModel.isDNSEnabled ? "info.circle" : "exclamationmark.triangle.fill")
                            .foregroundColor(viewModel.isDNSEnabled ? .secondary : .orange)
                        Text(viewModel.isDNSEnabled
                             ? L10n.t("Host names only match when Enable DNS is on in the Proxy menu. IP addresses always work.")
                             : L10n.t("Enable DNS is off in the Proxy menu, so host names do not match. IP addresses still work."))
                            .font(.caption).foregroundColor(.secondary)
                    }
                    
                    formField(
                        label: L10n.t("Target ports"),
                        placeholder: "*",
                        text: $targetPorts,
                        hint: L10n.t("Example: 80; 8000-9000; 3128")
                    )

                    HStack(spacing: 4) {
                        Image(systemName: "info.circle").foregroundColor(.secondary)
                        Text(L10n.t("Target hosts and ports only apply to TCP. UDP rules match on the app (bundle id) only."))
                            .font(.caption).foregroundColor(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.t("Protocol"))
                            .fontWeight(.medium)
                        Picker("", selection: $selectedProtocol) {
                            Text("TCP").tag("TCP")
                            Text("UDP").tag("UDP")
                            Text("BOTH").tag("BOTH")
                        }
                        .pickerStyle(.segmented)
                        if selectedProtocol == "UDP" || selectedProtocol == "BOTH" {
                            HStack(alignment: .top, spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.yellow)
                                Text(L10n.t("UDP only works with a SOCKS5 proxy. Not all SOCKS5 proxies support UDP by default, and SOCKS5 UDP support does not guarantee QUIC or HTTP/3 works - verify your proxy supports these separately."))
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.t("Action"))
                            .fontWeight(.medium)
                        Picker("", selection: $selectedAction) {
                            Text("DIRECT").tag("DIRECT")
                            Text("BLOCK").tag("BLOCK")
                            if !viewModel.proxyConfigs.isEmpty {
                                Divider()
                                ForEach(viewModel.proxyConfigs) { config in
                                    Text(config.displayName).tag(config.id)
                                }
                            }
                            if !viewModel.chains.isEmpty {
                                Divider()
                                ForEach(viewModel.chains) { chain in
                                    Text(chain.displayName).tag(chain.action)
                                }
                            }
                        }
                        .pickerStyle(.menu)
                        if selectedProtocol == "UDP" || selectedProtocol == "BOTH" {
                            let isHttp = viewModel.proxyConfigs.first(where: { $0.id == selectedAction })?.type.lowercased() == "http"
                            if isHttp {
                                HStack(spacing: 4) {
                                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.yellow)
                                    Text(L10n.t("UDP only works with SOCKS5 proxy. HTTP proxies do not support UDP."))
                                        .font(.caption).foregroundColor(.secondary)
                                }
                            }
                        }
                        if viewModel.proxyConfigs.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "info.circle").foregroundColor(.secondary)
                                Text(L10n.t("No proxy servers configured - add one in Proxy Settings."))
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                        // a chain cannot carry udp, say so instead of letting the
                        // traffic go direct without an explanation
                        if let chain = viewModel.chains.first(where: { $0.action == selectedAction }) {
                            HStack(alignment: .top, spacing: 4) {
                                Image(systemName: "info.circle").foregroundColor(.secondary)
                                Text(L10n.f("This rule uses the chain \"%@\". A chain carries TCP only, UDP traffic of this rule goes direct.", chain.displayName))
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            
            HStack {
                Button(L10n.t("Cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(L10n.t("Save Rule")) {
                    saveRule()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(hasProblems)
            }
            .padding(.horizontal)

            if hasProblems {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
                    Text(L10n.t("The marked entries cannot work. Fix them before saving."))
                        .font(.caption)
                        .foregroundColor(.red)
                }
                .padding(.horizontal)
            }
        }
        .sheet(isPresented: $showProcessPicker) {
            ProcessPickerView(used: usedPrograms,
                               currentEntries: RuleProgramUsage.exactEntries(processNames)) { values in
                addProcesses(values)
            }
        }
        .alert(notice?.title ?? "", isPresented: Binding(
            get: { notice != nil },
            set: { if !$0 { notice = nil } }
        )) {
            Button(L10n.t("OK"), role: .cancel) { notice = nil }
        } message: {
            Text(notice?.message ?? "")
        }
        .padding()
        .frame(width: 600, height: 720)
    }

    // the entries of the program list the user typed
    private var processEntries: [RulePatternEntry] {
        return RulePatternValidator.checkPrograms(processNames)
    }

    // the entries of the host list the user typed
    private var hostEntries: [RulePatternEntry] {
        return RulePatternValidator.checkHosts(targetHosts)
    }

    // something in the lists cannot work
    private var hasProblems: Bool {
        return processEntries.contains { $0.hasProblem } || hostEntries.contains { $0.hasProblem }
    }

    // the entries that are marked in the editor
    private func problemRanges(_ entries: [RulePatternEntry]) -> [NSRange] {
        return entries.filter { $0.hasProblem }.map { $0.range }
    }

    // what is wrong with the entries, said out loud under the box
    @ViewBuilder
    private func problemList(_ entries: [RulePatternEntry]) -> some View {
        let broken = entries.filter { $0.hasProblem }
        if !broken.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(broken.enumerated()), id: \.offset) { _, entry in
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text("\"\(entry.text)\" \(entry.summary)")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
            }
        }
    }

    // the programs the other rules name, split by whether the rule is in
    // effect. the picker shows the ones in effect in yellow and warns about
    // the ones that are switched off.
    private var usedPrograms: RuleNameIndex {
        RuleNameIndexBuilder.build(otherRuleSources { $0.processNames },
                                   separators: RulePatternValidator.programSeparators)
    }

    // the hosts the other rules name, the same way
    private var usedHosts: RuleNameIndex {
        RuleNameIndexBuilder.build(otherRuleSources { $0.targetHosts },
                                   separators: RulePatternValidator.hostSeparators,
                                   keepRangesTogether: true)
    }

    // every rule but the one being edited
    private func otherRuleSources(_ entries: (ProxyRule) -> String) -> [RuleNameSource] {
        return otherRules.map {
            RuleNameSource(id: $0.localId, name: $0.name, entries: entries($0), enabled: $0.enabled)
        }
    }

    // the entries another rule that is in effect names. they are marked in
    // yellow: they are not wrong, but they are named twice.
    private func usedRanges(_ entries: [RulePatternEntry], names: RuleNameIndex, isHost: Bool) -> [NSRange] {
        var ranges: [NSRange] = []
        for entry in entries where !entry.hasProblem {
            let pattern = isHost
                ? RulePatternMatch.hostPattern(host: entry.text, entries: names.enabledEntries)
                : RulePatternMatch.programEntryPattern(entry: entry.text, entries: names.enabledEntries)
            if pattern != nil { ranges.append(entry.range) }
        }
        return ranges
    }

    // the user clicked in the box. an entry that a rule which is switched off
    // names is worth a word about, but it can still be used here.
    private func handleClick(_ index: Int, entries: [RulePatternEntry], names: RuleNameIndex, isHost: Bool) {
        guard let entry = RuleClickLookup.entry(at: index, in: entries) else { return }
        guard let owner = RuleClickLookup.offOwner(for: entry, names: names, isHost: isHost) else { return }
        notice = RuleNotice(title: L10n.t("Also named by a rule that is off"),
                            message: L10n.f("\"%@\" is also named by the rule \"%@\", which is switched off. It can still be used here.", entry.text, owner))
    }

    @ViewBuilder
    private func formField(label: String, placeholder: String, text: Binding<String>, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .fontWeight(.medium)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
            Text(hint)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // the picked programs are added to the list the matcher reads, which is
    // separated by ';' or ','. a program that is already in the list is not
    // added twice.
    private func addProcesses(_ values: [String]) {
        guard !values.isEmpty else { return }
        var existing = RulePatternValidator
            .entries(processNames, separators: RulePatternValidator.programSeparators)
            .map { $0.text }
        for value in values where !existing.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) {
            existing.append(value)
        }
        processNames = existing.joined(separator: "\n")
    }

    private func saveRule() {
        let rule = ProxyRule(
            localId: existingRule?.localId ?? UUID().uuidString,
            name: ruleName.trimmingCharacters(in: .whitespaces),
            processNames: RulePatternValidator.storedForm(
                processNames, separators: RulePatternValidator.programSeparators),
            targetHosts: RulePatternValidator.storedForm(
                targetHosts, separators: RulePatternValidator.hostSeparators, keepRangesTogether: true),
            targetPorts: targetPorts,
            ruleProtocol: selectedProtocol,
            action: selectedAction,
            enabled: existingRule?.enabled ?? true
        )
        onCommit(rule)
        dismiss()
    }
}

// The entries of a rule are stored in one line, separated by "; ". The table
// shows them one per line, the way Proxifier lists them, so a rule with four
// hosts does not read as one long string the eye has to scan.
struct RuleEntryCell: View {
    // the language of the app: the strings are read through it, so a change of
    // the language redraws the window
    @ObservedObject private var loc = LocalizationManager.shared
    let stored: String
    let separators: CharacterSet
    let keepRangesTogether: Bool

    init(stored: String, separators: CharacterSet, keepRangesTogether: Bool = false) {
        self.stored = stored
        self.separators = separators
        self.keepRangesTogether = keepRangesTogether
    }

    var body: some View {
        if stored.isEmpty {
            Text(L10n.t("Any"))
        } else {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(entries.enumerated()), id: \.offset) { pair in
                    Text(pair.element)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var entries: [String] {
        RulePatternValidator.displayForm(stored,
                                          separators: separators,
                                          keepRangesTogether: keepRangesTogether)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }
}

struct RulesDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    
    var rules: [ProxyRule]
    
    init(rules: [ProxyRule]) {
        self.rules = rules
    }
    
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let decoder = JSONDecoder()
        rules = try decoder.decode([ProxyRule].self, from: data)
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(rules)
        return FileWrapper(regularFileWithContents: data)
    }
}
