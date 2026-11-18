# Apps on This Mac (Local Receivers) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a site's own scripts and an extension's own code reach a program listening on this Mac over loopback —
`fetch`, `XMLHttpRequest` and `WebSocket` — through one native runner, behind one switch per site (plus a global
master switch) and one switch per extension.

**Architecture:** `LocalReceivers` is the runner: it validates loopback, makes a native `URLSession` request (or opens
a `URLSessionWebSocketTask`) presenting the caller's own `Origin`, and for a site enforces the helper's CORS reply
exactly as a browser would. `LocalReceiverShim` is the page-side patch, injected into the page's own world by `Tab`;
native decides the asking origin from `message.frameInfo.securityOrigin`, never from the message. The extension door
reuses the same runner from `BridgeExtensionFetch` and `WebSocketBridge`, keyed by a per-extension grant stored with
the extension's other answers. The site door needs `LocalReceivers.isEnabled` (global, off) **and** the site's switch;
the extension door needs only the extension's switch.

**Tech Stack:** Swift 6 (main-actor by default), AppKit, WebKit, Swift Testing (`#expect`), XcodeGen, JavaScript
resources under `Zigzag/Resources/Extensions/`.

**Spec:** `docs/superpowers/specs/2026-11-15-local-receivers-design.md`

## Global Constraints

- `SWIFT_VERSION: "6.0"`, `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor`, deployment target macOS 15.4.
- No Xcode on this Mac. The authoritative gate is CI (`xcode-27`). The local gate is the CLT harness described in
  Task 0; it compiles every `Zigzag/**/*.swift` and the named suites.
- New user-facing strings use `String(localized:)` with a `comment:`; the catalog catches up from a build.
- Feature name in code and comments: **Local Receivers**. User-facing words: **Apps on this Mac** for a switch, and
  **Allow websites to reach apps on this Mac** for the master setting. Never say "local network".
- A private window's page is refused and keeps nothing. Extensions never run in a private tab.
- A refused call fails as WebKit's block fails today: `fetch` rejects (`TypeError`), XHR fires `error`, a socket
  closes. The page is never told a switch exists.
- The site door is per **page origin** (`SiteOrigin.of(message.frameInfo.securityOrigin)`), never the helper's port,
  and one switch covers HTTP and WebSocket to any loopback port.
- Only `http` and `ws` are caught on loopback; `https`/`wss` stay with WebKit.

## Review Focus

1. **Master off, site switch on** — a page's call is still refused, and the Site Controls row is not offered.
   (Task 2 tests this policy directly; Task 3 uses it in the handler.)
2. **Private window** — refused before any storage is read or written, even with both switches on. (Task 3.)
3. **Forged identity** — native reads the frame's origin; a message that claims another site means nothing.
   (Task 3; code inspection + handler guard.)
