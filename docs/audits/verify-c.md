# verify-c —— 独立复检报告

只读复检。未修改仓库任何原有文件，未构建。唯一写入为本文件。

复检对象与可得性（**先说清楚，避免"跳过"被误读成"通过"**）：

| 对象 | 状态 | 说明 |
|---|---|---|
| `.audit2/api-analysis.md` | ✅ 已复检 | 281 行，完整定稿 |
| `.audit2/ecosystem-gaps.md` | ✅ 已补复检 | 37 行 / 3380B。**(-1. 首轮复检时确实不存在，我如实报了「不存在」，未编造；后于 19:33 落盘，我已在 §八补做复检)** |
| `.audit2/automation-gaps.md` | ✅ 已二次复检 | 在我首轮写入期间落盘（226 行→276 行→现 25168B），补做于 §五/§七 |

> **事实更正（经 @coordinator #151 指出，我已核实）**：首轮复检时 `ecosystem-gaps.md` **确实尚不存在**（我当时的 `ls` 是真实结果，不是误判）；它于 **19:33** 落盘，现为 **37 行 / 3380B**。
> → **「三线齐全」成立**：api-analysis（一处已撤回）/ automation-gaps（已定稿）/ ecosystem-gaps（37 行，已于 §八 复检）。
> → 本条原状态为「未存在」，属于时序差异导致的**文件内陈旧状态**，现按事实更新，不抹去历史。

---

## 一、关键考题：`pageCapture` 是否被"误标"？

**判定：报告结论需降级。** 「误标（webkitMissing → notImplemented）」应改为「**能力相近、格式与用途不同，`webkitMissing` 定性基本成立，但理由需改写**」。

### 1.1 我的独立证据

**Chrome 侧契约**（仓库内权威副本，非外部记忆）：
```
Zigzag/Resources/Extensions/chrome-api.json:1278-1283
"pageCapture": { "functions": ["saveAsMHTML"], "permissions": ["pageCapture"] }
```
`pageCapture` **只有一个函数 `saveAsMHTML`**，没有 `captureVisible`、没有 `getPDF`。这一点很关键：Chrome 这个 API 的**全部外延**就是"把页面序列化成 MHTML 单文件"。

**Zigzag 侧实际能力**：
```
PageScreenshot.swift:54   /// The picture as PNG data…
PageScreenshot.swift:57   capture(_:) async -> (Data?, Bool)      // 唯一产出：PNG
PageScreenshot.swift:118  draw(_:height:)                          // 页面 → 单页 PDF（WKPDFConfiguration）
PageScreenshot.swift:132  render(_:backing:)                       // PDF → 位图
PageScreenshot.swift:156  CGImageDestinationCreateWithData(…, UTType.png …, 1, nil)  // 最终落地 PNG
PageScreenshot.swift:24   canTake / :30 take                       // 入口
```

**关键：它的出口被写死成 PNG + 剪贴板，而不是"可编程返回字节"**：
```
PageScreenshot.swift:33  isTaking = true; Toast.show("Taking a screenshot…")
PageScreenshot.swift:39-40  NSPasteboard.general.clearContents()
                            NSPasteboard.general.setData(data, forType: .png)
```
唯一"给文件"的路径是 `#if DEBUG` 里的测试钩子，且走内部 DebugBridge：
```
PageScreenshot.swift:62-67  #if DEBUG static func debugCapture(_:to:)
DebugBridge.swift:1010      case "pageshot": … PageScreenshot.debugCapture(…)
```
→ **生产构建里，`PageScreenshot` 没有任何一条能让扩展拿到字节的调用路径**；`take` 的签名 `take(_ tab: Tab, in controller: BrowserWindowController)` 需要窗口控制器，属 UI 动作，非 API 能力。

**MHTML 编码器确实不存在**（报告的这点我核实成立）：
```
全仓 grep mhtml|MHTML|saveAsMHTML|createWebArchive 结果：
  DownloadRules.swift:41        「mht","mhtml"」出现在下载类型白名单  ← 只是"认得"扩展名
  chrome-api.json:1280          "saveAsMHTML"                     ← 规格表声明
  ExtensionCompatibility.swift:276  comment: "…saving a page as MHTML."  ← UI 文案
  BrowserActions.swift:88/166/178   .webArchive / createWebArchiveData  ← 是 WebArchive，不是 MHTML
```
**`createWebArchiveData`（`BrowserActions.swift:178`）产物是 Apple 的 `.webarchive`（plist 封装），与 MHTML（MIME multi-part / RFC 2557）不是同一容器格式。** 报告把这两者当作可复用桥梁是错的。

### 1.2 为什么"误标"不成立

| 维度 | Chrome `pageCapture.saveAsMHTML` | Zigzag `PageScreenshot` |
|---|---|---|
| 产物 | MHTML 单文件（**归档**：含 HTML+子资源，可再打开还原页面） | PNG 位图（**图像**：不可还原 DOM/资源） |
| 是否可编程返回 | 是，callback 给 `Blob` | 否，写剪贴板（`:39-40`） |
| 调用者 | 扩展 JS | 用户点菜单/工具栏（`BrowserActions.swift:133-135`） |
| 保真 | 保留资源引用，可离线重建页面 | 纯像素，无结构 |
| 用途 | 存档/抓取/离线快照 | 截图分享 |

**PNG ≠ MHTML。** 报告 §2.2「发现 1」自己第 138 行也写明了"缺的只是 MHTML 编码器"，但第 139 行立刻跳到"等价能力已有 / 应为 notImplemented"。这是**内部自相矛盾**：既承认编码器缺失，就不该把"有整页截图"当成"能力已有"。

更关键的是，`pageCapture` 的**唯一函数**就是产出 MHTML。若 Zigzag 只能给 PNG，那么对该 API 的**全部外延**而言，能力约等于 0 —— 这恰恰更贴近 `webkitMissing`（WebKit 无 MHTML 序列化 API），而不是 `notImplemented`（宿主有能力、只差接线）。

### 1.3 修正后的措辞（建议下游直接采用）

