# ProxyBridge 超集路线图

> 目标：把 ProxyBridge 做成**功能超集于 [Proxifier](https://www.proxifier.com/)** 的开源透明代理客户端。
> 本文件是 fork（`sdpong/ProxyBridge`）的路线图，上游仓库不包含它。

## English abstract

Goal: grow ProxyBridge into an open-source transparent proxy client that is a **strict superset of
Proxifier's feature set**. This roadmap is fork-specific (it does not exist upstream). Android is a
**part of the mainline**, not a separate project: it shares the same rule model, the same flow
terminator semantics and the same DNS policy layer as Windows and macOS.

Status legend: `[x]` done · `[~]` in progress · `[ ]` not started.

---

## 阶段 1 · 通道可中断 + 进程过滤 + DNS 透明代理

解决用户最直接的痛点：**「有些流量会吊死」**。Proxifier 的 Connections 工具栏有
"close a connection" 和 "terminate a process"，ProxyBridge 目前完全没有。

| 端 | 状态 | 内容 |
|---|---|---|
| Windows 引擎 | `[x]` | `ProxyBridge_KillFlow(id)`：TCP 走 `relay_abort()`（shutdown + CancelIoEx），UDP 打 `killed` 标记后丢包 |
| Windows IPC | `[x]` | `PBOP_KILL_FLOW`（id 拆两个 u32，低位在前），`PB_PROTO_VERSION` 6 → 7 |
| Windows GUI | `[x]` | Live Connections 右键菜单（终止此连接 / 终止该进程的所有连接）+ 新增「空闲」列 |
| Windows 测试 | `[x]` | `test_flows`（真连真断）、`test_service`（协议编解码）、`test_main_ui`（GUI 核函数） |
| macOS 扩展 | `[x]` | `LiveFlowRegistry` 流注册表 + `getFlows` / `killFlow` 扩展消息指令 |
| macOS GUI | `[x]` | 新增「Live Connections」标签页：活动连接表 + 右键终止（终止此连接 / 终止该进程的所有连接） |
| macOS DNS | `[x]` | DNS 策略层：`DNSPolicy`（三选一策略 / 排除名单 / 上游解析器 / 自动检测 / 防泄漏）+ `DNSParser`（可脱离 NetworkExtension 单测）+ App 侧「DNS Settings」窗口 |
| Android | `[ ]` | 并入主线，见下方「Android 并入主线」 |

### macOS DNS 策略层（本阶段实际交付）

1. **`extension/DNSPolicy.swift`**（纯模型，不含 NetworkExtension 类型，可单独跑逻辑测试）：
   - **三选一策略**：`system`（系统解析器应答，代理按自己的设置决定收主机名还是地址）/
     `local`（本机解析器应答，代理**只**拿地址）/ `remote`（**代理服务器自己解析**，
     本地应答只是引导）。
   - **排除名单**：`example.com` 只匹配自己，`*.example.com` 匹配其下所有名字，`*` 匹配全部。
     被排除的名字**根本不记录**进 `DNSMapStore`，所以永远不会成为代理的目标地址。
   - **上游解析器可指定**：逐个回退，第一个不可用就用下一个；未指定时用系统给的那个。
   - **自动检测**：关掉且没配解析器时，DNS 代理**不接管**流量，交给 macOS 正常解析。
   - **防泄漏开关**：无论策略与代理自身设置如何，代理服务器**总是**拿到主机名，
     本地解析出来的地址不可能成为代理实际连接的目标。
2. **`extension/DNSParser.swift`**：从 `DNSProxyProvider.swift` 拆出，并新增 `questionName()`
   （查询名要在应答回来之前就拿到，才能决定用哪个解析器、名字是否被排除）。
3. **策略怎么送达 DNS provider**：`sendProviderMessage` 只存在于 `NETunnelProviderSession`，
   DNS provider **没有**可发消息的 session。策略因此经 App Group 共享容器落盘
   （`dns_policy.json`）：App → 透明代理 provider → 共享容器 → DNS provider 读取
   （最多 2 秒缓存一次，避免每个 DNS 查询都读盘）。
4. **透明代理侧**：发主机名还是发地址由策略决定，策略说「地址」就绝不发名字，
   策略说「主机名」就绝不发地址；`system` 模式维持原有的按代理设置行为。

### 关键设计决策

1. **TCP 终止复用已有的 `relay_abort()`**，不新写中断原语——`shutdown` + `CancelIoEx` 已经能让
   应用侧看到连接死亡。
2. **UDP 没有连接可关**，改为语义正确的「标记丢弃」：`udp_flow_validate()` 对 killed 流仍返回
   TRUE（包留在代理路径内，**绝不回落到直连**），但中继侧 `get_connection_full_x()` 返回 FALSE
   丢包；不刷新 `last_activity`，让条目 20 秒自然老化，应用之后可以重新建流。
3. **空闲时长列不改协议**：引擎只报字节计数器，GUI 在两次轮询间比较 `(sent+received)` 变化来
   判定空闲，零协议改动。
4. **GUI 右键菜单用 ListView 子类化**（`SetWindowSubclass`）而不是父窗口 `WM_CONTEXTMENU`——
   父窗口收到的 `WM_CONTEXTMENU` 的 lParam 是屏幕坐标，而且系统 ListView 自带菜单会干扰。
5. **DLL 侧对 `KillFlow` 做可选绑定**：旧版 core DLL 仍能加载，GUI 检测到指针为 NULL 就禁用该操作。
6. **协议版本必须递增**：GUI 与服务握手时比对 `PB_PROTO_VERSION`，不匹配直接拒绝连接，
   避免旧 GUI 误发新指令。
7. **macOS 的流注册表单独成文件**（`extension/LiveFlowRegistry.swift`）：它不认识
   NetworkExtension 的类型，拆除动作由调用方以闭包传入，所以这份逻辑可以脱离 AppKit/NE
   单独编译成逻辑测试（`MacOS/tests/logic/liveflow_tests.swift`）。
8. **macOS 的流描述符必须显式清理**：握手的每一条失败路径都统一走 `closeRelay()`，
   否则 `ObjectIdentifier(connection)` 被复用时，新连接会继承上一条流的应用名和目标地址。

---

## 阶段 2 · 进程选择器

| 端 | 状态 | 内容 |
|---|---|---|
| Windows | `[x]` | 已有进程选择器（`S_PP_*`），支持系统进程 |
| macOS | `[x]` | 「Choose...」进程选择器：内核进程表枚举（含系统守护进程），可按可执行名 / bundle id / 完整路径加入规则 |
| Android | `[ ]` | `ConnectivityManager.getConnectionOwnerUid()`（API 29+）/ `NetworkCapabilities.getOwnerUid()`（API 30+，VPN 场景会填充）反查 UID |

> **Android 10+ 已封锁 `/proc/net`**，不能沿用 Linux 的老路子；必须走 `ConnectivityManager` 官方 API。

macOS 侧已确认 `proc_pidpath` 在扩展里可直接使用（`AppProxyProvider.swift:447`），
**不需要额外 entitlement**。规则匹配同时接受 bundle id 和可执行名（`matchesProcess(bundleId:processName:)`）。

### macOS 进程枚举是怎么做到的（实测结论）

App 沙盒**不允许**枚举进程，实测结论（本机沙盒 App 验证）：

| 手段 | 沙盒内结果 |
|---|---|
| `proc_listpids()` | **被封锁**（返回 0） |
| `posix_spawn("/bin/ps")` | **被封锁**（EPERM） |
| `sysctl(KERN_PROC_ALL)` | **可用**（约 1400 个进程） |
| `proc_pidpath(pid)` | **可用**（可读任意进程的完整路径） |
| `proc_pidinfo(PROC_PIDT_SHORTBSDINFO)` | **可用**（可读进程属主 uid） |
| `NSWorkspace.runningApplications` | 可用，但只有 GUI 应用，漏掉命令行工具与守护进程 |

因此进程列表走 `sysctl(KERN_PROC_ALL)` 读内核进程表，再用 `proc_pidpath` 取完整路径、
`proc_pidinfo` 取属主（**注意**：`PROC_PIDT_SHORTBSDINFO` 对应的是 `proc_bsdshortinfo`，
不是 `proc_bsdinfo`，用错结构体 uid 会读错偏移）、`Bundle(path:)` 取 bundle id。
1400 个进程枚举一次约 60ms，只在打开选择器时做一次。

取 bundle id 时取**最内层**的 `.app`：一个 App 的 helper 住在它自己内嵌的 bundle 里，
那才是属于该进程的 bundle。

---

## 阶段 3 · DNS 策略层

三选一策略（本地 / 远端 / 系统）、排除名单、自动检测、上游解析器可指定、防泄漏开关。

macOS 的 `NEDNSProxyProvider` 拦截层**已经存在**，缺的是策略层而不是拦截层。
Windows / Android 走各自的平台机制，但语义要对齐。

| 端 | 状态 | 内容 |
|---|---|---|
| macOS | `[x]` | 策略层已落地（见上方「macOS DNS 策略层」）：三选一策略、排除名单、上游解析器、自动检测、防泄漏开关 |
| Windows | `[x]` | 策略层已落地（见下方「Windows DNS 策略层」）：同样的三选一策略、排除名单、上游解析器、自动检测、防泄漏开关。profile 用**同一套键名**（`dnsPolicy` / `mode` / `excludedDomains` / `upstreamResolvers` / `autoDetectUpstream` / `leakProtection`），所以一个配置文件在两端意思相同 |
| Android | `[ ]` | 同上；Android 的 DNS 泄漏问题最突出，应优先落地 |

### Windows DNS 策略层（本阶段实际交付）

1. **引擎侧新文件 `src\pb_dnspolicy.c`**：策略本体、排除名单匹配、解析器规范化、
   引擎自己发 DNS 查询并解析应答的最小客户端。
2. **排除的名字根本不记录**：名字缓存是引擎学到名字的唯一入口，
   所以不记录就等于代理永远学不到它——排除名单因此是真的排除，不是「记录了但不发」。
3. **策略压过每代理的开关**：远程模式下即使代理配置写着「发 IP」，引擎也把名字交给代理；
   排除名单下即使代理配置写着「发域名」，引擎也只发地址。
4. **本地模式下引擎自己解析**：代理拿到的是用户指定解析器的答案，不是应用自己解析器的答案。
   解析结果按名字缓存 60 秒，避免每个连接都问一次。
5. **走管道**：协议版本升到 8，新增 `PBOP_SET_DNS_POLICY` / `PBOP_GET_DNS_POLICY`；
   策略存在 profile 里，GUI 有「DNS Settings」窗口，CLI 从 profile 读。

> **两端唯一不能一致的地方**（已写进 `FORK-NOTES.md`）：
> macOS 的系统扩展能替应用回答 DNS 查询，所以「上游解析器」决定的是**应用**拿到什么答案；
> Windows 上应用永远先问自己的解析器，所以「上游解析器」决定的是**代理**被告知什么。
> 名字的匹配规则、三选一策略的语义、排除名单的行为、profile 的键名，两端完全一致。

---

## 阶段 4 · 高级能力

| 能力 | 状态 | 说明 |
|---|---|---|
| 代理链（冗余 / 负载均衡） | `[~]` | macOS：**简单链已落地**（`Proxy Chains` 窗口 + 规则动作选链 + 扩展逐跳握手）。Windows：**简单链也已落地**（引擎链表 + 多跳握手 + `Proxy Chains` 窗口 + profile + CLI）。冗余 / 负载均衡链类型仍待做 |
| **Proxifier 配置导入（.ppx）** | `[x]` | macOS 与 Windows **两端都能读** Proxifier 导出的 `.ppx`（XML）。映射规格见 [docs/PPX-IMPORT.md](PPX-IMPORT.md)；导入落在**新配置**里，已有配置不动；映射不了的 Proxifier 特性给警告，不静默丢弃 |
| 流量统计面板 | `[ ]` | |
| 托盘流量图 | `[ ]` | |
| Proxy Checker 延迟测量 | `[x]` | Windows 与 macOS 的测试都已报出毫秒数（Windows `TestProxyConfigEx`、macOS `ProxyCheckerView` 的 Test 3） |
| Traffic dump | `[ ]` | |
| 手动代理化 | `[ ]` | |
| 规则绑定网卡 | `[ ]` | |
| 更多代理协议 | `[~]` | **SOCKS4 / SOCKS4a 两端都已落地**（macOS：代理类型下拉、扩展握手、代理检查器、链中可用；Windows：引擎握手、GUI 类型下拉、协议测试）。HTTPS 代理（到代理走 TLS）仍待做 |
| 代理认证增强 | `[ ]` | NTLM / Kerberos / 交互式登录弹窗 / 自定义 Label / Authentication URL |

### macOS 代理链（本阶段实际交付）

1. **链就是一组有序的代理 id**：规则的 action 用 `chain:<id>` 前缀指向一条链，
   前缀保证链和代理永远不会互相认错。
2. **逐跳握手**：第一跳向「下一个代理」要隧道，而不是向目标要隧道；最后一跳才拿真实目标。
   中间跳必须走域名，把名字原样交出去让那一跳去解析。
3. **只有最后一跳允许是 HTTP 代理**：HTTP CONNECT 的应答可能把隧道数据留在缓冲区里，
   下一跳的握手会把它当成自己的应答读走，所以中间的跳只能是 SOCKS5。
   App 与扩展各有一份校验，逻辑测试比对两边的判定一致，防止说法漂移。
4. **链不能带 UDP**：SOCKS5 的 UDP ASSOCIATE 是独立会话，串不起来。规则选中链时，
   GUI 明确提示「UDP 走直连」，扩展也明确记录一次，不静默回落。
5. **链跟着 profile 走**：导出 / 导入 / 改名 / 删除都带着链；删除链时，指向它的规则改成 DIRECT。
6. **CLI 同样支持**：`setProxyConfigs` 消息带上 `chains`，命令行从 profile 读链。

> 冗余链（故障转移）与负载均衡链（可按 PID 粘滞）仍待实现：它们改变的是「选哪一跳」的策略，
> 与简单链的逐跳握手是正交的。

### Windows 代理链（本阶段实际交付）

1. **链 id 有自己的号段**（`PB_CHAIN_ID_BASE = 1000` 起），规则的链 id 放在规则原有的代理字段里。
   这样**规则模型、规则 API、规则 IPC、连接跟踪热路径全都不用改**：走链的规则就是一条普通规则，
   链和代理也永远不会互相认错。macOS 用的是 action 里的 `chain:` 前缀，道理一样。
2. **引擎侧新文件 `src\pb_chain.c`**：链表 + 校验。校验规则与 macOS 完全一致——
   至少一跳、每跳必须是存在的代理、同一代理不能连续两跳、**只有最后一跳可以是 HTTP 代理**
   （HTTP CONNECT 的应答可能把隧道数据留在缓冲区里，下一跳的握手会把它当成自己的应答读走）。
3. **逐跳握手**（`src\pb_relay.c`）：第一跳向「下一个代理」要隧道，只有最后一跳拿真实目标；
   中间跳走域名，把名字原样交出去让那一跳去解析。
4. **删链时指向它的规则改 DIRECT**：与 macOS 同款语义，不留一条指向不存在东西的规则。
5. **链坏了就走直连**：链不存在、或者链里的代理没了，规则的动作降级成 DIRECT；
   UDP 不能走链（SOCKS5 的 UDP ASSOCIATE 是独立会话，串不起来），也走直连。
   这两条与 macOS 一致，macOS 还会明确记一条日志，Windows 这边同样记录。
6. **profile 用同一套键名**：`proxyChains`，里面是 `{id, name, proxies}`，
   与 macOS 导出的 profile 一致（macOS 的 proxy id 是 UUID 字符串，Windows 是数字）。
7. **CLI 同样支持**：CLI 从 profile 读 `proxyChains`，先把链交给引擎，再把规则接上去。

> **两端一致 / 不一致**：链的**语义**（能放什么、坏了怎么办、UDP 怎么办、删了怎么办）两端一致，
> 链的**表示**按平台各自的规则模型来（macOS action 前缀 vs Windows 号段），
> 但 profile 里的键名与形状一致，一个配置文件在两端意思相同。

---

## 网关模式（下一轮 · 只做 macOS）

**目标**：网络里的其他终端**不改代理配置**（只把网关指过来），流量按 ProxiRoute 的规则走代理，
并在本机的统计与活动连接里按来源分开显示。

**完整方案、权限模型、阶段划分与待实测清单见 [docs/GATEWAY.md](GATEWAY.md)。**

三件事决定了它的形状（都查证过，不是猜测）：

| 事实 | 影响 |
|---|---|
| NetworkExtension 的四个 provider **都只管本机**（Apple 文档原文），本 fork 的扩展是 `NETransparentProxyProvider`（`extension/AppProxyProvider.swift:392`） | 网关是**另一条数据面**，不是「打开转发开关」 |
| macOS 转发必须 root：`pfctl` 非 root 读都 Permission denied、`sysctl -w net.inet.ip.forwarding=1` 非 root 是 Operation not permitted（本机实测） | 要新做 root helper + PF |
| ad-hoc 签名下 `SMAppService`/`SMJobBless` 注册不了 | 走 **pkg postinstall 装 root LaunchDaemon**（不需要签名凭据，和现有分发形态兼容） |

> Windows / Linux 的同类结论（那边特权已就绪，Windows 甚至已有 NETWORK 层的 WinDivert）
> 记在 `GATEWAY.md` 里，**这一轮不做**。

| 阶段 | 内容 | 判定完成的标准 |
|---|---|---|
| **0** | **可行性实测**（要 sudo）：PF 的 `rdr` 重定向 + `DIOCNATLOOK` 读回原目的地址。脚本：`MacOS/ProxiRoute/tools/gateway-spike.sh` | 脚本打印 `PASS` |
| 1 | **规则引擎的无程序分支**（跳过点名程序的规则、补协议维度、chain 行为定死、域名匹配的来源） | 一条「只给域名」的规则能让网关的流量按它走 |
| 2 | **root helper**（helper + pkg postinstall + LaunchDaemon + PF anchor + 转发开关） | app 点一下能装上并启停，卸载清理干净 |
| 3 | **透明代理的数据面**（接住重定向 → 取原目的 → 按规则选上游 → 另开连接 → 中继） | 另一台机器把网关指过来，TCP 流量按规则走了代理 |
| 4 | **UDP/QUIC 与 DNS**（封 UDP 443 逼回落 + DNS 劫持） | 客户端 QUIC 被挡、回落 TCP 后仍按规则走代理 |
| 5 | **UI 收口**（第三种来源、终止权限、设置页那句橙字改成真话） | 不再写「转发还没有实现」 |

> **阶段 0 在最前面**：macOS 没有 tproxy，原目的地址只能靠 `DIOCNATLOOK` 反查，
> 而这个 ioctl 的结构体在 macOS 上**没有公开**（SDK 里没有 `<net/pfvar.h>`）。
> 万一这条路整个不通，后面三个阶段的写法全要改 —— 所以先花一次 sudo 验掉。

> **规则引擎有一条硬约束**：别的终端的流量**没有进程身份**，
> 点名程序的规则对网关客户端一律跳过，不能把 MAC / 主机名伪装成程序名。

---

## Proxifier 配置导入（.ppx）

Proxifier 把配置存成一个 XML 文件 `.ppx`。从 Proxifier 换过来的人手里就是这个文件，
手抄一遍规则不现实，所以直接读。**完整映射规格见 [docs/PPX-IMPORT.md](PPX-IMPORT.md)**。

### 本阶段实际交付

1. **两端都有读取器，共用一张映射表**
   - macOS：`MacOS/ProxyBridge/ProxyBridge/PPXImporter.swift`（用系统 `XMLParser`）
   - Windows：`Windows/gui/profile/ppx.c`（自写最小 XML 解析器）
   - 规格写在一份文档里，两端各有一份**内容完全相同的 fixture 与用例**
     （`ppx_tests.swift` ↔ `test_ppx.c`），用例逐条对应，防止说法漂移。
2. **导入落在新配置里**：macOS 新建 profile 并切过去，Windows 写一个新的 `.pbprofile`
   并切过去；**已有的配置一个都不动**。
3. **映射要点**
   - 代理类型：`SOCKS5`→socks5、`SOCKS4`→socks4（不带域名）、`SOCKS4A`→socks4（带域名）、
     `HTTPS`→HTTP 代理（Proxifier 的 "HTTPS" 是「会开 CONNECT 隧道的 HTTP 代理」）、
     `HTTP`→HTTP 代理 **+ 警告**（Proxifier 的纯 HTTP 没有 CONNECT 隧道）。
   - 链：只走 `enabled="true"` 的跳；**所有跳都关的链被丢弃**，指向它的规则**改直连**。
   - 规则：保留文件顺序（Proxifier 取第一条命中的规则）；协议固定 `TCP`
     （**Proxifier 只代理 TCP**）；应用名去掉引号、`.app` 后缀并去重。
   - 名字解析：`ViaProxy=true` → `remote` + 防泄漏；`false` → `local`；
     `AutoModeDetection` → `system` + 警告；排除名单里的 `%ComputerName%` 展开成本机主机名。
4. **不静默丢弃**：Proxifier 有而 ProxyBridge 没有的东西（流量加密、QUIC 阻断、
   连接环检测、逐代理 `<Options>` 位掩码……）要么给用户一条警告，要么在规格文档里写明。
   逐代理的位掩码**不猜**——公开资料查不到位定义，实测值只有 0/4，宁可原样忽略。
5. **CLI 同样能用**：macOS 的 `--profile x.ppx` 与标准输入都能读；
   Windows GUI 菜单「Profile → Import Proxifier Profile (.ppx)...」。
6. **导入结果的呈现**：macOS 导入后弹一个对话框，说明导入了多少代理 / 规则 / 链，
   映射不上的部分列在**可滚动的框里**（`NSAlert` 的 informativeText 会把长文本塞进
   一个看着像禁用状态的灰框，而且放不下）。Windows 侧走消息框 + 文本。

---

## 安装与授权（macOS 打包）

「装了能用」是路线图之外的一道关：macOS 的系统扩展装不上，app 界面照常打开，
但**什么都不会被代理**，用户看不出发生了什么。

| 环节 | 本 fork 的做法 |
|---|---|
| 产物签名 | 没有 Developer ID 证书就 **ad-hoc 签名**（`codesign --sign -`）并带上 entitlement；已经是 Developer ID 签名的构建不动 |
| entitlement | app 带 `com.apple.developer.system-extension.install`，扩展带 `com.apple.developer.networking.networkextension` |
| 脚本 | `MacOS/ProxyBridge/scripts/adhoc-sign.sh`，`build.sh` 与 macOS CI 打包前都调它 |
| 用户授权 | macOS 规定所有网络扩展都要用户手动开一次：**系统设置 → 通用 → 登录项与扩展 → 网络扩展**。app 会提示位置，并能一键打开该面板 |

> 细节与踩过的坑见 `FORK-NOTES.md` 的「macOS 系统扩展」一节。

---

## Android 并入主线

Android **不独立立项**，作为主线的一个端并行推进，共享：

- 同一套规则模型（进程 / 主机 / 端口 / 域名 / 协议 / 动作 / 本地直连标志）
- 同一套「通道可中断」语义（`killFlow` 终结一个流，而不是杀进程）
- 同一套 DNS 策略层（阶段 3）
- 同一套 UI 心智模型（活动连接表 + 右键终止）

实现顺序建议：阶段 1 的 Windows 语义定稿 → Android 复用同一套 flow id 编码 → 阶段 3 的 DNS 策略
在 Android 上先落地（Android 的 DNS 泄漏问题最突出）。

---

## Proxifier 对标清单（要点）

完整清单见 `ProxyBridge-对标Proxifier-可行性分析.html`。

- Proxifier 官方版本：Windows v4.14 / macOS v3.15 / Android v1.18，**没有 Linux 版**
- Proxifier 无 Personal / Professional 分级（只有 Standard / Portable / Mac，全 $39.95）
- Proxifier 官网**没有 API / SDK / 插件机制**——所以「超集」只能靠 UI + 行为对齐，不能靠插件
- Proxifier 的**假 IP 陷阱**：经代理解析时，基于 IP 的规则会静默失效。
  ProxyBridge 做超集时必须**保留真实 IP 路径**，不能照搬这个行为

---

## 参考

- 上游仓库：<https://github.com/InterceptSuite/ProxyBridge>
- fork：<https://github.com/sdpong/ProxyBridge>
- Proxifier：<https://www.proxifier.com/>
