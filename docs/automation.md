# Automating Zigzag

Zigzag can be scripted with AppleScript, from Shortcuts (Run AppleScript), and from the command line with `osascript`.
The dictionary follows Safari's and Chrome's, so most scripts written for them work with `tell application "Zigzag"`.
Open Script Editor › File › Open Dictionary › Zigzag to see all of it.

The first time a script or app talks to Zigzag, macOS asks whether to allow it. You can change your answer later in
System Settings › Privacy & Security › Automation.

## What a script sees

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

## List your tabs

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

## Open a page

```applescript
tell application "Zigzag"
	open location "https://example.com"
	-- or, in a window of your choosing, keeping hold of the new tab:
	set t to make new tab at end of tabs of window 1 with properties {URL:"https://example.com"}
	set current tab of window 1 to t
end tell
```

## Read a page

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

## Run JavaScript

Running JavaScript from a script is off until you turn on Settings › General › Automation › Allow JavaScript from Apple Events.
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

## From agents and MCP tools

Zigzag uses WebKit, so it has no Chrome DevTools Protocol. An agent that can run a shell command can drive it with
`osascript -e` instead, with nothing to install:

```sh
osascript -e 'tell application "Zigzag" to get URL of current tab of window 1'
osascript -e 'tell application "Zigzag" to get text of current tab of window 1'
osascript -e 'tell application "Zigzag" to do JavaScript "document.querySelector(\"h1\").textContent" in current tab of window 1'
```

macOS asks once whether the agent's app (Terminal, your editor, or the agent itself) may control Zigzag.
