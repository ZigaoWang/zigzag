# api-analysis —— 75 条 unsupported 扩展 API 的可做性判定

只读分析。除本文件外未修改仓库任何文件，未构建。

## 0. 方法与关键机制（先说清楚，否则下面的判定会被误读）

这个仓库里「API 是否可用」有**两条并行通道**，claim 的 `notImplemented` 判定大多只看第一条：

1. **JS 兜底桩（fallback shim）** — `Zigzag/Extensions/ExtensionStore.swift` 注入的 prelude。
   - MV2 回调式：`ExtensionStore.swift:928`
     `const add = (name, value) => { if (asked.has(name) && api[name] == null) {...} }`
   - MV3 Promise 式：`ExtensionStore.swift:1328` / `1357`
     `const add = (name, value) => { if (!api[name]) {...} }`
   - **关键点：`add` 只在 `api[name] == null` 时才写入。** 也就是说桩是"原生没给才补"的兜底。
   - 桩里的 `no('…')` 只是**错误文案兜底**，不代表能力真的不存在。
2. **原生 Bridge 命名空间** — `BridgeNamespace` 协议族，`Zigzag/Extensions/Bridge*.swift`。

**因此 claim 里凡是 "桩里写了 `no()`" 就判 `notImplemented` 的条目，有相当一部分在原生 Bridge 里已经实现了。** 这是本次分析最重要的发现来源。

原生已注册的 Bridge 命名空间（`grep 'static let name'` 实测）：

```
bookmarks contextMenusKept contexts downloads extensionFetch favicons history
identity idle notifications offscreen power proxy runtime sidePanel
system.display tabCapture topSites tts userScripts webRequest
```

前端侧 `Zigzag/Resources/Extensions/bridge.js`（965 行）用 `install('name', {...})` 把这些命名空间暴露给扩展，走 `method(ns, fn)` 转发。

WebKit 侧硬边界（判 `webkitMissing` 时应以此为据）—— macOS SDK
`WebKit.framework/Headers/WKWebExtensionPermission.h` 的**全部权限令牌**只有 17 个：

```
ActiveTab Alarms ClipboardWrite ContextMenus Cookies DeclarativeNetRequest
DeclarativeNetRequestFeedback DeclarativeNetRequestWithHostAccess Menus
NativeMessaging Scripting Storage Tabs UnlimitedStorage WebNavigation WebRequest
```

没有 fonts / debugger / tabGroups / sessions / notifications / system.display —— 这验证了绝大多数 `webkitMissing` 判定成立。

---

## 1. 35 个 `notImplemented` 逐条判定

判定三档：**接线即可**（底层数据/能力已在，只差把 Bridge 方法接上）、**需新建能力**（要写新的宿主能力）、**不建议做**（原因单列）。
工作量：S ≈ 只改 1 处 Bridge 方法；M ≈ 改 1–2 文件 + 已有数据模型映射；L ≈ 新增子系统。

### A. 已经有原生 Bridge 实现 —— claim 判错，属「误标 notImplemented」

