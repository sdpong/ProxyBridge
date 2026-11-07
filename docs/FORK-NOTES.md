# Fork 工作说明（sdpong/ProxyBridge）

> 本文件只存在于 fork（`sdpong/ProxyBridge`），上游 `InterceptSuite/ProxyBridge` 不包含它。

## 这个 fork 和上游的关系

```bash
git remote -v
# origin    https://github.com/sdpong/ProxyBridge.git   (fetch + push)
# upstream  https://github.com/InterceptSuite/ProxyBridge.git  (fetch only)
```

`upstream` 的 **push URL 被设成 `DISABLED://read-only-upstream`**，从物理上杜绝误推上游。

### 不 merge / 不 rebase 上游

上游更新**不 sync fork**——不做 `git merge upstream/master`，也不做 `git rebase upstream/master`。
原因：

1. 本 fork 的目标是把 ProxyBridge 改成 Proxifier 超集，改动方向和上游的重构方向经常冲突，
   自动合并会产生大量无意义的冲突解决；
2. 保持 `git diff upstream/master` 语义清晰——它就是「我们相对上游多做了什么」，可以直接拿去提 PR。

### 上游有更新时的做法

```bash
git fetch upstream master
git log --oneline HEAD..upstream/master        # 上游多了什么
git diff HEAD upstream/master -- <路径>        # 只读那个文件的差异
```

然后**读代码**，把需要的改动**逐项手工移植**进本 fork，移植完单独提交，提交信息里写明
「ported from upstream <sha>」。不要用 `git cherry-pick` 整块搬——上游的提交通常夹带重构。

## 分支与提交

- 开发分支命名：`feature/<主题>`，例如 `feature/kill-connection-stage1`
- 合并到 `master` 用 `--ff-only`，保持线性历史
- 一个提交只做一件事；提交信息用英文，与上游风格一致（`feat:` / `fix:` / `docs:`）
- 不要在同一个提交里夹带格式化无关行

## 构建与测试

### Windows（需要 Windows + Visual Studio Build Tools）

```powershell
cd Windows
.\compile.ps1              # 构建 core DLL / GUI / service / CLI
.\tests\run_tests.ps1      # 全部测试 + static_checks
```

`run_tests.ps1` 里的 `static_checks` 段会做纯文本一致性检查（版本号、loc.h 枚举与翻译表同序、
每个 `test_*.c` 都注册在册等），这些不需要编译就能跑。

### macOS（需要 Xcode）

```bash
cd MacOS/ProxyBridge
xcodebuild -project ProxyBridge.xcodeproj -scheme ProxyBridge -configuration Release build
```

`build.sh` 是**打包**脚本（生成 pkg），前提是 Xcode 已经导出 `output/ProxyBridge.app`。

## CI 与发布

fork 的 GitHub Actions（`master` 每次 push 都会跑）：

| 工作流 | 状态 | 说明 |
|---|---|---|
| Build Windows | ✅ 绿 | 跑全部测试（含 GUI 测试）、编译并用 NSIS 生成安装包，产物是 workflow artifact |
| Build macOS | ✅ 绿 | 本 fork 没有签名证书时构建通用二进制 App 与 pkg，产物是 workflow artifact |
| Build Linux | ❌ 红 | runner 镜像缺 `bpftool`（eBPF 工具链），与本 fork 的改动无关 |
| SonarQube / CodeQL | ❌ 红 | 需要上游的 Sonar 服务端令牌 / 授权，fork 里没有 |

**注意：secret 不能出现在 step 级的 `if:` 里**（GitHub 会判定工作流非法）。需要按 secret 取分支时，
先在 job 级 `env:` 里把它变成布尔字符串，再在 step 的 `if:` 里读这个变量：

```yaml
    env:
      HAS_SIGNING_CERT: ${{ secrets.MACOS_CERTIFICATE != '' }}
    steps:
      - if: env.HAS_SIGNING_CERT == 'true'
```

