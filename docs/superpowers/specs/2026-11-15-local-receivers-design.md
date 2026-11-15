# Reaching a helper on this Mac

## Why

Two user reports, and a correction found while checking the artifacts: the loopback case is real, but the two
reports are not the same case. ZeroWork's editor (a page at `https://creator.zerowork.io`) calls
`fetch('http://localhost:9990')` and `ws://localhost:9990` to its desktop agent; that works in Chrome and Firefox and
not in Zigzag. **Downie's current companion extension does not use loopback at all:** its `manifest.json` asks for
`nativeMessaging`, and its background calls `browser.runtime.sendNativeMessage`. That is a different gap (native
messaging, not mixed content) and is the owner's; it is not what the extension door below is for. The extension door
is for extensions that use loopback HTTP or WebSocket, which remains a real class even though Downie's current build
is not in it.

It is not Zigzag's bug, but it is Zigzag's to fix. **WebKit does not treat loopback as a trustworthy origin**, so a
secure page — an https site, or an extension's `webkit-extension://` page — reaching for `http://localhost` is mixed
content, and WebKit blocks it before it leaves the browser. Chrome and Firefox exempt loopback; WebKit does not, and
there is no per-site switch for it.

Upstream closed the ZeroWork report as waiting on Apple. That is true of *WebKit* and not of Zigzag: Zigzag does not
have to ask WebKit to make the request. It can make the request itself and hand the answer back — a shape Zigzag
already uses for extensions, and which needs a way for the person to say yes.

## The promise

**An extension's background can reach a program listening on this Mac when the person has turned that on for that
extension. A page's own scripts — `fetch`, `XMLHttpRequest`, `WebSocket` — can do the same only for a site the person
has explicitly turned it on for. Nothing more.**

The default is extensions only. Website access is off at two levels: a **global setting** in Settings › Privacy,
off until the person turns it on after a briefing on what it allows and what it risks; and, with that on, a
**switch for one origin** in Site Controls. A page can raise neither, and it is never on for "the web".

## Goals

- ZeroWork's `fetch` and `ws://` to `localhost:9990` work, with the site's explicit opt-in, from the page as it is
  written.
- An extension that talks to a program on this Mac over loopback can do so with its own switch. (Downie's current
  extension is a native-messaging case, not this one — see Why.)
- One mechanism behind both, so the site case is a gate on the extension case and not a second feature.
- Both doors are visible, revocable, and off until turned on. The site door needs the global setting first and then
  the site's own switch; no page can raise either.
- Nothing about it is silent: a call that goes through Zigzag is a call the person allowed.

## Non-goals and anti-goals

- **Not the local network.** Loopback only — `localhost`, `*.localhost`, `127.0.0.0/8`, `::1`. A printer, a router, a
  NAS, another machine: not this. macOS's own "local network" permission means the LAN, so this is narrower on
  purpose, and the wording must not imply otherwise.
- **Not subresource loads.** A granted site may not load `<img>`, `<script>` or a stylesheet from this Mac. That is
  the difference between "scripts can talk to a local app" and "the page can pull and render anything local", and only
  the first is promised.
- **Not a CORS escape.** Zigzag must not reach a helper a site could not reach in Chrome. A site's call goes out
  **as that site** and the helper's own CORS reply is honoured; a helper that refuses the site refuses it here too.
  (An extension is the one exception, and only because Chrome exempts extensions with host access — see below.)
- **Never silent, and not a private window's standing answer** (see Private windows).
- **Not a patch over a regression.** Downie's extension worked in Zigzag until recently; that belongs to the repo
  owner and is not chased here (see Risks).

## What exists now (as of `d890b439`)

**The extension half is already built, and it is the precedent for all of this.** `bridge.js` patches
`globalThis.fetch` and can run a request natively through the `extensionFetch` namespace
(`BridgeExtensionFetch` / `ExtensionFetchRequests` in `Zigzag/Extensions/BridgeNamespaces.swift`):

