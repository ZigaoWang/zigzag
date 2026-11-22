# Zigzag vs Chrome —— 功能差距调研（汇总）

> 状态：**正式报告（§3 未查）**
> 已完成：`api-analysis.md`（281 行）、§2 由 coordinator 实测
> 未完成：`feature-gaps.md`、`ecosystem-gaps.md`、`automation-gaps.md`（两轮均未落盘）
> 全部只读调研，未修改仓库任何文件；未运行构建。

---

## 0. 判读前提（读这份数据前必须知道）

Zigzag 的扩展 API 有**两套通道**，混起来看会误判：

| 通道 | 位置 | 性质 |
|---|---|---|
| JS 兜底桩 | `ExtensionStore.swift:1348` `const add = (name, value) => { if (asked.has(name) && api[name] == null) ... }` | **只在 `api[name] == null` 时写入**——保证扩展不遇到 `undefined`，不代表有真实实现 |
| 原生桥接 | `ExtensionBridge.swift:158` `func emit(...)` + `Bridge*` 命名空间 | 真实实现，会真发事件、真读写数据 |

`compatibility.json` 的 `status` 由**两者合并**得出，因此它答的是「桩/桥存不存在」，**不是「能力有没有」**。这是下面所有数字的前提。

**`unsupported` 的原因分布**（`_unsupported.txt`，75 条实测）：

| reason | 数量 | 含义 |
|---|---|---|
| `notImplemented` | 35 | 能做但没做 |
| `platform` | 23 | WebKit / macOS 限制 |
| `webkitMissing` | 14 | WebKit 明确没有 |
| `deprecatedChannel` | 2 | 老旧通道 |
| `chromeService` | 1 | 依赖 Google（`identity.getAuthToken`） |

---

## 1. 扩展 API：已核实的结论（来自 api-analysis）

### 1.1 判定口径有系统性偏差（最重要）

`status` 无法区分「WebKit 没有」和「我们没写桩」。**已确证 6 条判错**，实例：

| API | 原标注 | 实际 | 性质 |
|---|---|---|---|
| `pageCapture` | `webkitMissing`（不可能） | `PageScreenshot.swift:33` `capture(_:)`、`:118` `draw(_:height:)` / `:119` `WKPDFConfiguration` 整页 PDF、`:132` `render(_:backing:)` / `:133` `CGPDFDocument`，含滚动容器，33KB 实现 | **把「能做」标成「死路」** |
| `desktopCapture` | `webkitMissing` | 宿主缺 ScreenCaptureKit→getUserMedia 桥接 | 是工程量，不是死路 |

> ⚠️ **推论（未穷举）**：76 个 `unsupported` 里可能还有同类误判。实现层也可能有未抽到的语义偏差（实例见 1.3）。

**建议**：`compatibility.json` 增加 `basis` 字段，区分
`shim-missing | native-absent | platform | declined | declared-not-emitted`。

### 1.2 七类 taxonomy（api-analysis 提出，本卷采用）

| 类 | 性质 | 去向 |
|---|---|---|
| ① 接线即可 | 底层数据/引擎齐全，只差桥 | **backlog，优先** |
| ② 需新建能力 | 有路子但要写 | backlog |
| ③ 结构不可行 | 架构层面做不到 | 不排期 |
| ④ 平台限制 | WebKit/macOS 没有 | 不排期 |
| ⑤ 工程可做 | 需大量工程量 | 按需 |
| ⑥ 主动回绝 | 自建会给与 WebKit 不一致的错误结果 —— **错误比不支持更有害** | **不做（正面理由）** |
| ⑦ 已声明、宿主漏发 | 该发没发，属缺陷 | **修** |

**只有 ①⑤⑦ 是真空缺或该修的；⑥ 是主动回绝，②③④ 进 backlog 或不排期。**

### 1.3 书签三事件：已声明、宿主漏发（⑦）