**注意：未签名构建不能留下 `DEVELOPMENT_TEAM` 和 `PROVISIONING_PROFILE_SPECIFIER`**，
否则 xcode 会去找那个描述文件并直接失败，即使签名已经关掉。

**注意：没有证书也要 ad-hoc 签一次**。macOS 不许从没有 entitlement 的 app 里装系统扩展，
所以 CI 在打包前跑 `scripts/adhoc-sign.sh`（详见「macOS 系统扩展」一节）。
装了之后仍然需要用户在系统设置里开一次开关，这是 macOS 的规矩，构建替不了。

### 发一个 release

1. Windows 安装包来自 CI 的 `ProxyBridge-Build-<sha>` artifact（`Windows/output/` 里的
   `ProxyBridge-Setup-<版本>.exe`）；macOS 的 pkg 来自 `ProxyBridge-macOS-Installer` artifact。
2. `gh release create <tag> <文件...> --notes-file <说明>` 把两个产物挂上去。
3. 上游的 `release-*.yml` 在本 fork 里**用不了**：它们要求 `github.actor == 'Anof-cyber'`，
   Windows 那个还要上游的 self-hosted runner 和它上面装好的 WinDivert。

## 协议版本纪律

`Windows/src/service/pb_proto.h` 里的 `PB_PROTO_VERSION` 是 GUI 与服务之间的握手版本。
**任何新增/修改管道指令都必须递增它**——GUI 与服务握手时比对版本，不匹配直接拒绝连接。
不递增的后果是旧 GUI 误发新指令，行为未定义。

新增指令时：

1. 在 `pb_proto.h` 的枚举**末尾**追加（不要插在中间，那会重排已有的值）
2. 服务端在 `pb_service.c` 的 `Dispatch()` 里加 `case`
3. GUI 端在 `gui/api/pb_ipc.h` 里加对应的 `Ipc*` 函数并填进 `PB_LoadService()` 的表
4. 在 `Windows/tests/test_service.c` 里加一条编解码用例（**缺参数必须失败**）

`gui/api/pb_api.h` 里的 `PBApi` 表是 GUI ↔ 引擎 DLL 的直接调用表。新增引擎能力时：

- **必需**能力用 `PB_BIND` 宏（`GetProcAddress` 失败 → 加载失败）
- **可选**能力（老版本 DLL 没有也不影响使用）单独 `GetProcAddress`，允许为 NULL，GUI 侧据此禁用入口

## 代码风格

- 注释用英文，和上游一致；写**为什么**，不写**做了什么**
- 每个函数顶部一句话说明它的存在理由（上游的风格）
- 缩进 4 空格，`{` 同行
- Windows 侧偏好 `BOOL` / `UINT32` / `UINT64` 等显式类型

## 平台限制（本 fork 踩过的坑，改动前先看）

这些是**实测**出来的，不是猜的。改到相关代码前先读一遍，免得再踩一次。

### macOS App 沙盒

- **不能枚举进程**：`proc_listpids()` 被封锁（返回 0），`posix_spawn("/bin/ps")` 被封锁（EPERM）。
  读内核进程表要用 `sysctl(KERN_PROC_ALL)`，这个**可以**用；
  读单个进程的完整路径 `proc_pidpath` 也可以用。
- **能读别的进程的属主**：`proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, ...)` 可以，
  但它填的是 **`proc_bsdshortinfo`**，不是 `proc_bsdinfo`。用错结构体，uid 会读到错误偏移。
- **能读别的 App 的 bundle id**：`Bundle(path:).bundleIdentifier` 可以。
- 沙盒 App 与系统扩展共用 App Group `group.com.interceptsuite.ProxyBridge`，
  可以用共享容器当跨进程的传递通道。

### macOS 系统扩展

