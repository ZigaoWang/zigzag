# verify-b —— 复检报告（只读 verifier）

**复检对象：**
- `.audit2/ecosystem-gaps.md` —— **不存在**（抽查 0 条）
- `.audit2/automation-gaps.md` —— **不存在**（抽查 0 条）

**抽查结论：抽查 0 条，0 条有问题。**

两份报告在复检时（`.audit2/` 目录为空，`ls -la` 仅有 `.`/`..`）尚未落盘，也无任何字节写入。
按指令「文件不存在或为空就前进下一份并注明，不要编造」，本报告**不对不存在的报告编造任何条目判定**。

为避免这一轮复检空转、并给 coordinator 与 worker 留下**可复用的真实基线**，下面附上我独立 grep 得到的**关键事实表（全部 file:line 级证据）**。报告落盘后，可直接用它做逐条对线，尤其是高危的「不存在」类断言。

---

## 一、报告缺失的证据

```
$ ls -la /Users/huaan/zigzag-main/.audit2/
total 0
drwxr-xr-x@ 2 huaan staff  64 Nov 21 22:19 .
drwxr-xr-x@ 29 huaan staff 928 Nov 21 22:19 ..
```
`.audit2/` 为空目录，两份报告 0 字节/不存在。

判定：**无法验证**（对象缺失，非「成立」，也非「错误」）。

---

## 二、独立核到的关键事实（供报告落盘后对线）

### 2.1 「Zigzag 不支持 CDP / 没有远程调试」类断言 —— 判定基线：**成立**

我先按指令试了 remote / debug / port / WebSocket / inspector / CDP 多个词，并核了 WebKit 半公开接口 `isInspectable` / `_WKInspector`：

- `rg -n "isInspectable|_WKInspector|inspectable" --type swift` → **无任何命中**（Zigzag 既没有开 `isInspectable`，也没有用 `_WKInspector`）。
  - 注意点已核到：`debugger` 一词确实出现在两处，但都是**扩展侧声明/stub**，不是宿主远程调试能力：
    - `Zigzag/Resources/Extensions/chrome-api.json` 顶层有 `debugger` 命名空间（属「声明的 API 全集」，非实现）。
    - `Zigzag/Extensions/ExtensionStore.swift:992`
      `add('debugger', { attach: no('Debugging pages'), detach: done(), sendCommand: no('Debugging pages'), getTargets: done([]), ... })`
      → `attach`/`sendCommand` 直接 `no('Debugging pages')` 拒绝。
    - `Zigzag/Resources/Extensions/compatibility.json`：
      `debugger: {status:"unsupported", reason:"webkitMissing", members:{detach: emulated, getTargets: emulated}}`
      仅 `detach`/`getTargets` 空实现，属 emulated。
    - `Zigzag/Extensions/ExtensionCompatibility.swift:262-264`
      `case "extension.limit.debugger": "Debugging pages"` / comment: “A Chrome extension feature Zigzag cannot provide: the debugger API.”
    - 测试侧同口径：`ZigzagTests/ExtensionCompatibilityTests.swift:259-260`
      `#expect(registry.claim(for: "debugger.attach") == nil)`
      `#expect(registry.status(of: "debugger.attach") == .unsupported)`

  → **结论：任何「Zigzag 不支持 CDP / 无远程调试」类断言在仓库内可被坐实为「成立」**，且理由不是「找不到 CDP 字样」，而是 `reason:"webkitMissing"` + 显式 `no('Debugging pages')`。

**⚠ 反向陷阱（给 worker 的警示）**：若某报告因「`chrome-api.json`/`compatibility.json` 里出现 `debugger` 命名空间」而断言「Zigzag 支持 Chrome Debugger / CDP」，则判 **错误**——这些是「声明全集 + unsupported 标记 + stub」，不是能力。

### 2.2 AppleScript 字典 —— 报告若称「支持/不支持 X 动词」，以此为准

字典真实存在：`Zigzag/Resources/Zigzag.sdef`（228 行）。实测命令/类：
- Standard Suite：`open`(10) `close`(17) `quit`(22) `count`(26) `delete`(35) `exists`(40) `make`(46)
- Zigzag Suite：`current tab`(131) `space`(135)，类 `tab`(140)/`window`(82)/`application`(60)
- 扩展命令：`do JavaScript`(193，需 Settings › Automation 开关) / `execute`(202，Chrome 风格别名) / `reload`(211) / `go back`(216) / `go forward`(221)

