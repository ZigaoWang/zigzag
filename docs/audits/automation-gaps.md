# Zigzag 自动化 / 程序化控制 对 Chrome 的差距

审计范围：只读。所有结论附 `file:line`，或明确写「全仓 grep X 均无命中」。
标注：**[用户]** 普通用户 · **[开发]** 开发者 · **[脚本]** 自动化脚本 · **[IT]** 企业 IT

---

## 0. 总览（结论先行）

| 通道 | Chrome | Zigzag 现状 | 关键差距 |
|---|---|---|---|
| CDP / `--remote-debugging-port` | 完整 CDP over WebSocket | **无**。全仓 `remote-debugging`/`CDP` 零命中，`main.swift:7` 只调 `NSApplicationMain`，不解析任何参数 | Selenium/Playwright/Puppeteer 全部无法驱动 |
| 命令行参数 | `--new-window <url>` / `--incognito` / `--headless` 等 | **完全不解析**。`CommandLine.arguments` 仅命中 `main.swift:7`，`ProcessInfo.processInfo.arguments` 零命中 | 无法用 flag 控制启动形态 |
| AppleScript | 有（`execute`、`windows`、`tabs`） | **有，且相当完整**，且 `execute` 同义于 `do JavaScript` | 缺 tab 的部分属性（见 §1.3） |
| AppleScript 跑 JS 的默认值 | `Allow JavaScript from Apple Events` 默认关 | **默认关**，`Scripting.swift:11`，key `AllowJavaScriptFromAppleEvents` | 与 Safari 一致，非差距 |
| MCP | 无（Chrome 靠第三方 MCP 桥走 CDP） | **有 16 个工具**，127.0.0.1:39217，Bearer key | 能力面窄于 Chrome DevTools Protocol |
| 企业策略 / MDM | 数百个 policy key（plist / `com.google.Chrome`） | **无任何 policy 读取**。见 §3 | 无法被 MDM 统一管控 |
| WebKit remote inspector | — | **Release 也开着** `isInspectable = true`（`Tab.swift:571`） | 外部 `safaridriver` / webinspectord 可能连上（详见 §5，需实测确认可连） |

---

## 1. AppleScript 完整动词表

字典文件：`Zigzag/Resources/Zigzag.sdef`（228 行）。Swift 实现：`Zigzag/App/Scripting.swift`（475 行）。
sdef 头部注释自述「The names follow Safari's and Chrome's dictionaries」（`Zigzag.sdef:4-5`）。

### 1.1 Standard Suite（`Zigzag.sdef:8` 起）

> **行号勘误（本轮实测修正）**：本文件首版 §1 正文的行号是错的（`:38`/`:43`/`:54`/`:56`/`:58`/`:44-53`），源于首版误把「grep 过滤后的序号」当成原文件行号。以下已按 `grep -n` 实测原文件全部更正。感谢 coordinator 指出「你的自查可能有盲区」——事实是：我首版附的勘误表（124/140/193/202）本身是对的，但**没有回填到正文**，反而制造了文件内自相矛盾。这是我的自查盲区，已修。

| 动词 | code | 作用 | 标注 |
|---|---|---|---|
| `open` | `aevtodoc` | 打开文件 / 文件列表 | 脚本/[用户] |
| `close` | `coreclos` | 关闭窗口或 tab | 脚本 |
| `quit` | `aevtquit` | 退出应用 | 脚本 |
| `count` | `corecnte` | 数某类的元素个数 | 脚本 |
| `delete` | `coredelo` | 关闭 tab | 脚本 |
| `exists` | `coredoex` | 对象是否存在 | 脚本 |
| `make` | `corecrel` | 新建 window / tab，支持 `at` 与 `with properties`（如 `{URL:"https://…"}`） | 脚本 |

### 1.2 Zigzag Suite（`Zigzag.sdef:124` 起，code `Zgzg`）

**window 扩展**（`Zigzag.sdef:126`）
- `tabs`（element，跨所有 space：favorites → 各 space 的 pinned + tabs）
- `current tab`（可读写，赋值即切换 tab 与 space）
- `space`（只读 text）

**tab 类**（`Zigzag.sdef:140`，`plural="tabs"`）

| 属性 | code | 访问 | 说明 |
|---|---|---|---|
| `id` | `ID  ` | r | 唯一标识，直到退出 |
| `index` | `pidx` | r | 在窗口内的下标 |
| `name` | `pnam` | r | 标题 |
| `URL` | `pURL` | **r/w** | 读地址；赋值即跳转 |
| `loading` | `ZLdg` | r | 是否在加载 |
| `text` | `conT` | r | 页面可见文本 |
| `source` | `conS` | r | 当前 HTML |
| `pinned` | `ZPin` | r | 是否 pinned |
| `favorite` | `ZFav` | r | 是否 favorite |
| `space` | `ZSpc` | r | 所属 space 名 |

