# One Permission Model for Sites — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace six separate site-permission prompts with one banner whose answer is an action plus a duration (This time / Always), stored per site and subject, and gate download-rule handoffs behind it.

**Architecture:** A small policy layer (`PermissionAction`, `PermissionAnswer`, `PermissionSubject`) defines what a question offers and what is stored. `SitePermissions` stores an action id per `origin|subject`, migrating today's `[String: Bool]` in place. `PermissionPrompt` renders the banner and returns a `PermissionAnswer?`. Every caller — camera, microphone, location, notifications, screen sharing, pop-ups, app launches, handoff rules — maps that answer to its own behaviour. A `PendingQuestions` registry holds questions that cannot be shown yet, drives the tab dot and the sidebar-edge glow, and releases them when the tab comes forward.

**Tech Stack:** Swift 6 (main-actor by default), AppKit, WebKit, Swift Testing (`#expect`), XcodeGen, GitHub Actions (`xcode-27` runner).

**Spec:** `docs/superpowers/specs/2026-11-14-unified-site-permissions-design.md`

## Global Constraints

- `SWIFT_VERSION: "6.0"`, `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor`, deployment target macOS 15.4.
- No App Sandbox; `ENABLE_HARDENED_RUNTIME` off in Debug.
- There is no local Xcode: `xcodebuild` cannot run on this Mac. Every test run is a push to `fork` and a CI run on the `xcode-27` runner committed as `Lakeland97/zigzag`. Typecheck locally with the recipe in Task 0.
- New user-facing strings use `String(localized:)` with a `comment:`.
- No `/bin/sh -c`; no shell string building anywhere.
- Every permission question resolves: it never hangs a WebKit decision without an answer path.
- A private window asks and stores nothing.
- A frame from another site keeps its own answer key and never writes the page's origin.

## Review Focus

1. **A handoff in a background tab** — must not run; it waits with the tab marked. Test in Task 6 with a tab whose `isFront` is false.
2. **App launch on http, or in a foreign frame** — must not be able to store always-allow. Test in Task 4.
3. **Migration of old answers** — a user who allowed the camera yesterday must not be asked again, and an old block must still block. Test in Task 1.
4. **A stored pop-up destination** — "newTab" and "mini" must be honoured without a question, synchronously. Test in Task 5.
5. **Screen sharing** — three actions and no duration dropdown; the screen/window choice must survive the rewrite. Test in Task 3.
6. **Not Now** — closes the question without running anything and without storing, and hands the navigation or download back to the normal path. Test in Task 6.

---

### Task 0: Branch and local typecheck recipe

**Files:**
- Modify: `.github/workflows/build-zigzag.yml:5-7`

**Interfaces:**
- Produces: branch `feat/site-permissions`; a local `swiftc -typecheck` command every later task runs.

- [ ] **Step 1: Create the branch and allow CI on it**

```bash
git switch -c feat/site-permissions
python3 - <<'PY'
from pathlib import Path
p = Path(".github/workflows/build-zigzag.yml")
t = p.read_text().replace("branches: [feat/download-handoff]",
                          "branches: [feat/download-handoff, feat/site-permissions]")
p.write_text(t)
PY
git add .github/workflows/build-zigzag.yml && git commit -m "chore: build the permissions branch"
```

- [ ] **Step 2: Record the typecheck recipe**

Run, and expect only pre-existing errors outside the files this plan touches:

```bash
T=/private/var/folders/ms/1k14zlbd3t79sp0ygnzn5km00000gp/T/opencode
swiftc -typecheck -swift-version 6 -default-isolation MainActor \
  -sdk "$(xcrun --show-sdk-path)" -target arm64-apple-macos28.0 -I "$T/sparkle" \
  $(find Zigzag -name '*.swift' ! -name 'SystemPasswords.swift') "$T/SystemPasswords.swift" \
  ZigzagPDFRenderer/PDFService.swift ZigzagImageDecoder/PictureService.swift 2>&1 | grep error:
```

Expected: `SafePDF.swift:137` compiler-timeout only.

---

### Task 1: Policy types and the action store