- **Reads** (GET/HEAD) open a hidden `WKWebView` with `loadHTMLString(_:baseURL:)` whose base URL is the target's own
  directory, then run `requestScript` inside it — a `fetch` with `mode: 'same-origin'`, `credentials: 'include'`. So
  the request *is* the target's own origin, and only the target's own cookies travel.
- **Writes** go through `ExtensionWrite.writeRequest`, which makes a native `URLSession` request that **manufactures
  the sender's Chrome extension Origin** and uses that profile's cookies. This is the precedent for presenting a
  caller's identity, and it is the transport the loopback case wants (see *What the helper sees as the caller*).
- The gate in `bridge.js` (`bridge.js:96`) is `option('credentials', 'same-origin') !== 'include'`, so a plain
  `fetch('http://localhost:PORT')` — the default — falls through to WebKit's own fetch and is blocked.
- `ExtensionFetchRequests.isLoopback` (`BridgeNamespaces.swift:818`) already knows `localhost`, `*.localhost`, `::1`
  and `127.0.0.0/8` — but it arrived with #90 on the **write** branch only
  (`if url.scheme == "http", !Self.isLoopback(url) { return ["fallback": true] }`, line 766).
- `XMLHttpRequest` is patched **nowhere** in `Resources/Extensions/`. `ws://` is the one case already handled, by
  `WebSocketBridge`, which opens the socket natively with `URLSessionWebSocketTask`.
- `Zigzag/Info.plist` already carries `NSAllowsArbitraryLoads`, so a plain-HTTP request made natively is allowed.

Three facts about the existing gates decide the shape of this design:

1. **`ExtensionBridge.allows` requires the permission to be declared in the extension's own manifest**
   (`ExtensionBridge.swift:92–104`: `declared.required.contains(permission) || declared.optional.contains(permission)`).
   A Chrome Web Store extension cannot declare a permission Chrome doesn't have, so a Zigzag-only permission can
   never be granted that way.
2. **`BridgeExtensionFetch.allows(url:context:)` gates on host access**, not on a permission namespace
   (`static let permission = ""`), and `ExtensionReport` deliberately leaves `localhost` and `127.0.0.1` out of what
   a manifest can ask for — so loopback is not grantable through the manifest today either.
3. **`WebSocketBridge.allows` returns `true` for loopback unconditionally** (`WebSocketBridge.swift:90`). There is
   no grant check on that path at all: today, an extension's service-worker background can already open
   `ws://localhost` with nothing asked. The shim exists to stop a worker freezing, not as a localhost feature.

The site half exists as a model to fit into:

- `SitePermission` (`Zigzag/Web/SitePermissions.swift:454`) is the vocabulary: `cameraAndMicrophone, location,
  notifications, popups, apps, webRTC`, each with `kinds`, `choices`, `inPrivate` and `title`; `SitePermissions` keeps
  the answers per site and is what Site Controls and Settings › Privacy show.
- `PermissionPrompt` (same file) is the card, and `PermissionPrompt.queue` (`:577`) is how a second ask is held while
  one is up.
- **The answer model is moving, and this design is written against where it is going.** On the base, a card's answer
  is page-scoped (`Tab.permissionAnswers`, cleared on navigation) and only an allow is ever remembered, with a
  standing no left to Site Controls. `feat/site-permissions` replaces that with `PermissionAnswer` (`action` +
  `remember`) and a this-time/always control that is **free-standing**: `PermissionAnswer(action: action.id, remember:
  canRemember && prompt.duration.selectedIndex == 1)` stores *whichever* action was chosen, and
  `SitePermissions.rememberAnswer` writes it down for the site whenever `remember` is true. So **Allow or Deny, this
  time or always** — a remembered no is a standing block exactly like a remembered yes — and a private window keeps
  nothing whatever the answer says. That holds for the cards that offer the control today (downloads, location,
  camera and microphone, opening an app); it is **not yet universal** — notifications and display capture pass
  `canRemember: false` and keep their answers for the page, so the model is what this design builds on, not a
  description of every card as it stands.