- **DNS provider 收不到 App 消息**：`sendProviderMessage` 只存在于
  `NETunnelProviderSession`。`NEDNSProxyManager` 的 connection 没有这个方法，
  `NEDNSProxyProvider` 也没有 `handleAppMessage` 可覆盖。
  要给 DNS provider 送东西，只能走 **App Group 共享容器**（本 fork 用 `dns_policy.json`）。
- **透明代理与 DNS provider 可能是两个进程**：不要假设同进程内的单例会共享，
  共享容器才可靠。
- **没签名的 app 装不上系统扩展**：macOS 要求 app 带着
  `com.apple.developer.system-extension.install` entitlement 才肯装它的系统扩展，
  没带就直接报 `Missing entitlement com.apple.developer.system-extension.install`，
  app 能打开、能显示界面，但**什么都不会被代理**。
  - 本 fork 的 CI 把 `CODE_SIGNING_ALLOWED = NO` 写进了 xcconfig，
    所以**产物从来没有 entitlement**——这就是本机装完「没起作用」的原因。
  - **ad-hoc 签名能让它装上，但不能让它跑起来**（这是两件事，别混）：
    - `codesign --force --sign - --entitlements <file> --options runtime`
      会把 entitlement 真正嵌进二进制，`systemextensionsctl list` 里能看到
      `activated waiting for user`——**注册成功**。
    - 但 **AMFI 会拒绝这个 app**：
      ```
      Restricted entitlements not validated, bailing out. Code=-427 "Unable to retrieve certificate chain"
      Adhoc signed app with restricted entitlements detected
      ... not valid: Code=-424 "The file is adhoc signed but contains restricted entitlements"
      ```
      受限 entitlement（`system-extension.install` 与
      `networking.networkextension`）必须由**描述文件**放行，ad-hoc 签名没有描述文件，
      所以这些能力**不生效**——扩展注册了、进程却起不来，还是不代理任何流量。
  - **结论：macOS 上能用的构建必须有 Developer ID + 描述文件**。
    Apple DTS（Quinn）原话：Network Extension provider 与 Mac 上的 system extension
    所需 entitlement「must be whitelisted by a provisioning profile, which means that
    you will need a **paid developer membership**」；
    **免费的 Personal Team 不支持 Network Extensions 与 System Extension 这两个能力**。
    自签证书、自己编的 team id、`CODE_SIGN_IDENTITY="-"` 都等价于 ad-hoc，没有用。
  - **本 fork 的 CI 已经预留好了这条路**：workflow 里 `HAS_SIGNING_CERT` 为真时，
    会导入 `MACOS_CERTIFICATE`、安装 `MACOS_APP_PROVISION_PROFILE` /
    `MACOS_EXT_PROVISION_PROFILE`、用 `MACOS_APP_XCCONFIG` / `MACOS_EXT_XCCONFIG`，
    并走 `productsign` + `notarytool`。把凭据配成仓库 secret，产物就是正式签名并公证的。
  - **顺序：先签扩展，再签 app**。签 app 不会重签 bundle 里的代码，
    两部分各要各的 entitlement。
  - **entitlement 文件只有 Release 版本有**：`ProxyBridgeRelease.entitlements` 与
    `extensionRelease.entitlements` 是 Release 配置指向的那两个；
    Debug 变体的 `ProxyBridge.entitlements` / `extension.entitlements` **不存在**。
  - **批准这一步谁来都替不了**：macOS 要求所有网络扩展都让用户在
    「系统设置 → 通用 → 登录项与扩展 → 网络扩展」里开一次开关。
    深链 `x-apple.systempreferences:com.apple.LoginItems-Settings.extension` 实测能打开该面板，
    app 里已经有这个按钮。
  - **同一 bundle id 的新旧扩展会同时留在系统里**：上游正式版是 Developer ID 签名，
    本 fork 是 ad-hoc 签名（`teamID: none`），macOS 按「版本 + 签名团队」把它们记成
    两条独立的扩展记录。系统可能把隧道绑到**旧的那条**上，而旧扩展的协议更老
    （只认 `addRule` / `getLogs` / `setTrafficLogging`），于是规则和代理配置发过去没人懂，
    窗口里一条连接也没有。app 现在会做**握手自检**（扩展回答 `getInfo`，
    报协议号与版本），发现对不上就在窗口里明说，并给出清理命令
    （`scripts/remove-old-extensions.sh`，需要 root）。
  - **「VPN 配置所使用的 VPN App 尚未安装」（NEVPNConnectionErrorDomain 14）**
    是另一回事，也是最难查的一个：系统按 **cdhash** 认扩展。
    每条网络配置里存着当时的扩展二进制的哈希
    （`/Library/Preferences/com.apple.networkextension.plist` 里的
    `DesignatedRequirement` = `cdhash H"…"`）。
    扩展二进制被换掉、或者那个 app 被删掉之后，哈希就对不上了，
    系统报「app 未安装」，**而且新建的配置会继续钉住同一个死哈希**——
    因为系统解析 provider bundle id 时挑中的还是那条孤儿记录。
    修法只有一个：**把那个孤儿扩展从系统里摘掉**
    （`sudo systemextensionsctl uninstall <团队ID> com.interceptsuite.ProxyBridge.extension`），
    之后新建的配置才会钉到当前这个扩展的哈希上，隧道才起得来。
  - **app 不能抢别人的网络配置**：macOS 把所有 app 的透明代理配置放在同一个列表里，
    而它们的 provider bundle id 可能一模一样（上游的 ProxyBridge 和本 fork 就是）。
    所以配置里要写自己的标记（`providerConfiguration`），
    启动 / 停止 / 重建时**只碰带自己标记的那条**，
    否则用户的别的代理开关会被 app 动。
    但**修复路径**例外：隧道已经起不来时，本 bundle id 的旧配置全删掉重建
    （那些配置钉的是早已不存在的哈希，留着只会一直失败）。