**Files:**
- Create: `Zigzag/Web/PermissionPolicy.swift`
- Modify: `Zigzag/Web/SitePermissions.swift:68-110`, `:145-233`, `:251-300`
- Test: `ZigzagTests/SitePermissionsPolicyTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `nonisolated struct PermissionAction { let id: String; let title: String; let isDeny: Bool; let isProminent: Bool; static let deny, allow: PermissionAction; static func alternate(_ id: String, _ title: String) -> PermissionAction }`
  - `nonisolated struct PermissionAnswer { let action: String; let remember: Bool }`
  - `nonisolated enum PermissionSubject { static func media(_ type: WKMediaCaptureType) -> String; static let location, notifications, popups, apps: String; static func app(_ scheme: String) -> String; static func handoff(_ rule: UUID) -> String }`
  - `SitePermissions.action(_:origin:) -> String?`, `SitePermissions.remember(_:subject:origin:)`, `SitePermissions.actions(origin:) -> [String: String]`, `SitePermissions.forgetActions(prefix:)`

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import Zigzag

@Suite(.serialized) struct SitePermissionsPolicyTests {
    /// Every test starts with `let defaults = freshDefaults()` and restores with `defer { SitePermissions.defaults = before }`.
    private func freshDefaults(_ before: inout UserDefaults) -> UserDefaults {
        before = SitePermissions.defaults
        let suite = UserDefaults(suiteName: "SitePermissionsPolicyTests")!
        suite.removePersistentDomain(forName: "SitePermissionsPolicyTests")
        SitePermissions.defaults = suite
        return suite
    }

    @Test func remembersAnActionPerSubjectAndOrigin() {
        SitePermissions.remember("mini", subject: PermissionSubject.popups, origin: "https://example.com")
        #expect(SitePermissions.action(PermissionSubject.popups, origin: "https://example.com") == "mini")
        #expect(SitePermissions.action(PermissionSubject.popups, origin: "https://other.com") == nil)
    }

    @Test func forgetForgetsOnlyThatSubject() {
        SitePermissions.remember("deny", subject: PermissionSubject.location, origin: "https://example.com")
        SitePermissions.remember("allow", subject: PermissionSubject.notifications, origin: "https://example.com")
        SitePermissions.remember(nil, subject: PermissionSubject.location, origin: "https://example.com")
        #expect(SitePermissions.action(PermissionSubject.location, origin: "https://example.com") == nil)
        #expect(SitePermissions.action(PermissionSubject.notifications, origin: "https://example.com") == "allow")
    }

    @Test func migratesOldBoolsOnce() {
        defaults.set(["https://example.com|camera": true, "https://example.com|popups": false,
                      "https://example.com|app:zoommtg": true], forKey: "SitePermissions")
        SitePermissions.migrateAnswersToActions()
        #expect(SitePermissions.action(PermissionSubject.media(.camera), origin: "https://example.com") == "allow")
        #expect(SitePermissions.action(PermissionSubject.popups, origin: "https://example.com") == "deny")
        #expect(SitePermissions.action(PermissionSubject.app("zoommtg"), origin: "https://example.com") == "allow")
    }

    @Test func siteWideAppDenyWinsOverAPerAppAllow() {
        SitePermissions.remember("allow", subject: PermissionSubject.app("zoommtg"), origin: "https://example.com")
        SitePermissions.remember("deny", subject: PermissionSubject.apps, origin: "https://example.com")
        #expect(SitePermissions.action(PermissionSubject.app("zoommtg"), origin: "https://example.com") == "deny")
    }

    @Test func deletingARuleForgetsItsHandoffAnswers() {
        let rule = UUID()
        SitePermissions.remember("handOff", subject: PermissionSubject.handoff(rule), origin: "https://a.com")
        SitePermissions.remember("browser", subject: PermissionSubject.handoff(rule), origin: "https://b.com")
        SitePermissions.forgetActions(prefix: "handoff:\(rule.uuidString)")
        #expect(SitePermissions.actions(origin: "https://a.com").isEmpty)
        #expect(SitePermissions.actions(origin: "https://b.com").isEmpty)
    }
}
```

- [ ] **Step 2: Run the tests in CI and watch them fail**

Push and run `gh run watch <id> --repo Lakeland97/zigzag --exit-status`. Expected: compile failure, because `PermissionSubject` and the new accessors do not exist.

- [ ] **Step 3: Implement the types**

In `PermissionPolicy.swift`, `PermissionSubject` returns exactly these ids:

```swift
nonisolated enum PermissionSubject {
    static let location = "location", notifications = "notifications", popups = "popups", apps = "apps"
    static func media(_ type: WKMediaCaptureType) -> String {
        switch type { case .camera: "camera"; case .microphone: "microphone"; default: "cameraAndMicrophone" }
    }
    static func app(_ scheme: String) -> String { "app:\(scheme)" }
    static func handoff(_ rule: UUID) -> String { "handoff:\(rule.uuidString)" }
}
```

In `SitePermissions`, replace `private static var all: [String: Bool]` with:

```swift
private static var stored: [String: String] { ... }   // reads/writes key "SitePermissions"
static var defaults: UserDefaults = .standard
```

`stored` converts any legacy `Bool` value to `"allow"`/`"deny"` on read, so `migrateAnswersToActions()` is only needed
once at launch and the tests can call it directly. `action(_:origin:)` returns the stored id, with the `apps` deny rule:
if `stored["\(origin)|apps"] == "deny"` return `"deny"` for every `app:` subject.

- [ ] **Step 4: Rewrite the Bool-facing accessors on top of the store**

`decision(origin:type:) -> Bool?`, `location(origin:)`, `notifications(origin:)`, `appDecision(origin:scheme:)`,
`popups(origin:)` map `"deny"` → `false`, any other id → `true`, absent → `nil`. Their setters write `"allow"`/`"deny"`
or `nil`. Keep `choices(origin:)`, `keys`, `PermissionChoice` and `SiteControlsTests` passing unchanged.

- [ ] **Step 5: Run the tests and typecheck; expect pass**

CI: `ZigzagTests/SitePermissionsPolicyTests` and `ZigzagTests/SiteControlsTests` all pass. Local typecheck: no new errors.

- [ ] **Step 6: Commit**

```bash
git add Zigzag/Web/PermissionPolicy.swift Zigzag/Web/SitePermissions.swift ZigzagTests/SitePermissionsPolicyTests.swift
git commit -m "feat: store site permissions as actions, not yes or no"
```

---

### Task 2: The permission banner

**Files:**
- Modify: `Zigzag/Web/SitePermissions.swift:522-880` (the `PermissionPrompt` class and its callers)
- Test: `ZigzagTests/PermissionPromptTests.swift`