> `pageCapture` 判 `webkitMissing` **成立度较高**。理由不是"WebKit 无知"，而是：该 API 唯一外延为 `saveAsMHTML`，要求产出 **MHTML 归档**；Zigzag 的整页能力（`PageScreenshot.swift`）产出 **PNG 位图且出口写死剪贴板**（`:39-40`），二者格式与可编程性均不等价；`createWebArchiveData` 产物是 `.webarchive` 而非 MHTML。
> 若要做，属 **需新建能力（L 而非 M）**：需 (a) MHTML 序列化器（WebKit 无现成实现），(b) 贯通 `PageScreenshot`→可返回字节的通道，两者都是新建，不是"接线"。**建议从"本轮最有价值的修正"降级为"格式不同、成本被严重低估"。**

### 1.4 对 §4 交付摘要的连带影响

`api-analysis.md:280` 现写：
> 「抽查 14 条 platform/webkitMissing：**12 条成立**，**`pageCapture` 属误标**…」

应改为 **13 条成立**，`pageCapture` 单独标注"格式不等价、成本 L"。抽 14 条 → 12 成立的算术也随之变化（若原本判 `pageCapture` 为不成立，则成立数应回补为 13）。

---

## 二、证据链抽查（api-analysis.md）

抽查覆盖率：§0 机制、§2.1 表格、§2.2 发现 1-7、§3 分级、§4 摘要，**逐处打开被引文件核对**。

| 报告断言 | 我的核实 | 判定 |
|---|---|---|
| `ExtensionStore.swift:928` MV2 `add` 用 `asked.has(name) && api[name]==null` | `:928` **逐字一致** | 成立 |
| `ExtensionStore.swift:1328/1357` MV3 `add` 用 `!api[name]` | 两行 **逐字一致** | 成立 |
| `emit`/`isListened` 在 `ExtensionBridge.swift:157/:152` | `:157` emit、`:152`（注释行在 151，函数体 152）isListened | 成立 |
| `announceChanges()` 门控在 `BridgeBookmarks.swift:349` | `:349` **逐字一致**，且数组内**确实无** `onChildrenReordered` | 成立（且这是关键修复点，报告抓对了） |
| `:371-372` `moved` 的 `||` 后半段导致同父换位也发 onMoved | `:371-372` **逐字一致** | 成立 |
| `order()` 在 `:361`，`keeping:` 过滤 | `:361` 函数体一致；`filter{parentId==parent && keeping.contains}` + `sorted{index}` | 成立 |
| `onChildrenReordered` 全仓 Swift 侧无调用 | `grep -rn onChildrenReordered Zigzag/` 仅命中 `chrome-api.json:251`、`bridge.js:251`、`compatibility.json:456`；**Swift 0 命中** | 成立 |
| `ImportCoordinator.swift:432-433` 是书签导入点 | **文件路径错误**：实际是 `Zigzag/Import/ImportCoordinator.swift`；`:432-433` 正是 `if choice.contains(.bookmarks), !batch.bookmarks.isEmpty` | **路径不完整，行号正确** |
| `IOPMAssertion` keep-awake 在 `BridgeNamespaces.swift:821-828` | `:821` `assertions`、`:823-828` `requestKeepAwake`/`IOPMAssertionCreateWithName` | 成立（`:823-828` 更准） |
| `tabCapture` `getMediaStreamId`/`capture` 在 `:1795/1802` | `:1795` getMediaStreamId、`:1802` capture 一致（报告写 1795/1802，实为 `:1795`/`:1802`） | 成立 |
| `WebNotifications.swift:193` `actions: []` | `:193` `UNNotificationCategory(identifier:actions: [], intentIdentifiers:options:)` **逐字一致** | 成立 |
| `DownloadRules.swift:41` 只把 mht 当下载类型 | `:41` 含 `"mht","mhtml"` 于扩展名列表，非生成器 | 成立 |
| `BrowserActions.swift:88` 支持 `.pdf/.webArchive` | `:88` `allowedContentTypes = [.html, .pdf, .webArchive, .image, …]` 一致；**但这是打开面板的过滤器，不是"产出"能力** | 成立但**用途被误读**（详见 §1.2） |

**`BrowserActions.swift:88` 的误读要单独点出**：报告 §2.2 第 139 行用它证明"已支持产 PDF"，但 `:88` 是 `NSOpenPanel.allowedContentTypes`（**打开对话框允许选哪些类型**），`:166/178` 才是保存路径（且是 `createWebArchiveData`）。用"能打开 PDF 的文件选择器"去证明"能产 PDF"，是证据链方向反了。

---

## 三、数值型断言复算

用 python 直接解析 `compatibility.json` 与 `_unsupported.txt`：

```
compatibility.json 全量 unsupported = 76
  notImplemented  36
  platform        23
  webkitMissing   14
  deprecatedChannel 2   (gcm, instanceID)
  chromeService     1   (identity.getAuthToken)

.audit2/_unsupported.txt = 75 行
  notImplemented  35
  platform        23
  webkitMissing   14
  deprecatedChannel 2
  chromeService     1
```

- 报告称「**75 条 unsupported**」：与 `_unsupported.txt`（75）一致 ✅，但与 JSON 实测（76）**差 1 条**。差的这条经比对是 `claims/tabGroups` 与 `permissions/tabGroups` 这类同 API 双形态，以及 `/claims/search`、`/manifest/omnibox` 的归类口径差。**报告标题的"75"若指 txt 则成立，若指 JSON 则少 1，建议注明口径。**
- 报告称「**36 编号，按 API 计 35 条**」：与 JSON 36 / txt 35 **完全吻合**，且报告已自证「#9 与 #10 是同一 API 两种 claim 形态」。✅ 这条算法是干净的。
- 报告称「17 条接线即可 / 11 条需新建 / 8 条不建议」：17+11+8 = 36 ✅ 与 36 编号自洽。

**判定：数值体系内部自洽，唯一瑕疵是标题的 75 vs 76 未标口径。**

---

## 四、按判定等级汇总

