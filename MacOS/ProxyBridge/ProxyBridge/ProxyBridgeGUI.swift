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
    // the language of the app. the menus are built again when it changes, so a
    // language can be picked without restarting the app
    @StateObject private var localization = LocalizationManager.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    // when on, closing the window hides the app to the menu bar instead of quitting
    @AppStorage("closeToMenuBar") private var closeToMenuBar = false
    // when on (the default), closing the window leaves the app and the proxy
    // running in the background. the window comes back from the dock icon or
    // from the menu bar item.
    @AppStorage("keepProxyRunningInBackground") private var keepProxyRunningInBackground = true

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                // The window needs a title bar of its own, otherwise there is
                // nothing to take hold of: the window cannot be moved. A strip
                // the app draws itself is only a picture of a title bar.
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Text("ProxyBridge")
                            .font(.headline)
                    }
                }
                .background(WindowAccessor())
                .onAppear {
                    AppDelegate.viewModel = viewModel
                    checkForUpdatesOnStartup()
                }
                .onChange(of: localization.language) { _ in
                    // the menus are built again when the language changes, and
                    // the system writes its own titles into them
                    StandardMenuLocalizer.applySoon()
                }
                .onChange(of: viewModel.needsExtensionApproval) { needsApproval in
                    // The first time this happens it deserves a dialog, so it is not
                    // missed. After that the notice in the window is enough: a dialog
                    // on every launch is worse than the problem it describes.
                    guard needsApproval,
                          !UserDefaults.standard.bool(forKey: "extensionApprovalPromptShown") else { return }
                    UserDefaults.standard.set(true, forKey: "extensionApprovalPromptShown")
                    showExtensionApprovalAlert()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
            
            CommandMenu(L10n.t("Proxy")) {
                Button(L10n.t("Proxy Settings...")) {
                    openProxySettingsWindow()
                }
                .keyboardShortcut(",", modifiers: .command)
                
                Button(L10n.t("Proxy Rules...")) {
                    openProxyRulesWindow()
                }
                .keyboardShortcut("r", modifiers: .command)

                Button(L10n.t("Proxy Chains...")) {
                    openProxyChainsWindow()
                }

                Button(L10n.t("DNS Settings...")) {
                    openDNSSettingsWindow()
                }

                Divider()
                
                Toggle(L10n.t("Enable Traffic Logging"), isOn: Binding(
                    get: { viewModel.isTrafficLoggingEnabled },
                    set: { _ in viewModel.toggleTrafficLogging() }
                ))

                // saved in the profile. off: ProxyBridge does not use the system DNS proxy, so another
                // tool can use it, and host name rules and send hostname stop working
                Toggle(L10n.t("Enable DNS"), isOn: Binding(
                    get: { viewModel.isDNSEnabled },
                    set: { _ in viewModel.toggleDNS() }
                ))
            }

            CommandMenu(L10n.t("Profile")) {
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

                Button(L10n.t("New Profile...")) {
                    promptProfileName(title: L10n.t("New Profile"), message: L10n.t("Enter a name for the new profile.")) {
                        viewModel.createProfile($0)
                    }
                }

                Button(L10n.f("Rename \"%@\"...", viewModel.activeProfile)) {
                    promptProfileName(title: L10n.t("Rename Profile"), message: L10n.t("Enter a new name."), defaultText: viewModel.activeProfile) {
                        viewModel.renameProfile(viewModel.activeProfile, to: $0)
                    }
                }

                Button(L10n.f("Delete \"%@\"", viewModel.activeProfile)) {
                    viewModel.deleteProfile(viewModel.activeProfile)
                }
                .disabled(viewModel.profiles.count <= 1)

                Divider()

                Button(L10n.f("Export \"%@\"...", viewModel.activeProfile)) {
                    exportActiveProfile()
                }

                Button(L10n.t("Import Profile...")) {
                    importProfileFromFile()
                }
            }

            CommandMenu(L10n.t("Settings")) {
                Toggle(L10n.t("Close to Menu Bar"), isOn: $closeToMenuBar)
                // closing the window does not stop the proxy. the app stays in
                // the background and the tunnel keeps running until it is
                // stopped in the window or the app is quit.
                Toggle(L10n.t("Keep Proxy Running in Background"), isOn: $keepProxyRunningInBackground)
                Toggle(L10n.t("Run at Startup"), isOn: Binding(
                    get: { LoginItem.isEnabled },
                    set: { LoginItem.setEnabled($0) }
                ))

                Divider()

                // the language of the app. english and chinese for now
                //
                // the two languages are two entries of the menu and not a menu
                // of their own. a submenu in a menu bar menu only opens when
                // the pointer rests on it, and a person who moves the pointer
                // too fast gets a submenu that closes again before it can be
                // read. an entry that is right there cannot be missed.
                Divider()

                ForEach(L10n.Language.allCases) { language in
                    Button {
                        localization.language = language
                    } label: {
                        // a checkmark marks the language the app is in
                        if language == localization.language {
                            Label(language.displayName, systemImage: "checkmark")
                        } else {
                            Text(language.displayName)
                        }
                    }
                }

                // the four menus of the menu bar are drawn by SwiftUI itself and
                // not out of the menu, so they keep the language of the bundle
                // until the app is started again. the person should know that,
                // otherwise it looks like the change did not work
                Divider()

                Text(L10n.t("The menus macOS draws itself (Edit, View, Window, Help) change to the new language the next time ProxyBridge starts."))
                    .foregroundColor(.secondary)

                Divider()

                Button(L10n.t("Approve ProxyBridge in System Settings...")) {
                    openSystemSettingsForExtension()
                }

                Button(L10n.t("Take Out Older ProxyBridge Extensions...")) {
                    showRemoveOldExtensionsHint()
                }
            }

            CommandGroup(replacing: .help) {
                Button(L10n.t("Documentation")) {
                    if let url = URL(string: "https://interceptsuite.com/docs/proxybridge/") {
                        NSWorkspace.shared.open(url)
                    }
                }

                Button(L10n.t("Check for Updates...")) {
                    openUpdateCheckWindow()
                }

                Divider()

                Button(L10n.t("About ProxyBridge")) {
                    openAboutWindow()
                }
            }
        }
        
        Window(L10n.t("Proxy Settings"), id: "proxy-settings") {
            ProxySettingsView(viewModel: viewModel)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        
        Window(L10n.t("Proxy Rules"), id: "proxy-rules") {
            ProxyRulesView(viewModel: viewModel)
        }
        .defaultPosition(.center)
        
        Window(L10n.t("About ProxyBridge"), id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        
        Window(L10n.t("Check for Updates"), id: "update-check") {
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
        panel.title = L10n.t("Export Profile")
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
        panel.title = L10n.t("Import Profile")
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
        alert.messageText = L10n.f("Imported '%@'", profileName)
        alert.informativeText = L10n.f("%@ proxy server(s), %@ rule(s) and %@ chain(s) were imported.\n\nSome Proxifier settings have no counterpart in ProxyBridge. Here is what was done with them:", "\(proxies)", "\(rules)", "\(chains)")
        alert.accessoryView = makeNotesView(notes)
        alert.addButton(withTitle: L10n.t("OK"))
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
        alert.messageText = L10n.t("ProxyBridge needs your approval")
        alert.informativeText = L10n.t("Open System Settings > General > Login Items & Extensions > Network Extensions, and switch ProxyBridge on.\n\nUntil that is done, no traffic can be proxied.")
        alert.addButton(withTitle: L10n.t("Open System Settings"))
        alert.addButton(withTitle: L10n.t("Later"))
        if alert.runModal() == .alertFirstButtonReturn { openSystemSettingsForExtension() }
    }

    // the pane where the system extension is switched on (macOS 13 and later keep the
    // network extensions inside Login Items & Extensions)
    private func openSystemSettingsForExtension() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    // An older ProxyBridge extension can stay registered under the same bundle id.
    // The system may then bind the tunnel to it, and that one speaks an older
    // protocol: the rules and the proxies never arrive, so nothing is proxied.
    // Taking it out needs root, so the command goes on the clipboard and the user
    // runs it in a terminal.
    private func showRemoveOldExtensionsHint() {
        let command = ExtensionDiagnosis.removeOldExtensionsCommand
        let alert = NSAlert()
        alert.messageText = L10n.t("Take the older ProxyBridge extensions out")
        alert.informativeText = L10n.t("Run this in the Terminal. It removes the ProxyBridge extensions that were signed by another team, so the system can only use this build.\n\nAfter that, switch ProxyBridge on in System Settings > General > Login Items & Extensions > Network Extensions.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 460, height: 44))
        field.stringValue = command
        field.isEditable = false
        field.isSelectable = true
        field.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        field.backgroundColor = NSColor.textBackgroundColor
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.t("Copy Command"))
        alert.addButton(withTitle: L10n.t("Close"))
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
        }
    }

    // small AppKit text prompt, SwiftUI has no clean text-input alert on macOS
    private func promptProfileName(title: String, message: String, defaultText: String = "", onSubmit: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: L10n.t("OK"))
        alert.addButton(withTitle: L10n.t("Cancel"))

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

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    static var viewModel: ProxyBridgeViewModel?
    static var pendingUpdateInfo: VersionInfo?
    static weak var shared: AppDelegate?
    // the main window is kept on purpose: when the window is closed and the
    // proxy keeps running, this is how the window comes back. a weak
    // reference would be gone by then, and swiftui has no way to open the
    // window of a group without an id.
    static var mainWindow: NSWindow?
    // set at launch, tells WindowAccessor to keep the first window hidden
    static var startHidden = false

    private var statusItem: NSStatusItem?

    private var closeToMenuBar: Bool { UserDefaults.standard.bool(forKey: "closeToMenuBar") }

    // closing the window leaves the app and the proxy running. this is on
    // unless the user says otherwise: a proxy that stops when the window is
    // closed is a proxy that stops in the middle of something.
    private var keepProxyRunningInBackground: Bool {
        UserDefaults.standard.object(forKey: "keepProxyRunningInBackground") as? Bool ?? true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        setupStatusItem()
        // the menus macOS brings itself are renamed, so that they speak the
        // language of the app. it is done here and not from the window: the
        // window can be hidden in the menu bar, and the menus are there even
        // then.
        StandardMenuLocalizer.install()
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

    // the app is opened again - from the dock, from Finder, from a second copy
    // of the command in a terminal - has to bring the window back.
    //
    // without this the app stays in the menu bar with no way to get to its
    // window: it runs as an accessory (no dock icon) once the window was
    // closed, and AppKit does nothing on a reopen when there is no dock icon
    // to click. the window is still there, it only has to be shown again.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    // close-to-menu-bar off: the window closes. whether the app quits with it
    // is the "keep the proxy running in the background" setting: on (the
    // default) the app stays and the tunnel keeps running, off quits.
    // when close-to-menu-bar is on, windowShouldClose hides the window instead
    // so this never fires.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === AppDelegate.mainWindow,
              !closeToMenuBar else { return }
        if keepProxyRunningInBackground {
            // the app stays alive, so the tunnel stays up. the window comes back
            // from the dock icon or from the menu bar item.
            return
        }
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
        menu.addItem(NSMenuItem(title: L10n.t("Open ProxyBridge"), action: #selector(showMainWindow), keyEquivalent: ""))
        menu.addItem(.separator())
        // the same setting as in the Settings menu, so that it can be reached
        // when the window is closed and the app only lives in the menu bar
        let keepItem = NSMenuItem(title: L10n.t("Keep Proxy Running in Background"),
                                  action: #selector(toggleKeepProxyRunning),
                                  keyEquivalent: "")
        keepItem.target = self
        keepItem.state = keepProxyRunningInBackground ? .on : .off
        menu.addItem(keepItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L10n.t("Quit ProxyBridge"), action: #selector(quitApp), keyEquivalent: "q"))
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    // the checkmark of the menu item follows the setting, also when it is
    // changed in the Settings menu of the app
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items where item.action == #selector(toggleKeepProxyRunning) {
            item.state = keepProxyRunningInBackground ? .on : .off
        }
    }

    @objc private func toggleKeepProxyRunning() {
        UserDefaults.standard.set(!keepProxyRunningInBackground, forKey: "keepProxyRunningInBackground")
    }

    @objc private func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        // the window is still there, it was only closed. bringing it back is
        // enough, swiftui does not make a second one.
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
        openWindow(title: L10n.t("Proxy Settings"), size: NSSize(width: 600, height: 500)) {
            ProxySettingsView(viewModel: AppDelegate.viewModel!)
        }
    }
    
    @objc func openProxyRules() {
        openWindow(title: L10n.t("Proxy Rules"), size: NSSize(width: 1200, height: 600), resizable: true) {
            ProxyRulesView(viewModel: AppDelegate.viewModel!)
        }
    }

    @objc func openProxyChains() {
        openWindow(title: L10n.t("Proxy Chains"), size: NSSize(width: 720, height: 460)) {
            ProxyChainsView(viewModel: AppDelegate.viewModel!)
        }
    }

    @objc func openDNSSettings() {
        openWindow(title: L10n.t("DNS Settings"), size: NSSize(width: 660, height: 660)) {
            DNSSettingsView(viewModel: AppDelegate.viewModel!)
        }
        // the window is reused, so the view has to be told that it is opened
        // again: it fills itself with the settings that are stored right now
        AppDelegate.viewModel?.noteDNSSettingsOpened()
    }
    
    @objc func openAbout() {
        openWindow(title: L10n.t("About ProxyBridge"), size: NSSize(width: 400, height: 350)) {
            AboutView()
        }
    }
    
    @objc func openUpdateCheck() {
        openWindow(title: L10n.t("Check for Updates"), size: NSSize(width: 450, height: 300)) {
            UpdateCheckView()
        }
    }
    
    @objc func showUpdateNotification(_ sender: Any?) {
        if let versionInfo = AppDelegate.pendingUpdateInfo {
            openWindow(title: L10n.t("Update Available"), size: NSSize(width: 450, height: 350)) {
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