| # | API | group | Chrome 作用 | Zigzag 现状（证据） | 判定 | 量 |
|---|-----|-------|-------------|---------------------|------|----|
| 1 | `bookmarks.onImportBegan` | bookmarks | 书签导入开始时通知扩展 | **bridge.js:252 已注册该事件**；但 Swift 侧全仓无任何 emit（`grep onImportBegan` 仅命中 bridge.js:252） | **接线即可**（注册了但宿主从不 emit ⇒ 需在导入流程补发） | S |
| 2 | `bookmarks.onImportEnded` | bookmarks | 导入结束通知 | 同上，bridge.js:253 | **接线即可** | S |
| 3 | `bookmarks.onChildrenReordered` | bookmarks | 同层子节点重排通知 | 同上，bridge.js:251 | **接线即可** | S |
| 4 | `downloads.onDeterminingFilename` | downloads | 扩展干预下载文件名 | 桩里 `event()`（`ExtensionStore.swift:987`）；`BridgeDownloads` 全量实现 download/search/pause/cancel/erase/open/getFileIcon（`BridgeDownloads.swift:27-67`），但**没有** filename 决策回调 | **需新建能力**（下载器要在落盘前询问扩展；侵入 `DownloadPlace`/`DownloadManager`） | M |
| 5 | `sidePanel.getLayout` | sidePanel | 读侧栏布局 | `BridgeSidePanel` 已实现 setOptions/getOptions/open/close（`BridgeNamespaces.swift:1557+`，bridge.js `install('sidePanel')`） | **接线即可**（补一个 getLayout 返回值） | S |
| 6 | `permissions.addHostAccessRequest` | permissions | 运行时请求站点权限 | **MV3 prelude 已实现为空操作**：`ExtensionStore.swift:1378` `addTo('permissions', { addHostAccessRequest: async () => {}, removeHostAccessRequest: async () => {} })` | **接线即可**（行为已经"不报错"，要真做需接 `PermissionPolicy`） | S |
| 7 | `permissions.removeHostAccessRequest` | permissions | 撤销站点权限请求 | 同上 `:1378` | **接线即可** | S |
| 8 | `tabs.group` | tabGroups | 把标签归组 | **全量组引擎已在**：`TabManager.makeGroup(with:name:)` `:2218`、`ungroup` `:2258`、`renameGroup` `:2266`、`setGroupOpen` `:2274`、`setGroup(of:to:)` `:2282`、`moveGroup` `:2301`；模型 `TabGroup` `TabTree.swift:251`；`Tab.groupID` `Tab.swift:81`。桩里却是 `group: no('Tab groups')`（`ExtensionStore.swift:932`） | **接线即可**（成色最好的一条） | M |
| 9 | `tabGroups`（命名空间整体） | tabGroups | 分组命名空间 query/get/update/move + 事件 | 同上引擎 + `tabGroups(in:)` `:2198`、`group(_:)` `:2190`、`tabs(inGroup:)` `:2193`；bridge 里无对应 install | **接线即可** | M |
| 10 | `tabGroups`（perm 条目） | tabGroups | 同上（权限项） | 同上 | **接线即可** | S |
| 11 | `sessions.getRecentlyClosed` | sessions | 列出最近关闭的标签/窗口 | **底层数据已在**：`TabManager.closedTabs` `:34`，`recentlyClosedTabs` `:1468`（含 id/url/title）。但桩是 `getRecentlyClosed: done([])`（`:990`）——**硬编码返回空** | **接线即可**（最有用户感知的一条） | S |
| 12 | `sessions`（命名空间） | sessions | sessions 命名空间 | `reopenClosedTab(_:)` `:1474` 即 restore 原语；`BridgeNamespaces` 无 sessions | **接线即可**（getRecentlyClosed + restore；getDevices 可作空） | M |
| 13 | `sessions`（perm 条目） | sessions | 同上权限项 | 同上 | **接线即可** | S |
| 14 | `webRequestBlocking` | webRequestBlocking | MV2 阻塞式改写请求 | **已真实支持**：`BridgeWebRequest.swift:143` `return allows("webRequestBlocking") \|\| allows("webRequestAuthProvider")`，`mayAnswer` `:140-145` 完整判定 MV2/MV3 | **接线即可 / claim 判错**（仅 auth 场景生效，非通用阻塞） | S |
| 15 | `ttsEngine` | tts | 让扩展自建 TTS 引擎 | **`chrome.tts` 已用 AVSpeechSynthesizer 全量实现**：`BridgeSpeech`（`BridgeNamespaces.swift:722`，`static let name = "tts"`，speak/stop/pause/resume + `onEvent`）。ttsEngine 是"扩展提供语音"，需反向调用扩展 JS | **需新建能力**（方向相反，宿主→扩展回调） | M |
| 16 | `geolocation` | geolocation | 扩展读用户位置 | 位置**授权**已存在：`SitePermissions.location(origin:)` `:348`、`locationDecisions` `:301`。但"给扩展一个坐标"没有 CLLocationManager 实现（`grep CLLocationManager` 全仓 0 命中） | **需新建能力**（要接 CoreLocation + 权限申请） | M |