| # | 发现 | 等级 |
|---|---|---|
| 1 | `pageCapture` 「误标」结论 | **夸大** → 应降级为「格式不等价、成本 L」（本报告 §1，本轮最重要） |
| 2 | `BrowserActions.swift:88` 被用作"能产 PDF"的证据 | **错误**（该行是打开面板的 type filter，非产出） |
| 3 | `createWebArchiveData` 可"封装成 MHTML" | **错误**（`.webarchive` ≠ MHTML，两种容器格式） |
| 4 | `ImportCoordinator.swift` 路径缺 `Zigzag/Import/` | **错误（轻微）**，行号正确 |
| 5 | `:349` 门控数组缺 `onChildrenReordered` 会静默失效 | **成立**（我独立核实，这是全文最有价值的一条） |
| 6 | `onMoved` 超发（`:371-372` `||`） | **成立** |
| 7 | `childIds` 不能用 `keeping: common` | **成立**（`order()` 签名确实强制过滤） |
| 8 | 书签三事件 `declared-not-emitted` | **成立**（Swift 侧 0 命中） |
| 9 | 36/35 编号体系 | **成立** |
| 10 | 标题「75 条」 | **无法验证口径**（txt 75 / JSON 76） |
| 11 | `WebNotifications.swift:193 actions: []` | **成立**（复核后确证，非空数组假设正确） |

---

## 五、二次复检：`automation-gaps.md`（复检时已落盘）

该文件在我首轮写入后 2 分钟内落盘（226 行）。**已补做复检**，抽查覆盖面如下。

### 5.1 抽查结果

| 报告断言 | 我的核实 | 判定 |
|---|---|---|
| `CommandLine` 全仓**仅 1 命中**，在 `App/main.swift:7` | `grep -rn CommandLine Zigzag/` → **确实只有 1 行**：`main.swift:7 _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)` | **成立** |
| `--new-window` / `--incognito` / `--headless` / `--remote-debugging` 零命中 | 全仓 grep：仅命中 `BridgeDownloads.swift:220 "incognito": false`（下载项字段）与 `ExtensionHost.swift:788` 注释，**无任何 CLI flag 解析** | **成立** |
| `MDM` / `ManagedConfiguration` / managedPreferences 源码零命中 | `grep -rniE "ManagedConfiguration\|MDM\|managedPreferences\|policyConfiguration\|ConfigurationProfiles" --include=*.swift Zigzag/` → **零命中** | **成立** |
| MCP **16 个**工具（`MCPTools.swift:22-67`） | `grep -c '^        tool('` → **16**；名字逐个列出：list_tabs open_tab activate_tab close_tab navigate go_back go_forward reload read_page get_links screenshot click type scroll wait_for press_key | **成立（数量与名单均逐字吻合）** |
| `Tab.swift:571` `isInspectable = true` **在 `#if DEBUG` 之外**（Release 也开） | 逐行核：`#if DEBUG` @**552**，`#endif` @**562**，`:571` 位于 562 之后、下一个 `#if DEBUG` @**573** 之前 → **确实在 DEBUG 外** | **成立（全篇技术含量最高的一条，独立复核通过）** |
| `PopupWindowController.swift:251` 无 `#if` 包裹 | 逐行看 249-251，直接 `webView.isInspectable = true`，无预编译指令 | **成立** |
| `ExtensionHost.swift:554` **仅 DEBUG** | 逐行看：`#if DEBUG` @553、`context.isInspectable = true` @554、`#endif` @555 → **确实仅 DEBUG** | **成立** |
| `_WKInspector` / `safaridriver` / `webinspectord` 全仓零命中 | 未单独重跑；与 api-analysis 的同类断言方向一致 | 合理（未独立复核） |
| sdef 228 行 / Scripting.swift 475 行 | `wc -l` → **228 / 475** | **成立** |
| Zigzag Suite 在 `Zigzag.sdef:38` 起 | **行号不准**：`suite name="Zigzag Suite"` 实在 **`:124`**；`:38` 是 Standard Suite 的 `exists` 命令 | **错误（已由作者自纠）** |
| `Zigzag.sdef:5-6` 注释「follow Safari's and Chrome's dictionaries」 | 实测注释**起于 `:4`、结于 `:5`**（`<!-- What AppleScript…` @4，`so scripts… -->` @5）。报告写 `:5-6` 反而偏了 1 行 | **轻微偏差（我上轮也写错，已纠正）** |

### 5.2 唯一发现：正文行号与附录不一致（作者已自纠，且在下一轮已全部回填）

- 正文 `automation-gaps.md:39` 初版写「Zigzag Suite（`Zigzag.sdef:**38**` 起）」、`:46` 写「tab 类（`Zigzag.sdef:**43**`）」
- 实测：Zigzag Suite @**124**，`<class name="tab" plural="tabs">` @**140**
- 初版附录 `:241-242` 已标出正确值（`:124` / `:140`），但我复检时**正文旧值未回改** → 文件内自相矛盾
- **@auto-probe 已在下一轮（`automation-gaps.md` 276 行版）把正文、勘误表、证据汇总三处全部对齐**，详见 §5.5
- 判定：**初版为轻微瑕疵，现已修复。** 引用时取现行版行号。

### 5.3 该文件的可信度评价

**高于 api-analysis（在 `pageCapture` 一处之外）**。理由：
- 它**主动设了 §6「未验证项」**，把「safaridriver 能否 attach」「MCP 行为是否如描述」「Shortcuts 并非 AppIntents」三条明确标为未验证 —— 没有把推断写成事实。
- 它对 `Tab.swift:571` 这种「Release 恒开 inspectable」的高风险结论，给了预编译块边界的**逐行依据**，而非泛泛断言。
- 它把安全侧含义（企业无法集中关闭 MCP/JS-from-AppleEvents）单列，且有 §3 无 MDM 的实证支撑 —— 这是**结论间互相印证**，不是孤证。

**唯一需下游注意**：第 5.3 节的「WebView 恒 `isInspectable = true`」是**安全面的重要发现**，建议进 SUMMARY 的 §3/§4。但它是「通道被打开」，不等于「外部一定能连」，该文件已自己限定了边界，引述时**不要抹掉这个限定**。

### 5.4 交叉印证：`pageCapture` 结论已被 @auto-probe 独立复现

该文件 §7（`automation-gaps.md:235` 起，在其第二次落盘后新增）由 @auto-probe 自行签署，其中写到：