**Which makes the two a merge-order pair.** The unified model lands with `feat/site-permissions`; this design wants it
for the site door and must not grow a second, parallel answer model beside the old card. If it has not landed by the
time this is built, bring that answer shape over with it rather than reinvent it. The extension door does not depend
on it.

## One runner, two identities

The two cases differ in **whose permission is checked and who the helper thinks is calling**, so there is one request
runner and two doors:

- **The runner** makes an HTTP request or opens a WebSocket from the app, on the caller's behalf, and hands the result
  back. It is `ExtensionWrite.writeRequest`'s native transport, generalised: a real `URLSession` request, not the
  hidden-page read (see below).
- **The extension door** is a per-extension grant the **person** turns on — not a manifest permission, for the reason
  in fact 1 above. Off by default; recorded with the extension's other grants; shown and revocable in the extension's
  own page. The runner presents the extension's own origin, as `ExtensionWrite` already does, and is exempt from CORS
  exactly as Chrome exempts an extension with host access.
- **The site door** is a `SitePermission.localReceivers` switch for the asking origin, **off by default**, turned on
  by the person in Site Controls — not by a question over the page. It is reachable only while the **global setting**
  is on (see below): before that, the row is not offered and a call is refused as it is today. The unified permission
  model described above stores the answer; a no is a standing block, a yes is a standing grant, and there is no
  special case here to invent. The runner presents the site's origin and honours the helper's CORS reply.

Everything else — what counts as local, what is refused, how a refusal fails — is the same for both.

## The global setting and its briefing

The site door has a master switch of its own — working words **Allow websites to reach apps on this Mac** — in
Settings › Privacy beside Site Permissions, **off by default**. Turning it on shows a sheet that says, plainly:

- **What it allows:** a site you then switch on can make `fetch`, `XMLHttpRequest` and `WebSocket` calls to programs
  on this Mac, over loopback only.
- **What it does not allow:** the LAN, other machines, subresource loads, or a page granting itself.
- **The risk:** a local program may not have been written to be reachable by a web page, and a site you grant could
  use it in ways you did not intend. Only grant sites you trust.
- **How to undo it:** the per-site switch in Site Controls for one site, and this master switch for all of them.

The sheet needs an explicit acknowledgement ("I understand"), and the setting's row keeps a link that reopens the
briefing. While the master switch is off, the per-site Local Receivers row is not offered (or is disabled with the
reason), and a loopback call from a page is refused exactly as it is today — the shim is there, but the door is shut.

This is the user's requirement (2026-11-17): the site door is a deliberate, explained feature, not a checkbox buried
in a site panel. The extension door is unaffected; it keeps its own per-extension switch.

## What the helper sees as the caller

This decides the transport. It has been read from ZeroWork's page and its agent (2026-11-17); what remains is an API
question on Zigzag's side, not a helper question.

In Chrome the helper receives `Origin: https://creator.zerowork.io` and must answer CORS for it (or it would not
work in Chrome either). So the runner makes a **native request that presents the site's own origin**, and treats the
helper's CORS reply as binding. That means:

- the hidden-page-at-origin read is **not** used for sites — it would present `http://localhost:PORT` as the caller,
  which a helper that whitelists the site's origin would refuse;
- and it is **not** used where a helper expects `chrome-extension://<id>` — which is what `ExtensionWrite` already
  manufactures, and what the extension door keeps doing.