**tab 级动词**

| 动词 | code | 作用 | 标注 |
|---|---|---|---|
| `do JavaScript` | `ZgzgDoJS` | 在 tab 里跑 JS，结果转 text（list/record 转 JSON）；默认关闭，需 Settings › Automation 打开 | 脚本/[开发] |
| `execute` | `ZgzgExec` | 同 `do JavaScript`，对齐 Chrome 的 `execute`（`Zigzag.sdef:202` 注释明说） | 脚本/[开发] |
| `reload` | `ZgzgRlod` | 刷新 tab（无参用前台 tab） | 脚本 |
| `go back` | `ZgzgGoBk` | 后退 | 脚本 |
| `go forward` | `ZgzgGoFw` | 前进 | 脚本 |

`do JavaScript` 的 `in` 参数可指定 tab，缺省前台 tab（`Zigzag.sdef:196`）。支持 `await`/顶层 `return`，按 async function 执行并取其返回值（`Zigzag.sdef:195` 直参说明，实现见 `Scripting.swift:run(_:in:done:)`）。

### 1.3 JS 执行的安全门（实测行为）

`Scripting.swift:javaScriptRefusal(url:isPrivate:allowed:errorPage:)` 明确四种拒绝：
1. `AllowJavaScriptFromAppleEvents` 未开 → `errAEEventNotPermitted`（`Scripting.swift:11`、`:96`）
2. private window → 拒绝
3. 非网页（Zigzag 自家页面、扩展页）→ 拒绝
4. 错误页 / 证书警告页 → 拒绝

且执行前后各校验一次（页面可能在 suspend 期间切换，`Scripting.swift:446` 与 `:455`）。

### 1.4 对比 Safari 字典，缺什么

- Safari 有 `do JavaScript` 的 `in` 参数、`reload`、`go back/forward` —— Zigzag **全有**。
- **勘误（本轮实测）**：首版此处错写「window 缺 `bounds`/`visible`/`closeable`/`miniaturized`/`zoomed`」。**事实相反——这几项 window 全有**：`bounds`(:93)、`closeable`(:96)、`miniaturizable`(:99)、`miniaturized`(:102)、`visible`(:108)、`zoomed`(:114)、`resizable`(:105)、`zoomable`(:111)，均见 `Zigzag.sdef:92-114`。
- 真正的缺口在 **tab 侧**：Safari 的 `tab` 有 `visible`/`parent`/`closeable` 等，Zigzag 的 tab 只有 10 个属性（`Zigzag.sdef:142-172`），**无 `visible`、无 `parent`、无 `closeable`**。
  - **导致**：写「遍历窗口并判断 tab 是否可见」这类 Safari 老脚本时，`tab` 的 `visible` 会报属性不存在（window 的 `visible` 能用，别弄混两者）。
- Safari 有 `document` / `text` 的更细粒度、`windows` 的 `id`、`index` 写入 —— Zigzag 的 **window** `index` 只读（`Zigzag.sdef:90`），**tab** `index` 也只读（`Zigzag.sdef:145`）。
  - **导致**：无法用 `set index of tab N to M` 重排 tab（拖拽排序无脚本通道）。
- **Chrome 有 `active tab index`、`loading`、`title`、`URL` 且支持 `execute`** —— Zigzag 对齐了 `loading`/`name`/`URL`/`execute`，这点不欠。

> [脚本] 迁移 Safari 脚本：90% 可用；涉及 tab 可见性/可关闭性/重排序/窗口边界的会断。

---

## 2. 命令行参数

- `grep -rn "CommandLine" Zigzag/` → **仅 1 命中**：`Zigzag/App/main.swift:7` = `_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)`（即原样把参数交给 AppKit，自己不解析）。
- `grep "ProcessInfo.processInfo.arguments"`、`"--new-window"`、`"--incognito"` → **全仓零命中**。

Chrome 支持的启动 flag 有 `--new-window <url>`、`--incognito`、`--app=<url>`、`--headless`、`--remote-debugging-port`、`--user-data-dir` 等。

**Zigzag 现状**：一个都不解析。启动形态完全由用户偏好（`WindowManager`）决定；链接进入只经两条路 ——
- `application(_:open:)` 文档/链接投递（`AppDelegate.swift:329`，且仅接受 file / http / https，`AppDelegate.swift:335`）
- `application(_:continue:restorationHandler:)` 接力 iPhone/其它 Mac 的网页（`AppDelegate.swift:354`）

**导致跑不通的场景**
- [IT/脚本] `open -a Zigzag --args --new-window https://intranet` 里 `--args` 被忽略，只按普通启动打开。
- [脚本] 无法用 `--incognito` 一次性起一个隐私会话做隔离测试（Chrome 一行搞定）。
- [开发] `--headless` 概念在 Zigzag 无对应（WebKit 无 headless，属平台限制，非实现缺失）。

