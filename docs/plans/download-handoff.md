# Handing downloads to other apps

Goal: a download, or a link, can be handed to an app, a script, a URL scheme, or a JSON-RPC service by rules the person writes. Rules run top to bottom, first match wins, and the WebKit download stays the fallback. Branch `docs/download-handoff`; the work lands in small pull requests.

## What it's for

- Hand a file to aria2, Motrix, rTorrent, or yt-dlp with the tab's cookies and referrer.
- Send a YouTube or media link to mpv or IINA before the page loads.
- Send a link to a local tool, a custom web app, or a URL scheme.
- Keep the system download for everything else, including a private window.

## What exists today

- `DownloadManager` takes every `WKDownload`, saves it to Downloads or the folder in Settings (`DownloadPlace`), and lists it in the downloads panel. Private windows keep their own list.
- `Tab` and `PopupWindowController` decide navigation. `shouldPerformDownload` becomes `.download`; a response with `Content-Disposition: attachment`, or a MIME type WebKit can't show, becomes `.download`; `didBecome download` hands the `WKDownload` to `DownloadManager`.
- `DownloadManager.download(_:decideDestinationUsing:suggestedFilename:)` picks the file.
- Cookies live in the page's `WKWebsiteDataStore` and its `httpCookieStore`. A profile has its own store; a private window has a non-persistent one.
- Settings › General has "Save downloads to". There are no rules.
- `JSONStore` and `Paths` keep small state in Application Support. The password store shows the Keychain pattern for a secret.

## Approach

### Rules

`DownloadRule` holds an id, a name, whether it's on, what it applies to (links and downloads, or downloads only), a match (starts with, contains, ends with, regex, any), a pattern, whether the match is case-sensitive, and an action.

- An ordered list, `DownloadRules`, evaluated top to bottom. A disabled rule is skipped; the first match wins; an `any` rule at the bottom is the catch-all. A new rule applies to downloads only.
- Drag to reorder. A pattern beginning with `*` is not special: use `any` or a regex.
- A regex is checked with `NSRegularExpression` when the rule is saved. A rule that doesn't compile never matches.
- Rules are kept in `DownloadRules.json` through `JSONStore`. They are the same for every profile. The tokens and cookies a rule gets come from the tab that triggered it.
- No match leaves the current WebKit download path unchanged.

### Tokens

- `{link}`: the URL as it is.
- `{encoded_link}`: the URL percent-encoded as one query value.
- `{referrer}`: the `Referer` request header, else the page's URL.
- `{cookies}`: a path to a Netscape cookies.txt file for this handoff.
- `{cookie_header}`: the same cookies as a `name=value; ...` header.
- `{filename}`: the suggested filename, the `Content-Disposition` name, or the last URL component, cleaned of path separators and control characters.
- `{mime}`: the response MIME type, or empty for a link.
- `{space}`: the name of the space the tab is in.

The cookies are read from the tab's own store with `getAllCookies`, then filtered by the target URL's host, path, secure flag, and expiry. `{cookies}` and `{cookie_header}` are resolved only for a rule whose action uses them. The file is deleted when a script exits, and after an RPC response.

### Actions

- **Open App**: an app chosen from a picker. The URL goes to `NSWorkspace.open(_:withApplicationAt:configuration:)`.
- **Open URL**: a URL template, for `mpv://`, `iina://`, `obsidian://`, and custom web-app schemes. `{encoded_link}` is the token for a query value.
- **Run Script**: an executable and a list of argument templates. Tokens are substituted into each argument, never into a shell string. A `.sh` file runs as `/bin/sh <path> <args>`. The same values are available as `ZIGZAG_LINK`, `ZIGZAG_REFERRER`, `ZIGZAG_COOKIES`, `ZIGZAG_FILENAME`, and `ZIGZAG_SPACE`.
- **JSON-RPC**: an endpoint, a method, and a parameters template. The body is built with `JSONSerialization`. The method's secret lives in the Keychain, not in the rule file. Presets fill the fields for aria2, Motrix, rTorrent, and yt-dlp.
- Presets: Send to aria2 (`127.0.0.1:6800`), Send to Motrix (`127.0.0.1:16800`), Send to yt-dlp, Send to rTorrent, and Play in mpv or IINA. A preset adds a rule; its endpoint and secret are edited in the same sheet.

For aria2, the preset uses `aria2.addUri` with the URL as the first argument, `token:<secret>` when set, and options `header` (`Cookie: {cookie_header}`, `Referer: {referrer}`), `out` (`{filename}`), and `dir`. The rTorrent preset uses its XML-RPC endpoint and `load.start`.

### Interception

