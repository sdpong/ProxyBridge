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
struct ProxiRouteGUIApp: App {
    @StateObject private var viewModel = ProxiRouteViewModel()
    // the language of the app. the menus are built again when it changes, so a
    // language can be picked without restarting the app
    @StateObject private var localization = LocalizationManager.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // The window has an id of its own.
        //
        // Why: a WindowGroup without an id makes a new window every time the
        // app is opened again. The window of the app was in the menu bar, and
        // coming back from the menu bar went through the reopen of the app,
        // so every time the window came back there was one more of it: they
        // were stacked on the screen, and the one that was not the main window
        // was never closed. With an id there is one window, and it is the same
        // one every time.
        WindowGroup(id: "main") {
            ContentView(viewModel: viewModel)
                // The window needs a title bar of its own, otherwise there is
                // nothing to take hold of: the window cannot be moved. A strip
                // the app draws itself is only a picture of a title bar.
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Text("ProxiRoute")
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

            // The view menu is emptied at the source.
            //
            // macOS 26 puts a view menu into the menu bar of every app that
            // has a toolbar, and it is filled with the commands of the toolbar
            // and of the sidebar. This app has a toolbar with a title in it
            // and no sidebar, so the menu is a list of things that are not
            // there. Taking the commands out empties the menu.
            //
            // The menu itself is hidden by StandardMenuLocalizer, and it has
            // to be hidden there: taking a menu item out of the menu bar at
            // runtime does not work, because SwiftUI builds the menu bar
            // again as soon as it is touched, and the view menu is in it again
            // a moment later.
            CommandGroup(replacing: .toolbar) { }
            CommandGroup(replacing: .sidebar) { }

            // The edit menu is left to macOS.
            //
            // The system brings the editing commands itself - undo, redo,
            // cut, copy, paste, delete and select all - and they are the
            // ones that work with the log window and with the fields of the
            // windows. On macOS 26 the system put a row of things into that
            // menu as well that have nothing to do with editing: the contact
            // card, the passwords, the credit card, dictation and the emoji
            // picker. A proxy that shows a log has no use for any of them,
            // and they are taken out (see StandardMenuLocalizer).
            //
            // The items are not put in again here: the system adds a set of
            // its own whatever SwiftUI does, and two sets of undo and copy
            // in one menu is a menu that nobody can read.

            // The proxy menu and the settings menu are gone. Everything that
            // was in them is a setting, and a setting lives in the window
            // now - in the tab of the settings, where it can be seen and
            // changed next to the thing it belongs to.
            //
            // What is left of the menu bar is what belongs to the documents
            // (the profiles) and the help. A menu bar with three entries is
            // read at a glance.
            //
            // The settings are still one shortcut away, and the shortcut is
            // the one the proxy settings had before: the settings are what
            // a person opens the app for most of the time.
            CommandGroup(replacing: .appInfo) {
                Button(L10n.t("Settings...")) {
                    AppDelegate.shared?.openSettingsTab()
                }
                .keyboardShortcut(",", modifiers: .command)
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

            CommandGroup(replacing: .help) {
                Button(L10n.t("Documentation")) {
                    if let url = URL(string: "https://github.com/sdpong/ProxyBridge#readme") {
                        NSWorkspace.shared.open(url)
                    }
                }

                Button(L10n.t("Check for Updates...")) {
                    openUpdateCheckWindow()
                }

                Divider()

                Button(L10n.t("About ProxiRoute")) {
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
        
        Window(L10n.t("Gateway"), id: "routing") {
            RouteSettingsView(viewModel: viewModel)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window(L10n.t("Proxy Server"), id: "local-proxy-server") {
            LocalProxyServerView(viewModel: viewModel)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window(L10n.t("About ProxiRoute"), id: "about") {
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
        alert.informativeText = L10n.f("%@ proxy server(s), %@ rule(s) and %@ chain(s) were imported.\n\nSome Proxifier settings have no counterpart in ProxiRoute. Here is what was done with them:", "\(proxies)", "\(rules)", "\(chains)")
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
        alert.messageText = L10n.t("ProxiRoute needs your approval")
        alert.informativeText = L10n.t("Open System Settings > General > Login Items & Extensions > Network Extensions, and switch ProxiRoute on.\n\nUntil that is done, no traffic can be proxied.")
        alert.addButton(withTitle: L10n.t("Open System Settings"))
        alert.addButton(withTitle: L10n.t("Later"))
        if alert.runModal() == .alertFirstButtonReturn {
            NSApp.sendAction(#selector(AppDelegate.openSystemSettingsForExtension), to: nil, from: nil)
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
    static var viewModel: ProxiRouteViewModel?
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
    //
    // The answer is false, and that is the important part: the window is
    // brought back here, and saying "yes" to the system would let it make a
    // window of its own as well. Two windows of the app, stacked on the
    // screen, one of them never closed and one of them the wrong size - that
    // is what a person saw when they came back from the menu bar.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return false
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
        item.button?.image = NSImage(systemSymbolName: "network", accessibilityDescription: "ProxiRoute")

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: L10n.t("Open ProxiRoute"), action: #selector(showMainWindow), keyEquivalent: ""))
        menu.addItem(.separator())
        // the settings live in the window, and this is the way to them when
        // the window is not in front
        menu.addItem(NSMenuItem(title: L10n.t("Settings..."), action: #selector(openSettingsTab), keyEquivalent: ","))
        // what the app is doing right now. a person who looks into the menu
        // bar wants to know whether the proxy is running, and that is one
        // line instead of a guess.
        let state = NSMenuItem(title: stateTitle, action: nil, keyEquivalent: "")
        state.isEnabled = false
        // the line is found again when the menu is built again
        state.representedObject = "state"
        menu.addItem(state)
        menu.addItem(.separator())
        // the same setting as in the settings of the window, so that it can be
        // reached when the window is closed and the app only lives in the
        // menu bar
        let keepItem = NSMenuItem(title: L10n.t("Keep Proxy Running in Background"),
                                  action: #selector(toggleKeepProxyRunning),
                                  keyEquivalent: "")
        keepItem.target = self
        keepItem.state = keepProxyRunningInBackground ? .on : .off
        menu.addItem(keepItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L10n.t("Quit ProxiRoute"), action: #selector(quitApp), keyEquivalent: "q"))
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    // What the app is doing right now, in one line. The mode is the answer:
    // it says whether the traffic of this machine is taken over, and the
    // server says whether the clients of the network are waited for.
    private var stateTitle: String {
        guard let viewModel = AppDelegate.viewModel else { return L10n.t("Proxy: Off") }
        switch viewModel.runtimeMode {
        case .local, .gateway:
            // the traffic of this machine is taken over in every mode
            return viewModel.isProxyActive ? L10n.t("Proxy: On") : L10n.t("Proxy: Off")
        case .server:
            return viewModel.localProxyRunning ? L10n.t("Proxy Server: On") : L10n.t("Proxy Server: Off")
        }
    }

    // the checkmark of the menu item follows the setting, also when it is
    // changed in the Settings menu of the app
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items where item.action == #selector(toggleKeepProxyRunning) {
            item.state = keepProxyRunningInBackground ? .on : .off
        }
        // the line that says what the app is doing follows the mode
        for item in menu.items where (item.representedObject as? String) == "state" {
            item.title = stateTitle
        }
    }

    @objc private func toggleKeepProxyRunning() {
        UserDefaults.standard.set(!keepProxyRunningInBackground, forKey: "keepProxyRunningInBackground")
    }

    // The window comes back, and it shows the tab with the settings. The
    // settings are the tab a person wants when they come to the app to
    // change something.
    @objc func openSettingsTab() {
        showMainWindow()
        NotificationCenter.default.post(name: .proxirouteSelectTab, object: 3)
    }

    // The full screen of the window. It was in the view menu of macOS, and
    // that menu is gone: everything in it was about a sidebar or a toolbar,
    // and this app has none of them.
    @objc func toggleFullScreen() {
        guard let window = AppDelegate.mainWindow ?? NSApp.windows.first else { return }
        window.toggleFullScreen(nil)
    }

    @objc func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        // the window is still there, it was only closed. bringing it back is
        // enough, swiftui does not make a second one.
        AppDelegate.mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // the pane where the system extension is switched on (macOS 13 and later keep the
    // network extensions inside Login Items & Extensions)
    @objc func openSystemSettingsForExtension() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    // An older ProxiRoute extension can stay registered under the same bundle id.
    // The system may then bind the tunnel to it, and that one speaks an older
    // protocol: the rules and the proxies never arrive, so nothing is proxied.
    // Taking it out needs root, so the command goes on the clipboard and the user
    // runs it in a terminal.
    @objc func takeOutOlderExtensions() {
        let command = ExtensionDiagnosis.removeOldExtensionsCommand
        let alert = NSAlert()
        alert.messageText = L10n.t("Take the older ProxiRoute extensions out")
        alert.informativeText = L10n.t("Run this in the Terminal. It removes the ProxiRoute extensions that were signed by another team, so the system can only use this build.\n\nAfter that, switch ProxiRoute on in System Settings > General > Login Items & Extensions > Network Extensions.")
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

    @objc func openLocalProxyServer() {
        openWindow(title: L10n.t("Proxy Server"), size: NSSize(width: 640, height: 540)) {
            LocalProxyServerView(viewModel: AppDelegate.viewModel!)
        }
    }

    @objc func openGateway() {
        openWindow(title: L10n.t("Gateway"), size: NSSize(width: 620, height: 440)) {
            RouteSettingsView(viewModel: AppDelegate.viewModel!)
        }
    }

    @objc func openAbout() {
        openWindow(title: L10n.t("About ProxiRoute"), size: NSSize(width: 400, height: 350)) {
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
            // The size of the window is the size of the window, not the size of
            // what is in it.
            //
            // Without this the window follows the height of its content: the
            // pages of the settings are a scroll view, and a scroll view that
            // is given the whole height asks for all the height it needs. The
            // window was then taller than the screen, and it came back shorter
            // a moment later, when the system put it back into the screen.
            // A person opening the window from the menu bar saw it stretch and
            // then shrink.
            window.contentMinSize = NSSize(width: 800, height: 600)
            window.contentMaxSize = NSSize(width: 4000, height: 4000)
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

