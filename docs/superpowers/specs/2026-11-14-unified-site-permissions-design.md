# One permission model for sites

## Why

Zigzag asks a site for permission in seven places — camera and microphone, location, notifications, screen sharing,
pop-ups, opening an app, and (new) handing a link or download to a download rule — and each was built on its own. The questions differ in
their buttons, in what they remember, and in what "no" does: only an *allow* can be remembered from a question, a
deny is forgotten when the page goes, and the handoff rules would otherwise act with no question at all. A user cannot
tell from one prompt what the next one will do.

This makes the model the same everywhere: **Allow** or **Deny**, **this time** or **always**, with at most one
caller-supplied alternative (for a handoff rule, *Open in Browser*). "Ask" stops being a stored answer; it is the
absence of one. Site Controls and Settings › Privacy keep showing what is stored: nothing (ask each time), allowed, or
denied.

## What exists now (as of `7aaea117`)

- `SitePermissions` keeps `[String: Bool]` under `"origin|kind"` in `UserDefaults`, where `kind` is `camera`,
  `microphone`, `cameraAndMicrophone`, `location`, `notifications`, `popups`, `apps`, or `app:<scheme>`. A missing key
  means ask.
- `PagePermissionAnswers` (on `Tab`) keeps answers for the page that asked, cleared on navigation. It is what "this
  time" means today for camera, location, notifications and pop-ups.
- `SitePermission` (cameraAndMicrophone, location, notifications, popups, apps) drives the Site Controls rows and the
  Settings › Privacy dropdowns through `PermissionChoice` (`.ask`, `.allow`, `.block`).
- `PermissionPrompt.ask` shows the in-page sheet with a deny button, an optional middle button ("Always Open"), and an
  allow button, returning `Answer` (`.allow`, `.always`, `.alternate`, `.deny`, `.notNow`).
- `ExternalLinks` asks before opening another app; a Block stops it silently, Always Open runs at once.
- `DownloadHandoff.perform` runs a rule's action immediately when the rule matches, from link navigation, WebKit
  download decisions, response-stage downloads, popups and the context menu.

## The answer model

One value describes every answer:

```swift
struct PermissionAnswer {
    /// The action chosen from this question's own list: "allow", "deny", "thisTab", "newTab", "mini", "handOff"…
    var action: String
    /// Kept for the site (true) or only for the page that asked (false).
    var remember: Bool
}
```

Each question supplies its actions, in a fixed order: **Deny** first, always plain; the question's ordinary yes last,
always prominent in the accent; anything between them plain. So:

- Camera, microphone, location, notifications, app launch: Deny / Allow.
- Handoff rule: Deny / Open in Browser / Hand Off.
- Pop-up: Deny / Open in This Tab / Open in New Tab / Open in Mini, where Mini is the pop-up viewer and the prominent
  yes.

"this time" = `remember == false`, kept in the tab's `PagePermissionAnswers`; "always" = `remember == true`, kept in
`SitePermissions` for the origin. A stored answer is never asked again until it is forgotten in Site Controls or
Settings.

The page store holds the answer as an **action id**, not a yes or no, so a question whose answers are not just yes and
no holds for the page too: a handoff rule answered "Open in Browser" this time is not asked again for a download the
same page starts, and a pop-up answered "Mini" this time opens in the viewer again. A handoff rule's page answer is
keyed by the rule as well as the origin (`handoff:<rule UUID>`), so two rules on one page keep their own answers. Yes
and no still read as `"allow"` and `"deny"`, which is what the camera, microphone, location and notification paths use.

## The question

The prompt becomes a **permission banner**: the same in-window overlay view (`FloatingPanelView`) it is today, so it
never becomes key, never becomes first responder, and never takes the click or keystroke that summoned it. What changes
is its presence:

- **Wider:** laid out across the page's width (340 pt minimum, up to `Tokens.Dialog.width`·1.5 where the window allows),
  anchored under the address bar where the eye already goes after a navigation.
- **Loud without moving:** a tinted leading edge in the space's accent color, the site's favicon or the action's icon,
  body-size text rather than small text, and one soft fade in. No pulsing, no sound, no auto-dismiss, and Reduce Motion
  turns the fade into a cut. It is the only tinted surface on the page, which is what makes it hard to miss.