> 说明：1/2/3 三条本质是「**已声明、宿主漏发**」，与"API 不存在"是不同性质；建议单列一类（标识符 `declared-not-emitted`），否则修复优先级会被误判。

### B. 真正缺失，但值得做

| # | API | group | Chrome 作用 | Zigzag 现状 | 判定 | 量 |
|---|-----|-------|-------------|-------------|------|----|
| 17 | `tabs.createSplit` | tabActions | 把两个标签并排显示 | **拆分引擎已在**：`TabManager.tile(_:beside:_:)` `:1751`、`split(for:)` `:1706`、`makeGroup(_:shape:)` `:1797`。但 WebKit 的 `WKWebExtensionTabConfiguration.h` **只有** window/index/parentTab/url/shouldBeActive/shouldAddToSelection/shouldBePinned/shouldBeMuted/shouldReaderModeBeActive —— **没有 split/position 字段**，所以不能走 WebKit 的 create | **需新建能力**（需自建 tabs 命名空间覆写，绕开 WKWebExtension 的 tab 创建） | M |
| 18 | `tabs.unsplit` | tabActions | 解除并排 | `TabManager.unsplit(_:notify:)` `:1895`、`unsplit(_:keep:)` `:1905` 已有 | **需新建能力**（同 #17 的桥接路线） | S |
| 19 | `omnibox` | omnibox | 扩展接管地址栏关键词 | 地址栏与搜索完全在：`CommandBarModel.swift:429`（`Library.shared.searchEngine`）、`open(Library.shared.searchEngine.searchURL(query), search: true)` `CommandBarController.swift:1088`、`SiteSearch.swift`。但**没有"扩展注册关键词"的挂点** | **需新建能力**（要在 CommandBarModel 里插一层扩展关键词解析） | L |
| 20 | `search` | search | 读写默认搜索引擎 | 引擎模型已在：`Library.shared.searchEngine`；无写入接口 | **接线即可**（读：现成；写：`= ` 赋值即可） | S |
| 21 | `privacy`（命名空间） | privacy | 读写浏览器隐私开关 | MV2 桩是空对象 `services:{}, network:{}, websites:{}`（`:997`）；**MV3 prelude 已实现为无效设置**：`setting(false)`（`:1371`），返回 `levelOfControl: 'not_controllable'`。真实开关存在（`SiteJavaScript.isAllowed`、`SettingsView.swift:2384` 的 JavaScript 下拉、`ContentBlocker.isEnabled` `:2359`） | **接线即可**（读真值，写回真设置） | M |
| 22 | `privacy`（perm 条目） | privacy | 同上权限项 | 同上 | **接线即可** | S |
| 23 | `clipboardRead` | clipboardRead | 扩展读剪贴板 | 写有（`SettingsView.copy` `:3387`、`NSPasteboard`），**读**也已有（`DebugBridge.swift:2021` `NSPasteboard.general.string`）。WebKit 只给 `ClipboardWrite` 权限（头文件实测）| **需新建能力**（宿主侧读剪贴板后经 Bridge 回传；注意安全提示，Chrome 对此有强警告） | M |
| 24 | `contentSettings` | contentSettings | 按站点改 JS/图片/弹窗 | 逐站点 JS 已有：`Tab.javaScriptHere` `Tab.swift:243`、`SiteJavaScript.apply` `:1585`；弹窗/相机/话筒/位置/通知策略在 `SitePermissions.swift:207-224`。但**没有 `chrome.contentSettings` 命名空间** | **需新建能力**（要写 set/get 映射到 SitePermissions 的 kind 键） | M |
| 25 | `management`（命名空间） | management | 管理其他扩展 | 桩：getSelf 真、`getAll: done([])`、`get/setEnabled: no()`（`:993`）。真实扩展清单在 `ExtensionStore`/`ExtensionCenter.swift`，可枚举 | **需新建能力**（getAll/get 可接线；setEnabled 涉及安全边界） | M |
| 26 | `runtime.restart` | runtime | 重启扩展 | 宿主可重载扩展（`ExtensionHost` 有 release/launch 流程） | **接线即可** | S |
| 27 | `runtime.restartAfterDelay` | runtime | 定时重启 | 同上 + 定时器 | **接线即可** | S |
| 28 | `runtime.getPackageDirectoryEntry` | runtime | 拿到扩展目录的 FileSystem API | **不可直接实现**：WebKit 无 FileSystem API，且扩展包目录是只读 hardlink 影子目录（`ExtensionStore` 注释 `:1084` 起） | **不建议做**（WebKit 没有 `DirectoryEntry` 类型，做出来也只能返回空壳；收益≈0） | — |
| 29 | `action.onUserSettingsChanged` | action | 用户改扩展设置通知 | 无对应"用户设置"概念 | **不建议做**（Chrome 该事件本身仅企业策略通道触发，普通扩展几乎不用） | — |
| 30 | `cookies.getPartitionKey` | cookiePartitions | 读 cookie 分区键 | WebKit 无分区 cookie 概念（`cookies` 走 WKWebExtension 的 Cookies 权限） | **不建议做**（无底层模型，伪造会误导扩展） | — |
| 31 | `declarativeNetRequest.getMatchedRules` | dnr | 看哪些规则命中 | DNR 走 WebKit 原生（`ExtensionStore.swift:942` `fill('declarativeNetRequest', …)`，靠 WebKit 自己的匹配器）；**无命中记录 API** | **不建议做**（要自己重放匹配算法，与 WebKit 结果必然不一致） | — |
| 32 | `declarativeNetRequest.testMatchOutcome` | dnr | 测试某 URL 命中哪条 | 同上 | **不建议做**（同 #31：需复刻 WebKit 匹配语义） | — |
| 33 | `declarativeNetRequest.onRuleMatchedDebug` | dnr | 调试用命中回调 | 同上 | **不建议做**（同 #31，且仅 unpacked 调试用） | — |
| 34 | `declarativeNetRequest.setExtensionActionOptions` | dnr | 角标显示命中计数 | 同上，无命中计数 | **不建议做**（依赖 #31） | — |
| 35 | `declarativeNetRequestFeedback` | dnrFeedback | 命中反馈权限（调试） | 见 #33 | **不建议做**（同 #31/#33） | — |
| 36 | `readingList` | readingList | 阅读列表读写 | **Zigzag 无阅读列表功能**：全仓只有导入器把 Safari/Orion 的阅读列表折进书签（`OrionImporter.swift:128`、`SafariImporter.swift:40`），无运行时模型 | **需新建能力**（先要有"阅读列表"这个产品功能，才谈 API） | L |

