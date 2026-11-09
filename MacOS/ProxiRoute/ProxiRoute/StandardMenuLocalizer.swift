import AppKit
import Foundation

// The items of the menus that macOS brings itself: Undo, Redo, Cut, Copy,
// Paste, Delete, Select All, Minimize, Zoom, Bring All to Front, and the
// items of the application menu.
//
// Their titles come from the localization of the app bundle. This app has no
// bundle of resources - the strings live in L10n.swift instead - so the system
// has nothing to translate them with and leaves them in English, while the
// rest of the app speaks the language that was chosen in it.
//
// They are renamed here instead, so that they follow the same language as
// everything else.
//
// The renaming cannot be a one time thing. SwiftUI builds the menu bar again
// whenever something in the app changes, and it writes its own titles into it
// again - "Undo" and "Cut" come back in English every time. So the menus are
// watched: every change of an item is answered with a renaming of everything
// that has to be renamed. That way the title is right at the moment it is
// looked at, and not only at the moment the app started.
//
// The four menus of the menu bar itself (Edit, View, Window, Help) are drawn
// by SwiftUI and not out of the menu, so they cannot be renamed here.
//
// ---------------------------------------------------------------- the window menu
//
// The window menu is left to macOS entirely. It is not changed here, not one
// item at a time and not as a whole.
//
// What was tried, and what it did:
//
//   - The items that macOS puts into the window menu - the ones that move and
//     resize the window, the ones of the tabs and of the window sets - were
//     taken out while the menu was drawn. macOS put them in again a moment
//     later, the menu of a person who was looking at it changed its height
//     again and again, and the shadow of the menu that was taller stayed on
//     the screen for a moment. That was the ghost that grew and then shrank.
//
//   - The window menu of macOS was put aside and a menu of the app took its
//     place. The menu bar of SwiftUI is drawn by SwiftUI, and it did not take
//     the item of the app: the menu bar showed no window menu at all, and the
//     app wrote the menu bar again every half a second, because writing the
//     menu bar is what made SwiftUI write it again. The ghost was not gone
//     and the window menu was gone.
//
// So the items of the window menu are not touched at all. The menu is drawn by
// macOS, it settles down after a moment, and it stays as it is while it is
// open.
//
// The items that do not belong to this app are taken out at the source, where
// nothing puts them back:
//
//   - the ones that move and resize the window are out of the commands of the
//     app - see CommandGroup(replacing: .windowArrangement) in ProxiRouteGUI,
//   - the ones of the tabs and of the window sets are not there, because the
//     window of the app is not a tab and is not in a window set - see
//     WindowAccessor and NSWindow.allowsAutomaticWindowTabbing.
//
// What is left in the window menu is what macOS puts there and what belongs
// to the app: the items that open the windows of the app, and the ones that
// minimize, zoom and bring the windows to the front.
//
// The shape of the menu is looked at from time to time, and what does not
// belong to the app is written into the log. The log is the place where the
// answer is to be found: when the menu of a person is full of items that
// nobody put there, the log says which ones they were.
//
// Two of the menus go away anyway: the view menu (everything in it was about
// a sidebar or a toolbar, and this app has none) and the edit menu (it is a
// list of the editing keys, and the keys keep working without it - see
// installEditShortcuts). What is left of the menu bar is the app, the
// profiles, the window and the help.
enum StandardMenuLocalizer {

    // The name of the app, as the system menus put it in their titles.
    private static var appName: String {
        return Bundle.main.infoDictionary?["CFBundleName"] as? String
            ?? Bundle.main.infoDictionary?["CFBundleExecutable"] as? String
            ?? "ProxiRoute"
    }

    // One title of a system menu.
    //
    // The system writes the English one when the app has no localization, and
    // the Chinese one when the system language is Chinese. Both are
    // recognized, so that the menus can be renamed in either direction.
    private struct Title {
        let english: String
        let chinese: String
        // the text that is written into the menu
        let text: String

        func matches(_ title: String) -> Bool {
            return title == english || title == chinese
        }
    }

    // The titles of the items of the application menu.
    private static var appMenuTitles: [Title] {
        let name = appName
        return [
            Title(english: "About \(name)", chinese: "关于\(name)", text: L10n.f("About %@", name)),
            Title(english: "Hide \(name)", chinese: "隐藏\(name)", text: L10n.f("Hide %@", name)),
            Title(english: "Hide Others", chinese: "隐藏其他", text: L10n.t("Hide Others")),
            Title(english: "Show All", chinese: "显示全部", text: L10n.t("Show All")),
            Title(english: "Services", chinese: "服务", text: L10n.t("Services")),
            Title(english: "Quit \(name)", chinese: "退出\(name)", text: L10n.f("Quit %@", name))
        ]
    }