**Interfaces:**
- Consumes: `PermissionAction`, `PermissionAnswer`, `SitePermissions.action(_:origin:)`.
- Produces:
  - `PermissionPrompt.ask(host:origin:what:symbol:icon:in:tab:title:actions:canRemember:rememberNote:answered:) async -> PermissionAnswer?`
  - `PermissionPrompt.buttonTitles(actions:)` not needed; `DropdownButton.isEnabled` added so the duration control can be greyed rather than hidden.
  - `PermissionPrompt.actions(for: [PermissionAction]) -> [PermissionAction]` (deny first, prominent last)
  - `nil` means Not Now; callers never treat it as an answer.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func denyComesFirstAndTheProminentYesLast() {
    let ordered = PermissionPrompt.actions(for: [.allow, .alternate("browser", "Open in Browser"), .deny])
    #expect(ordered.map(\.id) == ["deny", "browser", "allow"])
    #expect(ordered.last?.isProminent == true)
}
@Test func aQuestionWithFourActionsKeepsDenyFirst() {
    let ordered = PermissionPrompt.actions(for: [.deny, .alternate("thisTab", "This Tab"),
                                                .alternate("newTab", "New Tab"), .alternate("mini", "Mini")])
    #expect(ordered.map(\.id) == ["deny", "thisTab", "newTab", "mini"])
    #expect(ordered.last?.isProminent == true)
}
@Test func theAnswerCarriesTheChosenActionAndDuration() {
    #expect(PermissionAnswer(action: "newTab", remember: true).action == "newTab")
}
```

- [ ] **Step 2: Run them and watch them fail**

CI compile failure: `PermissionPrompt.actions` and the new `ask` signature do not exist.

- [ ] **Step 3: Implement the banner layout and API**

Replace `Answer` with `PermissionAnswer?`; delete `allowTitle`/`alwaysTitle`/`alternateTitle`/`denyTitle` in favour of
`actions`. Draw a `DropdownButton` above the buttons with options **This time** / **Always on this site**, defaulting to
This time, greyed out with a tooltip explaining why when `canRemember` is false. Buttons are the ordered actions, equal width; a question with more than
three actions places its row under the request, one line each at the left, never below `Tokens.Dialog.minButtonWidth`.
Width: `min(max(420, measured), min(560, area.width - Tokens.Space.x6))`. Keep the existing fade, `shownAt` guard,
click monitor, `followTab`, debug hooks and `.notNow` behaviour.

- [ ] **Step 4: Update the four existing callers to pass actions**

Screen sharing: `[.deny, .alternate("screen", "Share Screen…"), .allow]` with `canRemember: false`.
Notifications: `[.deny, .allow]`, rememberable. Camera/mic and location: `[.deny, .allow]`, rememberable.
App launches: `[.deny, .allow]`, rememberable subject to Task 4's gates.

- [ ] **Step 5: Typecheck and run the prompt tests plus `SiteControlsTests`**

Expected pass; a manual smoke on the artifact is deferred to Task 9.

- [ ] **Step 6: Commit**

```bash
git add Zigzag/Web/SitePermissions.swift ZigzagTests/PermissionPromptTests.swift
git commit -m "feat: one prompt for every site permission"
```

---

### Task 3: Camera, microphone, location, notifications, screen sharing

**Files:**
- Modify: `Zigzag/Web/SitePermissions.swift:313-405`
- Test: `ZigzagTests/SitePermissionsPolicyTests.swift`

**Interfaces:**
- Consumes: Task 2's `PermissionPrompt.ask`.
- Produces: `SitePermissions.request(origin:type:window:isPrivate:tab:) async -> WKPermissionDecision` unchanged in name, now writing `PermissionAnswer.remember` into the store, and the page answer when `remember == false`; `SitePermissions.rememberAnswer(_ answer: PermissionAnswer, subject: String, origin: String, tab: Tab?, isPrivate: Bool) -> Bool` (stores only when `remember`, never from a tab that is private, whatever `isPrivate` says; returns whether the action is not `"deny"`); `DisplayCaptureChoice.actions: [PermissionAction]`; `PagePermissionAnswers` now stores action ids — `note(_ action: String, key:kind:)` and `action(key:kind:) -> String?` — with the Bool `note(_ allowed:key:kind:)` / `answer(key:kind:)` kept as its façade.

- [ ] **Step 1: Write failing tests for the answer mapping**

```swift
@Test func alwaysStoresAndThisTimeDoesNot() {
    let remember = SitePermissions.rememberAnswer(PermissionAnswer(action: "allow", remember: true),
                                                  subject: PermissionSubject.location, origin: "https://a.com", tab: nil)
    #expect(remember == true)
    #expect(SitePermissions.action(PermissionSubject.location, origin: "https://a.com") == "allow")
    _ = SitePermissions.rememberAnswer(PermissionAnswer(action: "deny", remember: false),
                                       subject: PermissionSubject.notifications, origin: "https://b.com", tab: nil)
    #expect(SitePermissions.action(PermissionSubject.notifications, origin: "https://b.com") == nil)
}
@Test func screenSharingOffersThreeActionsAndKeepsNothing() {
    #expect(DisplayCaptureChoice.actions.map(\.id) == ["deny", "screen", "allow"])
    #expect(DisplayCaptureChoice.actions.last?.isProminent == true)
}
```

- [ ] **Step 2: Run and watch them fail**

CI compile failure: `rememberAnswer` and `DisplayCaptureChoice.actions` do not exist.

- [ ] **Step 3: Implement the mapping and the five request paths**

`rememberAnswer(_:subject:origin:tab:) -> Bool` stores when `remember` and the window is not private (a private window
stores nothing and answers this time only), otherwise writes to `tab.permissionAnswers`; returns whether the action is
not `"deny"`. Each request path asks the banner with its subject and actions, then calls `rememberAnswer`. Screen
sharing passes `canRemember: false` and maps `"screen"` → `.screen`, `"allow"` → `.window`, anything else → `.deny`.

- [ ] **Step 4: Verify**

CI: the policy tests and `SiteControlsTests` pass. No `Answer.always`/`.alternate` references remain in the camera,
location, notification or screen paths (`grep -rn "\.always\|alternateTitle" Zigzag/Web/SitePermissions.swift` is empty).

- [ ] **Step 5: Commit**

```bash
git add Zigzag/Web/SitePermissions.swift ZigzagTests/SitePermissionsPolicyTests.swift
git commit -m "feat: remember deny, and this-time answers, for media and location"
```

---

### Task 4: App launches through the same question

**Files:**
- Modify: `Zigzag/Web/ExternalLinks.swift:60-137`
- Test: `ZigzagTests/SitePermissionsPolicyTests.swift`

**Interfaces:**
- Consumes: Task 2's prompt, Task 1's store.
- Produces: `ExternalLinks.decision(page:scheme:foreign:) -> String?` returning the stored action id; `ExternalLinks.verdict(byYou:clickedHere:scheme:stored:canRemember:) -> Verdict` where `Verdict` is `.block`, `.open`, `.ask`; `ExternalLinks.canRemember(url: URL?, foreign: Bool) -> Bool`.

- [ ] **Step 1: Write failing tests**

```swift
@Test func anHttpPageCannotRememberAnAppQuestion() {
    #expect(ExternalLinks.canRemember(url: URL(string: "http://example.com"), foreign: false) == false)
    #expect(ExternalLinks.canRemember(url: URL(string: "https://example.com"), foreign: false) == true)
    #expect(ExternalLinks.canRemember(url: URL(string: "https://example.com"), foreign: true) == false)
}
@Test func aStoredAllowSkipsTheQuestionAndABlockStopsIt() {
    #expect(ExternalLinks.verdict(byYou: false, clickedHere: false, scheme: "zoommtg", stored: "allow", canRemember: true) == .open)
    #expect(ExternalLinks.verdict(byYou: false, clickedHere: false, scheme: "zoommtg", stored: "deny", canRemember: true) == .block)
    #expect(ExternalLinks.verdict(byYou: false, clickedHere: false, scheme: "zoommtg", stored: nil, canRemember: true) == .ask)
}
@Test func aForeignFrameNeverSeesThePagesAllow() {
    #expect(ExternalLinks.decision(page: "https://zoom.us", scheme: "zoommtg", foreign: true, stored: "allow") == nil)
    #expect(ExternalLinks.decision(page: "https://zoom.us", scheme: "zoommtg", foreign: true, stored: "deny") == "deny")
}
```

- [ ] **Step 2: Run and watch them fail**

CI compile failure: the new signatures do not exist.

- [ ] **Step 3: Implement**

Read `SitePermissions.action(PermissionSubject.app(scheme), origin: page)`, then the site-wide `apps` deny. Ask with
`[.deny, .allow]`, `canRemember: ExternalLinks.canRemember(url: pageURL, foreign: foreign)`, title "Open \(name)".
Store `"allow"`/`"deny"` on remember; on this time, record in the tab's page answers. Keep `asking`, `putOff` and the
60-second pause; drop `declined`.

- [ ] **Step 4: Verify**

CI: the three tests above pass; `SiteControlsTests` still passes (its app cases use the Bool accessors, which Task 1
kept).

- [ ] **Step 5: Commit**

```bash
git add Zigzag/Web/ExternalLinks.swift ZigzagTests/SitePermissionsPolicyTests.swift
git commit -m "feat: ask once, and remember deny, before opening an app"
```

---

### Task 5: Pop-ups choose their destination

**Files:**
- Modify: `Zigzag/Web/PopupNotice.swift:58-120`, `Zigzag/Tabs/Tab.swift:1720-1760` (`createWebViewWith`), `Zigzag/Web/PopupWindowController.swift:240-260`
- Test: `ZigzagTests/SitePermissionsPolicyTests.swift`

**Interfaces:**
- Consumes: Task 1's store, Task 2's prompt.
- Produces: `PopupNotice.storedAction(origin:) -> String?`; `PopupNotice.ask(for:url:origin:in:tab:) async -> String?` returning `"mini"`, `"thisTab"`, `"newTab"`, or `"deny"`; `PopupNotice.open(_ url: URL, action: String, from: Tab?, in: BrowserWindowController)`.

- [ ] **Step 1: Write failing tests**

```swift
@Test func aStoredPopupDestinationIsUsedWithoutAsking() {
    SitePermissions.remember("newTab", subject: PermissionSubject.popups, origin: "https://example.com")
    #expect(PopupNotice.storedAction(origin: "https://example.com") == "newTab")
}
@Test func everyPopupActionIsADistinctStandingAnswer() {
    for action in ["mini", "thisTab", "newTab", "deny"] {
        SitePermissions.remember(action, subject: PermissionSubject.popups, origin: "https://example.com")
        #expect(PopupNotice.storedAction(origin: "https://example.com") == action)
    }
}
```

- [ ] **Step 2: Run and watch them fail**

CI compile failure: `storedAction` does not exist.

- [ ] **Step 3: Implement the synchronous path**

`PopupNotice.allows` becomes: user-initiated → true; stored action → true only for a yes (`mini`/`thisTab`/`newTab`), false
for `deny`; otherwise return false and call `ask` (fire-and-forget Task) which shows the banner with
`[.deny, .alternate("thisTab", "This Tab"), .alternate("newTab", "New Tab"), .alternate("mini", "Mini")]`. On answer,
`open` performs it: `thisTab` → `controller.open(url, disposition: .currentTab…)`, `newTab` → `.foregroundTab`, `mini` →
the existing `PopupWindowController` creation path. Delete the blocked-pop-up toast and `Toast` action.

- [ ] **Step 4: Verify**

CI: both tests pass. Grep shows no `PopupNotice.blocked` caller left (`grep -rn "PopupNotice.blocked" Zigzag` empty).

- [ ] **Step 5: Commit**

```bash
git add Zigzag/Web/PopupNotice.swift Zigzag/Tabs/Tab.swift Zigzag/Web/PopupWindowController.swift ZigzagTests/SitePermissionsPolicyTests.swift
git commit -m "feat: ask where a pop-up should open, and remember it"
```

---

### Task 6: Gate handoff rules behind the question

**Files:**
- Modify: `Zigzag/Web/DownloadHandoff.swift:10-90`, `Zigzag/Tabs/Tab.swift:1480-1500` and `:1724-1745`,
  `Zigzag/Web/PopupWindowController.swift:310-325`, `Zigzag/Web/DownloadManager.swift:485-510`
- Test: `ZigzagTests/DownloadRuleTests.swift`

**Interfaces:**
- Consumes: Task 1's store.
- Produces:
  - `DownloadHandoff.Request` gains `var pageOrigin: String?`.
  - `enum HandoffGate: Equatable { case handOff, browser, cancel, ask }`
  - `DownloadHandoff.gate(stored: String?, isPrivate: Bool) -> HandoffGate` (`"handOff"` → `.handOff`, `"browser"` → `.browser`, `"deny"` → `.cancel`, private or nil → `.ask`)
  - `DownloadHandoff.decide(_ rule: DownloadRule, request: Request, tab: Tab? = nil) async -> HandoffGate` (asks when `.ask`, stores when the answer says remember). A "this time" answer is kept in `tab.permissionAnswers` under the rule's own key (`handoff:<rule UUID>`, see Task 3) and is read back before asking, so a link and the download it starts are asked once, not twice.

- [ ] **Step 1: Write failing tests**

```swift
@Test func storedHandoffAnswersMapToGates() {
    #expect(DownloadHandoff.gate(stored: "handOff", isPrivate: false) == .handOff)
    #expect(DownloadHandoff.gate(stored: "browser", isPrivate: false) == .browser)
    #expect(DownloadHandoff.gate(stored: "deny", isPrivate: false) == .cancel)
    #expect(DownloadHandoff.gate(stored: nil, isPrivate: false) == .ask)
    #expect(DownloadHandoff.gate(stored: "handOff", isPrivate: true) == .ask)
}
@Test func aHandoffQuestionUsesThePageOrigin() {
    let request = DownloadHandoff.Request(url: URL(string: "https://cdn.example/file.zip")!,
                                          referrer: URL(string: "https://site.example/page")!,
                                          pageOrigin: "https://site.example")
    #expect(DownloadHandoff.questionOrigin(for: request) == "https://site.example")
}
```

- [ ] **Step 2: Run and watch them fail**

CI compile failure: `gate`, `pageOrigin`, `questionOrigin` do not exist.

- [ ] **Step 3: Implement the gate and the call-site mapping**

`.handOff` → run `perform` and return true from `handOffIfWanted` (cancel navigation); `.browser` → return false
(normal load/download, equivalent to no match); `.cancel` → return true only for links, false for downloads, and never
run the action; `.ask` on a question that resolved Not Now → `.browser`. Thread `pageOrigin` from the tab at each call
site; `DownloadManager` falls back to the referrer's origin, then the target's, then nil.

- [ ] **Step 4: Verify**

CI: `ZigzagTests/DownloadRuleTests` (19 existing) plus the two new tests pass; the download-handoff tests still pass.

- [ ] **Step 5: Commit**

```bash
git add Zigzag/Web/DownloadHandoff.swift Zigzag/Tabs/Tab.swift Zigzag/Web/PopupWindowController.swift Zigzag/Web/DownloadManager.swift ZigzagTests/DownloadRuleTests.swift
git commit -m "feat: ask before a rule hands a link or download off"
```

---

### Task 7: Waiting questions, the tab dot and the edge glow

**Files:**
- Create: `Zigzag/Web/PendingQuestions.swift`
- Modify: `Zigzag/Web/SitePermissions.swift:616-760` (show/queue), `Zigzag/Tabs/Tab.swift:200-215` and the `Change` enum, `Zigzag/Sidebar/FaviconView.swift:40-60`, `Zigzag/Window/BrowserRootView.swift:940-960`, `Zigzag/Window/BrowserWindowController.swift:1260-1295`
- Test: `ZigzagTests/PendingQuestionsTests.swift`

**Interfaces:**
- Consumes: every question path from Tasks 3–6.
- Also closes a gap Task 6 left open: a download a pop-up starts has no `PromptHost` of its own (`PopupWindowController`
  does not conform), so `DownloadHandoff.decide` returns `.browser` and the rule does not run. Holding the question
  here is what makes that case visible again, so route a no-host question into the held queue with its originating tab.
- Produces:
  - `@MainActor enum PendingQuestions { static func enqueue(_ question: PendingQuestion); static func answer(_ id: UUID, _ answer: PermissionAnswer?); static func pending(tabID: UUID) -> [PendingQuestion]; static func hasPending(tabID: UUID) -> Bool; static func canShow(isFront: Bool, windowVisible: Bool) -> Bool }`
  - `struct PendingQuestion: Identifiable { let id: UUID; let tabID: UUID; let origin: String?; let title: String }`
  - `FaviconView.attentionColor: NSColor?`; `BrowserRootView.showsAttention: Bool`

- [ ] **Step 1: Write failing tests**

```swift
@MainActor @Test func aBackgroundTabHoldsItsQuestion() {
    let tabID = UUID()
    PendingQuestions.enqueue(.init(id: UUID(), tabID: tabID, origin: "https://a.com", title: "Open mpv"))
    #expect(PendingQuestions.canShow(isFront: false, windowVisible: true) == false)
    #expect(PendingQuestions.pending(tabID: tabID).count == 1)
}
@MainActor @Test func answeringClearsTheMarker() {
    let tabID = UUID(), id = UUID()
    PendingQuestions.enqueue(.init(id: id, tabID: tabID, origin: "https://a.com", title: "Open mpv"))
    PendingQuestions.answer(id, .init(action: "deny", remember: false))
    #expect(PendingQuestions.hasPending(tabID: tabID) == false)
}
@MainActor @Test func oneDotPerTabHoweverManyQuestions() {
    let tabID = UUID()
    for _ in 0..<3 { PendingQuestions.enqueue(.init(id: UUID(), tabID: tabID, origin: "https://a.com", title: "Open mpv")) }
    #expect(PendingQuestions.hasPending(tabID: tabID) == true)
}
```

- [ ] **Step 2: Run and watch them fail**

CI compile failure: `PendingQuestions` does not exist.

- [ ] **Step 3: Implement the queue and the hold**

A question that cannot be shown (`canShow` false: window hidden or tab not front) is enqueued instead of resolved; the
awaiting WebKit decision stays suspended. When the tab becomes front (`Tab.changed == .url` / selection change), the
earliest question for that tab is shown. `answer` resolves the continuation with the answer, or `nil` when Not Now.
No more than two questions are shown at once in a window; the rest wait behind "N more waiting" and take a card as
one is answered.

- [ ] **Step 4: Implement the markers**

`FaviconView.attentionColor` draws a filled dot in the accent at the existing badge position, without the cut-out.
`TabRowView` sets it from `PendingQuestions` and adds "needs your answer" to the tooltip and VoiceOver name.
`BrowserRootView.showsAttention` draws the hairline-plus-glow at `resizeHandle.frame`, on `sidebarOnRight`'s side,
hidden while the sidebar is visible; clicking it sets `sidebarVisible = true` and selects the waiting tab.

- [ ] **Step 5: Verify**

CI: the three tests pass. Manual smoke on the artifact: a handoff in a background tab shows the dot; hiding the sidebar
shows the glow; bringing the tab forward shows the banner.

- [ ] **Step 6: Commit**

```bash
git add Zigzag/Web/PendingQuestions.swift Zigzag/Web/SitePermissions.swift Zigzag/Tabs/Tab.swift Zigzag/Sidebar/FaviconView.swift Zigzag/Window/BrowserRootView.swift Zigzag/Window/BrowserWindowController.swift ZigzagTests/PendingQuestionsTests.swift
git commit -m "feat: hold a question for a tab that isn't in front, and mark it"
```

---

### Task 8: Site Controls, Settings › Privacy, Settings › Downloads

**Files:**
- Modify: `Zigzag/Settings/SettingsView.swift:3185-3300` (privacy site rows), `Zigzag/Settings/DownloadRuleSheet.swift` or the Downloads pane list (`Zigzag/Settings/SettingsView.swift` Downloads section)
- Modify: `Zigzag/Web/SitePermissions.swift:251-300` (`setChoice`, `choice`)

**Interfaces:**
- Consumes: Task 1's store.
- Produces: `SitePermissions.actions(origin:) -> [String: String]` used by Settings; a per-rule site list in Settings ›
  Downloads fed by `SitePermissions.sites(prefix: "handoff:<uuid>")`.

- [ ] **Step 1: Write failing tests**

```swift
@Test func siteControlsStillReadTheUnifiedAnswers() {
    SitePermissions.remember("newTab", subject: PermissionSubject.popups, origin: "https://a.com")
    #expect(SitePermissions.choice(.popups, origin: "https://a.com") == .allow)
    SitePermissions.setChoice(.block, for: .popups, origin: "https://a.com")
    #expect(SitePermissions.action(PermissionSubject.popups, origin: "https://a.com") == "deny")
}
@Test func settingsListsTheSitesARuleWasDecidedOn() {
    let rule = UUID()
    SitePermissions.remember("handOff", subject: PermissionSubject.handoff(rule), origin: "https://a.com")
    #expect(SitePermissions.sites(prefix: "handoff:\(rule.uuidString)") == ["https://a.com"])
}
```

- [ ] **Step 2: Run and watch them fail**

CI compile failure: `sites(prefix:)` does not exist.

- [ ] **Step 3: Implement**

`setChoice(.allow)` writes the subject's ordinary yes (`"mini"` for pop-ups, `"allow"` otherwise); `.block` writes
`"deny"`; `.ask` removes. Add `sites(prefix:)`. In Settings › Downloads, under each rule, list allowed sites and denied
sites with a Forget button per site; deleting a rule calls `forgetActions(prefix: "handoff:<uuid>")`.

- [ ] **Step 4: Verify**

CI: both tests pass; `SiteControlsTests` unchanged and passing.

- [ ] **Step 5: Commit**

```bash
git add Zigzag/Settings/SettingsView.swift Zigzag/Web/SitePermissions.swift ZigzagTests/SitePermissionsPolicyTests.swift
git commit -m "feat: show the new answers where a site's choices are listed"
```

---

### Task 9: Strings, changelog and the whole-branch check

**Files:**
- Modify: `Zigzag/Resources/Localizable.xcstrings`, `CHANGELOG.md`
- Modify: `.github/workflows/build-zigzag.yml:66-73` (run the new test suites)

**Interfaces:**
- Consumes: all previous tasks.
- Produces: a shippable branch with a downloadable artifact.

- [ ] **Step 1: Add the new strings to the catalog**

Add entries for "This time", "Always on this site", "This Tab", "New Tab", "Mini", "Open in Browser", "Hand Off",
"needs your answer", "\(n) more waiting". Keep the existing camera/location/notification copy.

- [ ] **Step 2: Extend the CI test step**

Replace `-only-testing:ZigzagTests/DownloadRuleTests` with the four suites this plan touches:
`-only-testing:ZigzagTests/DownloadRuleTests -only-testing:ZigzagTests/SitePermissionsPolicyTests -only-testing:ZigzagTests/PermissionPromptTests -only-testing:ZigzagTests/PendingQuestionsTests -only-testing:ZigzagTests/SiteControlsTests`.

- [ ] **Step 3: Add the changelog entry**

Under Unreleased: one line for the unified permission banner, one for remembered denies and destinations, one for
handoff rules asking per site.

- [ ] **Step 4: Whole-branch verification**

Push; watch CI. Expect Build, sign, zip and every listed suite to pass. Then download the artifact:

```bash
cd /private/var/folders/ms/1k14zlbd3t79sp0ygnzn5km00000gp/T/opencode && rm -rf perm-artifact && mkdir perm-artifact &&
cd perm-artifact && gh run download <run-id> --repo Lakeland97/zigzag -n Zigzag-Dev &&
unzip -q Zigzag-Dev.zip && codesign --verify --deep --strict Zigzag.app &&
/usr/libexec/PlistBuddy -c "Print :CFBundleDisplayName" Zigzag.app/Contents/Info.plist
```

Expected: `Zigzag Dev` and a valid signature.

- [ ] **Step 5: Manual smoke list** (record results in the plan or the session)

1. First visit to a site with a matching handoff rule: banner appears, Deny cancels, Open in Browser loads, Always Hand
   Off stops asking.
2. Camera: answer Always Deny, reload, no question.
3. A pop-up with no stored answer: four buttons, Mini opens the viewer, Always Open in New Tab skips the question next
   time.
4. Background-tab handoff: dot, then banner on bringing the tab forward.
5. Sidebar hidden: edge glow, click restores the sidebar on the waiting tab.
6. Old answers still honoured after upgrading the app.

- [ ] **Step 6: Commit**

```bash
git add Zigzag/Resources/Localizable.xcstrings CHANGELOG.md .github/workflows/build-zigzag.yml
git commit -m "docs: permissions in the changelog, and test them in CI"
```
