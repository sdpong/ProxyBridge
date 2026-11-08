# 网关模式：让网络里其他终端的流量从这台机器过

> 这份是**下一轮的实现方案**。结论都有出处（文件:行号 / 官方文档 / 本机实测），
> 没把握的地方单独列在最后的「待实测」里，不混在结论里。

## 目标

网络里的其他终端**不改代理配置**（只把网关 / DNS 指向这台机器），
它们的流量按 ProxiRoute 的规则走代理，并且在本机的**统计**和**活动连接**里
按来源分开显示 —— 和现在「本机 + 代理服务器模式的客户端」那种分开是同一套语义。

用户已定的三条：

| 决定 | 内容 |
|---|---|
| 转发后走不走代理 | **走**：透明代理，按规则选上游（不是只做 NAT 直出） |
| 特权 | **接受**：安装时装一个 root 特权 helper，启用网关时授权一次 |
| 范围 | **三端一起**：macOS + Windows + Linux |

## 一、三条硬事实（决定了整个形状）

### 1. macOS 没有第三方「软件网关」的官方 API

NetworkExtension 的四个 provider **都只管本机**（官方文档原文）：

| Provider | 官方文档关键句 | 能看到别的机器的包吗 |
|---|---|---|
| `NEPacketTunnelProvider` | *"IP packets with matching destination addresses will then be diverted to Packet Tunnel Provider"* | 否（是**本机**发往那些目的地的包） |
| `NEAppProxyProvider` | *"Each `NEAppProxyFlow` object corresponds to a socket opened by an app that matches the app rules"* | 否（本机进程的 socket） |
| `NETransparentProxyProvider` | 继承 `NEAppProxyProvider`，差别只是 `handleNewFlow` 返回 `NO` 时直连 | 否 |
| `NEFilterDataProvider` | *"Each `NEFilterFlow` object corresponds to a network connection opened by an application running on the device"* | 否 |

出处：<https://developer.apple.com/documentation/networkextension/nepackettunnelprovider> 等四页。

**本 fork 的扩展基类是 `NETransparentProxyProvider`**（`MacOS/ProxiRoute/extension/AppProxyProvider.swift:392`）——
它接的是**本机进程开的 socket**，别的机器的包不会产生 flow。
所以网关模式**不是「加个转发开关」，而是另一条数据面**。

Apple 唯一的官方网关功能是「系统设置 → 通用 → 共享 → 互联网共享」，
它用系统自带的 `bootpd` + PF，**不向第三方 App 暴露数据包**。

### 2. macOS 上转发必须 root（本机实测）

```
$ pfctl -ss            → pfctl: /dev/pf: Permission denied
$ ls -l /dev/pf        → crw------- 1 root wheel
$ sysctl -w net.inet.ip.forwarding=1 → Operation not permitted
$ sysctl net.inet.ip.forwarding      → 0
```

- `pfctl(8)` man 原文：*"The packet filter does not itself forward packets between interfaces.
  Forwarding can be enabled by setting the sysctl(8) variables `net.inet.ip.forwarding` … to 1."*
  —— **PF 和转发是两件事**，规则本身不会让 Mac 变成路由器。
- 非特权进程读不到任何 PF 状态（状态表、每规则计数器都走 `/dev/pf` 的 ioctl）。
- macOS **没有** `/dev/tun`（本机实测不存在）；`utun` 是内核设备，
  非特权进程建不出可用的 utun（社区做法一致：root 守护进程持有 utun）。
- **SIP 不构成障碍**：SIP 保护 `/System`、kext、关键二进制，
  不挡改 sysctl、用 pfctl、装 LaunchDaemon。
- **App Sandbox 是障碍**：沙盒进程不能开 `/dev/pf`、不能改 sysctl。
  本 fork 的 app 本来就**不带沙盒**（`adhoc-sign.sh` 的注释：沙盒留给扩展），所以兼容。

### 3. ad-hoc 签名下 `SMAppService` / `SMJobBless` 注册不了 → 走 pkg postinstall

- `SMJobBless` 文档要求 *"Xcode must sign both the calling app and target executable tool"*；
  `SMJobBless` 已 deprecated，官方建议 `SMAppService`。
- 社区与工程实践一致结论：**`SMAppService.register()` 在 ad-hoc 签名下失败**，
  只有 Developer ID 签名才成功（微软 ProcExp for Mac 的发布文档明确写了这一点）。
  本 fork **没有** Developer ID 凭据（macOS 产物是 ad-hoc 签名 + 未公证）。
- Apple DTS（Quinn）的原话：*"If you already have a way to install your daemon — your installer package —
  there's really no point in involving SMJobBless."*