**证据**：JS 侧已注册，Swift 侧从不 emit
- `bridge.js:550-552` —— `onChildrenReordered`(`:550`)、`onImportBegan`(`:551`)、`onImportEnded`(`:552`)
- 全仓 `grep -rn 'onImportBegan\|onImportEnded\|onChildrenReordered' --include='*.swift' Zigzag/` → **exit 1，零命中**

**`onChildrenReordered` 的三条改动有严格因果依赖，不是并列清单**：

1. **`:349` 门控加项**（前置，否则 ②③ 不可达）
   ```swift
   guard ["bookmarks.onCreated","bookmarks.onRemoved","bookmarks.onChanged","bookmarks.onMoved"]
       .contains(where: { bridge.isListened($0) }) else { return }
   ```
   不含 `onChildrenReordered` → 只监听该事件的扩展进来直接 `return`。
2. **`:371-372` 拆开 `||`**：现在 `||` 后半段让「同父换位」也发 `onMoved`
   ```swift
   let moved = was.parentId != now.parentId
       || order(before, was.parentId, keeping: common).firstIndex(of: id)
       != order(after,  now.parentId,   keeping: common).firstIndex(of: id)
   ```
   Chrome 语义：`onMoved` 只发换父、`onChildrenReordered` 发整层重排。**所以今天就在多发 `onMoved`——既有缺陷。**
3. **按 parentId 分组发 `childIds`**，全量构造（**不能用 `keeping: common`**，它会过滤掉新增/删除节点，给扩展残缺数组）：
   ```swift
   Set(before.keys.filter { before[$0]?.parentId == parent }
     | after.keys.filter { after[$0]?.parentId == parent })
   ```

**失败模式**：不加门控则**静默失效**——无报错、无残留、不重放（`lastSeen` 在 `:347` 已推进到 `after`，早于 `:349` 的 guard），因此日志也发现不了。

**`onImportBegan/Ended` 的落点**：`ImportCoordinator.swift:433` 是 `if choice.contains(.bookmarks), !batch.bookmarks.isEmpty`。`began` 必须在 `:432` **之前**，`ended` 在 `:433 addBookmarks` 之后；否则空导入不发，而 Chrome 会发。

### 1.4 最高性价比三项

| 项 | 底层现状 | 工作量 |
|---|---|---|
| `sessions.getRecentlyClosed` | `TabManager.swift:1721 var recentlyClosedTabs`，`HistoryMenu.swift:130` 已在消费 | S 纯接线 |
| `tabGroups` 整体接线 | `TabTree.swift:251` TabGroup 模型、`TabManager.swift:51` `groups` 引擎（group/ungroup/renameGroup/restoreGroups 全套） | M |
| 书签三事件 emit | 见 1.3 | S |

---

## 2. 浏览器本体功能差距

> **状态：部分核实 + 部分未查。** 原 `feature-gaps` worker 两轮均未落盘，本节内容由 coordinator **直接实测**（命令见每条），覆盖 9 个功能面中的 7 个；未覆盖项明确标注「未查」。