（上表编号 17–36 为 35 条 notImplemented 中除去 A 段 16 条后的完整余量。）

### notImplemented 汇总

| 判定 | 条数 | 编号 |
|------|------|------|
| **接线即可** | **17** | 1,2,3,5,6,7,8,9,10,11,12,13,14,20,22,26,27 |
| 需新建能力 | 11 | 4,15,16,17,18,19,21,23,24,25,36 |
| 不建议做 | 8 | 28,29,30,31,32,33,34,35 |

合计 17 + 11 + 8 = 36 编号 —— 其中 **#9 与 #10 是同一条 API 的两种 claim 形态（`tabGroups` 命名空间 / `perm|tabGroups`）**，按 API 计为 35 条 notImplemented。

其中 **6 条属 claim 判错**（#1-3 书签事件、#6-7 permissions、#14 webRequestBlocking）——底层本就在，只是桩没接上/从未 emit，被误记成 notImplemented。

---

## 2. 核实 23 个 `platform` + 14 个 `webkitMissing`

### 2.1 抽查 12 条（超过要求的 10 条）

| claim | 类型 | 核查结论 | 证据 |
|-------|------|----------|------|
| `system.display.setDisplayProperties` | platform | **成立** — 需改 macOS 显示分辨率/布局，要 admin 权限，浏览器级 API 本身不该做 | `BridgeDisplay` 只实现 `getInfo`（`BridgeNamespaces.swift:646`） |
| `system.display.setDisplayLayout` | platform | **成立** — 同上 | 同上 |
| `system.display.*overscanCalibration*`（6 条） | platform | **成立** — TV 过扫描校准，macOS 无此概念 | 同文件无相关实现 |
| `system.display.clearTouchCalibration` | platform | **成立** — 触屏校准，Mac 无触屏 | 同上 |
| `power.reportActivity` | platform | **成立（但可补）** — 桥里有 keep-awake（`IOPMAssertion`，`:821-828`），`reportActivity` 是"声明活动"提示，可用 `IOPMAssertionDeclareUserActivity` 实现 | `BridgeNamespaces.swift:823-828` |
| `downloads.setShelfEnabled` | platform | **成立** — Chrome 的下载架 UI 概念，Zigzag 无此 UI；且桥已返回 nil | `BridgeDownloads.swift:68` `case "setUiOptions","setShelfEnabled","acceptDanger": return nil` |
| `downloads.acceptDanger` | platform | **成立** — "已确认危险下载"，Zigzag 下载策略不同 | 同上 `:68` |
| `notifications.onButtonClicked` | platform | **成立（有可补空间）** — 通知已实现（`BridgeNotifications:107`），但 macOS 通知按钮需 `UNNotificationCategory` 带 actions；现状 `WebNotifications.swift:193` `actions: []` **空数组** → 按钮确实没有 | `WebNotifications.swift:193` |
| `notifications.onPermissionLevelChanged` | platform | **成立** — Chrome 权限等级模型，macOS 只有二元授权 | `getPermissionLevel` 在 Bridge 里 |
| `identity.getAuthToken` | chromeService | **成立且无法做** — 需 Google OAuth broker 服务器互信；`BridgeIdentity` 只实现 `launchWebAuthFlow`/`getRedirectURL`（`:1445-1451`），`getAuthToken` 走 `default: throw unsupported` | `BridgeNamespaces.swift:1430-1453` |
| `debugger.attach` | webkitMissing | **成立** — 桩 `no('Debugging pages')` `ExtensionStore.swift:992`；且全仓无 `isInspectable`/`_WKInspector`（另有 worker 交叉验证） | `ExtensionStore.swift:992` |
| `devtools.panels` | webkitMissing | **成立** — 需自建 DevTools UI 宿主，WebKit 无 `WKWebExtension` devtools 支持 | SDK 头文件无 devtools 相关 |
| `fontSettings` | webkitMissing | **成立** — WebKit 权限令牌无 fonts；iOS/macOS 字体由系统管 | `WKWebExtensionPermission.h` 17 令牌无 fonts |
| `publicSuffix` | webkitMissing | **成立** — WebKit 无 PSL API；可用 `NSURLCredential`/PSL 数据自建但非浏览能力 | 全仓 0 命中 |