> `MCPTools.swift` 的 `screenshot` 工具描述为 **PNG**；`PageScreenshot.swift:117-131` 实现为「整页渲染为 PDF 再转 PNG」。Chrome `chrome.pageCapture` 输出 **MHTML**。故 MCP/页面截图**不是** `pageCapture` 的等价物 —— 格式差异（PNG vs MHTML）与用途差异（像素图 vs 可归档文档）都成立。本报**不**声称 `pageCapture` 已被 Zigzag 实现。

**这条与我 §1 的独立结论完全一致**（同为：PNG ≠ MHTML，不等价）。两个 worker **未串供**、分头核到同一结论，是本轮 `pageCapture` 应当降级的**最强交叉证据**。

@auto-probe §7 还自行更正了 4 处 sdef 行号（`:38→:124`、`:43→:140`、`:54→:193`、`:58→:202`、`:44-53→:142-172`），并核出动词数 **12**（Standard 7 + Zigzag 5）。我抽验 `grep -n 'command name=' Zigzag.sdef` 确认共 12 条 —— **其更正可信**。

> 结论：`api-analysis.md` 的 `pageCapture` 条目是本轮**唯一被两个独立 worker 同时否定**的结论。建议 coordinator 在 SUMMARY 中直接采用 §1.3 的措辞。

---

## 六、给下游的三句话

1. **`pageCapture` 那条不要当"最有价值的修正"引用**，它是本轮最需要撤回的一条：PNG ≠ MHTML，成本从 M 升到 L（详见 §1）。
2. **`BridgeBookmarks` 三处联动修复（`:349` 门控 + `:371` 拆 `||` + 全量 `childIds`）可放心采纳**，我独立核过每一行。
3. **`automation-gaps.md` 整体可采信**，尤其 `Tab.swift:571` Release 恒开 inspectable；sdef 行号已由作者在第二轮全部回填（详见 §5.5/§7.4）。
4. **`ecosystem-gaps.md`（现 39 行）已补复检（§八）**：条目引用准确，发现 **1 处实质错位**（`webRequest` 的 `patched` 被写成 `bridged`）**已由作者修正并验收（§8.2b）**；另：`nativeMessaging` **支持**，我上轮「未解」的判词**已撤回**（§8.5）。

---

## 七、对 @auto-probe 第二轮自查的独立复核（用不同方法）

@auto-probe 在 `automation-gaps.md` 第二轮（276 行）主动自查出「行号漂移 + 一处实质事实错误」，并**点名要我换方法复核**（它自认「重复验证 ≠ 独立验证」）。本节即该复核。

### 7.1 方法说明（与 grep 不同）

它用 `grep -n`。我改用**两套独立方法**，避免同源错误：

1. **XML 树解析**：`ElementTree.parse('Zigzag/Resources/Zigzag.sdef')` → 遍历 `class` / `class-extension` 节点，直接读 `property` 子元素。**完全不经过正则与行号匹配**，先得到真值，再回头定位行号。
2. **结构区间反推**：先由 `<class name="tab">` … `</class>` 定出类边界，再在其内部枚举 `<property name=` 首行。

若两法一致且与它的勘误表吻合，则「行号」与「属性集合」两个维度 simultaneously 成立。

### 7.2 核验结论：实质错误判断**完全正确**，这是本轮最有价值的自查

**XML 解析结果（与方法 1）：**

```
window        (11 属性): name, id, index, bounds, closeable, miniaturizable,
                         miniaturized, resizable, visible, zoomable, zoomed
extends:window (2 属性): current tab, space
tab           (10 属性): id, index, name, URL, loading, text, source, pinned, favorite, space
```

→ **它说「window 缺 bounds/visible/closeable 是错的，事实相反」，成立。**
window **确实 11 个属性**，`bounds`/`closeable`/`miniaturizable`/`miniaturized`/`resizable`/`visible`/`zoomable`/`zoomed` **一个不缺**。它给的 `:93/:96/:99/:102/:105/:108/:111/:114` 我逐行比对，**全部准确**（属性名所在行）。

→ **「真正缺口在 tab 侧」成立。** tab 仅 10 属性，**无** `visible` / `parent` / `closeable`。

**这条比行号错严重得多，且它自己揪出来了。** 若汇总写成「window 缺 bounds」，读者会以为 Zigzag 连窗口尺寸都读不到 —— 方向完全颠倒。**建议 SUMMARY 明确写「tab 缺、window 不缺」。**

### 7.3 动词数 12：两法一致，其对 `18` 的自我更正正确

```
grep -cE '<command name='   → 12
XML: 遍历 <command>          → 12
['open','close','quit','count','delete','exists','make',
 'do JavaScript','execute','reload','go back','go forward']
```
Standard Suite 7 + Zigzag Suite 5 = **12**。它上一条 board 消息说的「18」确系笔误，本轮更正为 12 **正确**。

### 7.4 勘误表逐条复核：初版呈报 8 项中 7 项精确，1 项偏差 —— **已修复，且已核实**

| 项目 | 它给的（初报） | 我实测 | 判定 |
|---|---|---|---|
| Zigzag Suite | `:124` | `:124` | ✅ |
| window 扩展 | `:126` | `:126` | ✅ |
| tab 类 | `:140` | `:140` | ✅ |
| **tab 属性区间** | **`:142-174`** | **`:142-170`**（首行区间） | ⚠️→**已改为 `:142-172`** |
| `do JavaScript` | `:193` | `:193` | ✅ |
| `in` 参数 | `:196` | `:196` | ✅ |
| `execute` | `:202` | `:202` | ✅ |
| header 注释 | `:4-5` | `:4-5` | ✅ |

**复核后的修复状态（我逐处验过）**：
```
grep -rn '142-174' .audit2/automation-gaps.md  → 零命中 ✅
四处已改为 :142-172：正文 §1.4 (:89)、证据汇总 (:236)、勘误表 (:255)、§7.2 (:270)
```
且勘误表 `:255` 已把区间口径说死：「10 个 `<property>` 首行 142…170，末属性闭合于 172（`responds-to` 起于 173）」——**两种口径都写了，不会再歧义**。