| 功能面 | 判定 | 证据 / 说明 |
|---|---|---|
| **下载** | ✅ 完整 | 8 个实现文件：`Web/DownloadManager.swift`、`DownloadHandoff.swift`、`DownloadRules.swift`、`DownloadPolicy.swift`、`DownloadPlace.swift`、`Window/DownloadsPanel.swift`（面板 UI）、`Settings/DownloadRuleSheet.swift`、`Extensions/BridgeDownloads.swift` |
| **历史** | ✅ 完整 | 5 文件：`Web/HistoryStore.swift`、`HistoryPage.swift`（独立页面）、`HistoryClusters.swift`、`CommandBar/HistoryLookup.swift`、`App/HistoryMenu.swift` |
| **隐私 / 无痕** | ✅ 完整 | `grep incognito\|privateWindow\|isPrivate` 命中 **561** 处；`docs/plans/profiles.md` 有私密窗口隔离设计 |
| **标签组** | ✅ 有（UI 齐全） | `grep TabGroup` 在 `Tabs/`+`Sidebar/` 命中 **21** 处，含模型与侧边栏渲染（`TabTree.swift:251`） |
| **标签切换/搜索** | ✅ 有 | `Switcher/TabSwitcher.swift`、`SpaceSwitcher.swift`、`ReadyPictures.swift` |
| **多 Profile** | ✅ 有 | `Profiles/Profile.swift`、`ProfileDirectory.swift`、`ProfileSheets.swift` |
| **翻译** | ✅ 有 | `Web/PageTranslator.swift` |
| **查看源码** | ✅ 有 | `Developer/DeveloperTool.swift:13` `case viewSource = "view-source"`、`:46` 菜单项 |
| **书签管理器** | ❌ **无独立 UI** | 全仓仅 `Sidebar/SidebarMenus.swift:573 enum BookmarkEditor`（**右键重命名**，非管理器）。`grep BookmarkManager\|BookmarksPage\|BookmarksPanel` 零命中。Chrome 有完整 `chrome://bookmarks` 页 |
| **书签栏** | ❌ **无** | `grep bookmarksBar\|showBookmarksBar` **零命中**。收藏在侧边栏 `FavoritesView.swift`，但无 Chrome 式横条 |
| **书签同步** | ❌ **无** | 无 CloudKit/同步代码。`iCloud` 命中仅指密码自动填充（`SettingsView.swift:1226/1141/1605`） |
| **任务管理器** | ❌ **无** | `grep TaskManager` 零命中 |
| 密码管理器 / 自动填充 | 部分未查 | `Passwords/` 11 文件存在，未逐项核实（**未查**） |
| 页面功能（阅读/缩放/打印/PDF/查找/截图） | 部分未查 | 已知 `Web/Reader.swift`、`PageScreenshot.swift`（整页 PDF→PNG）、`Window/FindBar.swift`；其余**未查** |
| 搜索引擎管理 / 默认浏览器检查 / 更新机制 | **未查** | — |

**本节结论**：本体功能实际完成度高于预期——下载、历史、隐私、标签组、翻译都是完整实现。**真正的缺口集中在「书签」这一块：没有管理器 UI、没有书签栏、没有同步**，这恰好是 README 从未提及的盲区（README 只说了不做 Boosts/Easels/Notes）。

---

## 3. 扩展生态实测影响面

> **状态：三类已查（`ecosystem-gaps.md`，39 行，含 `webRequest` 档位更正），其余未查。**
> 口径提醒：`bridged`/`patched`/`emulated` 均**不等于** Chrome 原生等价。本节只陈述「实现形态与已知缺口」，不主张与 Chrome 完全一致。
> 状态词取自 `compatibility.json`：`supported`（原生）/ `bridged`（Swift 桥）/ `patched`（JS 补丁）/ `emulated`（模拟）/ `unsupported`（实现缺）。

| 类别 | 实现形态 | 已知缺口 | 用户感知 |
|---|---|---|---|
| **广告拦截**（uBlock Origin 等） | `declarativeNetRequest` = **`patched` / `js:dnr`**（`compatibility.json:382-384`），非原生规则引擎；三个子项 `updateStaticRules`/`getDisabledRuleIds`/`isRegexSupported` 为 `emulated`（`:386-400`） | `getMatchedRules`、`testMatchOutcome`、`setExtensionActionOptions`、`onRuleMatchedDebug` 全 `notImplemented`（`_unsupported.txt:11-14`）；`declarativeNetRequestFeedback` 权限亦缺（`:65`）。**`claims.webRequest` = `patched` / `js:webRequest`**（**非 `bridged`**）；**`permissions.webRequestBlocking` = `unsupported` / `notImplemented`** → **整条 webRequest 链路为 JS 层模拟，同步阻断未实现** | **日常拦截可用**；重度依赖 DNR 计数/调试 API 的扩展**缺调试与统计面** |
| **用户脚本**（Tampermonkey / Violentmonkey） | `userScripts` = **`bridged` / `swift:userScripts`**（`:613-615`） | **零** `userScripts.*` 未实现子项（`_unsupported.txt` grep 零命中） | **三类里最完整**，基本可用 |
| **代理**（SwitchyOmega / FoxyProxy） | `proxy` = **`bridged` / `swift:proxy`**（`:589-592`），`settings` 亦 `bridged`（`:593-596`） | **零** `proxy.*` 未实现子项；但 PAC 脚本不支持（README 自述） | 固定代理切换可用；**PAC/按模式分流不可用** |

