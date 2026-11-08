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
// by SwiftUI and not out of the menu, so they cannot be renamed here. They are
// in the language of the bundle, and the bundle is put in the language of the
// app when the app starts (see main.swift).
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

    // The titles of the menus that are always there.
    private static var topLevelTitles: [Title] {
        return [
            Title(english: "Edit", chinese: "编辑", text: L10n.t("Edit")),
            Title(english: "View", chinese: "显示", text: L10n.t("View")),
            Title(english: "Window", chinese: "窗口", text: L10n.t("Window")),
            Title(english: "Help", chinese: "帮助", text: L10n.t("Help")),
            Title(english: "File", chinese: "文件", text: L10n.t("File")),
            Title(english: "Format", chinese: "格式", text: L10n.t("Format"))
        ]
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

    // The titles of the items of the window and edit menus.
    //
    // The list is the one of the items that macOS puts into those two menus.
    // An item that is not there is simply not found, so the list does not have
    // to be exact - but everything that is there has to be in it, or that one
    // stays in the language of the system.
    private static var itemTitles: [Title] {
        return [
            Title(english: "Minimize", chinese: "最小化", text: L10n.t("Minimize")),
            Title(english: "Zoom", chinese: "缩放", text: L10n.t("Zoom")),
            Title(english: "Bring All to Front", chinese: "前置全部窗口", text: L10n.t("Bring All to Front")),
            Title(english: "Undo", chinese: "撤销", text: L10n.t("Undo")),
            Title(english: "Redo", chinese: "重做", text: L10n.t("Redo")),
            Title(english: "Cut", chinese: "剪切", text: L10n.t("Cut")),
            Title(english: "Copy", chinese: "拷贝", text: L10n.t("Copy")),
            Title(english: "Paste", chinese: "粘贴", text: L10n.t("Paste")),
            Title(english: "Delete", chinese: "删除", text: L10n.t("Delete")),
            Title(english: "Select All", chinese: "全选", text: L10n.t("Select All"))
        ]
    }

    // The items that macOS 26 put into the edit menu and that have nothing to
    // do with editing: the contact card, the passwords, the credit card,
    // dictation and the emoji picker. A proxy that shows a log has no use for
    // any of them.
    //
    // They are removed and not renamed, because a menu that says "the credit
    // card" in a proxy is a menu that says something wrong.
    private static var editNoiseTitles: [Title] {
        return [
            Title(english: "AutoFill", chinese: "自动填充", text: ""),
            Title(english: "Contact…", chinese: "通讯录…", text: ""),
            Title(english: "Passwords…", chinese: "密码…", text: ""),
            Title(english: "Credit Card…", chinese: "信用卡…", text: ""),
            Title(english: "Start Dictation…", chinese: "开始听写…", text: ""),
            Title(english: "Emoji & Symbols", chinese: "表情与符号", text: "")
        ]
    }

    // Renames the system menus in the menu bar of the app.
    //
    // It is safe to call it more than once: a title that is already the one
    // that is wanted is left alone.
    static func apply() {
        // the renaming writes titles, and a written title is a change of an
        // item, and a change of an item is what brings the renaming here.
        // without this the two would call each other without end.
        guard !applying else { return }
        applying = true
        defer { applying = false }

        guard let menu = NSApp.mainMenu else { return }

        // the menus of the menu bar
        for item in menu.items {
            if let title = topLevelTitles.first(where: { $0.matches(item.title) }) {
                setTitle(item, title.text)
            }
        }

        // the application menu is the first one, its items are about the app
        if let appMenu = menu.items.first?.submenu {
            rename(appMenu, with: appMenuTitles)
        }

        // the items of the window and edit menus, and of the menus in them
        for item in menu.items {
            let isWindow = item.title == L10n.t("Window") || item.title == "Window" || item.title == "窗口"
            let isEdit = item.title == L10n.t("Edit") || item.title == "Edit" || item.title == "编辑"
            guard isWindow || isEdit, let submenu = item.submenu else { continue }
            rename(submenu, with: itemTitles)
        }

        // the items of macOS 26 that have nothing to do with editing
        pruneEditMenu(menu)

        // the view menu goes, and what is in it comes to the window menu
        removeViewMenu(menu)
        putWindowItems(menu)

        // What the menu bar looks like right now. It is written only when it
        // changed, because the names of the menus are different on every
        // system and the log is the place where that shows.
        let titles = menu.items.map { $0.title }.joined(separator: " | ")
        if titles != lastTitles {
            lastTitles = titles
            NSLog("[ProxiRoute] the menu bar: %@", titles)
        }

        // and what is in the menus that were worked on
        for item in menu.items where isEditMenu(item) || isWindowMenu(item) {
            guard let submenu = item.submenu else { continue }
            let entries = submenu.items.map { $0.title }.joined(separator: " | ")
            let line = "\(item.title): \(entries)"
            if lastEntries[line] == nil {
                lastEntries[line] = true
                NSLog("[ProxiRoute] the %@ menu: %@", item.title, entries)
            }
        }
    }

    // Removes the items of macOS 26 that have nothing to do with editing.
    //
    // They are in the edit menu of every app, and a proxy that shows a log
    // has no use for a credit card or an emoji picker.
    private static func pruneEditMenu(_ menu: NSMenu) {
        guard let edit = menu.items.first(where: { isEditMenu($0) }),
              let submenu = edit.submenu else { return }
        // from the back, so that the index of the item that is not removed
        // does not move
        for index in stride(from: submenu.numberOfItems - 1, through: 0, by: -1) {
            guard let item = submenu.item(at: index) else { continue }
            guard editNoiseTitles.contains(where: { $0.matches(item.title) }) else { continue }
            submenu.removeItem(at: index)
        }
    }

    // Removes the view menu.
    //
    // Everything in it was about a sidebar, a toolbar or a tab bar, and this
    // app has none of them. The one thing that was of use - the full screen -
    // is put into the window menu, so that there is one menu for the window
    // and not two.
    private static func removeViewMenu(_ menu: NSMenu) {
        for (index, item) in menu.items.enumerated() {
            guard item.title == "View" || item.title == L10n.t("View") || item.title == "显示" else { continue }
            menu.removeItem(at: index)
            return
        }
    }

    // Puts the items of the window menu at the top of it.
    //
    // The window menu of SwiftUI lists the windows of the app. What is missing
    // is the way to the main window and to the full screen, and those are the
    // two things a person reaches for.
    private static func putWindowItems(_ menu: NSMenu) {
        guard let delegate = AppDelegate.shared,
              let window = menu.items.first(where: { isWindowMenu($0) }),
              let submenu = window.submenu else { return }
        // they are already there when the menus are built again
        guard !submenu.items.contains(where: { $0.representedObject as? String == "windowItems" }) else { return }

        let open = NSMenuItem(title: L10n.t("Open ProxiRoute"), action: #selector(AppDelegate.showMainWindow), keyEquivalent: "")
        open.target = delegate
        open.representedObject = "windowItems"
        let full = NSMenuItem(title: L10n.t("Enter Full Screen"), action: #selector(AppDelegate.toggleFullScreen), keyEquivalent: "")
        full.target = delegate
        full.representedObject = "windowItems"
        submenu.insertItem(open, at: 0)
        submenu.insertItem(full, at: 1)
        submenu.insertItem(.separator(), at: 2)
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

    // Starts watching for the moments where the menus are built again.
    static func install() {
        applySoon()
        // the observers are added once: the app can be opened and closed again
        // as often as it is opened, and every visit would add another set of
        // them that does the same work twice
        guard !installed else { return }
        installed = true

        // The menu bar of SwiftUI is built again from time to time, and the
        // new one carries the titles of the system again. AppKit says nothing
        // about it: a new menu bar is not a change of an item, so the
        // notification of the items never comes. The menu bar itself is
        // watched instead, and the renaming is done again when it is
        // replaced.
        if menuBarObservation == nil {
            menuBarObservation = NSApp.observe(\.mainMenu, options: [.new]) { _, _ in
                NSLog("[ProxiRoute] the menu bar was built again")
                applySoon()
            }
        }
        // every change of an item is answered with a renaming. SwiftUI writes
        // the titles of the standard menus again whenever it builds the menu
        // bar again, and this is what puts them back into the language of the
        // app right away.
        NotificationCenter.default.addObserver(
            forName: NSMenu.didChangeItemNotification,
            object: nil,
            queue: .main
        ) { _ in
            apply()
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            apply()
        }
    }

    // whether the observers are already in place
    private static var installed = false
    // whether a renaming is going on
    private static var applying = false
    // the watch on the menu bar itself
    private static var menuBarObservation: NSKeyValueObservation?
    // the titles the menu bar had the last time it was looked at
    private static var lastTitles = ""
    // the menus that were already written into the log
    private static var lastEntries: [String: Bool] = [:]

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
