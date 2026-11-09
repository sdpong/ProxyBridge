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

**版本号是写在一个地方的，但宏才是真源**。`Windows/gui/res/resource.h` 里的
`PB_VER_MAJOR / PB_VER_MINOR / PB_VER_PATCH` 三个数字宏拼出期望版本，
`static_checks` 再拿它去比 `PB_VER_STR`、`PB_VER_STRW`、安装包的 `PRODUCT_VERSION` /
`VIProductVersion`、`cli/main.c` 的 `VERSION`、`src/pb_internal.h` 的 `VERSION`、
`app.manifest` 的 `assemblyIdentity version` 和 `CONTRIBUTING.md` 里的安装包名——
**一共十一个地方**。升版本时只改字符串、漏了数字宏（或反过来），
九项检查会一起红，`test_gui_misc` 里「解析 `PB_VER_STRW` 和宏要相等」那项也会红。
改版本号时，**先把三个数字宏改对，再照着它们核对所有字符串**。

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
| Build Linux | ✅ 绿 | 曾经长期红：runner 换镜像后 `bpftool` 找不到、测试有泄漏，都已修（见下） |
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

### runner 换镜像之后，Linux 构建连着坏了两处

runner 换到新镜像后，`Build Linux` **每次 push 都红**，而且是**一处接一处**——
修掉一个才看得见下一个：

1. **找不到 `bpftool`**。Ubuntu 上 `bpftool` 是虚拟包，真正的二进制由 `linux-tools-common`
   装成 `/usr/sbin/bpftool`（本来就在 PATH 上）；workflow 偏偏去
   `/usr/lib/linux-tools/*/bpftool` 里找，而 runner 跑在云内核上，没有对应的
   `linux-tools` 包，那个 glob 只能找到空目录。改成**先看 PATH，再退回版本目录**
   （`build-linux.yml`、`release-linux.yml`、`codeql.yml`、`sonarqube.yml` 四处都改了）。
2. **`Linux/gui/tests/boot_test.c` 有一处内存泄漏**。测试假定 `/usr/bin/true`
   一定是「普通的 root 文件」，但新镜像上 `/usr/bin` 本身是符号链接，
   `boot_path_trusted()` 会拒绝这样的路径（路径里带符号链接目录，正是它要防的事），
   于是它回给测试一个拒绝理由，而测试没释放这个字符串，LeakSanitizer 直接把构建判死。
   那次泄漏只有 **55 字节**，正好是
   `"/usr/bin is a symbolic link or not a regular directory"` 加结尾的 NUL——
   这行字节数就是当时定位到 `/usr/bin` 是符号链接的依据。
   改成**在几个候选文件里挑机器真正信任的那个**（`/usr/bin/true`、`/bin/true`、
   `/etc/passwd`、`/usr/bin/cat`），并把机器对其它路径的回答打印出来，
   这样「为什么被拒」是看见的而不是猜的；
   同时保留两条要求：**拒绝必须带理由**，**理由必须被释放**。
   （中途试过拿 `/` 当可信路径，那是错的：`boot_path_trusted` 要的是「文件」，
   `/` 是目录，按设计就该被拒。）

**Linux 侧的测试是开着 ASan/LSan 的**：测试里任何一处泄漏都会让整个构建失败。
所以在 Linux 侧写测试时，`g_strdup*` 出来的字符串都要有明确的释放点，
「函数会给我一个理由字符串」这种约定，调用方（包括测试）必须负责释放。

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
  - **DNS 代理配置也按 cdhash 认扩展，坑与上面同一个**：
    `NEDNSProxyManager` 保存的那条配置里也有 `ProviderDesignatedRequirement` = `cdhash H"…"`。
    ad-hoc 签名每构建一次哈希就变一次，配置里记的还是旧构建的哈希时，
    系统**直接忽略这条配置**——不报错、不启动 DNS provider，
    于是 `ip -> name` 映射永远是空的，**所有按域名写的规则全部落空**。
    隧道配置每次启动都重写（所以隧道一直好），DNS 配置当年是「已经是想要的状态就不动」，
    正好踩中这个坑。
    **修法：DNS 配置也每次启动都重写**，让系统去看当前装着的那个扩展。
    症状识别：扩展日志里有 `DNS provider is taking a query` 就是起来了，
    一行都没有就是配置过期了。
  - **provider 消息通道会按 app 的签名被系统拦下**：
    `sendProviderMessage` 走的是 app 与它自己的系统扩展之间的通道，
    系统核对签名，**ad-hoc 签名一条消息都过不去**。
    症状：隧道起得来、扩展在跑，但扩展**一条规则都没有**，
    所有连接直连，窗口里的连接列表永远是空的。
    实测：`amfid` 报 `not valid: Code=-424 "The file is adhoc signed but contains
    restricted entitlements"`，`containermanagerd` 报 app group 被拒
    （`Group containers identifiers should be prefixed by requestor's team ID`）。
    **规则、代理列表、链与 DNS 策略改为随 `startTunnel(options:)` 下发**——
    系统把启动参数交给 provider 时不查签名，这条路是通的。
    通道本身保留：正式签名的构建仍然走通道（那条路还能读回连接列表和日志）。
    - 实测还排除了两个看似合理的猜测：**扩展 bundle id 的前缀规则**不是原因
      （把 app id 改成 `com.sdpong.proxybridge` 让扩展 id 成为其前缀，照样失败）；
      **共享容器通道**也不成立——app 拿到的是用户级容器，
      扩展（root）拿到的是 `/private/var/root/Library/Group Containers/…`，
      根本不是同一个容器。
    - **Developer ID 是「窗口读得到连接列表」的正解**：
      通道恢复之后，窗口里的连接列表、Activity Log、实时流才有数据。
      不签名也能看到扩展的判定——判定写进了统一日志。
  - **统一日志会丢行**：`log show` 读的是落盘的日志库，量大了会掉行，
      看起来像「流没到扩展」。排查时用 `log stream` 实时抓，
      别用 `log show | tail`——`tail` 也会把关键行切掉。
  - **app 不能抢别人的网络配置**：macOS 把所有 app 的透明代理配置放在同一个列表里，
    而它们的 provider bundle id 可能一模一样（上游的 ProxyBridge 和本 fork 就是）。
    所以配置里要写自己的标记（`providerConfiguration`），
    启动 / 停止 / 重建时**只碰带自己标记的那条**，
    否则用户的别的代理开关会被 app 动。
    但**修复路径**例外：隧道已经起不来时，本 bundle id 的旧配置全删掉重建
    （那些配置钉的是早已不存在的哈希，留着只会一直失败）。
  - **本 fork 的扩展有自己独立的 bundle id**：`com.sdpong.proxybridge.extension`
    （上游是 `com.interceptsuite.ProxyBridge.extension`）。
    这不是洁癖，是上面那个坑的根治办法：macOS 解析 provider bundle id 时
    会从**所有已注册的同名扩展**里挑一个，挑中谁就钉谁的 cdhash。
    只要两个 build 共用一个 id，旧的那个（尤其是 app 已被删掉的孤儿）
    就会一直把隧道抢走。换成自己的 id 之后，系统只能挑到我们这一份。
    - app 自己的 bundle id **没改**（还是 `com.interceptsuite.ProxyBridge`）：
      改了沙盒容器路径，用户已导入的 profile 与设置就全没了。
    - 扩展的 `PRODUCT_MODULE_NAME` 也跟着改了
      （`com_sdpong_proxybridge_extension`），
      扩展 Info.plist 里的 provider 类名用的是 `$(PRODUCT_MODULE_NAME)`。
    - 真要用 Developer ID 签名时，描述文件的 App ID 要按新 id 申请，
      app group 也要按签名团队的 id 申请。
  - **批准入口要摆在用户看得见的地方**：扩展等待批准时，app 会**先把网络配置写进系统**，
    这样「系统设置 → 网络 → VPN 与过滤软件」里立刻出现一条
    「ProxyBridge (fork)」，把它打开就等于批准了扩展——
    比让用户自己去找「登录项与扩展」里的扩展条目靠谱得多。

### 扩展 → app 的回读通道：两道闸门，各有各的钥匙

扩展是**另一个进程**，app 要看到它做了什么，只有两条路。**两条都被卡住过，卡住的原因不一样**：

| 通道 | 谁在管 | 现状 |
|---|---|---|
| provider 消息通道（`sendProviderMessage`） | **签名** | 没开发者签名 → 一条消息都过不去 |
| 统一日志（`OSLogStore(scope: .system)`） | **App Sandbox** | 沙盒进程 → logd 拒绝 |

- **provider 通道卡在签名上**：`amfid` 报
  `not valid: Code=-424 "The file is adhoc signed but contains restricted entitlements"`。
  扩展收不到任何消息，但**隧道是好的**（规则随 `startTunnel(options:)` 下发，那条路系统不查签名）。
- **统一日志这条路卡在沙盒上**，实测三种表现：
  - `OSLogStore(scope: .system)` → `OSLogErrorDomain Code=10 "Connection to logd failed"`
  - `Process` 派生 `/usr/bin/log` → 工具自己拒绝：`log: Cannot run while sandboxed`
  - 直接读 `/var/log/system.log`、`/Library/Preferences/com.apple.networkextension.plist` → 权限拒绝

  **去掉 App Sandbox 之后三条全通**：同一个进程读同一份日志，读到 1 万 9 千条扩展写的记录。
- **但 `OSLogStore` 是快照，不是活的水龙头**——这一点踩过坑：
  - `OSLogStore(scope: .system)` **是创建那一刻的快照**。
    一直留着它，它就一直显示「创建那一刻的日志」，之后发生的连接一条都不出现。
  - 实测：同一个 store，隔几秒再读，新 store 读到最新条目，
    旧 store 仍停在快照末尾。
  - **游标救不了**：日期落在最后一条之后时，`position(date:)` 指向的是**日志末尾**，
    后面的新条目全在游标后面——越走越读不到东西。
  - **每轮重建 store 也救不了**：建一个要 **670 ms**，读一遍要 **490 ms**，
    在主线程上做就是**每秒堵 2 秒**——窗口点不动，拖不动（拖动也是主线程事件）。
  - **所以改成跟随**：macOS 自带的 `/usr/bin/log stream` 常驻跟随，
    条目来了就送到，**CPU 约 0.0%–0.1%**，主线程完全空闲。
    实测命令行连续刷 59 秒（16:09:19 → 16:10:18）。
- **统一日志里有什么**：扩展把**每一条连接判定**都写在那儿，格式固定——
  ```
  Connection TCP MiniMax Code Helper -> agent.minimax.cn:443 via Direct (rule 26)
  Connection TCP WeChat -> 240e:978:d04:3001::1d:80 via SOCKS5 127.0.0.1:9991 (rule 3)
  Flow #2300 from com.openai.codex.helper
  ```
  所以**连接列表与 Activity Log 都能从日志读回来**。
- **窗口要能拖**：`.windowStyle(.hiddenTitleBar)` 之后**窗口没有自己的标题栏**，
  自己画的那条「ProxyBridge」**只是一张标题栏的画**——没有可以抓住的地方。
  名字要放进**窗口自己的标题栏**（`.toolbar` 的 principal item），窗口才拖得动。
- **带密码的代理不需要 provider 通道**——这一条以前写错了。
  用户名和密码跟着隧道启动参数一起下去，那条路系统不查签名。
  实测（本地 RFC1929 认证的 SOCKS5 服务端）：正确密码 `AUTH OK` 并连上，
  错误密码 `AUTH FAIL`。
  还留在 provider 通道上的只有**「正在进行的连接 + 字节数」**和**扩展的运行期开关**。
- **provider 通道不通时，运行期的改动怎么到扩展**：
  改规则、改代理、改链以前只有一条路——往 provider 通道发消息。
  通道被签名拦下时，**窗口里的改动就静悄悄地什么也没发生**。
  现在两条路：通道通 → 照旧发消息；通道不通 → **重启隧道**，
  改动随隧道启动参数一起下去。重启会等一小会儿再动（连改三条规则只重启一次），
  并且等隧道真的停了才启动新的。
  实测：改一个代理的端口 → `Tunnel stopping` → `Tunnel starting` →
  之后的流量走新端口。
- **provider 通道不通时，`sendProviderMessage` 是抛异常的**。
  旧代码用 `try?` 吞了异常，**回调再也不来**，而 `stopProxy()` 等的就是那个回调，
  于是**隧道停不掉**：退出程序时隧道还在跑、规则还留着。
  现在发送失败也会回调，调用方知道「不会有回答了」，照常往下走。
- **去掉沙盒的代价**（都要处理）：
  - **偏好设置换地方**：沙盒里在
    `~/Library/Containers/<bundle id>/Data/Library/Preferences/<bundle id>.plist`，
    去掉沙盒后在 `~/Library/Preferences/<bundle id>.plist`。
    **用户的规则和代理会「消失」**——`PreferencesMigration` 在读任何设置之前把它们搬过去。
  - **app group 失效**：没有沙盒就没有 group container，
    `containerURL(forSecurityApplicationGroupIdentifier:)` 直接返回 nil。
    DNS 策略本来就随隧道启动参数下发（`payload["dnsPolicy"]`），所以不受影响。
  - **不能再上 App Store**：App Store 要求沙盒。Developer ID 直发不需要沙盒。
  - 扩展**保留沙盒**：它是碰流量的那部分，读回日志不需要动它。
- **两把钥匙的分工**：Developer ID 打开 provider 通道（正在进行的连接、运行期开关），
  去掉沙盒打开统一日志（连接列表、Activity Log）。
  **两个都要**才是完整的客户端——这也是为什么将来拿到付费会员之后，
  这套改动不用推倒重来。

### 跟随日志的管道会死锁（这条让「实时连接」一直是空的）

- **症状**：窗口能启动，能读到**最近一分钟**的日志（启动时那一次 `log show` 的结果），
  但**之后就再也没有新行进来**。活动日志停在启动那一刻，活动连接表永远是空的，
  而扩展明明在写、系统日志里明明有。
- **原因**：`FileHandle.readData(ofLength: 64 * 1024)` 是**读满**才返回的，
  而 **macOS 的管道缓冲只有 16 KB**。于是：
  - 写端（`/usr/bin/log stream`）把 16 KB 写满后**阻塞**，
  - 读端（app）在等第 64 KB，而**剩下的字节再也塞不进管道**。
  - **两边都不动**。app 只看得到管道里那 16 KB 的一部分，而且一次都读不出来。
  - 实测：`lsof` 显示管道 `SIZE/OFF = 16384`；`sample` 显示 app 的读者线程
    100% 卡在 `read`，而 `log stream` 子进程**闲着**（它以为写完了）。
- **修法**：改用 `availableData`——它**有多少给多少**，不等一个固定的数。
  同一个程序里 `availableData` 0 秒、1 秒、2 秒连续拿到数据，
  `readData(ofLength: 65536)` 25 秒一个字都拿不到。
- **判断这类问题的方法**：
  - `lsof -p <pid>` 看管道缓冲是不是 16 KB；
  - `sample <pid>` 看读者线程停在 `read` 还是停在别的；
  - `sample <子进程 pid>` 看它是**卡在 write** 还是**闲着**——
    闲着就说明它以为写完了，问题在读端。

### 流量与统计走统一日志的五种行

provider 通道不通的时候，流量与统计只能从统一日志拿。扩展写这五种行，
app 读它们（`ExtensionLogReader.parseFlow` / `parseProxyTotals`）：

```
FlowOpen 42 TCP curl -> api.github.com:443 via SOCKS5 127.0.0.1:9991
Flows 42:1234:5678 43:10:20
FlowLive 42 TCP curl -> api.github.com:443 via SOCKS5 127.0.0.1:9991 1234 5678
FlowEnd 42 9876 65432
ProxyTotals SOCKS5 127.0.0.1:9991|827000|7080000|292;Direct|0|0|820
```

- **`FlowLive` 不能省**：只在流打开时写一次的 `FlowOpen`，**后来才打开 app 的人永远看不到**——
  它早就从日志里滚走了，那条流对 app 就是「有 id、有字节、没有名字没有目的地」，
  于是列表里一行都出不来。所以每条还活着的流都要**定期重写**一行带全套信息的
  （有流量就每秒写，没流量就每十秒写一次，省得日志被刷爆）。
- **`ProxyTotals` 由扩展自己累计**：app 只看得见日志里有的东西，
  一条**在 app 打开之前就开了又关了**的流，在 app 去看的时候早就没了。
  所以每代理的连接数与字节数必须由扩展记着，app 只负责显示。
  代理名里有空格（`SOCKS5 127.0.0.1:9991`），所以分隔符用 `|` 和 `;`，不用空格。
