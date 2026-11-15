# Download rules and scripts

Zigzag can take a download or a link out of the browser and give it to something else: an app on this Mac, a script of
yours, a download manager at the other end of a network. The rules that decide this live in **Settings › Downloads**.

This page is the reference for them — what a rule catches, the question it asks the first time, every token a field can
use, what a script is handed and what it can say back, and where each answer you give is kept. For driving Zigzag from
outside it — AppleScript, Shortcuts, MCP — see [automation.md](automation.md).

## A rule

A rule is a match and an action. When something matches, the rule takes it; when nothing matches, Zigzag carries on as
if no rule existed.

| Part | What it means |
|---|---|
| **Catches** | A download, or a link and a download. A new rule catches downloads only, so adding one never changes how a link opens. |
| **Matches** | Starts with, contains, ends with, a regular expression, a file extension, or any address. Every kind but the extension reads the address; the extension reads the file's own name. |
| **Action** | Open App, Open URL, Run Script, or JSON-RPC / XML-RPC. |
| **Stop the page** | For a rule that takes links: the page it was on goes no further, so it doesn't load or follow the address it was going to. Off by default, for a rule that catches a whole site's clicks. |

Rules run from the top of the list and the **first match wins**; drag one to reorder it. The switch turns a rule off
without deleting it. A new rule can start from a preset — aria2, Motrix, **Torrents**, yt-dlp, mpv, IINA — or from
Custom. Torrents starts on rTorrent, with a pattern that catches `.torrent` addresses and `magnet:` links, and its
**Service** dropdown points the same rule at aria2, Motrix, or a service of your own.

**Private windows are left alone.** A rule doesn't run there unless **Run in private windows** in its sheet is on: no
question, no script, and the link or download carries on as if no rule had matched. A handoff can give another app a
private window's address — and its cookies, when the rule names them — which is why it's off until you say otherwise.
A file type that saves is not a handoff, so a private download still goes to the folder its type says; a file type
that opens obeys the switch, and while it is off the file is saved and not opened.

**File types** are the other kind of rule in the same list: **Save** and **Open**. They never take a download away from
Zigzag: they decide what happens to a file of a given type when WebKit makes the download — saved into the folder the
rule names, which starts as the folder downloads go to and can be changed, or saved and then opened in the Mac's own
app for that type. They're listed under Save downloads to, and they don't ask a question of their own.

## The question about a new file type

The first time a file of a type no rule covers arrives — a PDF, a ZIP, an EPUB — Zigzag asks, in the page's own window,
whether to open it or keep it:

> **Open this PDF?**
> Save · Open

Beside the buttons, one duration says how far the answer reaches:

| Duration | What it covers |
|---|---|
| **This time** | That one file. The next PDF asks again. |
| **Always for PDF** | The type, written as a file type rule you can change or delete. |
| **Always** | Every download no rule covers, whatever its type. A file type's own rule still wins. |

*Always* is kept in **Settings › Downloads** under **New file types**, where it can be set back to *Ask each time*.
A private window never asks: the file is saved, and nothing is opened.

## The question before a rule runs

A rule doesn't run silently the first time. When it would take something from a site, Zigzag asks in the page's own
window, naming the rule and the site:

> **Hand Off YouTube?**
> Don't Allow · Open in Browser · Hand Off

*Don't Allow* cancels the link or leaves the download to Zigzag, *Open in Browser* carries on as if no rule had matched,
and *Hand Off* runs it. The question is about the page that produced the link or download, not the file's own host, so a
download from a CDN asks about the site you clicked on.

Every answer has a duration, chosen from the dropdown beside the buttons:

| Duration | What it lasts on |
|---|---|
| **This time** | The page that asked — its tab, until it loads another page or reloads. |
| **Always on this site** | Every page of that site. |
| **Always for "<rule>"** | The rule itself, for every site. |

A **no** is kept exactly like a yes. *Don't Allow* with *Always on this site* is a standing block for that site, and
*Don't Allow* with *Always for "YouTube"* means the rule doesn't run anywhere until you change it. A private window
keeps nothing and reads no site's answer; the rule's own answer belongs to the rule, so it still stands there once the
rule has been allowed into private windows at all. Until then it doesn't run there.