- **One composition:** the request line naming the site and what is asked; a **This time / Always on this site**
  dropdown (`DropdownButton`) directly above the buttons; then one row of actions, always in the same order and weight:
  Deny plain on the left, alternatives plain in the middle, the ordinary yes prominent on the right in the accent. A
  question with more than three actions — the pop-up's four — puts its buttons on their own row under the request, at
  equal width, rather than shrinking them below a comfortable hit target. The dropdown picks the duration; the buttons
  pick the action. When nothing can be remembered, the dropdown stays in place **greyed out**, with a tooltip saying why
  — a private window, an insecure page, embedded content, or a page with no site. A control that vanishes explains
  nothing; a greyed one teaches.
- **Measured, two arrangements:** when the row fits, it is one line — question, then buttons, then dropdown. When the
  measured widths don't fit (narrow window, Zigzag Mini, longer translations), the dropdown and buttons move to a
  second line under the question. The breakpoint comes from `fittingWidth`, not a hard-coded number.

**Not seen yet is not silently answered.** A question is only shown in a window that is visible with its tab in front,
as today. A question that arrives for a background tab, a hidden window, a pop-up, or Zigzag Mini without focus is
**held** — a handoff's navigation or download waits, the camera or location request waits — and the tab gets the marker
described below. The banner asks the moment that tab is brought forward. A held question is never dropped and never
auto-allowed. When more than one question is waiting, the banner says how many.

**Several questions at once are stacked, and the stack is capped.** A site can ask for the camera and then location and
then to open an app, and serialising those silently makes each one a surprise after the last answer. So each question
gets its own banner card, up to two visible at a time, oldest on top and newest beneath, each with its own dropdown and
buttons. Anything past two waits behind a line on the newest card — "2 more waiting" — and takes a card as soon as one
is answered. The cap is deliberate: a third full-width card would cover the page and make the wrong click likely.
Every card keeps the half-second guard on Allow, and answering a card never answers another.

The sheet still queues one question per window, still returns `.notNow` when the window closes or the tab moves to
another site, and still records `SitePermissions.noteAsked`.

`PermissionPrompt.ask` returns `PermissionAnswer` instead of `Answer`. Its callers map the answer onto their own
behaviour; `.notNow` stays a separate outcome for "the question never got an answer".

## Storage

`SitePermissions` keeps the same keys but stores an action id per subject instead of a yes/no: `[String: String]`,
absent meaning ask. Existing `[String: Bool]` answers are migrated once, on launch: `true` becomes that subject's
ordinary yes (for pop-ups, "mini"), `false` becomes "deny".

- `origin|<kind>` for camera, microphone, cameraAndMicrophone, location and notifications: "allow" or "deny".
- `origin|popups`: "mini", "thisTab", "newTab", or "deny" — so *Always Open in New Tab* really is remembered as that.
- `origin|app:<scheme>`: "allow" or "deny" for that one app. The site-wide `origin|apps` row that Site Controls writes
  keeps working, and a site-wide "deny" still blocks every app.
- `origin|handoff:<rule UUID>`: "handOff", "browser", or "deny".

Site Controls and Settings › Privacy still show three choices per permission — Ask Each Time / Allow / Block — derived
as: nothing for Ask, "deny" for Block, anything else for Allow. Changing a row writes the subject's ordinary yes or
"deny".

`SitePermissions` gains the accessors this needs (`action(subject:origin:)`, `remember(_:subject:origin:)`,
`forget(subject:origin:)`) and keeps `choices(origin:)`, `forgetEverything(origin:)`, `sites`, `reset(origin:)` and the
existing app accessors working for the UI. Deleting a download rule forgets its `handoff:<uuid>` keys on every site.

A private window asks but stores nothing, as today. A frame from another site keeps its own answer key
(`origin|embed:<frame>`), so its answer cannot leak to the page's origin.

## Call sites

| Question | Actions (plain → prominent) | What each does |
|---|---|---|
| Camera / microphone | Deny / Allow | refuse; grant capture |
| Location | Deny / Allow | refuse; grant |
| Notifications | Deny / Allow | refuse; show them |
| Screen sharing | Deny / Share Screen / Share Window | refuse; macOS's picker for a display or a window (asked every time, nothing kept) |
| Pop-ups | Deny / This Tab / New Tab / Mini | block it; load its address in this tab, a new tab, or the Mini pop-up viewer |
| App launch (`ExternalLinks`) | Deny / Open | nothing; `NSWorkspace.open` |
| Handoff rule | Deny / Open in Browser / Hand Off | cancel the navigation or ignore the download; load it normally; run the rule |