- **Direct 的字节数是拿不到的**：DIRECT 规则在扩展里走 `return false`，
  macOS 直接把这些流交回系统，**扩展从头到尾没有碰过它们**。
  Proxifier 的 Windows 版靠驱动层抓包所以有；macOS 版要全都有，
  只能把 Direct 的流量也中继一遍（全部流量经过扩展）。
  本 fork **不做**这件事：风险大于收益，界面上 Direct 的字节写「not seen」，
  连接数照常显示。
- **`Flows` 这一行是「现在开着哪些流」的权威**：它把活着的流全列一遍，
  app 用它判断哪条流还活着。`FlowLive` 只负责补名字和目的地。

### macOS 系统扩展的登记、显示与清理（实测）

这一节记的是「用户看得到、但说不清」的那几个现象，都是实测出来的。

- **`systemextensionsctl uninstall` 的 team id 参数**：
  用法是 `uninstall <teamID> <bundleID>`，手册写明 team id 也可以是**单个 `-`**
  （`for matching empty Team ID`）——ad-hoc 签名的记录**没有** team id，就写这个 `-`。
  实测三种写法的结果：
  | 写法 | 结果 |
  |---|---|
  | `uninstall com.sdpong.proxybridge.extension`（缺 team id） | 只打印 usage，什么都没删 |
  | `uninstall -- com.sdpong.proxybridge.extension` | `team ID '--' does not exist` |
  | `uninstall - com.sdpong.proxybridge.extension` | `Success`，真的卸载了 |
  之前的清理命令用 awk **把空的 team id 过滤掉了**，于是参数少一个，永远只打印 usage。
- **扩展在系统设置里的显示名来自 build setting `INFOPLIST_KEY_CFBundleDisplayName`**，
  **不是** `Info.plist` 里的 `CFBundleDisplayName` 键（改了后者没有任何效果）。
  默认值是 `extension`，于是系统设置里几个条目全都叫 "extension"，用户分不出哪个是新的。
  现在设成「ProxyBridge 扩展」。
- **每装一次 app 就多一条扩展登记记录**：旧的记成
  `terminated waiting to uninstall on reboot`，**重启一次**才会真正清掉。
  本机实测攒到 11 条，只有 1 条是 `activated enabled`。
- **同一个 app 可能留下两条透明代理配置**：早期 build 用另一个 app bundle id 写了一条，
  一直没删。两条的 owner 标记完全一样（`owner = sdpong.ProxyBridge.fork`），
  而 `NetworkConfigOwner.ourManagers` 只更新 `ours.first`——另一条永远留着，
  于是「VPN 与过滤软件」里出现两个「ProxyBridge (fork)」。
  **归属哪个 app 是读不出来的**（`NEVPNProtocol` 没有这个公开 API，KVC 也读不到），
  所以修法是：**发现属于本 app 的配置超过一条，就全部删掉重建一条**。
  反正每次也要重建（cdhash 变了）。
- **`NEDNSProxyManager.saveToPreferences` 在扩展还没批准时会报 `permission denied`**：
  这是个会过去的状态，所以现在重试几次再算失败。不重试的话，
  扩展刚装上那一会儿启动的 app 会**顺带把旧条目清掉**（系统会清），域名规则全部落空。
- **「扩展没回答」和「另一个旧扩展回答了」是两回事**：
  握手重试三次没应答，**不能**报「另一个扩展回答了」——旧扩展会回一个不同的协议号，
  那是被单独检查过的。什么都没回答 = 消息根本没过去（签名问题）。
  说错会让用户去删跟问题无关的扩展。
- **provider 通道被签名拦下时，隧道其实是通的**：规则和代理列表随 `startTunnel(options:)`
  下发，系统把启动参数交给 provider 时**不查签名**。
  所以症状是「流量在代理，但窗口里连接列表是空的」，不是「什么都不代理」。
  这两件事在提示里必须分开说，否则用户会去查错的方向。

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

### DNS 代理必须接管每一个查询（Dia 登录不上的真正原因）

- **现象**：Dia 规则正确、代理正确、流量确实走了 SOCKS5，但 Dia 登录报
  “Something went wrong. Please try again.”，同一个代理在 Proxifier 里正常。
- **根因不是进程过滤**，是**扩展交给代理的是地址，不是名字**。
  浏览器自己解析（不走系统解析器），它的 DNS 查询被规则送进了代理，
  **代理回了一个只有它自己懂的地址**；扩展不知道这个地址对应哪个名字，
  只能把地址本身交给代理 → 连不上。
- **三个缺口**（`extension/DNSProxyProvider.swift`、`extension/DNSMapStore.swift`）：
  1. **DNS 代理以前会放行查询**：`!autoDetectUpstream && upstreamResolvers.isEmpty` 时
     直接 `return false`，名字缓存永远是空的。
     **现在无条件接管**：策略决定的是「查询发给谁」，不是「要不要接管」。
  2. **从代理回来的 DNS 应答被扔掉了**：现在也记进 `DNSMapStore`，
     代理给的假地址因此能对上名字（`extension/AppProxyProvider.swift` 的 `recordDNSAnswer`）。
  3. **IPv6 地址有两种写法**：应答里是 `fd00:696e:0:0:0:ffff:0:38`，
     流里是 `fd00:696e::ffff:0:38` —— 同一地址两个键，缓存永远查不到。
     现在统一走 `DNSMapStore.canonicalAddress`。
- **Proxifier 的做法**：它自己解析，然后把**名字**交给代理。我们现在也是这个行为。
- **DNS 代理的状态写进统一日志**（`DNSStatus running queries 12 answers 11 names 7 last x -> y`），
  App 侧从日志读回来显示在 DNS 设置窗口里。
  **不能用 provider 消息通道**：没签名的构建那条通道是关的（日志是唯一出路）。

### 规则只写 TCP 时，QUIC 会绕过代理（Dia 登录不上的第二个原因）

- **现象**：同一条 Dia 规则、同一个代理，别的页面都正常，登录却报
  “Something went wrong. Please try again.”。**和上面那条不是同一个原因**：
  上面那条是「地址不是名字」，这条是「UDP 根本没有规则接」。
- **根因**：浏览器优先用 QUIC（HTTP/3，udp/443）。规则的 `protocol` 写的是 `TCP` 时，
  **没有任何规则匹配这条 UDP** —— 它落到最后的 DIRECT 规则，直接出机器。
  网站看到的 IP 和这个程序其余流量（走代理）的国家不一样，
  Cloudflare 判定为攻击，返回 403，页面里写着 “Sorry, you have been blocked”。
- **证据**（Chromium netlog `--log-net-log`）：
  登录请求 `POST https://account.diabrowser.engineering/signin/method?embed_flow=true&rebrand=true`
  的响应是 `:status: 403`、`server: cloudflare`；
  同一个地址用 `curl` 走 TCP 是 200，Dia 加 `--disable-quic` 也是 200。
- **修法，两层**：
  1. **UDP 跟随同一条 TCP 规则**（`extension/AppProxyProvider.swift` 的 `udpRuleChoice`）：
     没有规则说 UDP 时，去问「这个程序的 TCP 规则」，它说往哪走，UDP 就往哪走。
     日志写 `(udp follows the tcp rule)`，让人一眼看出这是回退来的。
  2. **QUIC 兜底**：只写 TCP 的规则把 TCP 送进代理时，这个程序的 **udp/443 停掉**，
     浏览器因此改用 TCP —— 而 TCP 走的是规则指定的那个代理，出口只有一个。
     两条都要，因为「UDP 送进代理」还不等于「UDP 从代理出去」：
     macOS 的透明代理有时不接管已经建立的 UDP 连接，
     下游代理也可能只拿到地址、拿不到名字，于是按自己的规则走 —— 那就是第二个出口。
- **规则写 `BOTH` 的用户不受影响**：那是明确说「UDP 也走代理」，不停。
  规则写 `DIRECT` 也不停：程序本来就是直连，QUIC 直连是同一件事。
- **还有一处没覆盖**：代理链和 HTTP 代理本来就带不动 UDP，它们的 UDP 一直直接出去，
  QUIC 也一样。这两条路上没有「让它回落 TCP」的办法 ——
  要停它们得再写一套直连转发，这轮没有做。
- **三端默认值对齐**：Windows/Linux 新建规则默认 `BOTH`
  （`Windows/gui/main.c` 的 `ProtoIdx`、`Linux/gui/gui_rules.c` 的 `RULE_PROTOCOL_BOTH`），
  macOS 以前默认 `TCP`，现在也改成 `BOTH`。
- **PPX 导入仍然写 TCP**：Proxifier 本身只代理 TCP（`docs/PPX-IMPORT.md`），
  `<BlockUDP443>` 不导入；导入来的规则现在有上面那条兜底语义。

### 代理服务器模式下，本机自己也是一个客户端（统计和活动连接都要算上）

- **问题**：代理服务器模式以前**只显示网络里客户端的流量**，本机自己的流量看不见。
  但本机在代理服务器模式下**照样走隧道**（`applyRuntimeMode` 里三种模式都调
  `startTunnelIfNotRunning()`，扩展在三种模式下都在跑）—— 只是表格把它藏起来了。
  照这么看，「本机也是自己代理的一个客户端」这件事就没法一眼看到。
- **现在**（`MacOS/ProxiRoute/ProxiRoute/ProxiRouteViewModel.swift`）：
  - **统计**：本机的总量（扩展数的）和客户端的总量（服务器数的）**按来源和代理分行**：
    「来源」一列写「**本机**」或者客户端的地址（`192.168.254.140` 这样的）。
    合并逻辑抽成了纯模块 `MacOS/ProxiRoute/ProxiRoute/TrafficMerge.swift`，
    可以单独测（`MacOS/tests/logic/trafficmerge_tests.swift`）。
    直连的字节仍然标「未记录」——但**只有本机的那一行**是这样：
    macOS 把直连的流交回系统，扩展根本看不到它们的字节；
    客户端的直连是服务器自己转发的，字节它知道。
  - **活动连接**：本机的流和客户端的流**合在一张表里**。两边的 id 都从 1 开始数，
    会撞号，所以客户端的流用 id 的高位（`LiveFlow.clientTableId`，`id | 0x8000_0000_0000_0000`）
    区分来源。本机的流写进程名，客户端的流写客户端的地址（`127.0.0.1` 这种）——
    网络里的客户端没有程序，地址就是能说的全部。
  - **终止连接**：客户端的流**不能由扩展终止**（`killFlow` 见到 `origin != .machine` 就直接返回）——
    那是服务器手里的连接，扩展拿不到它的 socket。
- **来源怎么分开算的**：服务器原来是**按代理名**累加的（`proxyTotals[代理名]`），
  几个客户端走同一个代理就并成一行，谁走了多少就说不清了。
  现在是**按 (客户端, 代理)** 累加（`proxyTotals[客户端][代理名]`），
  `ServerProxyTotal` 带上 `client`。
- **来源列什么时候出现**：网关模式和代理服务器模式出现（这两种模式是给别的终端用的），
  本地模式不出现 —— 本地模式只有本机，没有第二个来源，分了也是白分。
  SwiftUI 的表格列没法在 macOS 13 上按条件增减（那要 14.4），
  所以带来源和不带来源的表各写了一份。
- **顺带修了一个真 bug**：服务器统计里的字节**只在连接结束时才累加**，
  正在传的流量在统计表里是 0（扩展那边是实时算的，两边口径不一致）。
  `LocalProxyServer.trafficSnapshot()` 现在把**进行中的流的字节也加上**，
  和扩展一个口径。改之前实测：客户端下载 25 秒、下了几 MB，
  统计行的「已接收」一字节不动；改之后从 11 KB 涨到 4.5 MB。
- **代理服务器的上出口是设置，不是规则**：设置里 `upstream` 可以是 `direct`（直出）、
  `proxy(id)`（走某一个代理）、`rules`（按规则）。
  默认是 `direct`，所以「客户端访问不上 google」多半不是 bug，
  是这个设置还没切到 `rules` —— 客户端没有程序，只有带域名/端口的规则才管得到它。

### 切换运行模式不该重启 DNS 代理

- **现象**：切换运行模式（本地 / 网关 / 代理服务器）之后的几秒里，
  **所有名字解析失败**（Chromium netlog 里一片 `ERR_NAME_NOT_RESOLVED`），
  刚打开的网页打不开；过几秒又好了。
- **原因**：`applyRuntimeMode` 里调了 `applyDNSProxy()`，而 `applyDNSProxy`
  会把 DNS 代理的配置**再写一遍**（`saveToPreferences`）—— macOS 于是把那个
  provider 停掉再启动（扩展日志：`DNS proxy stopping: the provider was disabled (5)`
  紧跟着 `DNS proxy starting`）。重启的那几秒里没有代理回答查询，名字就解析不了。
- **这个调用本来就没有用**：DNS 代理有自己的开关（`toggleDNS`），
  注释里自己写着「模式不决定它」。模式切换没有改这个开关，
  却把它重启了一遍 —— 白白换来一个解析空窗。
- **现在**：切模式不动 DNS 代理；开关变了（`toggleDNS`）才重新写它的配置。

### DNS 设置窗口：Save / Cancel 以前等于没做

- **它是一个独立 Window，不是 sheet**：`Cancel` 只把旧值读回输入框，**窗口不关**；
  `Save` 写完也不关。看上去就是「按了没反应」。
- **窗口是复用的**：SwiftUI 视图留在窗口里，第二次打开**不会再触发 `onAppear`**，
  窗口显示的是**第一次打开时的旧值**——保存时等于把旧值又写回去。
  现在用 `viewModel.dnsSettingsOpenCount`（打开时 +1）通知视图重新装载。
- **`updateDNSPolicy` 以前只写全局键**，profile 快照不更新：
  导出的 profile 里是旧策略，切换 profile 回来设置也白改。现在两个都写。
- **窗口现在显示 DNS 代理的实时状态**（跑了多少查询、知道多少名字、上一次是什么名字），
  另有「系统里的 DNS 代理条目是不是开着」。
- **系统会自己把 DNS 代理条目关掉**：条目记着扩展的代码签名，
  ad-hoc 构建每编译一次签名就变一次，系统于是拒绝这个条目
  （日志里是 `the configuration was disabled`）。
  现在 app 每 30 秒看一眼，被关掉就重新写回去。

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

### 规则编辑器：多行输入，错的条目标红

- **原来只有两个单行输入框**：`Process / Bundle Identifier` 和 `Target hosts`。
  规则里要写两个以上的程序或主机，就只能手打分号，而且**看不出写错**：
  同一个域名写两遍、两个 IP 段互相重叠，界面上一片正常，规则却不是想要的那条。
- **现在两个框都是多行文本框**，一行一条。保存时仍然存成 `a; b; c` 的单行分号串
  （扩展只按 `;` 拆），所以**扩展那边一个字都不用改**，
  老的规则读出来也是老样子。
- **标红的判断写在 app 侧的 `RulePatternValidator.swift`**（纯逻辑，有单测：
  `MacOS/tests/logic/rulepattern_tests.swift`），
  用的语法**和扩展 `AppProxyProvider.swift` 里的匹配器一样**：
  - `*` 通配、域名大小写不敏感、`*.example.com` 也覆盖 `example.com`；
  - IP 支持 `a.b.c.d`、`a.b.c.*`、`lo-hi`、`2001:db8:*`；
  - **不支持 CIDR**（`10.0.0.0/24` 会被标红，并提示改写成 `10.0.0.0-10.0.0.255`）。
- **标红有五种**：重复、被别的条目覆盖、IP 段重叠、IP 写反了、用了 CIDR。
  **只要有一条是红的，「保存规则」就是灰的**——这些规则的行为是含糊的
  （两条都匹配时谁赢？），存下来也说不清。
- **两个分隔符不一样**：主机之间可以拿空格分开（域名里没有空格），
  程序名里**有**空格（`Google Chrome Helper`），所以程序只按 `;` `,` 和换行分开。
  IP 段里的空格（`10.0.0.1 - 10.0.0.254`）跟着段走，不能拆开。
- **坑：SwiftUI 的 `TextEditor` 不能给局部文字上色**。要像拼写检查那样
  在出错的那一段上打红底，只能用 `NSTextView` 包一层（`PatternTextEditor.swift`）。
  注意别把用户正在选中的文字冲掉（加属性前后要把 `selectedRanges` 存下来再放回去）。

### 规则列表：条目一行一条

- **原来 `Bundle ID` 和 `Target Hosts` 两列直接显示存储串**，也就是
  `QQ; com.tencent.qq; DingTalk; com.alibaba.DingTalkMac` 这样挤成一长条，
  一眼看不出这条规则到底管哪几个程序、哪几个主机。