### 代理链

- **中间的跳只能是 SOCKS5 / SOCKS4**：HTTP CONNECT 的应答可能把隧道数据留在缓冲区里，
  下一跳的握手会把它当成自己的应答读走。App 与扩展各有一份校验，
  `MacOS/tests/logic/chain_tests.swift` 比对两边的判定，防止说法漂移。
- **链不能带 UDP**：SOCKS5 的 UDP ASSOCIATE 是独立会话，串不起来。
- **Windows 侧同样的规则**：`Windows/src/pb_chain.c` 的 `chain_problems()` 与 macOS 的
  `ChainPlan.problems()` 一一对应，`Windows/tests/test_chain.c` 跑同一批用例。
- **链的表示按平台各自的规则模型**：macOS 把链 id 写在 action 的 `chain:` 前缀里，
  Windows 把链 id 放在规则原有的代理字段里，链 id 走自己的号段（`PB_CHAIN_ID_BASE = 1000` 起）。
  两者达到同一个目的：链和代理永远不会互相认错，而且**规则模型、规则 API、规则 IPC、
  连接跟踪热路径都不用改**。
- **profile 的键名与形状两端一致**：`proxyChains`，里面是 `{id, name, proxies}`。
  macOS 的 proxy id 是 UUID 字符串，Windows 是数字——这是平台差异，不是语义差异。
- **Windows 的链表要按锁取**：链可以在连接走它的同时被改或被删，
  所以中继侧用 `chain_hops_of()` 在锁内把跳复制出来再用，不持指针出锁。

### 代理类型

- **名字与数字要一一对应**：profile 里存名字（`SOCKS5` / `SOCKS4` / `HTTP`），
  引擎里存数字。Windows 侧用 `pb_proxy_type_*` 一对函数收敛，
  macOS 侧用 `ProxyChain.problems` 与 `ChainPlan.problems` 各自校验（逻辑测试比对两边）。
- **UDP 只走 SOCKS5**：HTTP 没有 UDP，SOCKS4 也没有。规则指向这两种代理时 UDP 走直连，
  并且要**明说**，不能静默回落。

