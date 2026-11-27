# Automating Zigzag

There are two ways to drive Zigzag from outside it:

- **AI apps, over MCP.** An AI app on your Mac that supports the Model Context Protocol can list your tabs, open and
  read pages, and click and type in them. Off until you turn it on.
- **Scripts.** AppleScript, Shortcuts (Run AppleScript) and `osascript` from the command line, with a dictionary
  that follows Safari's and Chrome's.

Both live in Settings › Automation.

## AI apps (MCP)

Zigzag has a small MCP server built in. It listens on this Mac only (127.0.0.1), never on your network, and only
while you have it turned on. Off, nothing listens at all.

### Turning it on

Open Settings › Automation and turn on **Let AI apps use Zigzag**. Two rows appear under it:

- **Server address**: `http://127.0.0.1:39217/mcp`. Copy puts it on the clipboard.
- **Key**: the secret an app sends with every request. Copy Header puts `Authorization: Bearer <key>` on the
  clipboard; Reset Key makes a new one.

The key is made the first time it's needed and kept in a file only your user account can read, in Zigzag's folder in
`~/Library/Application Support`. It's never in the Keychain. Zigzag only takes a key it made itself from that file:
anything else written there is replaced with a new one. Whatever Settings copies with the key in it is marked as
concealed on the clipboard, so clipboard managers and history apps leave it out.

### Connecting an app

Zigzag speaks MCP's Streamable HTTP transport. An app needs three things:

| | |
|---|---|
| Transport | HTTP (Streamable HTTP) |
| URL | `http://127.0.0.1:39217/mcp` |
| Header | `Authorization: Bearer <key>` |

Under **Connect an App**, **Copy Setup** copies all three in the JSON form most MCP apps take, with your key filled in:

```json
{
  "mcpServers" : {
    "zigzag" : {
      "headers" : {
        "Authorization" : "Bearer <key>"
      },
      "type" : "http",
      "url" : "http://127.0.0.1:39217/mcp"
    }
  }
}
```

Paste it where the app adds MCP servers: usually a settings screen for MCP or "connectors", or a JSON settings file.
If the app's file already has an `mcpServers` list, add the `zigzag` entry to it rather than replacing the list. Some
apps call the transport `streamable-http` or `streamableHttp` instead of `http`; use the name the app's own
documentation gives.

**Copy Prompt** copies a short message instead, for an app that can set itself up from its chat: it says where Zigzag
is, which header to send, and what the app may do. Paste it into the app's chat and follow what the app asks.

Either one holds your key. Treat it as you would a password: paste it only into apps you trust, on this Mac.

### Sessions and connections

An app starts with MCP's `initialize`, and Zigzag answers with a session id in the `Mcp-Session-Id` header. Every
request after that has to send it back, as the transport says; one without it gets 400, and one with a session that
has ended (after Reset Key, say) gets 404 and starts over with `initialize`. MCP apps do this on their own.
Zigzag takes the protocol versions from 2025-03-26 to 2025-11-25 this way. An app on version 2026-07-28 skips
`initialize` and sessions, and sends the version, method and tool name in its headers with every request instead.

A tool that takes longer than 60 seconds is given up, and the app gets an error saying so.

A request without the right key, from a web page or to the wrong path is answered and its connection closed. Zigzag
keeps at most 64 connections open, and only a few of them may be ones that haven't sent the key yet, so connections
that never send it can't crowd out the apps that do.

### What an app can do

