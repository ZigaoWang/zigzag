# chrome.userScripts in Zigzag

Goal: Tampermonkey, Violentmonkey and ScriptCat run user scripts in Zigzag as they do in Chrome. Branch `feat/user-scripts`, ships in 0.5.18 once it's been used by hand and feels solid.

## What Tampermonkey actually does (5.5.1, read from its MV3 package)

Background (`background.js`):

- `chrome.userScripts.configureWorld({ csp: "script-src 'self' 'unsafe-inline' 'unsafe-eval' *", messaging: true })`, once, with no `worldId`.
- `chrome.userScripts.getScripts()` for the registered ids, then `unregister({ ids })` for stale ones and `register([script])` for new ones, one per call.
- Each script: `{ id, js: [{ code }] or [{ file }], matches, includeGlobs?, excludeGlobs?, allFrames, runAt (mostly "document_start"), world: "USER_SCRIPT" }`. The code is Tampermonkey's GM API setup with the user's scripts inside it.
- `update` is wrapped but rarely used.
- If `chrome.userScripts` is missing it shows "Please enable the allow user scripts setting" (FAQ Q209) and rechecks every few seconds. That's the screen people see in Zigzag today.
- It listens on both `runtime.onUserScriptMessage` and `runtime.onMessage`, and on both `onUserScriptConnect` and `onConnect`. So messages from user scripts that arrive on the plain events are still heard.

Content (`content.js`) checks `userScripts.onBeforeScript`, which is Firefox only, so in Chrome it takes the other path. Nothing needed there.

Today `api-surface.js` deliberately leaves `userScripts` out, and `ExtensionReport` lists it as missing ("Your own custom scripts").

## Approach

### Recommended: build userScripts on WebKit's own content scripts

`chrome.userScripts` is a JS layer in the extension's background over `chrome.scripting.registerContentScripts`. Swift writes each script's code to a file inside the extension's folder, since WebKit content scripts take files, not code strings.

Why this approach: WebKit then handles matching, frames, timing, `sender.tab`/`frameId`, and `runtime.sendMessage`/`connect` from the script to the background. That's exactly the hard part, and it already matches Chrome's tab IDs, so the background can `tabs.sendMessage` back.

- **register / update:** for each script, Swift (bridge namespace `userScripts`) writes `Extensions/<id>/.zigzag-user-scripts/<hash>.js`.
  - The file is the script's `code` (or the contents of its `file`), wrapped in a check for `includeGlobs`/`excludeGlobs`/`excludeMatches` against `location.href`, plus a guard so it runs once per document.
  - JS then calls `scripting.registerContentScripts({ id: "zz-us-" + id, js: [path], matches, allFrames, runAt, world: "ISOLATED" })`.
- **getScripts / unregister:** from Swift's registry (`UserScripts.json` per extension), the source of truth. Unregister removes the file and calls `scripting.unregisterContentScripts`.
- **configureWorld / resetWorldConfiguration / getWorldConfigurations:** store and answer. CSP: check whether WebKit applies the page's CSP to eval inside content-script worlds (test on github.com).
- **execute** (Chrome 135+): `scripting.executeScript` with a written file.
- **Restarts and extension updates:** on load, re-write the files and re-register from the registry. Don't rely on `persistAcrossSessions`.
- **Permission:** Chrome 138+ needs the per-extension "Allow user scripts" switch. In Zigzag, installing an extension that asks for `userScripts` is the consent, since the install sheet names it.

Trade-off: user scripts share the extension's content-script world instead of a separate USER_SCRIPT world, so they also see `chrome.storage` etc. With `messaging: true` they can already message the privileged background, so the trust is the same in practice. Write this down in the code.

Must be proven first (spike, step 1):

1. That WebKit's `scripting.registerContentScripts` works for an extension's background in Zigzag.
2. That WebKit serves a file written into the extension folder after the extension has loaded. If it caches the folder, a reload of the extension context after writing may be needed. That's acceptable only if it doesn't drop the background's state, so measure it.

### Fallback: Zigzag's own world

If the spike fails, use a `WKContentWorld` per extension, with `WKUserScript`s on every tab's content controller wrapped in a URL/frame check. Add a `chrome.runtime` shim in that world posting to a `WKScriptMessageHandlerWithReply`. Swift relays to the background as `runtime.onUserScriptMessage`/`onUserScriptConnect` over the bridge's event port, with replies over the bridge.

The hard part is giving `sender.tab.id` the same number WebKit's `chrome.tabs` uses (Tampermonkey keys badge counts and menu commands by it). Find out first whether that's possible before going this way.

## Steps

1. **Spike** (half a session): a tiny unpacked test extension that registers a content script from a file written after load. Prove or disprove the two points above. Also reproduce "Tampermonkey doesn't open" (its popup) on 0.5.17 and note why.
2. **Swift:** `BridgeUserScripts` namespace (permission `userScripts`), with registry, file writing, cleanup on `release` and on uninstall, and re-registering on load. Add `userScripts` to `ExtensionBridgeScript.permissions` and remove it from `ExtensionReport.limitNames`.
3. **JS:** `chrome.userScripts` in `bridge.js` (background only, as in Chrome), with Chrome's argument checks and error messages (duplicate id, empty matches, bad runAt). Stop `api-surface.js` skipping it once it exists. Add `runtime.onUserScriptMessage`/`onUserScriptConnect` as aliases that never fire, since messages arrive on `onMessage`/`onConnect`.
4. **Tampermonkey by hand:** install a script from Greasy Fork (the install page must open from a `.user.js` link), then run 4–5 popular ones. Cover `@grant none`, `GM_xmlhttpRequest` cross-site, `GM_setValue`, menu commands, `@run-at document-start`, frames, and a strict-CSP site (github.com). Also check the badge count and the popup's script list. Ask the LINUX DO thread for their must-have scripts.
5. **Violentmonkey and ScriptCat:** same checks, one extension at a time, removing each before the next.
6. **Edge cases:** private windows (no user scripts unless the extension is allowed there), turning the extension off or removing it (scripts stop, files go), extension update (re-registered), many scripts (startup time).
7. **Release 0.5.18:** a CHANGELOG entry and a note in the LINUX DO thread.

## Rules while doing it

- One extension loaded at a time in a test copy. No bulk runs.
- No pages that autoplay sound.
- No osascript keystrokes.
- Conventional commits, one small change each, no co-author lines.