Every call site reads the stored action first, so an always-yes runs without a banner and a "deny" never runs. Handoff
asks in `DownloadHandoff.perform`'s callers (or in `perform` itself) before any side effect, including reading cookies.

## Downloads, added after this design

The design above put the downloads prompt out of scope; it was asked for later, so it is here now as the eighth
question, and it uses the same answer shape, the same sheet and no new mechanism.

| Question | Actions (plain → prominent) | What each does |
|---|---|---|
| Downloads | Don't Allow / Allow | refuse the file, and say so over the page; let it be saved, and decided as usual |

- Asked for a new site's first download, **from either direction**: a file a page starts on its own, and a link you
  clicked that turns out to be one. "This time" answers for the page that asked; "Always" is kept for the site, so
  Settings › Privacy lists it like every other choice, and its Site Controls row offers Ask / Allow / Block.
- A deny blocks the file wherever it came from, and a toast says so where the page is — a click that quietly saves
  nothing is the one outcome nobody can see.
- **The question is permission only.** Where an allowed file lands is a separate decision, already made per file type
  (the `fileType` rules and their destinations), falling back to Save downloads to.
- `DownloadPolicy` keeps its own rules, and they are asked first: a frame's file with no click near it, or a page's
  second file inside half a minute, is refused for the reason it always was and never reaches the question. An
  "Always allowed" site is not a licence for a stream.
- **A rule you wrote beats the question.** A handoff rule takes the file before the policy decides, so nothing is
  asked; a destination rule is not a handoff, and the question comes first.
- A put-off question refuses the file, as every put-off question refuses what it asked. With nowhere to ask (a window
  that has gone) the download is left as WebKit decided it rather than silently eaten.
- Private windows ask and keep nothing, as every question does.

## Goals

- One answer shape and one sheet for all seven questions.
- A deny can be remembered per site from the question, not only from Settings.
- A handoff rule never runs without an answer: first use on a site asks, and Deny / Open in Browser / Hand Off are all
  available, each rememberable.
- A pop-up's destination is remembered too: Always Open in Mini, Always Open in New Tab and Always Open in This Tab are
  different standing choices.
- Existing stored choices, Site Controls rows and Settings › Privacy dropdowns keep working; the dropdowns still offer
  Ask Each Time / Allow / Block, which now mean no stored action / "deny" / any yes.
- Tests cover the decision table for every subject, private windows, and embedded frames.

## Non-goals

