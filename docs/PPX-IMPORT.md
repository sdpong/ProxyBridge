# .ppx 导入规格（Proxifier 配置 → ProxyBridge 配置）

> 本文件是 fork（`sdpong/ProxyBridge`）的规格，上游仓库不包含它。
> 它是 **macOS 端 `PPXImporter.swift` 与 Windows 端 `gui/profile/ppx.c` 的共同契约**：
> 两端必须按同一张表映射，同一个 `.ppx` 在两端必须得到同一个意思。
> 防漂移靠的是两端各有一份**内容完全相同的测试 fixture 与用例**
> （`MacOS/tests/logic/ppx_tests.swift` ↔ `Windows/tests/test_ppx.c`）。

## 目的

Proxifier 把配置存成一个 XML 文件 `.ppx`。从 Proxifier 换到 ProxyBridge 的人手里
拿到的就是这一个文件，让他手抄一遍规则不现实，所以直接读。

导入结果落在**一个新配置**里（macOS：新建 profile 并切过去；Windows：写一个新的
`.pbprofile` 并切过去），**已有的配置一个都不动**。

## English abstract

Proxifier stores its configuration as an XML file called a `.ppx`. Both platforms read it
now, and they share one mapping table (this file) and one test fixture, so the same file
means the same thing on macOS and on Windows. Whatever Proxifier has and ProxyBridge does
not — traffic encryption, QUIC blocking, loop detection, the per-proxy option bits — is
reported to the user rather than dropped silently. The import lands in a **new** profile;
the profiles that are already there are left alone.

---

## 一、文件结构

```xml
<ProxifierProfile version="101" platform="MacOSX" product_id="2" product_minver="200">
  <Options>
    <Resolve>
      <AutoModeDetection enabled="false"/>
      <ViaProxy enabled="true"><TryLocalDnsFirst enabled="false"/></ViaProxy>
      <ExclusionList ExcludeLocalhost="true" ExcludeSelfHostname="true"
                     ExcludeLocalDomain="true">localhost;%ComputerName%;*.local;</ExclusionList>
    </Resolve>
    <Encryption mode="disabled"/>
    <HttpProxiesSupport enabled="true"/>
    <HandleDirectConnections enabled="false"/>
    <ConnectionLoopDetection enabled="false"/>
    <ProcessServices enabled="true"/>
    <ProcessOtherUsers enabled="true"/>
    <BlockUDP443 enabled="false"/>
  </Options>
  <ProxyList>
    <Proxy id="101" type="SOCKS5">
      <Address>1.2.3.4</Address><Port>1080</Port><Options>0</Options>
      <Label>home</Label>
      <Authentication enabled="true"><Username>u</Username><Password>p</Password></Authentication>
    </Proxy>
  </ProxyList>
  <ChainList>
    <Chain id="126">
      <Name>office</Name>
      <Proxy enabled="false">118</Proxy>
      <Proxy enabled="true">125</Proxy>
    </Chain>
  </ChainList>
  <RuleList>
    <Rule enabled="true">
      <Name>r1</Name>
      <Applications>app.exe; "Some App.app";</Applications>
      <Targets>*.example.com; 10.0.0.0/8</Targets>
      <Ports>80;443</Ports>
      <Action type="Proxy">101</Action>
    </Rule>
  </RuleList>
</ProxifierProfile>
```

Proxifier for macOS 与 Proxifier for Windows **写的是同一种格式**
（Windows 存在 `%AppData%\Roaming\Proxifier4\Profiles\*.ppx`），
所以一个读取器服务两端。

**读取器的安全边界**（两端一致）：

- 只解析元素、属性、文本；不解析外部实体（macOS 用 `XMLParser` 且
  `shouldResolveExternalEntities = false`；Windows 自写解析器，遇到 DOCTYPE 整段跳过）。
- 只认 5 个内建实体 `&amp; &lt; &gt; &quot; &apos;` 和 `&#N;` / `&#xN;`；
  其它 `&` 原样保留（配置里一个手滑的 `&` 不该变成错误）。
- 根元素不是 `ProxifierProfile` → **拒绝**，不写任何东西进配置。
- 文件大小上限 8 MB；XML 深度上限 24；节点数上限 20000。

---

## 二、代理映射

| Proxifier `type` | ProxyBridge 类型 | `sendDomain`（由代理解析域名） | 说明 |
|---|---|---|---|
| `SOCKS5` | `socks5` / `SOCKS5` | 是 | 原样 |
| `SOCKS4` | `socks4` / `SOCKS4` | **否** | SOCKS4 只能带地址 |
| `SOCKS4A` | `socks4` / `SOCKS4` | 是 | SOCKS4A = SOCKS4 + 主机名 |
| `HTTPS` | `http` / `HTTP` | 是 | Proxifier 的 "HTTPS" = **会开 CONNECT 隧道**的 HTTP 代理 |
| `HTTP` | `http` / `HTTP` | 是 | **附警告**：Proxifier 的纯 HTTP 模式没有 CONNECT 隧道 |
| 其它 | — | — | **丢弃 + 警告**（写明是哪个代理、什么类型） |