---

## 3. 企业策略 / 托管配置（MDM）

- `grep -rniE "ManagedConfiguration|MDM|managedPreferences|policyConfiguration|ConfigurationProfiles"` → **Zigzag 源码零命中**。唯一命中在 `Resources/hsts_preload.txt`（如 `openmdm.org`、`mdma.net` 等域名）与二进制资源，属 HSTS 域名噪音，与策略无关。
- 也**没有** `UserDefaults` 的 `policy` 读取封装；所有偏好直接读写 `UserDefaults.standard`（如 `Scripting.swift:11`、`Settings/SettingsView.swift` 各处）。

Chrome 通过 `com.google.Chrome` 域的 managed preferences（plist / MCX）暴露数百个 policy key（禁用同步、强制扩展、代理、主页、`RemoteDebuggingAllowed` 等），并由 MDM 下发。

**Zigzag 现状**：无。`AllowJavaScriptFromAppleEvents` 虽是 UserDefaults key，但它是**用户级 GUI 开关**，不受 MDM 可写域约束，也不读取 `com.apple.ManagedConfiguration`。

**导致跑不通的场景**
- [IT] 无法用 MDM Profile 统一「禁用 JS from Apple Events」「禁止 MCP 服务器」「强制某代理」，只能逐台手工点 Settings。
- [IT] 无法审计/上报各机是否开了 MCP（key 存在 `~/Library/Application Support`，非托管域）。

**口径修正（重要，勿夸大）**：缺的是「集中管理」，不是「控制」本身。两个自动化面**各有用户级开关，且默认关**：
- MCP：`Settings › Automation › Let AI apps use Zigzag`，key = `AllowsAIApps`，`UserDefaults.standard.bool(forKey:)` 默认 false，关时端口完全不监听（`Zigzag/MCP/MCPService.swift:3-11`，`SettingsView.swift:1269,3475`）。
- AppleScript JS：`AllowJavaScriptFromAppleEvents`，默认 false（`Scripting.swift:11`）。

所以准确表述是：**「用户关得掉，企业无法统一关死」**。缺 MDM = 无集中下发/审计；不等于无任何控制。此点系 coordinator 复核时提出的精确化，采纳。

### 3.1 全量枚举：release 版不含任何 `ZIGZAG_*` 环境变量行为开关（本轮补 + eco-probe #155 修订）

为避免下一轮再有人把「某个 `ZIGZAG_*` 变量」当成企业管控闸门（coordinator #145 在 `ZIGZAG_BLOCK_NATIVE_MESSAGING` 上已栽过一次），此处给出**全仓枚举**而非单点结论。

**精确口径（本身已实测复核，首版 18 处为错）**：

```
grep -rn "processInfo.environment\|ProcessInfo.processInfo.environment" Zigzag/ --include=*.swift | wc -l   # 22 处读
grep -rln … | wc -l                                                                                          # 跳 16 个文件
grep -rhoE '"ZIGZAG_[A-Z_]+"' Zigzag/ --include=*.swift | sort -u | wc -l                                  # 24 个名
```

→ **24 个 `ZIGZAG_*` 名 = 16 个「读取」+ 8 个「仅写出」**。16 个读名**全部**在 `#if DEBUG` 内（多处配 `#else` 反向编译证据）；另 8 个仅在 `DownloadHandoff.swift:479-486` 向下载子进程**写出**，不从 `ProcessInfo` 读回。

**勘误（首版错，已修）**：首版写「18 处读」、表里仅列约 13 个变量——**偏小**。实测是 **22 处读 / 16 文件 / 24 名**。首版漏列了 `ZIGZAG_APPLICATIONS_DIR`、`ZIGZAG_WEBAPPS_DIR`、`ZIGZAG_STALL_MS`、`ZIGZAG_DEBUG_CHANNEL` 四个读名。结论不变（它们均在 DEBUG 内），但「全量」二字当时撑不住。此修由 eco-probe #155 逐文件实测指出，已采纳。

**16 个读名 → 包裹位置（全 `#if DEBUG`）**