### 2.2 被误标的高价值发现（**重点**）

**发现 1：`pageCapture` 判 `webkitMissing` 不准确 —— 等价能力已有。**
- claim：`pageCapture` 与 `perm|pageCapture` 均判 webkitMissing。
- 事实：`Zigzag/Web/PageScreenshot.swift` 已有**整页渲染**能力：`capture(_:)` `:57`、`draw(_:height:)` `:118`、`render(_:backing:)` `:132`（PDF→位图）、`findScroller` `:193` 处理嵌套滚动。`canTake` `:24`/`take` `:30` 是完整的"整页快照"链路。
- Chrome 的 `pageCapture.saveAsMHTML` 产物是 **MHTML**，Zigzag 缺的只是 MHTML **编码器**（`DownloadRules.swift:41` 只是把 `.mht/.mhtml` 当下载类型认得，不是生成器）。
- 修正判定：**应为 `notImplemented` 而非 `webkitMissing`**，且是 **需新建能力（M）**：用现有 `draw` 产 PDF（`BrowserActions.swift:88` 已支持 `.pdf/.webArchive`）再封装成 MHTML 包，或直接返回 PDF。**这条从"不可能"变成"可做"，是本轮最有价值的修正。**

**发现 2：`desktopCapture` 判 `webkitMissing` 需收窄。**
- macOS 侧屏幕捕获能力存在（ScreenCaptureKit / `CGWindowListCreateImage`），且 `tabCapture` Bridge 已实现 `getMediaStreamId`/`capture`（`BridgeNamespaces.swift:1795/1802`）。
- WebKit 确实没有"扩展请求桌面流"的通道 → **"WebKit 无此 API" 成立**，但理由应写成"宿主缺 ScreenCaptureKit→getUserMedia 桥接"，而非"平台不可能"。属 **需新建能力（L）**，不建议近期做。