    // The titles of the items that macOS puts into the window menu and that
    // this app does not want in it.
    //
    // They are the items of macOS 26 and 27 that change the size or the place
    // of the window - close, minimize, zoom, fill, center, move and resize,
    // the tiles - and the items of the tabs and of the window sets. They are
    // grey in this app: the app has a single window and no row of tabs, and
    // a grey item is a promise that is never kept.
    //
    // The titles are in a file of their own, so that the tests can look at
    // them without the whole app around it.
    private static var windowNoiseTitles: [Title] {
        // Every title of the list is a title on its own: the list holds the
        // english words and the chinese words of every item, one after the
        // other, and a title matches when it is one of them.
        return windowMenuNoiseTitles.sorted().map { title in
            Title(english: title, chinese: title, text: "")
        }
    }

    // Renames the titles of the menus of the app.
    //
    // The window menu is not touched here: see the note at the top.
    private static func renameMenus() {
        guard let menu = NSApp.mainMenu else { return }
        // the application menu is the first one, its items are about the app
        if let appMenu = menu.items.first?.submenu {
            rename(appMenu, with: appMenuTitles)
        }
        hideViewMenu(menu)
        hideEditMenu(menu)
    }

    // Renames the system menus in the menu bar of the app.
    //
    // It is safe to call it more than once: a title that is already the one
    // that is wanted is left alone.
    static func apply() {
        // A menu that is being drawn must not be changed.
        //
        // A menu that changes while it is drawn is drawn again, and the
        // picture of it jumps: the shape of the old one stays on the screen
        // for a moment - the shadow of a menu that was taller - and the menu
        // shrinks into the new one. That is the ghost that was seen under the
        // dropdown of the window menu, and the shiver that went with it.
        //
        // So the menus are left alone while one of them is drawn, and the
        // work is done as soon as the menu is closed.
        guard tracking == 0 else {
            pending = true
            return
        }
        applyNow()
    }

    // Renames the titles of the menus.
    private static func applyNow() {
        // the renaming writes titles, and a written title is a change of an
        // item, and a change of an item is what brings the renaming here.
        // without this the two would call each other without end.
        guard !applying else { return }
        applying = true
        defer { applying = false }

        guard let menu = NSApp.mainMenu else { return }

        // The titles of the menus of the menu bar itself are left alone.
        //
        // They are drawn by SwiftUI, and SwiftUI draws the menu bar again
        // whenever something in it changes - and it writes its own titles
        // into it again. A title written here is therefore gone a moment
        // later, and the writing of it is a change of the menu bar, which is
        // what makes SwiftUI draw it again. The language of those menus is the
        // language of the bundle, and the bundle keeps the language the app
        // was started with.

        // the application menu is the first one, its items are about the app
        if let appMenu = menu.items.first?.submenu {
            rename(appMenu, with: appMenuTitles)
        }

        // the view menu goes, and the edit menu goes as well. the keys are
        // still there - see installEditShortcuts - but a menu that is a list
        // of keys is a menu nobody opens.
        hideViewMenu(menu)
        hideEditMenu(menu)

        // The window menu goes.
        //
        // It is drawn by macOS, and the items of macOS 26 and 27 that change
        // the size or the place of the window - fill, center, move and
        // resize, the tiles - and the items of the tabs and of the window sets
        // are in it every time it is drawn. They are grey in this app: the
        // app has one window and no row of tabs, and a grey item is a promise
        // that is never kept.
        //
        // They cannot be taken out of it: the menu that macOS paints is its
        // own, and what is taken out of the menu of the menu bar is put back
        // into it a moment later. So the menu itself goes, and the menu of
        // the app takes its place.
        //
        // It is hidden and not taken out, for the same reason as the view
        // menu and the edit menu: taking a menu out is a change of the menu
        // bar, and SwiftUI answers a change of the menu bar by building the
        // menu bar again - with the menu in it again.
        hideWindowMenu(menu)

        // What the menu bar looks like right now. It is written only when it
        // changed, because the names of the menus are different on every
        // system and the log is the place where that shows.
        let titles = menu.items.filter { !$0.isHidden }.map { $0.title }.joined(separator: " | ")
        if titles != lastTitles {
            lastTitles = titles
            NSLog("[ProxiRoute] the menu bar: %@", titles)
        }

        // And what the window menu holds at the moment. It is only looked
        // at, never changed - see the note at the top.
        reportWindowMenu(menu)
    }

