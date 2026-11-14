# Automating Zigzag

There are two ways to drive Zigzag from outside it:

- **AI apps, over MCP.** An AI app on your Mac that supports the Model Context Protocol can list your tabs, open and
  read pages, and click and type in them. Off until you turn it on.
- **Scripts.** AppleScript, Shortcuts (Run AppleScript) and `osascript` from the command line, with a dictionary
  that follows Safari's and Chrome's.

Both live in Settings › Automation.

## AI apps (MCP)

Zigzag 0.8.5 and later has a small MCP server built in. It listens on this Mac only (127.0.0.1), never on your network, and only while
you have it turned on. Off, nothing listens at all.

### Turning it on

Open Settings › Automation and turn on **Let AI apps use Zigzag**. Two rows appear under it:

- **Server address**: `http://127.0.0.1:39217/mcp`. Copy puts it on the clipboard.
- **Key**: the secret an app sends with every request. Copy Header puts `Authorization: Bearer <key>` on the
  clipboard; Reset Key makes a new one.

The key is made the first time it's needed and kept in a file only your user account can read, in Zigzag's folder in
`~/Library/Application Support`. It's never in the Keychain.

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

### What an app can do

| Tool | What it does |
|---|---|
| `list_tabs` | Lists the open tabs, front window first: id, title, address, whether it's the tab in front, its window and space. |
| `open_tab` | Opens an http or https page in a new tab of the front window, in front or in the background. |
| `activate_tab` | Switches to a tab, and to its space. |
| `close_tab` | Closes a tab. |
| `navigate` | Loads an http or https page in a tab. |
| `go_back` | Goes back a page in a tab. |
| `go_forward` | Goes forward a page in a tab. |
| `reload` | Reloads a tab. |
| `read_page` | Gives the page's title, address and readable text, and its form fields, without password values. |
| `get_links` | Gives the links on the page, their text and address. |
| `screenshot` | Gives a picture of the page as it shows now. The tab has to be on screen. |
| `click` | Clicks an element, found by a CSS selector or by the text it shows. |
| `type` | Types into a field, or picks an option in a menu on the page. |
| `scroll` | Scrolls the page, or a part of it, up or down. |
| `wait_for` | Waits until some text shows or goes, an element shows or goes, or the page finishes loading. |
| `press_key` | Presses a key in the page, like Enter, Escape, Tab or an arrow, with Shift, Alt, Ctrl or Meta if wanted. |

A tool given no tab acts on the tab in front of you. There is no tool that runs an app's own JavaScript in a page.

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
- Read or type **passwords**. `read_page` never gives a password field's value, and `type` refuses password fields,
  so the app has to ask you to type one.
- Use **Zigzag's own pages** (Settings, History) or **extension pages**. They're listed, so the app knows they're
  there, but every tool on them is refused.
- Open anything but a website. Only http and https addresses open; `file:`, `javascript:`, `data:` and Zigzag's own
  addresses are refused.
- Be reached from another computer, or from a web page. Zigzag listens on 127.0.0.1 only, and refuses any request
  that comes from a website.

### The bar over a tab, and Stop

While an app uses a tab, a bar over the page says so: "*App* is using this tab", with the name the app gives, or "An
AI app is using this tab". The bar goes when the app hasn't touched the tab for five minutes, or its connection ends.

**Stop** on the bar takes the tab back at once: the app is disconnected, and that tab stays out of its reach until
Zigzag quits or you turn the setting off. The app can connect again, but not to that tab.

### Resetting the key

Reset Key in Settings › Automation makes a new key. Every app connected with the old one is cut off at once, so
copy the setup again and give the new key to the apps you still want. Turning the setting off also disconnects
every app, and frees every tab you stopped.

### Troubleshooting

- **"Couldn't start. Port 39217 may be in use by another app."** Something else on your Mac has the port. Quit it, or
  give Zigzag another port, then turn the setting off and on again:

  ```sh
  defaults write wang.zigao.zigzag MCPPort -int 39218
  ```

  The address in Settings changes to match; copy the setup again so the app has it.
- **401 Unauthorized.** The app didn't send the key, or sent an old one. Check that the header reads exactly
  `Authorization: Bearer <key>`, and copy it again after a Reset Key.
- **403 Forbidden.** The request came with a web page's `Origin` header, or to an address other than `127.0.0.1`
  or `localhost`. Zigzag answers apps on this Mac only, never pages in a browser. Use the address exactly as Settings
  gives it.
- **The app can't connect at all.** Check that Let AI apps use Zigzag is on and Zigzag is open: the server runs only
  while it is. Check that the app uses the HTTP transport, not stdio or SSE.
- **A tool says the tab was stopped.** You (or someone at your Mac) pressed Stop on that tab. Ask the app to use
  another tab, or turn the setting off and on to free it.
- **`screenshot` fails.** The tab has to be on screen. Ask the app to switch to it with `activate_tab` first.
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