| Tool | What it does |
|---|---|
| `list_tabs` | Lists the open tabs, front window first: id, title, address, whether it's the tab in front, its window and space. Private windows are never listed. |
| `open_tab` | Opens an http or https page in a new tab of the front window, in front or in the background. |
| `activate_tab` | Switches to a tab, and to its space. |
| `close_tab` | Closes a tab. |
| `navigate` | Loads an http or https page in a tab. |
| `go_back` | Goes back a page in a tab. |
| `go_forward` | Goes forward a page in a tab. |
| `reload` | Reloads a tab. |
| `read_page` | Gives the page's title, address and readable text, and its form fields, without the values of password, hidden, card number, card code and one-time code fields. |
| `get_links` | Gives the links on the page, their text and address. |
| `snapshot` | Gives the page as a screen reader has it, with a ref for each thing the app can use. See [Snapshots and refs](#snapshots-and-refs). |
| `screenshot` | Gives a picture of the page as it shows now. The tab has to be on screen. |
| `click` | Clicks an element, found by its ref, a CSS selector or the text it shows. |
| `type` | Types into a field, found by its ref or a CSS selector, or picks an option in a menu on the page. |
| `scroll` | Scrolls the page, or a part of it (by ref or CSS selector), up or down. |
| `wait_for` | Waits until some text shows or goes, an element shows or goes, or the page finishes loading. |
| `press_key` | Presses a key in the page, like Enter, Escape, Tab or an arrow, with Shift, Alt, Ctrl or Meta if wanted, in the element with the focus or one found by ref or CSS selector. |

A tool given no tab acts on the tab in front of you. There is no tool that runs an app's own JavaScript in a page.

| Tool | Arguments |
|---|---|
| `list_tabs` | none |
| `open_tab` | `url` (required), `background` (default false) |
| `activate_tab` | `id` (required) |
| `close_tab` | `id` (required) |
| `navigate` | `url` (required), `id` |
| `go_back`, `go_forward`, `reload` | `id` |
| `read_page` | `id`, `max_chars` (500 to 100,000, default 20,000) |
| `get_links` | `id`, `max` (1 to 1,000, default 200) |
| `snapshot` | `id`, `filter` (`all` or `interactive`), `depth`, `ref` (only that part of the page), `max_chars` (500 to 100,000, default 20,000) |
| `screenshot` | `id` |
| `click` | `id`, and one of `ref`, `selector` or `text` |
| `type` | `text` (required) and one of `ref` or `selector`, `id`, `clear` (default true), `submit` (default false) |
| `scroll` | `dy` (required: points, positive down, negative up), `id`, and `ref` or `selector` for a part of the page |
| `wait_for` | one of `text`, `text_gone`, `selector`, `selector_gone` or `load`, and `id`, `timeout_ms` |
| `press_key` | `key` (required), `id`, `modifiers`, and `ref` or `selector` |

`id` is a tab's id from `list_tabs`; leave it out for the tab in front. A tool given an argument it doesn't take says
which ones it takes. Addresses can be written without `https://`, like `example.com`; only http and https pages open.

### What pages write

Titles, addresses, page text, links and fields are written by whoever made the site, and a page can word them as
orders to the model. So every tool result that carries them comes with a line saying the content is the sites',
untrusted and never to be taken as instructions, and the content itself goes between two `page-content-…` lines
whose tag is random each time, so a page can't close the block early. Zigzag's own words in a result, like an error,
aren't marked.

### Snapshots and refs

`snapshot` gives an app the page the way a screen reader reads it: its landmarks, headings and text, and each thing
it can use (a link, a button, a field, a menu) with a short ref like `e12`. The app then clicks `e12`, rather than
guessing a CSS selector from the page's text:

```
Page "Sign in" at "https://example.com/login"

- heading "Welcome back" [level=1]
- textbox "Email" [ref=e3]: "me@example.com"
- textbox "Password" [ref=e4] [password]
- checkbox "Remember me" [checked] [ref=e5]
- button "Sign in" [ref=e6]
- link "Help" [ref=e2]:
  - /url: "/help"
```

`click`, `type`, `scroll` and `press_key` take a ref in place of a selector. A ref stands for one element as it was
when the app got it. If the page changes it (a button that said Buy now says Pay), takes it away, or loads again,
the ref is refused and the app is told to take a new snapshot; it is never matched to something else that looks
alike, and a new page never reuses an old ref's number. A ref works only on the tab it came from: used on another
tab, it's refused, even when two tabs were read at the same moment. `[new]` marks what appeared since the app's last snapshot of
the page, like a menu a click opened.

`filter: "interactive"` gives only the things that can be used, one per line; `depth` and `ref` give part of the
page; `max_chars` keeps it short, cutting from the middle so the end of the page (where a dialog's buttons usually
are) stays. While a dialog is open, only the dialog is listed, as the rest of the page can't be used.

A snapshot only has what shows on the page. Text a page hides from people (off the screen, a pixel high, see-through,
shrunk or clipped to nothing, inside a closed "more details", hidden from screen readers) is left out, so a page
can't slip instructions to an app that you'd never see. It's a filter for the ways pages are known to hide text,
not a guarantee: text the color of its background, or under a picture, still gets through. Names are
what you see: a button that shows Save but tells screen readers something else is listed as Save, marked
`[label differs]`. One that shows only a sign (×, +) goes by what it tells screen readers. A link to another site says `[other site]`, and a word mixing alphabets (a Cyrillic а in
Wаlmart) says `[mixed scripts]`. Everything the page wrote is in quotes, so it can't pass for Zigzag's own words.
A run of text longer than 1,000 characters is cut there and marked `[shortened]`; `read_page` has all of it. The
answer's `truncated` is about the snapshot as a whole: true when it was cut to fit `max_chars`, or the page was
too large to read in full.

Snapshots read the page itself, not frames inside it, which are listed with their site. Clicks come from Zigzag,
not your hand, so what a page only allows on a real click (a pop-up window, the clipboard, choosing a file) may not
happen. A click is refused when something covers the element (a cookie banner, for example), when it's disabled, or
when a dialog is in the way. `type` and `press_key` are refused the same way for an element that's disabled or
behind a dialog, and for one that can't take the keyboard focus (a field the page hides), with a ref or a selector.
`type` takes a field: for a rich-text editor that's the editor itself, not a paragraph inside it (clearing "the
paragraph" would empty the whole editor). To put text at one place in it, click there and use `press_key`.

### Waiting for a page

A page that fills itself in after it loads (search results, a list that comes from the server, a message after
you save) isn't done when `navigate` or `click` answers. `wait_for` waits for one thing:

| Argument | Waits until |
|---|---|
| `text` | The text shows on the page. Case and spacing don't matter. |
| `text_gone` | The text is no longer on the page. |
| `selector` | An element matching the CSS selector is there and visible. |
| `selector_gone` | No visible element matches the selector. |
| `load: true` | The page has finished loading. |

`timeout_ms` is how long to wait: 5000 (five seconds) unless the app says otherwise, and never more than 30000.
The page itself watches for the change, so waiting costs nothing while nothing happens. The answer says what
matched and how long it took, or, when the time runs out, what it was waiting for.

A wait ends early, with an error, when the tab closes, goes to sleep or loads another page (a page that only
changes its address as you use it, like many web apps, doesn't count), and when you press Stop or turn the
setting off.

### Pressing keys

`press_key` presses one key: Enter, Escape, Tab, Backspace, Delete, ArrowUp, ArrowDown, ArrowLeft, ArrowRight,
Home, End, PageUp, PageDown, Space, or a single character. Modifiers come in `modifiers` (`shift`, `alt`, `ctrl`,
`meta`) or in the key, like `Shift+Tab` or `Meta+a`. With a `selector`, that element gets the focus first, as
`type` finds a field; without one, the key goes to whatever has the focus.

Zigzag presses the key as your keyboard would, so the page can't tell it apart from you: Enter submits a form, Tab
moves to the next field, arrows move the caret or the selection, and Escape closes what the page closes with it.
This works in a tab that isn't showing and in a window behind others, without bringing anything forward.

Keys only ever reach the page. A key the page doesn't use stops there, so Meta (⌘) and Ctrl combinations never
run Zigzag's own shortcuts: ⌘W doesn't close the tab, ⌘Q doesn't quit, and ⌘V doesn't paste what's on your
clipboard. `press_key` won't type a character, Space, Backspace or Delete into a password field, or into a frame
inside the page where Zigzag can't see whether the field is one. To put text in a field, `type` is quicker; with an
input method on (Pinyin, for example), a character key may go to the input method rather than straight into the
field.

### What an app can never do

- See or use **private windows**. They aren't listed, and nothing reaches them.
- Read or type **passwords**. `read_page` and `snapshot` never give a password field's value, not even after a
  site's Show password turns it into plain text, and `type` and `press_key` refuse password fields, so the app has to ask
  you to type one.
- Read **card details, one-time codes and the like**: a card's number, expiry or security code, a one-time code, an
  IBAN, a PIN, by the field's type, name or label, or a card number in any field. The same fields Zigzag never
  keeps for a sleeping tab. The rule errs on the careful side (a field named `passenger_name` has "pass" in it), so
  an app is still given back what it typed into such a field itself, for as long as the field holds exactly that.
- Read **what your saved details filled in**. A name, email, phone number or address that came from your saved data
  is given only as filled, and how long it is, unless the app typed all of it itself (adding to what's there doesn't
  count).
- See **text a page hides** from you, in `snapshot` and in the names tools give back.
- Reach **your windows and tabs while they run in the background**: only their own window, on the AI Apps profile.
- Use **Zigzag's own pages** (Settings, History) or **extension pages**. They're listed, so the app knows they're
  there, but every tool on them is refused.
- Use Zigzag's **error or certificate warning page**. Only you can choose Visit anyway; the app has to go back or
  open another page.
- Open anything but a website. Only http and https addresses open; `file:`, `javascript:`, `data:` and Zigzag's own
  addresses are refused.
- Be reached from another computer, or from a web page. Zigzag listens on 127.0.0.1 only, and refuses any request
  that comes from a website.

### The bar over a tab, and Stop

While an app uses a tab, a bar over the page says so: "*App* is using this tab", with the name the app gives, or "An
AI app is using this tab". `list_tabs` puts it over the tab in front too. The bar goes when the app hasn't touched
the tab for five minutes, or its connection ends.

**Stop** on the bar cuts off every AI app at once, not only the one on that tab: every session ends, the key is
replaced, and Let AI apps use Zigzag turns off, so nothing listens. A toast says where to turn it back on. When you
do, copy the setup again and give your apps the new key; the old one opens nothing.

### Running in the background

AI apps can work with nothing on screen, in a window of their own that no one sees, on a profile of their own. Your
windows and tabs are then out of their reach: they can't list, read or use them.

Turn on **Run AI apps in the background** in Settings › Automation, under Let AI apps use Zigzag. It's off until
you turn it on, and it needs AI apps allowed too.

With both on, you can also open Zigzag with **`--headless`**. With Zigzag closed, it opens with no Dock icon, no
menu bar and no window, and your saved windows wait until you open Zigzag yourself:

```sh
open -g -a Zigzag --args --headless
```

With either switch off, `--headless` does nothing: Zigzag says why on standard error (shown when you run
`Zigzag.app/Contents/MacOS/Zigzag --headless` itself) and in the system log, and exits with an error.

While AI apps work in the background:

- **Their window is on the AI Apps profile**, which Zigzag makes the first time it's needed, with a space of its
  own. It's listed in Settings › Profiles, but its name can't be changed, and its space stays out of your windows:
  it's not among your spaces in the sidebar, the command bar, Settings › Spaces or a space's Profile menu. Its
  sign-ins, history and extensions are its own: an app is signed in to nothing of yours there.
- **Nothing of yours is given to its pages**: no sign-in or certificate from your Keychain, no password saved or
  filled and no form filled from your card, no passkeys, none of the answers you gave sites (camera, microphone,
  location, notifications and screen sharing are asked again, and with no one there, refused), none of your
  download and link rules, none of your site routes, and no reaching apps on this Mac (Settings › Privacy › Apps on
  This Mac doesn't apply there). Its tabs never go to your Archive. Extensions you install in it yourself are its
  own.
- **An item in the menu bar** shows while their window is open or Zigzag runs for them alone, with **Show AI Apps
  Window** (to watch them), **Stop AI Apps** (the same as Stop on a tab's bar: every app is cut off and the key
  replaced), and, when Zigzag runs for them alone, **Quit Zigzag**.
- **Show AI Apps Window**, in the Window menu and the command bar too, brings their window on screen. They go on
  where they were, with the same refs, and the bar with Stop shows over the tab in use. Closing it hides it again
  while they work. It's a window to watch them in: it shows only the AI Apps profile's spaces, and can't be
  minimized or made full screen.
- **Pages there run as if seen, and silent.** They keep running and drawing, `screenshot` works without
  `activate_tab`, and their tabs start muted (unmute one in Show AI Apps Window to hear it). A
  page whose process ended loads again the next time an app uses it. A tab an app is using stays awake, and
  macOS is kept from slowing Zigzag down meanwhile; a few minutes after its last tool, a tab sleeps like any other
  (the one in front there too, as no one is looking at it) and wakes when an app comes back to it.
- **No one is there to answer a page.** What a page asks of a person is answered no at once, so an app never waits
  on it: `alert`, `confirm` and `prompt` are dismissed, a file picker and a sign-in sheet cancelled, a site asking
  for a certificate goes on without one, printing skipped, camera, microphone, location and screen sharing denied,
  a link to another app (`mailto:`, a meeting app) not opened. A pop-up window opens as a tab, where the app can
  find it. The app's next answer about that tab, whichever tool it is, lists what was dismissed and on which page,
  as `dialogs`.
- **Nothing of theirs reaches your screen or clipboard.** A page's full screen only ever fills its page, never
  the screen, and a page can't copy to your clipboard (an app's clicks and keys count as someone being there, so
  this is refused outright). You can still copy from their window yourself while you watch.
- **Their downloads are their own.** A download goes, without asking where, into a Downloads folder in the AI Apps
  profile's data (in Zigzag's folder in `~/Library/Application Support`, under `Profiles`), never into yours, and
  stays out of your downloads list and the Dock. Deleting the profile deletes them.

You can delete the AI Apps profile in Settings › Profiles once AI apps have stopped running in the background (it's
refused while their window is open). Its space, routes to it and its downloads go with it, and Zigzag makes a new
one, empty, the next time AI apps run in the background.

Opened with `--headless` and nothing else, Zigzag quits on its own 30 minutes after an app last asked it anything
(never while a download is still coming in), and as soon as either switch is turned off. Opening it with
`--headless` again counts as asking, too. Open it yourself meanwhile (from the Dock, Finder or a link) and it's the Zigzag
you know, your windows with it; AI apps stay in their window until it quits. macOS only runs it while you're logged
in.

### Resetting the key

Reset Key in Settings › Automation makes a new key. Every app connected with the old one is cut off at once, so
copy the setup again and give the new key to the apps you still want. Turning the setting off also disconnects
every app.

### Troubleshooting

- **"Couldn't start. Port 39217 may be in use by another app."** Something else on your Mac has the port. An app
  that connects there would hand that program its key, so when the key may already be with your apps, Zigzag
  replaces it and Settings says "Port 39217 is in use by another app, so Zigzag made a new key. Give your AI apps
  the new key." A key that was never copied out of Settings stays as it is. Quit what holds the port, or give
  Zigzag another port, then turn the setting off and on again:

  ```sh
  defaults write wang.zigao.zigzag MCPPort -int 39218
  ```

  The address in Settings changes to match; copy the setup again so the app has it.
- **401 Unauthorized.** The app didn't send the key, or sent an old one. Check that the header reads exactly
  `Authorization: Bearer <key>`, and copy it again after a Reset Key.
- **403 Forbidden.** The request came with a web page's `Origin` header, or to an address other than `127.0.0.1`
  or `localhost`. Zigzag answers apps on this Mac only, never pages in a browser. Use the address exactly as Settings
  gives it. Right after Stop, every request gets 403 too, until the setting is turned on again.
- **400 Mcp-Session-Id is required, or 404 Session not found.** The app sent a request without the session
  `initialize` gave it, or with one that has ended. It has to initialize again; most apps do when they reconnect.
- **The app can't connect at all.** Check that Let AI apps use Zigzag is on and Zigzag is open: the server runs only
  while it is. Check that the app uses the HTTP transport, not stdio or SSE.
- **`screenshot` fails.** The tab has to be on screen. Ask the app to switch to it with `activate_tab` first.
- **A tool says AI apps work in the background and the tab isn't theirs.** Run AI apps in the background is on: they
  can use only their own window's tabs. Ask the app to use `list_tabs` and `open_tab`, or turn the setting off to
  give them your windows again.
- **A page's dialog never shows, or a click "did nothing".** In the background no one can answer a page, so its
  `confirm` was dismissed, which a page takes as Cancel. The tool's answer says so under `dialogs`. For a step
  that needs a yes, turn Run AI apps in the background off and let the app use a window you can see.
- **A tool says a ref changed or isn't on the page.** The page changed since the app's snapshot, or loaded again.
  The app should take a new snapshot and use the refs in it.
- **A click says something covers the element.** A banner or a dialog is on top of it, as it would be for you. The
  app should close it first (its button is in the snapshot), or scroll the element out from under it.
- **`wait_for` times out.** What it waited for never happened in time: the text may be spelled differently on the
  page, or the element may be there but hidden. Ask the app to read the page with `read_page`, or to wait longer
  with `timeout_ms`.

## Scripts

Zigzag can be scripted with AppleScript, from Shortcuts (Run AppleScript), and from the command line with `osascript`.
The dictionary follows Safari's and Chrome's, so most scripts written for them work with `tell application "Zigzag"`.
Open Script Editor › File › Open Dictionary › Zigzag to see all of it.

The first time a script or app talks to Zigzag, macOS asks whether to allow it. You can change your answer later in
System Settings › Privacy & Security › Automation.

### What a script sees

A `window` is a browser window. Private windows and Zigzag Mini are never listed, so a script can't see or touch them.

A window's `tabs` are all of its tabs, in every space, in the sidebar's order: the favorites that are open, then for each
space its open pinned tabs and its tabs. A window also has a `current tab` (Chrome's `active tab` works too) and the
name of the `space` it shows.

Each `tab` has a `URL`, a `name` (or `title`), an `id` that stays the same until Zigzag quits, an `index`, `loading`,
`pinned`, `favorite`, the `space` it belongs to, and the page's `text` and `source`. Reading the text of a tab Zigzag
put to sleep wakes it and waits for its page to load.

The commands are `make`, `close` (or `delete`), `reload`, `go back`, `go forward`, `do JavaScript` and Chrome's
`execute`, along with the standard `count`, `exists` and `quit`. Setting a tab's `URL` takes it there, and setting a
window's `current tab` switches to that tab and its space.

Only web addresses (http and https) can be opened from a script. Files open with the standard `open` command.

### List your tabs

```applescript
tell application "Zigzag"
	repeat with t in tabs of window 1
		log (name of t) & " — " & (URL of t)
	end repeat
end tell
```

From a shell:

```sh
osascript -e 'tell application "Zigzag" to get {name, URL} of tabs of window 1'
```

### Open a page

```applescript
tell application "Zigzag"
	open location "https://example.com"
	-- or, in a window of your choosing, keeping hold of the new tab:
	set t to make new tab at end of tabs of window 1 with properties {URL:"https://example.com"}
	set current tab of window 1 to t
end tell
```

### Read a page

```applescript
tell application "Zigzag"
	set t to current tab of window 1
	repeat while loading of t
		delay 0.2
	end repeat
	return text of t
end tell
```

`source` gives the page's HTML as it is now, after its scripts have run.

### Run JavaScript

Running JavaScript from a script is off until you turn on Settings › Automation › Allow JavaScript from Apple Events.
A script that can run JavaScript can read and change anything on your pages, including sites you're signed in to, so
only turn it on when you need it. Until then, `do JavaScript` stops with error -1743, which says where the setting is.
It never runs in private windows, or in Zigzag's own pages such as Settings and History.

```applescript
tell application "Zigzag"
	do JavaScript "document.title" in current tab of window 1
	-- Chrome's form does the same:
	execute active tab of window 1 javascript "location.href"
end tell
```

The JavaScript runs in the page, as Safari does it, and the value of its last line comes back as text. Lists and
objects come back as JSON, and `undefined` and `null` as `missing value`. To wait for a promise, use `await` and
`return` at the top:

```applescript
tell application "Zigzag"
	do JavaScript "const r = await fetch('/api/me'); return (await r.json()).name" in current tab of window 1
end tell
```

### From an agent's shell

An agent that can run shell commands but doesn't speak MCP can drive Zigzag with `osascript -e`, with nothing to
install:

```sh
osascript -e 'tell application "Zigzag" to get URL of current tab of window 1'
osascript -e 'tell application "Zigzag" to get text of current tab of window 1'
osascript -e 'tell application "Zigzag" to do JavaScript "document.querySelector(\"h1\").textContent" in current tab of window 1'
```

macOS asks once whether the agent's app (Terminal, your editor, or the agent itself) may control Zigzag. For an app
that speaks MCP, [AI apps (MCP)](#ai-apps-mcp) is the simpler way: no permission prompt, no JavaScript of its own in your
pages, and no passwords.
