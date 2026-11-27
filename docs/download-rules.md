# Download rules

Settings › Downloads decides where a file goes after Save downloads to. It has two lists:

- **File Types** send files of a type to a folder of their own, or open them in your Mac's app once they're saved.
- **Hand Off Downloads and Links** hand a download, or a link you click, to another app or service instead of saving
  it in Zigzag.

Both are one list underneath, tried from the top, and the first entry that fits takes the file. File types always
come first: Settings shows them above the handoff rules, and a new file type goes after the other file types and
before the first handoff rule, so a catch-all handoff below can't take a file a type has already claimed. Each entry
can be switched off without being deleted, and moved up or down. Whatever nothing matches is saved where downloads
go, as before.

**Test a Rule**, at the bottom, takes a link or a file's address and says which entry would take it, and what it
would do.

## File types

Add File Type… asks for one or more extensions, like `pdf, epub`, and what happens to those files:

- **Save** writes them to the folder you choose.
- **Open** saves them where downloads go, then opens them in the app your Mac uses for that type, the one a
  double-click in Finder would open.

Open works only for safe types. Apps, scripts, installers, disk images, archives, plug-ins, web pages and links to
other places (`.webloc`, `.inetloc` and the like), Office files with macros and `.mobileconfig` profiles are always
just saved, never opened. A file with no extension is never opened either. Zigzag checks the extension against its
own list and against what macOS says the type is, and a name like `file.tar.gz` counts as an archive. An Open entry
for one of these types, from a hand-edited rules file say, doesn't run: the file is saved as if the entry weren't
there, and a later entry can still decide where it goes.

A file type matches a download by its file name, never a link, since a link has no name yet. In a private window,
Save still applies; Open only runs there when **Allow in private windows** is on for that file type.

## Handoff rules

A handoff rule is one match and one action.

### What a rule matches

A rule applies to downloads only, or to links and downloads. It matches the address by:

- **Starts with**, **Contains** or **Ends with**, with **Match case** off by default.
- **Regular Expression**, for the cases the three plain kinds can't say. A regex that doesn't compile is kept as typed
  but never matches, so a half-written rule can't catch anything.
- **Any address**, the catch-all at the bottom of a list when it is used at all.

With several rules, the first match wins. Whatever no rule matches is saved by Zigzag exactly as before.

The ready-made rules for aria2, Motrix, rTorrent and yt-dlp catch **downloads only**: a file a page sends, or one you
download, is handed to the service. A link you merely click is not, even if it is a magnet or a video page. Make a
rule that applies to links and downloads if you want that, and choose what it sends to. The ready-made rules for mpv
and IINA are the exception: they catch links and downloads whose address contains `youtube.com/watch`, so a
YouTube video opens in the player.

### What a rule does

Add Rule lists the ready-made rules first. **Custom…** holds the four actions below, for a rule of your own.

- **Open App** opens the link in the app at the path chosen in the rule. **Choose…** lists the apps in your
  Applications folders, and Choose an App… picks one kept anywhere else.
- **Open URL** opens a URL the rule builds, such as `mpv://{encoded_link}`. This is how a scheme another app handles is
  reached.
- **Run Script** runs an executable, with every value as its own argument or environment variable. A `.sh` file is run
  by `/bin/sh`; anything else must be executable. Zigzag never builds a shell line, so `&`, `;`, `$()` and quotes in a
  URL arrive as part of one argument, not as commands. Scripts can live in Zigzag's Scripts folder, which **Choose… ›
  Show Scripts Folder** opens: a script there is named in the rule by its file name, like `yt-dlp.sh`, and any other
  script by its full path.
- **JSON-RPC** or **XML-RPC** sends the link to a service such as aria2, Motrix or rTorrent. The endpoint and method
  are literal, as an app's or script's path is. An optional token is kept in the Keychain, never in the rules file.

The executable path, the script path, the endpoint and the method are **literal**. A page can fill the values a rule
passes along, but it cannot choose what runs or where the values are sent.

A handoff rule also chooses **Hand off: URL or File**. **URL** gives the action the address, as before. **File**
downloads in Zigzag first, using the page's own session, then gives the action the saved file. A link never waits for
a file: a rule that catches links and downloads still hands off a link's address. The file goes to the downloads
folder, and the rule runs only after the download finishes. This is how a `.torrent` from a site that needs a passkey
outside the address reaches rTorrent or aria2: Zigzag makes the request with the page's sign-in, then hands over the
file it saved, so the service doesn't have to sign in itself. The same choice opens a finished download in an app, or
sends it to a service, once it is saved.

### Values and tokens

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
| `{file}` | The saved file's path, for a File handoff. Empty for a URL handoff. |
| `{file_url}` | The saved file as a `file://` URL, for a File handoff. Empty for a URL handoff. |
| `{file_raw}` | The saved file's own bytes, base64, for a File handoff. Sent as the XML-RPC binary type in an XML-RPC rule and as base64 text in a JSON-RPC one, which is how rTorrent's `load.raw_start` and a torrent client that takes the metafile itself want it. Filled in only in a service's parameters, and refused past 16 MB. |

A script also gets `ZIGZAG_LINK`, `ZIGZAG_REFERRER`, `ZIGZAG_FILENAME`, `ZIGZAG_MIME`, `ZIGZAG_SPACE`,
`ZIGZAG_COOKIES` and `ZIGZAG_COOKIE_HEADER` where they apply. A File handoff also sets `ZIGZAG_FILE` and
`ZIGZAG_FILE_URL` to the saved file. A JSON-RPC or XML-RPC rule may use `{secret}` in its parameters for the token
kept in the Keychain; a script is not given the token. A rule's endpoint may ask who it is with a username and
password: both are kept in the Keychain, bound to the address they were entered for, and sent as `Authorization: Basic`
rather than written into the address.

### Cookies

A rule that names `{cookies}` or `{cookie_header}` gets the tab's cookies from its own profile, never another
profile's. They are read for the target only when the target is the page's own site, or when you clicked the link
that led there. A download a page starts on its own, or one from the context menu, is treated as not clicked, so it
gets no cookies. A page that names another site on its own gets none of this site's cookies, whichever rule it names.
A JSON-RPC or XML-RPC rule also gets them only when its endpoint is on this Mac: a remote service is reached without
the site's sign-in.

The cookie file is made in a private temporary folder, readable by its owner only, and removed once the app or script
has had its moment to read it.

### Before a handoff

A rule asks before it hands anything off, on the same card over the page that a site's other questions use:
**Hand Off**, **Open in Browser** (or **Save in Zigzag** for a download), or **Don't Allow**, with a close button for
"not now". The answer holds for the page that asked, so a link and the download it starts ask once. Open in Browser, or Save in Zigzag, leaves the link or download exactly as it would have
been without the rule. Don't Allow refuses it: a link goes nowhere, and a download is not saved.

For a File handoff, **Hand Off** starts the download in Zigzag and the rule runs when it finishes. If the download
fails or is cancelled, the rule doesn't run, and Zigzag says so once in its notice and diagnostics.

A question is only asked where it can be seen: in the page in front, in a window that is visible and front. A page's
earlier answer still holds in a background tab or a window behind another; where it has no earlier answer, a new
question is not asked there, and the link or download carries on as if no rule had matched. A pop-up window never asks:
its links and downloads are always handled by Zigzag itself.

### Private windows

A rule stays out of private windows unless **Allow in private windows** is turned on in its own sheet. Off, a private
window never asks and never runs the rule; the link or download carries on as if no rule had matched. A private
window's address, and the cookies a rule names, are what that promise protects.