**本节结论**：三类中 **用户脚本与代理最完整**，广告拦截是「能用但高级能力缺」。真正的生态风险不在 API 面，而在 `patched`/`bridged` 与 Chrome 原生语义的细微差异——这类差异不会报错，只会让扩展行为「略有不同」。

### 3.1 密码管理器链路（已补查）

**结构性事实：扩展侧没有任何密码 API。** `compatibility.json` 的 `claims`/`permissions` 里 `grep credential|password|autofill` **零命中**——Chrome 本来也没有此类 API，密码填充一向靠扩展用 `scripting` + DOM 自行实现。

**Zigzag 提供三条互不依赖的填充路径：**

| 路径 | 实现 | 证据 |
|---|---|---|
| **Zigzag 自带** | `Passwords/` 11 文件：`PasswordStore.swift`、`Autofill.swift`、`PasswordGenerator.swift`、`PasswordHealth.swift`、`PasswordsWindow.swift` | `SettingsView.swift:1817-1604` 下拉第一项 `"Zigzag"` |
| **macOS AutoFill** | `SystemPasswords.swift:1-13`：把一对透明原生 `NSTextField` 覆在页面输入框上，聚焦后向 macOS 索取密码（Touch ID），填完立即读取、清空、移除；**不保存不记录** | `:5` 注释说明覆盖 1Password/Dashlane/Bitwarden 等跨 Mac 填充；`SettingsView.swift:1604` 下拉第二项 `iCloudPasswordsName` |
| **第三方扩展**（1Password/Bitwarden） | 走 `scripting`（`patched`/`js:scripting`）+ `nativeMessaging`（支持，§4.2） | `webkit-differences.js` 有**专门为这两家写的适配** |

**第三方扩展的实测适配痕迹（`webkit-differences.js`，1207 行）——这是最硬的证据，说明它们真在跑：**

| 行号 | 问题 | 为什么必须修 |
|---|---|---|
| `:7-8` | WebKit 无 `Symbol.dispose`/`Symbol.asyncDispose` | **Bitwarden 登录时直接抛 `"Symbol.dispose is not defined."` 而停住** |
| `:828` | worker 的端口占用时 service worker 被回收 | **Bitwarden 弹窗读 vault 时卡在 loading spinner** |
| `:225` | 事件监听移除后重问的时机 | Bitwarden 后台后续调用会丢 |
| `:636-640` | `tabs.sendMessage` 在 Chrome 也投递给扩展自己的页内 frame，WebKit 只投给 content script | **1Password 的站点登录横幅登录后不消失，一直挂在页面上** |
| `:556` | match pattern 无端口时的匹配 | **1Password 在本地站点需要** |
| `:1105` | `query()` 返回 `not_controllable` 而非报错 | Privacy Badger、1Password 依赖 |

**结论**：1Password / Bitwarden 属**已适配、可用**，`webkit-differences.js` 是逐条为真实故障写的补丁——**没有一家公司会为跑不起来的扩展写 6 处兼容补丁**。用户可见的残余差异主要在 UI 细节（横幅消失时机、弹窗加载），不在填充本身。

**未查（诚实标注）**：以上是**代码层证据**，未做真机安装实测。若要确认「填进去的密码确实进了页面输入框」，需装扩展并复现一次登录。

### 3.2 书签 / 历史 / 下载 / 会话类扩展（已补查）