**What the ZeroWork page actually does** (read from `socket-5aefe823.js` in the editor's own bundle, 2026-11-17):

- it opens a **socket.io WebSocket** at `ws://localhost:9990/ws` with `transports: ["websocket"]` and infinite
  reconnection — no polling, no SSE and no long-poll;
- on a reconnect attempt it probes `http://localhost:9990/` with an async `fetch` (`cache: "no-store"`, a 3 s
  timeout) and reads a JSON `message`, scanning the ports 9990, 14990, 19990, 24990 and 29990;
- both calls carry the page's own `https://creator.zerowork.io` origin, and the page uses no synchronous XHR.

So the site runner needs both a one-shot HTTP call and a **held WebSocket that pushes back into the page**, and one
switch for the origin must cover both. The helper's side is now known (ZeroWork Agent 1.1.76, `dist-server/core.js`,
read from the DMG without installing or running it):

- it binds `127.0.0.1` and tries `9990`, `14990`, `19990`, `24990`, `29990` in turn — the same list the page scans;
- `GET /` answers JSON `{message: "ZeroWork Agent running", version, port, address}` with
  `Access-Control-Allow-Origin: *` and no credentials;
- `/ws` is socket.io with `transports: ["websocket"]`, `allowEIO3`, and an `allowRequest` that accepts **only an exact
  `Origin`** in `["http://localhost:5173", "https://creator.zerowork.io", "https://creator.dev.zerowork.io"]`; the
  socket.io CORS setting uses the same list with credentials.

So the helper **whitelists** rather than reflects: the runner must present the page's origin byte for byte, and a
`webkit-extension://`, `null` or rewritten origin fails the handshake even though the page works in Chrome. Holding
the socket open is also part of this: the existing 32 MB / 30 s whole-body read cannot serve it.

**To verify first:** that `URLSessionWebSocketTask` will send an `Origin` header chosen by Zigzag. If it refuses
`Origin` as a reserved header, the WebSocket runner needs its own handshake rather than that API.

## What counts as local

`ExtensionFetchRequests.isLoopback`'s list, and nothing wider: `localhost`, `*.localhost`, `::1`, `127.0.0.0/8`. The
destination's **port is not restricted** (a helper may listen anywhere), and only `http` and `ws` are caught —
`https`/`wss` on loopback are not blocked by WebKit and stay with it.

## The runner

### Extensions

1. The loopback branch is checked **before** `BridgeExtensionFetch.allows`'s host-access test, against the extension's
   `localReceivers` grant instead — because a loopback URL won't survive that test (fact 2 above).
2. In `bridge.js`, a loopback URL takes the native path **regardless of credentials mode**, so a default
   `fetch('http://localhost:PORT')` is answered natively instead of falling through to WebKit.
3. `XMLHttpRequest` gains a shim with the same shape as the `fetch` one (send, wait, answer), since it is unpatched
   today and helpers use it.
4. `WebSocketBridge.allows`'s unconditional `true` for loopback is **replaced** by the grant check. This is a fix in
   its own right: that path is open today.
5. The grant is a switch in the extension's own row in the Extensions list, plus the reason it might want it.

### Sites

1. A user script in the **page's own world** patches `fetch`, `XMLHttpRequest` and `WebSocket`. It must be the page's
   world — a world of its own would not be the page's `fetch`, and the page would keep using WebKit's.
2. A call whose URL is loopback is sent to native code over a script message handler and held while the grant is
   decided. `WKScriptMessageHandlerWithReply` gives the promise the shim needs; the WebSocket case also needs pushes
   from native into the page, so it keeps a shim object and native calls into it per frame, as the extension shim does.
3. **Native code decides the asking origin, never the message.** The grant is looked up from the frame's own origin
   (`message.frameInfo.securityOrigin`, resolved by Zigzag), because a page-world shim is the page's to forge. The
   shim may say what it wants; it may not say who it is.
4. **The switch, not a question, is the opt-in.** A site with no grant is refused at once; the page learns nothing
   about the shim except that the call failed, as it does today. The person turns the site on in Site Controls ›
   Local Receivers, for that exact origin, and the next call goes through. A page cannot ask for the grant, queue a
   card for it, or carry one from another site. One switch covers every call to that origin — HTTP and WebSocket
   alike.