- **现在两列按条目分行显示**，跟编辑器里看到的、跟 Proxifier 的规则表一个样子。
  用的还是 `RulePatternValidator.displayForm`——**只是显示形式变了，
  存储格式一点没动**，扩展那边依旧只按 `;` 拆。
- **注意别用 `Text` 直接塞换行符**：改成 `RuleEntryCell`（`VStack` + `ForEach`）
  才是一行一个 `Text`，`Text` 的换行在表格单元格里不按预期排。
  `ForEach` 的 id 用 `\.offset` 而不是 `\.self`，因为条目**可以重复**
  （重复的条目正是编辑器要标红的那一类），用 `\.self` 会崩。

### 进程选择器：别的规则已经用过的进程标黄

- **原来能选任何进程**，于是一个程序常常同时落在两条规则里。
  先匹配到的那条拿走流量，另一条看着像在干活，其实什么也没做。
- **现在选择器知道别的规则写了什么**，并且**只认生效的规则**：
  - **生效**的规则写了某个程序 → 这一行**整行标黄**，**点了也选不中**，
    右边写着是**哪条规则**写的（规则名）。
  - **没生效**（开关关着）的规则写了某个程序 → **不标黄**，右边写
    `规则名 (off)`；**可以选**，但选的时候**弹一句提示**告诉用户
    「别的规则也写了它，那条规则现在关着」，**不阻止**。
- **按匹配器的语义判断**，不是按字符串相等：
  别的规则里写 `*chrome*`，那 Google Chrome 就算被占用了。
- **但是 `*` 不算占用**：一条「匹配所有程序」的规则没有占住任何名字，
  否则一旦有这种规则，选择器里就什么都选不了了。

### 选择器里三个按钮：所选字段排第一行

- **原来 `Name` / `Bundle ID` / `Full path` 三个按钮点起来长得一模一样**，
  用户根本看不出按下去会加哪一个字段。
- **现在把「会被加进规则的那个字段」放到第一行大字**，
  其余两个降成灰色副行；语义没变，按 `Bundle ID` 仍然是加 bundle id。
- **当前这条规则里已经有的程序不再出现在列表里**：
  判定是**精确相等**（name / bundle id / full path 全等，大小写不敏感），
  **通配不算**——`*chrome*` 这种写法在扩展那边照样命中这个程序，
  用户可能仍想把它明写出来。

### 编辑器里的黄色标记和点击提示

- **Edit Rule 的 `Target hosts` 和 `Process / Bundle Identifier` 两个框**，
  别的**生效**规则写过的条目**标黄**（黄色是「别的规则也写了它」的提示，
  红色留给「这条写错了」）。当前这条规则自己写的**不标黄**。
- **点框里被「没生效的规则」命中的条目会弹提示**，说明是哪条规则写的，
  **但照常能用**——只是提醒，不是禁止。
- **规则列表里点一条没生效的规则的铅笔**，如果它和别的规则写了同样的东西，
  弹一个 **Named twice** 的提示（列出和哪条规则重复、哪条生效哪条未生效），
  底下有 **Cancel / Open**；**Open 照样能打开这条规则**，提示不拦人。

### 坑（本轮踩到的，写下来免得再踩）

- **规则存储里没有 `localId`**：`ProxyRule.toDict()` 不写它，
  `init(dict:)` 每次都现生成一个随机 UUID。
  所以**用 `localId` 排除「当前这条规则」永远排除不掉**——
  排除条件和被排除对象每次都不一样。
  最后改成**由规则列表直接把「别的规则」传给编辑器**
  （`RuleEditorView(otherRules:)`），不靠 id 对比。
- **`NSTextView.mouseDown` 要在 `super` 之前报告点击位置**：
  `super.mouseDown` 会进入 AppKit 的 tracking loop（等鼠标松开才返回），
  放在它**之后**的回调可能等不到、或在窗口重建时丢掉。
- **SwiftUI 的 `Table` 单元格里的按钮，点第一下只是选中那一行**，
  第二下才真的触发。用合成点击事件驱动界面时要点**同一个位置两次**。

### 关窗口不等于退出：后台代理的寿命

- **原来关窗口 = 退出 app = 隧道停掉**。下载到一半关了窗口，代理就没了。
- **现在默认关窗口只是关窗口**：app 和隧道继续跑。
  设置在 **Settings 菜单**和**菜单栏图标**里，叫 `Keep Proxy Running in Background`，
  **默认开**；关掉它就是原来的行为。
  这个键是**全局的**（不像 `closeToMenuBar` 那样跟着 profile 走），
  因为它是「这个 app 要不要在后台活着」，不是某一套配置的事。
- **窗口怎么回来**：点 Dock 图标，或者菜单栏里的「Open ProxyBridge」，
  或者在终端里 `open -a /Applications/ProxyBridge.app`。
  最后这一条以前是**没用的**：窗口收进菜单栏之后 app 变成 accessory（没有 Dock 图标），
  AppKit 在 reopen 时什么都不做，窗口再也回不来。
  现在 `applicationShouldHandleReopen` 会把 `AppDelegate.mainWindow` 叫回来
  （`makeKeyAndOrderFront`），并且顺手把 app 从 accessory 改回 regular。
  **顺带修掉一个 SwiftUI 的坑**：`WindowGroup` 不带 id 时没法用 `openWindow` 重新打开，
  试过加 id，结果非正常退出后重启会出现两个窗口（系统按上次状态恢复一个，
  SwiftUI 自己又开一个）。最后是**app 侧强引用主窗口**（`AppDelegate.mainWindow`
  从 weak 改成 strong），关掉之后窗口对象还在，叫得回来。
- **`applicationShouldTerminateAfterLastWindowClosed` 必须一直返回 false**：
  它数的是**所有**窗口（包括菜单栏那个），macOS 26 上点开菜单再点外面
  看起来就像「最后一个窗口关了」，app 会自己退出（#233）。

### 多语言：中文 / 英文（自己写的字典，`.lproj` 只用来声明语言）

- **两种语言**：中文（简体）和英文。**第一次启动跟随系统语言**，
  之后记住用户的选择（UserDefaults 里的 `appLanguage` 键）。
- **在 Settings 菜单里切换**，切换后**所有打开的窗口立刻重绘**，不用关窗重开。
- **翻译表在 `MacOS/ProxyBridge/ProxyBridge/L10n.swift`**，不是 `.xcstrings`：
  - 字典表**可以编进 ad-hoc 签名的二进制**，也可以在不改资源流程的前提下增删；
  - **key 就是英文原文本身**，没翻译的句子直接显示英文，不会露出一个 key；
  - `L10n.f(_:_:)` 处理带 `%@` 的插值句，`L10n.t(_:)` 处理整句。
- **视图持有 `@ObservedObject private var loc = LocalizationManager.shared`**，
  `LocalizationManager` 是 `ObservableObject`，`@Published language` 一变，视图就重画。
- **语言选项是菜单里的两个直接项**（`简体中文` / `English`），**不是子菜单**：
  子菜单要靠鼠标驻留才展开，驻留时间不够就点不开——用户报的就是这个。
  两个直接项点一下就中，没有驻留这回事。
- **逻辑测试 `l10n_tests.swift` 会扫 app 源码**：把每个 `L10n.t(` / `L10n.f(` 用到的 key
  收集起来，核对翻译表里都有。漏一条不会让 app 崩（会退回英文），
  但会让翻译悄悄破个洞，测试就是堵这个洞的地方。
- **翻译的边界**：**界面上的文字全部走 `L10n`**（窗口、表格、日志、导入提示、状态栏菜单），
  但 **CLI 输出和代理检测器的技术输出保持英文**——
  那是给脚本和管道看的，工具输出用英文是惯例，翻译它反而碍事。

#### macOS 自己画的那些菜单，翻译要分两层做

- **菜单栏顶层的四个标题（编辑 / 显示 / 窗口 / 帮助）是 SwiftUI 自己画的**，
  不是从 `NSApp.mainMenu` 读的。改 `NSApp.mainMenu` 里那四个标题的字符串，
  **屏幕上不会变**（用 `ZZZEDIT` 之类的标记试过：对象里是 ZZZ，屏幕还是 Edit）。
- **菜单的条目（撤销 / 重做 / 剪切 / 拷贝 / 粘贴 / 删除 / 全选 / 自动填充 /
  开始听写… / 表情与符号 / 最小化 / 缩放 / 前置全部窗口，以及应用菜单的条目）
  确实是 AppKit 从 `NSApp.mainMenu` 画的**，所以**运行时改名是有效的**。
  实现在 `MacOS/ProxyBridge/ProxyBridge/StandardMenuLocalizer.swift`：
  监听 `NSMenu.didChangeItemNotification` 和 `NSApplication.didBecomeActiveNotification`，
  每来一次就重新改名一遍，带 `applying` 重入保护。
  - **必须靠通知，不能只改一次**：SwiftUI 会不停重建菜单栏（实测 780+ 次重建），
    每次都把自己的英文标题写回去。监听通知才能保证「看的那一刻是对的」。
  - `NSMenu.itemChangedNotification` **不存在**，正确的名字是 `NSMenu.didChangeItemNotification`。
- **顶层的四个标题只能靠 app bundle 的语言**。做法是：
  - app bundle 里放 `zh-Hans.lproj/Localizable.strings` 和 `en.lproj/Localizable.strings`，
    **两个文件都是空的**（只有一句注释）——字符串仍然在 `L10n.swift` 里，
    `.lproj` 只是**声明「这个 app 会说这两种语言」**，让 AppKit 知道去哪儿取；
  - app 启动时把当前语言写到 `UserDefaults` 的 `AppleLanguages` 键上
    （`main.swift` 最前面，`LocalizationManager.didSet` 里同步一次），
    **app 里的选择因此排在系统语言前面**。
  - **结果**：系统中文 + app 选 English → 菜单栏整条英文；
    系统中文 + app 选中文 → 整条中文。实测截图确认过两种。
- **bundle 的语言在进程启动时就被缓存了**（`Bundle.main.preferredLocalizations`
  切完还是旧值），`CFBundleSetLocalization` 在现在的 SDK 里已经**不导出**（链接失败）。
  所以**运行时切换语言后，那四个标题要下次启动才换过来**。
  设置菜单里有一行灰字说明这件事（`The menus macOS draws itself ... next time`），
  不然看起来就像切换没生效。

#### `L10n.f` 的多参数 bug（改一次，所有插值句都对了）

- 原来的 `L10n.f` 用 `replacingOccurrences(of: "%@", with: ...)` 换占位符，
  **`replacingOccurrences` 会把所有 `%@` 都换成第一个参数**——
  于是「A 到 B」这种两个名字的句子，两个位置都成了第一个名字。
- 现在改成**按顺序替换第一个还没用掉的占位符**，参数多的时候不会串位。
- `l10n_tests.swift` 里有 4 条断言专门盯这个。

### 代理链的健康检查（断则跳过，好则接回）

- **扩展每 10 分钟探一次链上每一跳**（`ChainHealth.probeInterval = 600`），
  定时器每 60 秒醒一次，只探到期的跳；**没探过的跳立刻探一次**，
  所以刚建好的链不用等十分钟才有第一个答案。
- **探的是跳本身**：TCP 连上就算活着；**SOCKS5 还要再问一声握手**，
  因为「端口开着但后面没东西」不是一个能用的代理。
- **不通的跳被跳过**，日志写 `Chain health: <跳> does not answer, it is skipped until it does`；
  **恢复了就接回链里**，日志写 `Chain health: <跳> answers, it is back in its chain`。
- **全链都不通时仍然整条尝试**，不静默直连——用户看到的是代理失败，不是流量跑掉了。
- **只由周期探测决定跳不跳**，不做「每条连接失败就临时跳一跳」：
  中间跳的 CONNECT 失败和「最后一跳连不上目标」在扩展看来是一样的，
  贸然跳过会把流量送到用户没要求的地方。
- **健康状态只在扩展的内存里**，跨进程只能靠统一日志——
  ad-hoc 签名下 provider 消息通道不可用（见上面「扩展 → app 的回读通道」）。
  app 侧靠解析 `Chain health: ` 开头的行来显示红标。
- **app 侧另有「测试链」按钮**（`ProxyChainTesterView`）：逐跳测一次，给出 ✓/✗ 和延迟。
  这一条走 app 自己的 socket（`ProxySocket.swift`），和扩展的周期探测互不干扰。

### 把包名送给代理服务器（可行，已实现）

- **这是 Proxifier 的能力**（按应用决定走哪个代理），本轮把它落到了协议层：
  **代理服务器知道这条流量来自哪个程序**，服务端就能按程序分流。
- **做法是按代理配置开关的**（`sendAppIdToProxy`，默认关）：
  - **HTTP**：加两个头 `ProxyBridge-App-Id` 和 `ProxyBridge-Process`。标准代理会忽略不认识的。
  - **SOCKS5**：用 RFC1929 的**用户名字段**。**必须只提供 method `0x02`**，
    否则服务端会挑 `0x00`（不要求认证），包名永远到不了。
  - **SOCKS4**：用 USERID 字段。
- **已经配了凭据时凭据优先**：用户名字段只有一个，给了包名就没地方放凭据。
- **服务端拒绝认证时，不带包名重走一次链**（只重试一次，第二次失败就结束这条连接），
  这样「服务端不认这个用户名」不会变成「连不上」。
- **纯逻辑在 `extension/ProxyAppIdentity.swift`**，`appid_tests.swift` 覆盖握手字节。

#### 送什么包名：由**命中的那条规则**说了算，不是流量本身

- **规则没有设定过滤程式（进程过滤）时**，送 **ProxyBridge 自己的包标识名**
  （扩展的 bundle id，本 fork 是 `com.sdpong.proxybridge.extension`），
  **进程名字段留空**。这就是**虚拟进程名字**：
  代理看到的是「一大块 ProxyBridge 自己的流量」，而不是某个应用。
  用户可以在代理那边按这一个名字写一条规则。
- **规则有进程过滤时**，送**真实来源程序的 bundle id**（进程名一起送，HTTP 走第二个头）。
- **是规则说了算，不是流量说了算**：同一个程序走过两条规则，
  在第一条那里被当成那个程序，在第二条那里被当成 ProxyBridge——**规则怎么写就是这么回事**。
- **实现**：`ProxyRule.Matcher.hasProcessFilter`（`!processAll`），
  `findMatchingRule` 现在返回 `CompiledRule`（规则 + matcher）而不只是规则，
  调用点取 `matched?.matcher.hasProcessFilter`。
  `ProxyAppIdentity.payload(bundleId:processName:ruleHasProcessFilter:proxyBridgeBundleId:)` 是唯一的决定点。
- **真机端到端验证过**（用假的 SOCKS5 / HTTP 服务器看它到底收到了什么）：

  | 规则 | 代理收到的用户名字段 / 头 |
  |---|---|
  | 无进程过滤 | `com.sdpong.proxybridge.extension` |
  | 进程过滤 `com.apple.*` | `com.apple.Safari`（HTTP 还带 `ProxyBridge-Process: Safari`） |

- **Clash / mihomo 侧怎么用**：包名只能进 `inboundUser`（SOCKS5 用户名），
  代理侧写 `IN-USER` 规则按应用分流。
  **「让 Clash 的进程栏显示真实应用名」是做不到的**——mihomo 的 `metadata.Process`
  只来自本机 socket 的属主，源码级别没有别的来源。
  能做的是**包名进 `IN-USER` 规则**，Clash 的「规则/链路」栏会显示命中的那条 `IN-USER` 规则。

#### 做这个验证时的两个坑

- **回环地址（127.0.0.1）的流量根本进不了隧道**：
  用 `curl http://127.0.0.1:18080/` 去试，连接直接出去了，扩展连日志都没有。
  要试就用**非回环的目标**（比如 `1.2.3.4:18080`）——反正假代理根本不会真的去连目标。
- **`curl` 会读 `no_proxy` 环境变量**，本机的 `no_proxy` 里有 `127.0.0.1`，
  试回环地址时它会自己绕开隧道，看起来像是扩展没生效。
  要试就得 `env -u no_proxy curl --noproxy "" ...`。
- **GUI app 和 CLI 不能同时开**（都要控制同一个扩展），
  做这种验证最省事的是用 `ProxyBridge --profile -` 喂一份临时 profile，
  跑完 `Ctrl+C` 清规则，**用户的 profile 一个字都不会动**。

### 链的存盘格式：跳板走的是 `proxies`，不是 `proxyIds`

- **这是本轮挖出来的一个真 bug**：扩展日志一直写 `27 config(s), 0 chain(s)`——
  **链根本没送到扩展**，规则里指向链的流量等于没走链，链健康检查也没有目标可探。
