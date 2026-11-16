# Download rules

Settings › Downloads can hand a download, or a link you click, to another app or service instead of saving it in
Zigzag. A rule is one match and one action. The rules are tried from the top of the list, and the first one whose match
fits an address takes it. A rule can be switched off without being deleted, and the list can be reordered.

## What a rule matches

A rule applies to downloads only, or to links and downloads. It matches the address by:

- **Starts with**, **Contains** or **Ends with**, with **Match case** off by default.
- **Regular Expression**, for the cases the three plain kinds can't say. A regex that doesn't compile is kept as typed
  but never matches, so a half-written rule can't catch anything.
- **Any address**, the catch-all at the bottom of a list when it is used at all.

With several rules, the first match wins. Whatever no rule matches is saved by Zigzag exactly as before.

The ready-made rules for aria2, Motrix, rTorrent and yt-dlp catch **downloads only**: a file a page sends, or one you
download, is handed to the service. A link you merely click is not, even if it is a magnet or a video page. Make a
rule that applies to links and downloads if you want that, and choose what it sends to.

## What a rule does

- **Open App** opens the link in the app at the path chosen in the rule.
- **Open URL** opens a URL the rule builds, such as `mpv://{encoded_link}`. This is how a scheme another app handles is
  reached.
- **Run Script** runs an executable, with every value as its own argument or environment variable. A `.sh` file is run
  by `/bin/sh`; anything else must be executable. Zigzag never builds a shell line, so `&`, `;`, `$()` and quotes in a
  URL arrive as part of one argument, not as commands.
- **JSON-RPC** or **XML-RPC** sends the link to a service such as aria2, Motrix or rTorrent. The endpoint and method
  are literal, as an app's or script's path is. An optional token is kept in the Keychain, never in the rules file.

The executable path, the script path, the endpoint and the method are **literal**. A page can fill the values a rule
passes along, but it cannot choose what runs or where the values are sent.

## Values and tokens

An Open URL template, a script's arguments and a service's parameters may use:

| Token | Value |
| --- | --- |
| `{link}` | The address the rule caught. |
| `{encoded_link}` | The same, as one query value. |
| `{host}` | The address's host, such as `www.google.com`. |
| `{path}` | Its path, percent-encoded as the address has it. |
| `{query}` | Its query, without the `?`. |
| `{referrer}` | The page that linked to it. |
| `{cookies}` | A `cookies.txt` file written for this one handoff. |
| `{cookie_header}` | A `Cookie:` header, for a service that takes one. |
| `{filename}` | The download's name, or a safe name made from the address. |
| `{mime}` | The file's media type, where there is one. |
| `{space}` | The name of the space the tab is in. |

A script also gets `ZIGZAG_LINK`, `ZIGZAG_REFERRER`, `ZIGZAG_FILENAME`, `ZIGZAG_MIME`, `ZIGZAG_SPACE`,
`ZIGZAG_COOKIES` and `ZIGZAG_COOKIE_HEADER` where they apply. A JSON-RPC or XML-RPC rule may use `{secret}` in its
parameters for the token kept in the Keychain; a script is not given the token.

## Cookies

A rule that names `{cookies}` or `{cookie_header}` gets the tab's cookies from its own profile, never another
profile's. They are read for the target only when the target is the page's own site, or when you clicked the link
that led there. A download a page starts on its own, or one from the context menu, is treated as not clicked, so it
gets no cookies. A page that names another site on its own gets none of this site's cookies, whichever rule it names.
A JSON-RPC or XML-RPC rule also gets them only when its endpoint is on this Mac: a remote service is reached without
the site's sign-in.

The cookie file is made in a private temporary folder, readable by its owner only, and removed once the app or script
has had its moment to read it.

## Before a handoff

A rule asks before it hands anything off: **Hand Off**, **Open in Browser** (or **Save in Zigzag** for a download), or
**Don't Allow**, with a close button for "not now". The answer holds for the page that asked, so a link and the
download it starts ask once. Open in Browser, or Save in Zigzag, leaves the link or download exactly as it would have
been without the rule. Don't Allow refuses it: a link goes nowhere, and a download is not saved.

A question is only asked where it can be seen: in the page in front, in a window that is visible and front. A link or
download in a pop-up, in a background tab, or in a window behind another is handled by Zigzag itself, as if no rule
had matched; the page's earlier answer still holds. The handoff question comes to pop-ups with the permission card
that gives them a place of their own.

## Private windows

A rule stays out of private windows unless **Run in private windows** is turned on in its own sheet. Off, a private
window never asks and never runs the rule; the link or download carries on as if no rule had matched. A private
window's address, and the cookies a rule names, are what that promise protects.