- **所以唯一可行路径**：pkg 的 postinstall 阶段本来就是 root 上下文
  （`MacOS/ProxiRoute/scripts/postinstall` 现在就以 root 跑），
  在那里装 root helper 到 `/Library/PrivilegedHelperTools/`、
  装 LaunchDaemon plist 到 `/Library/LaunchDaemons/`、`launchctl bootstrap system`。
  **这条路不需要任何签名凭据**，和本 fork 现在的分发形态（pkg + ad-hoc）兼容。

## 二、三端现状对比

| | 能不能看到**别的机器**的包 | 保留原目的地址 | UDP / QUIC | 特权怎么来 | 现有基础 |
|---|---|---|---|---|---|
| **Windows** | ✅ WinDivert **NETWORK 层**（`Windows/src/ProxyBridge.c:1348`）抓的是网卡上的包，含转发的包 | ✅ WinDivert helper 可取原目的 | ⚠️ 可做，但建议仍封 UDP 逼回落 | **已经有了**：服务跑在 LocalSystem（`Windows/src/service/pb_service.c:3,49`） | **已具备大半** |
| **Linux** | ❌ 现有 eBPF 全是 cgroup socket 钩子（`Linux/src/bpf/proxybridge.bpf.c:249+`）；要加 `tc` egress / XDP | ✅ `nftables` tproxy / `SO_ORIGINAL_DST` | ✅ 支持 | **已经有了**：`Linux/src/pb_bpf.c:168` 要求 root，unit 里已有 `CAP_NET_ADMIN CAP_BPF`（`Linux/src/pb_unit.c:75`） | 特权就绪，钩子要补 |
| **macOS** | ❌ NE 全都不行；必须 PF / utun | ⚠️ 只能 `rdr` + `DIOCNATLOOK` 反查，**IPv4 TCP only** | ❌ 透明代理做不了 UDP，只能**封 UDP 443 逼回落 TCP** | ❌ 要新做 root helper + PF anchor | 扩展只覆盖本机，数据面要重做 |

**结论：三端的难度差得很远。**
Windows 最短（特权和数据面都现成），Linux 次之（特权现成，钩子和 tproxy 要写），
macOS 最难（helper + PF + 数据面重做 + 没有 tproxy）。

## 三、规则引擎：网关这一侧没有「程序」维度

ProxiRoute 的规则主体是**按程序**的（`ProxyRule.processNames`、`ProxyAppIdentity.swift`）。
别的终端的包**没有进程身份** —— 不能把客户端的 MAC / 主机名伪装成「程序名」。

所以规则引擎要加一条**「无程序维度」的分支**，三端语义必须一致：

1. **点名程序的规则对网关客户端一律跳过**。
   现有 macOS 侧已经是这个语义（`MacOS/ProxiRoute/ProxiRoute/LocalProxyUpstream.swift:265` 的
   `if rule.hasProgram { continue }`），Windows/Linux 要对齐。
2. **协议维度现在在 App 侧是死字段**：`LocalProxyRule.protocolMode`（`LocalProxyUpstream.swift:76`）
   全文件没人读。网关要区分 TCP/UDP（对应扩展侧 `RuleProtocol`），
   `LocalProxyRule.matches`（`:80-89`）和 `LocalProxyRules.upstream`（`:262`）都要加协议参数。
3. **chain 在 App 侧解析不了**：`action == "chain:<id>"` 在 `LocalProxyUpstream.swift:272-276`
   落到 `default` 分支 → 找不到对应代理 → 返回 `.direct`（静默直连，不是报错）。
   网关要么实现多跳，要么明说「网关不支持 chain」。
4. **域名能不能匹配，取决于数据面**：扩展侧能靠 `DNSMapStore` 反查域名（`AppProxyProvider.swift:1743`），
   App 侧 `LocalProxyRule.host` 只能匹配字面 host / 通配符片段（`LocalProxyUpstream.swift:92-112`）。
   转发路径若能拿到原目的（域名），就能按域名分流；只拿到 IP 就只能按 IP。
   → **这是三端数据面设计的硬约束，不是 UI 能补的**。

## 四、数据面（每端各写各的）

### Windows（第一刀：最短路径）

1. 服务已是 SYSTEM → 直接开 IP 转发（注册表 `HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\IpEnableRouter=1`）。
2. WinDivert 已有 **NETWORK 层**句柄（`ProxyBridge.c:1348`）→ 在这一层加一条过滤器抓**转发包**。
3. 用 `WinDivertHelperFormatPacket` 取原始目的地址 → 交给「按规则选上游 → 连代理 → 中继」。
4. 上游握手与中继：Windows 端已有 SOCKS4/5、HTTP CONNECT 的引擎握手，
   规则引擎加「无程序维度」分支即可复用。

