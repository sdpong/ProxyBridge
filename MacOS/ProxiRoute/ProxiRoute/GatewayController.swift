import Foundation
import Combine

// The gateway mode of this machine.
//
// The gateway mode is the mode in which this machine is the gateway of the
// network: the traffic of the other terminals comes in through it and goes
// out by the rules of the app.
//
// Two programs do the work, and they are told apart by what they need:
//
//   - the helper is a program of root. It loads the rules of the packet
//     filter, it turns the forwarding of the machine on, and it asks the
//     kernel where a redirected connection was going. The device of the
//     filter is for root alone, so there is no other way.
//   - the app is a program of the person in front of the machine. It takes
//     the redirected connections in, it decides by the rules where they go,
//     and it carries the bytes.
//
// The app talks to the helper over a unix socket, and the helper checks who
// is on the other end of it.

@MainActor
final class GatewayController: ObservableObject {

    // What the person in front of the window is told.
    @Published private(set) var status: String = ""
    @Published private(set) var isRunning = false
    @Published private(set) var helperInstalled = false
    // how many connections of the network have been carried
    @Published private(set) var carriedConnections = 0

    // The part of the gateway mode that runs in the app.
    //
    // The helper is a program of root, and this is the program that takes the
    // traffic of the network in and carries it. The two are told apart by
    // what they need, and they are put in step by this controller: the
    // filter has to be on before the traffic comes in, and it has to be off
    // before the program stops listening.
    private let dataPlane = GatewayDataPlane()

    // The interface the traffic of the network comes in through.
    //
    // It is empty when the person has not chosen one, and then the helper
    // is asked to find the interface the machine leaves the network by.
    @Published var interface: String = ""

    // Whether the gateway mode is wanted.
    //
    // It is the switch in the window, and it is remembered: a machine that
    // is the gateway of its network stays that way when the app is opened
    // again.
    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: GatewayController.storageKey)
            apply()
        }
    }

    static let storageKey = "gatewayEnabled"

    // The rules of the app, as the engine reads them.
    //
    // The traffic of the network has no program behind it, so the rules that
    // name one are skipped by the engine.
    var rules: [EngineRule] = []
    var proxies: [ProxyEndpoint] = []
    var chains: [String: [String]] = [:]

    // What the log says.
    var logHandler: ((String, String) -> Void)?

    private var pollTimer: Timer?

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: GatewayController.storageKey)
        // The traffic of the network is carried by threads of their own, and
        // the log of the app belongs to the window: the lines are brought to
        // the main thread, or the window would be written to from two
        // threads at once.
        dataPlane.logHandler = { [weak self] message, level in
            Task { @MainActor in
                self?.log(message, level: level)
            }
        }
    }

    // The gateway is asked to start.
    //
    // The helper does the work, and the app asks it. The answer of the
    // helper is what the person is told: if the helper is not installed, or
    // if it refused, the reason is in words.
    func apply() {
        // the rules of the app are the rules the traffic of the network goes
        // by, and they may have changed since the last time
        dataPlane.update(rules: rules, proxies: proxies, chains: chains)
        if isEnabled {
            start()
        } else {
            stop()
        }
    }

    // Turns the gateway on.
    func start() {
        let name = interface.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            status = L10n.t("The gateway mode needs an interface: the network card the other terminals reach this machine through.")
            isRunning = false
            return
        }

        // The program that takes the traffic in has to be listening before the
        // rules of the filter are in place: a client whose connection is
        // redirected to a port that nobody listens on is a client with no
        // internet at all.
        switch dataPlane.start() {
        case .failure(let failure):
            isRunning = false
            status = failure.reason
            log("The gateway mode could not be started: \(failure.reason)", level: "ERROR")
            return
        case .success:
            break
        }

        let result = GatewayHelperClient.enable(interface: name, redirectPort: GatewayDataPlane.redirectPort)
        if result.ok {
            isRunning = true
            helperInstalled = true
            status = L10n.f("The gateway mode is on: the traffic of the network comes in through %@.", name)
            log("The gateway mode was turned on on \(name)", level: "INFO")
        } else {
            // The rules of the filter are not in place, so no traffic comes
            // in. The program stops listening as well, or it would wait for
            // a traffic that cannot come.
            dataPlane.stop()
            isRunning = false
            status = result.message
            log("The gateway mode could not be turned on: \(result.message)", level: "ERROR")
        }
        startPolling()
    }

    // Turns the gateway off.
    func stop() {
        stopPolling()
        guard helperInstalled else {
            dataPlane.stop()
            isRunning = false
            status = ""
            return
        }
        // The rules of the filter go first: the traffic of the network is not
        // taken in any more, and only then does the program stop listening.
        let result = GatewayHelperClient.disable()
        dataPlane.stop()
        if result.ok {
            isRunning = false
            status = L10n.t("The gateway mode is off.")
            log("The gateway mode was turned off", level: "INFO")
        } else {
            status = result.message
            log("The gateway mode could not be turned off: \(result.message)", level: "ERROR")
        }
    }

    // Asks the helper whether it is there.
    //
    // It is asked now and then, so that the window says what is really
    // going on: the helper may have been taken away by a person who knows
    // what they are doing, and the machine may have been restarted.
    func refresh() {
        let result = GatewayHelperClient.status()
        helperInstalled = result.ok
        if !result.ok {
            isRunning = false
            if !status.isEmpty, !status.contains("not installed") {
                status = result.message
            }
            return
        }
        let enabled = result.response.gatewayEnabled ?? false
        if enabled != isRunning {
            isRunning = enabled
            status = enabled
                ? L10n.t("The gateway mode is on.")
                : L10n.t("The gateway mode is off.")
        }
        // what the traffic of the network has carried so far
        carriedConnections = dataPlane.statistics.connections
    }

    // How often the helper is asked.
    private let pollInterval: TimeInterval = 3.0

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            // The timer runs on the main thread, and the window belongs to the
            // main thread. The jump is written down, so that the compiler
            // does not have to guess where the line is written.
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func log(_ message: String, level: String) {
        logHandler?(message, level)
    }
}