- No per-rule default permission in the rule editor; the answer is always about a site.
- No new permission kinds. (The downloads prompt was asked for after this design and is delivered: see "Downloads,
  added after this design".)
- No change to ContentBlocker, extensions, zoom, dark pages, keep-awake or other site choices.
- No redesign of the Settings › Privacy page beyond wording that refers to the unified answers.
- No change to how the handoff rules match URLs or run actions.

## Anti-goals

- Never store an answer for a private window.
- Never let an embedded frame's answer count for the page's origin (or vice versa).
- Never show a permission sheet for a background tab, or leave one up after its tab moved on.
- Never drop a held question, and never answer one on the user's behalf because it waited.
- Never take key status, first-responder status, or a keystroke/click to put a question up.
- Never let "this time" silently become "always" (or the reverse).
- Never prompt twice for the same question while an answer is stored.
- Never cancel a link without a way back: a denied handoff leaves the page as it was, and any other choice loads it.

## Constraints

- Swift 6 with `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor`; the permission store is main-actor, as today.
- The sheet must lay out up to four actions without shrinking a button below its comfortable hit target; the measured
  fallback moves the row under the request instead.
- Handoff questions run inside WebKit decision callbacks; awaiting a sheet is allowed and must not deadlock the
  decision (the tab may close, the question must resolve `.notNow`).
- New strings go through `String(localized:)` with comments, as the project's localization workflow requires.
- The repo has no Xcode here; the app is built and tested on the CI runner, so type-level changes must compile under
  the macOS 27 SDK.

## Decisions taken here

- The duration is a labelled This time / Always dropdown above the action buttons, not a checkbox and not extra
  buttons; the buttons are the question's own actions, Deny first and the ordinary yes last.
- What is stored is the chosen action, not a yes/no: "deny", "allow", "mini", "newTab", "thisTab", "handOff" or
  "browser", per subject and origin.
- Denying from the question stores "deny" for the same site, for every kind where a site-wide deny exists.
- App launches keep the site-wide `apps` flag as their deny key; the per-app allow key is unchanged.
- Handoff keys are per rule and per origin, with the rule's UUID so renaming a rule keeps its answers.
- Site Controls keeps its three choices (Ask Each Time / Allow / Block) because "Ask" is still meaningful as a stored
  state of "nothing kept".
- Settings › Downloads shows, under each rule, the sites it is allowed or denied on, with a way to forget them. This is
  the smallest surface that makes the new decisions visible outside Site Controls.

## Waiting for an answer

Any question — camera, microphone, location, notifications, opening an app, a held handoff — marks the tab that asked,
so a question that can't be shown yet is still visible:

- **Sidebar showing:** an accent dot on the waiting tab's favicon, using the same badge cut-out `FaviconView` already
  draws for developer badges, so nothing new is invented. The row's tooltip and VoiceOver name gain "needs your
  answer". One dot per tab, however many questions are waiting for it.
- **Sidebar hidden, Mini, or a web app window:** a soft glow along the sidebar's edge — a hairline in the accent color
  over a short outer glow, in the same place the resize handle lives and on the side `sidebarOnRight` puts the sidebar.
  It fades in once and stays; it does not pulse or blink. Its tooltip reads "2 tabs need your answer", and clicking it
  brings the sidebar back and selects the waiting tab.
- **When the question is on screen**, no marker is needed in that window; the marker returns if the banner is dismissed
  without an answer (Not Now) while the question stays pending, and when the question waits for a tab that isn't in
  front.
- A marker goes when its answer is given, when the tab closes, or when the tab navigates elsewhere. Nothing about the
  marker times out.

A marker also covers a pop-up waiting for its answer.

## Questions the builder raised, settled here

- **Which site a handoff question is about.** The page that produced the link or download, not the address being
  handed off. A CDN-hosted file therefore asks on the site you were reading, and a magnet link is rememberable. The
  page origin is threaded through `DownloadHandoff.Request`; when there is no page, the referrer's origin stands in,
  then the target's. With none of the three (a script-started download with no referrer), the question is asked every
  time and nothing is stored.
- **`.notNow` for a handoff.** It behaves as if no rule matched: the navigation or download carries on normally. It
  never runs the rule and it is not the same as Deny, which cancels. Nothing is stored.
- **App launches keep their extra gates.** Always-allow for an app is still kept only for an https page and never for a
  frame from another site, and a stored block still applies to foreign frames. The duration dropdown is therefore
  greyed, with that reason as its tooltip, in private windows, on origin-less pages, off https, and inside a foreign
  frame.
- **Session guards.** `asking` stays (one question per site+scheme at a time). `declined` is replaced by the tab's
  page-scoped deny, which already lasts until the page navigates. `putOff` and its 60-second pause after Not Now stay.
- **A handoff caught at new-window time.** Open in Browser opens a normal new tab, since there is no existing tab to
  load into. The pending disposition is kept until that choice is made.
- **Pop-ups use the banner too, and remember where they went.** WebKit's `createWebViewWith` is synchronous: the answer
  has to exist before the pop-up window does. So a pop-up is decided in this order. A stored yes opens it at once in the
  remembered place — Mini (the pop-up viewer), a new tab, or this tab — with no question. A stored "deny" blocks it at
  once. Anything else returns nil for this request, and the banner asks with **Deny / This Tab / New Tab / Mini** and the
  duration dropdown. Choosing This Tab or New Tab loads the pop-up's address there; Mini opens it in the pop-up viewer.
  Always is what makes the next pop-up synchronous and seamless, including the `window.opener` exchanges that a
  late-opened window cannot have: a first-time choice is a fresh load and is documented as such. The blocked-pop-up
  toast goes away.

The following is settled as part of this design:

## Left to the builder

- Exact button and dropdown wording, within the project's tone.
- The dropdown's exact width and whether its label sits inside it or beside it.
- How the Settings › Downloads site list is laid out and whether it is collapsed by default.
- Names of the new `SitePermissions` accessors and test helper seams.
- Whether `Answer` is deleted or kept as a thin mapping to `PermissionAnswer` while call sites migrate.

Still open: nothing. The design is complete once this document is approved.
