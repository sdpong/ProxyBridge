import Foundation
import Combine

// The language of the app.
//
// The strings live in this file instead of in a bundle of resources: the app is
// signed ad hoc, and a bundle of resources is one more thing that can go
// missing. A string that has no translation is shown the way it is written, so
// a missing translation is a missing translation and never a blank.
//
// The key of a translation is the English text itself. That keeps the two
// sides next to each other in the source, and it makes a string that was
// forgotten obvious: it simply stays English.
enum L10n {

    // The languages the app speaks.
    enum Language: String, CaseIterable, Identifiable {
        case english = "en"
        case chinese = "zh-Hans"

        var id: String { rawValue }

        // The name of the language, in that language.
        var displayName: String {
            switch self {
            case .english: return "English"
            case .chinese: return "简体中文"
            }
        }
    }

    // The language the app is in.
    static var language: Language {
        get { LocalizationManager.shared.language }
        set { LocalizationManager.shared.language = newValue }
    }

    // The text of a string, in the language of the app.
    static func t(_ text: String) -> String {
        return translate(text, language: LocalizationManager.shared.language)
    }

    // A text with names in it. The names go where the %@ is, in order.
    static func f(_ text: String, _ arguments: String...) -> String {
        return formatted(text, arguments: arguments, language: LocalizationManager.shared.language)
    }

    // The text of a string in a given language. A string that has no
    // translation is shown the way it is written.
    static func translate(_ text: String, language: Language) -> String {
        if language == .english { return text }
        return translations[text] ?? text
    }

    // A text with names in it, in a given language.
    //
    // The names go into the placeholders one after the other. Replacing them
    // all at once would put the first name into every placeholder, so a text
    // with three names would say the first name three times.
    static func formatted(_ text: String, arguments: [String], language: Language) -> String {
        var out = translate(text, language: language)
        for argument in arguments {
            guard let range = out.range(of: "%@") else { break }
            out.replaceSubrange(range, with: argument)
        }
        return out
    }

    // Where the sources of the app are. The test that goes through them needs
    // to find them, and this file knows where it was compiled from.
    static let sourcesDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