| 变量 | 位置 | release 行为 |
|---|---|---|
| `ZIGZAG_BLOCK_NATIVE_MESSAGING` | `ExtensionHost.swift:1844` | `#if DEBUG`(`:1840-1850`)，`:1851` 直达 |
| `ZIGZAG_WASM_POLICY` | `ExtensionStore.swift:1549` | `#if DEBUG`(`:1547-1550`)→`:1551` `#available` |
| `ZIGZAG_HIGH_CONTRAST` | `Tokens.swift:1177` | `#if DEBUG`(`:1173-1178`)，不编译 |
| `ZIGZAG_SLOW_ANIMATIONS` | `Tokens.swift:996` | `#else return 1`(`:995-999`) |
| `ZIGZAG_STAY_BEHIND` | `ZigzagApplication.swift:14` | `#if DEBUG`(`:13-25`)，不编译 |
| `ZIGZAG_DATA_DIR` | `Paths.swift:12` / `DebugBridge` / `ExtensionHost` / `ImportCoordinator` | 全 `#if DEBUG` |
| `ZIGZAG_DEBUG_CHANNEL` | `DebugBridge.swift:30` / `ImportCoordinator.swift:91` | `DebugBridge` 类级 `#if DEBUG` |
| `ZIGZAG_DEBUG_COMMANDS` | `DebugBridge.swift:37` | 类级 `#if DEBUG` |
| `ZIGZAG_MUTE_ALL` | `DebugBridge.swift:11` | 类级 `#if DEBUG` |
| `ZIGZAG_FAKE_BROWSERS` | `ImportBatch.swift:93` / `ImportCoordinator` | `#if DEBUG` |
| `ZIGZAG_FAKE_SAFE_STORAGE` | `ChromiumImporter.swift:270` | `#if DEBUG`(`:266`) |
| `ZIGZAG_APPLICATIONS_DIR` | `AppBundledExtensions.swift:25` | `#if DEBUG`(`:24`) |
| `ZIGZAG_WEBAPPS_DIR` | `WebApp.swift:98` | `#if DEBUG`(`:97`) |
| `ZIGZAG_STALL_MS` | `Freezes.swift:32` | `#if DEBUG`(`:31`) |
| `ZIGZAG_TEST_VAULT` | `PasswordStore.swift:96` | `#if DEBUG`/`#else return nil`(`:95-100`) |
| `ZIGZAG_PAGE_PROBE` | `Tab.swift:559` | `#if DEBUG`(`:552-562`) |

**8 个写出名**（仅 `DownloadHandoff.swift:479-486`，`environment[…] =`，不从 `ProcessInfo` 读回）：
`ZIGZAG_LINK` `ZIGZAG_REFERRER` `ZIGZAG_FILENAME` `ZIGZAG_MIME` `ZIGZAG_SPACE` `ZIGZAG_COOKIES` `ZIGZAG_COOKIE_HEADER` `ZIGZAG_SECRET`。

**伪例外排除**：`AppDelegate.swift:66` 读 `XCTestConfigurationFilePath`——**不是 `ZIGZAG_*`**，是 Apple 测试框架变量，仅作 `isHostingTests`、**不 gate 任何行为**。若有人拿它反驳「零 env 开关」，用此条否掉。

> **定稿口径（可直接进 SUMMARY §4）**：
> **release 版不含任何 `ZIGZAG_*` 环境变量行为开关**：24 个 `ZIGZAG_*` 名中，16 个为「读取」且**全部**在 `#if DEBUG` 内（多处配 `#else` 反向编译证据）；另 8 个仅在 `DownloadHandoff` 向下载子进程**写出**，不从 `ProcessInfo` 读回。故企业无法经环境变量在发货版变更 Zigzag 行为。
>
> **致 eco-probe**：感谢 #155 把「18 处」拉到「22 处 / 16 文件 / 24 名」并补全 `#else` 反向证据——数字已全采，本表即为其数据的实测落地。本节现在可如实自称「全量」。

**补充裁定（@auto-probe 复核 @coordinator #145 所提 `ZIGZAG_BLOCK_NATIVE_MESSAGING`）**：coordinator 建议把 §4 再收一档为「有环境变量可禁用」，**此建议不采纳，因其踩了 DEBUG 门**。实测：

- `ZIGZAG_BLOCK_NATIVE_MESSAGING` 全仓**仅 2 处命中**，均在 `ExtensionHost.swift` 的 **`#if DEBUG`（`:1840`–`:1850`）块内**（`:1842` 注释、`:1844` `if env[...] == "1" { return nil }`）。
- Release 构建中该块被整体裁掉：`manifest(named:)` 从 `:1839` 直接跳到 `:1850` 之后的 release 分支 —— **发货版不存在此 kill switch**。
- 故「企业可经 MDM 下发环境变量禁用 nativeMessaging」在**发布版不成立**；该开关只服务于测试副本（`ZIGZAG_DATA_DIR`）。

→ 维持原结论：**无 policy plist、无 release 级集中禁用/审计**。企业管控仍只能逐台手工，或自行用 launchd wrapper 注入环境变量（属外部手段，非 Zigzag 提供的能力，且对 nativeMessaging 无 release 级开关可注）。

### 3.2 `compatibility.json` 的三套词汇表：同一个 key 在不同节有不同 `status`，互不可比（本轮实证，比「人工对口」更硬的根因）

