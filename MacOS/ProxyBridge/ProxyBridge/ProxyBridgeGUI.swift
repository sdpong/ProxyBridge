import SwiftUI
import UniformTypeIdentifiers
import ServiceManagement

// launch-at-login. the desired state lives in the "runAtStartup" working key so
// it can be part of a profile, and applyToSystem keeps the real login item in sync
enum LoginItem {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "runAtStartup") }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "runAtStartup")
        applyToSystem(enabled)
    }

    static func applyToSystem(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if enabled, SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            } else if !enabled, SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // registration can fail if the app isn't in /Applications, ignore
        }
    }
}

// no @main here, main.swift starts this for a normal launch (and the command line mode otherwise)
struct ProxyBridgeGUIApp: App {
    @StateObject private var viewModel = ProxyBridgeViewModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    // when on, closing the window hides the app to the menu bar instead of quitting
    @AppStorage("closeToMenuBar") private var closeToMenuBar = false

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .background(WindowAccessor())
                .onAppear {
                    AppDelegate.viewModel = viewModel
                    checkForUpdatesOnStartup()
                }
                .onChange(of: viewModel.needsExtensionApproval) { _ in
                    // macOS needs the user to switch the extension on once. Without it
                    // nothing is proxied, so say where the switch is and open the pane.
                    if viewModel.needsExtensionApproval { showExtensionApprovalAlert() }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
            
            CommandMenu("Proxy") {
                Button("Proxy Settings...") {
                    openProxySettingsWindow()
                }
                .keyboardShortcut(",", modifiers: .command)
                
                Button("Proxy Rules...") {
                    openProxyRulesWindow()
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("Proxy Chains...") {
                    openProxyChainsWindow()
                }

                Button("DNS Settings...") {
                    openDNSSettingsWindow()
                }

                Divider()
                
                Toggle("Enable Traffic Logging", isOn: Binding(
                    get: { viewModel.isTrafficLoggingEnabled },
                    set: { _ in viewModel.toggleTrafficLogging() }
                ))

                // saved in the profile. off: ProxyBridge does not use the system DNS proxy, so another
                // tool can use it, and host name rules and send hostname stop working
                Toggle("Enable DNS", isOn: Binding(
                    get: { viewModel.isDNSEnabled },
                    set: { _ in viewModel.toggleDNS() }
                ))
            }

            CommandMenu("Profile") {
                ForEach(viewModel.profiles, id: \.self) { name in
                    Button(action: { viewModel.switchProfile(to: name) }) {
                        // checkmark marks the active profile
                        if name == viewModel.activeProfile {
                            Label(name, systemImage: "checkmark")
                        } else {
                            Text(name)
                        }
                    }
                }

                Divider()

                Button("New Profile...") {
                    promptProfileName(title: "New Profile", message: "Enter a name for the new profile.") {
                        viewModel.createProfile($0)
                    }
                }

                Button("Rename \"\(viewModel.activeProfile)\"...") {
                    promptProfileName(title: "Rename Profile", message: "Enter a new name.", defaultText: viewModel.activeProfile) {
                        viewModel.renameProfile(viewModel.activeProfile, to: $0)
                    }
                }

                Button("Delete \"\(viewModel.activeProfile)\"") {
                    viewModel.deleteProfile(viewModel.activeProfile)
                }
                .disabled(viewModel.profiles.count <= 1)

                Divider()

                Button("Export \"\(viewModel.activeProfile)\"...") {
                    exportActiveProfile()
                }

                Button("Import Profile...") {
                    importProfileFromFile()
                }
            }

            CommandMenu("Settings") {
                Toggle("Close to Menu Bar", isOn: $closeToMenuBar)
                Toggle("Run at Startup", isOn: Binding(
                    get: { LoginItem.isEnabled },
                    set: { LoginItem.setEnabled($0) }
                ))

                Divider()

                Button("Approve ProxyBridge in System Settings...") {
                    openSystemSettingsForExtension()
                }
            }

            CommandGroup(replacing: .help) {
                Button("Documentation") {
                    if let url = URL(string: "https://interceptsuite.com/docs/proxybridge/") {
                        NSWorkspace.shared.open(url)
                    }
                }

                Button("Check for Updates...") {
                    openUpdateCheckWindow()
                }

                Divider()

                Button("About ProxyBridge") {
                    openAboutWindow()
                }
            }
        }
        
        Window("Proxy Settings", id: "proxy-settings") {
            ProxySettingsView(viewModel: viewModel)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        
        Window("Proxy Rules", id: "proxy-rules") {
            ProxyRulesView(viewModel: viewModel)
        }
        .defaultPosition(.center)
        
        Window("About ProxyBridge", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        
        Window("Check for Updates", id: "update-check") {
            UpdateCheckView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
    
    private func openProxySettingsWindow() {
        NSApp.sendAction(#selector(AppDelegate.openProxySettings), to: nil, from: nil)
    }
    
    private func openProxyRulesWindow() {
        NSApp.sendAction(#selector(AppDelegate.openProxyRules), to: nil, from: nil)
    }

    private func openDNSSettingsWindow() {
        NSApp.sendAction(#selector(AppDelegate.openDNSSettings), to: nil, from: nil)
    }

    private func openProxyChainsWindow() {
        NSApp.sendAction(#selector(AppDelegate.openProxyChains), to: nil, from: nil)
    }
    
    private func openAboutWindow() {
        NSApp.sendAction(#selector(AppDelegate.openAbout), to: nil, from: nil)
    }
    
    private func openUpdateCheckWindow() {
        NSApp.sendAction(#selector(AppDelegate.openUpdateCheck), to: nil, from: nil)
    }

    private func exportActiveProfile() {
        let name = viewModel.activeProfile
        guard let data = viewModel.exportProfileData(name) else { return }
        let panel = NSSavePanel()
        panel.title = "Export Profile"
        panel.nameFieldStringValue = "\(name).pbprofile"
        if let type = UTType(filenameExtension: "pbprofile") {
            panel.allowedContentTypes = [type]
        }
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url)
        }
    }

    private func importProfileFromFile() {
        let panel = NSOpenPanel()
        panel.title = "Import Profile"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        var types: [UTType] = [.json]
        if let pb = UTType(filenameExtension: "pbprofile") { types.insert(pb, at: 0) }
        // a Proxifier profile (.ppx) is read too
        if let ppx = UTType(filenameExtension: "ppx") { types.insert(ppx, at: 0) }
        panel.allowedContentTypes = types
        if panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) {
            let name = url.deletingPathExtension().lastPathComponent
            if viewModel.importProfile(from: data, name: name) {
                // what could not be carried over is said out loud, not dropped silently
                let notes = viewModel.lastImportNotes
                if !notes.isEmpty { showImportNotes(profileName: name, notes: notes) }
            }
        }
    }

    // The import says what could not be carried over. The notes go into a scrollable
    // text view of their own: an NSAlert puts a long informative text into a grey box
    // that reads like a disabled field, and the notes are often longer than fits.
    private func showImportNotes(profileName: String, notes: [String]) {
        let proxies = viewModel.proxyConfigs.count
        let rules = UserDefaults.standard.array(forKey: "proxyRules")?.count ?? 0
        let chains = viewModel.chains.count

        let alert = NSAlert()
        alert.messageText = "Imported '\(profileName)'"
        alert.informativeText = "\(proxies) proxy server(s), \(rules) rule(s) and \(chains) chain(s) were imported.\n\nSome Proxifier settings have no counterpart in ProxyBridge. Here is what was done with them:"
        alert.accessoryView = makeNotesView(notes)
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // the notes, in a scrollable box that can be read to the end and copied
    private func makeNotesView(_ notes: [String]) -> NSView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 170))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = false

        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.font = NSFont.systemFont(ofSize: 11)
        text.string = notes.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")
        text.textContainerInset = NSSize(width: 6, height: 8)
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        return scroll
    }

    // macOS asks for a one-time approval of the system extension. Nothing can be
    // proxied until the user switches it on, so say where the switch is and open the
    // pane for them.
    private func showExtensionApprovalAlert() {
        let alert = NSAlert()
        alert.messageText = "ProxyBridge needs your approval"
        alert.informativeText = "Open System Settings > General > Login Items & Extensions > Network Extensions, and switch ProxyBridge on.\n\nUntil that is done, no traffic can be proxied."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn { openSystemSettingsForExtension() }
    }

    // the pane where the system extension is switched on (macOS 13 and later keep the
    // network extensions inside Login Items & Extensions)
    private func openSystemSettingsForExtension() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    // small AppKit text prompt, SwiftUI has no clean text-input alert on macOS
    private func promptProfileName(title: String, message: String, defaultText: String = "", onSubmit: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = defaultText
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        if alert.runModal() == .alertFirstButtonReturn {
            onSubmit(field.stringValue)
        }
    }

    private func checkForUpdatesOnStartup() {
        let shouldCheck = UserDefaults.standard.object(forKey: "checkForUpdatesOnStartup") as? Bool ?? true
        
        if shouldCheck {
            Task {
                let updateService = UpdateService()
                let versionInfo = await updateService.checkForUpdates()
                
                if versionInfo.isUpdateAvailable {
                    await MainActor.run {
                        AppDelegate.pendingUpdateInfo = versionInfo
                        NSApp.sendAction(#selector(AppDelegate.showUpdateNotification(_:)), to: nil, from: nil)
                    }
                }
            }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static var viewModel: ProxyBridgeViewModel?
    static var pendingUpdateInfo: VersionInfo?
    static weak var shared: AppDelegate?
    static weak var mainWindow: NSWindow?
    // set at launch, tells WindowAccessor to keep the first window hidden
    static var startHidden = false

    private var statusItem: NSStatusItem?

    private var closeToMenuBar: Bool { UserDefaults.standard.bool(forKey: "closeToMenuBar") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        setupStatusItem()
        // keep the real login item in sync with the active profile's setting
        LoginItem.applyToSystem(LoginItem.isEnabled)

        // a login-item / resume launch is not a "default" launch. if we got here
        // that way and startup is enabled, come up in the menu bar with no window
        let isDefaultLaunch = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        if !isDefaultLaunch && LoginItem.isEnabled {
            AppDelegate.startHidden = true
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // never let AppKit decide this. it counts every window, including the one
    // behind the menu bar item, and on macOS 26 dismissing that menu looks like
    // the last window closing, so the app quit when you clicked away from it
    // (#233). the main window's own close decides instead, see windowWillClose.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // close-to-menu-bar off: closing the main window quits, matching the windows
    // "close = exit" behavior. when on, windowShouldClose hides the window instead
    // so this never fires.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === AppDelegate.mainWindow,
              !closeToMenuBar else { return }
        NSApp.terminate(nil)
    }

    // the window's close button, hide to the menu bar instead of closing when enabled
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard closeToMenuBar else { return true }
        sender.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)  // drop the dock icon, live in the menu bar
        return false
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "network", accessibilityDescription: "ProxyBridge")

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open ProxyBridge", action: #selector(showMainWindow), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit ProxyBridge", action: #selector(quitApp), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    @objc private func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        AppDelegate.mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Clear extension memory before app quits
        AppDelegate.viewModel?.stopProxy()

        // Give time for memory clearing to complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.reply(toApplicationShouldTerminate: true)
        }

        return .terminateLater
    }
    
    @objc func openProxySettings() {
        openWindow(title: "Proxy Settings", size: NSSize(width: 600, height: 500)) {
            ProxySettingsView(viewModel: AppDelegate.viewModel!)
        }
    }
    
    @objc func openProxyRules() {
        openWindow(title: "Proxy Rules", size: NSSize(width: 1200, height: 600), resizable: true) {
            ProxyRulesView(viewModel: AppDelegate.viewModel!)
        }
    }

    @objc func openProxyChains() {
        openWindow(title: "Proxy Chains", size: NSSize(width: 720, height: 460)) {
            ProxyChainsView(viewModel: AppDelegate.viewModel!)
        }
    }

    @objc func openDNSSettings() {
        openWindow(title: "DNS Settings", size: NSSize(width: 620, height: 560)) {
            DNSSettingsView(viewModel: AppDelegate.viewModel!)
        }
    }
    
    @objc func openAbout() {
        openWindow(title: "About ProxyBridge", size: NSSize(width: 400, height: 350)) {
            AboutView()
        }
    }
    
    @objc func openUpdateCheck() {
        openWindow(title: "Check for Updates", size: NSSize(width: 450, height: 300)) {
            UpdateCheckView()
        }
    }
    
    @objc func showUpdateNotification(_ sender: Any?) {
        if let versionInfo = AppDelegate.pendingUpdateInfo {
            openWindow(title: "Update Available", size: NSSize(width: 450, height: 350)) {
                UpdateNotificationView(versionInfo: versionInfo)
            }
            AppDelegate.pendingUpdateInfo = nil
        }
    }
    
    private func openWindow<Content: View>(
        title: String,
        size: NSSize,
        resizable: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        if let window = NSApplication.shared.windows.first(where: { $0.title == title }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            let controller = NSHostingController(rootView: content())
            let window = NSWindow(contentViewController: controller)
            window.title = title
            window.setContentSize(size)
            window.styleMask = resizable ? [.titled, .closable, .resizable] : [.titled, .closable]
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
    }
}

// grabs the main SwiftUI window so the app delegate can intercept its close
struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            AppDelegate.mainWindow = window
            window.delegate = AppDelegate.shared
            // launched at login, keep it hidden in the menu bar
            if AppDelegate.startHidden {
                AppDelegate.startHidden = false
                window.orderOut(nil)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

