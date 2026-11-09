import Foundation

// The titles of the items that must not be in the window menu.
//
// The window menu of macOS is drawn by the system, and the system puts a row
// of items in it that change the size or the place of the window: fill,
// center, move and resize, the tiles. It puts the items of the tabs and of
// the window sets in it as well. They are grey in this app: the app has a
// single window and no row of tabs, and a grey item is a promise that is
// never kept.
//
// The list is a piece of code of its own, and not a part of the menu code,
// so that the tests can look at it without the whole app around it: the menu
// code needs the app delegate, and the app delegate needs the whole app.
//
// The way to the window is not in the list, and neither are the items that
// belong to the window menu: close, minimize, zoom and bring all to front
// work in this app, and the items that open the windows of the app are the
// ones a person is there for.
//
// The titles are written twice, in the words of macOS in english and in
// chinese, because the system writes the menu in the language of the
// machine.
let windowMenuNoiseTitles: Set<String> = [
    // The items that move and resize the window.
    //
    // They are taken out at the source: the command group that holds them is
    // out of the commands of the app - see
    // CommandGroup(replacing: .windowArrangement) in ProxiRouteGUI. The list
    // is here so that the tests can see that the items of that group are
    // the ones of this list.
    "Fill",
    "填充",
    "Center",
    "居中",
    "Move & Resize",
    "移动与调整大小",
    "Full Screen Tile",
    "全屏幕平铺",
    "Move to Left of Screen",
    "移到屏幕左侧",
    "Move to Right of Screen",
    "移到屏幕右侧",
    "Move to Top of Screen",
    "移到屏幕顶部",
    "Move to Bottom of Screen",
    "移到屏幕底部",
    "Tile Window to Left of Screen",
    "窗口平铺到屏幕左侧",
    "Tile Window to Right of Screen",
    "窗口平铺到屏幕右侧",
    "Tile Window to Top of Screen",
    "窗口平铺到屏幕顶部",
    "Tile Window to Bottom of Screen",
    "窗口平铺到屏幕底部",
    "Exit Full Screen",
    "退出全屏",
    "Enter Full Screen",
    "进入全屏",
    "进入全屏幕",

    // The items of the tabs and of the window sets.
    //
    // They are not there either, because the window of the app is not a tab
    // and is not in a window set - see WindowAccessor and
    // NSWindow.allowsAutomaticWindowTabbing.
    "Show Previous Tab",
    "显示上一个标签页",
    "Show Next Tab",
    "显示下一个标签页",
    "Select Previous Tab",
    "选择上一个标签页",
    "Select Next Tab",
    "选择下一个标签页",
    "New Tab",
    "新建标签页",
    "Close Tab",
    "关闭标签页",
    "Duplicate Tab",
    "复制标签页",
    "Move Tab to New Window",
    "将标签页移到新窗口",
    "Add Tab to Window Set",
    "将标签页添加到窗口组",
    "Merge All Windows",
    "合并所有窗口",
    "Move Window to New Set",
    "将窗口移到新组",
    "Rename Window Set",
    "重命名窗口组",
    "Remove Window from Set",
    "从组中移除窗口",
]