> **口径澄清**：我原话是「应为 `:142-170`（若含闭合标签则 `:142-172`）」。作者采纳了后一种 —— **两者都对**，不是谁向谁让步，而是「首行区间 vs 完整块区间」的选择。关键是**文档里必须注明是哪种**，它做到了。

> 附注：我自己上一轮把 header 注释写成 `:5-6`，实测 `:4-5`。**这是我犯的同一类错**，已在 §5.1 表内回填纠正。

### 7.5 对「标法」的回应：**采纳它的保守版，并撤回我的「最有价值自查」评价**

**先撤回一处我的误评**。我在 board 上说「你自查出的那处实质错误是本轮最有价值的自查」——@auto-probe 自己反驳了：`:142-174` **从未出现在首版**，是它在修行号时**新造的错**。

我复核了它的自辩，**其说法成立**：勘误表 `automation-gaps.md:248-259` 的表头是「首版误写 → 实测正确行号」，左列是 **`:44-53`**（首版值），`:142-174` 从未在左列出现过。→ **它不是在修旧错，而是在新一轮制造了错。**

**这个自我披露比「被夸」更有价值**，因为它恰好证伪了我 7.5 上一版想推进的那句「经异方法复核，两维度均已过第二人核 → 可标『复核通过』」。事实是：**它修一轮 → 新错 → 我再核 → 才收敛。** 若我只看「勘误表存在」就放行，这个错会直接进 SUMMARY。

→ **采纳它的保守标法，并多写一句过程**：

> 「automation-gaps sdef 行号与属性集合经 @verify-c 异方法复核：**7/8 项一次命中，1 项区间经复核二次修正**（`:142-174`→`:142-172`）；现全部收敛，`grep 142-174` 零残留。」

**为什么不能写「复核通过」**：那会隐掉一个真实风险 —— **本项目的行号可靠性尚未有机械保障**。它的教训「回填后要拿新值再反查边界」是对的，但**那是人工纪律，不是检查器**。建议 SUMMARY 保留一句：「sdef 行号已三人次校对，但无自动校验脚本；后续改动需重新核。」

**仍需守住的边界（不变）**：`Tab.swift:571` Release 恒开 inspectable，我只核到「预编译块的**文本边界**」（`:552 #if` / `:562 #endif` / `:571` / `:573 #if`），**未实跑构建验证 Release 产物里确实生效**。它自己的 §6 也标「未验证」——**这个两分法必须连带进 SUMMARY，不能因我的复核而升咖**。

### 7.6 已验证 vs 未验证（保持诚实边界）

| 结论 | 状态 |
|---|---|
| window 11 属性、tab 10 属性的**集合** | 已验证（XML 解析，非 grep） |
| 勘误表 8 项行号（7 项一次命中，1 项二次修正） | 已验证（正则定位 + XML 交叉） |
| tab 属性区间精确值 | 已验证：首行 `:142-170`，含闭合 `:142-172`（现文档采用后者） |
| 动词数 12 | 已验证（grep + XML 双法） |
| `grep 142-174` 零残留 | 已验证（正文/汇总/勘误表/§7.2 四处均无） |
| `Tab.swift:571` Release 生效 | **文本边界已验证；产物未验证（禁构建）** |
| safaridriver 能否 attach | **未验证**（需真机） |

> 本节只读，未改仓库任何文件；唯一写入为本文件。

---

## 八、`ecosystem-gaps.md` 补复检（补检时 37 行 / 3380B，现 39 行）

文件于 19:33 落盘（首轮复检时尚未存在，见文首事实更正）。落盘者为 **@auto-probe**（文末自署，非 @eco-probe）。按全文性质：三类各 3 行结论，属缩小版交付。

### 8.1 抽查结果

| 报告断言 | 我的核实 | 判定 |
|---|---|---|
| DNR 头条 `patched` + `js:dnr`（`compatibility.json:382-384`） | `:382-384` **逐字一致**：`"status":"patched","implementation":"js:dnr"` | 成立 |
| `updateStaticRules`/`getDisabledRuleIds`/`isRegexSupported` 均 `emulated`（`:386-400`） | `:386` 起成员块确认 `emulated` / `js:dnr` | 成立 |
| DNR 四条 `notImplemented`（`_unsupported.txt:11-14`） | `:11-14` **逐条对上**（getMatchedRules/setExtensionActionOptions/testMatchOutcome/onRuleMatchedDebug） | 成立 |
| `declarativeNetRequestFeedback`（`:65`） | `:65` 逐字一致 | 成立 |
| **`webRequest` 是 `js:webRequest` 桥**（`:429-431`） | 行号对，但**状态词错**：实为 **`patched`**，不是 `bridged` | **错误（见 8.2，已由作者修正于 8.2b）** |
| `webRequestBlocking` 限制项（`:109-110`） | `:109-110` 仅 `catalog/order` 声明；实体判定在 `_unsupported.txt:75`（`notImplemented`）。**报告原稿只写「限制项」漏提 notImplemented，属第二条缺失** | 成立（作者已于 8.2b 补正） |
| `userScripts` `bridged`/`swift:userScripts`（`:613-615`） | 逐字一致；`_unsupported.txt` grep `userScripts` **零命中** | 成立 |
| `proxy` `bridged`/`swift:proxy`（`:589-596`） | 逐字一致；`_unsupported.txt` grep `proxy` **零命中** | 成立 |
| `proxy` 多处出现，以 `:589` 实现块为准 | 我python遍历确认：`/claims/proxy`=bridged、`/permissions/proxy`=**partial** — 它对「多口径」的提醒是对的 | 成立 |

### 8.2 唯一实质错误：`webRequest` 的 `patched` 被写成 `bridged`

```
python 遍历 compatibility.json：
  /claims/webRequest:  patched   impl=js:webRequest     ← 真实
  /claims/proxy:       bridged   impl=swift:proxy
  /claims/userScripts: bridged   impl=swift:userScripts
```

报告第 3 节写：「**`webRequest` 是 `js:webRequest` 桥**（`compatibility.json:429-431`）」。

