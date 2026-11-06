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

## 已知限制

- **本机（macOS）没有 MSVC / mingw 交叉编译器**，Windows 侧改动只能逐行人工复核 +
  靠 Windows 上的 `compile.ps1` 与 `run_tests.ps1` 验证
- `test_main_ui` 需要**桌面会话**才能跑（它创建真实窗口）

## 相关文件

- `docs/ROADMAP.md` —— 功能路线图（超集 Proxifier）
- `Windows/README.md` —— Windows 端架构说明
- `MacOS/README.md` —— macOS 端架构说明
- `CONTRIBUTING.md` —— 上游贡献指南（提交 PR 前看这个）