### Linux

1. 已有 root + `CAP_NET_ADMIN` → 开 `net.ipv4.ip_forward=1`。
2. 新增 `tc` egress（clsact）或 XDP 钩子，把转发包送进用户态。
3. 用 `nftables` tproxy 或 `SO_ORIGINAL_DST` **保留原目的地址**交给本地 socket。
4. UDP 可以真透明代理（Linux 才有这个能力）。

### macOS

1. **root helper**（新）：只做四件事 —— `sysctl` 转发开关、PF anchor 的规则装载/卸载、
   状态回读、helper 的启停。**规则匹配和代理连接留在非特权的 app 侧**，不把整个 app 提权。
2. **PF 规则**：入向 `rdr` 到本地端口 → app 侧透明代理入口；
   `route-to lo0` 让出向包回到 lo0 才看得见；`no rdr` 排除临时端口避免回环；
   UID 级别的回环规避（`pass out quick on lo0 … user <uid>`）。
3. **原目的地址**：`DIOCNATLOOK` 反查 —— **只支持 IPv4 TCP**。
4. **UDP/QUIC**：macOS 上做不了透明 UDP → 只能**封 UDP 443 逼客户端回落 TCP**
   （ProxiRoute 已有这个语义的雏形：`RouteSettings.proxyUDP`、`MacOS/ProxiRoute/ProxiRoute/RouteSettings.swift:25`）。
5. **DNS**：别的终端的 DNS 查询不会到 `NEDNSProxyProvider`（那只管本机）。
   网关要按域名分流，就得自带 DNS 劫持（PF `rdr` 53 → 本地 DNS）或要求终端手动设 DNS。

## 五、特权组件与打包

| 环节 | 做法 |
|---|---|
| helper 二进制 | 新 target；不放进带沙盒的 extension；独立 Mach-O，签名脚本要加一段（`scripts/adhoc-sign.sh` 现在只签扩展与 app） |
| 安装 | `pkgbuild --root build/component` 可以直接放 `/Library/LaunchDaemons`（`MacOS/ProxiRoute/build.sh:82-89` 现在就是这么放 app 的） |
| postinstall | `MacOS/ProxiRoute/scripts/postinstall` 已是 root 上下文 → 加「装 helper + bootstrap LaunchDaemon」 |
| 启停 | app 通过 unix socket / Mach service 连 helper；**helper 要校验调用方** |
| 安全取舍 | ad-hoc 签名的 cdhash 每次构建都变 → 无法做强身份校验，只能做「同一 bundle id + root 拥有 + 文件权限」这类弱校验。**这是一个必须显式记录在案的取舍** |
| CI | macOS workflow（`.github/workflows/build-mac.yml`）的 pkg 步骤要跟着改；helper 若独立于 app bundle，要单独 notarize + staple |

## 六、统计与 UI：第三种来源

现在的来源模型是两种（本轮刚做的）：

- `TrafficMerge.Source`（`MacOS/ProxiRoute/ProxiRoute/TrafficMerge.swift:16-54`）：`.machine` / `.client(address)`
- `LiveFlow.Origin`（`ProxiRouteViewModel.swift:209-214`）：`.machine` / `.client`
- id 空间：`LiveFlow.clientTableId`（`:237-239`）把客户端的流放在 UInt64 的高半区

加第三种来源「**网关转发的终端**」要动：

1. `TrafficMerge.Source` 加 case → 连带 `key`（`:37`）、`ordered`（`:44-53`）、`isMachine`（`:27`）、`clientAddress`（`:30`）
2. `TrafficMerge.rows(machine:clients:)`（`:85`）的签名现在硬编码两个数组
3. `LiveFlow.Origin` 加 case，**id 空间要再切一段**（高半区已经被 client 占了）
4. `publishTraffic`（`:1817`）/ `mergedTrafficRows`（`:1918`）/ `publishLiveFlows`（`:1983`）都要加分支；
   现在它们用 `runtimeMode == .server` 作为「拼接」的开关，网关模式是第三种
5. `killFlow`（`:2110`）的 `guard flow.origin == .machine else { return }` 要重新想：
   转发连接在 helper 进程里，**能不能终止取决于 helper 有没有提供这个能力**
6. UI：`ProxyTrafficView.tableWithSource`（`ContentView.swift:412`）的 `sourceName`（`:367`）
   要新的显示名（终端地址？还是终端名？）；`showsSource` 的条件（`:174`）现在是 `!= .local`，
   网关模式**要显示**来源列