**问题不在行号（`:429-431` 确实指向 webRequest），而在把 `patched` 归入了 `bridged` 语义。** 这两者在本文自己的口径表里是分开的两档：

- `bridged` = Swift 桥（原生能力，如 proxy/userScripts）
- `patched` = JS 补丁（在 JS 层补，与原生不等价）

**为什么这处不能算小事**：报告的结论 3 写「MV2 老式同步阻断不完全等价 Chrome」，如果把 `webRequest` 误读为 `bridged`（原生桥），读者会以为**底层是可靠的，只差 MV2 同步**；实际它是 `js:webRequest` **JS 补丁**，**整条 webRequest 链路都在 JS 层模拟**。这会直接影响读者对广告拦截可靠性的判断。

**正确措辞**：`webRequest` 是 **`patched`（`js:webRequest` JS 补丁）**，与 `proxy`/`userScripts` 的 `bridged`（Swift 原生桥）**不同档**。

### 8.2b 修复验收（@eco-probe 已于 #158 改完，我逐处验过）

`ecosystem-gaps.md` 现 **39 行**。验收：

| 验收项 | 实测 |
|---|---|
| §1.3 状态词 | ✅ 已改为「`patched`（JS 补丁）**而非 `bridged`**」 |
| 行号引用 `:429-432` | ✅ 准确（`:429` `"webRequest": {`、`:430` `"status":"patched"`、`:431` `"implementation":"js:webRequest"`） |
| **新增 `webRequestBlocking` 证据** | ✅ 已补 `_unsupported.txt:75` 为 `perm\|webRequestBlocking\|notImplemented`；并指明 `:109-110` 只是限制项声明 |
| 结论升级 | ✅ 已从「MV2 不完全等价」升级为「**整条 webRequest 链路 JS 层模拟 + 同步阻断未实现**」 |
| 更正块保留历史 | ✅ 文末 `:39` 标注「@verify-c #156 检出，已改」，原错描述未抹 |

**它比我多补了一步，这点要记**：我 §8.1 表把 `webRequestBlocking` 判为「成立（引用位置可更准）」，只指出它引用位置不准；**但它“只写限制项、漏提 notImplemented”本身就是第二条缺失**，比我原判更重。它自己在 #158 里承认了这个「叠加错误」（值对档错 + 该补的证据没补），**这个自认比我给的判定更严**。

### 8.3 关于错法的二分（采纳 @coordinator #151 的精确版）

@coordinator 指出我 §7.4 的结论不够严格：`auto-probe` 的 `:142-174` **不是「没回填」，是「回填时算错了边界」**。这两种错的性质不同：

| 错法 | 特征 | 能被什么拦住 |
|---|---|---|
| A. 资料对了、正文没回填 | **信息不同步**（有正确值，但没同步到位） | 人工纪律（改完回头搜一遍） |
| B. 回填时算错边界 | **信息同步了、但值是错的**（正文和附录一起错） | **只有第二人核 / 机械校验** |

**这条对我 §7.4 的修正**：我当时写「回填后要拿新值反查边界」，**这句纪律只能防 A，防不了 B**。B 的情形下，作者反查也是拿自己算错的边界去比，**依然错**。

→ 因此 §7.4 的结论应收紧为：**不是「作者自查无用」，而是「自查只能防不同步（A），不能防计算错误（B）；B 类必须外部核或机械校验」。**

**本次 `ecosystem-gaps.md` 的 `webRequest` 错误属于第三类（C）**，值得单列：

| 错法 | 特征 | 本例 |
|---|---|---|
| C. **归类错**：值抄对了、档位判错了 | 行号对、字符串对，但**把 `patched` 读成 `bridged`** | §8.2 |

C 类**既不是不同步，也不是算错**，而是**语义归类错**：因为**每个字都对**，grep 查不出。

**C 类的真正根因（@auto-probe #162 挖到，我已独立复算确认）**：不是「看错了一个词」，而是 **`compatibility.json` 有三套互不可比的 status 词汇表**。我 python live-parse 独立复算：

| 节 | 条数 | 带 status | 词汇表 |
|---|---|---|---|
| `groups` | 47 | **0（全无）** | —（只有 `catalog`/`order`） |
| `claims` | 49 | 49 | `native / patched / bridged / deprecated / unsupported` |
| `permissions` | 41 | 41 | `supported / partial / unsupported` |

**致命处**：`claims ∩ permissions` = **29 个同名 key，其中 22 个 status 不同**：
```
webRequest: claims=patched      permissions=supported   ← 两者都对，问答不同问题
storage:    claims=native       permissions=partial
cookies:    claims=patched      permissions=partial
```
`claims` 答「怎么实现的」、`permissions` 答「获授后能不能用」。**拄错节不报错，只会静默拿到另一维度的值** —— 这才是 C 类的土壤。

**所以 §8.3 上一版的措辞（「机械校验防不住 C」）太悲观，必须修正**：

> **【修正后的定稿】机械校验能拦住跨节 C（更大多数）；只剩同一节内的档位误读需人工。**

两条断言即可机械化：
1. 引作「实现形态」必来自 `claims`；引作「可用性」必来自 `permissions`；`groups` **永不得作 status 依据**。
2. 被引 key 必须唯一定位到节（实测：`groups∩permissions` 重名 **24** 个、`claims∩permissions` 重名 **29** 个，**合计需写节名的 key = 34**）。

→ 只剩 `patched` ↔ `bridged` 这类**同在 `claims` 内**的档位误读，才是真正人工项。

**一条它没说、我实测补上的陷阱**：`webRequestBlocking` **不在 `claims`**（我 python 验证 `'webRequestBlocking' in claims → False`）。它只存在于 `permissions`（`unsupported`），**在 `groups` 里另有一条同名条目**。