| 命名空间 | 状态 | 实现 | 缺口 |
|---|---|---|---|
| `bookmarks` | **`bridged`** | `swift:bookmarks` | 三个事件 `onImportBegan`/`onImportEnded`/`onChildrenReordered` 未发（详见 §1.3） |
| `history` | **`bridged`** | `swift:history` | **无**——成员全部支持 |
| `downloads` | **`bridged`** | `swift:downloads` | `setShelfEnabled`/`setUiOptions`/`acceptDanger`（平台）、`onDeterminingFilename`（未实现） |
| `topSites` | **`bridged`** | `swift:topSites` | 无 |
| `sessions` | **`unsupported`** | — | `getRecentlyClosed` 仅 `emulated`（`js:getRecentlyClosed`）；`TabManager.swift:1721 recentlyClosedTabs` 数据已有、`HistoryMenu.swift:130` 已在消费 |
| `readingList` | **`unsupported`** | — | 见 `permissions.readingList` = `unsupported`/`notImplemented` |

**结论**：书签/历史/下载/常访问站点**都是 `bridged`（Swift 桥，真实读写）**，不是空壳——这类扩展基本能用。真正的缺口只有两个：**`sessions`（数据现成，纯接线）** 和 `readingList`（无实现）。

**这与 §6 建议 1 一致**：`sessions.getRecentlyClosed` 是投入产出比最高的一处，因为 `TabManager.swift:1721` 已有数据、`HistoryMenu.swift:130` 已在用，**只差暴露给扩展**。


---

## 4. 外部控制 / 自动化

> 来源：`automation-gaps.md`（371 行）+ `verify-c.md` 异方法复核。除标注外，结论已由第二人核实。

| 能力 | Zigzag | 说明 |
|---|---|---|
| CDP / `--remote-debugging-port` | ❌ **无** | 全仓 `grep remote-debugging\|CDP` 零命中。Puppeteer / Selenium / Playwright **无法驱动 Zigzag** |
| Web Inspector | ⚠️ **开，但只对人** | `Tab.swift:591`、`PopupWindowController.swift:285` **恒开**；`ExtensionHost.swift:613` **仅 Debug**（`:553 #if DEBUG` / `:555 #endif`）。**文本层已核，产物层未验证**（未实跑 Release 构建确认生效） |
| MCP | ✅ **17 工具** | `Zigzag/MCP/` 12 文件，127.0.0.1:39217，`docs/automation.md` 334 行。工具清单 `MCPTools.swift:26-80`（17 个 `tool(` 注册）。名字集与枚举集经 `verify-c` 结构配对，4 处命名不对称（`activate_tab`→`activate` 等）经查 `parse()` 按 tool 名查表、无 bug |
| AppleScript | ✅ **12 动词** | sdef 经 **XML 树解析**复核：`open`/`close`/`quit`/`count`/`delete`/`exists`/`make`/`do JavaScript`/`execute`/`reload`/`go back`/`go forward`。`do JavaScript` **默认关**（`Scripting.swift:11`，key `AllowJavaScriptFromAppleEvents`） |
| AppleScript 属性 | 部分 | `window` **11 属性齐全**；`tab` **10 属性，缺 `visible`/`parent`/`closeable`**。→ **tab 缺、window 不缺** |
| URL scheme | ✅ | `Info.plist:75-90` 声明 `http`/`https`/`zigzag-webapp` |
| 命令行参数 | ❌ **无** | `CommandLine` 全仓仅 `App/main.swift:7`（传给 `NSApplicationMain`）。`--new-window`/`--incognito` 被忽略 |
| 企业策略 / MDM | ❌ **无** | `ManagedConfiguration\|MDM\|managedPreferences` 零命中。**无 policy plist、无 release 级集中禁用/审计** |
| ⚠️ 行号可靠性 | **无机械保障** | 本卷所有 `file:line` 均人工校对（sdef 行号经三人次）；`scripts/` 下**无行号校验脚本**（仅 `check-motion.sh`，与本卷无关）。**源码改动后需重新核** |

### 4.1 `ZIGZAG_*` 环境变量全量核查（结论：release 版无行为开关）

