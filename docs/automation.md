# Automating Zigzag

There are two ways to drive Zigzag from outside it:

- **AI apps, over MCP.** An AI app on your Mac that supports the Model Context Protocol can list your tabs, open and
  read pages, and click and type in them. Off until you turn it on.
- **Scripts.** AppleScript, Shortcuts (Run AppleScript) and `osascript` from the command line, with a dictionary
  that follows Safari's and Chrome's.

Both live in Settings › Automation.

## AI apps (MCP)

Zigzag has a small MCP server built in. It listens on this Mac only (127.0.0.1), never on your network, and only while
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

A tool given no tab acts on the tab in front of you. There is no tool that runs an app's own JavaScript in a page.

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
