<p align="center">
  <a href="https://zigzagbrowser.com"><img src="docs/brand/readme-hero.jpg" width="960" alt="Zigzag: Feels great. Weighs nothing. The lightweight browser for Mac, free and open source. A Zigzag window in split view, Fonts In Use beside Grilli Type, with the sidebar of spaces and pinned tabs."></a>
</p>

<div align="center">

English | [简体中文](README.zh-Hans.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md)

</div>

<p align="center">
  <a href="https://zigzagbrowser.com/download"><b>Download for Mac</b></a><br>
  <sub>or <code>brew install --cask zigaowang/tap/zigzag</code></sub><br>
  <sub>Free and open source. macOS 15.4 or later.</sub>
</p>

<p align="center">
  Your tabs in a sidebar, grouped into spaces. A native Mac app in Swift on WebKit,<br>
  about 35 MB installed, with no account and no telemetry.
</p>

## Why I built it

Hi, I'm Zigao, a high school student in Shanghai. I used Arc every day. When The Browser Company said it's shutting
Arc down on December 22, I really didn't want to go back to tabs along the top, and the alternatives I tried were
either Chromium forks or browsers built around AI. So I made my own, and I've used it as my main browser ever since.

**Why WebKit and not Chromium?** I actually started by forking Helium. The source was about 100 GB and every build
took 3 to 4 hours on my Mac, which isn't something I can keep up by myself. WebKit already comes with macOS, it's
lighter on battery and memory, and Apple ships its security fixes with macOS updates. You still get Chrome
extensions, installed straight from the Chrome Web Store.

**Why not Zen or Orion?** I tried both before starting this, and they're good. Zen runs on Firefox, so it uses Firefox
extensions and doesn't feel like a Mac app to me. Orion is closer, but it isn't open source. I wanted something
that works like Arc, feels native, is open source, and runs my Chrome extensions.

## Coming from Arc

**Your Arc comes with you.** File › Import from Another Browser…, pick Arc, and your spaces, pinned tabs, pinned folders, Favorites,
history, passwords, sign-ins and extensions come over. Your open tabs can come too, split views and all, and wait to
load until you click them; leave Open Tabs unchecked to start clean. If your spaces are on more than one Arc profile,
each Arc profile comes over as a Zigzag profile of its own.

**1Password works.** Install it from the Chrome Web Store inside Zigzag, like you would in Arc. It talks to the
1Password app. The first time, add Zigzag in 1Password › Settings › Browser. Bitwarden works too.