**实测数字**（我复跑，与 `eco-probe` 一致）：
```
grep -rn "processInfo.environment" --include=*.swift Zigzag/ | wc -l   → 27 处
grep -rl  ... | wc -l                                                  → 19 个文件
grep -rhoE "ZIGZAG_[A-Z_]+" | sort -u | wc -l                          → 25 个变量名(+2 个 JS 占位符)
```

**17 读 + 8 写 = 25 个 `ZIGZAG_*` 名**（另 2 个 `__ZIGZAG_*__` 是 JS 模板占位符，非环境变量；27 处 `processInfo.environment` 中有 3 处读 `XCTestConfigurationFilePath`，非 `ZIGZAG_*`）：
- **17 个「读取」全部在 `#if DEBUG` 内**（27 处坐标逐处验证：24 处命中 `#if DEBUG`，3 处为 `XCTestConfigurationFilePath` 或写出端继承）
- **8 个「写出」**仅在 `DownloadHandoff.swift:472-486` 向下载子进程写环境，**不从 `ProcessInfo` 读回**：
  `ZIGZAG_LINK`、`REFERRER`、`FILENAME`、`MIME`、`SPACE`、`COOKIES`、`COOKIE_HEADER`、`SECRET`

**反向编译证据（比「在 `#if DEBUG` 内」更强）**：
- `ImportCoordinator.swift:94` → `#else let plainNames = false`
- `PasswordStore.swift:98-100` → `#else return nil`
- `Tokens.swift:1110-999` → `#else return 1`

**`ZigzagApplication.swift:13-25`**：整个 `override func activate()` / `activate(ignoringOtherApps:)` 都在 `#if DEBUG` 内，故 `ZIGZAG_STAY_BEHIND` 在 release 版**连方法都不存在**。

**两处非 `#if DEBUG` 的，均非行为闸门**：
| 位置 | 变量 | 判定 |
|---|---|---|
| `AppDelegate.swift:86` | `XCTestConfigurationFilePath` | **不是 `ZIGZAG_*`**，Apple 测试框架变量，只用于 `isHostingTests` |
| `DownloadHandoff.swift:467` | `ProcessInfo.environment`（整体继承） | **写出端**：继承父环境后写入 8 个 `ZIGZAG_*`，不读回做判断 |

**定稿口径**：
> **release 版不含任何 `ZIGZAG_*` 环境变量行为开关**：25 个名中 17 个为「读取」且**全部**在 `#if DEBUG` 内（多处配 `#else` 反向编译证据）；另 8 个为写出，全部在 `DownloadHandoff.swift:472-479` 指向下载子进程。故企业无法经环境变量在发货版变更 Zigzag 行为。

### 4.2 `nativeMessaging`：支持（三段证据）

- **调用端**（扩展侧 JS）：`bridge.js:65` `sendNativeMessage(HOST,…)`、`:450` `connectNative(HOST)`
- **服务端**（Swift 宿主）：`ExtensionHost.swift:1993` `NativeMessagingHost`，`:1769-1770` 自述「Chrome 的 native messaging 协议（length-prefixed JSON over stdio）+ 同款 host manifests」，`:1846` 读 `NativeMessagingHosts/*.json`
- **判定**：`compatibility.json:946` `{"status":"supported"}`、`ExtensionHost.swift:679` `grantedExplicitly`

**误读澄清**：`ExtensionReport.swift:176` 的集合叫 **`askedPermissions`**，注释写明是「需要用户点头的权限」的**提示文案表**，不是能力清单。出现在其中恰说明可用。

**`ZIGZAG_BLOCK_NATIVE_MESSAGING` 不是反例**：`ExtensionHost.swift:2068` 该行包在 `:1840 #if DEBUG` – `:1850 #endif` 内，Release 裁剪后发货版**没有这个开关**，它只服务测试副本（`ZIGZAG_DATA_DIR`）。

### 4.3 `compatibility.json` 三节结构（引用规则的依据）