- **原因是两边对同一个词的理解不一样**：
  - **链的跳板在 json 里的键是 `proxies`**——Proxifier 的 `.ppx` 导入写的是它，
    命令行读的是它，扩展读的也是它（`extension/AppProxyProvider.swift` 里
    `chainDict["proxies"]`）。
  - **app 的 `ProxyChain` 却写 `proxyIds`**。于是**从导入进来的链**（带 `proxies`）
    被 app 读成「一条没有跳板的链」，而空链会被扩展直接丢掉 → `0 chain(s)`。
- **现在两种键都读，写的是 `proxies`**（`ProxyChain.CodingKeys`），
  所以 app、命令行、扩展说的是同一个词，旧配置也不会丢跳板。
- **导出和导入都走同一个解码器**，出来的形状两边都认。
- **逻辑测试 `chainstorage_tests.swift`**：两种形状各读一次、写一次再读回来。

### 改偏好设置要用 CFPreferences，`defaults import` 靠不住

- **本机有两份 `com.interceptsuite.ProxyBridge` 的偏好**：
  `~/Library/Preferences/` 下的一份，和
  `~/Library/Containers/com.interceptsuite.ProxyBridge/Data/Library/Preferences/` 下的一份。
- **`defaults import` / `defaults export` 读写的是容器那一份**，
  而 **app 读的是另一份**。用 `defaults import` 改完，**app 看到的还是旧值**——
  扩展日志里拿到的仍是改之前的地址，很容易误判成「改了没生效」。
- **可靠的办法**：用 `CFPreferencesSetAppValue` + `CFPreferencesAppSynchronize`
  （`CFPreferencesCopyAppValue` 读回来验证），它写的就是 app 读的那一份。
- **改完要用 `defaults export` 核对两份是否一致**——两份不一致时，
  哪一份被 app 读到取决于进程上下文，不能靠猜。

## 本轮：改名 ProxiRoute + 本机代理服务器 + 路由模式 + CPU 修复

这一轮做了四件事，顺序是：先把软件改名，再加「本机当代理服务器」和「路由模式」，
最后处理这两样东西把 CPU 吃到 100% 的问题。

### 改名：软件、包名、扩展 id、app group 全都换了

| | 旧 | 新 |
|---|---|---|
| app bundle id | `com.sdpong.ProxyBridge` | `com.sdpong.ProxiRoute` |
| 扩展 bundle id | `com.sdpong.proxybridge.extension` | `com.sdpong.proxiroute.extension` |
| app group | `group.com.sdpong.ProxyBridge` | `group.com.sdpong.ProxiRoute` |
| 命令行 | `proxybridge` | `proxiroute` |
| 日志子系统 | `com.sdpong.proxybridge.extension` | `com.sdpong.proxiroute.extension` |

- **改名的原因很直接**：本机同时装了**真正的 Proxifier**（`com.initex.proxifier.v3.macos.ProxifierExtension`，
  已激活）和我们自己的扩展，两个透明代理抢同一批流量。名字不一样，排查时能一眼看出是谁在管这条连接。
- **老数据迁移并清掉**：旧偏好、旧 app group 里的配置文件都搬过来，然后删掉。
  旧的 `ProxyBridge.app` **保留不删**（用户自己决定什么时候清理）。
- **新旧双读**：owner 标记、`providerConfiguration` 的键（新的 `proxiroute`，回退旧的 `proxybridge`）、
  自流量豁免列表——**旧扩展还登记在系统里**（要重启 Mac 才会卸载），
  它的 id 还在豁免列表里，免得它把自己也代理一遍。
- **系统扩展要重新批准**：换了 bundle id 就是一个新的扩展，
  要在「系统设置 → 通用 → 登录项与扩展 → 网络扩展」里再批准一次。

### 网关模式：为什么必须另做一条数据面（查证记录）

> 完整方案见 [docs/GATEWAY.md](GATEWAY.md)。这里是**查过的事实**，别再查第二遍。

- **本 fork 的 macOS 扩展基类是 `NETransparentProxyProvider`**（`extension/AppProxyProvider.swift:392`），
  不是 `NEFilterDataProvider`。它接的是**本机进程开的 socket**。
- **NetworkExtension 没有任何 API 能看到别的机器的包**（Apple 文档原文）：
  `NEPacketTunnelProvider` 收的是**本机**发往指定目的地的包；
  `NEAppProxyProvider` / `NEFilterDataProvider` 的 flow 都是「本机应用开的连接」；
  `NETransparentProxyProvider` 继承 `NEAppProxyProvider`。
  → 网关模式是**另一条数据面**，不是给现有扩展加个开关。
- **macOS 转发必须 root**（本机实测）：
  `pfctl -ss` → `Permission denied`（`/dev/pf` 是 `crw------- root wheel`）；
  `sysctl -w net.inet.ip.forwarding=1` → `Operation not permitted`。
  `pfctl(8)` man 原文：*"The packet filter does not itself forward packets between interfaces"* ——
  **PF 和转发是两件事**。
- **macOS 没有 `/dev/tun`**（本机实测不存在）。utun 由内核控制，非特权进程建不出可用的 utun；
  社区做法一致：root 守护进程持有 utun。
- **SIP 不挡这些**（它保护 `/System`、kext、关键二进制）。
  **App Sandbox 挡**（沙盒进程不能开 `/dev/pf`、不能改 sysctl）——
  本 fork 的 app 本来就不带沙盒（沙盒留给扩展），兼容。
- **ad-hoc 签名下 `SMAppService`/`SMJobBless` 注册不了**：两者都要 app 与 helper 的签名匹配，
  `SMJobBless` 已 deprecated；社区结论一致（微软 ProcExp for Mac 的发布文档明说
  `SMAppService.register()` 在 ad-hoc 下失败）。
  → **只能走 pkg postinstall**：postinstall 本来就是 root 上下文，
  在那里装 root helper 到 `/Library/PrivilegedHelperTools/` + LaunchDaemon 到 `/Library/LaunchDaemons/`。
  这条路**不需要任何签名凭据**，和现在的分发形态（pkg + ad-hoc）兼容。
  Apple DTS 也说过：已经有 installer 的话，就不必用 SMJobBless。
- **macOS 的透明代理是「rdr + 反查」，不是 Linux 的 tproxy**：
  `rdr` 重定向到本地端口后用 `DIOCNATLOOK` 反查原目的，**只支持 IPv4 TCP**；
  UDP 拦不到（社区做法一致）。macOS 没有 Linux 的 `TPROXY`/divert socket。
  → macOS 上 UDP/QUIC 只能**封 UDP 443 逼回落 TCP**。
- **三端的难度差得很远**：
  - **Windows 最快**：服务已是 LocalSystem（`Windows/src/service/pb_service.c:3,49`），
    WinDivert 已在 **NETWORK 层**抓包（`Windows/src/ProxyBridge.c:1348`）——那层能看见转发的包。
  - **Linux 次之**：特权已就绪（`Linux/src/pb_bpf.c:168` 要求 root，
    unit 已有 `CAP_NET_ADMIN CAP_BPF`），但现有 eBPF 全是 cgroup socket 钩子
    （`Linux/src/bpf/proxybridge.bpf.c:249+`），要补 `tc`/XDP；
    好在 Linux 有 `nftables` tproxy，**UDP 也能真透明代理**。
  - **macOS 最难**：helper + PF + 数据面重做，而且没有 tproxy。
- **规则引擎的硬约束**：别的终端的流量**没有进程身份**，
  点名程序的规则对网关客户端一律跳过（macOS 侧已经是这个语义：
  `LocalProxyUpstream.swift:265` 的 `if rule.hasProgram { continue }`），Windows/Linux 要对齐。
  域名能不能匹配取决于数据面能不能拿到原目的（拿到域名就能按域名分流，只拿到 IP 就不能）。

### 网关模式（只做 macOS）的几条实测事实

> 方案见 [docs/GATEWAY.md](GATEWAY.md)。这里是**查过的事实**，别再查第二遍。

- **macOS 上没有 tproxy**：原目的地址只能靠 `DIOCNATLOOK` 反查，**只支持 IPv4 TCP**。
- **macOS 不公开 `<net/pfvar.h>`**：本机 SDK（`/Applications/Xcode.app/.../MacOSX.sdk/usr/include/net/`）
  里只有 `bpf.h` 和 `pfkeyv2.h`，**没有 `pfvar.h`**；
  `/usr/share/man/man4/` 里也**没有 `pf.4`**（只有 `pflog.4`）。
  → 结构体和 ioctl 号只能**探测**：结构体的大小进了 ioctl 号，
  猜错了内核会用 `ENOTTY` 挡回来，不会读错。实测工具：
  `MacOS/ProxiRoute/tools/gateway-natlook.c`（两种布局都试，端口的两种读法都打印）。
- **重定向规则要挂在 `rdr-anchor` 上**：普通 `anchor` 里的 `rdr` 规则**不会被求值**
  （rdr 规则走的是重定向那条链，地址转换走的是 `nat-anchor` 那条链）。
  这跟直觉相反，是这次写实测脚本时才踩出来的。
- **本机 `/etc/pf.conf` 里没有 `set skip on lo0`**：所以本机自己发的包也会进过滤器，
  「重定向 + 反查原目的」**可以在这台机器上自测**，不必先找第二台机器。
  （Apple 的默认 pf.conf 本来就没有这一句，`set skip on lo0` 是 OpenWrt 那类的写法。）
- **本机的 pf 规则集很简单**：`/etc/pf.anchors/com.apple` 只有 AirDrop 和应用防火墙两个子 anchor；
  深信服留下的 `com.sangfor.*` anchor 文件都是 **0 字节占位**。
  → 在主规则集里挂一个自己的 anchor 是可控的（实测脚本会先存下原规则集再还原）。
- **NAT 可能根本不需要**：TCP 走的是 helper **另开**的连接，不是包的地址转换；
  只有「不代理、直出」的那部分（UDP、ICMP）才需要 NAT。
  → 社区做法里的 `route-to lo0` 也是同一个道理：本方案**不需要**它。
- **实测脚本要 root，而开发环境没有 sudo**（`sudo -n` 回「需要密码」）→
  这一步必须由人在本机跑一次，输出贴回来。

### 本机当代理服务器

- **用 BSD socket 而不是 Network.framework**：`NWListener` 不能绑定到指定地址（EINVAL），
  只有 BSD socket 能做到「绑定本机 IP 或网卡」（`IP_BOUND_IF` / `IPV6_BOUND_IF`）。
- **每连接 1 个线程 + `poll()` 双工中继**，没有 per-connection timer（线程 + timer 是最容易出泄漏的地方）。
- **协议**：SOCKS5（CONNECT + UDP ASSOCIATE）和 HTTP（CONNECT + plain）都支持，可同时开。
- **端口冲突提示**：用 `/usr/sbin/lsof -nP -iTCP:<port> -sTCP:LISTEN -F pc` 查出占用它的程序名，
  报给用户看。
- **不设密码**：局域网场景，界面上写明了。
- **「按规则」的出口只匹配目标主机和端口**——进程过滤规则对网络客户端不适用，
  客户端是别的机器上的程序。

### 路由模式：Global 是兜底，不是覆盖

- **一开始写成了「全局模式打开时规则不参与判断」，这是错的**，改成了
  **规则优先、全局兜底**：规则里写明了程序的仍按规则走，全局代理只接那些没有规则命中的流量。
- **为什么必须这样**：本机的代理服务器（ClashX 的 mihomo）就在这台机器上，
  它自己的流量也会被扩展看见。全局模式覆盖规则时，扩展把代理自己的流量又交回给代理，
  代理再要连接，扩展再交给代理……**这个回环就是整机 100% CPU**，
  而「规则里点名那个代理」正是把它掐断的东西。
- 界面文案同步改了：「没有规则匹配的流量走这个代理。规则里写明了程序的，仍然按规则走。」

### UDP 关联：一个程序一条，不是每条流一条

- **SOCKS5 的 UDP 关联（一条 TCP 控制连接 + 一个 UDP session）本来就能带很多目标**——
  真实目标地址写在每个数据报的 SOCKS5 头里。**之前是每条流建一条关联**，
  而一个「每次查询都开新 socket」的程序（问 DNS 的辅助进程、探端口的程序）
  一分钟能开好几百个 socket——本机实测扩展手上握着 **2442 条 TCP 控制连接 + 412 个 UDP socket**，
  扩展 100% CPU、93 MB 内存。
- **现在改成池化**：**一个程序 + 一个代理 = 一条关联**，下一个 socket 直接加入。
  回包按「谁问的这个目标」送回给那个 socket，所以关联共享了，流量没有混。
- **连带改的三件事**：
  - **流量列表里 UDP 按程序聚合**：一条 socket 一行的话，列表会被上千行内容完全一样的行填满。
  - **UDP 的连接日志按程序限流**，被丢掉的行在一秒末尾汇总成一行说清楚。
    探端口的程序每秒开几百个 socket，**写日志本身是另一半开销**：
    20 秒 14376 行降到 93 行。
  - **UDP 的字节数开始计数**，流量面板能看到了。
- **DNS 应答只在来自 53 端口时才解析**——每个数据报都当 DNS 报文解析是白干活。

### 局域网流量留在本地（这条把 CPU 从 100% 压到 0.5%）

- **全局模式原来把局域网流量也交给了代理**：打印机、共享、路由器的 DNS。
  **网上的代理没法替这里的服务器作答**。
- **本机实测的后果不小**：路由器 DNS（192.168.254.254）**没法**通过前面那个 SOCKS5 代理到达，
  于是**每个自己解析域名的程序**（代理客户端的辅助进程、办公软件、浏览器）
  问了又问、没完没了地重试，**整机都在跑那些哪儿也去不了的流量**：
  扩展 100% CPU，而**搬运流量的 `nehelper` 是 94%**。
- **现在本机和这个网络的地址一律直连**。规则仍然说了算：
  **只有全局兜底才走这条**，规则里点名了程序的，仍然按规则走。
- **UDP 的目标是第一个数据报到了才知道的**，所以是在那里判断，那个数据报直连出去。
- **地址判定是自己写的**（不依赖 Network.framework），所以能脱离网络做单元测试：
  从 `10.0.0.0/8` 到「写在 IPv6 里的 IPv4」都覆盖了（`localaddress_tests.swift`）。
- 开关在路由窗口里，默认开着。

### 本轮验证过的

| 项 | 结果 |
|---|---|
| 扩展 CPU / `nehelper` CPU | **100% + 94% → 0.5% + 0.1%** |
| 扩展常驻内存 | 93 MB → 16 MB |
| 到代理的 TCP 连接数 | 2442 → 18 |
| UDP 往返 | SOCKS5 关联通（8.8.8.8 / 223.5.5.5 有应答），本地 DNS 直连通（192.168.254.254，0.01 s 应答） |
| 本机代理服务器 | SOCKS5 CONNECT / SOCKS5 UDP ASSOCIATE / HTTP CONNECT / HTTP plain 全部实测通过 |
| 入站用户 | mihomo `inboundUser = com.sdpong.proxiroute.extension`，控制器里可见 |
| 逻辑测试 | 23 套全绿（新增「局域网地址判定」） |

### 做这一轮时踩到的两个坑

- **`lsof` 对某些进程看不到 socket**（Clash core、扩展就是这样），
  查端口占用用 `netstat -an | grep <port>` 更可靠。
- **扩展进程 `sample` 不了**（没有 sudo），CPU 的归属只能靠开关对照实验来定位：
  把一个开关关掉再测一次，是唯一可靠的办法。

## 本轮：设置回到窗口里 + 运行模式二选一

这一轮把「设置」从菜单栏搬回窗口，顺带解决一个一直存在的老问题：
**路由模式和本机代理服务器同时开着，机器要付两份开销**。

### 菜单栏之前长什么样

菜单栏上有三个自建菜单：**代理**（代理设置/规则/链/DNS/路由/代理服务器 + 两个开关）、
**设置**（关闭到菜单栏/后台保持/开机启动 + 语言 + 两个系统扩展按钮）、
**Profile**。加上 macOS 自己的编辑/显示/窗口/帮助，一共七项。

问题不是「多」，是**放错了地方**：菜单是做事的入口，设置不是。
「设置」菜单里的语言切换、开机启动这些东西，藏在两层菜单底下，
**没人会为了改一个开关去找它们**。

### 现在：主窗口的第 4 个标签页

新增 **设置** 标签页（就在「活动日志」右边），分七张卡片：

