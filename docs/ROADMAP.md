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
| macOS | `[ ]` | libproc 枚举进程（含系统守护进程），按可执行名 / bundle id 匹配 |
| Android | `[ ]` | `ConnectivityManager.getConnectionOwnerUid()`（API 29+）/ `NetworkCapabilities.getOwnerUid()`（API 30+，VPN 场景会填充）反查 UID |

> **Android 10+ 已封锁 `/proc/net`**，不能沿用 Linux 的老路子；必须走 `ConnectivityManager` 官方 API。

macOS 侧已确认 `proc_pidpath` 在扩展里可直接使用（`AppProxyProvider.swift:447`），
**不需要额外 entitlement**。规则匹配同时接受 bundle id 和可执行名（`matchesProcess(bundleId:processName:)`）。

---

## 阶段 3 · DNS 策略层

三选一策略（本地 / 远端 / 系统）、排除名单、自动检测、上游解析器可指定、防泄漏开关。

macOS 的 `NEDNSProxyProvider` 拦截层**已经存在**，缺的是策略层而不是拦截层。
Windows / Android 走各自的平台机制，但语义要对齐。

| 端 | 状态 | 内容 |
|---|---|---|
| macOS | `[x]` | 策略层已落地（见上方「macOS DNS 策略层」）：三选一策略、排除名单、上游解析器、自动检测、防泄漏开关 |
| Windows | `[ ]` | 引擎已有 DNS snoop 缓存（`pb_dns.c`），缺策略层：把「本地 / 远端 / 系统」与排除名单接到 GUI 与引擎 |
| Android | `[ ]` | 同上；Android 的 DNS 泄漏问题最突出，应优先落地 |

---

## 阶段 4 · 高级能力

| 能力 | 状态 | 说明 |
|---|---|---|
| 代理链（冗余 / 负载均衡） | `[ ]` | 多上游串联 |
| 流量统计面板 | `[ ]` | |
| 托盘流量图 | `[ ]` | |
| Proxy Checker 延迟测量 | `[ ]` | Proxifier 有，ProxyBridge 目前只有可达性测试 |
| Traffic dump | `[ ]` | |
| 手动代理化 | `[ ]` | |
| 规则绑定网卡 | `[ ]` | |

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