## 七、阶段划分

| 阶段 | 内容 | 判定完成的标准 |
|---|---|---|
| **A · Windows 打通全链路** | SYSTEM 服务开转发 + WinDivert NETWORK 层抓转发包 + 取原目的 + 按规则选上游 + 中继 + 统计里出现「转发」来源 | Windows 上另一台机器把网关指向这台机器，流量按 host 规则走了代理，统计里能看到 |
| **B · 规则引擎的无程序分支** | 三端规则引擎统一：跳过点名程序的规则、补协议维度、chain 的行为定死（支持还是明确不支持）、域名能不能匹配 | 三端同一套规则写法，三端行为一致 |
| **C · Linux** | `tc`/XDP 钩子 + nftables tproxy + 保留原目的 + UDP 真透明 | 同 A 的判定标准 |
| **D · macOS 的 root helper** | helper 二进制 + pkg postinstall + LaunchDaemon + PF anchor（转发 + NAT + rdr） + app 侧透明代理入口 | 另一台机器把网关指过来，TCP 流量按规则走了代理 |
| **E · macOS 的 UDP/QUIC 策略** | 封 UDP 443 逼回落 + DNS 劫持（若要按域名分流） | 客户端的 QUIC 被挡、回落 TCP 后仍按规则走代理 |
| **F · UI 收口** | 第三种来源在统计/活动连接里的显示、终止权限、网关状态卡片的橙字改成真话 | 设置页不再写「转发还没有实现」 |

**阶段 A 之前不需要碰 macOS 的特权问题**，所以可以先把最容易出成果的那端做出来，
同时用阶段 B 把三端的规则语义钉死。

## 八、待实测（结论没把握、必须先验的）

| # | 待验 | 为什么重要 | 怎么验 |
|---|---|---|---|
| 1 | WinDivert NETWORK 层能否看到**转发**包、能取到原目的地址 | 决定阶段 A 成不成立 | Windows 上开 ICS，WinDivert NETWORK 层抓包看有没有别的机器的 IP |
| 2 | `tc` egress / XDP 上转发包的可见性与原目的地址 | 决定阶段 C 的具体钩子 | Linux 上开转发 + 抓包 |
| 3 | macOS 上 `rdr` + `DIOCNATLOOK` 能否在**转发**流量上恢复原目的 | 决定阶段 D 的透明代理成立与否 | 网关配好后 `pfctl -ss` 看 state |
| 4 | macOS 上 `route-to lo0` 在 macOS 26/27 的实际行为 | 社区文档提过 macOS 26 VM 验证，但无 Apple 文档 | 按社区配方在目标 OS 上复现 |
| 5 | 系统 Internet Sharing 的 NAT 规则与自定义 anchor 会不会打架 | 两条 NAT 路径可能互相覆盖 | 同时开 ICS 与自定义 anchor 观察 |
| 6 | `NETransparentProxyProvider` 会不会意外看到转发流 | 若会，macOS 的数据面能省一大截 | 转发流量时看扩展日志里有没有 flow |
| 7 | ad-hoc 签名下 `SMAppService.register()` 的确切错误码 | 确认「只能走 pkg postinstall」 | 本机跑一次 register 看 `SMAppService.status` |
| 8 | 网关客户端的**进程名**怎么表达 | ProxiRoute 的 UI 一贯是程序名维度 | 产品决定（见下面的待定项） |

## 九、还没定的事

- **网关客户端在 UI 上叫什么**：地址（`192.168.254.140`）？主机名（要解析）？还是像 Proxifier 那样按客户端分组？
  现在「代理服务器模式」的客户端已经是用地址表示的（`Source.client(address)`），
  网关这一侧沿用地址是最省事的。
- **网关模式和代理服务器模式的关系**：两者都是「别的终端的流量从这台机器过」，
  区别是终端**要不要配代理**。UI 上是两个模式并存，还是合并成一个（终端可配可不配）？
- **UDP/QUIC 在 macOS 上只能封**：这会让网关客户端的 QUIC 流量被挡，
  体验上要写清楚。

---

## 参考

- `docs/FORK-NOTES.md` —— 本 fork 的坑与实测记录
- `docs/PPX-IMPORT.md` —— `.ppx` 导入的映射规格
- Apple 文档：<https://developer.apple.com/documentation/networkextension/netransparentproxyprovider>、
  <https://developer.apple.com/documentation/servicemanagement/smjobbless(_:_:_:_:)>
- 本机 man：`/usr/share/man/man8/pfctl.8`、`/usr/share/man/man8/sysctl.8`