| 卡片 | 内容 |
|---|---|
| 运行模式 | 三选一 + 一句说明 + 两个状态行 |
| 路由 | 全局模式、出口网卡、UDP、局域网直连、DNS 转发 |
| 代理服务器 | 协议、监听地址/网卡/端口、UDP、上游、连接上限 |
| 日志与 DNS | 流量日志开关、DNS 开关 |
| 语言 | 中 / 英文 |
| 应用 | 关闭到菜单栏、后台保持代理、开机启动 |
| 系统扩展 | 去系统设置授权、移除旧扩展 |
| 更多窗口 | 代理设置/规则/链/DNS 设置的入口（表格仍然是独立窗口） |

**路由和代理服务器两个卡片是互斥显示的**：当前不是那个模式，那张卡片根本不出现。
一张 1200×600 的规则表塞进标签页会毁掉体验，所以那四个仍然是独立窗口，
设置页给的是入口。

### 运行模式：路由和代理服务器二选一

这是这一轮真正的技术改动。

**原来的问题**：`RouteSettingsView` 和 `LocalProxyServerView` 是两个独立的窗口，
两个独立的开关（`routeSettings.globalMode` 和 `localProxySettings.enabled`），
**互相不知道对方存在**。两个都开着的时候：

- 扩展接管**本机每一条流量**，逐条判断、逐条走 SOCKS5；
- 本机代理服务器同时**替整个网络的机器转发流量**，每条连接一个线程 + `poll()`。

**两个都是「让这台机器一直干活」的事**，处理器两份开销一起付。
而且这两个窗口摆在一起时，一个写着「路由」，一个写着「代理服务器」，
**没有人能看出它们是互斥的**。

**现在**：一个 **运行模式**，三选一：

| 模式 | 扩展 | 代理服务器 | 本机开销 |
|---|---|---|---|
| 不接管 | 停 | 停 | 零 |
| 路由模式 | 接管本机流量 | 停 | 扩展的开销 |
| 代理服务器 | 停 | 等网络里的客户端 | 服务器的开销 |

实现上有三处要点：

1. **模式是唯一的开关**。`localProxySettings.enabled` 现在由模式推导，
   不再是第二个能自己说话的东西——**两个开关管一件事，迟早会打架**。
2. **模式在干活之前就写下来**。中途被杀，下次启动读到的是「最后要求的模式」，
   而不是「做了一半的模式」。
3. **DNS 代理跟着模式走**。DNS 代理是用来教扩展「哪个名字对应哪个地址」的，
   它属于本机流量；不接管本机流量时它没有事可做，
   而且 macOS 只有一个 DNS 代理位置，**空着给别人比占着强**。

**老用户不受影响**：模式是新的，旧的设置（代理服务器开/关）正好能推出它——
服务器开着就是「代理服务器」模式，否则是「路由模式」。迁移写在
`RuntimeModeStore.modeBeforeModesExisted` 里，有单元测试。

### 菜单栏：编辑菜单审核的结论

**「编辑」菜单不能整删。** 删掉它，**日志窗口就 ⌘C 不动了**——
`LogTextView` 是 `NSTextView`，拷贝走的是 responder chain 里的 `copy:`，
而**那个动作是菜单项带过去的**（⌘C 的键位来源就是菜单）。
一个代理软件的主窗口不能复制日志，是不能接受的。

**但可以裁**。macOS 26 往编辑菜单里塞了一排跟编辑无关的东西：
自动填充、通讯录、密码、信用卡、开始听写、表情与符号。
一个显示日志的代理软件，这些一个都用不上，而且是**打开菜单第一眼看到的东西**。

裁掉之后（实测菜单内容）：

```
撤销 | 重做 |  | 剪切 | 拷贝 | 粘贴 | 删除 | 全选
```

**这里踩了一个坑**：一开始用 SwiftUI 的 `CommandGroup(replacing: .textEditing)`
自己补了一套编辑命令，结果**菜单里出现了两套**（SwiftUI 的一套 + 系统自动加的一套）。
教训是：**macOS 26 的编辑菜单是系统自己加的，跟 SwiftUI 怎么写无关**——
所以正确做法是**不动它**，只在 AppKit 层把那六个噪音项删掉。

### 显示菜单和窗口菜单合并

「显示」菜单里的东西（侧边栏、工具栏、标签页平铺）对本 app 一个都用不上，
**唯一有用的是「进入全屏」**。所以整个菜单删掉，全屏搬进「窗口」菜单，
**窗口的事只有一个菜单**。

「窗口」菜单现在是：

```
打开 ProxiRoute | 进入全屏 |  | 最小化 | 缩放 |  | 代理设置 | 代理规则 | 路由 | 代理服务器 | 关于 ProxiRoute | 检查更新 |  | 前置全部窗口
```

「打开 ProxiRoute」和「进入全屏」是加在最前面的——SwiftUI 自己生成的那个
窗口菜单**只列窗口**，不列「怎么把窗口叫回来」。

### 顺带修的一个 bug：菜单改名跟不上语言切换

「语言」切换后，**SwiftUI 画的菜单**（Profile）立刻变成中文，
**macOS 画的菜单**（编辑/窗口/帮助）却还是英文。

原因：SwiftUI 重建菜单栏时**换掉了整个 `NSApp.mainMenu` 对象**，
而重命名是靠 `NSMenu.didChangeItemNotification` 触发的——
**换掉整个菜单栏不是「某个条目变了」，那条通知根本不来**。
旧代码里只有 `didChangeItemNotification` 和 `didBecomeActive` 两个观察者，
所以改名就漏掉了。

现在**菜单栏本身被 KVO 盯着**（`NSApp.observe(\.mainMenu, ...)`），
它一被换掉就重新改名。

### 本轮验证过的

| 项 | 结果 |
|---|---|
| 菜单栏 | `ProxiRoute \| 编辑 \| 配置 \| 窗口 \| 帮助`（代理/设置/显示三个菜单都没有） |
| 编辑菜单 | `撤销 \| 重做 \| \| 剪切 \| 拷贝 \| 粘贴 \| 删除 \| 全选`，macOS 26 噪音项全无、**且只有一套** |
| 窗口菜单 | 顶部有「打开 ProxiRoute」「进入全屏」 |
| 设置页 | 8 张卡片全部渲染正常（语言切换即时生效，实测中/英文互切） |
| 运行模式互斥 | 切到「代理服务器」后：本机流量变「未接管」、代理服务器变「运行中」、18888 开始监听；切回「路由模式」后反过来 |
| 扩展 CPU / 内存 | 0.2% / 5.5 MB（路由模式下，与上一轮同量级） |
| 逻辑测试 | 24 套全绿（新增「运行模式互斥 + 老设置迁移」） |

### 做这一轮时踩到的坑

- **`NSApp.mainMenu` 被换掉时没有任何通知**。AppKit 只说「某个条目变了」，
  换整个菜单栏它不管。要盯住的是菜单栏这个对象本身（KVO）。
- **macOS 26 的编辑菜单是系统加的**。SwiftUI `replacing:` 掉它，
  系统那套照样在——自己再补一套就变成两套了。
- **两个窗口摆在一起，看不出它们互斥**。互斥这件事**必须在同一个地方说清楚**，
  否则就是两个各自为政的开关。

## 本轮：菜单栏再瘦身 + 设置页去重 + 代理服务器自己数流量

### 1. 「编辑」菜单删掉了，⌘C/⌘V/⌘A/⌘Z 还在

用户问「edit 为什么还在」。上一轮的结论是「不能整删，删了日志就复制不了」——
**这个结论只对了一半**。

菜单项从来不是那条命令本身，命令是**第一响应者**回答的：
日志窗口里的 `NSTextView`、输入框的 `NSTextView`。菜单项只是找到它的**一条路**。
所以现在改成：菜单项拿掉，**用 `NSEvent.addLocalMonitorForEvents` 盯住编辑快捷键**，
直接把命令发给第一响应者（`copy:` / `cut:` / `paste:` / `selectAll:` / `undo:` / `redo:`）。

实测（本机，菜单里已经没有任何编辑项）：

```
⌘A → 日志全选（selectedRanges = {0, 18}）
⌘C → 剪贴板拿到 "hello from the log"
```

> 注意：`NSApp.sendAction(_:to:nil)` 走的是**响应链**，从 **key window 的第一响应者**开始。
> 如果 app 不是 key app，`NSApp.keyWindow` 是 nil，命令就没人接。
> 所以代码里显式取 `NSApp.keyWindow?.firstResponder ?? AppDelegate.mainWindow?.firstResponder`。

### 2. 窗口菜单里 macOS 26 的灰色项拿掉了

这些项**永远是灰的**：它们管的是**标签页**和**窗口组**，而本 app 只有一个窗口、
没有标签栏。灰色项 = 永远不会兑现的承诺。

实测本机 macOS 26 的真实标题（**第一版猜的中文标题全错**，所以按实测改）：

| 英文 | macOS 实际用的中文 | 处理 |
|---|---|---|
| Remove Window from Set | 从组中移除窗口 | 拿掉 |
| Show Previous Tab | 显示上一个标签页 | 拿掉 |
| Show Next Tab | 显示下一个标签页 | 拿掉 |
| Move Tab to New Window | 将标签页移到新窗口 | 拿掉 |
| Merge All Windows | 合并所有窗口 | 拿掉 |

拿掉之后会把**多出来的分隔线**收掉（连续两条分隔线、或结尾的分隔线）。

### 3. 窗口菜单里的系统项全部中文化

macOS 26 会往窗口菜单里塞自己的项：关闭 / 全部关闭 / 最小化 / 全部最小化 / 缩放 /
全部缩放 / 填充 / 居中 / 移动与调整大小 / 全屏幕平铺。

本 app 没有资源包，系统没有东西可以翻译它们，于是**在系统语言是中文时它们是中文，
在 app 语言是英文时它们是英文**。现在两种语言的标题都登记了，改名时统一换成 app 选的语言。

### 4. 「显示」菜单老跑回来

SwiftUI **每次窗口变成 key 窗口都会重建菜单栏**，把「显示」放回去。
而 `NSMenu.didChangeItemNotification` 是**同步**回调的——我们的删除动作发生在
SwiftUI 重建**进行到一半**的时候：编辑菜单（在前）被拿掉了，显示菜单（在后）留下了。

改法：通知回调里 `DispatchQueue.main.async { apply() }`——等这一轮 runloop 结束再改名。
再加一个 2 秒的兜底看门狗（只在 app 在前台时跑）。

### 5. 设置页：标题不说两遍，长文本不越界

- 8 张卡片里有 6 张的 **Form Section header 和卡片标题重复**（运行模式 / 日志与 DNS /
  语言 / 应用程序 / 系统扩展 / 更多窗口）——重复的拿掉；
  「监听位置」「出口」「上限」这种**不重复**的分段标题保留。
- 长文本（DNS 说明、路由说明…）之前**跑出卡片右边界**：给它们
  `.fixedSize(horizontal: false, vertical: true)`，Form 和卡片都 `.frame(maxWidth: .infinity)`。

### 6. 标签栏最右端加了一个常驻状态

`统计 | 活动连接 | 活动日志 | 设置` 之后加了一行状态：
`🟢 代理服务器 · 运行中 · 客户端: 0`（路由模式下是 `🟢 路由模式 · 已接管`）。

### 7. 统计 / 活动连接在代理服务器模式下不再是空的（**这才是空白的真正原因**）

用户截图里两张表都是空的。查下来**不是 bug，是模式**：

- 统计和活动连接的数字**全部来自系统扩展**（扩展写统一日志，app 读回来）；
- 而**代理服务器模式下扩展是停着的**（路由模式和代理服务器互斥）→ 所以永远是空的。

修法：**代理服务器自己数流量**。每个客户端连接开一个 flow，双向计字节，
结束时计入所走代理的总量；代理名沿用扩展的那一套（`Direct` / 代理名 / `BLOCK`），
所以两种模式下表格长得一样。客户端在网络上**没有程序名**，所以表里写它的地址。

实测（代理服务器模式下过一条流量）：

```
统计：    Direct | 1 连接 | 已发送 74 字节 | 已接收 933 字节 | 合计 1 KB
活动连接：127.0.0.1 | 2606:4700:7:0:0:0:da:443 | TCP | Direct | 520 字节 | 8.7 MB | 0:00
```

（`::ffff:127.0.0.1` 这种 IPv4-mapped 地址已经还原成 `127.0.0.1`。）

### 本轮验证过的

| 项 | 结果 |
|---|---|
| 菜单栏 | `ProxiRoute \| 配置 \| 窗口 \| 帮助`（编辑菜单没了；**「显示菜单不再回流」这一条当时是错的**，真相见下一节） |
| 窗口菜单 | 全中文：打开 ProxiRoute / 进入全屏 / 关闭 / 最小化 / 缩放 / 填充 / 居中 / 移动与调整大小 / 全屏幕平铺…，**灰色标签页项全无** |
| 编辑能力 | ⌘A 全选、⌘C 复制（**用独立小程序验证过机制**：没有编辑菜单时第一响应者照常响应） |
| 设置页 | 6 张卡片去掉重复标题；长文本全部在卡片内换行 |
| 标签栏右侧 | `代理服务器 · 运行中 · 客户端: 0` |
| 统计 / 活动连接 | 代理服务器模式下有数据（见上） |
| 逻辑测试 | 24 套全绿（`localproxy_tests` 新增流量计数断言） |
| Release 构建 | BUILD SUCCEEDED（arm64+x86_64），ad-hoc 签名，已装到 `/Applications` |

### 做这一轮时踩到的坑

- **macOS 26 的灰色项中文标题和我想的不一样**。「从组中移除窗口」不是我以为的
  「从窗口组中移除窗口」——**按实测标题来剪**，中英文两套都要登记。
- **`NSMenu.didChangeItemNotification` 是同步回调**。在 SwiftUI 重建菜单栏的过程中
  同步动它，会动到「前面的」而留下「后面的」。必须 `DispatchQueue.main.async`。
- **键盘事件在本机走中文输入法**，用 `osascript keystroke` 发的 ⌘ 组合键会被输入法吃掉，
  自动化验证不了 ⌘C。改用**独立小程序**验证机制（同样的 monitor + sendAction 写法），
  结论可靠且可复现。

## 补：显示菜单的真相（SwiftUI 会把菜单栏再建一遍）

上一节里「显示菜单不再回流」这句话是**错的**。日志里写着
`the menu bar: ProxiRoute | 配置 | 窗口 | 帮助`，看着是干净的，**屏幕上却一直有「显示」**。

查下来的原因是这样：

1. SwiftUI **盯着菜单栏**。菜单栏一变，它就把菜单栏**重建一遍**，重建出来的菜单栏里
   **带着它的「显示」菜单**。
2. 我们把「显示」这个菜单项 `removeItem(at:)` 删掉 —— 这本身**就是一次菜单栏变化**，
   于是 SwiftUI 把它加回来。
3. 于是变成一个循环：我们删 → SwiftUI 加 → 我们再删 → ……**菜单栏每两秒抖一次**，
   而屏幕上的「显示」绝大多数时间是**在的**。

**关键证据**（诊断日志 + 屏幕截图对照）：

| 做法 | 屏幕上的菜单栏 |
|---|---|
| 不删「显示」 | `ProxiRoute \| 显示 \| 配置 \| 窗口 \| 帮助`（它自己不消失） |
| `removeItem(at:)` 删掉 | 删掉后 0.15 秒又被加回来，来回抖 |
| `item.isHidden = true` | **`ProxiRoute \| 配置 \| 窗口 \| 帮助`，干干净净** |

**结论：隐藏（`isHidden`）而不是删除（`removeItem`）**。
隐藏一个菜单项**不算菜单栏的变化**，SwiftUI 不会因此重建菜单栏，所以它不会回来。

编辑菜单同理——它以前也是用 `removeItem` 删的，改成隐藏。

顺带两件事：