### DNS 策略层（两端唯一不能一致的地方）

- **macOS 能替应用回答 DNS，Windows 不能**：macOS 的 `NEDNSProxyProvider` 拦下应用的查询，
  自己回答，所以「上游解析器」决定的是**应用**拿到什么答案。
  Windows 上应用永远先问自己系统的解析器（WinDivert 只能旁观，没法替它回答），
  所以「上游解析器」决定的是**代理**被告知什么——本地模式下引擎自己去问那个解析器，
  把它的答案交给代理。
- **能对齐的部分全部对齐**：三选一策略（system / local / remote）的语义、
  排除名单的匹配规则（`example.com` 只匹配自己、`*.example.com` 匹配其下全部、`*` 匹配全部）、
  排除的名字不进名字缓存、防泄漏开关压过其他设置——
  这些两端一模一样，profile 的键名也用同一套
  （`dnsPolicy` / `mode` / `excludedDomains` / `upstreamResolvers` / `autoDetectUpstream` / `leakProtection`）。
- **防漂移靠测试**：macOS 的 `dnspolicy_tests.swift` 同时编译 App 侧与扩展侧两份模型，
  逐字段比对「App 写出去的」与「扩展读回来的」；
  Windows 的 `test_dnspolicy.c` 跑同一批用例。
- **Windows 的 `FIXED_INFO.DnsServerList` 只有一个解析器**，而且是 `IP_ADDRESS_STRING`，
  地址在 `.String` 里，不是数组。

### Proxifier 配置导入（.ppx）

- **两端共用一张映射表**：`docs/PPX-IMPORT.md` 是契约。
  两端各有一份**内容完全相同**的 fixture 与用例
  （`MacOS/tests/logic/ppx_tests.swift` ↔ `Windows/tests/test_ppx.c`），
  改了一边的映射就要改另一边，否则测试对不上。
- **macOS 用系统 `XMLParser`**（`shouldResolveExternalEntities = false`）；
  **Windows 自己写了一个最小 XML 解析器**（`Windows/gui/profile/ppx.c`）：
  只认元素 / 属性 / 文本、5 个内建实体与数字实体，DOCTYPE 整段跳过（不解析实体定义），
  深度 24、节点 20000、文件 8 MB 上限。
- **导入落在新配置里**，已有配置不动（macOS 新建 profile；Windows 写新 `.pbprofile`）。
- **链被丢弃时，指向它的规则必须改直连**——macOS 早期版本把链 id 先收进集合再判空，
  结果「所有跳都关」的链被丢掉了、规则却还指着它。Windows 侧按「已导入的链」查找，
  两端现在一致，各有一条用例守着。
- **逐代理 `<Options>` 位掩码不映射**：公开资料查不到位定义（实测 0 / 4，
  第三方生成的 .ppx 里常见 48）。宁可原样忽略并在规格文档里写明，也不按猜的语义改用户的路由。
- **Windows 的 `PBProfile` 有 4 MB 多**（128 条规则 × 两条 8 KB 长的列表），
  **不能放栈上**。导入时用 `malloc` 拿。

## 已知限制

- **本机（macOS）没有 MSVC / mingw 交叉编译器**，Windows 侧改动只能逐行人工复核 +
  靠 Windows 上的 `compile.ps1` 与 `run_tests.ps1` 验证
- `test_main_ui` 需要**桌面会话**才能跑（它创建真实窗口）

## 相关文件

- `docs/ROADMAP.md` —— 功能路线图（超集 Proxifier）
- `docs/PPX-IMPORT.md` —— Proxifier `.ppx` 导入的映射规格（两端共用）
- `Windows/README.md` —— Windows 端架构说明
- `MacOS/README.md` —— macOS 端架构说明
- `CONTRIBUTING.md` —— 上游贡献指南（提交 PR 前看这个）