> ⚠️ Proxifier 里的 "HTTPS" **不是**「到代理服务器的链路是加密的」，
> 而是「HTTP 代理，且允许 CONNECT 到任意端口」；"HTTP" 才是只能跑明文 HTTP 的那种。
> ProxyBridge 的 HTTP 代理一律用 CONNECT，所以 `HTTPS` 直接映射成 HTTP 代理；
> `HTTP` 映射成 HTTP 代理但要提醒用户：ProxyBridge 会向它要 CONNECT 隧道。

| Proxifier | ProxyBridge | 说明 |
|---|---|---|
| `<Address>` | `host` | 空 → 该代理丢弃 + 警告 |
| `<Port>` | `port` | 不是 1–65535 → 该代理丢弃 + 警告 |
| `<Label>` | `name` | 没有就留空 |
| `<Authentication enabled="true">` → `<Username>` | `username` | |
| `<Authentication enabled="true">` → `<Password>` | `password` | |
| `<Proxy><Options>` 位掩码 | **不映射** | 见第四节 |

代理 **id** 沿用文件里的值（Proxifier 的 id 是它自己的号段，如 101–127），
这样规则里的 `<Action type="Proxy">101</Action>` 不用改写就能对上。

---

## 三、链映射

Proxifier 把链上的**所有**代理都列在 `<Chain>` 里，用 `enabled` 开关决定走哪几跳；
**只有 `enabled="true"` 的跳会被走**。

| Proxifier | ProxyBridge |
|---|---|
| `<Chain id>` | macOS：沿用文件 id（字符串）；Windows：重新分配一个 ≥ `PB_CHAIN_ID_BASE`(1000) 的 id（链 id 号段与代理 id 号段不重叠，两者在 profile 里不会混淆） |
| `<Name>` | `name` |
| `<Proxy enabled="true">` | 一跳，**按文件里的先后顺序** |
| `<Proxy enabled="false">` | 跳过 |
| `<Proxy>` 没有 `enabled` | 视为启用 |
| 跳指向一个不存在的代理 | 跳过该跳 |
| **所有跳都关闭** | **整条链丢弃 + 警告**；指向它的规则改直连 |
| 跳超过 8 个 | 取前 8 个（`PB_MAX_CHAIN_HOPS`） |

> 关键一致性点：**「链被丢弃」时，指向它的规则必须改成直连**，
> 不能留一个指向不存在的链的 `chain:` 动作。
> macOS 早期实现踩过这个坑（链 id 先入集合、后判空），Windows 侧按「已导入的链」查找，
> 两端现在一致，并各有一条用例守着。

---

## 四、规则映射

规则**保留文件里的顺序**：Proxifier 取第一条命中的规则，ProxyBridge 也一样。

| Proxifier | ProxyBridge | 说明 |
|---|---|---|
| `<Rule enabled>` | `enabled` | `true/1/yes` → 开，`false/0/no` → 关，缺省 → 开 |
| `<Name>` | `name` | |
| `<Applications>` | `processNames`（Windows：`ProcessName`） | 见下面的「应用名归一化」 |
| `<Targets>` | `targetHosts` | 按 `;` 拆，去首尾空白，去空项 |
| `<Ports>` | `targetPorts` | 同上 |
| 协议 | **固定 `TCP`** | **Proxifier 只代理 TCP**（UDP 它只记录/阻断，不走代理） |
| `<Action type="Direct"/>` | `DIRECT` | |
| `<Action type="Block"/>` | `BLOCK` | |
| `<Action type="Proxy">101</Action>` | 代理 101 | 代理不存在 → **改直连 + 警告** |
| `<Action type="Chain">126</Action>` | 链 126 | 链不存在或已被丢弃 → **改直连 + 警告** |
| 其它 `type` | `DIRECT` | **+ 警告** |

### 应用名归一化（两端逐字一致）

1. 去掉首尾空白；
2. **去掉引号**：直引号 `"` `'` 与弯引号 `“ ” ‘ ’` 都算，
   一层一层去（`"a b"` → `a b`）；
3. 去掉 **`.app` 后缀**（`QQ.app` → `QQ`）；
4. 按 `;` 拆分后**去重**（`"QQ.app"` 与 `"QQ"` 常常同时出现）；
5. 用 `;` 连接。

> 为什么去掉引号和 `.app`：规则匹配时会把模式同时和**进程可执行文件名**比对，
> 留着 `"` 或 `.app` 就永远匹配不上。

---

## 五、名字解析（DNS 策略）映射

Proxifier 的 `Profile → Name Resolution` 对应 ProxyBridge 的 **DNS 策略层**。

