import SwiftUI
import Combine
import Darwin

// The test of a proxy chain: every hop of the chain is asked whether it is there.
//
// The extension asks the same question every ten minutes and skips the hops
// that do not answer. This is that question, asked by hand, with the answers
// shown one hop at a time.
struct ProxyChainTesterView: View {
    // the language of the app: the strings are read through it, so a change of
    // the language redraws the window
    @ObservedObject private var loc = LocalizationManager.shared
    let chain: ProxyChain
    let hops: [ProxiRouteViewModel.ProxyConfig]
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: ChainTesterModel

    init(chain: ProxyChain, hops: [ProxiRouteViewModel.ProxyConfig]) {
        self.chain = chain
        self.hops = hops
        _model = StateObject(wrappedValue: ChainTesterModel(hops: hops))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 620, height: 430)
        .onAppear { model.run() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "link")
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(chain.displayName)
                    .font(.headline)
                Text(L10n.t("Every proxy of the chain is asked whether it answers."))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button(model.isRunning ? L10n.t("Testing...") : L10n.t("Retest")) { model.run() }
                .disabled(model.isRunning)
            Button(L10n.t("Close")) { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }

    @ViewBuilder
    private var content: some View {
        if model.results.isEmpty {
            Spacer()
            ProgressView()
            Spacer()
        } else {
            List {
                ForEach(model.results) { result in
                    HStack(spacing: 10) {
                        Image(systemName: result.alive == true ? "checkmark.circle.fill" : (result.alive == false ? "xmark.circle.fill" : "circle.dashed"))
                            .foregroundColor(result.alive == true ? .green : (result.alive == false ? .red : .secondary))
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.name)
                                .font(.body)
                            Text(result.address)
                                .font(.caption.monospaced())
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            if let ms = result.latencyMs {
                                Text(String(format: "%.0f ms", ms))
                                    .font(.caption.monospacedDigit())
                            }
                            Text(result.note)
                                .font(.caption)
                                .foregroundColor(result.alive == false ? .red : .secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(L10n.t("The extension asks the same question every ten minutes and skips a hop that does not answer."))
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Button(L10n.t("Close")) { dismiss() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }
}

// The test itself.
final class ChainTesterModel: ObservableObject {
    // What one hop answered.
    struct HopResult: Identifiable {
        let id = UUID()
        let name: String
        let address: String
        // nil while the hop is still being asked
        var alive: Bool?
        var latencyMs: Double?
        var note: String = ""
    }

    @Published var results: [HopResult] = []
    @Published var isRunning = false

    private let hops: [ProxiRouteViewModel.ProxyConfig]

    init(hops: [ProxiRouteViewModel.ProxyConfig]) {
        self.hops = hops
    }

    func run() {
        guard !isRunning else { return }
        isRunning = true
        results = hops.enumerated().map { index, config in
            HopResult(name: config.displayName,
                      address: "\(config.type.uppercased()) \(config.host):\(config.port)")
        }
        DispatchQueue.global(qos: .utility).async {
            for (index, config) in self.hops.enumerated() {
                let answer = self.test(config)
                DispatchQueue.main.async {
                    guard index < self.results.count else { return }
                    self.results[index].alive = answer.alive
                    self.results[index].latencyMs = answer.latencyMs
                    self.results[index].note = answer.note
                }
            }
            DispatchQueue.main.async { self.isRunning = false }
        }
    }

    // One hop: is it there, and does it answer as the proxy it says it is?
    private func test(_ config: ProxiRouteViewModel.ProxyConfig) -> (alive: Bool, latencyMs: Double?, note: String) {
        guard let (fd, ms) = ProxySocket.open(host: config.host, port: config.port) else {
            return (false, nil, L10n.t("does not answer"))
        }
        defer { Darwin.close(fd) }

        let type = config.type.lowercased()
        if type == "socks5" {
            // the greeting is the smallest thing that says "this is a socks5 server"
            if ProxySocket.socks5Handshake(fd, username: config.username, password: config.password) {
                return (true, ms, L10n.t("answers"))
            }
            return (false, ms, L10n.t("does not answer as a socks5 server"))
        }
        // the other protocols need a destination to talk to, so the connection
        // itself is all that can be said about them
        return (true, ms, L10n.t("answers"))
    }
}