    // Writes what does not belong to the window menu of the app into the log.
    //
    // The menu of the app holds the windows of the app and nothing else, and
    // this is the check that it stays that way. It changes nothing: it reads
    // the menu and writes a line into the log when there is something in it
    // that does not belong there.
    private static func reportWindowMenu(_ menu: NSMenu) {
        guard let item = menu.items.first(where: { isWindowMenuOfTheApp($0) }),
              let submenu = item.submenu else { return }
        let noise = submenu.items
            .map { $0.title }
            .filter { title in windowNoiseTitles.contains(where: { $0.matches(title) }) }
        guard !noise.isEmpty else { return }
        let line = "the window menu holds \(noise.count) item(s) that do not belong to this app: \(noise.joined(separator: " | "))"
        if lastNoise != line {
            lastNoise = line
            NSLog("[ProxiRoute] %@", line)
            log(line)
        }
    }

    // Hides the window menu of macOS.
    //
    // The menu of the app takes its place - see CommandMenu(L10n.t("Window"))
    // in ProxiRouteGUI. Both are called "window", so they are told apart by
    // what is in them: the menu of macOS holds the items that move and
    // resize the window, and the menu of the app holds the windows of the
    // app.
    //
    // The menu is hidden and not taken out, for the same reason as the view
    // menu and the edit menu: taking a menu out is a change of the menu bar,
    // and SwiftUI answers a change of the menu bar by building the menu bar
    // again - with the menu in it again.
    private static func hideWindowMenu(_ menu: NSMenu) {
        for item in menu.items where isWindowMenu(item) {
            // the menu of the app is the one that opens the windows of the
            // app. the menu of macOS is the other one.
            guard !isWindowMenuOfTheApp(item) else { continue }
            item.isHidden = true
        }
    }

    // Whether a menu of the menu bar is the window menu of the app.
    //
    // The menu of the app holds the windows of the app and nothing else, so
    // it is the one that has "Open ProxiRoute" in it.
    private static func isWindowMenuOfTheApp(_ item: NSMenuItem) -> Bool {
        guard let submenu = item.submenu else { return false }
        return submenu.items.contains { $0.title == L10n.t("Open ProxiRoute") }
    }

    // Hides the view menu.
    //
    // Everything in it was about a sidebar, a toolbar or a tab bar, and this
    // app has none of them. The things that were of use - the settings and
    // the full screen - are in the menu of the app.
    //
    // The menu is hidden and not taken out, and the reason is that SwiftUI
    // watches the menu bar. A menu item that is taken out is a change of the
    // menu bar, and SwiftUI answers a change of the menu bar by building it
    // again - with the view menu in it. The menu was taken out, SwiftUI put
    // it back a moment later, and the two of them kept at it until somebody
    // looked at the screen.
    //
    // A hidden item is not a change of the menu bar. SwiftUI does not notice
    // it, and the menu bar keeps the four menus that the app has.
    private static func hideViewMenu(_ menu: NSMenu) {
        for item in menu.items {
            guard item.title == "View" || item.title == L10n.t("View") || item.title == "显示" else { continue }
            item.isHidden = true
        }
    }

    // Hides the edit menu.
    //
    // The menu itself is only a list of the editing keys, and a proxy that
    // shows a log has nothing to edit. The keys keep working: they are
    // answered by the first responder, and the first responder is looked at
    // by installEditShortcuts.
    //
    // The menu is hidden and not taken out, for the same reason as the view
    // menu: taking a menu out is a change of the menu bar, and SwiftUI
    // answers it by building the menu bar again.
    private static func hideEditMenu(_ menu: NSMenu) {
        for item in menu.items where isEditMenu(item) {
            item.isHidden = true
        }
    }

