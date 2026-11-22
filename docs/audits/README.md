# Audit: Zigzag vs Chrome (November 2026)

A read-only audit of Zigzag 0.9.2's gaps against Chrome, run with a swarm of
independent workers and two cross-checkers. **Line numbers were re-verified
against 0.9.4** before this was submitted; conclusions that had changed were
updated or dropped.

Nothing here proposes code changes. It is a findings report for the maintainer
to triage — several items are small and mechanical, a few are larger.

## Start here

| File | What it covers |
|---|---|
| **[SUMMARY.md](SUMMARY.md)** | The report. Read this one. |
| [api-analysis.md](api-analysis.md) | All 76 `unsupported` extension APIs, sorted into what can be wired up, what needs building, and what WebKit cannot do |
| [automation-gaps.md](automation-gaps.md) | CDP, command line, AppleScript, enterprise policy, Web Inspector |
| [ecosystem-gaps.md](ecosystem-gaps.md) | Ad blocking, user scripts, proxies: what a real extension runs into |
| [verify-b.md](verify-b.md), [verify-c.md](verify-c.md) | The cross-checks, including where the first pass was wrong |
| [_unsupported.txt](_unsupported.txt) | Raw extract from `compatibility.json`, for re-deriving the counts |

## The three things worth reading first

1. **`chrome.sessions.getRecentlyClosed` returns nothing**, while
   `TabManager.recentlyClosedTabs` already has the data and `HistoryMenu` already
   reads it. `sessions` is `unsupported` overall; only `getRecentlyClosed` is
   emulated. This looks like a short wire-up.
2. **Three `bookmarks` events never fire** (`onImportBegan`, `onImportEnded`,
   `onChildrenReordered`). The JS side registers them; the Swift side never
   emits. Fixing `onChildrenReordered` needs three edits **in order** — the
   guard at `BridgeBookmarks.swift:349` lists only four events, so adding the
   emit without adding it to that guard fails silently.
3. **`pageCapture` is marked `webkitMissing`, but the file it needs exists.**
   `chrome.pageCapture.saveAsMHTML` archives a page as MHTML; Zigzag has
   full-page capture in `PageScreenshot.swift` but it exits as PNG (and the only
   path that returns bytes is `#if DEBUG`). So the capability is closer than
   "WebKit cannot do it" suggests — though an MHTML serializer is still a real
   piece of work.

## What is *not* in here

The audit did not verify, and does not claim anything about:

- Password filling on a real install (the code paths are documented; no
  extension was installed and used).
- The finer gaps in page features (Reader, zoom, print, find, screenshot).
- Search engine management, default-browser checks, update mechanism.

Those are marked "not audited" in SUMMARY.md rather than guessed at.

## Method, and what it caught

Six workers audited different areas; two checked the others. The checks found
real errors in the first pass — a count of `cgColor` call sites that was off by
82%, a claim that `ENABLE_TESTABILITY` was disabled based on a `grep` that did
not include the generated `project.pbxproj`, and a `#if DEBUG`-only environment
variable described as a release feature. Those corrections are kept in the
report rather than quietly removed, because the pattern behind them is worth
knowing: *a grep that looks in the wrong place gives a confident wrong answer,
and every single error in this audit was an undercount, never an overcount.*

Every `file:line` here was checked by hand. There is no automated line-number
checker in `scripts/`; if the source moves, these numbers need re-checking.