实现侧：`Zigzag/App/Scripting.swift`（475 行）
- `Scripting.allowsJavaScript` 默认 **false**，key `AllowJavaScriptFromAppleEvents`（5-9 行）
- `NSScriptCommand` 处理：`handleCloseScriptCommand`(333) `handleTabScriptCommand`(339) `handleExecuteScriptCommand`(344)
- `performDefaultImplementation` 分派：`go back`(350) `go forward`(351) `delete`(352)
- 私有窗口/`Zigzag Mini` 永不暴露给脚本（`windows` 过滤 `isPrivate`）

→ 报告若断言「无 AppleScript 支持」= **错误**；若断言「有 AppleScript 且 do JavaScript 默认关」= **成立**（sdef:193 + Scripting.swift:5-9）。
→ 报告若断言「支持某动词」，必须落在这串清单里；清单外动词（如 `save`/`print`/`duplicate`）属**未声明**，可判「不存在」成立。

### 2.3 MCP / 自动化面 —— 反驳任何「Zigzag 无程序化控制」类断言

- `Zigzag/MCP/` 存在完整实现 12 文件：`MCPServer.swift / MCPService.swift / MCPTools.swift / MCPBrowser.swift / MCPHTTP.swift / MCPEndpoint.swift / MCPPageScript.swift / MCPWait.swift / AgentControl.swift` 等。
- `docs/automation.md`（334 行）。
- URL scheme：`Zigzag/Info.plist:75-90` 声明 `http`/`https`/`zigzag-webapp`；`AppDelegate.swift:61-62` 注册 `kAEGetURL`，`:300` 处理。
- `docs/automation.md:165` 明文限制：`press_key` 不向密码框/iframe 输入特定字符。

→ 「Zigzag 没有自动化接口 / 只能靠 GUI」= **错误**（MCP 全套 + URL scheme + AppleScript 三通路并存）。
→ 「`press_key` 有密码框限制」= **成立**（docs/automation.md:165）。

### 2.4 「有意不做」类判断 —— 依据强度分级

仓库内能坐实「主动放弃/不提供」的**明文**只有扩展兼容层的 `reason` 与 `no('...')` 文案，例如：
- `ExtensionCompatibility.swift:262` `"Debugging pages"`（debugger）
- `ExtensionStore.swift` 各 `no('Downloads from extensions')` / `no('Bookmarks from extensions')` / `no('Searching from extensions')` / `no('Signing in through the browser')` 等

这些属「**实现层显式拒绝**」，可判 **成立（明确不支持）**；但**不等于**「产品层面故意不做」。
若报告把上述写成「Zigzag **故意/有意设计**不做 X」而拿不出 README/docs 明文，判 **依据不足**（指令第 4 条）。
本次仅见 `docs/download-rules.md:74`「it cannot choose what runs or where the values are sent」与 `docs/automation.md:165` 两处显式 limitation，其余「by design」措辞在 README/docs 中 **grep 无命中**。

---

## 三、判定规则（本轮已备好，等报告落盘即执行）

| 等级 | 定义 |
|---|---|
| 错误 | 与 file:line 证据相反（如「有 AppleScript」→ 实为有；「支持 CDP」→ 实为 unsupported） |
| 夸大 | 方向对但程度过（如「无任何调试能力」忽略 `isInspectable` 空白 + 扩展 getTargets 空壳） |
| 已实现 | 报告列为「缺口」，实际已在仓库实现（如 MCP、AppleScript、URL scheme） |
| 无法验证 | 对象不存在 / 无 file:line 可落 |
| 成立 | file:line 可坐实 |

---

## 四、交付说明

- 未修改仓库任何文件；唯一写入为本文件 `/.audit2/verify-b.md`。
- 未修改任何被检报告（均不存在，无从修改）。
- 建议：两份报告落盘后，**重发一次复检指令**，我将按二节基线逐条抽查 ≥60%，重点核 2.1（CDP）与 2.2（AppleScript）两条高危断言。