- 「显示」菜单里的命令（工具栏/边栏的那些）也一并**清空**
  （`CommandGroup(replacing: .toolbar) { }` / `.sidebar` { }`），
  这样万一隐藏哪天失灵，露出来的也是一个空菜单，而不是一堆跟这个 app 无关的东西。
- `NSMenu.autosignalsDisabled` 是 AppKit 的**私有 API**，Swift 里根本调不到
  （`type 'NSMenu' has no member 'autosignalsDisabled'`），所以这条路走不通。

**教训**：改菜单栏之前，先想清楚「这次改动会不会被 SwiftUI 当成菜单栏变了」。
会被它当成的，就别去动结构，去动显示。

## 本轮：设置页里重复的两行搬走 + 空表格说明原因

### 用户看到的现象

运行模式卡片里，分段控件（不接管 / 路由模式 / 代理服务器）下面有两行：
**本机流量 → 已接管/未接管**、**代理服务器 → 运行中/未运行**。
切到哪个模式下，这两行都不变 —— **每个选项下面都是同样的东西**。

要求是：把它们放到**统计、活动连接、活动日志、设置之后**（标签栏最右端）。

### 怎么做的

标签栏最右端本来就有放状态的地方（上一轮放的是「运行模式 · 已接管」这类摘要）。
现在改成放这两行本身：

```
● 本机流量 未接管    🟢 代理服务器 运行中 客户端：0
```

卡片里只留分段控件和模式说明。

**为什么不留「模式名」**：这两个状态已经说明了模式 —— 两者互斥，最多只有一个是绿的。
再写一遍模式名就是第三份重复（模式名 + 两个状态，代理服务器模式下会出现
「代理服务器 · 代理服务器」）。

### 顺带修掉的两个毛病

- **卡片里那条空的坏行**：`Divider()` 放在 grouped `Form` 里会自己占一行，
  屏幕上就是一段没有内容的空白。卡片里不需要它，去掉。
- **空表格不解释为什么空**：不接管模式下扩展整个停掉，本机流量根本没被接管，
  所以「活动连接」是空的。空状态却写着「被代理的连接会显示在这里」，
  读起来像坏了。现在每个模式都说明自己为什么空。
  **顺带回答一个常见误会**：这跟 DNS 代理开关没关系 —— 不接管模式下
  DNS 代理也跟着停（`isDNSEnabled && runtimeMode.takesOverLocalTraffic`），
  但那是**结果**不是原因。

### 「启用 DNS」开关原来会骗人

DNS 代理服务于本机流量，**只在路由模式下运行**。可是开关一直显示「开」，
在不接管/代理服务器模式下它其实是关的。现在设置页明说它现在是关的，
日志里那句「在「代理」菜单中启用 DNS」也改了 —— 那个菜单上一轮就没了。

### 验证

| 项 | 结果 |
|---|---|
| 不接管模式标签栏右端 | `● 本机流量 未接管  ● 代理服务器 未运行` |
| 代理服务器模式标签栏右端 | `● 本机流量 未接管  🟢 代理服务器 运行中 客户端：0` |
| 统计页空状态（不接管） | 本机没有被接管 / 没有接管任何流量，所以这里没有统计…… |
| 活动连接空状态（不接管） | 本机没有被接管 / 扩展已停止，本机的连接不会被代理…… |
| 运行模式卡片 | 只剩分段控件 + 说明；那条空的坏行没有了 |
| DNS 说明 | 按模式出现（不接管/代理服务器模式下说明它是关的） |
| 逻辑测试 | 24 套全绿（`l10n_tests` 抓到了新词条） |

## 本轮：四张卡片搬去「选项」页 + 模式改名（本地 / 网关）

### 先认错：上一轮把「重复的项」认错了

用户说的「每个页面设置详情时均出现相同的项」指的是**四张与运行模式无关的卡片**：
语言、应用程序、系统扩展、更多窗口 —— 这四张在任何模式下都一样，和模式无关。

我上一轮（stage22）却把**分段控件下面那两行**（本机流量 / 代理服务器）搬去了标签栏，
理由是「它们在每个选项下面都一样」。**这是错的**，代码核对下来它们是随模式变化的：

| 模式 | 本机流量 | 代理服务器 |
|---|---|---|
| 本地 | 未接管 | 未运行 |
| 网关（原来的路由模式） | 已接管 | 未运行 |
| 代理服务器 | 未接管 | 运行中 |

所以这一轮：**两行状态搬回运行模式卡片**（它们本来就属于它），
**四张卡片搬去新的标签页「选项」**。stage22 那个方向是误读，不做回滚而是改正。

### 这一版的样子

标签栏：`统计 ｜ 活动连接 ｜ 活动日志 ｜ 设置 ｜ 选项`

- **设置**：运行模式（分段控件 + 模式说明 + 两行状态）、路由设置（仅网关模式显示）、
  代理服务器（仅代理服务器模式显示）、日志与 DNS
- **选项**：语言、应用程序、系统扩展、**规则设定**

「更多窗口」改名「规则设定」：原来的名字说的是东西**在哪**（窗口），
不是东西**是什么**（规则）。窗口只是通往规则的路。

卡片代码抽成了共享组件（`MacOS/ProxiRoute/ProxiRoute/SettingsCard.swift`），
两个页面用的是同一份 `SettingsCard` / `SettingsCardFooter`。

### 模式改名：不接管 → 本地，路由模式 → 网关

- **不接管 → 本地**：旧名字听起来像「什么都不做」，其实它是「本机流量照旧走」，
  是一种明确的选择。新名字说的是**范围**（本机），不是**否定**。
- **路由模式 → 网关**：这个名字是用户给的初心 —— 这台机器要当网络里其他终端的网关。

### 「网关」的实话（这一段不能省）

macOS 侧到现在**只接管本机流量**（`NEFilterDataProvider`），
**其他终端把流量交给这台 Mac 的真正转发并没有实现**（TUN 栈 / IP 转发在 app 内做不出来）。
所以网关模式的卡片上写了两行：

- 说明行：它**是**网络里其他终端的网关，流量从这里过
- 橙色行：目前只有本机的流量被接管，其他终端的转发还没有实现

不写橙色行就是在界面上编造一个还没做的功能。名字是计划，橙色行是进度。

### 顺便回答：「本地模式没有活动连接，是 DNS 代理被关的原因吗？」

**不是。**

- 本地模式下扩展**整个停掉**（不只是不接管流量），DNS 代理是本机流量的一部分，
  它跟着停 —— `isDNSEnabled && runtimeMode.takesOverLocalTraffic`
  （`ProxiRouteViewModel.swift` 的 `applyDNSProxy`）。
- 但那是**结果**不是原因：本机流量根本没被接管，所以没有任何连接会产生。
- 界面现在把这件事说清楚：
  - 活动连接空状态：`扩展已停止，本机的连接不会被代理，DNS 代理也跟着停了。`
  - 设置页橙色行：`DNS 代理服务于本机流量，只在「网关」模式下运行。现在它是关的…`
- 标签栏右端也回到「模式 · 状态」的摘要（`网关 · 已接管`），
  不再是两行状态 —— 状态属于模式，就待在模式卡片里。

### 顺带解开的一处绑定：DNS 代理不再跟着模式走

用户在设置页截图上问：**「本地模式 dns 也是要打开的……没增加路由（现网关）和代理服务器模式前
应该也是开的，可以读历史确认，所以这行字还要么？」**

历史确认如下（`git log -S"takesOverLocalTraffic"`）：

| 提交 | `applyDNSProxy()` 里的判断 |
|---|---|
| `7868ca9`（加运行模式那次）之前 | `let enable = isDNSEnabled` —— **与模式无关** |
| `7868ca9` 之后 | `let enable = isDNSEnabled && runtimeMode.takesOverLocalTraffic` |

也就是说：**在加运行模式之前，DNS 代理一直开着**，开关说了算。
把它绑到模式上是加模式时顺手做的（当时的理由是「不接管流量时它没事干，
不如把 macOS 唯一的 DNS 代理位置让给别人」），并不是 DNS 代理本身需要隧道。

**但 DNS 代理是独立的 provider（`NEDNSProxyProvider`），不是隧道的一部分**：
它回答系统的 DNS 查询并记下「哪个名字对应哪个地址」，这套映射在隧道真正跑起来的那一刻就要用，
代理服务器也要用它。所以：

- `applyDNSProxy()` 回到 `let enable = isDNSEnabled`，**模式不再决定它**；
- 设置页里那句橙色说明（「只在「网关」模式下运行。现在它是关的…」）**删掉** ——
  它和上面的开关自相矛盾（开关说「开」，橙字说「现在是关的」）；
- 活动连接空状态里那句「DNS 代理也跟着停了」也删掉；
- DNS 条目的看护定时器跟着**开关**走，不再跟着隧道走（隧道不跑时 macOS 也会把条目关掉）。

结果：**本地模式下 DNS 代理照旧开着**，开关说什么就是什么，不再说谎。

### 模式语义改了：三种模式都接管本机流量

用户指出：**「三种模式，均需接管本地流量……三种模式除第一个本地外，其他为增加的为其它终端提供的服务。」**

之前的语义是「三选一」：不接管（扩展整个停）/ 路由模式（接管本机）/ 代理服务器（服务器开着，本机不管）。
这跟 Proxifier 的模型不一样 —— Proxifier 一直是接管本机的流量，网关和代理服务器是在这之上**另外**提供的服务。

现在的语义：

| 模式 | 本机流量 | 给其他终端的服务 |
|---|---|---|
| **本地** | 接管 | 无 |
| **网关** | 接管 | 网关：其他终端的流量从这台机器过 —— **转发还没实现** |
| **代理服务器** | 接管 | 代理服务器：网络里的客户端连上来 |

代码上：

- `RuntimeMode.takesOverLocalTraffic` 变成**恒为 true**，另加 `RuntimeMode.runsGateway`；
- 枚举改名：`.off` → `.local`，`.route` → `.gateway`；旧的存储值 `off` / `route`
  会被读成新模式，**升级不丢设置**（`RuntimeModeStore.load`）；
- `applyRuntimeMode()` 不再停隧道：隧道一直跑，模式只决定代理服务器开不开；
- 「代理服务器」模式现在是**隧道和服务器同时跑**。这不会成环：扩展不接管自己的流量
  （`AppProxyProvider` 里按 bundle id 放行 `com.sdpong.ProxiRoute`），所以代理服务器的出站连接
  不会被自己的隧道再抓一遍。

界面跟着改：

- 运行模式卡片里**「本机流量 接管/未接管」那一行删掉** —— 三种模式都是接管，
  每个选项下面都一样的行没有意义。接管状态由标签栏右端那一行说（`● 本地 · 已接管`）；
- 「代理服务器 运行中/未运行」那行保留：它是唯一一个只有一种模式是开的状态；
- **路由卡片只在网关模式下出现**：它是网关这个服务的设置（全局模式、出口网卡、UDP、局域网直连）。
  本地模式和代理服务器模式**用默认参数**，也就是加这两个模式之前的做法 —— 想要给其他终端做路由
  的时候切到网关模式，其他时候保持原样；
- 空表格的说法改了：不再是「扩展停了所以没有连接」，而是「还没有流量经过」。

### 验证

| 项 | 结果 |
|---|---|
| 标签栏 | 统计 / 活动连接 / 活动日志 / 设置 / **选项** |
| 设置页 | 运行模式（分段控件 + 说明 + **两行状态**）+ 路由或代理服务器 + 日志与 DNS |
| 选项页 | 语言 / 应用程序 / 系统扩展 / **规则设定** |
| 分段控件 | **本地 / 网关 / 代理服务器** |
| 本地模式 | 隧道在跑（`● 本地 · 已接管`），**没有路由卡片**（用默认参数），只有「代理服务器 未运行」一行 |
| 网关模式 | 隧道在跑 + 路由卡片 + 橙色「转发还没实现」 |
| 代理服务器模式 | 隧道和服务器同时跑 |
| 标签栏右端 | `● 本地 · 已接管` / `● 网关 · 已接管` / `● 代理服务器 · 运行中` |
| 活动连接（本地模式实测） | `Vivaldi Helper · ab.chatgpt.com:443 · TCP · SOCKS5 127.0.0.1:9991` |
| 活动连接空状态（本地） | `扩展已停止，本机的连接不会被代理。切到「网关」才会在这里看到连接。` |
| 本地模式的 DNS | 日志写「DNS 代理已启用」（没有隧道也开着） |
| 设置页的橙字 | 删掉了，开关说什么就是什么 |
| 菜单栏 | `Apple, ProxiRoute, 配置, 窗口, 帮助`（没被这轮改动影响） |
| 逻辑测试 | 21 套全绿（`l10n_tests` 抓到了漏译与失效词条） |

## 本轮：网关模式可行性实测，第一次跑砸了，教训三条

网关模式只做 macOS（用户拍板），所以第一件事是验掉一个致命前提：
**别的终端的流量被 PF `rdr` 重定向到本机后，helper 能不能读回原目的地址**
（macOS 没有 tproxy，原目的只能靠 `DIOCNATLOOK` 反查，而 SDK 里没有 `<net/pfvar.h>`）。

实测工具：`MacOS/ProxiRoute/tools/gateway-spike.sh` + `gateway-natlook.c`
（放 `tools/` 不放 `scripts/`：`build.sh` 是 `pkgbuild --scripts scripts`，
会把整个 `scripts/` 目录打进安装包）。

### 第一次跑的失败，和它教出来的三件事

第一次跑的结果：清理逻辑全对（原规则集还原、过滤器关回去、转发开关回 0），
但**规则根本没装上**：

```
main.rules:6/8: Rules must be in order: options, normalization, queueing, translation, filtering
pfctl: Syntax error in config file: pf rules not loaded
```

而且那个 FAIL 是**误导性的** —— helper 只打印了 `listening on 127.0.0.1:18081`，
连接根本没到它手里，机制本身压根没被测到。

**教训一：translation 段的规则不能追加到文件末尾。**
PF 的段序是 `options → normalization → queueing → translation → filtering`，
过滤段的 `anchor` 一出现，后面再出现 translation 的规则就被拒。
实测规则必须插到**第一条 `anchor` 之前**。

**教训二：还原要以 `/etc/pf.conf` 为基准，不能用 `pfctl -sr`。**
`pfctl -sr` 只打印过滤段的规则，翻译段（`nat`/`rdr`）的 anchor 不在里面，
拿它还原会把系统自己的翻译钩子（`com.apple/*`）弄丢。

**教训三：`pfctl -n -f` 只解析、不动过滤器，而且不需要 root。**
这是个好东西：装规则之前先用 `-n` 读一遍，文件被拒就在**机器还没被动过**之前停下；
顺带让人能不加 sudo 先看规则长什么样（脚本的 `--dry-run`）。

### 顺带查清的几件事

| 事实 | 怎么查的 | 为什么重要 |
|---|---|---|
| `no rdr` 后面**不能跟 `pass`** | `pfctl -n -f` 试出来的：`"pass" not valid with "no"` | 写错就是一条废规则 |
| macOS 自动分配端口从 **49152** 起 | `sysctl net.inet.ip.portrange.first` | helper 自己绕开重定向要用的源端口段必须低于它，否则会跟别的程序撞 |
| 没有状态可查时，内核对**三种布局一律回 `ENXIO`**，不会用 `ENOTTY` 挡回错布局 | 空跑 helper，三种 ioctl 全是 errno 6 | **不能靠报错挑布局**，实现上必须按值（地址+端口）判断；实测工具因此扫描内核返回的**每一行** |
| 内核写回的结构体是它自己那个尺寸 | 由上一条推出 | 所有探测共用一个大缓冲区，否则可能写越界 |
| 「重定向规则要挂 `rdr-anchor`」这条**查不到出处**，两种挂法都可能被求值、也可能都不 | `pfctl -n -f` 两种写法都能过语法预检，但**语法过不等于会被求值** | 实测脚本把规则**写两遍**（直挂翻译段 + 挂自己的 anchor），认哪种都能工作；阶段 2 的 helper 照做 |

### 现在的状态

实测脚本已重写并自测过（`--dry-run` 两种模式的规则都过了 pfctl 预检，
判定逻辑用伪造的内核返回验过四种情形：答对 / 只答回重定向目标 / 答不出来 / 客户端流量）。
**但真正的结论还是要你跑一次 sudo**：这个环境没有免密 sudo，AI 无法自证。

```bash
cd /Volumes/mydata/Downloads/ProxyBridge-src/MacOS/ProxiRoute/tools
./gateway-spike.sh --dry-run          # 不用 root，先看规则
sudo ./gateway-spike.sh                # 本机自测
sudo ./gateway-spike.sh --forward      # 再加：等另一台机器连过来
```

## 本轮：规则引擎拆成自己的文件，四件事定死

网关模式阶段 1 的东西。规则引擎原来长在 `LocalProxyUpstream.swift` 里，
是「代理服务器模式」自己的一份简版：跳过点名程序的规则、其余按主机和端口匹配。
网关模式要用的是同一套规则，所以它被拆成 `ProxiRoute/ProxyRuleEngine.swift`，
**不依赖 app 的任何东西** —— 网关模式的 helper 以后要读同一份文件，
app 和 helper 读法不一样的规则，等于一条规则有两个意思。

四件事在这里定死（都有测试）：

1. **点名程序的规则一律跳过**（原来就有，保留）。
2. **协议维度开始算数**。原来规则的 `protocol` 解析出来就扔了（死字段），
   标了「UDP」的规则照样拦 TCP。现在规则带 `TCP` / `UDP` / `BOTH`，
   只对上协议的规则才算数。
3. **chain 的行为定死**。原来规则的动作是 `chain:<id>` 时，
   引擎去找一个 id 叫 `chain:<id>` 的代理，找不到 → **静默直连**：
   用户以为走了链，其实没有。现在：TCP 把链逐跳走完；UDP 走直连（并写明原因）；
   链是空的 / 有代理不在列表里 / 中间夹了个 http 代理 → 走直连**并写明原因**。
   代理服务器模式因此也学会了走链（一个代理问下一个代理要下一个）。
4. **域名来源定死**。流量带「名字」和「地址」两样：规则按名字比，
   名字不知道的时候按地址比。网关模式默认只知道地址（SOCKS 客户端才会送名字），
   DNS 劫持是阶段 4 的事。

顺带修掉一个自己改出来的 bug：搬 `parse(url:)` 的时候把 `rest[range.upperBound...]`
写成了 `rest[rest.index(after: range.upperBound)...]`，**吞掉了主机名的第一个字母**
（`example.com` 变成 `xample.com`）。逻辑测试当场抓到 3 处失败 ——
这也是为什么搬代码要逐段和原文 diff 一遍。

## 本轮：实测跑通了，重定向成立，原目的没读回来

**最重要的结论：透明代理的数据面在这台机器上可行。**

实测输出里的三行：

```
the client got 415 bytes
accepted from 127.0.0.1:52807 to 127.0.0.1:18081
```

- `accepted from … to 127.0.0.1:18081`：**PF 的 `rdr` 真的把连接重定向到了 helper**，
  也就是说「别的终端的流量 → PF 重定向 → 本机端口 → 问原目的 → 另开连接出去 →
  双向倒」这条路的前半段是通的（阶段 3 的形状成立）；
- `the client got 415 bytes`：helper 回的字节**带着原目的**回到了客户端
  （PF 的反向翻译是对的），curl 正常收到页面。

### 没读回来的那半段，和它的三条线索

```
NATLOOK layout=old was refused: Device not configured (errno 6)
NATLOOK layout=older was refused: Device not configured (errno 6)
NATLOOK layout=new was refused: Device not configured (errno 6)

ALL tcp 127.0.0.1:18081 <- 127.0.0.1:52807
```

1. 三种布局**一律** `ENXIO`（errno 6）：这个错误**不是**「布局不对」——
   上一次没有状态可查时也是这个错误。`ENXIO` 更像是「按这个键没找到状态」。
2. 我们查的键是「对端地址 + socket 本地地址（也就是重定向目标 18081）」。
   而状态表里那一行显示的是 **18081**，**没有 18080**：
   状态是按**重定向后**的元组存的，原目的不在这行里。
   → 所以「读状态表当兜底」这条路按原来的写法也不通，
   要看翻译详情得用 **`pfctl -ss -o nat`**。
3. 反过来想：**状态是按重定向后的元组存的，那我们的键就该是对的**，
   除非 —— **端口的字节序不对**。pf 的状态表里端口是主机序，
   而我们塞进去的是 `sin_port`（网络序）。地址同理：
   `127.0.0.1` 在网络序和主机序下是两个不同的数。

### 下一轮实测改成穷举

与其猜，不如一次问完。现在每条连接会试 **384** 种问法：

| 维度 | 取值 |
|---|---|
| 布局 | old / older / new |
| 两端谁在前 | 对端在前 / 本地在前 |
| 端口字节序 | 网络序 / 主机序 |
| **地址字节序** | 网络序 / 主机序 |
| protocol 字段 | 6（IPPROTO_TCP）/ 2（PF_INET） |
| direction | PF_IN / PF_OUT |
| 查的目的地 | socket 本地地址 / **已知的原目的** |

最后一个维度是专门为了验证「状态是按原目的存的」这个假设 ——
测试本来就知道自己把连接发去了哪里（127.0.0.1:18080）。

同时脚本会打�� `pfctl -ss -o nat`：**如果翻译详情里能看到 18080，
那「读状态表」这条兜底路就是通的**，helper 作为 root 读得到它。

## 本轮：ioctl 的三件事查清了 —— 设备、结构体、方向

第二次实测（384 种问法全灭）之后，做了两件事：写了一个**不需要 root 的 ioctl 扫描器**，
和查 Apple 自己的内核源码。答案就写在那里。

### 一、ioctl 发在 `/dev/pf` 上，不是发在 socket 上

扫描器在 socket 上试了 `'D'` 组 0–63 号 × 5 种尺寸共 320 个 ioctl，
**没有一个与「不存在的 ioctl」行为不同**（全是 `ENXIO`）。
也就是说：socket 根本不认识 pf 的 ioctl。

Apple 的 `pf_io.c` 里 `DIOCNATLOOK` 是 **`/dev/pf` 设备的 ioctl**。
`/dev/pf` 是 `crw------- root wheel` → **要 root**。
（FreeBSD 后来才改成发在 socket 上，OpenBSD/Apple 这一支不是。）

### 二、结构体不是 BSD 的那个

Apple 的 `bsd/net/pfvar.h`（XNU 公开源码）里的定义：

```c
struct pf_addr {            /* 128 位！BSD 的是 32 位 */
	union { struct in_addr v4addr; struct in6_addr v6addr;
	        uint8_t addr8[16]; uint16_t addr16[8]; uint32_t addr32[4]; } pfa;
};
union pf_state_xport { uint16_t port; uint16_t call_id; uint32_t spi; };

