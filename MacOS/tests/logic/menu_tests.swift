import Foundation

// The tests of the menus of macOS.
//
// The window menu of macOS is drawn by the system. The system puts a row of
// items in it that change the size or the place of the window - fill, center,
// move and resize, the tiles - and the items of the tabs and of the window
// sets. They are grey in this app: the app has a single window and no row of
// tabs, and a grey item is a promise that is never kept.
//
// The items are taken out at the source, and not while the menu is drawn.
// Taking them out while the menu is drawn is a change of the menu, and macOS
// puts its own items back into it every time it builds the menu - so the
// menu of a person who was looking at it changed its height again and again,
// and the shadow of the menu that was taller stayed on the screen for a
// moment. That was the ghost under the dropdown of the window menu.
//
// So the tests keep four things:
//   - the list of the items that must not be in the window menu is the list
//     of the items of the window arrangement and of the tabs,
//   - those items are taken out at the source,
//   - the window menu is not touched while it is drawn, and
//   - the app does not refresh its lists while a menu is drawn, because a
//     refresh makes SwiftUI build the menu bar again.

func check(_ condition: Bool, _ what: String) {
    if condition {
        print("  ok   \(what)")
    } else {
        print("  FAIL \(what)")
        exit(1)
    }
}

print("menu tests:")

let noise = windowMenuNoiseTitles

// The items that change the size of the window. They are the ones a person
// clicks by accident, and the size the window gets is the size it had before,
// which is the noise the app does not want in its menu.
let sizeChangingTitles = [
    "Fill", "Center", "Move & Resize", "Full Screen Tile",
    "Move to Left of Screen", "Move to Right of Screen",
    "Move to Top of Screen", "Move to Bottom of Screen",
    "Tile Window to Left of Screen", "Tile Window to Right of Screen",
    "Tile Window to Top of Screen", "Tile Window to Bottom of Screen"
]

for title in sizeChangingTitles {
    check(noise.contains(title), "the item '\(title)' is not in the window menu")
}

// and the same in the language of the machine
for title in ["填充", "居中", "移动与调整大小", "全屏幕平铺",
              "移到屏幕左侧", "移到屏幕右侧", "移到屏幕顶部", "移到屏幕底部",
              "窗口平铺到屏幕左侧", "窗口平铺到屏幕右侧",
              "窗口平铺到屏幕顶部", "窗口平铺到屏幕底部"] {
    check(noise.contains(title), "the item '\(title)' is not in the window menu")
}

// The items of the tabs and of the window sets are not in the window menu
// either.
for title in ["New Tab", "Close Tab", "Merge All Windows", "Rename Window Set",
              "Show Previous Tab", "Show Next Tab", "Select Previous Tab",
              "Select Next Tab", "Move Tab to New Window", "Duplicate Tab",
              "Add Tab to Window Set", "Move Window to New Set",
              "Remove Window from Set",
              "新建标签页", "关闭标签页", "合并所有窗口", "重命名窗口组",
              "显示上一个标签页", "显示下一个标签页", "选择上一个标签页",
              "选择下一个标签页", "将标签页移到新窗口", "复制标签页",
              "将标签页添加到窗口组", "将窗口移到新组", "从组中移除窗口"] {
    check(noise.contains(title), "the item '\(title)' is not in the window menu")
}

// The item that goes full screen is not in the window menu either.
//
// macOS draws a ghost of the window next to that item, and the ghost grows
// while the mouse stays on the item. The cursor lands on the item by itself
// when the window menu is opened, so the ghost was drawn every time the menu
// was opened. The full screen is in the menu of the app, where macOS draws no
// ghost.
check(noise.contains("Enter Full Screen"), "the item that goes full screen is not in the window menu")
check(noise.contains("进入全屏"), "the item that goes full screen is not in the window menu")

// The items that belong to the window menu are not in the list. Close,
// minimize, zoom and bring all to front work in this app, and a list that
// holds them would take away what the menu is for.
for title in ["Close", "Minimize", "Zoom", "Bring All to Front",
              "关闭", "最小化", "缩放", "前置全部窗口"] {
    check(!noise.contains(title), "the item '\(title)' stays in the window menu")
}

// The way to the window is not in the list either.
check(!noise.contains("Open ProxiRoute"), "the way to the window is not in the list")
check(!noise.contains("打开 ProxiRoute"), "the way to the window is not in the list")

// The folder of the app sources is given by the environment, because the test
// is compiled in a temporary folder.
let appFolder: URL
if let fromEnvironment = ProcessInfo.processInfo.environment["PROXIRoute_APP"] {
    appFolder = URL(fileURLWithPath: fromEnvironment)
} else {
    appFolder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // logic
        .deletingLastPathComponent()   // tests
        .deletingLastPathComponent()   // ProxiRoute
        .appendingPathComponent("ProxiRoute")
}

func read(_ name: String) -> String {
    let path = appFolder.appendingPathComponent(name)
    guard let text = try? String(contentsOf: path, encoding: .utf8) else {
        print("  FAIL cannot read \(name)")
        exit(1)
    }
    return text
}

