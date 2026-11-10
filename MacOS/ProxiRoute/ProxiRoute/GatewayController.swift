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
    // whether the helper of the gateway mode is on the machine
    @Published private(set) var helperState: GatewayInstaller.State = .notInstalled
    // whether an installation is going on right now
    @Published private(set) var isInstalling = false
    // what the last installation said
    @Published private(set) var helperMessage: String = ""

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

    // Whether the switch of the gateway mode may be turned on.
    //
    // The helper is the program of root that does the part of the gateway
    // mode that needs root. Without it the switch would fail every time it
    // was turned on, so it is not offered in the first place.
    var canTurnOn: Bool {
        return GatewayInstaller.canTurnOn(helperState)
    }

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
        // The state of the helper is asked about before the state of the
        // switch. A remembered "on" without the helper is a switch that fails
        // at every start of the app, and there is nothing the person in front
        // of it can do about it, so such a state is not kept.
        let state = GatewayInstaller.state()
        helperState = state
        let stored = UserDefaults.standard.bool(forKey: GatewayController.storageKey)
        isEnabled = GatewayInstaller.initialGatewayState(stored: stored, state: state)
        if stored && !state.isInstalled {
            // the remembered state is one the machine cannot keep, so it is
            // not kept
            UserDefaults.standard.set(false, forKey: GatewayController.storageKey)
        }
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
        // The gateway mode needs the helper: it is the program of root that
        // loads the rules of the filter and turns the forwarding of the
        // machine on. Without it there is nobody to ask, and the switch goes
        // off again - a switch that stays on fails at every start of the app,
        // and the person in front of it can do nothing about it.
        let state = GatewayInstaller.state()
        helperState = state
        guard state.isInstalled else {
            isEnabled = false
            isRunning = false
            dataPlane.stop()
            status = L10n.t("The helper of the gateway mode is not installed. Install it with the button in this card.")
            log("The gateway mode could not be turned on: the helper of the gateway mode is not installed", level: "ERROR")
            startPolling()
            return
        }

        let name = interface.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            status = L10n.t("The gateway mode needs an interface: the network card the other terminals reach this machine through.")
            isRunning = false
            return
        }

        // The address the traffic of the network is redirected to.
        //
        // It is the address of this machine on that card, and not the
        // loopback: the answer of the filter has to come from the same place
        // the traffic was sent to, or the kernel does not recognise it as the
        // answer of the traffic it redirected.
        guard let redirectAddress = LocalAddresses.address(ofInterface: name) else {
            status = L10n.f("The interface %@ has no address on this network.", name)
            isRunning = false
            return
        }

        // The program that takes the traffic in has to be listening before the
        // rules of the filter are in place: a client whose connection is
        // redirected to a port that nobody listens on is a client with no
        // internet at all.
        switch dataPlane.start(address: redirectAddress) {
        case .failure(let failure):
            isRunning = false
            status = failure.reason
            log("The gateway mode could not be started: \(failure.reason)", level: "ERROR")
            return
        case .success:
            break
        }

        // The addresses of the proxies go with it: the traffic to a proxy
        // does not go through a proxy, or the proxy would be talking to
        // itself.
        let proxyHosts = proxies.map { $0.host }
        let result = GatewayHelperClient.enable(interface: name, redirectPort: GatewayDataPlane.redirectPort,
                                                redirectAddress: redirectAddress, proxyHosts: proxyHosts)
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
            // A helper that is not there is said in the words of the window,
            // and the words point at the button that puts it there. Anything
            // else is said in the words of the helper, which is the one that
            // knows what went wrong.
            status = GatewayInstaller.state().isInstalled
                ? result.message
                : L10n.t("The helper of the gateway mode is not installed. Install it with the button in this card.")
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
        refreshHelperState()
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

    // MARK: - the helper of the gateway mode

    // Asks whether the helper is on the machine.
    //
    // It is a file and a socket, and neither of them needs root to be read:
    // the folder of the privileged helper tools can be read by anybody, and
    // the socket is for the people of the machine.
    func refreshHelperState() {
        helperState = GatewayInstaller.state()
    }

    // Puts the helper of the gateway mode in place.
    //
    // It needs the password of an administrator, and macOS asks for it in the
    // dialog of the administrator. The app cannot be a program of root
    // itself: it is signed ad hoc, and the system does not trust an app
    // without a team to run something as root.
    func installHelper() {
        guard !isInstalling else { return }
        isInstalling = true
        helperMessage = ""
        let appPath = Bundle.main.bundlePath
        GatewayInstaller.install(appPath: appPath) { [weak self] result in
            Task { @MainActor [weak self] in
                self?.finishInstall(result)
            }
        }
    }

    // Takes the helper of the gateway mode out of the machine.
    //
    // The machine goes back the way it was first, and only then is the helper
    // taken away: a helper that is taken away while its rules are in place
    // leaves the traffic of the network being redirected to a port where
    // nobody listens.
    func uninstallHelper() {
        guard !isInstalling else { return }
        isInstalling = true
        helperMessage = ""
        // The gateway goes off first, the way it goes off when the switch is
        // turned off: the rules of the filter go back before the helper is
        // taken away. The script does it as well, but the app asks its own
        // helper, so that the app and the machine agree.
        _ = GatewayHelperClient.disable()
        GatewayInstaller.uninstall { [weak self] result in
            Task { @MainActor [weak self] in
                self?.finishUninstall(result)
            }
        }
    }

    // What the installation said.
    private func finishInstall(_ result: GatewayInstaller.Result) {
        isInstalling = false
        refreshHelperState()
        if result.ok {
            helperMessage = L10n.t("The helper of the gateway mode is installed.")
            log("The helper of the gateway mode was installed", level: "INFO")
        } else {
            helperMessage = result.message
            log("The helper of the gateway mode could not be installed: \(result.message)", level: "ERROR")
        }
    }

    // What the removal said.
    private func finishUninstall(_ result: GatewayInstaller.Result) {
        isInstalling = false
        // the program stops listening as well: the rules of the filter are
        // gone, so nothing comes in any more
        dataPlane.stop()
        isRunning = false
        // the switch goes off with the helper: there is nothing left to turn
        // it on, and a switch that stays on is a switch that fails at every
        // start of the app.
        //
        // The helper is said to be gone before the switch is turned off, so
        // that the turning off does not ask a helper that is not there to
        // take the rules of the machine back.
        helperInstalled = false
        isEnabled = false
        refreshHelperState()
        if result.ok {
            helperMessage = L10n.t("The helper of the gateway mode is gone.")
            log("The helper of the gateway mode was taken out", level: "INFO")
        } else {
            helperMessage = result.message
            log("The helper of the gateway mode could not be taken out: \(result.message)", level: "ERROR")
        }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            // The timer runs on the main thread, and the window belongs to the
            // main thread. The jump is written down, so that the compiler
            // does not have to guess where the line is written. The weak
            // reference is taken inside the task, so that nothing that
            // changes is shared between the threads.
            Task { @MainActor [weak self] in
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