    // The English text and its Chinese translation.
    static let translations: [String: String] = [
        // the windows and the menus
        "Proxy": "代理",
        "Proxy Settings": "代理设置",
        "Proxy Settings...": "代理设置…",
        "Proxy Rules": "代理规则",
        "Proxy Rules...": "代理规则…",
        "Proxy Chains": "代理链",
        "Proxy Chains...": "代理链…",
        "DNS Settings": "DNS 设置",
        "DNS Settings...": "DNS 设置…",
        "Settings": "设置",
        "Profile": "配置",
        "About ProxiRoute": "关于 ProxiRoute",
        "Check for Updates": "检查更新",
        "Check for Updates...": "检查更新…",
        "Documentation": "文档",
        "Enable Traffic Logging": "启用流量日志",
        "Enable DNS": "启用 DNS",
        "Close to Menu Bar": "关闭时收进菜单栏",
        "Keep Proxy Running in Background": "在后台保持代理运行",
        "Run at Startup": "开机启动",
        "Approve ProxiRoute in System Settings...": "在系统设置中授权 ProxiRoute…",
        "Take Out Older ProxiRoute Extensions...": "移除较旧的 ProxiRoute 扩展…",

        // the menus macOS brings itself. their titles come from the
        // localization of the app bundle, and this app has no bundle of
        // resources, so they are renamed at runtime (StandardMenuLocalizer)
        "View": "显示",
        "Window": "窗口",
        "Help": "帮助",
        "File": "文件",
        "Format": "格式",
        "About %@": "关于 %@",
        "Hide %@": "隐藏 %@",
        "Hide Others": "隐藏其他",
        "Show All": "显示全部",
        "Services": "服务",
        "Quit %@": "退出 %@",
        "Minimize": "最小化",
        "Zoom": "缩放",
        "Bring All to Front": "前置全部窗口",
        "Undo": "撤销",
        "Redo": "重做",
        "Cut": "剪切",
        "Copy": "拷贝",
        "Paste": "粘贴",
        "Select All": "全选",
        "AutoFill": "自动填充",
        "Contact…": "通讯录…",
        "Passwords…": "密码…",
        "Credit Card…": "信用卡…",
        "Start Dictation…": "开始听写…",
        "Emoji & Symbols": "表情与符号",

        // the texts that were written before the app spoke the language of the
        // person. they are the log of the app and the notes of the windows.
        "Deselect All": "全不选",
        "Edit Rule": "编辑规则",
        "Shown in the rules list. Leave empty if you don't need one.": "显示在规则列表中。不需要就留空。",
        "Host names only match when Enable DNS is on in the Proxy menu. IP addresses always work.": "只有在「代理」菜单中打开「启用 DNS」时，主机名才会匹配。IP 地址始终有效。",
        "Enable DNS is off in the Proxy menu, so host names do not match. IP addresses still work.": "「代理」菜单中的「启用 DNS」是关闭的，因此主机名不会匹配。IP 地址仍然有效。",
        "Example: 80; 8000-9000; 3128": "例如：80；8000-9000；3128",
        "Export Proxy Rules": "导出代理规则",
        "Choose a location to save the selected rules": "选择保存所选规则的位置",
        "Export failed: %@": "导出失败：%@",
        "Import Proxy Rules": "导入代理规则",
        "Choose a rules file to import": "选择要导入的规则文件",
        "Failed to import rules: %@": "导入规则失败：%@",
        "Named twice": "重复命名",
        "program(s): %@": "程式：%@",
        "host(s): %@": "主机：%@",
        "another rule": "另一条规则",
        "is in effect": "已生效",
        "is switched off too": "也是关闭的",
        "The rule \"%@\" %@ and names the same:\n%@": "规则「%@」%@，并且命名了同样的内容：\n%@",
        "Also named by a rule that is off": "也被一条已关闭的规则命名",
        "\"%@\" is also named by the rule \"%@\", which is switched off. It can still be used here.": "「%@」也被规则「%@」命名，而那条规则是关闭的。这里仍然可以使用。",
        "Full path": "完整路径",
        "Nothing matches \"%@\".": "没有匹配「%@」的项目。",
        "Every program that matches is already in this rule.": "匹配到的每个程式都已经在这条规则里了。",
        "No programs found.": "没有找到程式。",
        "Programs in yellow are named by a rule that is in effect and cannot be picked.": "黄色的程式已被一条生效的规则命名，不能被选中。",
        "Pick one or more programs. A rule matches a program by its name or its bundle id.": "挑选一个或多个程式。规则按名称或包标识匹配程式。",
        "%@ program(s) picked.": "已挑选 %@ 个程式。",
        "Already named by \"%@\", which is in effect": "已被「%@」命名，而那条规则已生效",
        "Also named by \"%@\", which is switched off": "也被「%@」命名，而那条规则已关闭",
        "\"%@\" is also named by the rule \"%@\", which is switched off. It can still be added.": "「%@」也被规则「%@」命名，而那条规则是关闭的。仍然可以添加。",
        "Add Proxy": "添加代理",
        "Edit Proxy": "编辑代理",
        "Add Chain": "添加代理链",
        "Edit Chain": "编辑代理链",
        "The proxy answers": "该代理有回应",
        "The proxy does not answer, the chain is walked without it": "该代理没有回应，代理链会跳过它",
        "Checking for updates...": "正在检查更新…",
        "Unable to check for updates": "无法检查更新",
        "New version available!": "有新版本可用！",
        "You have the latest version": "已经是最新版本",
        "Download URL not available": "没有下载链接",
        "Starting download...": "开始下载…",
        "Downloading... %.0f%%": "正在下载… %.0f%%",
        "Download complete. Starting installer...": "下载完成，开始安装…",
        "Download error: %@": "下载出错：%@",
        "Download failed": "下载失败",
        "Error downloading update: %@": "下载更新出错：%@",
        "Copy the command": "复制命令",
        "Version %@": "版本 %@",
        "Rule added successfully": "规则添加成功",
        "Unknown error": "未知错误",
        "Cleared %@ rule(s)": "已清除 %@ 条规则",
        "The state of the DNS proxy is not known yet.": "DNS 代理的状态还不清楚。",
        "The DNS proxy is running.": "DNS 代理正在运行。",
        "The DNS proxy is not running.": "DNS 代理没有运行。",
        "ProxiRoute looks in the log of the system extension for it. The window shows it as soon as the extension has written something.": "ProxiRoute 会在系统扩展的日志里找它。扩展一有写入，这个窗口就会显示出来。",
        "%@ queries, %@ answers, %@ names known.": "已知 %@ 个查询、%@ 个回答、%@ 个名字。",
        " Last answer: %@ -> %@.": " 最后回答：%@ → %@。",
        "Saved: %@": "已保存：%@",
        "The DNS proxy is running. %@ queries, %@ answers, %@ names.": "DNS 代理正在运行。%@ 个查询、%@ 个回答、%@ 个名字。",
        "System": "系统",
        "Local": "本地",
        "Remote": "远端",
        "macOS answers the name with the resolver it was given. The proxy server is given the name only when the proxy's own setting says so, otherwise it gets the address.": "macOS 用给它的解析器回答名字。只有当代理服务器自己的设置这样要求时，代理服务器才拿到名字，否则它拿到的是地址。",
        "A resolver on this Mac answers, and the proxy server is always given the address. The proxy server never resolves a name.": "由本机的解析器回答，代理服务器拿到的永远是地址。代理服务器从不解析名字。",
        "The proxy server resolves the name itself. The answer from this Mac is only used to start the connection, so the site is reached even when the local answer is wrong or is an address that only means something here.": "由代理服务器自己解析名字。本机的回答只用来建立连接，所以即使本机的回答是错的、或者只是个在本机才有意义的地址，网站照样能打开。",
        "the address, unless the proxy's own setting asks for the name": "地址，除非代理服务器自己的设置要求给名字",
        "the address": "地址",
        "the name": "名字",
        "resolution %@": "解析方式：%@",
        "leak protection on": "已开启防泄漏",
        "resolvers %@": "解析器 %@",
        "the resolver of the system": "系统解析器",
        "%@ excluded name(s)": "已排除 %@ 个名字",
        "Open ProxiRoute": "打开 ProxiRoute",
        "Quit ProxiRoute": "退出 ProxiRoute",
        "DNS settings saved: %@": "DNS 设置已保存：%@",
        "Failed to load managers: %@": "无法载入管理器：%@",
        "Found %@ saved network configurations of this app. Removing the old ones and writing a single new one.": "本 app 有 %@ 份已保存的网络配置。正在删除旧的那几份，并写入一份新的。",
        "Failed to save preferences: %@": "无法保存设置：%@",
        "Configuration saved": "配置已保存",
        "DNS proxy setup failed: %@. Host name rules and send hostname will not work.": "DNS 代理设置失败：%@。主机名规则和 send hostname 将无法工作。",
        "DNS proxy enabled": "DNS 代理已启用",
        "DNS proxy is off (Enable DNS in the Proxy menu). Host name rules and send hostname do not work.": "DNS 代理已关闭（在「代理」菜单中启用 DNS）。主机名规则和 send hostname 无法工作。",
        "Could not switch the DNS proxy off: %@": "无法关闭 DNS 代理：%@",
        "The DNS proxy entry was off in the system. It is being written again, so host names are known again.": "系统里的 DNS 代理条目是关闭的。正在重新写入，主机名因此又能被认出来。",
        "Failed to reload preferences: %@": "无法重新载入设置：%@",
        "Loaded %@ rule(s) from local storage": "从本地存储载入了 %@ 条规则",
        "Proxy tunnel started": "代理隧道已启动",
        "Failed to start tunnel: %@": "无法启动隧道：%@",
        "%@. macOS says: %@": "%@。macOS 说：%@",
        "Command: %@": "命令：%@",
        "Remove the ProxiRoute entries in System Settings, Network, restart the Mac and open ProxiRoute again. If it still fails, report it with the output of: systemextensionsctl list": "请在「系统设置 → 网络」里删掉 ProxiRoute 的条目，重启 Mac 后再打开 ProxiRoute。如果还是不行，请附上 systemextensionsctl list 的输出来反馈。",
        "Removing the saved network configuration and creating a new one. macOS may ask you to allow it again": "正在删除已保存的网络配置并新建一份。macOS 可能会再次要求你允许",
        "Proxy stopped and extension memory cleared": "代理已停止，扩展的内存已清空",
        "Extension handshake ok (protocol %@, version %@)": "扩展握手成功（协议 %@，版本 %@）",
        "The extension that answered is not this build%@. The rules and the proxies never reach it, so no connection is proxied. Take the older extension out and approve this one.": "回应的扩展不是这个版本%@。规则和代理从未送到它那里，因此没有任何连接被代理。请移除旧的扩展并授权这一个。",
        "The extension does not answer over the provider channel. The tunnel is up, so the extension on the other end is not this build. Take the older extension out and approve this one.": "扩展在 provider 通道上没有回应。隧道已经起来了，因此另一端的扩展不是这个版本。请移除旧的扩展并授权这一个。",
        "The extension does not answer over the provider channel: this build is not signed by a developer, and macOS does not let it talk to its own system extension. The traffic is proxied all the same, and the connections and their traffic are read from the system log. What is lost: the switches the extension reads while it runs, and closing a connection by hand.": "扩展在 provider 通道上没有回应：这个版本没有开发者签名，macOS 不让它与自己的系统扩展通信。流量照样被代理，连接和它们的流量是从系统日志里读出来的。失去的是：扩展运行时读取的那些开关，以及手动关闭连接。",
        "The extension did not answer, so the tunnel is restarted to pick up the change.": "扩展没有回应，因此隧道被重启，以便应用这次改动。",
        "Failed to encode proxy configs": "无法编码代理配置",
        "Proxy configs sent: %@ config(s)": "已送出代理配置：%@ 项",
        "Extension installed successfully": "扩展安装成功",
        "Extension failed: %@": "扩展失败：%@",
        "macOS does not install the system extension from a build that is not signed. Use a signed build, or build from source: the build script signs the app for you.": "macOS 不会从未签名的版本安装系统扩展。请使用已签名的版本，或者从源码构建：构建脚本会替你签名。",
        "macOS wants you to approve ProxiRoute once. Open System Settings > General > Login Items & Extensions > Network Extensions (on macOS 26 and later: Network > VPN & Filters) and switch ProxiRoute on. Until that is done, no traffic can be proxied.": "macOS 需要你一次性授权 ProxiRoute。请打开「系统设置 → 通用 → 登录项与扩展 → 网络扩展」（macOS 26 及以后是「网络 → VPN 与过滤器」）并打开 ProxiRoute。在那之前无法代理任何流量。",

        "Proxy %@ has the type '%@', which ProxiRoute does not know. It was left out.": "代理 %@ 的类型「%@」ProxiRoute 不认识，已被略过。",
        "The profile says HTTP proxy servers are not used, so %@ HTTP proxy/proxies were left out.": "配置说明不使用 HTTP 代理服务器，因此 %@ 个 HTTP 代理被略过。",
        "Proxifier's plain HTTP proxy mode has no CONNECT tunnel. The %@ HTTP proxy/proxies were imported, but ProxiRoute always asks them for a CONNECT tunnel.": "Proxifier 的普通 HTTP 代理模式没有 CONNECT 隧道。%@ 个 HTTP 代理已导入，但 ProxiRoute 总是向它们要 CONNECT 隧道。",
        "Proxy %@ has no address or no port. It was left out.": "代理 %@ 没有地址或没有端口，已被略过。",
        "The chain '%@' has no proxy that is switched on. It was left out, and the rules that named it go direct.": "代理链「%@」里没有打开的代理。它已被略过，指向它的规则走直连。",
        "A rule points at proxy %@, which is not in the profile. It goes direct.": "规则指向的代理 %@ 不在配置里，它走直连。",
        "A rule points at chain %@, which is not in the profile. It goes direct.": "规则指向的代理链 %@ 不在配置里，它走直连。",
        "A rule has the action '%@', which ProxiRoute does not know. It goes direct.": "规则的动作「%@」ProxiRoute 不认识，它走直连。",
        "The profile lets Proxifier detect the DNS settings automatically. The DNS policy was set to 'system'; check it in the DNS settings.": "配置让 Proxifier 自动侦测 DNS 设置。DNS 策略被设成了「system」，可以在 DNS 设置里查看。",
        "The profile tries the local DNS first and the proxy second. ProxiRoute asks the proxy server to resolve the name.": "配置先用本地 DNS、再用代理。ProxiRoute 会让代理服务器去解析名字。",
        "Invalid update URL": "更新链接无效",
        "Failed to check for updates: %@": "检查更新失败：%@",
        "Invalid download URL": "下载链接无效",
        "Nothing to remove": "没有需要删除的东西",
        "Removed the saved %@": "已删除保存的 %@",
        ". Problems: %@": "。问题：%@",
        "This build cannot read the unified log. The App Sandbox is what stops it: logd does not serve the system scope to a sandboxed process, and /usr/bin/log refuses to run in one at all. A build that is not sandboxed reads it without trouble.": "这个版本读不了统一日志。挡住它的是 App 沙盒：logd 不给沙盒进程提供系统域的日志，而 /usr/bin/log 在沙盒里干脆不运行。未沙盒化的版本读它毫无障碍。",
        "The unified log cannot be read: %@": "统一日志读不了：%@",
        "The tool that reads the unified log stopped (status %@).": "读取统一日志的工具退出了（状态 %@）。",
        "The tool that reads the unified log could not be started: %@": "读取统一日志的工具起不来：%@",
        "The tunnel stopped before it was ready": "隧道在准备好之前就停了",
        "The tunnel did not start in 30 seconds": "隧道 30 秒内没有启动",

        "DNS proxy entry": "DNS 代理条目",

        "A rule that names no program says to the proxy that the traffic is ProxiRoute's own: the bundle id of the extension is the name it sees. A proxy that routes by program can then send that traffic its own way.": "没有指定程式的规则会告诉代理：这些流量是 ProxiRoute 自己的流量，代理看到的是扩展的包标识名。按程式分流的代理因此可以把这类流量送到它该去的地方。",

        "The menus macOS draws itself (Edit, View, Window, Help) change to the new language the next time ProxiRoute starts.": "macOS 自己画的四个菜单（编辑、显示、窗口、帮助）会在下次启动 ProxiRoute 时换成新的语言。",

        // the buttons
        "Add": "添加",
        "Add Rule": "添加规则",
        "Save": "保存",
        "Save Rule": "保存规则",
        "Cancel": "取消",
        "Done": "完成",
        "Close": "关闭",
        "Delete": "删除",
        "Edit": "编辑",
        "Clear": "清除",
        "OK": "好",
        "Open": "打开",
        "Import": "导入",
        "Export": "导出",
        "Import Profile...": "导入配置…",
        "New Profile...": "新建配置…",
        "Later": "稍后",
        "Download Now": "立即下载",
        "Update Now": "立即更新",
        "Don't Ask Again": "不再询问",
        "Hide this notice for now": "暂时隐藏此提示",
        "Refresh": "刷新",
        "Check Again": "重新检查",
        "Retest": "重新测试",
        "Test": "测试",
        "Test the chain": "测试代理链",
        "Testing...": "测试中…",
        "Choose...": "选择…",
        "Choose Programs": "选择程序",
        "Add to Rule": "添加到规则",
        "View Release Notes": "查看发布说明",
        "Terminate connection": "终止连接",
        "Terminate all connections of this process": "终止该程序的所有连接",
        "Copy Command": "复制命令",
        "Open System Settings": "打开系统设置",
        "Add a proxy...": "添加代理…",

        // the words of the tables
        "Name": "名称",
        "Type": "类型",
        "Server": "服务器",
        "Auth": "认证",
        "Action": "动作",
        "Application": "应用程序",
        "Bundle ID": "包标识",
        "Proto": "协议",
        "Protocol": "协议",
        "Connections": "连接",
        "Total": "合计",
        "Sent": "已发送",
        "Received": "已接收",
        "Idle": "空闲",
        "Destination": "目标",
        "Target Hosts": "目标主机",
        "Target Ports": "目标端口",
        "Target ports": "目标端口",
        "Target hosts": "目标主机",
        "Process / Bundle Identifier": "进程 / 包标识",
        "Proxy Type": "代理类型",
        "Resolution": "解析",
        "On": "开",
        "Any": "任意",
        "Only my programs": "仅我的程序",
        "No proxy servers configured": "尚未配置代理服务器",
        "No rules configured": "尚未配置规则",
        "No proxy chains yet.": "还没有代理链。",
        "No proxy in this chain yet.": "这条链里还没有代理。",
        "No active connections": "当前没有活动连接",
        "No traffic yet": "还没有流量",
        "Connections that are proxied show up here": "被代理的连接会显示在这里",
        "Every proxy the traffic goes through gets a line here": "流量经过的每个代理在这里都会占一行",
        "No proxy servers configured - add one in Proxy Settings.": "尚未配置代理服务器 —— 请在「代理设置」中添加。",
        "Click 'Add' to configure your first proxy server": "点「添加」来配置第一个代理服务器",
        "Click 'Add Rule' to create your first rule": "点「添加规则」来建立第一条规则",
        "No proxy in this chain": "这条链里没有代理",

        // the hints
        "Optional, e.g. Home SOCKS": "可选，例如 Home SOCKS",
        "Optional, e.g. Home via work": "可选，例如 Home via work",
        "Optional, e.g. Work traffic": "可选，例如 Work traffic",
        "Leave empty if no auth": "无需认证则留空",
        "Select proxy type": "选择代理类型",
        "Search by name, bundle id or path": "按名称、包标识或路径搜索",
        "Search logs...": "搜索日志…",
        "Host:": "主机：",
        "Port:": "端口：",
        "Password": "密码",
        "Proxies, in order": "代理，按顺序",
        "Upstream resolvers": "上游解析器",
        "Excluded domains": "排除的域名",
        "Current Version:": "当前版本：",
        "Latest Version:": "最新版本：",
        "New Version:": "新版本：",
        "Update Available": "有可用更新",
        "A new version of ProxiRoute is available!": "ProxiRoute 有新版本可用！",
        "License: MIT": "许可证：MIT",
        "Author: Sourav Kalal / InterceptSuite": "作者：Sourav Kalal / InterceptSuite",
        "Website:": "网站：",
        "GitHub:": "GitHub：",
        "Universal proxy client for macOS applications": "适用于 macOS 应用程序的通用代理客户端",

        // the sentences
        "On: the proxy gets the host name the app looked up. Off: it gets the IP address. Turn it off for a proxy that can't resolve the names your Mac can.": "开：代理拿到的是程序查到的主机名。关：代理拿到的是 IP 地址。对于无法解析你这台 Mac 能解析的域名的代理，请关掉它。",
        "Host names are only sent when Enable DNS is on in the Proxy menu.": "只有在「Proxy」菜单里打开「启用 DNS」时，才会发送主机名。",
        "Send the application name to the proxy server": "把应用名称送给代理服务器",
        "The proxy server is told which application the traffic comes from, so it can route by application. HTTP proxies get it in a header, SOCKS proxies in the user name field.": "代理服务器会知道流量来自哪个程序，因此可以按程序分流。HTTP 代理由请求头携带，SOCKS 代理由用户名字段携带。",
        "A SOCKS5 proxy that needs a user name of its own keeps it: there is only one user name field.": "需要自带用户名的 SOCKS5 代理会保留自己的用户名：用户名字段只有一个。",
        "A chain sends a rule's traffic through several proxies, one after the other. Add one, then pick it as the action of a rule.": "代理链让规则的流量依次经过多个代理。先添加一条，再把它设为某个规则的动作。",
        "A rule that uses a chain sends its traffic through every proxy of the chain, in order.": "使用代理链的规则，其流量会按顺序经过链中的每一个代理。",
        "The first proxy is asked to open a tunnel to the second one, and so on. The last proxy is the one that reaches the destination.": "第一个代理负责打通到第二个代理的隧道，依次类推。最后一个代理才是真正连到目标的。",
        "Every proxy of the chain is asked whether it answers.": "链中的每个代理都会被问一句：它答不答。",
        "The extension asks the same question every ten minutes and skips a hop that does not answer.": "扩展每十分钟问一次同样的问题，并跳过没有响应的跳板。",
        "Does not answer: ": "无响应：",
        "answers": "有响应",
        "does not answer": "无响应",
        "does not answer as a socks5 server": "不像 socks5 服务器那样应答",
        "This chain will be permanently removed.": "这条代理链将被永久删除。",
        "This proxy will be permanently removed.": "这个代理将被永久删除。",
        "Delete Chain?": "删除代理链？",
        "Delete Proxy?": "删除代理？",
        "The marked entries cannot work. Fix them before saving.": "标记出来的条目无法工作，保存前请先修正。",
        "Target hosts and ports only apply to TCP. UDP rules match on the app (bundle id) only.": "目标主机和端口只对 TCP 有效。UDP 规则只能按程序（bundle id）匹配。",
        "UDP only works with SOCKS5 proxy. HTTP proxies do not support UDP.": "UDP 只能通过 SOCKS5 代理，HTTP 代理不支持 UDP。",
        "UDP only works with a SOCKS5 proxy. Not all SOCKS5 proxies support UDP by default, and SOCKS5 UDP support does not guarantee QUIC or HTTP/3 works - verify your proxy supports these separately.": "UDP 只能通过 SOCKS5 代理。并非所有 SOCKS5 代理默认都支持 UDP，而且支持 SOCKS5 UDP 并不保证 QUIC 或 HTTP/3 能用 —— 这些要另外确认。",
        "Matches the bundle id or the process name, one per line. Examples: com.apple.Safari; curl; Google Chrome Helper; *chrome*; *": "每行匹配 bundle id 或进程名。例如：com.apple.Safari; curl; Google Chrome Helper; *chrome*; *",
        "One per line. IP: 127.0.0.1; 192.168.1.*; 10.0.0.1-10.0.0.254; ::1   Domain: github.com; *.github.com; *google*": "每行一个。IP：127.0.0.1; 192.168.1.*; 10.0.0.1-10.0.0.254; ::1　域名：github.com; *.github.com; *google*",
        "One per line, for example 1.1.1.1 or 8.8.8.8:53. The first one that can be read answers every name that is not excluded.": "每行一个，例如 1.1.1.1 或 8.8.8.8:53。第一个可用的解析器会回答所有未被排除的域名。",
        "One per line. An excluded name is answered by the resolver of this Mac and never becomes a proxy destination. Use *.example.com for everything below a domain.": "每行一个。被排除的域名由本机解析器回答，永远不会成为代理目标。用 *.example.com 匹配某个域名下的全部子域。",
        "Detect the system resolver automatically": "自动检测系统解析器",
        "Leak protection (proxy server always resolves)": "防泄漏（始终由代理服务器解析）",
        "Let proxy resolve DNS (send hostname)": "让代理解析 DNS（发送主机名）",
        "What the three settings mean": "这三项设置是什么意思",
        "With this off and no resolver listed above, the resolver of this Mac answers. With this on, the resolver of this Mac is used when the list above is empty. It does not decide whether DNS is watched: the DNS proxy always takes the queries, so that the names of the addresses are known.": "关闭且上面没有列解析器时，由本机解析器回答。打开时，上面列表为空则使用本机解析器。它并不决定是否监视 DNS：DNS 代理总是接管查询，这样才能知道地址对应的域名。",
        "The proxy server is always given the host name, whatever its own setting says. The address this Mac resolved can then never be the address the proxy connects to. The query itself still goes to the resolver of this Mac, so this is not a way to hide the names that are looked up.": "无论代理服务器自身怎么设置，它拿到的永远是主机名。这样本机解析出来的地址就不可能是代理去连的地址。查询本身仍然发给本机的解析器，所以这不是隐藏所查询域名的办法。",
        "The DNS proxy entry is off in the system. ProxiRoute writes it again while the tunnel runs, but the names of the addresses are unknown until then.": "系统里的 DNS 代理项被关掉了。ProxiRoute 会在隧道运行时重新写入，但在那之前地址对应的域名是未知的。",

        // the tabs and the notices of the main window
        "Statistics": "统计",
        "Live Connections": "活动连接",
        "Activity Logs": "活动日志",
        "Details": "详情",
        "not seen": "未记录",
        "Hide details": "隐藏详情",

        // the notices about the extension
        "macOS bound the tunnel to an extension whose app is no longer installed. Another build of ProxiRoute is still registered in the system (its app was removed), and the system picked that one, so no traffic is proxied. Copy the command and run it in the Terminal to take the old extension out, then start the proxy again. macOS finishes the removal at the next restart.": "macOS 把隧道绑定到了一个应用已被删除的扩展上。系统里还登记着另一个版本的 ProxiRoute（它的应用已被移除），系统选中了那个，所以没有任何流量被代理。复制下面的命令到终端里运行，把旧扩展移除，然后重新启动代理。macOS 会在下次重启时完成移除。",
        "The extension does not answer. The tunnel is up, so the extension on the other end is not this build.": "扩展没有回应。隧道已经建立，所以另一端的扩展不是当前这个版本。",
        "The extension does not answer. The tunnel is up, so the extension on the other end is not this build. Take the old record out with the command below, then start the proxy again.": "扩展没有回应。隧道已经建立，所以另一端的扩展不是当前这个版本。用下面的命令移除旧记录，然后重新启动代理。",
        "This build is not signed by a developer, so the switches the extension reads while it runs are not available. The traffic is proxied all the same, and the connections and their traffic come from the system log.": "当前版本没有开发者签名，所以扩展运行期间读取的那些开关不可用。流量照常被代理，连接和流量数据来自系统日志。",
        "The extension does not answer over the provider channel. macOS checks that channel against the app's signature, and a build that is not signed by a developer gets no message through it.": "扩展在 provider 通道上没有回应。macOS 会用应用的签名校验该通道，没有开发者签名的版本无法通过它传递消息。",
        "What that costs: the switches the extension reads while it runs, and closing a connection by hand. Everything else is read from the unified log instead: the extension writes every decision it made there, and it writes the traffic of the open flows there as well, so the connections, their traffic and the activity log are all there. The traffic itself is proxied either way: the rules, the proxies and the passwords went with the start of the tunnel.": "代价是：扩展运行期间读取的那些开关，以及手动断开连接。其余的信息都改从统一日志读取 —— 扩展把每一个决定都写在那里，也把打开中的流量写在那里，所以连接、流量和活动日志都在。流量本身无论如何都会被代理：规则、代理和密码都是随隧道启动一起送过去的。",
        "Sign the app with a Developer ID certificate to get the running switches and the hand-made disconnects as well.": "用 Developer ID 证书签名应用，就能同时得到运行中的开关和手动断开连接。",
        "The system bound the tunnel to another, older ProxiRoute extension%@. That one does not understand this version's rules, so nothing is proxied. Take it out with the command below, then switch ProxiRoute on in System Settings > General > Login Items & Extensions > Network Extensions.": "系统把隧道绑定到了另一个较旧的 ProxiRoute 扩展%@。那个扩展看不懂当前版本的规则，所以没有任何流量被代理。用下面的命令把它移除，然后在「系统设置 > 通用 > 登录项与扩展 > 网络扩展」里打开 ProxiRoute。",

        // the texts with a name in them
        "Delete \"%@\"": "删除「%@」",
        "Export \"%@\"...": "导出「%@」…",
        "Rename \"%@\"...": "重命名「%@」…",
        "Profile: %@": "配置：%@",
        "Imported '%@'": "已导入「%@」",
        "New Profile": "新建配置",
        "Rename Profile": "重命名配置",
        "Enter a name for the new profile.": "请为新配置取一个名字。",
        "Enter a new name.": "请输入新名字。",
        "Export Profile": "导出配置",
        "Import Profile": "导入配置",
        "ProxiRoute needs your approval": "ProxiRoute 需要你的授权",
        "Open System Settings > General > Login Items & Extensions > Network Extensions, and switch ProxiRoute on.\n\nUntil that is done, no traffic can be proxied.": "请打开「系统设置 > 通用 > 登录项与扩展 > 网络扩展」，把 ProxiRoute 打开。\n\n在这之前，任何流量都无法被代理。",
        "Take the older ProxiRoute extensions out": "移除较旧的 ProxiRoute 扩展",
        "Run this in the Terminal. It removes the ProxiRoute extensions that were signed by another team, so the system can only use this build.\n\nAfter that, switch ProxiRoute on in System Settings > General > Login Items & Extensions > Network Extensions.": "请在终端里运行这条命令。它会移除由别的团队签名的 ProxiRoute 扩展，这样系统就只能使用当前这个版本。\n\n之后，请在「系统设置 > 通用 > 登录项与扩展 > 网络扩展」里打开 ProxiRoute。",
        "%@ proxy server(s), %@ rule(s) and %@ chain(s) were imported.\n\nSome Proxifier settings have no counterpart in ProxiRoute. Here is what was done with them:": "已导入 %@ 个代理服务器、%@ 条规则和 %@ 条代理链。\n\nProxifier 的部分设置在 ProxiRoute 里没有对应项，处理情况如下：",
        "This rule uses the chain \"%@\". A chain carries TCP only, UDP traffic of this rule goes direct.": "这条规则使用代理链「%@」。代理链只承载 TCP，该规则的 UDP 流量会直连。",
        "%@ rule(s) use this proxy and will be set to Direct.": "%@ 条规则使用这个代理，它们会被改为直连。",
        "%@ rule(s) use this chain and will be set to Direct.": "%@ 条规则使用这条代理链，它们会被改为直连。",
        "%@ program(s) running": "%@ 个程序正在运行",
        "%@ (off)": "%@（已关闭）",

        // the texts of the forms
        "Rule Name": "规则名称",
        "Proxy IP/Domain": "代理 IP/域名",
        "Proxy Port": "代理端口",
        "Username": "用户名",
        "Invalid proxy IP/domain": "代理 IP/域名无效",
        "Port must be between 1 and 65535": "端口必须在 1 到 65535 之间",
        "Port must be a valid number": "端口必须是数字",
        "Chain": "代理链",

        // what is wrong with a chain
        "The chain has no proxy in it.": "这条代理链里没有代理。",
        "Proxy %@ of the chain does not exist.": "代理链中的第 %@ 个代理不存在。",
        "Proxy %@ of the chain has the type '%@', it must be socks5, socks4 or http.": "代理链中的第 %@ 个代理类型是「%@」，必须是 socks5、socks4 或 http。",
        "Proxy %@ of the chain is an HTTP proxy. Only the last proxy of a chain may be one.": "代理链中的第 %@ 个代理是 HTTP 代理。代理链中只有最后一个可以是 HTTP 代理。",
        "The same proxy is used twice in a row.": "同一个代理连续用了两次。"
    ]
}

// The language of the app, as something a view can watch.
//
// The views read the strings through L10n, which reads the language from here.
// A view that wants to be redrawn when the language changes holds this object,
// so the change reaches the window without a restart.
final class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()

    // the key the language is remembered under
    private static let storageKey = "appLanguage"

    @Published var language: L10n.Language {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: LocalizationManager.storageKey)
            // The menus macOS draws itself (Edit, View, Window, Help) are drawn
            // in the language of the app bundle, and the bundle reads that
            // language once, when the process starts. The language of the app is
            // put in front of them, so that they follow the choice that was
            // made here and not the one of the system - from the next start of
            // the app on, because the bundle does not read it again.
            UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
        }
    }

    private init() {
        let stored = UserDefaults.standard.string(forKey: LocalizationManager.storageKey)
        // the language of the system, when it is one the app speaks
        let system = Locale.preferredLanguages.first.map {
            L10n.Language(rawValue: $0) ?? (($0 as NSString).hasPrefix("zh") ? L10n.Language.chinese : nil)
        } ?? nil
        language = stored.flatMap { L10n.Language(rawValue: $0) } ?? system ?? .english
    }
}