### Where those answers are kept

In **Settings › Downloads**, under the rule:

- **Every site** — the rule's own answer, with an × to forget it.
- One row per site, grouped by what it answered (*Hand Off*, *Open in Browser*, *Don't Allow*) and each with its own ×.
  One site can be asked again without touching the others.

Deleting a rule forgets its sites too. The same answers appear per site in **Site Controls › Permissions**, where they
can be forgotten there instead.

## Open URL: where a web address opens

An *Open URL* rule opens the web's own addresses inside Zigzag. Anything else — `mpv://`, a magnet, a mail link —
belongs to the app that handles it and is handed straight to that app.

The rule's sheet has an **Open in** menu: *Ask*, *This Tab*, *New Tab*, *Mini*, or *Don't Open*. *Ask* is a rule that
hasn't been told yet: when it fires on a site it asks, with the places in a dropdown and the buttons saying whether to
open at all:

> **Where should this open?**
> [This Tab ▾] · Don't Allow · Allow

The duration is the same three choices. *Always on this site* keeps the place for that site and this rule; *Always for
"<rule>"* keeps it on the rule, for every site. A site's answer is the more specific one and outranks the rule's.
*Don't Allow* is kept too — the rule then doesn't open anything there — and *Don't Open* in the sheet is where that
refusal can be changed back.

## Tokens

Every field in a rule can use tokens. They're filled in when the rule fires, for that link.

| Token | Becomes |
|---|---|
| `{link}` | The address, as it is. |
| `{host}` | Its host. |
| `{path}` | Its path, percent-encoded. |
| `{query}` | Its query, percent-encoded. |
| `{encoded_link}` | The whole address as one query value, so `&`, `+`, `=` and `#` in it stay part of the value. |
| `{referrer}` | The page it came from, or nothing. |
| `{filename}` | A name safe to write in Downloads or an argument: no folder separators, no control characters, no leading dot. |
| `{mime}` | The file's type, when the page said. |
| `{space}` | The Zigzag space the link or download was in. |
| `{cookies}` | The path to a temporary `cookies.txt` holding the site's cookies. |
| `{cookie_header}` | The same cookies as a `Cookie:` header value. |
| `{secret}` | A JSON-RPC rule's own secret, for a service that wants one. |

`{cookies}` and `{cookie_header}` are read from the tab's own session — so a logged-in download keeps its sign-in — but
**only when the rule's fields actually use one of them**. A rule that never names them never reads your cookies.

They are your cookies, so the editor says when a JSON-RPC endpoint isn't on this Mac and the rule would send them there.
It's a warning, not a refusal: a NAS or a build box on your network may be exactly what you mean.

## Scripts

### Where they live

`~/Documents/Zigzag/Scripts` — one folder, in your Documents, so you can see and edit the scripts in Finder. The sheet's
**Choose…** menu lists everything in it, and a rule that names a script by its file name (`yt-dlp.sh`) keeps working if
the folder moves with your home directory. **Choose a Script…** picks one from anywhere else; a full path is kept as a
path.

### How a script runs

- A `.sh` file is run by `/bin/sh`. Anything else must be executable, with its own interpreter line (`#!/usr/bin/env
  python3`).
- Each argument in the rule is one `argv` value, with tokens filled in inside it. Zigzag never builds a shell line and
  never runs `/bin/sh -c`, so `&`, `;` and `$(…)` in a URL stay in the URL.
- The run starts in your home folder. `/opt/homebrew/bin` and `/usr/local/bin` are put at the front of `PATH`, because an
  app opened from the Finder inherits a bare one — so `yt-dlp` installed by Homebrew is found without a full path.

### What a script is handed

Tokens are in its arguments and in its environment:

| Environment variable | Holds |
|---|---|
| `ZIGZAG_LINK` | The address, as `{link}`. |
| `ZIGZAG_REFERRER` | The page it came from, or empty. |
| `ZIGZAG_FILENAME` | `{filename}`. |
| `ZIGZAG_MIME` | `{mime}`. |
| `ZIGZAG_SPACE` | `{space}`. |
| `ZIGZAG_COOKIES` | The `cookies.txt` path, only when a field used `{cookies}`. |
| `ZIGZAG_COOKIE_HEADER` | The `Cookie:` value, only when a field used `{cookie_header}`. |
| `ZIGZAG_SECRET` | The rule's secret, for JSON-RPC only. |

### What it can say back

A script may print whatever it likes. A **line that is one JSON object naming a `kind`** is an answer, and the first
such line decides; everything else — logs, progress, a pretty-printed object — is passed over.

```sh
#!/bin/sh
# Hand the link to the viewer instead of downloading it.
printf '{"kind":"openApp","appPath":"/Applications/mpv.app"}\n'
```

An answer can name the same actions a rule can: `openApp`, `openURL`, `jsonRPC`. It may **not** name another script, or
a save destination: a script that could name another script would be a way to make one script run another. Say either,
and Zigzag tells you why instead of passing it over.

An Open URL answer from a script opens where its own JSON says, and in a new tab if it doesn't — it doesn't ask, because
there's no rule to keep the answer on.

The output is read **as it is written**, not waited for, so a script that says what to do next and then works for ten
minutes still gets its answer at once. An answer named more than a minute into the run is too late to act on; the run
itself is not affected.

While it runs, a card over the page says **Running script: yt-dlp.sh** — with a run that comes and goes in a moment, the
card appears with how it ended instead. When it exits:

- **Ran script: yt-dlp.sh** — it exited 0.
- **Script failed: yt-dlp.sh** — it exited with an error, and the card shows its own last words (usually from stderr).

## Allow Once on a refused download

Two notices can stand where a download was refused:

- The site isn't allowed to save files at all. That's a site permission: **Site Controls › Permissions › Downloads**, or
  the question the first time.
- The page started a download on its own, without a click.

Both notices offer **Allow Once** — in a tab, and in the small pop-up window for a download the page started. It asks
for the file again through the same page — the session the site expects — and keeps that answer for the page, the same
as *This time* on a question. What comes back is tracked like any other download. Only a plain GET can be asked for
again, so a POST leaves the notice as it is rather than fetching something else in its place.

## Every firing is announced

An automation you didn't write has to be detectable. Every time a rule fires, a line over the page says what it did and
names the rule:

- *YouTube: opened this link in a new tab*
- *YouTube: handed this link to mpv*
- *aria2: sent this link to aria2.addUri · 127.0.0.1*

Questions can go quiet once an answer is kept; the notice does not. A script's own card is its notice, and a rule that
was told not to open says nothing, because nothing happened. The same notice twice while it is still up is one notice
with a count, **(×2)**, rather than a stack.

## Where each answer is kept

| Question | This time | Always on this site | Always for the rule |
|---|---|---|---|
| Camera and microphone | page | site | — |
| Location | page | site | — |
| Notifications (and where they show) | page | site | — |
| Pop-ups (and where they open) | page | site | — |
| Open an app | page | site | — |
| Downloads (may this site save files) | page | site | — |
| WebRTC | page | site | — |
| Screen sharing | page | site | — |
| A download rule's handoff | page | site, for that rule | the rule |
| Open URL's place | page | site, for that rule | the rule |

Every one of them is revocable: the per-site answers in **Site Controls › Permissions** and, for the rule questions,
under the rule in Settings › Downloads. Private windows keep none of them.

Screen sharing is the one that doesn't capture anything on its own, whatever is kept: macOS's own picker still asks
which window or display.

## An example

A rule for yt-dlp, end to end:

1. **Settings › Downloads › Add Rule › Custom.**
2. Name it `Videos`, make it catch **Links and downloads**, match **Contains** `youtube.com`.
3. Action **Run Script**, script `yt-dlp.sh` in `~/Documents/Zigzag/Scripts`, one argument: `{link}`.

```sh
#!/bin/sh
# One token per argument. Zigzag never builds a shell line, so the link arrives as one argument, needing no escaping.
exec yt-dlp --no-progress -o "$HOME/Downloads/%(title)s.%(ext)s" "$1"
```

The first time you click a YouTube link, it asks **Hand Off Videos?** Choose *Hand Off* and *Always for "Videos"*, and
from then on every YouTube link goes to the script — announced each time, with the script's own card while it runs.