struct pfioc_natlook {
	struct pf_addr saddr, daddr, rsaddr, rdaddr;   /* 4 × 16 字节 */
	union pf_state_xport sxport, dxport, rsxport, rdxport;
	sa_family_t af;            /* macOS 上 sa_family_t 是 1 字节 */
	uint8_t proto;
	uint8_t proto_variant;     /* Apple 自己加的 */
	uint8_t direction;
};
#define DIOCNATLOOK _IOWR('D', 23, struct pfioc_natlook)
```

**`sizeof` = 84 字节**（地址 64 + 端口 16 + af/proto/proto_variant/direction 4）。
大小进了 ioctl 号，所以用 BSD 的布局去问，问的是**另一个 ioctl**，内核当然不理。
（`sa_family_t` 在 macOS 是 `unsigned char` —— 差一个字节就不是同一个 ioctl 了。）

### 三、方向要用 `PF_OUT`，答案在 `rdaddr`/`rdxport`

内核的处理器（`pf_io.c`）：

```c
if (direction == PF_IN) {
	key.ext = daddr/dxport;  key.gwy = saddr/sxport;
	state = pf_find_state_all(&key, PF_IN, &m);
	/* 答案：rsaddr = sk->lan.addr，rdaddr = 原样返回我们给的 daddr */
} else {
	key.lan = daddr/dxport;  key.ext = saddr/sxport;
	state = pf_find_state_all(&key, PF_OUT, &m);
	/* 答案：rdaddr = sk->gwy.addr，rdxport = sk->gwy.xport  ← 原目的！ */
}
```

**`gwy`（gateway）就是重定向前那��真正目的地** —— 只有 `PF_OUT` 那条分支把它交出来。
`PF_IN` 分支给的是「我们给什么它就还什么」，没有信息。

所以正确的问法是：

| 字段 | 填什么 |
|---|---|
| `saddr` / `sxport` | 对端（客户端）地址和端口 |
| `daddr` / `dxport` | socket 本地地址和端口（= 重定向目标 18081） |
| `af` | `AF_INET` |
| `proto` | `IPPROTO_TCP` |
| `direction` | **`PF_OUT`（2）** |
| 答案 | `rdaddr` + `rdxport` = 原目的 |

### 顺带查清的两件事

| 事实 | 怎么查的 | 影响 |
|---|---|---|
| macOS 的 pfctl **没有** `pfctl -ss -o nat` | `pfctl: Unknown optimization 'nat'`（`-o` 只是规则集优化器） | 「读状态表当兜底」这条路**不成立**：状态表那一行只有重定向后的元组（`ALL tcp 127.0.0.1:18081 <- 127.0.0.1:54009`），没有原目的。**DIOCNATLOOK 是唯一的路**，而它要 root → **helper 必须背这个活** |
| XNU 的 `pf_io.c` 里有 `securelevel > 1` 的白名单，`DIOCNATLOOK` 在里面 | 读到源码 | 说明这个 ioctl 是给有特权的程序用的，不是给普通 app 的 |

### 现在的状态

实测工具按上面三条重写：ioctl 发在 `/dev/pf` 上、用 Apple 的 84 字节布局、方向用 `PF_OUT`。
另外脚本也修了两处自己的毛病：`verdict` 在定义之前被调用（用户输出里那句
`verdict: command not found`），以及普通用户跑 helper 时进不去 root 建的 700 临时目录。

## 本轮：成了 —— 原目的地址读回来了

第三次实测，三处修正全部被证实：

```
NATLOOK ok layout=apple order=peer_first ports=net addrs=net proto=6 dir=out dst=local
  saddr=127.0.0.1/1.0.0.127 sport=55061/5591
  daddr=127.0.0.1/1.0.0.127 dport=18081/41286
  rsaddr=127.0.0.1/1.0.0.127 rsport=55061/5591
  rdaddr=127.0.0.1/1.0.0.127 rdport=18080/41030
