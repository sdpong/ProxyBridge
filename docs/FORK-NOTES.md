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
- **窗口怎么回来**：点 Dock 图标，或者菜单栏里的「Open ProxyBridge」。
- **坑：SwiftUI 的 `WindowGroup` 不带 id 的话没法用 `openWindow` 重新打开**。
  试过给它加 id（`WindowGroup(id: "main")` + `openWindow(id:)`），
  结果**非正常退出（kill -9）后重启会出现两个窗口**：
  系统按上次的状态恢复一个，SwiftUI 自己又开一个。
  最后改成**app 侧强引用主窗口**（`AppDelegate.mainWindow` 从 weak 改成强），
  关掉之后窗口对象还在，`makeKeyAndOrderFront` 就能把它叫回来。
- **`applicationShouldTerminateAfterLastWindowClosed` 必须一直返回 false**：
  它数的是**所有**窗口（包括菜单栏那个），macOS 26 上点开菜单再点外面
  看起来就像「最后一个窗口关了」，app 会自己退出（#233）。

### 多语言：中文 / 英文（自己写的字典，不用 .lproj）

- **两种语言**：中文（简体）和英文。**第一次启动跟随系统语言**，
  之后记住用户的选择（UserDefaults 里的 `appLanguage` 键）。
- **在 Settings 菜单里切换**，切换后**所有打开的窗口立刻重绘**，不用关窗重开。
- **翻译表在 `MacOS/ProxyBridge/ProxyBridge/L10n.swift`**，不是 `.lproj` / `.xcstrings`：
  - 字典表**可以编进 ad-hoc 签名的二进制**，也可以在不改资源流程的前提下增删；
  - **key 就是英文原文本身**，没翻译的句子直接显示英文，不会露出一个 key；
  - `L10n.f(_:_:)` 处理带 `%@` 的插值句，`L10n.t(_:)` 处理整句。
- **视图持有 `@ObservedObject private var loc = LocalizationManager.shared`**，
  `LocalizationManager` 是 `ObservableObject`，`@Published language` 一变，视图就重画。
- **菜单里用 `Menu` + `Button`，不用 `Picker`**：系统菜单里的 `Picker` 子菜单
  在自动化点击下很难点开，`Menu` + `Button`（带 checkmark）更可靠，也更好点。
- **逻辑测试 `l10n_tests.swift` 会扫 app 源码**：把每个 `L10n.t(` / `L10n.f(` 用到的 key
  收集起来，核对翻译表里都有。漏一条不会让 app 崩（会退回英文），
  但会让翻译悄悄破个洞，测试就是堵这个洞的地方。

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