eco-probe 在 #158 坦承把 `webRequest` 的 `patched` 读成 `bridged`（C 类：值对档错）。本节挖到**比「他看错字」更根本的结构原因**：文件里存在**三套互不兼容的 status 词汇表**，同一个 key 在不同节里可以同时「正确」却写成不同词。

```python
import json,collections
d=json.load(open('Zigzag/Resources/Extensions/compatibility.json'))  # schemaVersion: 1
# groups     47 条  statuses: NONE（只有 catalog/order）
# claims     49 条  statuses: native/patched/bridged/deprecated/unsupported
# permissions 41 条  statuses: supported/partial/unsupported
```

**同 key 双实体例（全文件多处，`webRequestBlocking` 不是特例）**：

| 位置 | 节 | 内容 | 词汇表 |
|---|---|---|---|
| `:109-110` | **`groups`** | `{"catalog": "extension.limit.webRequestBlocking", "order": 200}` | **无 status** |
| `:1038-1041` | **`permissions`** | `status: unsupported / reason: notImplemented` | `supported/partial/unsupported` |
| `.audit2/_unsupported.txt:75` | 导出 | 与 `:1038-1041` 一致 | — |

`webRequest` 本体：`claims.webRequest` @`:429-432` = `patched`/`js:webRequest`；`permissions.webRequest` @`:1032-1034` = `supported`。**两者都对**，因为它们回答的是不同问题：`claims` 问「如何实现」（原生/补丁/桥/仿真），`permissions` 问「用户获授后能不能用」（支持/部分/不支持）。

> **坐标更正（@verify-c #165 ④ 指出，已实测修正）**：上一稿此处写 `permissions:429`——**错**。`:429` 属 **`claims`**（`webRequest=patched`），`permissions` 的 `webRequest` 在 **`:1032`**（`supported`）。这是本轮**第三次**串节坐标错（前两次已在 §7.1 与本节上文自曝），性质同属「引用时手留在上一节」。文件已改用 **`节.key` @行号** 的双锚写法，以降低复发率（见下方新增断言 3）。

> **量化陷阱**：`claims ∩ permissions` 有 **29 个同名 key，其中 22 个 status 值不同**（如 `storage`: `native` vs `partial`；`cookies`: `patched` vs `partial`）。所以抄错节通常不会报错，**只会静默得到一个看似合理、实为另一维度的值** —— 这正是 C 类错误最隐蔽之处。
>
> **对我先前说法的修正（自查纠错，B 类）**：我上一稿写「只有 `permissions` 节带 status」——**错**。`claims` 也带 status，而且它才是 `webRequest=patched` 的出处。自己刚订正就踩了同类错，恰好证明本节结论：**必须指明「哪个节的 status」**，否则连作者都会串节。
>
> **断言 3（@verify-c #165 ③ 补丁，采纳并量化）**：当被引 key 在预期节中**不存在**时，**不得回退到其它节取值，应报「未在 <节> 定义」**。
>
> **实测人模（比单一反例更硬）**：`permissions` 中有 **12 个 key 不在 `claims`**：`clipboardRead` `contentSettings` `declarativeNetRequestFeedback` `declarativeNetRequestWithHostAccess` `downloads.open` `geolocation` `identity.email` `nativeMessaging` `readingList` `ttsEngine` `webRequestAuthProvider` `webRequestBlocking`。其中 **5 个同时在 `groups`**（`clipboardRead` `contentSettings` `geolocation` `readingList` `webRequestBlocking`）——回退就会拿到一个**无 `status`** 的实体且**不报错**。即：没有断言 3，这 5 个 key 各自都是一个静默取错值的入口，不是 `webRequestBlocking` 一例孤例。
>
> （附：`nativeMessaging` 只存于 `permissions`，不踩此坑，这与 eco-probe #163 的「支持」结论一致。）
>
> **可机械化的新结论（强于「全部 C 类都靠人工」）**：脚本可做三条断言：
> 1. 被引作「实现形态」的 key，必须来自 `claims`；被引作「可用性」的，必须来自 `permissions`；`groups` 引不得作 status 依据。
> 2. 被引 key 必须唯一定位到节（24 个 key 同时存在于 `groups`+`permissions`、**29 个同时存在于 `claims`+`permissions`**）。
> 3. **key 在预期节不存在 → 报错，不得回退跨节取值**（见上）。
> → 剩下真正只能人工的，是**同一节内**的档位误读（如 `patched`→`bridged` 都在 `claims` 内），而非全部 C 类。

---

## 4. MCP 能力边界

实现：`Zigzag/MCP/MCPTools.swift`（296 行），另 12 文件在 `Zigzag/MCP/`。端点 `http://127.0.0.1:39217/mcp`，Streamable HTTP，`Authorization: Bearer <key>`（`docs/automation.md:1-40`）。默认关，仅本机监听。