NATLOOK best layout=apple addr=127.0.0.1 port_host=18080 port_net=41030
going to the original destination
```

**`rdport=18080` 就是原目的端口。** helper 用它连了回去，客户端拿到 480 字节。

**整条链路闭合了**：

> 客户端 → PF `rdr` 重定向 → helper 接住 → `DIOCNATLOOK` 读回原目的 →
> 按规则选上游 → 另开连接 → 双向中继 → 客户端拿到页面

**网关模式在 macOS 上可行 —— 这不再是猜测，是实测。**

### 三处修正都被证实

| 修正 | 实测 | 说明 |
|---|---|---|
| `layout=apple`（Apple 的 84 字节布局） | ✅ 成功 | BSD 的布局问的是另一个 ioctl |
| `dir=out`（只有 `PF_OUT` 交出 gateway） | ✅ 成功 | `dir=in` 那一路没找到状态 |
| `ports=net`（内核按网络序存端口） | ✅ 成功 | 只有网络序那两种组合有答案；地址两种读法都能中（`127.0.0.1` 对称） |

答案的读法也定了：**地址和端口都是网络序**（`rdport=41030` = `htons(18080)`）。

### 顺带定下来的架构

- **反查原目的必须 root**（`/dev/pf` 是 root 专属），**且不需要 socket fd** ——
  内核是按四元组查状态的（Apple 的结构体里没有 fd 字段）。
  → **helper（root）负责查**：app 告诉它「客户端 192.168.254.140:52344 → 127.0.0.1:18081」，
  它回「1.1.1.1:443」。
- app 侧（无特权）负责：接住被重定向的连接、**按规则选上游**（阶段 1 的规则引擎）、
  另开连接、双向中继。

### 这次输出里也有我自己的两个毛病（已修）

1. 结论脚本里有一处检查是看状态表里有没有 `18080` —— **状态表里根本没有原目的**，
   而**规则文本里恰好写着 `port 18080`**，于是它为一个错的原因报了 PASS。
   这条检查整条删掉：ioctl 是唯一的路。
2. 「程序没接到连接」时只说这一句，不看程序写了什么 ——
   非 root 那轮其实写了「`/dev/pf` 打不开」，这才是原因。现在把程序写的全打出来。

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


## 窗口与菜单栏：本轮查实的三件事

这一轮是顺着「菜单栏的窗口点了会先拉长后变短」查下去的，查出来的不是一个原因，是三个。
下面的都是**在本机实测过的**，不是推的。

### 1. `WindowGroup` 没有 id → 每次 reopen 叠一个新窗口

`ProxiRouteGUI.swift` 里主窗口是 `WindowGroup { ... }`，**没有 id**。
SwiftUI 的语义是：无 id 的 `WindowGroup` 每次 app 被重新打开都会新建一个窗口。
而 app 每次从菜单栏回来都会走一次 `applicationShouldHandleReopen` → `showMainWindow()`。

实测（改之前）：
- 全新启动：AX 窗口数 = 1
- 反复 reopen 之后：AX 窗口数 = 2（且不继续增长，稳在 2）
- 两个窗口内容完全相同，都是主窗口，位置重叠

两个窗口叠在屏幕上，其中一个从不关闭 —— 这就是「点左上角窗口时看起来怪」的来源。

**修法**：`WindowGroup(id: "main")` + `applicationShouldHandleReopen` 返回 `false`
（窗口由 app 自己带回来，就不要让系统再带一个）。
另外 `WindowAccessor` 里给窗口钉 `contentMinSize` / `contentMaxSize`，
让尺寸由窗口自己定，而不是由内容定（设置页是 ScrollView，会要全部高度）。

实测（改之后）：窗口数恒为 1；关窗 → 从菜单栏唤回，高度稳定 652 点。

### 2. 「窗口」菜单里塞满了会改变窗口尺寸的项

macOS 27 的「窗口」菜单里有一堆系统自己加的项：
`关闭 / 全部关闭 / 最小化 / 全部最小化 / 缩放 / 全部缩放 / 填充 / 居中 /
移动与调整大小 / 全屏幕平铺 / 移到屏幕… / 窗口平铺到屏幕… / 前置全部窗口 / 排在前面`。

这些是 macOS 记下来的**窗口位置与尺寸历史项**——点一下就把窗口改成它以前的样子。
本 app 的窗口尺寸由内容决定，跟这些历史项合不来。

实测（改之前，菜单 24 项）：其中 8 项直接改变窗口尺寸，另有 2 项是窗口排列。

**修法**：把这些标题加进 `windowNoiseTitles`（`StandardMenuLocalizer.swift`），
由 `pruneWindowMenu` 删掉。中英文两套标题都要写。
清单拆到独立文件 `ProxiRoute/WindowMenuNoise.swift`，这样测试不用拉整个 app 的依赖链
（菜单代码依赖 `AppDelegate`，测试只需要那份标题清单）。

实测（改之后，菜单 11 项）：只剩
`打开 ProxiRoute / 进入全屏 / 代理设置 / 代理规则 / 网关 / 代理服务器 / 关于 / 检查更新 / ProxiRoute`，
**没有一项会动窗口尺寸**。

### 3. 「安装 / 卸载」按钮被折叠在网关卡片中段

`SettingsTabView.gatewayCard` 里，helper 那一段（状态行 + 安装/卸载按钮 + 说明）
原本排在「打开网关 / 网卡 / 状态 / 已承载连接」之后、路由选项之前。
卡片很长，**按钮在折叠线以下**——用户说「网关页面没看到」是真的没看到。

AX 树里能找到 `AXButton d='安装'`，说明按钮渲染了，只是位置看不见。

**修法**：helper 段提到卡片**第一项**。没有 helper 的话网关模式什么也不干，
这本来就是这张卡最该先说的话。

### 关于「噪音」

用户怀疑是日志噪音。查下来**不是**：
`activityLogs` 上限 500 条、裁到 400 条（`ProxiRouteViewModel.swift:115-117`），
裁剪只减条数不改数组结构，不会让窗口先涨后跌；而且日志页是 `NSScrollView`，
本身没有理想高度。真正让窗口变的是上面第 1 条的第二个窗口。

## 打包：CI 的 app zip 里没有 helper

发 stage28 的时候查出来的：**CI 产出的 `ProxiRoute-v4.1.2-Universal.app.zip`
里没有 `Contents/Helpers/com.sdpong.proxiroute.helper`，也没有
`Contents/Resources/com.sdpong.proxiroute.helper.plist`**。

实测（stage28 的 CI 产物）：解压后 `Contents/` 只有
`Info.plist / Library / MacOS / PkgInfo / Resources`——没有 `Helpers`。

**为什么这是坏的功能**：app 里的「安装」按钮是从 bundle 里取 helper 的
（`GatewayInstaller.swift`：`SRC_TOOLS="$APP/Contents/Helpers/$NAME"`）。
zip 是免安装版，没有 pkg 的 postinstall 帮它把 helper 放到
`/Library/PrivilegedHelperTools`，所以**用 zip 的人点「安装」必然失败**。

**为什么 CI 会这样**：`build-mac.yml` 的「Package App Bundle」步骤直接把
`xcodebuild` 的产物打包成 zip，而 helper 是 `build.sh` 才放进去的
（`build.sh` 负责编译 helper 并复制进 `Contents/Helpers`）。pkg 走的是
`build.sh`，所以 pkg 有 helper，zip 没有。

**修法**：

- 新增 `scripts/embed-helper.sh`：编译 helper，放进 bundle
  （`Contents/Helpers` + `Contents/Resources/*.plist`），**然后重新签一次 bundle**
  ——签名要盖住里面的 helper。
- `scripts/adhoc-sign.sh` 加 `--force`：bundle 里加了东西之后要能重签
  （原来的早退逻辑会因为「已经有 entitlements」而跳过）。
- `build-mac.yml` 在 Notarize 之前加一步「Put the helper of the gateway mode
  into the app」，签完名再公证；zip 和 pkg 于是拿到同一个带 helper 的 bundle。
- `build.sh` 改成**优先用 bundle 里已有的 helper**。原因：bundle 是签过名的，
  签名盖住了里面的 helper；再塞一份新的进去会破坏签名，系统会拒绝运行这个 app。
  pkg 的载荷里放的也就是 bundle 里那一份。

实测（本地模拟 CI 全流程）：`xcodebuild → embed-helper.sh → ditto zip`，
zip 里有 `Contents/Helpers/com.sdpong.proxiroute.helper`（356528 字节）+
`Contents/Resources/com.sdpong.proxiroute.helper.plist`；
`build.sh` 打印 "Using the helper that is already inside the app bundle."；
pkg 载荷里 helper 是 `100755 0/0`、daemon 是 `100644 0/0`（root:wheel）；
pkg 里的 app `codesign --verify` 通过（helper 在签名覆盖范围内）。

## 网关模式：没装 helper 时，「打开网关」开关不该能点

用户问「不装 helper 只点打开网关」和「装 helper 再打开网关」有什么区别的时候，
查出来的两件事：

**一、两个动作是两层完全不同的东西。**

| | 谁做 | 改不改这台机器 | 要密码吗 |
|---|---|---|---|
| 安装 helper | app 用 `osascript` 要 root，把 root 程序装到 `/Library/PrivilegedHelperTools/`、plist 装到 `/Library/LaunchDaemons/`，launchd 拉起来 | **不改**（安装脚本第一步恰恰是「机器先回原样」：`pfctl -f /etc/pf.conf` + `forwarding=0`） | **要** |
| 打开网关 | app 通过 unix socket 问 helper；helper 装 PF 规则 + 开转发 | **改**：PF 里装 `rdr` 规则、`sysctl -w net.inet.ip.forwarding=1` | 不要（helper 已经是 root） |

helper 启动时（`helper/main.swift` → `GatewayHelper.run()`）**只开 socket 干等**，
不碰过滤器、不碰转发。所以「只装 helper 不开网关」= 机器上多个 root 常驻程序，
网络行为跟没装一样。

**二、「打开网关」这个开关在没有 helper 时是个陷阱。**

`SettingsTabView` 里那个 Toggle 原来没有 `.disabled(...)`：
helper 没装也能点，点了必然失败（app 连不上 helper 的 socket），
而 `GatewayController.isEnabled` 的 didSet 会把 `true` 写进 `UserDefaults`
（键 `gatewayEnabled`）——于是**每次打开 app 都会自动再试一次、再失败一次**，
而且开关看起来是「开着的」，人怎么点都没用（点了就失败，失败后又变回…）。

修法（`GatewayInstaller.canTurnOn` / `GatewayInstaller.initialGatewayState`）：

- 没装 helper 时，开关和网卡选择器都置灰，并在开关下面写明为什么；
- app 启动时先问 helper 的状态：**记住的「开」只有 helper 还在才保留**，
  helper 不在了就把那个记住的状态丢掉（`UserDefaults` 里也清掉）；
- 点「打开网关」时发现 helper 不在，开关自己弹回「关」，不留一个假的「开」；
- 点「卸载」把 helper 拿走时，开关也跟着关掉。

实测：先把 `defaults write com.sdpong.ProxiRoute gatewayEnabled -bool true` 写进去，
再启动 app → `defaults read` 已经是 `0`；AX 树里「打开网关」`enabled=0`，
底下出现「要先安装网关模式的 helper，才能打开网关。」，网卡选择器也是灰的。

## 菜单栏：查实的两件事（跳闪 + 语言）

用户报「窗口菜单下拉框跳闪」和「改成英文了菜单栏还是中文」。两件都查到了根因。

### 一、跳闪：菜单开着的时候，我们在改菜单

**实测数据**（加计数器后）：菜单打开的 2 秒里，`apply()` 被调了 **382 次**，
删了 20 项、插了 3 项。AppKit 同时在报：

```
[com.apple.AppKit:Menu_Tracking] didChangeSubmenuContents: rep returned item view with wrong item
[com.apple.AppKit:Menu_Tracking] didChangeImage: rep returned item view with wrong item
  expected item = <SwiftUI.SwiftUIMenuItem ... action: performMiniaturize:>
  actual item = <NSMenuItem ... action: showMainWindow>
```

**因果链**（死循环）：

1. SwiftUI 画窗口菜单时会把系统的那些项加进去（最小化 / 缩放 / 填充 / 居中 /
   移动与调整大小 / 平铺…）；
2. 我们的 `StandardMenuLocalizer` 看到它们就把它们**删掉**；
3. 删掉是「菜单变了」，SwiftUI 就**把菜单重画一遍**，那些项又回来了；
4. 回到第 2 步。

菜单开着的时候 AppKit 正在跟踪它，菜单项被删了又插 → **下拉框一直在跳**。

**试过但不管用的**：

- 改成**隐藏**（`isHidden = true`）而不是删除：还是循环（2 秒里隐藏了 5011 次）；
- **菜单开着时不动它**：菜单里就会露出那些项（SwiftUI 是在打开的时候加的）。

**修法**：**从源头不画它们**。SwiftUI 的命令里加

```swift
CommandGroup(replacing: .windowArrangement) { }
```

那一组里的项（移动与调整大小 / 平铺到屏幕… / 移到屏幕边缘…）就再也不会进菜单，
运行时**一个项都不用删**，也就没有循环。

实测（同一个测量方法）：

| | AppKit 菜单错误 |
|---|---|
| 改之前 | 15 次/秒（2 分钟 1874 条） |
| 改之后 | **0** |

窗口菜单现在的内容：`打开 ProxiRoute / 进入全屏 / — / 代理设置 / 代理规则 /
网关 / 代理服务器 / 关于 ProxiRoute / 检查更新 / — / ProxiRoute`。

**还剩两个**：`移到"内建视网膜显示器"` 和 `全部移到内建视网膜显示器`——
macOS 27 新加的，标题里带**显示器名字**，所以固定清单对不上；它们不改窗口大小，
单显示器时什么也不做。

**顺带**：`StandardMenuLocalizer` 里那段「给菜单栏的四个菜单改名字」的代码删了。
实测：写进去的名字一会儿就没了（SwiftUI 重画菜单栏时写回自己的标题），
而写标题本身是「菜单栏变了」，又会让 SwiftUI 重画 → 白忙一场，还制造抖动。

### 二、语言：bundle 的语言在启动时就定死了

**实测**（切换语言后读 bundle）：

```
preferredLocalizations=["en"] appleLanguages=["zh-Hans"]
```

`AppleLanguages` 在运行中改了，**bundle 的语言没有跟着变**——bundle 的语言是
进程启动时读进去的（`main.swift` 里的那句 `AppleLanguages` 对**下一次**启动有效）。

而 macOS 自己画的「窗口 / 帮助」两个菜单，标题来自 bundle 的语言 → **运行中改语言，
这两个菜单不变**（app 自己的菜单是 `L10n.t()` 画的，会变 ✓）。

试过在运行中改 bundle 的语言：`Bundle.main.setValue(_:forKey:"preferredLocalizations")`
会抛 `NSUnknownKeyException` 直接崩，**不能用**。

**修法**：改语言之后，app **问一句要不要重启**：

- 「窗口 / 帮助」是 macOS 画的，用的是 app 启动时的语言；
- 重启一次，它们就是刚选的那种语言。

实测：切到中文 → 弹窗 → 点「现在重启」→ app 重启（pid 变了）→ 菜单栏变成
`ProxiRoute / 配置 / 窗口 / 帮助`；切到英文 → 重启 → `ProxiRoute / Profile / Window / Help` ✓

## stage29-c：签名会静悄悄地坏掉，而坏掉的 app 要等用户装上才发现

### 一、现象

用户在 app 里打开代理，系统直接拒了：

```
[ERROR] 无法保存设置：permission denied
[ERROR] 扩展失败：Missing entitlement com.apple.developer.system-extension.install
[ERROR] macOS 不会从未签名的版本安装系统扩展。
```

### 二、根因（实测，不是猜的）

`/Applications/ProxiRoute.app` 的签名是**坏的**，而 `codesign -dv` 看上去还像签了：

```
CodeDirectory v=20400 flags=0x20002(adhoc,linker-signed)
Signature=adhoc
Sealed Resources=none          ← 应该是有的
```

三处对不上：

| 该有的 | 实际的 |
|---|---|
| app 带 `com.apple.developer.system-extension.install` | **没有**（`codesign -d --entitlements -` 输出为空） |
| 扩展 bundle 已签名 | **完全没签**（`code object is not signed at all`） |
| helper 已签名 | 已签（`flags=0x2(adhoc)`） |

**为什么**：app 是被 `embed-helper.sh` 签过的（helper 签上了就是证据），**之后又跑了一次
`xcodebuild`**。xcodebuild 重建会把 `Contents/MacOS/ProxiRoute` 和整个扩展 bundle 换成新的，
新文件上没有签名 → **bundle 的签名被作废**。

这就是它「静悄悄」的原因：`codesign -dv` 还能打印出签名（是 Mach-O 自己的 linker 签名，
不是 bundle 的签名），不看 `--entitlements` 根本发现不了。

**为什么难发现**：坏掉的 app 一样能启动、一样能开窗口、一样能改设置，
**只有真的要接管流量的时候**系统才拒绝。而那一刻是**用户在自己机器上**、
**下载安装之后**才知道。

### 三、修法：让它在能修的时候失败

新增 `MacOS/ProxiRoute/scripts/verify-app-signature.sh`，检查四件事：

1. 整个 bundle 的签名有效（`codesign --verify`）
2. app 带 `com.apple.developer.system-extension.install`
3. 嵌套的扩展 bundle 已签名，且带 `com.apple.developer.networking.networkextension`
4. bundle 里的 helper 已签名（helper 在 bundle 里，签名必须盖住它）

接到两个地方：

- `build.sh`：打包前跑 → 坏的 app **打不出包**
- CI：签完名、打包后跑，且**把 zip 解开再验一次**（zip 才是别人下载的东西）

外加 `MacOS/tests/logic/signature_tests.swift`（17 条断言）盯住这条链路不会被改没。

### 四、实测

- 坏签名（把扩展的签名去掉）→ 校验脚本 **exit 1** 并指出是哪一项 ✓
- 修好的 app → 校验脚本 exit 0 ✓
- 重新签名的 app 装回 `/Applications` → 启动后界面日志里 **没有 ERROR**，
  换成正常的提示「macOS has to approve ProxiRoute once…」✓
- 本地 `build.sh` 跑通，pkg 载荷里的 app 签名校验通过 ✓
- **CI 已发布的 app.zip（stage29）解包后签名校验通过** → 之前发的产物没坏 ✓

## stage30：窗口是最费电的地方 —— 内存和 CPU 的实测与修法

### 一、实测到的现象

ProxiRoute 的 app 进程跑久了会涨到 **800MB 内存**、**十几 % 的 CPU**，而机器并没有做什么特别的事。

```
pid=3888 rss=617MB cpu=10.6%
```

`vmmap` 看内存的构成：

```
Malloc Small                             683.4M    647.6M    644.6M      401
DefaultMallocZone_0x101974000            712.4M    649.3M    645.6M   480971
```

**48 万个小对象，645MB** —— 不是几个大块，是几十万个小东西。

`sample` 看 CPU 在哪儿：

```
+ 3605 main
  + 3605 NSApplicationMain
    + 3605 [NSApplication run]
      + 3600 _DPSNextEvent
        + 2626 __CFRunLoopRun
          + 283 CA::Transaction::flush          ← SwiftUI 在重画
            + 202 CA::Transaction::commit
              + 201 NSDisplayCycleFlush
                + 94 __NSWindowGetDisplayCycleObserverForLayout_block_invoke
                  + 93 -[NSWindow layoutIfNeeded]
                    + 56 @objc NSHostingView.layout()
                      + 43 ViewGraphRootValueUpdater.render()
                        + 28 ViewGraph.updateOutputs(at:)
                          + 27 PlatformItemListViewGraph.needsUpdate(graph:)
                            + 11 ResolvedTextFilter.updateValue()   ← 列表的文本又解析了一遍
```

**只有主线程在跑**，别的线程都空着。CPU 全花在 SwiftUI 重画上，而重画的原因是
**列表里的文本被反复重新解析**。

### 二、根因（实测，四个地方）

**根因 0：扩展每秒写几百行日志。**

```
$ log show --last 60s --predicate 'subsystem == "com.sdpong.proxiroute.extension"'
extension log lines in last 60s: 826
```

每条连接一行，每条流一行。826 行/秒。

**根因 1：每一行日志都让窗口重画一次。**

`append(_ lines:)` 把一行一行地塞进 `activityLogs` / `connections`，
两个都是 `@Published` —— 每塞一行，SwiftUI 就重画一次整个窗口。
826 行/秒 = 826 次重画/秒。

**根因 2：日志视图在 body 里重建整个带格式的文本。**

```swift
private var logsText: NSAttributedString {   // ← body 里每次都跑
    let out = NSMutableAttributedString()
    for log in logs {
        out.append(LogText.seg("[\(log.timestamp)] ", .secondaryLabelColor))   // 4 段
        out.append(LogText.seg("[\(log.level)] ", ...))
        out.append(LogText.seg(log.message, .labelColor))
        out.append(LogText.seg("\n", .labelColor))
    }
    return out
}
```

日志最多 500 行 × 4 段 = **一次 2000 个小对象**，而 body 每来一行就跑一次。
而且重建的是**全部**，不是新增的那几行。

**根因 3：每个单元格都新建一个重量级的格式化器。**

```swift
static func bytes(_ count: Int64) -> String {
    let f = ByteCountFormatter()    // ← 每格一个
    f.countStyle = .file
    return f.string(fromByteCount: count)
}
```

`ByteCountFormatter` 内部要建数字格式化器和单位表，不轻。
连接表每行 3 个数字格，流量表每行 3 个 —— 表每秒重画一次，就是每秒几百个。

**根因 4：轮询拿到的是新数组，即使内容一模一样。**

`liveFlows = machineFlows` 每次都发布新数组。SwiftUI 分不出「新数组」和
「装着同样内容的旧数组」—— 它看到新值就重建表格，每格重新解析文本。

### 三、修法

| 地方 | 改法 |
|---|---|
| 数字格式化 | 全局一个 `ByteCountFormatter`（表格都在主线程画，够用） |
| 日志文本 | 从 body 里挪进 `LogTextView`，只往末尾追加新行；被裁剪时整体重写 |
| 日志行/连接行 | 先进 `pendingActivity` / `pendingConnections`，每 0.25 秒一起上屏 |
| 流量表/连接表 | 加 `sameAs` 比较，内容没变就不发布数组 |

### 四、实测（同一台机器，同一个扩展状态）

| | 未优化 | 优化后 |
|---|---|---|
| 启动 20 秒后 | 138MB / CPU 4.1% | 145MB / CPU 0.0% |
| 跑 5 分钟后 | **163MB**（涨 25MB） | **145.5MB**（不涨） |
| 5 分钟内 CPU | 3.5% ~ 4.8% | **0.0%** |

原来约 **5MB/分钟**地涨，一小时后就是 800MB。优化后这条曲线是平的。

### 五、为什么「内容没变就不发布」是对的

连接的「空闲时间」每秒都在长，所以比较的时候按秒取整
（`Int(age) == Int(other.age)`）：一秒内没动的连接，画出来的是同一行，
表格就不用重建。

### 六、测试

新增 `MacOS/tests/logic/windowdrawing_tests.swift`（22 条断言），盯住这四件事不被以后改没：
数字格式化器只有一个、日志文本不在 body 里造、日志行不是一行一行上屏的、
流量表走的是比较而不是直接发布。

### 七、基准测试（决定性数据）

单看进程内存会看走眼：那些对象是**autorelease** 的，用完就进池子，
RSS 增量测出来是 0 —— 但它们**产生得极快**，回收跟不上，内存曲线就一路涨。
所以量的是**产生垃圾的速度**。

日志 500 行，每来一行日志做一次（日志文本这一项）：

| | 100 行的耗时 |
|---|---|
| 旧：每次重建整个带格式文本 | **354.5 ms** |
| 新：只往末尾追加新行 | **4.4 ms** |

**80 倍。**

每来一行日志，旧做法要重建 500 行 × 4 段的带格式文本（2000 个小对象）。
扩展每秒写 1300 行 —— 也就是说，**光这一项每秒要扔掉 260 万个小对象**。
```bash
swiftc -O bench3.swift -o bench3   # 见下
```