4. **CORS is still binding for a site** — a `*` reply without `Allow-Credentials` cannot answer a credentialed
   call; a preflight that does not name the method/headers refuses. (Task 1's ported tests.)
5. **Extension door defaults off** — with the grant off, the loopback call returns `{fallback:true}` so WebKit's
   own refusal is what the extension sees, exactly as before this work. (Task 7.)
6. **The `ws://` gate takes something away** — `WebSocketBridge` allows loopback unconditionally today; after Task 8
   an extension needs the switch. The changelog says so. (Task 10.)

---

### Task 0: Branch, plan, and the local gate

**Files:**
- Create: `docs/superpowers/plans/2026-11-18-local-receivers.md` (this file)
- Create (outside the repo): `/private/var/folders/ms/1k14zlbd3t79sp0ygnzn5km00000gp/T/opencode/run_tests-lr.sh`

**Interfaces:**
- Produces: branch `feat/local-receivers` at current `origin/main` (`baa8d9e7`) plus the two design commits; a working
  `ZZ_REPO=… run_tests-lr.sh` command every later task runs.

- [ ] **Step 1: Confirm the branch base**

```bash
cd /Users/user/Scripts/git/zigzag-local-receivers
git log --oneline -3
```

Expected: the design commits (`docs: local receivers need a global site switch and a briefing`,
`docs: a design for reaching a helper on this Mac`) on top of `baa8d9e7 chore: 0.9.2 beta 1`. This worktree is the
code worktree for the branch; build in it, do not create a second checkout.

- [ ] **Step 2: Make the local gate harness**

```bash
cp /private/var/folders/ms/1k14zlbd3t79sp0ygnzn5km00000gp/T/opencode/run_tests-ff-final.sh \
   /private/var/folders/ms/1k14zlbd3t79sp0ygnzn5km00000gp/T/opencode/run_tests-lr.sh
cd /private/var/folders/ms/1k14zlbd3t79sp0ygnzn5km00000gp/T/opencode
python3 - <<'PY'
from pathlib import Path
p = Path("run_tests-lr.sh")
t = p.read_text()
t = t.replace("agent-ff-final", "agent-lr")
t = t.replace("PendingQuestionsTests PageLinkTests SiteControlsPermissionTests FormSheetTests SettingsLayoutTests)",
              "PendingQuestionsTests PageLinkTests SiteControlsPermissionTests FormSheetTests SettingsLayoutTests\n        LocalReceiversTests ExtensionLocalReceiversTests)")
p.write_text(t)
PY
```

Expected: `T=/private/var/folders/ms/1k14zlbd3t79sp0ygnzn5km00000gp/T/opencode/agent-lr`, and both new suite names in
`SUITES`. Run it once from the branch to prove the harness works before any change:

```bash
cd /Users/user/Scripts/git/zigzag-local-receivers
ZZ_REPO=$PWD /private/var/folders/ms/1k14zlbd3t79sp0ygnzn5km00000gp/T/opencode/run_tests-lr.sh 2>&1 | tail -20
```

Expected: `### RUN_TESTS_DONE`. `ExtensionLocalReceiversTests` reports `no suite named` until Task 6; that line is
allowed here and must be gone by Task 6.

- [ ] **Step 3: Commit the plan**

```bash
git add docs/superpowers/plans/2026-11-18-local-receivers.md
git commit -m "docs: the plan for reaching a helper on this Mac"
```

---

### Task 1: The native runner (port `dd4c8a80`)

**Files:**
- Create: `Zigzag/Web/LocalReceivers.swift`
- Create: `ZigzagTests/LocalReceiversTests.swift`

**Interfaces:**
- Produces: `LocalReceivers.isLoopback(_ url: URL)`, `isLoopback(host: String)`,
  `LocalReceivers.send(_:as:transport:) async throws -> Response`, `Identity.site(origin:)`,
  `Identity.webExtension(id:)`, `Request`, `Response`, `Credentials`, `Failure`, `urlRequest(for:as:)`,
  `needsPreflight(_:)`, `preflightHeaderNames(_:)`, `responseLimit`.
- Transport is injectable: `typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)`.

- [ ] **Step 1: Apply the commit**

```bash
git cherry-pick -n dd4c8a80
git status --short
```

Expected: exactly `Zigzag/Web/LocalReceivers.swift` and `ZigzagTests/LocalReceiversTests.swift` added. No conflicts:
both are new files.

- [ ] **Step 2: Read the added runner once, end to end**

Confirm by reading, not by skimming the diff:

- `urlRequest` overwrites `Origin` with `identity.origin`, sets `Sec-Fetch-Site` (`cross-site` for a site, `none` for
  an extension), `Sec-Fetch-Mode: cors`, and a `Referer` for a site; it strips `Host`, `Origin` and `Referer` from
  the caller's headers and never uses the URL session's cookies (`httpShouldHandleCookies = false`).
- A site gets a preflight when `needsPreflight`; an extension does not (`identity.isWebExtension`).
- A site's answer must pass `allowsRead`; with `credentials: include`, `*` is not enough.
- A redirect is refused rather than followed.
- A body over `responseLimit` (32 MB) is refused.
- `defaultTransport` is an ephemeral session with no cookie storage and no cache.

- [ ] **Step 3: Run the ported suite**

```bash
ZZ_REPO=$PWD /private/var/folders/ms/1k14zlbd3t79sp0ygnzn5km00000gp/T/opencode/run_tests-lr.sh LocalReceiversTests 2>&1 | tail -15
```

Expected: all `LocalReceivers` tests pass (12 tests). Fix nothing in the test file unless a real base drift appears.

- [ ] **Step 4: Commit**

```bash
git add Zigzag/Web/LocalReceivers.swift ZigzagTests/LocalReceiversTests.swift
git commit -m "A native request to this Mac carries the caller's own origin"
```

---

### Task 2: The global setting, its briefing, and the site-door policy

**Files:**
- Modify: `Zigzag/Web/LocalReceivers.swift`
- Modify: `Zigzag/Settings/SettingsView.swift`
- Modify: `ZigzagTests/LocalReceiversTests.swift`

**Interfaces:**
- Produces: `LocalReceivers.isEnabled` (UserDefaults, default `false`),
  `LocalReceivers.allowsSite(origin: String) -> Bool` = `isEnabled && SitePermissions.localReceivers(origin:)`.
- Produces: `SettingsView.localReceiversGroup`, `SettingsView.reloadLocalReceivers()`.
- Consumes: `SitePermissions.defaults` (tests swap it), `ConfirmSheet.show(in:title:message:confirmTitle:completion:)`.

- [ ] **Step 1: Write the failing policy tests**

Append to `ZigzagTests/LocalReceiversTests.swift`:

```swift
@Test func theSiteDoorNeedsBothSwitches() {
    let name = "LocalReceiversTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    let before = SitePermissions.defaults
    SitePermissions.defaults = defaults
    let master = LocalReceivers.isEnabled
    defer {
        SitePermissions.defaults = before
        LocalReceivers.isEnabled = master
        defaults.removePersistentDomain(forName: name)
    }
    let origin = "https://creator.zerowork.io"

    LocalReceivers.isEnabled = false
    SitePermissions.setLocalReceivers(true, origin: origin)
    #expect(!LocalReceivers.allowsSite(origin: origin), "off for every site, even where the site said yes")

    LocalReceivers.isEnabled = true
    #expect(LocalReceivers.allowsSite(origin: origin))

    SitePermissions.setLocalReceivers(false, origin: origin)
    #expect(!LocalReceivers.allowsSite(origin: origin))
}

@Test func theSiteDoorIsOffUntilItIsTurnedOn() {
    let name = "LocalReceiversTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    let before = SitePermissions.defaults
    SitePermissions.defaults = defaults
    defer {
        SitePermissions.defaults = before
        defaults.removePersistentDomain(forName: name)
    }
    #expect(!LocalReceivers.isEnabled)
    LocalReceivers.isEnabled = true
    #expect(LocalReceivers.isEnabled)
    LocalReceivers.isEnabled = false
}
```

Run: expect both to fail to compile (`isEnabled`, `allowsSite` absent). That is the intended red step.

- [ ] **Step 2: Add the setting and the policy**

In `Zigzag/Web/LocalReceivers.swift`, inside `enum LocalReceivers`:

```swift
/// The master switch: Settings › Privacy, off until the person reads the briefing and turns it on. The per-site
/// switch is offered only while this is on, and a call is refused without it however the site answered.
private static let enabledKey = "AllowWebsitesToReachLocalApps"

static var isEnabled: Bool {
    get { SitePermissions.defaults.bool(forKey: enabledKey) }
    set { SitePermissions.defaults.set(newValue, forKey: enabledKey) }
}

/// Whether a page at `origin` may use this door now: the person allowed websites in Settings, and allowed this one
/// in Site Controls. A private tab is refused by the caller before this is read.
static func allowsSite(origin: String) -> Bool {
    isEnabled && SitePermissions.localReceivers(origin: origin)
}
```

- [ ] **Step 3: Run the policy tests**

```bash
ZZ_REPO=$PWD /private/var/folders/ms/1k14zlbd3t79sp0ygnzn5km00000gp/T/opencode/run_tests-lr.sh LocalReceiversTests 2>&1 | tail -15
```

Expected: pass.

- [ ] **Step 4: Add the Privacy row and the briefing**

`SettingsView.swift`:

1. Beside `private let sitesGroup = FormGroup()` (line ~886) add:

```swift
/// The one master switch for a page reaching an app on this Mac, above the sites' own answers.
private let localReceiversGroup = FormGroup()
```

2. In `groups(for:)`, `.privacy` case (line ~2594), insert before the sites heading:

```swift
case .privacy: [(nil, blockingGroup), (Self.localReceiversHeading, localReceiversGroup), (Self.sitesHeading, sitesGroup)] + …
```

and add the heading property near `sitesHeading`:

```swift
private static var localReceiversHeading: String {
    String(localized: "Apps on This Mac", comment: "A heading in Settings › Privacy, over the master switch that lets websites reach programs on this Mac.")
}
```

3. In `reloadPrivacy()` (after `sitesGroup.removeAllRows()`) call `reloadLocalReceivers()`.

4. Implement:

```swift
/// One switch, off, and a briefing before it can be turned on. The same words are the site row's name, so the two
/// places read as one feature.
private func reloadLocalReceivers() {
    localReceiversGroup.removeAllRows()
    let toggle = Toggle(isOn: LocalReceivers.isEnabled)
    toggle.setAccessibilityLabel(String(localized: "Allow websites to reach apps on this Mac",
                                        comment: "Accessibility label of the master switch in Settings › Privacy."))
    let more = PillButton(title: String(localized: "What This Allows…",
                                        comment: "Button on the apps-on-this-Mac setting in Settings › Privacy: reopens the briefing."))
    more.onClick = { [weak self] _ in if let self { self.explainLocalReceivers(reason: nil) } }
    toggle.onChange = { [weak self] on in
        guard let self else { return }
        if !on {
            LocalReceivers.isEnabled = false
            return
        }
        // The knob has already moved; the setting follows only the acknowledgement.
        toggle.isOn = LocalReceivers.isEnabled
        self.explainLocalReceivers(reason: { LocalReceivers.isEnabled = true; toggle.isOn = true })
    }
    let controls = NSStackView(views: [more, toggle])
    controls.spacing = Tokens.Space.x2
    let row = FormRow(title: String(localized: "Allow websites to reach apps on this Mac",
                                    comment: "A setting in Settings › Privacy: the master switch for a site's scripts reaching a program listening on this Mac."),
                      detail: String(localized: "A site you switch on in Site Controls can use fetch, XMLHttpRequest and WebSocket to talk to a program on this Mac, over loopback only. Never the local network, and a page can’t switch itself on.",
                                     comment: "Explanation under the apps-on-this-Mac setting in Settings › Privacy. fetch, XMLHttpRequest and WebSocket are API names: keep them as they are."),
                      control: controls)
    row.keywords = String(localized: "localhost loopback local server app fetch websocket xmlhttprequest",
                          comment: "Words that find the apps-on-this-Mac setting with Find a setting. Not shown.")
    localReceiversGroup.add(row)
}

/// The briefing the master switch needs before it goes on. `reason` runs only after "I understand"; without one this
/// is the row's link, read-only.
private func explainLocalReceivers(reason: (() -> Void)?) {
    let message = String(localized: "Websites you switch on in Site Controls can use fetch, XMLHttpRequest and WebSocket to reach programs listening on this Mac, over loopback only.\n\nThe local network, other machines, images, scripts and stylesheets are not included, and a page cannot switch itself on.\n\nA local program may not have been written to be reachable by a web page, and a site you grant could use it in ways you did not intend. Only grant sites you trust.\n\nTurn one site off in its Site Controls, or turn this setting off for every site.",
                          comment: "The briefing shown before websites may reach apps on this Mac. fetch, XMLHttpRequest and WebSocket are API names: keep them as they are.")
    guard let reason else {
        ConfirmSheet.notice(in: self, title: String(localized: "Apps on This Mac", comment: "Title of the briefing about the apps-on-this-Mac setting."),
                            message: message)
        return
    }
    ConfirmSheet.show(in: self, title: String(localized: "Before You Allow This", comment: "Title of the briefing shown before the apps-on-this-Mac setting can be turned on."),
                      message: message,
                      confirmTitle: String(localized: "I understand", comment: "Button that acknowledges the briefing and turns the setting on.")) { agreed in
        guard agreed else { return }
        reason()
    }
}
```

5. Add `reloadLocalReceivers()` beside `reloadBlocking()` at the initial reload (line ~1541), so the group is built
when Settings opens.

- [ ] **Step 5: Typecheck the app through the harness**

```bash
ZZ_REPO=$PWD /private/var/folders/ms/1k14zlbd3t79sp0ygnzn5km00000gp/T/opencode/run_tests-lr.sh LocalReceiversTests SettingsLayoutTests 2>&1 | tail -15
```

Expected: compile clean, both suites pass (`SettingsLayoutTests` has one known base failure on `main`; if it fails on
the same assertion it did before this change, record it and carry on).

- [ ] **Step 6: Commit**

```bash
git add Zigzag/Web/LocalReceivers.swift Zigzag/Settings/SettingsView.swift ZigzagTests/LocalReceiversTests.swift
git commit -m "Websites reach this Mac only after a master switch and a briefing"
```

---

### Task 3: The site door (port `329cce01`)

**Files:**
- Create: `Zigzag/Web/LocalReceiverShim.swift` (first half: `fetch`)
- Modify: `Zigzag/Tabs/Tab.swift`
- Modify: `Zigzag/Web/PermissionPolicy.swift`
- Modify: `Zigzag/Web/SitePermissions.swift`
- Modify: `Zigzag/Window/SitePanel.swift`
- Modify: `Zigzag/Resources/Localizable.xcstrings`
- Modify: `ZigzagTests/LocalReceiversTests.swift`

**Interfaces:**
- Produces: `LocalReceiverShim.attach(to:tab:) -> LocalReceiverMessages?`, `LocalReceiverMessages`
  (`WKScriptMessageHandlerWithReply`), `SitePermissions.localReceivers(origin:)`,
  `SitePermissions.setLocalReceivers(_:origin:)`, `PermissionSubject.localReceivers`,
  `SitePanelRows.Row.localApps` (keep the enum name; the title is what changed).
- Consumes: `LocalReceivers.allowsSite(origin:)` from Task 2.

- [ ] **Step 1: Apply the commit and resolve**

```bash
git cherry-pick -n 329cce01
git status --short
git diff --name-only --diff-filter=U
```

Expected conflicts in `Zigzag/Web/SitePermissions.swift`, `Zigzag/Window/SitePanel.swift`,
`Zigzag/Tabs/Tab.swift`, `Zigzag/Resources/Localizable.xcstrings`. The new shim file applies cleanly.

Resolve by keeping **main's** structure and adding only this commit's hunks (the commit itself contains no download
work; `git show 329cce01` is the source of truth):

- `PermissionPolicy.swift`: add `static let localReceivers = "localReceivers"` to `PermissionSubject`.
- `SitePermissions.swift`: add `localReceivers(origin:)` and `setLocalReceivers(_:origin:)` as in the commit. Do **not**
  add any downloads helpers — they are not in this commit.
- `Tab.swift`: in `makeWebView`/configuration setup, after the extension bridge attach, add the shim only for a page:

```swift
// A page's own scripts may ask Zigzag to make a loopback call, when Settings and the site's switch both say yes.
// An extension's own page has its bridge instead, and a private window's page is refused by the handler.
if extensionConfiguration == nil {
    localReceivers = LocalReceiverShim.attach(to: configuration, tab: self)
}
```

and the weak property near `webView` (Task 4 adds the close-sockets use).
- `SitePanel.swift`: take the `context.localApps` line, the `.localApps` toggle case, the `Row` case and the
  `Context.localApps` field. Change the title to **"Apps on this Mac"** and the status closures stay `onHere`/`offHere`.
  Change the context line to require the master switch:

```swift
context.localApps = context.isWeb && !isPrivate && origin != nil && LocalReceivers.isEnabled
```

- `Localizable.xcstrings`: keep both catalogs consistent; the gate does not need it, a release does. Add the new
  strings with `String(localized:)` as the source and run the catalog sync after a full build (Task 5).

- [ ] **Step 2: Gate the handler on both switches**

In `LocalReceiverShim.swift`, the `LocalReceiverMessages.userContentController` guard must read:

```swift
guard let tab, message.frameInfo.isMainFrame,
      let origin = SiteOrigin.of(message.frameInfo.securityOrigin),
      !tab.isPrivate,
      LocalReceivers.allowsSite(origin: origin) else {
    replyHandler(["error": "denied"], nil)
    return
}
```

This is the whole identity model: `origin` is WebKit's, not the message's.

- [ ] **Step 3: Run the ported tests**

```bash
ZZ_REPO=$PWD /private/var/folders/ms/1k14zlbd3t79sp0ygnzn5km00000gp/T/opencode/run_tests-lr.sh LocalReceiversTests SiteControlsPermissionTests SettingsLayoutTests 2>&1 | tail -20
```

Expected: `LocalReceiversTests` still green. If `SiteControlsPermissionTests` asserts the exact row set, add
`.localApps` only where the context says `localApps: true`; do not weaken an existing assertion.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "A site's own scripts reach this Mac only through two switches"
```

---

### Task 4: A page's WebSocket and XMLHttpRequest (port `748e53ba`, `7ce17c6f`)

**Files:**
- Modify: `Zigzag/Web/LocalReceiverShim.swift`
- Modify: `Zigzag/Tabs/Tab.swift`

**Interfaces:**
- Produces: `LocalReceiverSocket`, `LocalReceiverMessages.closeAllSockets()`, the page-side `LocalXHR` and
  `LocalWebSocket`, and `Tab.localReceivers` used on navigation.

- [ ] **Step 1: Apply the two commits**

```bash
git cherry-pick -n 748e53ba
git cherry-pick -n 7ce17c6f
git status --short
```

Expected: `LocalReceiverShim.swift` merges (both add to the same new file); `Tab.swift` may conflict around
`didStartProvisionalNavigation`/`didCommit`. Keep main's surrounding code and add:

```swift
// The page is going: a socket it opened to this Mac goes with it.
localReceivers?.closeAllSockets()
```

in the navigation callback the commit used (find `localReceivers?.closeAllSockets()` in the commit diff and match it
to main's equivalent delegate method).

- [ ] **Step 2: Verify the two behaviours in code**

- A socket's `Origin` is the page's own (the `LocalReceiverSocket` initializer sets it); no cookie jar.
- `closeAllSockets()` cancels every socket on navigation; `cancelForNavigation()` invalidates its session.
- The page's `WebSocket` keeps the native constants and event surface (`CONNECTING`, `OPEN`, `addEventListener`,
  `send`, `close`), so socket.io's transport works unchanged.
- `LocalXHR` answers only asynchronous loopback requests; a synchronous one stays with WebKit and fails as today.
- `fetch` refuses `no-cors`, `navigate` and `redirect: manual` to WebKit; it never pretends to answer those.

- [ ] **Step 3: Run the suites**

```bash
ZZ_REPO=$PWD /private/var/folders/ms/1k14zlbd3t79sp0ygnzn5km00000gp/T/opencode/run_tests-lr.sh LocalReceiversTests SiteControlsPermissionTests PendingQuestionsTests 2>&1 | tail -20
```

Expected: pass. The socket/XHR paths have no unit test that opens a port; Task 10's smoke list covers them.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "A page's WebSocket and XMLHttpRequest to this Mac take the same door"
```

---

### Task 5: Regenerate the project

**Files:**
- Modify: `Zigzag.xcodeproj/project.pbxproj` (generated)

- [ ] **Step 1: Regenerate**

```bash
xcodegen generate
git diff --stat Zigzag.xcodeproj/project.pbxproj
```

Expected: `LocalReceivers.swift`, `LocalReceiverShim.swift` appear in the app target's sources. The prototype's
`9c646f74` is not cherry-picked; the generator is the source of truth.

- [ ] **Step 2: Confirm both files are in the target**

```bash
grep -c 'LocalReceiver' Zigzag.xcodeproj/project.pbxproj
```

Expected: at least 4 (two file references, two build-file entries). If xcodegen produces unrelated churn, keep only
the lines for the new files.

- [ ] **Step 3: Commit**

```bash
git add Zigzag.xcodeproj/project.pbxproj
git commit -m "The local receiver files are part of the app target"
```

---

### Task 6: A grant for one extension

**Files:**
- Modify: `Zigzag/Extensions/ExtensionInstalls.swift`
- Modify: `Zigzag/Settings/SettingsView.swift`
- Create: `ZigzagTests/ExtensionLocalReceiversTests.swift`

**Interfaces:**
- Produces: `ExtensionInstalls.State.localReceivers: Bool?` (in `State.keys` and `carried(enabled:)`),
  `ExtensionInstalls.localReceivers(_ id: String) -> Bool`, `ExtensionInstalls.setLocalReceivers(_:for:)`.
- Consumes: nothing from the site door. The grant is independent by design.

- [ ] **Step 1: Write the failing tests**

`ZigzagTests/ExtensionLocalReceiversTests.swift`:

```swift
import Foundation
import Testing
@testable import Zigzag

@Suite("ExtensionLocalReceivers")
struct ExtensionLocalReceiversTests {
    @Test func aGrantIsOffUntilItIsRecorded() {
        var state = ExtensionInstalls.State()
        #expect(state.localReceivers == nil)
        state.localReceivers = true
        #expect(state.localReceivers == true)
        state.localReceivers = false
        #expect(state.localReceivers == false)
    }

    @Test func anotherProfileStartsWithTheSameGrant() {
        var state = ExtensionInstalls.State()
        state.localReceivers = true
        #expect(state.carried(enabled: true).localReceivers == true)
        #expect(state.carried(enabled: false).localReceivers == true, "the grant is a decision about the extension, not about being on")
    }

    @Test func theGrantSurvivesWhatIsWritten() throws {
        var state = ExtensionInstalls.State()
        state.localReceivers = true
        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(ExtensionInstalls.State.self, from: data).localReceivers == true)
    }
}
```

Run:

```bash
ZZ_REPO=$PWD /private/var/folders/ms/1k14zlbd3t79sp0ygnzn5km00000gp/T/opencode/run_tests-lr.sh ExtensionLocalReceiversTests 2>&1 | tail -10
```

Expected: compile failure on `localReceivers`. Intended red.

- [ ] **Step 2: Add the field and accessors**

In `ExtensionInstalls.State`:

```swift
/// Whether the person turned on Apps on This Mac for it: its own code may reach a program listening on this Mac
/// over loopback. Off when nil, and carried with the other approvals to another profile.
var localReceivers: Bool?
```

Add `"localReceivers"` to `State.keys`. `carried` already copies the whole state, so no extra line; confirm it does not
strip it.

Accessors beside `setSiteAccess`:

```swift
/// Whether this extension may reach a program listening on this Mac. The person's switch, never a manifest
/// permission: a Chrome Web Store extension cannot declare one Chrome doesn't have.
func localReceivers(_ id: String) -> Bool { state(id)?.localReceivers == true }

func setLocalReceivers(_ allowed: Bool, for id: String) {
    update(id) { $0.localReceivers = allowed }
}
```

- [ ] **Step 3: Add the switch under the extension's row**

In `SettingsView.reloadExtensions()`, after `extensionsGroup.add(extensionRow(id: id, ext: ext))`:

```swift
extensionsGroup.add(localReceiversRow(id: id))
```

and implement:

```swift
/// Its own switch, indented under it: a grant the person gives one extension, with the reason in plain words.
private func localReceiversRow(id: String) -> FormRow {
    let installs = profile.installs
    let toggle = Toggle(isOn: installs.localReceivers(id))
    toggle.setAccessibilityLabel(String(localized: "Let this extension reach apps on this Mac",
                                        comment: "Accessibility label of the apps-on-this-Mac switch under an extension in Settings › Extensions."))
    toggle.onChange = { on in installs.setLocalReceivers(on, for: id) }
    let row = FormRow(title: String(localized: "Apps on This Mac",
                                    comment: "A switch under an extension in Settings › Extensions: its own code may reach a program listening on this Mac."),
                      detail: String(localized: "Lets this extension’s own code reach a program listening on this Mac, over loopback only. Off until you turn it on.",
                                     comment: "Explanation under the apps-on-this-Mac switch on an extension’s row in Settings › Extensions."),
                      control: toggle)
    row.isIndented = true
    return row
}
```

- [ ] **Step 4: Run the tests**

```bash
ZZ_REPO=$PWD /private/var/folders/ms/1k14zlbd3t79sp0ygnzn5km00000gp/T/opencode/run_tests-lr.sh ExtensionLocalReceiversTests SettingsLayoutTests 2>&1 | tail -15
```

Expected: green (except the known base failure, if it is the same one).

- [ ] **Step 5: Commit**

```bash
git add Zigzag/Extensions/ExtensionInstalls.swift Zigzag/Settings/SettingsView.swift ZigzagTests/ExtensionLocalReceiversTests.swift
git commit -m "An extension reaches this Mac only through its own switch"
```

---

### Task 7: The extension fetch door

**Files:**
- Modify: `Zigzag/Web/LocalReceivers.swift` (cookie helpers, so both doors share them)
- Modify: `Zigzag/Web/LocalReceiverShim.swift` (use the shared helpers)
- Modify: `Zigzag/Extensions/BridgeNamespaces.swift`
- Modify: `Zigzag/Resources/Extensions/bridge.js`
- Modify: `ZigzagTests/ExtensionLocalReceiversTests.swift`

**Interfaces:**
- Produces: `BridgeExtensionFetch.localReceiverRequest(_ options: [String: Any], url: URL) throws -> LocalReceivers.Request`
  and `BridgeExtensionFetch.localReceiverAnswer(_ response: LocalReceivers.Response) -> [String: Any]`.
- Produces: `LocalReceivers.cookies(for:in:) async -> String?` and
  `LocalReceivers.store(_:for:in:) async`, both `@MainActor`, taking `WKWebsiteDataStore`.
- Consumes: `ExtensionInstalls.localReceivers(_:)`, `LocalReceivers.send(_:as:transport:)`.

- [ ] **Step 1: Write the failing parsing tests**

Append to `ExtensionLocalReceiversTests`:

```swift
@Test func aLoopbackExtensionRequestKeepsItsMethodHeadersBodyAndCredentials() throws {
    let url = URL(string: "http://localhost:9990/save")!
    let request = try BridgeExtensionFetch.localReceiverRequest(
        ["method": "post", "headers": [["Content-Type", "application/json"], ["X-Token", "abc"]],
         "body": "{\"ok\":true}", "credentials": "include"], url: url)
    #expect(request.method == "POST")
    #expect(request.headers["Content-Type"] == "application/json")
    #expect(request.headers["X-Token"] == "abc")
    #expect(request.body == Data("{\"ok\":true}".utf8))
    #expect(request.credentials == .include)
}

@Test func aLoopbackExtensionRequestDefaultsToNoCookies() throws {
    let request = try BridgeExtensionFetch.localReceiverRequest([:], url: URL(string: "http://127.0.0.1:1/")!)
    #expect(request.method == "GET")
    #expect(request.credentials == .sameOrigin)
}

@Test func aLoopbackAnswerIsWhatTheBridgeExpects() {
    let response = LocalReceivers.Response(url: URL(string: "http://localhost:9990/")!, status: 200,
                                           headers: ["content-type": "application/json"],
                                           body: Data("{}".utf8))
    let answer = BridgeExtensionFetch.localReceiverAnswer(response)
    #expect(answer["status"] as? Int == 200)
    #expect((answer["headers"] as? [[String]]) == [["content-type", "application/json"]])
    #expect((answer["body"] as? String).flatMap { Data(base64Encoded: $0) } == Data("{}".utf8))
    #expect(answer["redirected"] as? Bool == false)
}
```

Run: expect compile failure. Intended red.

- [ ] **Step 2: Add the native branch**

In `BridgeExtensionFetch.call`, after `context` is resolved and **before** `guard Self.allows(...)`:

```swift
// This Mac is its own door: a loopback URL would fail the host-access test, and the grant is the person's switch
// rather than a manifest permission. With the grant off, hand the call back to WebKit, which refuses it as it does
// today; the extension learns nothing about why.
if LocalReceivers.isLoopback(url) {
    guard host.profile.installs.localReceivers(extensionID) else { return ["fallback": true] }
    var request = try Self.localReceiverRequest(options, url: url)
    if request.credentials.sendsCookies, let cookie = await LocalReceivers.cookies(for: url, in: host.profile.store) {
        request.headers["Cookie"] = cookie
    }
    let answer = try await LocalReceivers.send(request, as: .webExtension(id: extensionID))
    if request.credentials.sendsCookies { await LocalReceivers.store(answer, for: url, in: host.profile.store) }
    return Self.localReceiverAnswer(answer)
}
```

Add the two static helpers:

```swift
/// The bridge's options as the runner's request. A body is the string bridge.js sent; headers arrive as pairs.
static func localReceiverRequest(_ options: [String: Any], url: URL) throws -> LocalReceivers.Request {
    let method = (options["method"] as? String ?? "GET").uppercased()
    guard ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"].contains(method) else {
        throw BridgeError("That method is not sent to this Mac.")
    }
    let body = (options["body"] as? String).map { Data($0.utf8) }
    guard (body?.count ?? 0) <= LocalReceivers.responseLimit else { throw BridgeError("That request is too large.") }
    var headers: [String: String] = [:]
    for pair in options["headers"] as? [[String]] ?? [] where pair.count == 2 { headers[pair[0]] = pair[1] }
    let credentials: LocalReceivers.Credentials = switch options["credentials"] as? String {
    case "omit": .omit
    case "include": .include
    default: .sameOrigin
    }
    return LocalReceivers.Request(url: url, method: method, headers: headers, body: body, credentials: credentials)
}

static func localReceiverAnswer(_ response: LocalReceivers.Response) -> [String: Any] {
    ["status": response.status, "statusText": "", "headers": response.headers.map { [$0.key, $0.value] },
     "body": response.body.base64EncodedString(), "url": response.url.absoluteString, "redirected": false]
}
```

- [ ] **Step 3: Share the cookie helpers**

Move the bodies of `LocalReceiverMessages.cookies(for:in:)` and `store(_:for:in:)` into `LocalReceivers` as
`@MainActor static func cookies(for url: URL, in store: WKWebsiteDataStore) async -> String?` and
`@MainActor static func store(_ answer: Response, for url: URL, in store: WKWebsiteDataStore) async`, changing the
`webView?.configuration.websiteDataStore.httpCookieStore` lookup to the passed store. `LocalReceivers.swift` gains
`import WebKit`. `LocalReceiverMessages` calls the shared versions with `webView?.configuration.websiteDataStore`.

- [ ] **Step 4: Let the page's `fetch` take the loopback path with its default credentials**

In `bridge.js`, inside the fetch patch:

1. Add, next to the patch:

```js
// This Mac by the names loopback is reached by; http only, because that is what WebKit blocks.
const localLoopback = (url) => {
  if (url.protocol !== 'http:') return false;
  let host = url.hostname.toLowerCase();
  if (host.startsWith('[') && host.endsWith(']')) host = host.slice(1, -1);
  if (host.endsWith('.')) host = host.slice(0, -1);
  if (host === 'localhost' || host.endsWith('.localhost')
      || host === '::1' || host === '0:0:0:0:0:0:0:1') return true;
  const parts = host.split('.');
  return parts.length === 4 && parts.every((p) => /^\d{1,3}$/.test(p) && Number(p) <= 255)
    && parts[0] === '127';
};
```

2. Compute `const loopback = localLoopback(url);` beside `url`.
3. Change the credentials clause to `(!loopback && option('credentials', 'same-origin') !== 'include')`.
4. Add `credentials: option('credentials', 'same-origin')` to the `extensionFetch` payload.

Keep every other clause as it is: loopback does not widen what the bridge will carry (method list, string body, no
integrity, no manual redirect, no `only-if-cached`).

- [ ] **Step 5: Run the tests**

```bash
ZZ_REPO=$PWD /private/var/folders/ms/1k14zlbd3t79sp0ygnzn5km00000gp/T/opencode/run_tests-lr.sh ExtensionLocalReceiversTests LocalReceiversTests 2>&1 | tail -15
```

Expected: green.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "An extension's fetch to this Mac goes through its own switch"
```

---

### Task 8: The extension WebSocket gate

**Files:**
- Modify: `Zigzag/Extensions/WebSocketBridge.swift`
- Modify: `Zigzag/Extensions/ExtensionHost.swift`

**Interfaces:**
- Changes: `WebSocketBridge.allows(_ url: URL, context: WKWebExtensionContext, localReceivers: Bool) -> Bool`.
- Consumes: `ExtensionInstalls.localReceivers(_:)`.

- [ ] **Step 1: Change the gate**

```swift
static func allows(_ url: URL, context: WKWebExtensionContext, localReceivers: Bool) -> Bool {
    …
    // This Mac used to be allowed with nothing asked. It is a door now, like the site's: the person's switch for
    // this extension, and nothing else.
    if isLoopback(host) { return localReceivers }
    …
}
```

- [ ] **Step 2: Pass the grant at the call site**

`ExtensionHost.swift`, where `WebSocketBridge` is made:

```swift
extensionContext.map {
    WebSocketBridge.allows(url, context: $0,
                           localReceivers: profile.installs.localReceivers($0.uniqueIdentifier))
} ?? false
```

Capture `profile` implicitly through `self` as the surrounding code already does, or add `[weak self]` if the closure
outlives the host. The closure is the bridge's `mayConnect`, called when its port says "open".

- [ ] **Step 3: Run the suites**

```bash
ZZ_REPO=$PWD /private/var/folders/ms/1k14zlbd3t79sp0ygnzn5km00000gp/T/opencode/run_tests-lr.sh ExtensionLocalReceiversTests ExtensionBridgeTests 2>&1 | tail -20
```

Expected: green, with `ExtensionBridgeTests.writesGoThroughTheProfilesProxy` allowed to fail exactly as it does on
`main`.

- [ ] **Step 4: Commit**

```bash
git add Zigzag/Extensions/WebSocketBridge.swift Zigzag/Extensions/ExtensionHost.swift
git commit -m "An extension's WebSocket to this Mac needs its switch"
```

---

### Task 9: XMLHttpRequest for an extension

**Files:**
- Modify: `Zigzag/Resources/Extensions/bridge.js`

**Interfaces:**
- Produces: a page-world `XMLHttpRequest` wrapper in extension pages, backed by `extensionFetch`.
- Consumes: the same native branch from Task 7.

- [ ] **Step 1: Port the page shim's XHR state machine**

Read `LocalXHR` in `Zigzag/Web/LocalReceiverShim.swift` (from `const NativeXHR = window.XMLHttpRequest` to
`window.XMLHttpRequest = LocalXHR`). Add the same wrapper to `bridge.js` when
`typeof XMLHttpRequest === 'function'`:

- `open(method, url, async)` records a loopback async request and calls the native `open` with `about:blank` so
  WebKit never touches the network; a synchronous or non-loopback request uses the native method unchanged.
- `setRequestHeader` records pairs for a loopback request; otherwise native.
- `send(body)` posts `{kind: 'fetch', ...}` through `send('extensionFetch', 'fetch', [{ requestID, url, method,
  headers, body, credentials: this.withCredentials ? 'include' : 'same-origin' }])`, then fills status, headers,
  `responseText`/`response`, and fires `readystatechange` (1, 2, 3, 4), `loadstart`, `progress`, `load`, `loadend`.
- A refusal or network failure fires `readystatechange` with `readyState` 4, `status` 0, then `error` and `loadend`.
- `abort()` cancels with `send('extensionFetch', 'cancel', [requestID])` when one is in flight.
- `getAllResponseHeaders()`/`getResponseHeader()` expose only what the answer carried, as the site shim does.

Do not patch `EventSource`, `sendBeacon` or subresource loads.

- [ ] **Step 2: Syntax-check the resource**

```bash
node --check Zigzag/Resources/Extensions/bridge.js 2>&1 | head -5 || true
```

Expected: no output. If `node` is unavailable, open the file's changed region and check brackets by reading; do not
skip the check silently.

- [ ] **Step 3: Run the Swift suites**

```bash
ZZ_REPO=$PWD /private/var/folders/ms/1k14zlbd3t79sp0ygnzn5km00000gp/T/opencode/run_tests-lr.sh ExtensionLocalReceiversTests ExtensionBridgeTests 2>&1 | tail -20
```

Expected: unchanged from Task 8. The JS path has no unit test; smoke in Task 10.

- [ ] **Step 4: Commit**

```bash
git add Zigzag/Resources/Extensions/bridge.js
git commit -m "An extension's XMLHttpRequest to this Mac takes the same door"
```

---

### Task 10: Notes, full gate, smoke list, and the pull request

**Files:**
- Modify: `CHANGELOG.md`
- Modify: `docs/superpowers/specs/2026-11-15-local-receivers-design.md` only if a decision above diverged from it

- [ ] **Step 1: Write the release notes**

Under `## [Unreleased]`, `### New`, add:

> - A site you allow can reach a program listening on this Mac — the local agent an editor, a download helper or a
>   companion app runs. Chrome and Firefox allow `http://localhost` and `ws://localhost` from a secure page; WebKit
>   refuses it as mixed content, so Zigzag makes the request itself, as the site, and hands the answer back. It is off
>   until you turn on **Settings › Privacy › Allow websites to reach apps on this Mac** and then the site's own
>   **Apps on This Mac** switch in Site Controls; nothing on the web can ask for either. An extension gets the same
>   door through its own **Apps on This Mac** switch in Settings › Extensions, off by default. Extensions that already
>   opened `ws://localhost` without a switch now need that switch; a companion app that relied on it should be turned
>   on once. Loopback only: not the local network, not another machine, and not images, scripts or stylesheets.

- [ ] **Step 2: Full local gate**

```bash
ZZ_REPO=$PWD /private/var/folders/ms/1k14zlbd3t79sp0ygnzn5km00000gp/T/opencode/run_tests-lr.sh 2>&1 | tail -25
```

Expected: every suite green except the two known base failures (`SettingsLayoutTests.fitsThePageItIsGivenInsideAnAnimation`,
`ExtensionBridgeTests.writesGoThroughTheProfilesProxy`). Record the test count. If any other failure appears, fix it
before pushing; do not call a known failure new.

- [ ] **Step 3: Regenerate and check the tree**

```bash
xcodegen generate
git status --short
git diff --stat origin/main...HEAD
```

Expected: only intended files. No `.watchdog/`, no build products, no `agent-lr` artifacts.

- [ ] **Step 4: Push and open the PR against `main`**

```bash
git push fork feat/local-receivers
```

PR body must contain:

- The two user-visible doors and what is off by default.
- The `ws://` behaviour change in bold, as a release note, so the owner can decide to keep it in the beta.
- The verification: gate count and the two known failures.
- The owed smoke list (below), because there is no WebKit host here.
- The design and plan file paths.

- [ ] **Step 5: Hand over the smoke list**

Six scenarios, run in a build (the user has them):

1. Master off: a page that calls `fetch('http://127.0.0.1:PORT')` fails as today; Site Controls has no Apps row.
2. Master on, site off: the call fails; the Apps row is present and off.
3. Master on, site on: `GET /` returns the helper's JSON; a POST with `Content-Type: application/json` sends a
   preflight and succeeds; a helper that answers `Access-Control-Allow-Origin: *` without credentials answers a
   non-credentialed call and is refused for `credentials: 'include'`.
4. ZeroWork's editor connects to its agent on port 9990 over `ws://localhost:9990/ws`; the socket survives a
   reconnect and closes when the tab navigates.
5. Extension: with its switch off, its background's `fetch('http://localhost:PORT')` fails as before; on, it
   succeeds and presents `Origin: chrome-extension://<id>`. Same for XHR in an extension page, and for a background
   WebSocket after the gate change.
6. A private window with both switches on is refused and writes no answer; toggling the master off and back on keeps
   the per-site answers dormant, not erased.

---

## Notes for the implementer

- The prototype's other commits on `feat/local-receivers-code` are **not** part of this work: the download-rule
  changes in that branch predate it and already exist on `main` in another form. Cherry-pick only the five SHAs named
  above, and never take the branch's whole diff.
- If a SHA is missing (a fresh clone), the files are readable in the prototype worktree at
  `/private/var/folders/ms/1k14zlbd3t79sp0ygnzn5km00000gp/T/opencode/zigzag-loopback` at `7ce17c6f`; copy the files and
  the commit's hunks by hand.
- The app target is generated. Never hand-edit `project.pbxproj`; run `xcodegen generate`.
- `.watchdog/` is excluded from git; ledger edits never enter a commit.
