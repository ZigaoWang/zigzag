# Zigzag 扩展生态差距：广告拦截 / 用户脚本 / 代理（三类）

审计范围：只读。结论附 `file:line`。状态词取自 `Zigzag/Resources/Extensions/compatibility.json`：
`supported`（原生）/ `bridged`（Swift 桥）/ `patched`（JS 补丁）/ `emulated`（模拟）/ `unsupported`（实现缺）。

> 交付范围按 @coordinator #143 缩小版：三类各 3 行结论。三类之外的扩展能力（密码填充链路、书签、历史等）不在本文。

---

## 1. 广告拦截（declarativeNetRequest / webRequest）

1. **`declarativeNetRequest` 头条是 `patched`（JS 补丁），非 `supported`** —— `compatibility.json:382-384`（`"status":"patched","implementation":"js:dnr"`）；三个子项 `updateStaticRules` / `getDisabledRuleIds` / `isRegexSupported` 均为 `emulated`（`:386-400`），是**模拟**不是原生规则引擎。
2. **关键规则能力有实缺**：`getMatchedRules`、`testMatchOutcome`、`setExtensionActionOptions`、`onRuleMatchedDebug` 全部 `notImplemented`（`_unsupported.txt:11-14`）；`declarativeNetRequestFeedback` 权限同样 `notImplemented`（`:65`）。→ **uBlock Origin 这类重度用 DNR 计数/调试 API 的拦截器会缺调试与统计面**。
3. **`webRequest` 是 `patched`（JS 补丁）而非 `bridged`（Swift 桥）** —— `compatibility.json:429-432`（`"status":"patched","implementation":"js:webRequest"`）；且 `webRequestBlocking` 权限为 **`notImplemented`**（`_unsupported.txt:75`：`perm|webRequestBlocking|notImplemented`），`compatibility.json:109-110` 的 `extension.limit.webRequestBlocking` 只是限制项声明。→ **整条 webRequest 链路都在 JS 层模拟，且同步阻断（blocking）直接未实现**，比 MV2「不完全等价」更严重。结论：日常广告拦截（DNR 规则注入）能工作，但 webRequest 观察/阻断与 DNR 高级查询/反馈均有缺口。

## 2. 用户脚本（userScripts）

1. **`userScripts` 判 `bridged`（Swift 桥），非原生** —— `compatibility.json:613-615`（`"status":"bridged","implementation":"swift:userScripts"`）。
2. `_unsupported.txt` 中**无** `userScripts.*` 叶子条目（grep `userScripts` 该文件零命中）—— 即无已知子项缺失，**Tampermonkey / Violentmonkey 的 API 面基本覆盖**。
3. 属三类中**最完整**的一类：桥接实现 + 无未实现子项。结论：用户脚本管理器可用，是生态里最不该担心的那块。

## 3. 代理（proxy）

1. **`proxy` 判 `bridged`（Swift 桥）** —— `compatibility.json:589-592`（`"status":"bridged","implementation":"swift:proxy"`），子项 `settings` 亦 `bridged`（`:593-596`）。
2. `_unsupported.txt` 中**无** `proxy.*` 叶子条目 —— 无已知子项硬缺。
3. 注意 `proxy` 出现在 `compatibility.json` 多处（`:185` 需求清单、`:589` 实现块、`:968` 二进制判定块），判定以 `:589` 实现块为准。结论：SwitchyOmega 类代理切换能用，桥接而非原生。

---

## 附：证据索引

- `compatibility.json:382-400`（DNR 补丁+模拟）/ `:429-431`（webRequest）/ `:613-615`（userScripts）/ `:589-596`（proxy）
- `_unsupported.txt:11-14`（DNR 四个 notImplemented）/ `:65`（DNR Feedback 权限）
- 三类的 `_unsupported.txt` 缺失对照：DNR 有 5 条缺、userScripts 零条、proxy 零条

> **口径提醒**：`bridged`/`patched`/`emulated` 都**不等于** Chrome 原生等价。本文只陈述"实现形态与已知缺口"，不主张"与 Chrome 完全一致"。
> 本文由 @auto-probe 落盘（@coordinator #145 指派缩小版）；nativeMessaging 的密码管理器链路属另一线，见 `SUMMARY.md`，不在本文。

> **更正（@verify-c #156 检出，已改）**：§1.3 原写 `webRequest` 为「`js:webRequest` 桥」，**归类错** —— 状态实为 `patched`（JS 补丁），非 `bridged`（Swift 桥）；行号与实现字符串均对，错在把 `js:` 前缀读成「桥」。同时补正：`webRequestBlocking` 权限是 `unsupported`/`notImplemented`（`_unsupported.txt:75`），非仅「限制」。结论由「底层原生、只差 MV2 同步」修正为「**整条链路 JS 层模拟 + 同步阻断未实现**」。此类「值对、档位错」的错法 grep 与行号校验都拦不住，需对照本文开头 status 口径人工判档。
