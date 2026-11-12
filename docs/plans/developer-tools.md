# Developer tools

Goal: the tools someone building a website reaches for, on the sites they build and nowhere else. Issue [#141](https://github.com/ZigaoWang/zigzag/issues/141). Branch `feat/developer-tools`, in small pull requests.

## What exists today

- View › Developer: Web Inspector (⌥⌘I, F12), JavaScript Console (⌥⌘J), Inspect Element (⌥⌘C), View Source (⌥⌘U). The inspector docks inside the page's own holder (`PageHolder`, #148).
- View › Reload Ignoring Cache (⌥⌘R).
- Site Controls › ⋯: Clear Cache for This Site…, Clear Cookies for This Site….
- `PageErrors` hears every page's uncaught errors and rejected promises, for Help › Report a Problem.
- Settings › Extensions › Developer mode is about extensions and stays where it is.

## What WebKit allows (tried in test web views on macOS 26.5; 15.4 by its headers only)

Public API:

- Sizing the page: the web view is a view, its holder gives it a size.
- `webView.appearance` for light or dark, `mediaType` for print styles, `customUserAgent`, `WKWebpagePreferences.allowsContentJavaScript` per navigation.
- Trusting a server's certificate, in the navigation delegate's challenge.

Private setters, left for later, one at a time, each guarded like the `_inspector` calls: shrink to fit (`_setLayoutMode`, `_setViewScale`), the pixel ratio, images and styles off.

Not possible from an app that hosts a `WKWebView`: touch events, network throttling (proxies are bypassed for loopback), emulating reduced motion or contrast, turning the cache off, choosing the inspector's tab or side.

The inspector and a narrow page (tried on `main` at 4c6dad22, a split in a 560-wide window and a window narrowed with the inspector docked):

- Opened in a holder under its minimum width, it doesn't dock: it opens in its own window.
- Already docked when its holder narrows, it stays docked and keeps its own width (500 here), whatever the holder's is; the page gets what is left, and under 500 the inspector hangs out of the holder.
- Its width doesn't depend on the holder's, and both are plain subviews of the holder. So a page given a size keeps it beside a docked inspector if the holder is made that size plus the inspector's room.

## Approach

One rule: a tab is a **development tab** while Developer tools is on and the page it shows is on the list of development sites (`DeveloperTools.applies(to:)`, `Tab.isDevelopment`). Every tool, mark and choice made with them exists only then.

- Off the list, the tools and the mark go and the tab's choices (a size, a look, a user agent, JavaScript off) stop applying, from the moment the other site's page arrives. They're kept and apply again when the tab comes back, a sign-in that passes through another site included, and are gone when the tab closes. Nothing about them is saved.
- Developer tools off: no tab is a development tab. The menu bar, Settings › Shortcuts, the window and every page are as they are without this feature.
- The page it shows is the one last committed; before any, the address the tab is going to. An address shown early changes nothing, so a redirect doesn't flicker the tools.

The list (`DevelopmentSites`) starts as `localhost` and `127.0.0.1`. A site is a host without "www.", whatever its port, and covers its subdomains, as every other choice for a site does. Nothing is written until the list is changed. It isn't changed from a private window.

Where the tools show: a thin strip at the top of the page, on the page card, for a development tab only. Not in the address bar: the bar above the page would have to come and go with the tab, which moves the sidebar's list under the pointer. In a split each pane keeps its header and the tools are in Site Controls, the menu bar and the command bar.

## Steps

1. **Settings › Developer, the list, the mark.** The switch, the list with Add Site… and Remove, and a hammer on a development tab's row in the sidebar.
2. **The tools Zigzag already has**, by the menu bar, the command bar and Site Controls: this site's cache and cookies, and Developer Tools on This Site (⌃D) to put the site you're on on the list or take it off.
3. **The strip**: Console, Inspect Element, reload's choices and More, folding into More in a narrow window; "Tools above the page" in Settings, and the same tools as tiles in Site Controls wherever a development page has no strip.
4. **The error count** on Console: uncaught errors and rejected promises since the page loaded.
5. **Page appearance**: follow the Mac, light or dark, and print styles.
6. **Page size**: presets, a custom size, rotate, handles on the page's edges.
7. **The rest of More**: JavaScript off, user agent, open in another browser, outline every element.
8. **A development site's certificate**: trusted without the warning for a site on this Mac, off until turned on.

Not in these: the private setters above, reloading when files change, counting `console.error`, a user agent typed by hand, tools in a split's panes, moving Extensions' Developer mode.

## Rules while doing it

- Public API only. Anything private waits for its own pull request.
- With Developer tools off, or on a site that isn't listed, nothing differs from `main`.
- No state moves anything in the sidebar or the address.
- Conventional commits, one small change each, no co-author lines.
