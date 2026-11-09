import Foundation

// The tests of the menus of macOS.
//
// The window menu of macOS is drawn by the system, and the system puts a
// row of items in it that change the size of the window: close, minimize,
// zoom, fill, center, and the place and the size the window had. They are
// noise for this app, and one of them is the reason a person saw the window
// of the app change its size behind their back.
//
// The tests cannot look at the menu itself - the system draws it - so they
// look at the list of the titles that are taken out of it, and they say that
// the items that change the size of the window are in that list.

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
    "Close", "Close All", "Minimize", "Minimize All", "Zoom", "Zoom All",
    "Fill", "Center", "Move & Resize", "Full Screen Tile",
    "Move to Left of Screen", "Move to Right of Screen",
    "Move to Top of Screen", "Move to Bottom of Screen",
    "Tile Window to Left of Screen", "Tile Window to Right of Screen",
    "Tile Window to Top of Screen", "Tile Window to Bottom of Screen"
]

for title in sizeChangingTitles {
    check(noise.contains(title), "the item '\(title)' is taken out of the window menu")
}

// and the same in the language of the machine
for title in ["关闭", "全部关闭", "最小化", "全部最小化", "缩放", "全部缩放",
              "填充", "居中", "移动与调整大小", "全屏幕平铺",
              "移到屏幕左侧", "移到屏幕右侧", "移到屏幕顶部", "移到屏幕底部",
              "窗口平铺到屏幕左侧", "窗口平铺到屏幕右侧",
              "窗口平铺到屏幕顶部", "窗口平铺到屏幕底部"] {
    check(noise.contains(title), "the item '\(title)' is taken out of the window menu")
}

// the items that bring windows to the front are noise as well: the app has
// one window
for title in ["Bring All to Front", "Bring Window to Front", "Cycle Through Windows",
              "前置全部窗口", "排在前面", "在窗口间循环"] {
    check(noise.contains(title), "the item '\(title)' is taken out of the window menu")
}

// macOS 27 calls the item that brings the windows to the front "Arrange in
// Front" and not "Bring All to Front"
check(noise.contains("Arrange in Front"), "the item 'Arrange in Front' is taken out of the window menu")

// the items about tabs and window sets are still taken out
for title in ["New Tab", "Close Tab", "Merge All Windows", "Rename Window Set",
              "新建标签页", "关闭标签页", "合并所有窗口", "重命名窗口组"] {
    check(noise.contains(title), "the item '\(title)' is taken out of the window menu")
}

// The way to the window itself stays: without it the menu is a list of
// things that are not there.
check(!noise.contains("Open ProxiRoute"), "the way to the window is not taken out")
check(!noise.contains("打开 ProxiRoute"), "the way to the window is not taken out")

// The items that change the size of the window are taken out at the source.
//
// The window menu is drawn by SwiftUI, and SwiftUI draws it again whenever
// something in it changes - so an item that is taken out of the menu while
// it is drawn comes back a moment later, and the dropdown of the menu jumps
// while it is open. The command group that holds them is taken out of the
// commands of the app instead, and then they are never in the menu at all.
//
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

let guiSource = (try? String(contentsOf: appFolder.appendingPathComponent("ProxiRouteGUI.swift"), encoding: .utf8)) ?? ""
check(guiSource.contains("CommandGroup(replacing: .windowArrangement)"),
      "the items that move and resize the window are taken out at the source")

print("menu tests: ALL PASS")