**发现 3：`sessions` 被列 notImplemented，但 `sessions.getDevices` 是 `emulated`，而 `getRecentlyClosed` 明明有数据。**
- 见 #11：`recentlyClosedTabs` `TabManager.swift:1468` 已经返回 id/url/title 三元组，`done([])` 属**假 emulation**——返回"空"比"未实现"更糟，扩展会认为用户从没关过标签。

**发现 4：`bookmarks` 三条事件已在 bridge.js 注册，claim 却记 notImplemented。**
- `bridge.js:251-253` 明确 `onChildrenReordered/onImportBegan/onImportEnded` 都是 `event(...)`。这三条不是"缺失 API"，而是"**已声明、宿主漏发**"。

**发现 5（补充核实）：这三条的修复是 S 不是 M —— `emit` 通道已现成。**
- `ExtensionBridge.swift:157` `func emit(_ event: String, _ args: [Any], to:)`、`:152` `func isListened(_:)` 都是成熟通用设施。
- `BridgeBookmarks.swift:349-376 announceChanges()` 已经在用它们发 `onCreated/onRemoved/onChanged/onMoved` 四个事件。
- `onImportBegan/onImportEnded` 的落点已定：`ImportCoordinator.swift:432-433`（书签导入执行点）。**但位置有讲究：`began` 发在进入 `if` 之前，`ended` 发在 `addBookmarks` 之后。**
  `:433` 是 `if choice.contains(.bookmarks), !batch.bookmarks.isEmpty` —— 若两条都塞进 if 内，"用户选了书签但文件里没有书签"的空导入就不会发 began/ended，而 Chrome 是发的（导入会话已开始）。
- **`onChildrenReordered` 不能照抄 `onMoved`，且顺带修一处既有语义偏差**（详见 §发现 6）。**无需新建 fire 通道。**

**发现 6（对 Chrome 官方语义核实后的修正）：`onMoved` 现有实现超发，与 `onChildrenReordered` 是同一处。**
Chrome 文档（developer.chrome.com/docs/extensions/reference/api/bookmarks，2026-10-29 版）原文：
> `onChildrenReordered` — "Fired when the children of a folder have changed their order **due to the order being sorted in the UI**. **This is not called as a result of a move().**"　参数 `(id, { childIds: string[] })`
> `onMoved` — "Fired when a bookmark or folder is moved to a **different parent folder**."

两点后果：

1. **`onChildrenReordered` 是「每个父节点一次 + 携带完整 `childIds` 数组」**，不是 per-id。`order()`（`BridgeBookmarks.swift:361`）可直接复用（它正是"按 parentId 过滤 + 按 index 排序"），但正确写法是**按 parentId 分组比对 childIds 序列，一组发一次**。

2. **`BridgeBookmarks.swift:371-372` 现有的 `onMoved` 超出 Chrome 语义：**
   ```swift
   let moved = was.parentId != now.parentId
       || order(before, was.parentId, keeping: common).firstIndex(of: id) != order(after, now.parentId, keeping: common).firstIndex(of: id)
   ```
   `||` 后半段让「**同父换位**」也发 `onMoved`，而 Chrome 只在**换父**时发。**今天就在给扩展发多余的 `onMoved`。**

**正确改法是拆 `||`，而非"复制两行"**：换父 → `onMoved`；同父顺序变 → `onChildrenReordered`。一处拆分同时修掉「多发 onMoved」与「漏发 onChildrenReordered」。**工作量 S，但性质是修语义偏差。**