| Proxifier | ProxyBridge `dnsPolicy` |
|---|---|
| `<AutoModeDetection enabled="true">` | `mode = "system"` + **警告**（Proxifier 自己决定，ProxyBridge 交给用户检查） |
| `<ViaProxy enabled="true">` | `mode = "remote"` 且 `leakProtection = true` |
| `<ViaProxy enabled="false">` | `mode = "local"` |
| `<TryLocalDnsFirst enabled="true">` | **不映射 + 警告**（ProxyBridge 一律由代理解析） |
| `<ExclusionList>` 的文本 | `excludedDomains`，按 `;` 拆分、去空白、去重（**大小写不敏感**去重） |
| 文本里的 `%ComputerName%` | **展开成本机主机名**（macOS：`ProcessInfo.processInfo.hostName`；Windows：`GetComputerNameW`） |
| `ExcludeLocalhost="true"` | 追加 `localhost` |
| `ExcludeLocalDomain="true"` | 追加 `*.local` |
| `ExcludeSelfHostname="true"` | 追加本机主机名 |
| `ExcludeSimpleHostnames` | **不映射**（见第四节） |

> `%ComputerName%` 是 Proxifier 独有的常量，两端各自展开成**本机**的名字，
> 所以同一个 `.ppx` 在两台机器上得到的排除名单不一样——这是对的。

---

## 六、**不**映射的部分（全部有警告或已记录）

| Proxifier 的东西 | 为什么不做 |
|---|---|
| `<Options><Encryption mode="...">` | 流量加密。ProxyBridge 没有这一层 |
| `<Options><BlockUDP443>` | QUIC 阻断。ProxyBridge 的 UDP 能不能走由 SOCKS5 代理本身决定 |
| `<Options><ConnectionLoopDetection>` | 连接环检测 |
| `<Options><HandleDirectConnections>` | 「直连也接管」开关，与本 fork 的语义不同 |
| `<Options><ProcessServices>` / `<ProcessOtherUsers>` | 限定只代理「服务进程」或「其他用户的进程」 |
| `<Proxy><Options>` 位掩码 | 公开资料查不到这个掩码的位定义（实测值只有 0 / 4，第三方生成的 .ppx 里常见 48）。**不猜**：宁可原样忽略，也不要按猜的语义改用户的路由 |
| `<ExclusionList ExcludeSimpleHostnames>` | 「不含单词主机名」的排除语义，ProxyBridge 的排除名单没有这一层 |
| 根元素属性 `version` / `platform` / `product_id` / `product_minver` | 版本信息，与配置内容无关 |

> 凡是**丢掉的东西**，要么给用户看一条警告，要么在这份文档里写清楚——
> **不静默丢弃**。

---

## 七、两端一致性的保证

| 手段 | 位置 |
|---|---|
| 同一份 fixture、同一批用例 | `MacOS/tests/logic/ppx_tests.swift` ↔ `Windows/tests/test_ppx.c`（用例逐条对应） |
| 同一张映射表 | 本文件 |
| 同一套警告文案 | 两个实现里的字符串是**逐字相同**的，测试用同一批子串去断言 |

macOS 侧跑 `MacOS/tests/logic/run.sh`；
Windows 侧跑 `Windows/tests/run_tests.ps1`（`test_ppx`）。

---

## 八、已知的、**故意**不一样的两处

1. **链 id 的类型**
   - macOS 的 profile 里链 id 是字符串（应用自己生成 UUID）；
   - Windows 的 profile 里链 id 是数字，且住在 `≥1000` 的号段里，
     这样规则里那个「代理 id」字段里放链 id 时，两者在模型层就分得开。
   - 语义一致（一条链、若干跳、按顺序），只是 profile 的 id 类型不同。

2. **容量上限**
   - Windows：代理 32、规则 128、链 32、链跳 8（`profile.h` 里的 `PB_MAX_*`）；
   - macOS：应用侧上限更宽（`CLIProfile` 里 100 代理 / 5000 规则）。
   - 超出上限时**给出警告并说明丢了几个**，不静默截断。

---

## 九、相关文件

| 文件 | 作用 |
|---|---|
| `MacOS/ProxyBridge/ProxyBridge/PPXImporter.swift` | macOS 端读取器（用系统 `XMLParser`） |
| `MacOS/tests/logic/ppx_tests.swift` | macOS 端用例 |
| `Windows/gui/profile/ppx.c` / `ppx.h` | Windows 端读取器（自写最小 XML 解析器） |
| `Windows/tests/test_ppx.c` | Windows 端用例 |
| `Windows/gui/main.c` | Windows 端菜单「Import Proxifier Profile (.ppx)...」 |
| `MacOS/ProxyBridge/ProxyBridge/ProxyBridgeGUI.swift` | macOS 端导入面板接受 `.ppx` |
| `MacOS/ProxyBridge/ProxyBridge/CLIProfile.swift` | macOS CLI：`--profile x.ppx` 与标准输入都能读 |