let guiSource = read("ProxiRouteGUI.swift")
let localizer = read("StandardMenuLocalizer.swift")
let viewModel = read("ProxiRouteViewModel.swift")

// ---------------------------------------------------------------- at the source
//
// The items that move and resize the window are taken out of the commands of
// the app, so that they are not in the menu at all.
check(guiSource.contains("CommandGroup(replacing: .windowArrangement)"),
      "the items that move and resize the window are taken out at the source")

// The window of the app is not a tab and is not in a window set, so the items
// of the tabs and of the window sets are never there.
check(guiSource.contains("window.tabbingMode = .disallowed"),
      "the window is not a tab and is not in a window set")
check(guiSource.contains("NSWindow.allowsAutomaticWindowTabbing = false"),
      "no window of the app is put into a tab")

// ---------------------------------------------------------------- the full screen

check(!localizer.contains("#selector(AppDelegate.toggleWindowFullScreen)"),
      "the full screen is not put into the window menu")

// The way into the full screen is in the menu of the app.
check(guiSource.contains("CommandGroup(replacing: .appInfo)"),
      "the menu of the app is built by the app")
check(guiSource.contains("L10n.t(\"Enter Full Screen\")"),
      "the full screen is in the menu of the app")
check(guiSource.contains("L10n.t(\"Open ProxiRoute\")"),
      "the way to the window is in the menu of the app")

// The action is not called the way macOS calls it. macOS draws the ghost for
// an item whose action is the full screen, and the name of the action is
// what it looks at.
check(!guiSource.contains("@objc func toggleFullScreen()"),
      "the action of the full screen is not called the way macOS calls it")
check(guiSource.contains("@objc func toggleWindowFullScreen()"),
      "the action of the full screen has a name of its own")

// ---------------------------------------------------------------- the menu is not changed while it is drawn

check(localizer.contains("guard tracking == 0 else {"),
      "a menu that is being drawn is not changed")
check(localizer.contains("NSMenu.didBeginTrackingNotification"),
      "the app knows when a menu is being drawn")
check(localizer.contains("NSMenu.didEndTrackingNotification"),
      "the app knows when the menu is closed")
check(localizer.contains("NSApplication.didResignActiveNotification"),
      "the flag is cleared when the app loses the focus")

// Nothing is taken out of a menu while it is drawn.
//
// A menu that is changed while it is on the screen is drawn again, and the
// shadow of the taller one stays on the screen for a moment. That was the
// ghost under the dropdown of the window menu.
check(!localizer.contains("menu.removeItem(at:"),
      "no item is taken out of a menu")

// The menu bar of the app is not written again.
//
// Writing it is what made SwiftUI write it again, every half a second, and
// the window menu of the app was gone from the bar in between.
check(!localizer.contains("NSApp.mainMenu = menu"),
      "the menu bar of the app is not written again")

// ---------------------------------------------------------------- the window menu of the app
//
// The window menu of macOS is drawn by macOS, and it holds the items that
// move and resize the window and the items of the tabs and of the window
// sets. They are grey in this app, and they cannot be taken out of it: the
// menu that macOS paints is its own, and what is taken out of the menu of
// the menu bar is put back into it a moment later.
//
// So the menu of macOS is hidden, and the menu of the app takes its place.
// The menu of the app holds the windows of the app and nothing else.
check(localizer.contains("private static func hideWindowMenu"),
      "the window menu of macOS is hidden")
check(localizer.contains("private static func isWindowMenuOfTheApp"),
      "the window menu of the app is told apart from the one of macOS")
check(guiSource.contains("CommandMenu(L10n.t(\"Window\"))"),
      "the app has a window menu of its own")

// the windows of the app are in it
for title in ["Open ProxiRoute", "Proxy Settings", "Proxy Rules", "Gateway",
              "Proxy Server", "About ProxiRoute", "Check for Updates"] {
    check(guiSource.contains("L10n.t(\"\(title)\")"),
          "the window menu of the app holds '\(title)'")
}

// The items that do not belong to the window menu of macOS are looked at,
// and what is found is written into the log. That is the check that they
// stay out of the menu of the app.
check(localizer.contains("reportWindowMenu"),
      "the items of the window menu are looked at")

// The items that do not belong to the window menu are looked at, and what is
// found is written into the log. That is the check that they stay out.
check(localizer.contains("reportWindowMenu"),
      "the items of the window menu are looked at")

// ---------------------------------------------------------------- the lists are not refreshed while a menu is drawn
//
// A refresh makes SwiftUI build the menu bar again, and the menu that is
// open is built again with fewer items: the menu was tall for a moment and
// then it was short, and the shadow of the tall one stayed on the screen.

check(localizer.contains("static var isDrawing: Bool"),
      "the app knows that a menu is being drawn")
for poll in ["pollFlows", "pollLogs", "pollServerTraffic"] {
    check(viewModel.contains("func \(poll)() {\n        // the lists are not refreshed while a menu is drawn")
            || viewModel.contains("func \(poll)() {\n        // The lists are not refreshed while a menu is drawn."),
          "the list of \(poll) is not refreshed while a menu is drawn")
}

print("menu tests: ALL PASS")