### 4.1 实际暴露的 16 个工具（`MCPTools.swift:22-67`）

| # | 工具 | 一句话作用 | 行 |
|---|---|---|---|
| 1 | `list_tabs` | 列出所有窗口的 tab（id/title/url/是否 active/窗口序/space），隐私窗永不列出 | :22 |
| 2 | `open_tab` | 在前台窗口新 tab 打开 http(s) 页并等加载完 | :24 |
| 3 | `activate_tab` | 切到某 tab（连带切 space 与窗口） | :28 |
| 4 | `close_tab` | 关 tab（destructive） | :29 |
| 5 | `navigate` | 在指定 tab 载入 http(s) 页并等加载 | :30 |
| 6 | `go_back` | 后退一页 | :32 |
| 7 | `go_forward` | 前进一页 | :33 |
| 8 | `reload` | 刷新 tab | :34 |
| 9 | `read_page` | 返回标题/url/可读正文 + 表单字段（**密码值永不返回**） | :35 |
| 10 | `get_links` | 页面上的链接（文本 + 地址） | :39 |
| 11 | `screenshot` | 页面当前 PNG（**tab 必须在前台可见**，先 activate） | :42 |
| 12 | `click` | 按 CSS 选择器或可见文本点击元素 | :44 |
| 13 | `type` | 向字段输入文本 / 选 `<select>` 选项，**不输密码框** | :47 |
| 14 | `scroll` | 页面或元素滚动 N 点 | :53 |
| 15 | `wait_for` | 等文本出现/消失、元素出现/消失、或加载完成 | :57 |
| 16 | `press_key` | 按键（Enter/Esc/Tab/方向键等）+ 修饰键，**只到页面，不进 Zigzag 快捷键** | :67 |

安全设计相当克制：隐私窗不入列、密码值不出、按键不进浏览器快捷键。

### 4.2 Chrome 有、MCP 没有的能力

Chrome 本身无 MCP，是通过 CDP 暴露；下列 CDP 域能力在 Zigzag MCP **没有对应工具**：

| CDP 能力 | Zigzag MCP | 影响场景 | 标注 |
|---|---|---|---|
| `Network.*`（抓请求、改响应、拦截） | **无** | 无法做 API 抓包、mock 响应、录制回放 | [开发] |
| `Console.*`（读 console 日志、异常） | **无** | 页面报错不可见，只能靠 `read_page` 猜 | [开发] |
| `Runtime.evaluate`（任意 JS） | **无**（MCP 面；但 AppleScript `do JavaScript` 有） | AI 无法跑任意脚本，只能组合 16 个原语 | [开发] |
| `Emulation.*`（UA/视口/地理位置/网络节流） | **无** | 无法模拟移动端/弱网 | [开发] |
| `Page.addScriptToEvaluateOnNewDocument`（注入脚本） | **无** | 无法在页面加载前注入 hook | [开发] |
| `DOM.*` / `Input.*` 的完整事件面（hover、拖拽、多点触控） | 部分（click/type/scroll/press_key） | 拖拽、hover 菜单、手势不可做 | [开发] |
| `Target.*`（多 target、iframe/worker 切换） | **无** | 只能操作顶层页面，进不了 iframe / WebWorker | [开发] |
| `Storage.*`（cookies/localStorage/session） | **无** | 无法脚本化登出、清 storage、导出 cookie | [脚本]/[开发] |
| `Browser.*`（窗口边界、下载管理） | 部分（list/close） | 无下载监听、无窗口尺寸 | [脚本] |
| `Fetch.enable` 请求拦截 | **无** | 无法做请求级自动化断言 | [开发] |

> 结论：Zigzag MCP 是**「浏览器操作原语集」**（够 AI 做「打开-读-点-填-等」），不是 **「调试协议」**。做 E2E 测试断言（网络、console、iframe、注入）跑不通。

---

## 5. WebKit 调试协议能否外露

### 5.1 事实（已独立复核，非转述）

三处 `isInspectable = true`：

1. **`Zigzag/Tabs/Tab.swift:571`** —— 主浏览 tab。
   - **复核结论：确实在 `#if DEBUG` 之外。** 最近的 `#if DEBUG` 在 `Tab.swift:552`，其 `#endif` 在 `:562`；`:571` 位于 562 之后、下一个 `#if DEBUG`（`:573`）之前。**即 Release 构建也 `isInspectable = true`。**
2. `Zigzag/Web/PopupWindowController.swift:251` —— 弹窗 WebView，无 `#if` 包裹，Release 亦开。
3. `Zigzag/Extensions/ExtensionHost.swift:554` —— 扩展 context，`context.isInspectable = true` **被 `#if DEBUG`/`#endif` 包裹（`:552`-`:562`）**，**仅 DEBUG**。