A `HandoffRouter` takes a URL, a `Tab`, the request, the MIME type, the disposition, and the suggested filename. It returns a match and the expanded action, or no match.

- **Link clicks**: in `Tab.decidePolicyFor navigationAction`, after the user-initiated check, match a rule that applies to links when the navigation is a click (`.linkActivated`) or a download (`shouldPerformDownload`). On a match, return `.cancel` and run the action. Redirects, reloads, back and forward, Zigzag's own pages, and extension pages are not matched.
- **New windows**: `Tab` checks the same router before `createWebViewWith` creates a popup. A match returns `nil`, so no blank window is made. `PopupWindowController` uses the same router for its own navigations.
- **Attachments**: in `Tab.decidePolicyFor navigationResponse`, when the response is an attachment or a MIME type WebKit can't show and the frame may save, match a rule that applies to downloads. On a match, return `.cancel` and run the action; otherwise return `.download` as today.
- **Context-menu downloads**: in `DownloadManager.download(_:decideDestinationUsing:suggestedFilename:)`, match a rule before returning the destination. A match cancels that `WKDownload` and runs the action. A per-navigation marker stops a download that was already handed off at the policy stage from being handed off twice.
- A tab opened only for a link that was handed off closes, as `closeIfOnlyADownload` does for a download today.
- Cookie lookups are async. The router matches first, then resolves tokens only when the chosen action needs them.

### UI

Settings gains a Downloads pane: the existing save location at the top, then the rules.

- The list shows a switch, name, match summary, action summary, and a drag handle. The row menu duplicates or deletes a rule.
- Add Rule opens a sheet with the name, what it applies to, the match kind and pattern, the action, its target or fields, a token menu, and a preview of the expanded action. A Test field takes a URL and shows the first matching rule and its expanded action, with secrets redacted.
- The list uses the app's own `FormRow`, `FormSheet`, `DropdownButton`, and `IconButton`.

### Tests

- Matching: each match kind, case sensitivity, an invalid regex, disabled rules, first match wins, and the catch-all.
- Tokens: `{link}`, `{encoded_link}`, `{filename}`, `{referrer}`, `{space}`, and a filename with spaces and slashes.
- Cookies: a file in Netscape form, an HTTP-only cookie, a cookie outside the target path, and a secure cookie.
- JSON-RPC: the aria2 body with a secret, cookies, referrer, filename, and directory.
- Scripts: arguments arrive as separate argv values, including a URL with `&`, `;`, `$()`, and a quote.

## Steps

1. **Model and matcher.** `DownloadRule`, `DownloadRules`, `DownloadRules.json`, and the pure matcher with tests.
2. **Tokens and cookies.** Token expansion, the Netscape file, `{cookie_header}`, and the cookie lookup with tests.
3. **Router.** `HandoffRouter` and the `Tab` and `PopupWindowController` hooks for link clicks, new windows, and attachments, with the blank-tab cleanup.
4. **Download fallback.** The `DownloadManager` hook for context-menu downloads and the double-handoff marker.
5. **Actions.** Open App, Open URL, Run Script, and JSON-RPC, with the aria2, Motrix, rTorrent, yt-dlp, mpv, and IINA presets.
6. **Settings › Downloads.** The rules list, the editor, reordering, the token menu, and the Test field.
7. **By hand.** YouTube to mpv, a magnet to rTorrent, a logged-in PDF to aria2 with cookies, a direct file to the system, a private window, a popup link, a regex rule, and a first-match order with two overlapping rules.
8. **Release.** A CHANGELOG entry and a note in the Settings pane's help text.

## Must be proven first

- That cancelling in `decidePolicyFor navigationResponse` before `.download` leaves no tab, no download row, and no second request.
- That `getAllCookies` returns in time for a policy decision and produces a cookies.txt that yt-dlp and aria2 accept for a logged-in file.
- That cancelling a `WKDownload` in `decideDestinationUsing` removes its row cleanly and hands off a context-menu download.
- That the aria2 `addUri` call with `Cookie` and `Referer` headers downloads a signed-in file.
- That a custom scheme from a link click opens mpv or IINA with the URL intact.

## Rules while doing it

- No `/bin/sh -c`, no string interpolation into a shell. Tokens are argv or environment values.
- Secrets in the Keychain; cookie files written with mode 0600 and deleted when a script exits or an RPC response comes back.
- No cookies, secrets, or expanded scripts in Diagnostics.
- Match only clicks, new-window links, and attachment responses. No redirects, reloads, back and forward, or Zigzag's own pages.
- One pull request per step, with tests for the matcher, tokens, cookies, and RPC body.
