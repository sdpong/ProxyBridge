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
| Build macOS | ✅ 绿 | 本 fork 没有签名证书时构建**未签名**的通用二进制 App 与 pkg，产物是 workflow artifact |
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

### 代理链

- **中间的跳只能是 SOCKS5 / SOCKS4**：HTTP CONNECT 的应答可能把隧道数据留在缓冲区里，
  下一跳的握手会把它当成自己的应答读走。App 与扩展各有一份校验，
  `MacOS/tests/logic/chain_tests.swift` 比对两边的判定，防止说法漂移。
- **链不能带 UDP**：SOCKS5 的 UDP ASSOCIATE 是独立会话，串不起来。

### 代理类型

- **名字与数字要一一对应**：profile 里存名字（`SOCKS5` / `SOCKS4` / `HTTP`），
  引擎里存数字。Windows 侧用 `pb_proxy_type_*` 一对函数收敛，
  macOS 侧用 `ProxyChain.problems` 与 `ChainPlan.problems` 各自校验（逻辑测试比对两边）。
- **UDP 只走 SOCKS5**：HTTP 没有 UDP，SOCKS4 也没有。规则指向这两种代理时 UDP 走直连，
  并且要**明说**，不能静默回落。

## 已知限制

- **本机（macOS）没有 MSVC / mingw 交叉编译器**，Windows 侧改动只能逐行人工复核 +
  靠 Windows 上的 `compile.ps1` 与 `run_tests.ps1` 验证
- `test_main_ui` 需要**桌面会话**才能跑（它创建真实窗口）

## 相关文件

- `docs/ROADMAP.md` —— 功能路线图（超集 Proxifier）
- `Windows/README.md` —— Windows 端架构说明
- `MacOS/README.md` —— macOS 端架构说明
- `CONTRIBUTING.md` —— 上游贡献指南（提交 PR 前看这个）
