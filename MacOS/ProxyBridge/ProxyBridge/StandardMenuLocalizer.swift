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
            ?? "ProxyBridge"
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
            Title(english: "AutoFill", chinese: "自动填充", text: L10n.t("AutoFill")),
            Title(english: "Contact…", chinese: "通讯录…", text: L10n.t("Contact…")),
            Title(english: "Passwords…", chinese: "密码…", text: L10n.t("Passwords…")),
            Title(english: "Credit Card…", chinese: "信用卡…", text: L10n.t("Credit Card…")),
            Title(english: "Start Dictation…", chinese: "开始听写…", text: L10n.t("Start Dictation…")),
            Title(english: "Emoji & Symbols", chinese: "表情与符号", text: L10n.t("Emoji & Symbols"))
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