5. A denied or failed call must fail the way WebKit's block fails today — `fetch` rejects with a `TypeError`, XHR
   fires `error`, a WebSocket closes — so a refused page behaves exactly as it does now, and no site has to handle
   anything new.

## Private windows

Follow what Zigzag already does. A private tab's page asks and **keeps nothing** (like camera, location, apps and
downloads there); extensions never see a private tab at all, so their door cannot apply to one.

## What is deliberately not covered

- `<img>`, `<script>`, stylesheets, `sendBeacon` and `EventSource` — not promised, so not caught.
- The LAN, `.local` names, and anything that is not loopback.
- `https`/`wss` on loopback (WebKit already allows them).
- **`ws://` from an extension's background *page* or popup.** `ExtensionShims.webSocketShim` returns immediately when
  `typeof window !== 'undefined'` and `usesWebSocketShim` requires `background.service_worker`, so only an MV3
  service-worker background is covered today. Widening that is a later step, and it must be said plainly rather than
  implied.
- **Synchronous `XMLHttpRequest`.** No page-world shim can answer it: `WKScriptMessageHandlerWithReply` has no
  synchronous form and nothing native can unblock a blocked `send()`. If a helper needs it, the promise must be
  narrowed in the words the person reads.
- Requests the page makes after the shim is removed or replaced — see Risks.

## What the builder still decides

- The permission's own name (`localReceivers` is the working one), and the exact switch wording.
- Where the site switch lives — the site's Permissions page in Site Controls, or a Local Receivers row of its own,
  with the origin it applies to said plainly beside it — and the exact words of the master switch, its row, and the
  briefing's acknowledgement.
- Where the extension's switch lives — its row in the Extensions list, or its own page. The row is the more visible.
- Whether the shim is one script or three, and how the runner is organised.
- Whether an answered site is keyed by site or by site-and-port. Per site is the default here.

## Risks, and what to verify first

1. **The transport is settled; the API is not.** ZeroWork 1.1.76 whitelists the page's exact origin and holds a
   socket.io WebSocket, so the runner must do the same (page facts and helper facts above). The remaining risk is
   whether `URLSessionWebSocketTask` lets Zigzag send that `Origin`; if not, the handshake has to be built rather than
   borrowed. The held-connection case is real either way, so the site runner's WebSocket shim is not optional for this
   helper; a read that waits for the whole body (32 MB / 30 s, and `bridge.js` declines `text/event-stream` and
   ndjson) cannot serve it.
2. **The shim is the page's.** A page-world patch can be seen, replaced or removed. That is inherent — Chrome's own
   extensions have the same property — and it loses no security here, because a hostile page can hide its own use of a
   grant it holds but cannot obtain one. It does mean "nothing about it is silent" holds for Zigzag's accounting, not
   for a hostile page's honesty.
3. **Adding the gate to `ws://` takes something away.** That path is ungated today (fact 3), so an extension that
   happens to rely on it stops working until the switch is turned on. That is the right direction, and it should be
   said in the release notes rather than discovered.
4. **Downie's regression belongs to the owner, not to this work.** Its current extension uses
   `browser.runtime.sendNativeMessage`, so it is a native-messaging gap rather than a loopback one. Keep the two apart
   in the reports, so a regression is not mistaken for a gap this closes — and if what the owner finds turns out to
   be this same runner, this should not land as a second one.
5. **Confirm no macOS local-network prompt appears.** Loopback should not need it; a prompt here would be wrong, and
   would make the wording above matter more, not less.
6. **The master switch is the real consent, and the briefing is part of it.** A per-site switch alone would make the
   feature look like one more site permission; the global setting and its acknowledgement are what make it a
   deliberate choice. The briefing must not undersell a vulnerable helper: "only grant sites you trust" is the load-
   bearing sentence, and the extension door's switch should not be described as if it has the same reach.
