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
//
// Two of them go away anyway: the view menu (everything in it was about a
// sidebar or a toolbar, and this app has none) and the edit menu (it is a list
// of the editing keys, and the keys keep working without it - see
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
            Title(english: "Select All", chinese: "全选", text: L10n.t("Select All")),
            // the items macOS 26 puts into the window menu
            //
            // The chinese words in them are the ones macOS itself uses, so
            // that an item that the system has already translated is left
            // alone and one that comes in english is renamed.
            Title(english: "Close", chinese: "关闭", text: L10n.t("Close")),
            Title(english: "Close All", chinese: "全部关闭", text: L10n.t("Close All")),
            Title(english: "Minimize All", chinese: "全部最小化", text: L10n.t("Minimize All")),
            Title(english: "Zoom All", chinese: "全部缩放", text: L10n.t("Zoom All")),
            Title(english: "Fill", chinese: "填充", text: L10n.t("Fill")),
            Title(english: "Center", chinese: "居中", text: L10n.t("Center")),
            Title(english: "Move & Resize", chinese: "移动与调整大小", text: L10n.t("Move & Resize")),
            Title(english: "Full Screen Tile", chinese: "全屏幕平铺", text: L10n.t("Full Screen Tile")),
            Title(english: "Exit Full Screen", chinese: "退出全屏", text: L10n.t("Exit Full Screen")),
            Title(english: "Move to Left of Screen", chinese: "移到屏幕左侧", text: L10n.t("Move to Left of Screen")),
            Title(english: "Move to Right of Screen", chinese: "移到屏幕右侧", text: L10n.t("Move to Right of Screen")),
            Title(english: "Move to Top of Screen", chinese: "移到屏幕顶部", text: L10n.t("Move to Top of Screen")),
            Title(english: "Move to Bottom of Screen", chinese: "移到屏幕底部", text: L10n.t("Move to Bottom of Screen")),
            Title(english: "Tile Window to Left of Screen", chinese: "窗口平铺到屏幕左侧", text: L10n.t("Tile Window to Left of Screen")),
            Title(english: "Tile Window to Right of Screen", chinese: "窗口平铺到屏幕右侧", text: L10n.t("Tile Window to Right of Screen")),
            Title(english: "Tile Window to Top of Screen", chinese: "窗口平铺到屏幕顶部", text: L10n.t("Tile Window to Top of Screen")),
            Title(english: "Tile Window to Bottom of Screen", chinese: "窗口平铺到屏幕底部", text: L10n.t("Tile Window to Bottom of Screen"))
        ]
    }

    // The items of macOS 26 that belong to the tabs and to the window sets.
    //
    // The app has one window and no row of tabs, so those items are always
    // grey: they are about a set of windows or a tab bar that does not exist
    // here. A grey item is a promise that is never kept, so they are taken
    // out instead of being renamed.
    private static var windowNoiseTitles: [Title] {
        return [
            // the words macOS uses in english ...
            Title(english: "Remove Window from Set", chinese: "从组中移除窗口", text: ""),
            Title(english: "Add Tab to Window Set", chinese: "将标签页添加到窗口组", text: ""),
            Title(english: "Move Tab to New Window", chinese: "将标签页移到新窗口", text: ""),
            Title(english: "Merge All Windows", chinese: "合并所有窗口", text: ""),
            Title(english: "Show Previous Tab", chinese: "显示上一个标签页", text: ""),
            Title(english: "Show Next Tab", chinese: "显示下一个标签页", text: ""),
            Title(english: "Select Previous Tab", chinese: "选择上一个标签页", text: ""),
            Title(english: "Select Next Tab", chinese: "选择下一个标签页", text: ""),
            Title(english: "New Tab", chinese: "新建标签页", text: ""),
            Title(english: "Close Tab", chinese: "关闭标签页", text: ""),
            Title(english: "Duplicate Tab", chinese: "复制标签页", text: ""),
            Title(english: "Move Window to New Set", chinese: "将窗口移到新组", text: ""),
            Title(english: "Rename Window Set", chinese: "重命名窗口组", text: ""),
            // ... and the ones it uses in chinese
            Title(english: "从组中移除窗口", chinese: "从组中移除窗口", text: ""),
            Title(english: "将标签页添加到窗口组", chinese: "将标签页添加到窗口组", text: ""),
            Title(english: "将标签页移到新窗口", chinese: "将标签页移到新窗口", text: ""),
            Title(english: "合并所有窗口", chinese: "合并所有窗口", text: ""),
            Title(english: "显示上一个标签页", chinese: "显示上一个标签页", text: ""),
            Title(english: "显示下一个标签页", chinese: "显示下一个标签页", text: ""),
            Title(english: "选择上一个标签页", chinese: "选择上一个标签页", text: ""),
            Title(english: "选择下一个标签页", chinese: "选择下一个标签页", text: ""),
            Title(english: "新建标签页", chinese: "新建标签页", text: ""),
            Title(english: "关闭标签页", chinese: "关闭标签页", text: ""),
            Title(english: "复制标签页", chinese: "复制标签页", text: "")
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

        // the grey items of macOS 26 that belong to the tabs and the window
        // sets. this app has neither, so they are taken out.
        pruneWindowMenu(menu)

        // the view menu goes, and what is in it comes to the window menu
        removeViewMenu(menu)
        putWindowItems(menu)

        // the edit menu goes as well. the keys are still there - see
        // installEditShortcuts - but a menu that is a list of keys is a menu
        // nobody opens.
        removeEditMenu(menu)

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

    // Removes the items of the window menu that are about the tabs and the
    // window sets.
    //
    // macOS 26 puts them into the window menu of every app, and they are
    // always grey in this one: the app has a single window and no row of
    // tabs, so there is no set of windows and no tab to move. A grey item is
    // a promise that is never kept, so it is taken out.
    private static func pruneWindowMenu(_ menu: NSMenu) {
        guard let window = menu.items.first(where: { isWindowMenu($0) }),
              let submenu = window.submenu else { return }
        // from the back, so that the index of the item that is not removed
        // does not move
        for index in stride(from: submenu.numberOfItems - 1, through: 0, by: -1) {
            guard let item = submenu.item(at: index) else { continue }
            guard windowNoiseTitles.contains(where: { $0.matches(item.title) }) else { continue }
            submenu.removeItem(at: index)
        }
        // the items that went took their separators with them, and what is
        // left is a row of empty lines
        collapseSeparators(submenu)
    }

    // Removes the lines that are empty twice in a row, and the one at the end.
    //
    // The items of macOS 26 stand between lines, and taking one of them out
    // leaves two lines where there was one.
    private static func collapseSeparators(_ menu: NSMenu) {
        // whether the item that comes after the one that is looked at is a
        // line. Nothing comes after the last item, so the last line is a
        // line at the end of the menu.
        var nextIsSeparator = true
        for index in stride(from: menu.numberOfItems - 1, through: 0, by: -1) {
            guard let item = menu.item(at: index) else { continue }
            if item.isSeparatorItem {
                // two lines in a row are one line too many, and a line at the
                // end of the menu has nothing after it
                if nextIsSeparator {
                    menu.removeItem(at: index)
                    continue
                }
                nextIsSeparator = true
            } else {
                nextIsSeparator = false
            }
        }
    }

    // Removes the edit menu.
    //
    // The menu itself is only a list of the editing keys, and a proxy that
    // shows a log has nothing to edit. The keys keep working: they are
    // answered by the first responder, and the first responder is looked at
    // by installEditShortcuts.
    private static func removeEditMenu(_ menu: NSMenu) {
        for (index, item) in menu.items.enumerated() where isEditMenu(item) {
            menu.removeItem(at: index)
            return
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
            DispatchQueue.main.async { apply() }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            DispatchQueue.main.async { apply() }
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
    // the watch on the menu bar itself
    private static var menuBarObservation: NSKeyValueObservation?
    // the watch on the editing keys
    private static var editKeyMonitor: Any?
    // the watch that looks at the menu bar from time to time
    private static var menuTimer: Timer?
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