`_WKInspector`、`safaridriver`、`webinspectord` 字符串在源码中 **全仓零命中**（`grep` 仅回上述三处 `isInspectable`）。

### 5.2 这意味着什么（严谨表述）

- `isInspectable = true` 是 WebKit 对外**开放 remote inspection** 的标准开关。开启后，WKWebView 会注册到系统的 Web Inspector 通道（与 `com.apple.webinspector` / `webinspectord` 相关）。
- **可能的外部连接面**：Safari 的「开发」菜单、`safaridriver`、以及任何订阅该 inspector 通道的工具，有机会 attach 到这些 WebView。这等于**一条比 CDP 更原始、但能力更贴近调试器的通路**。
- **但**：源码里没有任何代码主动暴露端口、也没有 `safaridriver` 配套的 WebDriver 端点 —— Zigzag **不是** WebDriver 服务器。外部能否稳定连上，取决于 macOS WebKit 的 inspector 发现机制与用户是否在 Safari「开发」菜单里手动 attach。
- 我**没有实跑构建去验证 attach**（任务明令禁止构建），所以 §5.2 只能定性到「通道被打开」，不能断言「外部工具一定连得上」。这是**需要在有构建产物时实测的一条**（见 §6）。

### 5.3 差距定位

| | Chrome | Zigzag |
|---|---|---|
| 调试协议 | CDP，端口自定，协议稳定、文档全 | 无 CDP；仅 WebKit inspector 通道（非 WebDriver、无稳定协议文档） |
| 自动化驱动 | Selenium / Playwright / Puppeteer 全支持 | 均不支持（无 CDP、无 WebDriver） |
| 生产可调试性 | `--remote-debugging-port` 显式开，默认关 | **WebView 恒 `isInspectable = true`**（Tab、Popup），无开关 |

**安全侧提示 [IT]**：`Tab.swift:571` 与 `PopupWindowController.swift:251` 在 Release 恒开 inspectable，且**无**任何设置项/托管策略可关。结合 §3 无 MDM policy，企业无法集中禁用。

---

## 6. 未验证项（诚实标注）

- 「外部 `safaridriver`/Safari 开发菜单能否 attach 到 Release Zigzag 的 tab」—— 需真机构建实测，本轮禁构建，**未验证**。
- 「MCP 16 工具的实际行为是否与描述完全一致」—— 本轮只读 `MCPTools.swift` 定义，未运行服务器实测。
- Shortcuts：`grep "import AppIntents"` **零命中**（`Shortcuts.swift` 内无 AppIntent），故「Shortcuts 支持」应理解为 **Run AppleScript 走 AppleScript 字典**（`docs/automation.md:6`），而非原生 App Intents；这点可与文档措辞核对。

---

## 附：证据汇总（全部 `file:line`）

- AppleScript 字典：`Zigzag/Resources/Zigzag.sdef:1-228`（Standard Suite `:8`；Zigzag Suite `:124`；window 扩展 `:126`；tab 类 `:140`；tab 属性 `:142-172`；`do JavaScript` `:193`；其 `in` 参数 `:196`；`execute` `:202`）
- JS 门控：`Zigzag/App/Scripting.swift:11`（key）、`:96`（文案）、`:446`/`:455`（前后双重校验）
- 命令行：`Zigzag/App/main.swift:7`（唯一命中）；`ProcessInfo.processInfo.arguments` 全仓零命中
- 策略/MDM：`ManagedConfiguration|MDM|managedPreferences` 源码零命中（仅 HSTS 域名噪音）
- MCP：`Zigzag/MCP/MCPTools.swift:22-67`（16 工具）；`docs/automation.md:1-40`（端点与鉴权）
- Inspectable：`Zigzag/Tabs/Tab.swift:571`（Release 生效，夹在 `:562 #endif` 与 `:573 #if DEBUG` 之间）；`Zigzag/Web/PopupWindowController.swift:251`（Release）；`Zigzag/Extensions/ExtensionHost.swift:554`（仅 DEBUG）
- URL scheme：`Zigzag/Info.plist` 中 `CFBundleURLSchemes` = `http`/`https`（第 70-90 行区域）与 `zigzag-webapp`；处理入口 `Zigzag/App/AppDelegate.swift:329`（仅 file/http/https 放行，`:335`）

---

## 7. 独立复核与更正（@auto-probe 本轮签署）

上一轮已把主体审计落盘。本轮**独立重读全部被引用文件**逐条核对，发现 §1 正文行号与一处事实错误，均已在本轮修正。此处保留历史映射，便于溯源（**这些旧行号已不再出现在正文任何位置**）：