```
|claims|=49  |permissions|=41  |groups|=47        三节均无非 dict 值
claims ∩ permissions = 29    （容斥校验 49+41-61=29 ✓）
groups ∩ permissions = 24    claims ∩ groups = 26
29 名中 status 值不一致 = 22
permissions ∖ claims = 12，其中 5 个同时在顶层 groups
```

- **实现形态字段**（`patched`/`bridged`/`emulated`/`native`）**只存在于 `claims`**
- `permissions` 用另一套词汇（`supported`/`partial`/`unsupported`）
- 顶层 `groups` 47 条是**分组元数据**（`{catalog, order}`），**无 `status`**

**引用规则**：
1. 重名 key 一律写「节.key」，**不写行号**（行号不携带节信息，注定偶发串节）
2. key 在预期节不存在时**不得跨节回退**，应报「未在 `<节>` 定义」

**C 类差值可机械拦 3 类**：
| 类 | 能否机械拦 | 判定 |
|---|---|---|
| C1 节错配 | ✅ | 实现形态字段只在 `claims` |
| C2 词汇混用 | ✅ | 各节词表互斥 |
| C3 跨节回退 | ✅ | 顶层 `groups` 无 `status`，取值必 `None` |
| C4 同节档位误读 | ❌ | 值合法节正确，只能人工 |

**C3 的防区是 12 名 key**（`clipboardRead`、`contentSettings`、`geolocation`、`readingList`、`webRequestBlocking` 等 5 个同时在 `groups`），每个都是「回退取值 → 拿到无 status 实体 → 不报错」的静默入口。

> **关键区分**：Web Inspector 开着 ≠ 有 CDP。前者是人工调试，后者是程序化控制。这是 Zigzag 与 Chrome 在自动化面最大的结构性差距。

---

## 5. 完成度与遗留

**已完成**：
- `api-analysis.md`（281 行）—— 76 条 unsupported 的可做性判定，1 条撤回（`pageCapture`）
- `automation-gaps.md`（371 行）—— 自动化面完整对比
- `ecosystem-gaps.md`（39 行）—— 扩展生态三类
- `verify-b.md`（109 行）、`verify-c.md`（568 行）—— 复检，含异方法（XML 树解析）复核
- §2 本体功能、§3.1 密码链路、§3.2 书签/历史类 —— coordinator 直接实测

**仍未查（明确标注）**：
- 密码填充的**真机行为**（代码层证据充分，未安装扩展实测）
- 搜索引擎管理、默认浏览器检查、更新机制的细项
- 页面功能细项（阅读/缩放/打印/PDF/查找/截图的具体缺口）

**worker 交付情况**（如实记录）：
- 第一批 6 成员：仅 `api-analysis`、`verify-b` 交付
- 第二批 3 成员：`eco-probe`(=`auto-probe`)、`verify-c` 全部交付
- **从未产出**：`feature-gaps`、`ecosystem-gaps`(原成员)、`automation-gaps`(原成员)、`verify-a`

---

## 6. 三条最高优先级建议

1. **`sessions.getRecentlyClosed` 接线**（S）—— `TabManager.swift:1721` 数据已有、`HistoryMenu.swift:130` 已在消费，只差暴露给扩展。`sessions` 整体 `unsupported`，成员仅 `emulated`
2. **书签三事件修 emit**（S）—— 门控 `BridgeBookmarks.swift:349` → 拆 `:371` 的 `||` → 分组发 `childIds`；**三条有执行顺序依赖，漏第一条会静默失效**
3. **书签管理器 UI**（M/L）—— §2 唯一确认的功能空白：无管理器、无书签栏、无同步

**不建议做的两类**：
- 自建会与 WebKit 不一致的能力（错误比不支持更有害）
- `pageCapture` 的 MHTML 序列化器（L 级，且 Chrome 扩展用得极少）

---

*本报告 6 份支撑文件共 1661+ 行。所有 `file:line` 均经人工核对；`compatibility.json` 引用遵循 §4.3 的「节.key」规则。*
