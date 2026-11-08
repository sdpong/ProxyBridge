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
    static func formatted(_ text: String, arguments: [String], language: Language) -> String {
        var out = translate(text, language: language)
        for argument in arguments {
            out = out.replacingOccurrences(of: "%@", with: argument)
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
        "About ProxyBridge": "关于 ProxyBridge",
        "Check for Updates": "检查更新",
        "Check for Updates...": "检查更新…",
        "Documentation": "文档",
        "Enable Traffic Logging": "启用流量日志",
        "Enable DNS": "启用 DNS",
        "Close to Menu Bar": "关闭时收进菜单栏",
        "Keep Proxy Running in Background": "在后台保持代理运行",
        "Run at Startup": "开机启动",
        "Approve ProxyBridge in System Settings...": "在系统设置中授权 ProxyBridge…",
        "Take Out Older ProxyBridge Extensions...": "移除较旧的 ProxyBridge 扩展…",

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
        "A new version of ProxyBridge is available!": "ProxyBridge 有新版本可用！",
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
        "The DNS proxy entry is off in the system. ProxyBridge writes it again while the tunnel runs, but the names of the addresses are unknown until then.": "系统里的 DNS 代理项被关掉了。ProxyBridge 会在隧道运行时重新写入，但在那之前地址对应的域名是未知的。",

        // the tabs and the notices of the main window
        "Statistics": "统计",
        "Live Connections": "活动连接",
        "Activity Logs": "活动日志",
        "Details": "详情",
        "not seen": "未记录",
        "Hide details": "隐藏详情",

        // the notices about the extension
        "macOS bound the tunnel to an extension whose app is no longer installed. Another build of ProxyBridge is still registered in the system (its app was removed), and the system picked that one, so no traffic is proxied. Copy the command and run it in the Terminal to take the old extension out, then start the proxy again. macOS finishes the removal at the next restart.": "macOS 把隧道绑定到了一个应用已被删除的扩展上。系统里还登记着另一个版本的 ProxyBridge（它的应用已被移除），系统选中了那个，所以没有任何流量被代理。复制下面的命令到终端里运行，把旧扩展移除，然后重新启动代理。macOS 会在下次重启时完成移除。",
        "The extension does not answer. The tunnel is up, so the extension on the other end is not this build.": "扩展没有回应。隧道已经建立，所以另一端的扩展不是当前这个版本。",
        "The extension does not answer. The tunnel is up, so the extension on the other end is not this build. Take the old record out with the command below, then start the proxy again.": "扩展没有回应。隧道已经建立，所以另一端的扩展不是当前这个版本。用下面的命令移除旧记录，然后重新启动代理。",
        "This build is not signed by a developer, so the switches the extension reads while it runs are not available. The traffic is proxied all the same, and the connections and their traffic come from the system log.": "当前版本没有开发者签名，所以扩展运行期间读取的那些开关不可用。流量照常被代理，连接和流量数据来自系统日志。",
        "The extension does not answer over the provider channel. macOS checks that channel against the app's signature, and a build that is not signed by a developer gets no message through it.": "扩展在 provider 通道上没有回应。macOS 会用应用的签名校验该通道，没有开发者签名的版本无法通过它传递消息。",
        "What that costs: the switches the extension reads while it runs, and closing a connection by hand. Everything else is read from the unified log instead: the extension writes every decision it made there, and it writes the traffic of the open flows there as well, so the connections, their traffic and the activity log are all there. The traffic itself is proxied either way: the rules, the proxies and the passwords went with the start of the tunnel.": "代价是：扩展运行期间读取的那些开关，以及手动断开连接。其余的信息都改从统一日志读取 —— 扩展把每一个决定都写在那里，也把打开中的流量写在那里，所以连接、流量和活动日志都在。流量本身无论如何都会被代理：规则、代理和密码都是随隧道启动一起送过去的。",
        "Sign the app with a Developer ID certificate to get the running switches and the hand-made disconnects as well.": "用 Developer ID 证书签名应用，就能同时得到运行中的开关和手动断开连接。",
        "The system bound the tunnel to another, older ProxyBridge extension%@. That one does not understand this version's rules, so nothing is proxied. Take it out with the command below, then switch ProxyBridge on in System Settings > General > Login Items & Extensions > Network Extensions.": "系统把隧道绑定到了另一个较旧的 ProxyBridge 扩展%@。那个扩展看不懂当前版本的规则，所以没有任何流量被代理。用下面的命令把它移除，然后在「系统设置 > 通用 > 登录项与扩展 > 网络扩展」里打开 ProxyBridge。",

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
        "ProxyBridge needs your approval": "ProxyBridge 需要你的授权",
        "Open System Settings > General > Login Items & Extensions > Network Extensions, and switch ProxyBridge on.\n\nUntil that is done, no traffic can be proxied.": "请打开「系统设置 > 通用 > 登录项与扩展 > 网络扩展」，把 ProxyBridge 打开。\n\n在这之前，任何流量都无法被代理。",
        "Take the older ProxyBridge extensions out": "移除较旧的 ProxyBridge 扩展",
        "Run this in the Terminal. It removes the ProxyBridge extensions that were signed by another team, so the system can only use this build.\n\nAfter that, switch ProxyBridge on in System Settings > General > Login Items & Extensions > Network Extensions.": "请在终端里运行这条命令。它会移除由别的团队签名的 ProxyBridge 扩展，这样系统就只能使用当前这个版本。\n\n之后，请在「系统设置 > 通用 > 登录项与扩展 > 网络扩展」里打开 ProxyBridge。",
        "%@ proxy server(s), %@ rule(s) and %@ chain(s) were imported.\n\nSome Proxifier settings have no counterpart in ProxyBridge. Here is what was done with them:": "已导入 %@ 个代理服务器、%@ 条规则和 %@ 条代理链。\n\nProxifier 的部分设置在 ProxyBridge 里没有对应项，处理情况如下：",
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
