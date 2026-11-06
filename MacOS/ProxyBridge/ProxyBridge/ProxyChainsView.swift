import SwiftUI

// The proxy chains: the proxies a connection walks through, in order.
//
// A chain lets a rule send its traffic through several proxies one after the
// other, which is what Proxifier calls a proxy chain.
struct ProxyChainsView: View {
    @ObservedObject var viewModel: ProxyBridgeViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var showAddChain = false
    @State private var editingChain: ProxyChain?
    @State private var deletingChain: ProxyChain?
    @State private var affectedRulesCount = 0

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            listContent
            Divider()
            footerButtons
        }
        .frame(minWidth: 720, idealWidth: 720, maxWidth: .infinity, minHeight: 420, idealHeight: 460, maxHeight: .infinity)
        .alert("Delete Chain?", isPresented: Binding(
            get: { deletingChain != nil },
            set: { if !$0 { deletingChain = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let c = deletingChain { viewModel.removeChain(c) }
                deletingChain = nil
            }
            Button("Cancel", role: .cancel) { deletingChain = nil }
        } message: {
            if affectedRulesCount > 0 {
                Text(verbatim: "\(affectedRulesCount) rule\(affectedRulesCount == 1 ? "" : "s") use this chain and will be set to Direct.")
            } else {
                Text("This chain will be permanently removed.")
            }
        }
        .sheet(isPresented: $showAddChain) {
            ProxyChainEditorView(viewModel: viewModel, existing: nil)
        }
        .sheet(item: $editingChain) { chain in
            ProxyChainEditorView(viewModel: viewModel, existing: chain)
        }
    }

    private var headerView: some View {
        HStack {
            Image(systemName: "link")
                .font(.title2)
                .foregroundColor(.accentColor)
            Text("Proxy Chains")
                .font(.title2)
                .fontWeight(.semibold)
            Spacer()
            Button(action: { showAddChain = true }) {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                    Text("Add")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }

    @ViewBuilder
    private var listContent: some View {
        if viewModel.chains.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "link.circle")
                    .font(.system(size: 40))
                    .foregroundColor(.secondary)
                Text("No proxy chains yet.")
                    .font(.headline)
                Text("A chain sends a rule's traffic through several proxies, one after the other. Add one, then pick it as the action of a rule.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(viewModel.chains) { chain in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(chain.displayName)
                                .font(.body)
                                .fontWeight(.medium)
                            Text(proxySummary(chain))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        Spacer()
                        if !chain.problems(proxyTypes: viewModel.proxyTypesById).isEmpty {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .help(chain.problems(proxyTypes: viewModel.proxyTypesById).joined(separator: " "))
                        }
                        Button(action: { editingChain = chain }) {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                        Button(action: {
                            affectedRulesCount = viewModel.rulesUsingChain(id: chain.id)
                            deletingChain = chain
                        }) {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var footerButtons: some View {
        HStack {
            Text("A rule that uses a chain sends its traffic through every proxy of the chain, in order.")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private func proxySummary(_ chain: ProxyChain) -> String {
        let names = chain.proxyIds.compactMap { id in
            viewModel.proxyConfigs.first { $0.id == id }?.displayName
        }
        return names.isEmpty ? "No proxy in this chain" : names.joined(separator: " -> ")
    }
}

// The chain editor: the name and the ordered list of proxies.
struct ProxyChainEditorView: View {
    @ObservedObject var viewModel: ProxyBridgeViewModel
    var existing: ProxyChain?

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var proxyIds: [String]
    @State private var pickerChoice: String = ""
    @State private var validationError: String = ""

    private var isEditMode: Bool { existing != nil }

    init(viewModel: ProxyBridgeViewModel, existing: ProxyChain? = nil) {
        self.viewModel = viewModel
        self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
        _proxyIds = State(initialValue: existing?.proxyIds ?? [])
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "link")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                Text(isEditMode ? "Edit Chain" : "Add Chain")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Name").fontWeight(.medium)
                        TextField("Optional, e.g. Home via work", text: $name)
                            .textFieldStyle(.roundedBorder)
                    }
                    .padding(.vertical, 8)
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Proxies, in order").fontWeight(.medium)
                        Text("The first proxy is asked to open a tunnel to the second one, and so on. The last proxy is the one that reaches the destination.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if proxyIds.isEmpty {
                            Text("No proxy in this chain yet.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.vertical, 6)
                        }

                        ForEach(Array(proxyIds.enumerated()), id: \.offset) { index, id in
                            HStack(spacing: 8) {
                                Text("\(index + 1)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundColor(.secondary)
                                    .frame(width: 20, alignment: .trailing)
                                Text(proxyName(id))
                                    .font(.body)
                                Spacer()
                                Button {
                                    move(index, to: index - 1)
                                } label: {
                                    Image(systemName: "chevron.up")
                                }
                                .buttonStyle(.borderless)
                                .disabled(index == 0)
                                Button {
                                    move(index, to: index + 1)
                                } label: {
                                    Image(systemName: "chevron.down")
                                }
                                .buttonStyle(.borderless)
                                .disabled(index == proxyIds.count - 1)
                                Button {
                                    proxyIds.remove(at: index)
                                    validate()
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                            }
                        }

                        HStack(spacing: 8) {
                            Picker("", selection: $pickerChoice) {
                                Text("Add a proxy...").tag("")
                                ForEach(viewModel.proxyConfigs) { config in
                                    Text(config.displayName).tag(config.id)
                                }
                            }
                            .pickerStyle(.menu)
                            Button("Add") {
                                addPicked()
                            }
                            .disabled(pickerChoice.isEmpty)
                        }
                        .padding(.top, 4)
                    }
                    .padding(.vertical, 4)

                    if !validationError.isEmpty {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                            Text(validationError).font(.caption).foregroundColor(.orange)
                        }
                        .padding(.top, 4)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack(spacing: 12) {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { save(); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(minWidth: 560, idealWidth: 560, maxWidth: .infinity, minHeight: 460, idealHeight: 500, maxHeight: .infinity)
        .onAppear(perform: validate)
    }

    private func proxyName(_ id: String) -> String {
        return viewModel.proxyConfigs.first { $0.id == id }?.displayName ?? "a proxy that no longer exists"
    }

    private func addPicked() {
        guard !pickerChoice.isEmpty else { return }
        proxyIds.append(pickerChoice)
        pickerChoice = ""
        validate()
    }

    private func move(_ index: Int, to target: Int) {
        guard target >= 0, target < proxyIds.count else { return }
        let item = proxyIds.remove(at: index)
        proxyIds.insert(item, at: target)
        validate()
    }

    private func validate() {
        // only the contents matter here, the id does not
        let problems = ProxyChain(name: name, proxyIds: proxyIds)
            .problems(proxyTypes: viewModel.proxyTypesById)
        validationError = problems.joined(separator: " ")
    }

    private func save() {
        let chain = ProxyChain(id: existing?.id ?? UUID().uuidString,
                               name: name.trimmingCharacters(in: .whitespaces),
                               proxyIds: proxyIds)
        if existing != nil {
            viewModel.updateChain(chain)
        } else {
            viewModel.addChain(chain)
        }
    }
}