> 引申：`announceChanges()` 这段历史代码未被逐条对过 Chrome 语义。汇总若标「claim 层偏差未穷举」，**实现层同样可能有未抽到的语义偏差**——本条即实例。

### 发现 7：完整修法是三处，漏掉第 1 处会**静默失效**

`BridgeBookmarks.swift:349` 是 `announceChanges()` 的总门控：

```swift
guard ["bookmarks.onCreated", "bookmarks.onRemoved", "bookmarks.onChanged", "bookmarks.onMoved"]
    .contains(where: { bridge.isListened($0) }) else { return }
```

**数组里没有 `bookmarks.onChildrenReordered`。** 一个只监听 `onChildrenReordered` 的扩展进来时，`isListened` 对这四个都是 false → 整个函数 `return` → 第 2、3 步加的 emit 永远走不到。

**行为定性（已核行号）**：`lastSeen = after` 在 **`:347`、位于 `:349` 的 `isListened` guard 之前**。

```
344: private func announceChanges() {
345:     guard let before = lastSeen else { return }
346:     let after = snapshot()
347:     lastSeen = after          ← 快照先推进
348:     let bridge = host.bridge
349:     guard [...four events...].contains(where: { bridge.isListened($0) }) else { return }
```

所以 guard `return` 时 `lastSeen` **已经**推进到 `after`：**不存在积压补发，也不会重放历史变更**。这一轮变更被干净丢弃——无报错、无残留，下一轮从新快照继续。

**后果**：只监听 `onChildrenReordered` 的扩展永远收不到通知，属**纯静默功能缺失**（危险在于不报错）。仍需把 `onChildrenReordered` 加进 `:349` 门控，否则第 2、3 步的 emit 不可达。

**三处缺一不可：**

| # | 位置 | 改动 |
|---|------|------|
| 1 | `:349` | 门控数组加 `"bookmarks.onChildrenReordered"` |
| 2 | `:371-372` | 拆 `\|\|`：换父才发 `onMoved` |
| 3 | 新增分支 | 同父顺序变 → 按 parentId 分组发 `onChildrenReordered` |

**第 3 步的 `childIds` 必须用全量，不能用 `keeping:`。**
`order(_ tree:_ parent:keeping:)` 的签名（`:360`）强制带 `keeping: Set<String>`：

```swift
func order(_ tree: [String: Placed], _ parent: String, keeping: Set<String>) -> [String] {
    tree.filter { $0.value.parentId == parent && keeping.contains($0.key) }
        .sorted { $0.value.index < $1.value.index }.map(\.key)
}
```

- `:372` 现有调用用 `keeping: common` 是**对的**——它判的是"有没有相对位移"，过滤掉本次新增/删除正好避免误报。
- 但发 `childIds` 时若仍用 `common`，会把本次新增的子节点排除在外，**给扩展一个残缺数组**。必须传该父节点下的全量 key 集合。
- `snapshot()` `:329` 从 root 全量遍历，`before`/`after` 都含所有节点，所以全量集合构造得到；具体为 `Set(before.keys.filter { before[$0]?.parentId == parent } | after.keys.filter { after[$0]?.parentId == parent })`。

**修订后工作量：仍 S**（三处、单文件、无新类型），但**是三处联动**，不是"补两行"。

---

## 2.3 分类自洽声明（防误读）

「**不建议做 8 条**」= #28–#35（`runtime.getPackageDirectoryEntry`、`action.onUserSettingsChanged`、`cookies.getPartitionKey`、`declarativeNetRequest.{getMatchedRules, testMatchOutcome, onRuleMatchedDebug, setExtensionActionOptions}`、`declarativeNetRequestFeedback`）。

**`bookmarks.onImportBegan / onImportEnded / onChildrenReordered` 不在其中**——它们是 #1–#3，归类为「**接线即可**」。

本报告对"不建议做"的唯一理由（"自行复刻会与 WebKit 真实行为不一致，错误比不支持更有害"）**只适用于 #28–#35 那 8 条**，因为只有它们需要复刻 WebKit 的内部语义（分区 cookie / FileSystem / DNR 命中记录）。