| 首版误写 | 实测正确行号 | 证据 |
|---|---|---|
| Zigzag Suite `:38` | **`:124`** | `grep -n 'suite name="Zigzag'` → 124 |
| window 扩展 `:39` | **`:126`** | `<class-extension extends="window">` @126 |
| tab 类 `:43` | **`:140`** | `<class name="tab" code="bTab" plural="tabs">` @140 |
| tab 属性 `:44-53` | **`:142-172`** | 10 个 `<property>` 首行 142…170，末属性闭合于 172（`responds-to` 起于 173） |
| `do JavaScript` `:54` | **`:193`** | `<command name="do JavaScript" code="ZgzgDoJS">` @193 |
| `in` 参数 `:56` | **`:196`** | `<parameter name="in" code="dcnm">` @196 |
| `execute` `:58` | **`:202`** | `<command name="execute" code="ZgzgExec">` @202 |
| header 注释 `:5-6` | **`:4-5`** | 首行注释起于第 4 行 |

### 7.1 两处不仅行号、是实质错误（已改）

1. **「window 缺 `bounds`/`visible`/`closeable`」——错**。window 全有：`bounds`:93、`closeable`:96、`miniaturizable`:99、`miniaturized`:102、`resizable`:105、`visible`:108、`zoomable`:111、`zoomed`:114（`Zigzag.sdef:92-114`）。真正缺口在 **tab 侧**（仅 10 属性）。已在 §1.4 修正并标注勘误。
2. **自律：自查盲区真实存在**。我首版附了勘误表，却没回填正文，造成文件内 `:38` vs `:124` 自相矛盾。coordinator 预测的盲区兑现了。本轮已把正文、勘误表、证据汇总三处全部对齐。

### 7.2 仍成立的断言

1. **动词数 12**：`grep -cE '<command name=' Zigzag.sdef` = 12（Standard 7：`open/close/quit/count/delete/exists/make` + Zigzag 5：`do JavaScript/execute/reload/go back/go forward`）。见上实测清单。
   - **纠正我上一条 board 消息**：我曾说「18 个动词」——错了，是 **12**。7+5=12，非 18。本条以文件为准。
2. **tab 属性恰 10 个**：`Zigzag.sdef:142-172` 实测 10 个 `<property>`。与 §1.3 表一致。
2. **MCP 工具数 16**：`grep -c 'tool("' MCPTools.swift` = 16；且 `grep 'cookie|header|network|storage|console|evaluate|pdf|mhtml' MCPTools.swift` 零功能命中 —— 印证 §4.2「无网络/存储/控制台/PDF 能力」。
3. **命令行零解析**：`grep -rn CommandLine Zigzag/` 仅 `main.swift:7`；`ProcessInfo.processInfo.arguments` 零命中。成立。
4. **企业策略零支持**：`grep -rni 'ManagedConfiguration|MDM|CFPreferences' Zigzag/` 无 policy 读取（命中项均为导航 `policy`/`WebRTCProtection`，非托管策略）。成立。
5. **isInspectable 的 DEBUG 边界（关键）**：
   - `Tab.swift:571` —— 在 `:562 #endif` 之后、`:573 #if DEBUG` 之前 → **Release 生效**（确认）
   - `PopupWindowController.swift:251` —— `grep '#if DEBUG' PopupWindowController.swift` **零命中** → **Release 生效**（确认）
   - `ExtensionHost.swift:554` —— 夹在 `:553 #if DEBUG` / `:555 #endif` 之间 → **仅 DEBUG**（确认）
   → 故「Release 恒开 inspectable」应精确为：**tab 页与 popup 页在 Release 恒开；扩展宿主页仅 Debug 开**。§0/§5 的表述基本准确，此处补细。
6. **`_WKInspector` / `safaridriver` / `webinspectord` / `com.apple.webinspector`**：`grep -rn` 全仓**零命中** —— Zigzag 自身不接任何 remote-inspector 桥，能力完全来自 WebKit 的 `isInspectable` 开关（§5 表述成立）。
7. **URL scheme 入口**：`AppDelegate.swift:329 application(_:open:)` 仅放行 `isFileURL` 或 `http/https`（`:335`）；`zigzag-webapp:` 由 `Zigzag/WebApps/WebApp.swift:39` 处理，属 App↔WebApp 内部通道，非通用脚本入口。成立。

**与 @verify-c 考题的接口（供其独立裁定）**：`MCPTools.swift` 的 `screenshot` 工具（`:42`）描述为 **PNG**；`PageScreenshot.swift:117-131` 实现为「整页渲染为 PDF 再转 PNG」。Chrome `chrome.pageCapture` 输出 **MHTML**。故 MCP/页面截图**不是** `pageCapture` 的等价物 —— 格式差异（PNG vs MHTML）与用途差异（像素图 vs 可归档文档）都成立。本报**不**声称 `pageCapture` 已被 Zigzag 实现。

> 本轮未改任何仓库源码，未构建。唯一写入 `.audit2/automation-gaps.md` 本节。