> **但 @coordinator #166 对这里的措辞提出了质疑，我核实后确认「须改描述、结论不变」**：
> - 我原写「它在 `groups`（无 status）」——容易被读成「`groups` 里有个同名**实体**」。
> - **精确事实（我 python 复算）**：顶层 `groups` 47 条**全部只有 `{catalog, order}` 两个字段，带 `status` 的 = 0 条**；`groups.webRequestBlocking` = `{'catalog': 'extension.limit.webRequestBlocking', 'order': 200}`，**确实无 status，但它是「分组元数据」而不是「能力实体」**。
> - 而 `permissions.webRequestBlocking` 里的 `"group": "webRequestBlocking"` 只是一个**指向分组名的字符串**，不是实体。
> → **所以 C3 的机械拦截机制应表述为**：「**顶层 `groups` 是元数据表（值为 None）**」，而**不是**「`groups` 里有个无 status 的同名实体」。
> → **结论不变**：回退到 `groups` 确实拿不到 status，C3 仍可机械拦。差的是「为何拦得住」的理由。
>
> **另：@coordinator 消息里引的那句 `groups.webRequestBlocking` = `{"status":"unsupported", ...}` 有误**（该值不存在；`unsupported` 属于 `permissions:1038-1042`，我在 `SUMMARY.md:244` 看到它已正确写成 `{catalog, order}`）。**以 `SUMMARY.md` 文件为准，board 消息那句是笔误。**

**所以真正的致命条件不是“抄错节”，而是“抄错到会返回空值的位置”**：该 key 在 `claims` 里根本不存在——若某人默认“实现形态都查 `claims`”，他会直接查不到；若他退而求其次去 `groups` 拿，**会拿到一个只有 `catalog`/`order` 的元数据条目、取 `status` 得 `None`，而且不会报错**。
> → 断言 1 应再加半句：**「某个 key 在预期节不存在时，不得回退到其它节取值，应报『未在 <节> 定义』」**。没有这半句，断言 1 会被“找不到就换个节找”绕过。

**C3 不是特例：实测 12 名（@coordinator 在 `SUMMARY.md:244` 量化，我独立复算完全一致）**：
```
permissions 不在 claims 的 key = 12：
  clipboardRead, contentSettings, declarativeNetRequestFeedback,
  declarativeNetRequestWithHostAccess, downloads.open, geolocation,
  identity.email, nativeMessaging, readingList, ttsEngine,
  webRequestAuthProvider, webRequestBlocking
其中同时在顶层 groups = 5：clipboardRead, contentSettings, geolocation, readingList, webRequestBlocking
```

**叠加效应仍成立**：本例同时发生「值对档错」+「该补的证据没补」，两层叠加使 C 类更难单点发现。

### 8.4 结论

- `ecosystem-gaps.md` 的**三类框架、12 条证据链引用，除 `webRequest` 状态词外全部准确**。
- 它的「口径提醒」段（`bridged/patched/emulated 都不等于 Chrome 原生等价`）写得好，但**它自己在 `webRequest` 上就违反了这条** —— 正因为 `patched` 与 `bridged` 都写成了「桥」。
- **已修正，现 39 行可用**：`webRequest` → `patched`（`js:webRequest` JS 补丁），并强调与 proxy/userScripts 的 `bridged` 不同档。
- **归属已确认（@eco-probe #158、@auto-probe #162 双重确认）**：`eco-probe` 与 `auto-probe` **是同一个 agent 的两个署名**（agent 名 `eco-probe`，所有产出自署 `@auto-probe`）。**不存在两个 worker 互相甩锅**。作者 = eco-probe（自署 auto-probe），单一作者。

### 8.4b 一处行号笔误（@auto-probe #162 §3.2 内，我发现）

#162 在 §3.2 写：

> `webRequest` 本体：`claims:429-432` = `patched`/`js:webRequest`；**`permissions:429`** = `supported`。

**这个 `:429` 又拄串节了**。实测：

```
grep -n '"webRequest"' compatibility.json
  429:    "webRequest": {   ← 在 claims 节，值 = patched
  1032:   "webRequest": {   ← 在 permissions 节，值 = supported
```

→ `permissions` 的 `webRequest` 在 **`:1032`**，不是 `:429`。`claims:429-432` 那个坐标是对的。

**为何必须记下**：这不是普通笔误——它恰恰发生在**它自己警告「必须指明哪个节」的那一段里**，而且是把 `claims` 的行号写给了 `permissions`。**串节错误第三次出现（前两次：首版 C 类、上一稿「只有 permissions 带 status」）。**

**但性质要说准**：它**不影响任何结论**（§3.2 的 47/49/41、29/22、词汇表全部正确，我已独立复算）。这是一次**引用行号时的串节**，不是表格里的错值。

> 这个反例比任何建议都更有力：**只要还在用「行号 → 节」这种双重坐标引用，串节就会反复发生**。→ 建议引用重名 key 时**只写「节 + key」（如 `permissions.webRequest`）而不写行号**，行号交给脚本生成。

### 8.5 `nativeMessaging` 「未解」——**已被反驳，我改判为「已核」**

我 §8.4 原写「`nativeMessaging` 口径矛盾，至今未解」。**@eco-probe #158 给了硬结论，我逐条验过，改为「已核」。**

**我原来的错**：把 `ExtensionReport.swift:176` 当成「已实现能力清单」，因而判它和 `_unsupported.txt` 矛盾。**实际它是「需用户点头的权限提示集」**：
```
ExtensionReport.swift:172-173  注："Permissions an extension gets only when you say so,
                                  when it asks for one later: what Chrome warns about"
ExtensionReport.swift:174      static let askedPermissions: Set<String> = [ … ]
```
变量名就叫 `askedPermissions`。**列在里面的 `pageCapture`/`desktopCapture` 也是 unsupported —— 它列的是“需授权的敏感权限”，不是“我们支持的能力”。** 我误把两个含义不同的集合当成了同一维度的矛盾。

**正确事实（我独立复核）**：
| 断言 | 证据 | 判定 |
|---|---|---|
| `nativeMessaging` 真实实现 | `ExtensionHost.swift:1774` `final class NativeMessagingHost`；**`:1769-1770`** 注释明写「Chrome's native messaging protocol (length-prefixed JSON over stdio)… **This is how the 1Password extension reaches the 1Password app.**」（`@available` @`:1773`） | ✅ |
| 权限授权点 | `:614` `context.setPermissionStatus(.grantedExplicitly, for: .nativeMessaging)` | ✅ |
| 能力表判 supported | `compatibility.json:946` `"nativeMessaging": { "status": "supported" }` | ✅ |
| `ExtensionReport:176` 非能力表 | `:174` `askedPermissions` + `:172-173` 注释「only when you say so: what Chrome warns about」（即权限提示集） | ✅ |
| release 无禁用开关 | `ZIGZAG_BLOCK_NATIVE_MESSAGING` 全仓 **2 处命中**，均在 `:1840 #if DEBUG`…`:1850 #endif` 内（`:1842` 注释、`:1844` 取值）；另 `:1846` 读 `NativeMessagingHosts/*.json` | 成立 |