    // Keeps the editing keys alive without an edit menu.
    //
    // The menu item was never the command: the command is answered by the
    // first responder - the text view of the log, or the field that holds the
    // keyboard. The menu item was one way of reaching it, and the way that
    // goes away with the menu.
    //
    // So the keys are watched here and the commands are sent to the first
    // responder. The log can still be copied out of it, and a field can still
    // be pasted into, without a menu that lists the keys.
    private static func installEditShortcuts() {
        guard editKeyMonitor == nil else { return }
        editKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.contains(.command),
                  !event.modifierFlags.contains(.control),
                  !event.modifierFlags.contains(.option),
                  let key = event.charactersIgnoringModifiers?.lowercased() else {
                return event
            }

            let selector: Selector
            switch key {
            case "c": selector = #selector(NSText.copy(_:))
            case "x": selector = #selector(NSText.cut(_:))
            case "v": selector = #selector(NSText.paste(_:))
            case "a": selector = #selector(NSText.selectAll(_:))
            case "z":
                // the redo is the undo with the shift key
                selector = event.modifierFlags.contains(.shift) ? Selector(("redo:")) : Selector(("undo:"))
            default:
                return event
            }

            // The command is answered by the first responder: the text view
            // of the log, or the field that holds the keyboard.
            //
            // The first responder of the window that has the keyboard is
            // asked first, and the window of the app is the one to fall back
            // on - the keys of the app arrive when the app has the keyboard,
            // but the window that has it is not always the main one.
            let responder = NSApp.keyWindow?.firstResponder ?? AppDelegate.mainWindow?.firstResponder
            if let responder, responder.responds(to: selector) {
                NSApp.sendAction(selector, to: responder, from: nil)
            } else {
                // nobody answers it: the chain of the responders is asked
                // anyway, and the undo manager is in it
                NSApp.sendAction(selector, to: nil, from: nil)
            }
            return nil
        }
    }

    // whether a menu of the menu bar is the edit menu
    private static func isEditMenu(_ item: NSMenuItem) -> Bool {
        return item.title == L10n.t("Edit") || item.title == "Edit" || item.title == "编辑"
    }

    // whether a menu of the menu bar is the window menu
    private static func isWindowMenu(_ item: NSMenuItem) -> Bool {
        return item.title == L10n.t("Window") || item.title == "Window" || item.title == "窗口"
    }

    // Renames the menus a moment later.
    //
    // The language changed and the menus were built again with the titles of
    // the system. The rename has to happen after that, and the moment the
    // menus are built is not a fixed one, so it is tried a few times. The
    // watcher below takes care of the rest.
    static func applySoon() {
        for delay in [0.05, 0.2, 0.5, 1.0, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { apply() }
        }
    }

    // Runs the renaming a moment later, and only once.
    //
    // SwiftUI writes the titles of its menus again and again, and every one
    // of those writes is a change of an item. A renaming for every change
    // would be a renaming nine times a second, and every one of them would
    // touch the menus of a person who is looking at one of them.
    private static func scheduleApply(after delay: TimeInterval = 0.15) {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            scheduled = false
            apply()
        }
    }

    // What happened to the menus, and when.
    //
    // The menus of macOS are watched because SwiftUI builds them again, and
    // the app has to put them back into the wanted shape. When that goes
    // wrong - and it did: the dropdown of the window menu jumped while it
    // was open - the log is the only thing that says what was changed and
    // when.
    //
    // The file is small on purpose: the last lines are the ones that matter.
    static func log(_ line: String) {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ProxiRoute")
        let file = folder.appendingPathComponent("menu.log")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = String(format: "%.3f", Date().timeIntervalSince1970)
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write("\(stamp) \(line)\n".data(using: .utf8) ?? Data())
            try? handle.close()
        } else {
            try? ("\(stamp) \(line)\n").write(to: file, atomically: true, encoding: .utf8)
        }
    }

    // Starts watching for the moments where the menus are built again.
    static func install() {
        applySoon()
        // the observers are added once: the app can be opened and closed again
        // as often as it is opened, and every visit would add another set of
        // them that does the same work twice
        guard !installed else { return }
        installed = true

        // the editing keys are watched as well: the edit menu is gone, and the
        // keys have to keep working without it
        installEditShortcuts()

        // The menu bar of SwiftUI is built again from time to time, and the
        // new one carries the titles of the system again. AppKit says nothing
        // about it: a new menu bar is not a change of an item, so the
        // notification of the items never comes. The menu bar itself is
        // watched instead, and the renaming is done again when it is
        // replaced.
        if menuBarObservation == nil {
            menuBarObservation = NSApp.observe(\.mainMenu, options: [.new]) { _, _ in
                NSLog("[ProxiRoute] the menu bar was built again")
                log("the menu bar was built again")
                applySoon()
            }
        }
        // every change of an item is answered with a renaming. SwiftUI writes
        // the titles of the standard menus again whenever it builds the menu
        // bar again, and this is what puts them back into the language of the
        // app right away.
        //
        // The renaming waits for the turn of the run loop to end. SwiftUI
        // builds the menu bar item by item, and a renaming that runs in the
        // middle of that would take away the edit menu - which comes before
        // the view menu - and leave the view menu, which comes after it.
        NotificationCenter.default.addObserver(
            forName: NSMenu.didChangeItemNotification,
            object: nil,
            queue: .main
        ) { _ in
            // The window menu is not touched here.
            //
            // macOS puts its own items into the window menu again every time
            // it builds the menu, and taking them out again is a change of
            // the menu, which makes macOS build it again. That is a round
            // that never ends, and the menu of a person who is looking at it
            // changed its height in every round of it.
            //
            // So the window menu is not touched at all. The titles of the
            // menus are renamed here, because a title that is wrong is worse
            // than a title that is in the language of the system.
            if tracking == 0 {
                renameMenus()
            } else {
                pending = true
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            DispatchQueue.main.async { apply() }
        }

        // When a menu is being drawn, it must not be changed.
        //
        // A menu that is changed while it is drawn is drawn again, and the
        // dropdown of the window menu jumped while it was open. These two
        // notifications say when a menu is being drawn.
        NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { _ in
            tracking += 1
            log("a menu is being drawn")
        }
        NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification,
            object: nil,
            queue: .main
        ) { _ in
            tracking = max(0, tracking - 1)
            log("the menu is closed")
            // Something wanted the menus to be changed while the menu was
            // drawn. It is done now, with the menu closed.
            if pending {
                pending = false
                scheduleApply(after: 0.05)
            }
        }

        // A menu can be left open when the app loses the focus, and then the
        // end of the tracking never comes. The flag is cleared here, so that
        // the app does not go on believing that a menu is open.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            tracking = 0
            pending = false
        }

        // The window that gets the keyboard brings the view menu with it:
        // SwiftUI builds the menu bar again when a window becomes the key
        // one, and the new one has the view menu in it. The renaming is
        // done again when that happens.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { _ in
            DispatchQueue.main.async { apply() }
        }

        // And once more from time to time, as long as the app is in front.
        //
        // SwiftUI does not say anything when it puts a menu back: the view
        // menu was back more than once without a word in the log. A check
        // every two seconds is nothing - it is a handful of names compared -
        // and it keeps the menu bar the way the person left it.
        if menuTimer == nil {
            menuTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                guard NSApp.isActive else { return }
                apply()
            }
        }
    }

    // whether the observers are already in place
    private static var installed = false
    // whether a renaming is going on
    private static var applying = false
    // how many menus of the app are being drawn at the moment
    private static var tracking = 0

    // Whether a menu of the app is being drawn at the moment.
    //
    // The app stops refreshing its lists while a menu is drawn. A refresh
    // makes SwiftUI build the menu bar again, and the menu that is open is
    // built again with fewer items: the menu was tall for a moment and then
    // it was short, and the shadow of the tall one stayed on the screen for
    // a moment. That is the ghost that was seen under the dropdown of the
    // window menu, and the shiver that went with it.
    static var isDrawing: Bool { return tracking > 0 }
    // whether something wanted the menus to be changed while a menu was drawn
    private static var pending = false
    // whether a renaming is already on its way
    private static var scheduled = false
    // the watch on the menu bar itself
    private static var menuBarObservation: NSKeyValueObservation?
    // the watch on the editing keys
    private static var editKeyMonitor: Any?
    // the watch that looks at the menu bar from time to time
    private static var menuTimer: Timer?
    // the titles the menu bar had the last time it was looked at
    private static var lastTitles = ""
    // the last line about the items that do not belong to the window menu
    private static var lastNoise = ""

    // Renames the items of one menu, and of the menus in it.
    private static func rename(_ menu: NSMenu, with titles: [Title]) {
        for item in menu.items {
            if let title = titles.first(where: { $0.matches(item.title) }) {
                setTitle(item, title.text)
            }
            if let submenu = item.submenu {
                rename(submenu, with: titles)
            }
        }
    }

    // Writes a title, but only when it is a different one: writing the same
    // title again would be a change of the item, and the change is what the
    // watcher listens to.
    private static func setTitle(_ item: NSMenuItem, _ text: String) {
        guard item.title != text else { return }
        item.title = text
    }
}