**It can't be switched off.** There's no account, and Zigzag doesn't depend on a server of mine. The only things I
host are the update feed and a short list of ad blocking fixes, and if they went away, Zigzag would keep working.
[Privacy](#privacy) lists everything Zigzag connects to on its own.

## See it

<p align="center">
  <img src="docs/spaces.gif" width="960" alt="Switching between three spaces in Zigzag, each with its own color and tabs">
</p>

<table>
  <tr>
    <td width="50%"><img src="site/assets/clips/split.jpg" alt="Split view: Fonts In Use beside Grilli Type"><br><b>Split View.</b> Drag a tab onto the page to open it beside, up to four at once.</td>
    <td width="50%"><img src="docs/all-tabs.jpg" alt="Every tab across three spaces shown as cards"><br><b>Every tab at once.</b> ⇧⌘\ shows every space. Type to filter.</td>
  </tr>
  <tr>
    <td width="50%"><img src="site/assets/win-peek.webp" alt="A Wikipedia article on typography over the page it was opened from"><br><b>Zigzag Mini.</b> Shift-click a link to glance at it without losing your place.</td>
    <td width="50%"><img src="site/assets/clips/reader.jpg" alt="An essay from The Public Domain Review in Reader"><br><b>Reader.</b> Long reads, without the clutter.</td>
  </tr>
</table>

<p align="center"><sub>More, in motion, at <a href="https://zigzagbrowser.com">zigzagbrowser.com</a>.</sub></p>

## What it does

| | |
|---|---|
| **Spaces** | Each with its own color, icon, pinned tabs and folders. Swipe on the sidebar, or nudge the mouse wheel sideways, to switch. |
| **Favorites** | Your most used sites as tiles, above every space. Any tab, pinned tab or favorite can wear its own emoji or symbol. |
| **Profiles** | Keep work and personal apart. Each profile has its own extensions, sign-ins, history and favorites, and every space is on one. |
| **Sites in spaces** | Choose a space for a site in Site Controls or Settings › Spaces, and its links open there wherever they come from: another app, ⌘T or another space, as with Arc's Air Traffic Control. Paths can go to their own spaces too, like `github.com/org1` to one and `github.com/org2` to another. A space on its own profile works like a Firefox container. |
| **Command bar** | ⌘T or ⌘L. Finds open tabs, history and sites. Type `you`, press Tab, and you're searching YouTube. Drag the bar anywhere in the window and it opens there from then on. |
| **Tab groups** | Pick some tabs and choose Group Tabs, and they become a folder in the sidebar that opens and closes, renames, and moves as one. Drag a tab to the right to nest it under the tab above, and to the left to take it back out. |
| **Live folders** | A pinned folder that fills itself from a feed or a site, or from GitHub: pull requests, review requests, or the open issues and pull requests in your repositories. New pages come with a dot. |
| **Split view** | Up to four tabs: drag a tab onto the page's edges for a half, or its corners for a quarter. Drag a page by its strip to move it, and pin a split to keep it. |
| **Windows** | Drag a tab to another window and it moves as it is, without loading again. Turn on Settings › Tabs › Windows share a space's tabs and every window on a space lists the same tabs, as in Arc. The sidebar sits on the left or the right. |
| **Web apps** | Install as App makes a site an app of its own, in your Applications folder, the Dock and ⌘Tab, with a toolbar in the site's color. |
| **Mini player** | Leave a tab while its video plays and the video follows you in a small player. Resize it from any edge and put it anywhere, even outside the window over other apps. Turn it off from its menu if you'd rather not have it. Switch to another app and the video floats over it in Picture in Picture. |
| **Streaming** | Protected music and video play as in Safari, through WebKit's FairPlay Streaming: Spotify's web player works, and so do other services that support Safari. |
| **Now Playing** | Every tab playing sound in the background gets a card at the foot of the sidebar, up to three, to pause or mute it. |
| **All tabs** | ⇧⌘\ shows every space at once. Type to filter, drag a tab to another space. |
| **Clear** | Closes the tabs you've drifted away from and keeps the ones you're working with. Point at it to see which it would close. A split view stays or goes whole. Undo brings them back. |
| **Zigzag Mini** | ⌃⌘N opens a small window for one quick page, and ⌘O moves it into your browser window. Shift-click a link, or choose Open Link in Zigzag Mini, and it opens in one over your window; ⌘O puts it in a tab next to the one you clicked in, and Esc closes it. Links from other apps open in it, like Little Arc (turn that off in Settings › Zigzag Mini), and Open in Zigzag Mini moves a tab into one. |
| **Passwords** | In your Mac's Keychain, synced by iCloud Keychain. Touch ID, a generator, and a check for weak and reused ones. Passkeys work. |
| **Dark pages** | Light sites drawn dark by Dark Reader's engine, with its fixes for thousands of sites, so photos stay true. Sites with a dark look of their own keep it. Pure black if you like it darker. On everywhere or per site. |
| **Ad blocking** | Built in and on: about 130,000 EasyList, EasyPrivacy and EasyList China rules, compiled into WebKit content rule lists, plus uBlock Origin's filter lists, which update on their own. |
| **WebRTC** | Turn on Protect IP address from WebRTC, and sites can't learn your real IP address through WebRTC while you use a proxy or VPN. Calls work on the sites you allow, and a site that tries WebRTC while it's blocked says so, with Allow for This Site. |
| **Cookie pop-ups** | Turned down for you, never accepted, with DuckDuckGo's Autoconsent rules. Leave them alone everywhere or for one site if you'd rather answer yourself. |
| **Site Controls** | One panel per site: zoom, permissions (camera, microphone, location, notifications, pop-ups, opening apps, screen sharing, WebRTC), each set to Ask, Allow or Block, JavaScript on or off, the certificate, extensions, and switches for dark pages, ad blocking and cookie pop-ups. When a site asks for one of these, it asks on one card over the page, for this time or always, and a site you said no to stops asking. |
| **Boosts** | Zap Element hides the parts of a site you don't want, like a banner or a sidebar, and Edit Style gives a site CSS of your own. Both are in Site Controls' ⋯ menu and stay with the site. |
| **Developer Mode** | For the sites you build, `localhost` to begin with: the console with an error count, Inspect Element, device sizes, light and dark, print styles, JavaScript, images or styles off, another user agent, and a QR code to open the page on your phone. |
| **Extensions** | From the Chrome Web Store, where the store's own button reads Add to Zigzag. 1Password, Bitwarden, Dark Reader, Tampermonkey and most popular ones work; see below for what doesn't. |
| **Import** | Bookmarks, history, passwords, sign-ins and extensions from Arc, Chrome, Safari, Dia, Edge, Brave, Vivaldi, Opera, Comet, Helium, Yandex, Whale, Chromium, Thorium, Firefox, Zen and Orion. |
| **Downloads** | Send files of a type to a folder of their own, or open safe ones like PDFs once they're saved. Rules hand a link or a download to an app, a script or a download manager like aria2, asking you first. See [docs/download-rules.md](docs/download-rules.md). |
| **Automation** | AppleScript, Shortcuts and `osascript` can list and open tabs and read pages, written the way Safari and Chrome take them. See [docs/automation.md](docs/automation.md). |
| **AI apps** | Off until you turn it on: AI apps on your Mac can use your tabs over MCP, never private windows or passwords. See [docs/automation.md](docs/automation.md#ai-apps-mcp). |
| **Your data** | File › Export Your Data… saves your bookmarks as a standard HTML file any browser imports, and a full Zigzag backup you can restore on another Mac. |
| **Languages** | English, Simplified Chinese, and Traditional Chinese. |
| **And** | Reader, PDF viewer, Handoff to your iPhone, iPad or other Mac, Capture of an area, a part of the page or the whole page (⇧⌘2), on-device translation, find on page that marks every match, a History menu with Recently Closed and the last seven days, a default page zoom, an address bar above the page if you'd rather have one, Picture in Picture, private windows, Web Inspector. |

## What's missing

It's my everyday browser, but Zigzag is young and you'll find bugs. Things Arc users will notice:

- No sync between Macs or to iPhone. Passwords sync through iCloud Keychain; spaces and tabs don't.
- Space icons don't come over from Arc; pick them again in Zigzag. Space colors come over as the nearest Zigzag color.
- No Easels or Notes, and Boosts are CSS only (Zap Element and Edit Style, no per-site scripts). No AI built into the browser: AI apps can use Zigzag over MCP only if you turn it on.
- A few Chrome extension APIs aren't there yet: the tab groups API, debugger settings, Chrome's own Google account sign-in (`identity.getAuthToken`), and the old request-blocking webRequest. Proxy extensions can set a fixed HTTP, HTTPS or SOCKS5 proxy but not a PAC script, so FoxyProxy's Proxy by Patterns mode doesn't work.
- EasyList and the other built-in blocking lists update with Zigzag, not on their own; only uBlock Origin's lists do.
- macOS 15.4 or later only.

## How it's built

Zigzag is about 120,000 lines of Swift 6 and AppKit around `WKWebView`. There's no Chromium and no Electron: the
engine is the WebKit that ships with macOS, which is why the app is small and why engine security fixes arrive
with macOS updates rather than from me.

| Part | How |
|---|---|
| **Pages** | One `WKWebView` per tab. Tabs you haven't used in a while can be suspended: the web view is released and the tab keeps its snapshot and state, then reloads when you come back. Private windows use a non-persistent data store. |
| **Extensions** | WebKit's web extension support (`WKWebExtensionController`, the reason for the macOS 15.4 minimum). Zigzag downloads the CRX3 package from the Chrome Web Store, checks its signatures, and loads it. Chrome APIs WebKit doesn't have (history, bookmarks, downloads, notifications, side panels, offscreen pages, web sign-in, tab audio, new tab pages, user scripts, proxies and more) are answered by Zigzag itself through a small bridge, checked against each extension's own permissions. A search engine an extension gives (`search_provider`) joins the choices in Settings, used only once you pick it. Native messaging connects the helper apps of 1Password and other extensions. |
| **Sandboxing** | Pictures and PDFs from websites are read in two sandboxed XPC helpers, `ZigzagImageDecoder` and `ZigzagPDFRenderer`, with no network and no file access, so a malformed image or PDF can't reach your passwords or profiles. The PDF viewer draws the pages the helper renders; the app never opens a site's PDF itself. |
| **Secure connections** | Certificate warnings say what's wrong under Details. A site that asked for secure connections only, by its HSTS header or on Chromium's preload list (bundled, about 95,000 names, read in place only when a warning needs it), gets no Visit anyway, as in Safari and Chrome. A site that asks for a certificate to identify you is offered the ones in your Keychain that it would take, as in Safari: add one by opening its .p12 in Keychain Access. |
| **Ad blocking** | EasyList, EasyPrivacy and EasyList China converted ahead of time with SafariConverterLib into content rule lists (`WKContentRuleListStore`), compiled once and cached. uBlock Origin's lists, downloaded as they expire, are matched by Ghostery's adblocker engine in its own JavaScript context, and each page gets the scriptlets and hiding rules its site needs as it starts to load. |
| **Dark pages** | Dark Reader's dynamic theme and its site fixes, bundled, in a script world of its own. Pages are told the window is dark first, so a site with its own dark theme uses it and is left alone. |
| **Cookie pop-ups** | DuckDuckGo's Autoconsent and its rules, bundled, in a script world of its own. |
| **Passwords** | Saved as Keychain items, so iCloud Keychain syncs them and Touch ID unlocks them. Passkeys go through Apple's browser passkey entitlement. Autofill is a small content script that only fills fields you can see. |
| **Import** | Reads each browser's own files: Arc's `StorableSidebar.json`, Chromium's bookmarks and SQLite history, Safari's `Bookmarks.plist`, Firefox's `places.sqlite`, Orion's `favourites.plist` and `history`. Chromium passwords are decrypted with the key from that browser's Keychain item, after macOS asks you. |
| **Your data** | Spaces, pins and favorites in `Library.json`, profiles in `Profiles.json`, open tabs in `Session.json`, history in SQLite (one file per profile), all under `~/Library/Application Support/Zigzag`. Writes are debounced and atomic, and a file that can't be read is set aside, never overwritten. |
| **Reader** | Mozilla's Readability, run in the page, shown in Zigzag's own typography. |
| **Web apps** | A site installed as an app is a small app of its own in `~/Applications/Zigzag Apps` that hands every launch to Zigzag, so the page runs in Zigzag with your sign-ins, extensions and blocking. |
| **Updates** | Sparkle 2, with EdDSA-signed updates from zigzagbrowser.com, on a stable or a beta feed. Releases are signed with Developer ID and notarized. |

The source is organized by feature: `Sidebar`, `Tabs`, `Web`, `Extensions`, `Passwords`, `Import`, `Profiles`,
`CommandBar`, `Desk` (every tab at once), `WebApps`, `Developer`, `MCP` (AI apps), `Settings`, `Window` and
`Design` (Zigzag's own drawn controls and design tokens). Over 2,000 tests cover importing, passwords, extensions,
address handling, history, AI apps and the security fixes.

## Privacy

No account, no analytics, no telemetry. Nothing about how you browse is sent to me. These are the only
connections Zigzag makes on its own, apart from the pages you open:

- **Updates.** Every few hours, and after your Mac wakes, Zigzag reads the update feed at zigzagbrowser.com. The
  request says Zigzag's version and nothing else; no system profile is sent. A new version downloads from there too.
- **Search suggestions.** As you type in the address bar, the text goes to your search engine for suggestions,
  without cookies. Google, DuckDuckGo, Brave, Bing, Kagi and Ecosia offer them; with any other engine, nothing is
  sent. Turn them off in Settings › Search.
- **Site icons.** Icons come from each site itself, also for pinned tabs, favorites and imported bookmarks you
  haven't opened yet.
- **Filter lists.** At launch and then as they expire, every few hours to once a day, Zigzag downloads uBlock
  Origin's filter lists from uBlock Origin's own addresses (GitHub Pages, Cloudflare Pages or jsDelivr) and its
  scriptlets from Ghostery's CDN. It also downloads Zigzag's own short list of site fixes from zigzagbrowser.com.
  The requests carry no cookies, and nothing about you or your browsing.
- **Extensions.** Installing one downloads it from the Chrome Web Store. At launch, at most once a day, Zigzag
  asks the store whether your extensions have updates, which sends their IDs and versions to Google.
- **Setup.** The welcome screens show a few site icons from Google's icon service and load Wikipedia's front page
  as a preview.

Translation runs on your Mac, with Apple's on-device Translation. Fraudulent website warnings are WebKit's own,
the same as Safari's. Passwords stay in your Mac's Keychain and sync only through your own iCloud Keychain.
Help › Report a Problem writes a report you can read first, and nothing is sent unless you send it.
The Mac's Passwords list keeps a small log of its steps in `~/Library/Logs/Zigzag/passwords.log`, never a login or
a site, and it stays on your Mac. Your Zigzag Card is made on your Mac from your account's name and the day Zigzag
first ran, and its picture holds only what the card shows.

## Install

Download the DMG from [zigzagbrowser.com](https://zigzagbrowser.com/download), open it, and drag Zigzag to
Applications. Or, with Homebrew:

    brew install --cask zigaowang/tap/zigzag

Updates install by themselves. What changed in each version is in the
[release notes](https://zigzagbrowser.com/release-notes) and [CHANGELOG.md](CHANGELOG.md).

## Feedback

- **Bugs and ideas:** [open an issue](https://github.com/ZigaoWang/zigzag/issues/new/choose), or Help › Send Feedback… in the app. For a bug, Help › Report a Problem… writes a report you can read before you send it.
- **Email:** a@zigao.wang
- **Security problems:** see [SECURITY.md](SECURITY.md). Please don't post them in public issues.

## Build from source

Requirements: macOS 15.4 or later, Xcode 27 or later, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
git clone https://github.com/ZigaoWang/zigzag.git
cd zigzag
xcodegen generate
open Zigzag.xcodeproj
```

Run the **Zigzag** scheme. Debug builds run as a separate app, "Zigzag Dev", with their own data, so they never
touch your everyday Zigzag.

Signing is set up for my team. To build on your Mac, change two things in `project.yml` and run
`xcodegen generate` again:

- `DEVELOPMENT_TEAM`: your own team ID (Xcode › Settings › Accounts shows it).
- The Debug `PRODUCT_BUNDLE_IDENTIFIER`: one of your own, such as `com.yourname.zigzag.dev`, since
  `wang.zigao.zigzag.dev` is registered to my team.

Run the tests:

```sh
xcodebuild test -project Zigzag.xcodeproj -scheme Zigzag
```

## Contributing

Contributions are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) for how the project is built, tested and
styled.

## License

Zigzag's code is licensed under the [Apache License, Version 2.0](LICENSE). Use it, change it, fork it and ship
it, commercially or not.

The name "Zigzag", the app icon and the logo are not covered by the license: they're trademarks, all rights
reserved. A fork needs its own name and icon. See [TRADEMARKS.md](TRADEMARKS.md) and [NOTICE](NOTICE).
Third-party work Zigzag uses is listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Acknowledgments

Thanks to the [LINUX DO](https://linux.do) community for trying Zigzag early and sharing their feedback.

<p align="center">
  <a href="https://linux.do"><img src="https://shorturl.at/ggSqS" alt="LINUX DO" /></a>
</p>