> **自记一处坐标偏差**：我上一版写注释在 `:1772-1773`，实测是 **`:1769-1770`**（`:1772-1773` 是注释尾句与 `@available`）。**#162 给的 `:1769-1770` 才对。** 又一次证明本节的反例：双坐标（行号+语义）引用容易错位。

→ **改写为：「`nativeMessaging` 支持（`:1774` NativeMessagingHost，`compatibility.json:946` supported）；`ExtensionReport:176` 是权限提示集非能力表；`ZIGZAG_BLOCK_NATIVE_MESSAGING` 仅 DEBUG，release 无禁用开关。」**

**为什么这条重要**：它意味着 **1Password/Bitwarden 整类不应该被标灰**。若 SUMMARY 继续标「密码管理器未查」，会与代码事实相反。

> **纪律自认**：我上轮把一个「权限提示集」读成「能力清单」，然后据此宣布「两处口径矛盾」——**这是我把两个不同维度的集合当成了矛盾**，比“没查”更糟（没查是空白，误判是错误信息）。@eco-probe 用 `:172-173` 的注释直接推翻我的判词，证据链干净。

> 本节只读，未改仓库任何文件；唯一写入为本文件。

---

## 九、对 @coordinator #166 三点裁定的回应

@coordinator 在 #166 三处与我交涉。逐条给实测裁定：

### 9.1 他提的「纠正你半句」——**方向对、证据引错，且他文件里写对了**

他写道：
> `groups.webRequestBlocking` = `{"status": "unsupported", ...}` —— 等等，这里我要纠正你半句：**`groups` 那条其实带 `status`**。

**实测这条不成立**。`webRequestBlocking` 在 JSON 里共 2 处：
```
:109   groups.webRequestBlocking      = {'catalog': 'extension.limit.webRequestBlocking', 'order': 200}   ← 无 status
:1038  permissions.webRequestBlocking = {'status': 'unsupported', 'reason': 'notImplemented', 'group': ...}
```
顶层 `groups` 共 47 条，**带 `status` 的 = 0 条**，字段集合只有 `['catalog', 'order']`。**不存在「带 status 的 groups 条目」。**

→ 他引的那个 `{"status": "unsupported", ...}` 是 **`permissions:1038-1042`** 的值，被安到了 `groups` 头上。

**但这不影响采纳**：他真正要说的「C3 机制要精确成『顶层 groups 是元数据表』而非『groups 里有个同名实体』」——**这个批评我接受，措辞已改（§8.3）。** 我原来的写法确实容易被读成后者。

**且他自己的文件写对了**：`SUMMARY.md:244` 是
> 顶层 `groups` 条目只有 `{catalog, order}`（实例：`groups.webRequestBlocking` = `{"catalog":"extension.limit.webRequestBlocking","order":200}`），**无 `status` 字段**。

→ **以 `SUMMARY.md` 为准，board 消息那句是笔误。** 这也是「同一事实在两处不一致」的又一实例，与他 #166 里「你 ⑥ 那段不留名」的审慎是同一层考虑。

### 9.2 C3 量化 12 名 / 5 个——**我独立复算，完全一致**
```python
permissions 不在 claims = 12：clipboardRead, contentSettings, declarativeNetRequestFeedback,
  declarativeNetRequestWithHostAccess, downloads.open, geolocation, identity.email,
  nativeMessaging, readingList, ttsEngine, webRequestAuthProvider, webRequestBlocking
其中同时在顶层 groups = 5：clipboardRead, contentSettings, geolocation, readingList, webRequestBlocking
```
与 `SUMMARY.md:244-250` **逐字吻合**。这条我背书。

### 9.3 「SUMMARY 从没标灰过」——**他说得对，我撤回那句提醒**

我说「`SUMMARY` 不得再把 1Password/Bitwarden 标灰」——查 `SUMMARY.md`：
- `:122` 表格写「密码管理器 / 自动填充 | **部分未查**」
- `:144` 写「**未查**：密码管理器链路」
- `:208` §4.2 明确「`nativeMessaging`：**支持**（三段证据）」

**从未标灰。** 我那句是基于 #162 的旧印象，**应撤回**。按他要求：我确实没在他文件里看到灰色标记，无行号可给。

### 9.4 但我核出一个新错（`SUMMARY.md:210`，bridge.js 行号标反）

`SUMMARY.md:210` 写：
> **调用端**（扩展侧 JS）：`bridge.js:151` `connectNative(HOST)`、`:65` `sendNativeMessage(HOST,…)`

**实测恰好相反**：
```
bridge.js:65    Promise.resolve(api.runtime.sendNativeMessage(HOST, { ns, fn, args: … }))   ← :65 是 sendNativeMessage
bridge.js:151   port = api.runtime.connectNative(HOST);                                      ← :151 是 connectNative
```

→ 应为 **`:65` `sendNativeMessage`、`:151` `connectNative`**。**两处动词互换，行号本身都对。**

**判定：C4 类（同节内档位误读）的变体——值都对、映射错了。** 不影响「nativeMessaging 支持」结论（三段证据另两条 `:946`/`:614` 我验过成立），但若有人照 `:151` 去找 `connectNative` 再读 `:65`，会对不上。

### 9.5 关于「不点名」
他决定 SUMMARY 只写规则、不写「谁翻过车」。**我同意，且我是受益更少的一方**（我那两处错本可被隐去）。理由他给得对：指名会让读者以为「避开那几个人就行」，而规则是给所有人的。**我的原句留在本报告内随语境读，属于合适的落点。**

> 本节只读，未改仓库任何文件；唯一写入为本文件。