那三条书签事件属**第 7 类独立形态：已声明、宿主漏发（`declared-not-emitted`）**，性质是"桥接侧已就绪、宿主侧漏发"，与"不建议做"无关，修复方向完全相反（应尽快补 emit）。

> 给下游读者的结论：看到一个 API 标 `unsupported`，先分清它属于哪一类——
> ①桩判错（能力本在）②接线即可 ③需新建能力 ④WebKit 硬边界(webkitMissing) ⑤平台边界(platform) ⑥不建议做（复刻会错）⑦已声明、宿主漏发。
> 只有 ④⑤ 是真正"做不到"，⑥ 是"不该做"，①②③⑦ 全是"能做且该做"。

---

## 3. 按「用户能感觉到的程度」排序

### T0 — 用户马上能察觉（扩展会静默失效/报错）
1. **`sessions.getRecentlyClosed` 返回空**（#11）— 任何"恢复最近关闭"的扩展直接失效。**S，最高性价比。**
2. **`tabs.group` / `tabGroups`**（#8-10）— 标签分组类扩展（很多生产力扩展依赖）完全不可用，而引擎已经完备。**M。**
3. **`tabGroups.query` 已是 `done([])`**（`ExtensionStore.swift:982`）— 同 #2，返回空比报错更误导。

### T1 — 有感知但受众窄
4. `webRequestBlocking`（#14）— 裁决：auth 场景已通，通用阻塞不通；老 MV2 广告/隐私扩展会感知。
5. `privacy` / `contentSettings`（#21-22, #24）— 广告拦截/内容控制类扩展。
6. `bookmarks` 三条事件（#1-3）— 书签同步类扩展收不到导入通知。
7. `tabs.createSplit/unsplit`（#17-18）— 只有 Split View 类扩展关心。
8. `clipboardRead`（#23）— 剪贴板类工具（同时是隐私敏感点，需明确提示）。

### T2 — 边缘功能
9. `management.getAll/get`（#25）— 扩展管理面板类。
10. `sidePanel.getLayout`（#5）、`permissions.*HostAccessRequest`（#6-7）、`runtime.restart*`（#26-27）— 多数扩展只是探测，不接也能跑。
11. `ttsEngine`（#15）、`geolocation`（#16）— 极少数扩展。
12. `downloads.onDeterminingFilename`（#4）— 仅下载重命名类。
13. `omnibox`（#19）、`readingList`（#36）— 需要先有对应产品功能。

### T3 — 不建议做（明确回绝）
`runtime.getPackageDirectoryEntry`、`action.onUserSettingsChanged`、`cookies.getPartitionKey`、`declarativeNetRequest.{getMatchedRules,testMatchOutcome,onRuleMatchedDebug,setExtensionActionOptions}`、`declarativeNetRequestFeedback`。
理由统一为：**WebKit 无对应底层模型（分区 cookie / FileSystem / 命中记录），自行复刻会与 WebKit 真实行为不一致，给出错误结果比不支持更有害。**

### platform / webkitMissing 中的"可补但不必补"
- `power.reportActivity` — 一行 `IOPMAssertionDeclareUserActivity` 可补（S），但用户无感知，优先级最低。
- `notifications.onButtonClicked` — 需给 `WebNotifications.swift:193` 的 `UNNotificationCategory` 填 `actions`（M），通知类扩展才有按钮。

---

## 4. 交付摘要

- 35 条 notImplemented：**17 条"接线即可"**（其中 6 条属 claim 判错，底层本就在）、11 条需新建能力（含 readingList）、8 条不建议做。
- 抽查 14 条 platform/webkitMissing：**12 条成立**，**`pageCapture` 属误标**（等价整页渲染已在 `PageScreenshot.swift`，应为 notImplemented/M），`desktopCapture` 理由需收窄。
- 最高性价比三件事：`sessions.getRecentlyClosed` 接真数据（S）、`tabGroups` 整体接线（M）、`bookmarks` 三条事件 emit（S）。
