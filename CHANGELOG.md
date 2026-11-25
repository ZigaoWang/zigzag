# Changelog

Every release of Zigzag, newest first. The app shows the notes for the version you're running, and
[zigzagbrowser.com/release-notes](https://zigzagbrowser.com/release-notes) shows them all.

## [Unreleased]

### New
- Compatibility mode in Site Controls, for a site that doesn't work right: one switch turns off extensions, ad blocking, cookie banners and zapped elements on that site, and turning it off brings back every choice you made for them. Site Controls shows it in the accent while it's on, and Settings › Privacy › Sites lists it. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#497](https://github.com/ZigaoWang/zigzag/issues/497))
- In Settings, long lists fold into boxes the way Site Permissions does: each menu in Shortcuts, each download rule with its saved answers inside, each kind of feature flag, and Sites in Developer Mode, Trusted Certificates and Page Sizes once they list more than three. Find a setting still opens the box a match is in. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#536](https://github.com/ZigaoWang/zigzag/issues/536))
- Settings opens faster. A section's rows are made the first time you open it, and a folded box's when you open it or a search looks in it, so opening Settings on General no longer builds Downloads, Shortcuts or Developer. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#536](https://github.com/ZigaoWang/zigzag/issues/536))

## [0.10.0] - 2026-11-25

Zigzag in thirteen more languages, from Japanese and Korean to German, French, Spanish and Russian; download rules that hand off the saved file; live folders that say when they last updated; and typing Chinese Pinyin then switching to English without stray spaces.

### New
- Zigzag is now in Japanese, following Apple's own Japanese terms for macOS and Safari. It follows your Mac's language, or pick it in Settings › General › Language.
- Zigzag is now in Korean, German, French, Italian, Spanish, Brazilian Portuguese, Russian, Dutch, Polish and Turkish, following Apple's own terms for each. It follows your Mac's language, or pick one in Settings › General › Language.
- A download rule can hand off the file instead of the address: set Hand off to File, and Zigzag downloads it first with the page's session, then gives the saved file to the app, script or service. Links still hand off their address, and a File handoff's templates can use {file} or {file_url} for the saved file. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#529](https://github.com/ZigaoWang/zigzag/issues/529))
- A live folder's menu now starts with when it last updated, like Updated 5 Minutes Ago, or Updating… while it fetches.
- The New and Edit Live Folder sheet asks for the source first, lines its menus up with the fields, and says under them what the folder will show and that it checks every 30 minutes (hourly in Low Power Mode). A name left empty shows the name it will get, and a username GitHub can't have is marked.

### Fixed
- With Zigzag Mini open over a page, scrolling over the dimmed page no longer moves the page behind it. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#531](https://github.com/ZigaoWang/zigzag/pull/531))
- The briefing before websites may reach apps on this Mac now says the steps in order: turn the setting on, then turn on each site in its Site Controls, and turning the setting off stops every site. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#533](https://github.com/ZigaoWang/zigzag/issues/533))
- In Settings, a list under a heading with buttons or a search beside it, like Stored by Websites or Hand Off Downloads and Links, no longer starts right under those controls. It keeps the same space below them as every other heading has. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#527](https://github.com/ZigaoWang/zigzag/issues/527))
- Switching from Chinese Pinyin to English mid-word no longer leaves spaces between the letters, on a page or in the address bar, as in Chrome.
- A see-through space with Clear glass no longer keeps the Mac's graphics busy while Zigzag sits still, even on a blank page or in Settings. macOS was redrawing the whole window and its shadow every frame; it now draws it only when something changes. The update card's progress bar also stops sliding while it's hidden.

## [0.9.5] - 2026-11-25

Export Your Data so you can always take everything with you, live folders, nesting tabs by dragging, Traditional Chinese, full screen that stays in the browser, an Autohide address bar, the sidebar from the screen edge, smoother scrolling with less of Zigzag's own work on every page, pages at your display's full 120 Hz, touch that feels native on a touch display, Dia's pinned tabs on import, press and hold Back or Forward for history, sign-ins and YouTube's theater mode kept after a relaunch, and password manager extensions in Settings.

### New
- Importing from Dia brings its sidebar too, as from Arc. Each Dia profile's pinned tabs are pinned in the space its bookmarks go in, split views stay side by side, Dia's favorites become favorites, and with Open Tabs on, the tabs open there come over and wait to load until clicked. Importing again adds only what's new. ([#511](https://github.com/ZigaoWang/zigzag/issues/511))
- Press and hold Back or Forward to see the pages that way and pick one, as in Safari and Chrome. Slide onto a page and let go to go there, or let go and click one. It works in the sidebar, the bar above the page, split view, Zigzag Mini and web apps, and a finger held on a touch display opens the same list. A right-click still opens it too, now in Zigzag's own menu. ([#509](https://github.com/ZigaoWang/zigzag/issues/509))
- With Settings › Tabs › Full screen videos fill set to The Whole Screen, a video's full screen now stays in the browser window. The window goes into its own full-screen space, as with View › Enter Full Screen, and the sidebar and bar step aside; move the pointer to the top to bring the bar down. In split view the video fills its own pane instead. Esc puts the window back as it was, and a window that was already in full screen stays there. The button in the video's top corner still gives it a full screen of its own, as before. Web apps, Zigzag Mini and the mini player keep the full screen they had. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#462](https://github.com/ZigaoWang/zigzag/issues/462))
- Zigzag now speaks Traditional Chinese. Choose it in Settings › General › Language and restart Zigzag. Thanks to [aliceric27](https://github.com/aliceric27). ([#505](https://github.com/ZigaoWang/zigzag/issues/505))
- Sidebar from the screen edge, in Settings › Appearance, brings the sidebar out over whatever app you're in, the way a hidden Dock comes out. Push the pointer against the edge of the screen on the sidebar's side and rest a moment: your spaces, favorites, tabs and what's playing show over that app. Click a tab, a favorite or New Tab and Zigzag comes forward on it, as from the Dock; move the pointer away and the sidebar goes back with the other app still in front. It never comes out in a corner, on the side the Dock or Stage Manager uses, or at an edge that leads to another display. Off until you turn it on. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#363](https://github.com/ZigaoWang/zigzag/issues/363))
- AI apps can work in the background, with nothing on screen: turn on Settings › Automation › Run AI apps in the background (off until you do, and only with Let AI apps use Zigzag on). They get a hidden window of their own on a profile of their own, AI Apps, and can't see your windows or tabs; its space stays out of your sidebar and space lists, and you can delete the profile in Settings › Profiles. With both switches on, opening Zigzag with `--headless` runs it for them alone, with no Dock icon or window until you open it, and it quits on its own once they're done. That profile is given nothing of yours: no saved passwords, sign-ins, certificates or passkeys, none of the permissions you gave sites, none of your download rules or site routes, no reaching apps on this Mac, and its tabs never go to your Archive. Their pages start muted, can't go full screen over your screen or write to your clipboard, and their downloads go to a folder of their own, out of your downloads list and the Dock. No one is there to answer a page, so its dialogs are dismissed and the app is told. An item in the menu bar shows they're working, with Show AI Apps Window to watch them and Stop AI Apps. Tabs an AI app is using are no longer put to sleep, archived or cleared away under it. Thanks to [vandenbulckjean](https://github.com/vandenbulckjean). ([#214](https://github.com/ZigaoWang/zigzag/issues/214))
- Extensions that save pages (`chrome.pageCapture`) work: they can save a tab as one MHTML file, as in Chrome, with its styles, pictures and frames, which Chrome and other browsers open as the page. It's only for web pages on sites the extension can access. Of what a page loaded, only its pictures, stylesheets and fonts go in, as in Chrome, and a frame from a site the extension can't access is left out. Thanks to [OnurrUgur](https://github.com/OnurrUgur). ([#488](https://github.com/ZigaoWang/zigzag/issues/488))
- File › Export Your Data… saves your spaces, pinned tabs and favorites as a bookmarks file Chrome, Safari, Firefox and other browsers import, each space a folder with its folders and pages in the sidebar's order. It can also save a Zigzag backup with your spaces, folders, split views, favorites, profiles, site settings and settings, and if you like your open tabs and history, which Zigzag restores on this Mac or another when you double-click it or choose it in the Import window, asking first and never making copies of what's already there. Passwords stay in the Passwords window, which exports them on its own. It's in Settings › General and the command bar too. ([#518](https://github.com/ZigaoWang/zigzag/issues/518))
- The address bar above the page can Autohide. Settings › Appearance › Address bar above the page is now Off, Autohide or Always, and if you had it on, it stays Always. With Autohide the bar goes up with the page as you scroll down, the page taking its room, and comes back when you scroll up in a new swipe, scroll to the very top, move the pointer to the window's top, press ⌘L, or tap where it was on a touch display. It stays put while you type in a page or while the page scrolls by itself, and the window buttons go and come back with it. In split view each page's bar follows its own scroll. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#359](https://github.com/ZigaoWang/zigzag/issues/359))
- Live folders, as in Arc. Choose New Live Folder… from the sidebar's +, a space's menu or a folder's menu, and paste a feed's address or just a site's, or pick a GitHub list (your open pull requests, issues assigned to you, or review requests) and type your username. The folder fills itself with the newest pages and checks for more every half hour in the background, and new ones have a dot until you open them. Its menu has Mark All as Read, Refresh Now and Edit…, and says why when a feed couldn't be fetched. Drag a page out to pin it where you drop it. GitHub lists show public repositories only, since Zigzag doesn't sign in to GitHub for them.
- Settings' long lists fold. In Privacy › Site Permissions each site is a box with its name, how many choices it has and Forget, its choices inside; in Extensions each extension is a box with its switch, and its site access and private window settings inside; in Stored by Websites each site is a box that opens to its cookies and its cache, each cleared on its own after asking, with the trash still removing everything. With more than three, boxes start folded; click one, or press Space or →, to open it, and it stays as you left it while Settings is open. With eight or more sites or extensions, a search beside the heading narrows the list, and Find a setting opens the box a match is in. Thanks to [Lakeland97](https://github.com/Lakeland97) for the idea. ([#368](https://github.com/ZigaoWang/zigzag/issues/368))
- Drag a tab to the right to nest it under the tab above, even one with no tabs under it yet, and to the left to take it back out. The line shows how far in it will land. From the keyboard, View › Nest Tab (⌃⇧→) puts the tab you're on under the tab above it, and Unnest Tab (⌃⇧←) moves it back out. Thanks to [bkonia](https://github.com/bkonia) for the idea. ([#523](https://github.com/ZigaoWang/zigzag/issues/523))
- Live folders can follow the open issues or pull requests in the repositories a GitHub user owns, whoever opened them, so a maintainer's folder fills with what comes in. The other GitHub lists now say what they hold: Pull Requests Opened, Issues Assigned and Review Requests.
- A live folder shows its site's icon in the sidebar, GitHub's for a GitHub list, with a small live mark on the corner so it still reads as live.
- Hold your mouse's Back or Forward button to see the pages that way at the pointer, as with the on-screen arrows. Slide onto a page and let go to go there, or let go and click one. A quick press still goes one step. Thanks to [Lakeland97](https://github.com/Lakeland97) for the idea. ([#515](https://github.com/ZigaoWang/zigzag/issues/515))
- Turn on Settings › Zigzag Mini › Open ⇧-clicked links in the page and a ⇧-clicked link opens in Zigzag Mini right over the page you clicked from, the page dimmed behind it, instead of in a window of its own. Esc, a click on the dimmed page, ⌘W or switching tabs puts it away, and Open in Window gives the same page a Mini window of its own without reloading it. Off until you turn it on, so ⇧-click works as before. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#481](https://github.com/ZigaoWang/zigzag/issues/481), [#501](https://github.com/ZigaoWang/zigzag/issues/501))

### Fixed
- An English page no longer offers to translate from Hindi or Marathi because of a list of language names on it, and a few short lines like place names no longer make a page read as another language. Pages in any language in your list in System Settings › Language & Region aren't offered for translation, unless you set that language to Always Translate. ([#510](https://github.com/ZigaoWang/zigzag/issues/510))
- On a touch display, two fingers swiped sideways on a page go back or forward again, with the same arrow, distance and flick as on the trackpad. Before, the page scrolled instead. Up and down still scrolls, a pinch still zooms, and a page that pans sideways itself under your finger, like a map or a carousel, keeps the swipe.
- YouTube's theater mode and sign-ins that use session cookies stay after a relaunch when Zigzag reopens your last session, as in Chrome. With On launch set to Open a new window they're dropped as before, and private windows keep none.
- On a touch display, tapping one tab right after another selects each one. Before, a quick tap on the tab next to the one you just tapped renamed it, as two taps on the same tab do.
- On a touch display, a tap on a tab, a favorite or a sidebar button always does what a click does, even when macOS sends no click for it, and quick taps one after another each count.
- On a touch display, dragging tabs, pinned tabs, folders, favorites and space dots works like on an iPad. Hold for about a third of a second and the item lifts under your finger right away; move a few points and it drags, following your finger. Its menu only opens if you keep still a moment longer, so it no longer pops up in the way of a drag. Once lifted, the list doesn't scroll out from under the drag, and holding a tab near the top or bottom of the list scrolls it, faster nearer the edge.
- Settings › Passwords › Password manager lists each password manager extension you have on, like Bitwarden or 1Password, after Zigzag and iCloud Passwords. While one handles your passwords it shows checked instead of Zigzag. Choosing it turns off Zigzag's own Offer to save passwords and Fill saved passwords, and choosing Zigzag turns them back on.
- On a touch display, a two-finger swipe goes back or forward after about 2 cm of finger travel, as it feels on the trackpad, instead of twice that, and a page that fits the window no longer slides sideways under your fingers.
- Pages draw at the display's full refresh rate, up to 120 times a second on a ProMotion display, as in Chrome, so scrolling and animations are smoother. A page too heavy to keep up while you scroll, like signed-in GitHub, steadies at 60 until you go to another site, instead of stuttering. Settings › Developer › Feature Flags › Prefer Page Rendering Updates near 60fps still holds every page at 60. ([#394](https://github.com/ZigaoWang/zigzag/issues/394))
- A tab woken from sleep keeps its page's session storage, where some sites keep you signed in. Putting the tab to sleep used to drop it, so such a site could ask you to sign in again, two-factor and all, each time you came back to the tab. It's kept only in memory while the tab sleeps, and only the page that loads first on waking gets it back. ([#502](https://github.com/ZigaoWang/zigzag/issues/502))
- On a touch display, a two-finger swipe sideways on a page goes back or forward even when one finger lands a moment before the other or the swipe starts a little slanted. Before, it usually scrolled the page instead.
- Show All Tabs (⇧⌘\) opens and closes smoothly. The page starts shrinking into its card sooner, and the cards no longer hitch as they settle in, because less work runs as it opens, the overview stays ready between opens, and pages you left are made ready for it ahead of time.
- A two-finger swipe on the trackpad shows its arrow, and the page starts to move, as soon as your fingers start sideways, instead of a moment later, so you can tell right away that it will go back or forward. A page that scrolls sideways under the pointer, like a carousel or a map, still keeps the swipe, and scrolling up and down never shows the arrow. ([#508](https://github.com/ZigaoWang/zigzag/issues/508))
- The menu of saved logins under a sign-in field stays under the field when you zoom the page, resize the window or a split pane, or the page moves the field, and opens in the right place on a pinched-in page. Before, it stayed where it opened, over the field, and a click meant for the field could fill a login. ([#378](https://github.com/ZigaoWang/zigzag/issues/378))
- Importing from Dia makes a space for every Dia profile, named as in Dia, even one with no bookmarks or pinned tabs, and Dia's sidebar tabs land in the profile you last used there when Dia doesn't say which they belong to. ([#511](https://github.com/ZigaoWang/zigzag/issues/511))
- Scrolling long pages that keep changing, like X, GitHub and forums such as linux.do, is smoother, because Zigzag does less of its own work meanwhile. Cookie pop-up checks wait until you stop scrolling, a forum that changes its address for each post you scroll past no longer redraws the sidebar's address each time, and a page's language is worked out away from what draws the window. Help › Report a Problem also lists any moment Zigzag paused for more than a twentieth of a second, with what it was doing then. Pages also do less of Zigzag's work as you scroll: they listen for a back or forward swipe only while one may be starting, and look for new sign-in fields only after loading or something you do.
- A site that was too heavy for 120 Hz starts at 60 on its first page after a relaunch, instead of stuttering until Zigzag notices again; a site is remembered for a month, and clearing History or the site's data forgets it. A page that gets held near 60 changes rate once you stop scrolling, never mid-scroll. In Low Power Mode or when the Mac is hot, pages start near 60. ([#519](https://github.com/ZigaoWang/zigzag/issues/519))
- A feature flag you changed in Settings › Developer has a Reset button beside its switch, in place of a plain “Changed”, and a flag Zigzag starts other than WebKit, like Prefer Page Rendering Updates near 60fps, says so under its name.
- Letting go of a swipe that goes back or forward no longer springs the page back before it leaves. The page slides on a little and dims, then the next page shows in its place, so you can tell the swipe took without looking at the arrow. A swipe called off still springs back, and with Reduce Motion the page stays put. ([#508](https://github.com/ZigaoWang/zigzag/issues/508))
- A password manager extension you choose in Settings › Passwords › Password manager now counts even when Zigzag doesn't know it by name, like Litewarden: Zigzag stops offering to save and fill, shows no key icon in sign-in fields and leaves passkeys to it. An extension that turns the browser's own password saving off, as Bitwarden and 1Password can in Chrome, is listed there and counted the same way, until it turns that back, or you turn it off or remove it. ([#513](https://github.com/ZigaoWang/zigzag/issues/513))
- Sites you let use your location get it. Before, macOS never asked whether Zigzag could use your location and Zigzag wasn't listed in System Settings › Privacy & Security › Location Services, so a site you allowed, like Google Maps, never found where you are. Now the first site you allow makes macOS ask once. With Location Services off for the whole Mac, or refused for Zigzag, the site is told no at once instead of waiting.
- ⇧-clicking a link that the site opens by itself, as on YouTube and parts of Google, opens it in Zigzag Mini like any other ⇧-clicked link, instead of as a pop-up tab. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#522](https://github.com/ZigaoWang/zigzag/pull/522))
- Extensions that open a minimized window to load a page in the background, like Property Mate, no longer bring a window to the front. As in Chrome, it goes straight to the Dock, and one opened unfocused opens behind your window, which keeps focus. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#521](https://github.com/ZigaoWang/zigzag/issues/521))
- Sites that keep your sign-in in a tab's session storage, like Microsoft 365, keep you signed in after Zigzag quits and opens again on your last session, or restarts for an update. A tab that was asleep, or open as Zigzag quit, gets its page's session storage back before the page loads, as in Chrome. It's kept in your profile's folder, readable only by you, never for a private window, and it goes when you clear the site's data or close the tab. With On launch set to Open a new window it's dropped. ([#502](https://github.com/ZigaoWang/zigzag/issues/502))
- A link a site or extension takes off on purpose so a plain click opens its own viewer, like a quoted tweet in Old Twitter Layout, still opens in a tab on ⌘-click or middle-click, now through one rule in Zigzag that any site or extension can use: keep the address in `data-zigzag-href` ([docs/extensions.md](https://github.com/ZigaoWang/zigzag/blob/main/docs/extensions.md)). A plain click still opens the viewer. Thanks to [Lakeland97](https://github.com/Lakeland97) for the design. ([#517](https://github.com/ZigaoWang/zigzag/issues/517))
- A rule that hands downloads to an app, a script or a service can now match the file's own type, like torrent or pdf, not only its address. A tracker's download address often names no file, so its .torrent downloads can now reach the downloader whatever the address looks like. ([#524](https://github.com/ZigaoWang/zigzag/issues/524))
- Opened for a Zigzag Mini link, an installed site or AI apps alone, Zigzag no longer drops the last session's sign-ins: when you open a browser window and the session comes back, its session cookies and sessionStorage come back with it, so Microsoft 365 and similar sites keep you signed in. ([#502](https://github.com/ZigaoWang/zigzag/issues/502))
- A tab's chevron goes away once the last tab nested under it leaves, instead of staying behind and doing nothing, and dragging a tab right to nest it under the tab just above now shows the line at the depth it will land. Thanks to [bkonia](https://github.com/bkonia). ([#526](https://github.com/ZigaoWang/zigzag/issues/526))
- Holding Back or Forward with the mouse or trackpad, then sliding onto a page in the list and letting go, goes to that page again, as with a finger. Before, letting go there did nothing in the sidebar's top row and the bar above the page. ([#509](https://github.com/ZigaoWang/zigzag/issues/509))
- An extension pinned to the address, like 1Password, shows its whole icon centered in its button. Before, an icon that arrived after the button was drawn sat a little off and soft. In Site Controls the pin mark sits in the tile's corner instead of over the icon.
- 1Password's toolbar icon now matches Zigzag's toolbar: on a dark space it shows its dark-toolbar icon even when the Mac is in light mode, and the other way around.
- Pressing and holding Back or Forward in the sidebar, then sliding down, no longer drags the whole window: the list opens and you can slide onto a page and let go, with the mouse as with a finger.
- With a link open in Zigzag Mini over its page, ⌘T opens the browser's new tab bar with the Mini out of the way instead of acting behind it, and Esc goes to the sidebar's picked rows, its fields or the command bar when one of them has the keys. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#528](https://github.com/ZigaoWang/zigzag/pull/528))

## [0.9.4] - 2026-11-24

Reader redesigned to feel like part of Zigzag, Capture like Arc's for an area, an element or the page, Handoff to your iPhone, iPad and other Macs, ⌘Z for split changes, a sidebar width every window keeps, typed and held zoom, Zigzag Mini for shift-clicked links in place of Peek, a choice to start fresh on launch, new glass colors for spaces, Always and Never Translate, a calmer Settings, touch on a touch display, and Your Zigzag Card.

### New
- Zoom keeps going while you hold − or + in Site Controls, and ⇧-clicking the percentage lets you type one, like 130%, instead of stepping to it. A plain click still goes back to Actual Size. ([#395](https://github.com/ZigaoWang/zigzag/issues/395))
- Reader looks and works like the rest of Zigzag. Wide now fills the window inside its margins instead of stopping at a narrow column, Medium stays a book's line length, and Narrow is a little narrower. Large pictures and code blocks run past the text into the margins when the window has room, and pictures are centered rather than on the text's left edge. The title is lighter, the author is no longer repeated at the top of the text, the site's icon lines up with the text, and the spacing follows one steady rhythm. The Reader button in the address bar shows pressed while Reader is on. Aa sits in the article's top-right corner, fades away as you read down and comes back when you scroll up or move the pointer near the top. It opens Zigzag's own panel right under it, as View › Reader Text and Colors does, with each choice named: Text Size steps as page zoom does (− 100% +, the percentage puts it back), Typeface, Column Width, and Colors as round dots, like picking an accent color in System Settings, the chosen one ringed in the accent color. Auto is split between its light and dark paper and takes the barest hint of the space's color, the text as dark (or light) as before. Changing a choice keeps the line you were reading in place, and the text settles in as Reader opens, a plain fade with Reduce Motion. ([#455](https://github.com/ZigaoWang/zigzag/issues/455))
- Handoff works as in Safari. The page you're on in the front window shows up on your iPhone, iPad or other Mac to pick up there, and follows you as you switch tabs or go to another page. Private windows, Zigzag Mini, web apps, Zigzag's own pages, error pages, and files or `localhost` pages on your Mac are never offered. With Zigzag as your default browser, a page handed off from Safari or another device opens in a new tab of the front window, in its own space if you chose one for the site. It follows the Handoff setting in System Settings › General › AirDrop & Handoff. ([#456](https://github.com/ZigaoWang/zigzag/issues/456))
- ⌘Z takes back a change to a split's tiles. Each finished drag of a line between pages is one step, and so is Reset Tile Layout; ⇧⌘Z does it again. It still works after you switch to another tab. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#435](https://github.com/ZigaoWang/zigzag/issues/435))
- With the address bar above the page, the pin star sits at the end of the address pill, so the page can be pinned from there. As in the address field, it's left out where there is nothing to pin: Zigzag's own pages, a new tab and private windows. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#437](https://github.com/ZigaoWang/zigzag/issues/437))
- Capture works like Arc's. File › Capture… (⇧⌘2), Capture in Site Controls or the command bar dims the page: point at a part of the page and click to take it, even one that runs past the window, or drag over it to take an area, which you can then move and resize by its corners and sides before pressing Return or Capture. Full Page takes the whole page as ⇧⌘2 did before, and Visible takes what's on screen. Esc or Cancel leaves. The picture is copied right away and shows in a small card in the page's corner with Save, Share and a thumbnail you can drag into another app; Save puts it in your download folder, named after the page and the time. The picture is as sharp as your screen, at any zoom and in a split, and nothing is kept anywhere else, in private windows too. ([#457](https://github.com/ZigaoWang/zigzag/issues/457))
- The sidebar's edge can be dragged while it's out over the page, as it can while it takes room in the window, and the width it leaves is the width every new window starts with, after a restart too; double-clicking the edge puts the usual width back. ([#431](https://github.com/ZigaoWang/zigzag/issues/431))
- Your Zigzag Card is in Zigzag › About Zigzag: a card with your name and the day you started using Zigzag. Under it you pick its finish: your space's color, Holographic, Graphite or Paper, the chosen one ringed in the accent color, and Zigzag keeps your choice. The card turns toward the pointer with its light following, and a click turns it over. Save as Image… makes a sharp picture with a soft shadow on a clear background, and Share… opens the Mac's share menu. It's made on your Mac, and nothing is sent unless you share it.
- Reader has a Space color. The article takes the colors of the space you're in, the same color as the sidebar, light or dark as the space is, with text and links kept dark (or light) enough to read easily. It changes right away when you switch spaces or change the space's color. ([#455](https://github.com/ZigaoWang/zigzag/issues/455))
- Peek is now Zigzag Mini: shift-click a link (or Open Link in Zigzag Mini) and it opens in a Mini over your window, the same as links from other apps; ⌘O moves it into a tab next to where you clicked, Esc closes it. It opens in the page's own space and profile. From a private window it's private too: it says Private at its top and is never saved to History. Open Link in Peek in a link's menu is now Open Link in Zigzag Mini, and the getting-started guide's shift-click step shows Zigzag Mini.
- On launch can start fresh: Pick Up Where You Left Off is the default, and Start Fresh opens one new window, keeps the previous session for History › Reopen Last Session (with its back and forward history), and doesn’t save the new session until a page actually loads. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#433](https://github.com/ZigaoWang/zigzag/issues/433))
- Translating works as in Chrome and Safari. The offer on a page in another language has a … menu with Always Translate (the language), Never Translate (the language) and Never Translate This Site. On a page in another language, a translate button in the address bar opens the same choices, with Translate or Show Original; it stays pressed while the page is translated. Settings › Translation lists the languages you always or never translate and the sites you never translate, each with Remove; with no language to always translate yet, it points to the translate button. A private window never saves a site to the list: Never Translate This Site there lasts until the window closes.
- New spaces start in Slate, a clear, light glass with the desktop showing through, nearly white with a barely cool tint on a light Mac and deep slate on a dark one. The space editor has seventeen glass colors beside solid white: neutral Slate, Stone and Smoke; Mist, Dew, Shell and Orchid, near-white glass with just a faint tint; cool Azure, Navy, Seafoam, Pine and Fern; warm Citron, Coral and Red; and Iris and Pink. All but Smoke and Navy are light tints of clear glass, so the desktop stays plainly in view instead of under a gray haze; Smoke and Navy keep the window dark with light text, and Citron and Coral keep it light. A few have a finish of their own: Stone a fine linen texture, Smoke and Coral a light grain. Iris, Coral and Navy get a little deeper toward the bottom. Your spaces keep the colors they have now. A space in one of these colors from an earlier 0.9.4 beta moves to its clearer version; for the earlier betas' other colors, Use Default Colors gives the nearest new color.
- A site that turns Zigzag away can be told it's in another browser. User agent in Site Controls offers Default, Safari, Chrome and Firefox, or Custom… to type one, and the page reloads with it. It covers the site's subdomains, its Zigzag Mini pages, installed apps and pop-ups, and Settings › Privacy › Sites lists it with a × to remove. ([#392](https://github.com/ZigaoWang/zigzag/issues/392))
- Mute Tab is always in a tab's menu in the sidebar, and in a pinned page's or favorite's while it's open, so a tab can be muted before it plays anything. It stays muted as you go to other pages in it, reload it or it goes to sleep. Thanks to [bkonia](https://github.com/bkonia). ([#490](https://github.com/ZigaoWang/zigzag/issues/490))
- Settings › General has Install updates automatically, on by default. Turn it off to stay on the version you have. Zigzag still checks, and a new version shows on the update card as available: Update downloads it and restarts into it, and Skip stops offering that version until a newer one comes out. Check for Updates… still finds a skipped version. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#492](https://github.com/ZigaoWang/zigzag/issues/492))
- Zigzag works with a touch display and with Sidecar on an iPad. Touch and hold a tab, a folder, a space or the empty sidebar to open its menu. Tapping links that open a new window works like clicking them, and tapping outside a panel or menu closes it. A tap on a row shows its × and other buttons that otherwise only appear under the pointer. The strips that resize the sidebar and split panes, and a row's ×, also answer a finger just beside them. The mouse and trackpad work exactly as before.
- More of Zigzag works by touch. Touch and hold a tab, folder, favorite or space, then slide onto its menu and lift on an item to choose it, or lift elsewhere to keep the menu open. Move away from the menu instead and the tab is picked up, to reorder it, drop it in a folder, onto another tab or the page for a split, or onto a space. Swipe one finger sideways across the sidebar to change spaces, pinch in on a page to see all tabs (pinch out on one to open it), and swipe two fingers sideways on a page to go back or forward. The mouse and trackpad work exactly as before.
- Dragging a tab or a pinned page over the page shows a clearer preview: the half or quarter it would take is shaded in the space's accent, with a card naming the page and where it opens, like Open on the Left. The card keeps out from under the pointer or your finger, the shading glides between places, and it fades away when you drag back off the page. Dragging a page of a split by its strip shows the same.
- On a touch display you can drag a page of a split by its strip with your finger, to move it to another place in the split or out to the sidebar, as with the mouse.
- Two taps with a finger on the top of the window, the sidebar's empty space or the bar above the page zoom the window, as a double-click does there (or whatever the Mac's title bar double-click is set to). Two taps in the empty tab list open a new tab, as a double-click does.
- On a touch display, two fingers sideways across the sidebar change spaces too, as one does.
- On a touch display, swipe in with one finger from the edge of the window to pull out a hidden sidebar. Let go a third of the way out, or flick it, and it stays until you tap the page, pick a tab or swipe it back from the page; otherwise it slides back. This works in full screen too. The sidebar button in the bar above the page also takes a tap just beside it.
- Zapped elements can be shown again one at a time. In Site Controls, the “3 zapped” row opens a list of them, newest first, each with a short name, its selector under it in code type, and × to show it again on the page right away; Restore All is at the end of the list. The name is what the element says about itself when you zap it, like Cookie notice from its label or Sign up for our newsletter from its heading; elements zapped before this, or with nothing to say, are named from their selector, like div.cookie-banner. Settings › Privacy › Sites lists the same elements under Zapped elements, the newest five first, with the same ×. A private window's list is that window's own. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#498](https://github.com/ZigaoWang/zigzag/issues/498))
- On a touch display, while the sidebar is hidden, tap the top corner where the traffic lights live: they show with the sidebar toggle, then fade after a few seconds. Tap the toggle and the sidebar shows in the window, as a click on it does; drag from it and the sidebar follows your finger. In a split view the toggle is a button in the top pane's strip, before Back. Nothing sits over the page otherwise, and the mouse and trackpad work as before.
- On a touch display, tapping an open favorite shows its ×, and tapping the Tabs label shows Clear, as hovering does with the pointer.

### Fixed
- A solid space with the sidebar on hover no longer stutters on a 120 Hz display. The sidebar that slides out on hover is a card of glass, and in a solid space it was made of Liquid Glass; that glass view stays in the window while the sidebar is tucked away, and Liquid Glass anywhere in a window holds the whole window to 80 frames a second on a ProMotion display, so the page stuttered with the sidebar hidden and was smooth with it shown. The sidebar now slides out in frosted glass there, as it does in a frosted space, which looks the same and keeps the display's full rate. A clear space still slides it out in Liquid Glass. ([#394](https://github.com/ZigaoWang/zigzag/issues/394))
- A split favorite's × no longer covers a page's icon. It sits on the tile's corner and unloads all its pages.
- Open in (⌘O) in Zigzag Mini brings Zigzag forward with the page, in a browser window on the desktop you're on when there is one. It used to leave the window behind other apps or on another desktop.
- Pointing at a split view's row in the sidebar no longer shows the Mac's gray tooltip with a page's title. Zigzag's own hover card shows its pages instead.
- Settings says less: lines under a label that only repeated it are gone, the lines that stay carry a consequence or a warning, and choices that asked the same question in different words now use one. Extension Site Access says On Click. ([#448](https://github.com/ZigaoWang/zigzag/issues/448))
- The address field no longer shows the star where there is nothing to pin: on Zigzag's own pages (Settings, History, the archive), a new tab and private windows. It used to sit there dimmed, and the pins beside it now take its place. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#442](https://github.com/ZigaoWang/zigzag/issues/442))
- A theme from the Chrome Web Store or Firefox Add-ons, or a theme folder picked with Install from Folder, isn't installed. Zigzag doesn't use browser themes, so it says that and points to a space's colors, where it used to add the theme as an extension that did nothing. Add on the bar over a store theme ends with that one line, without a Try Again that could only fail the same way. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#454](https://github.com/ZigaoWang/zigzag/issues/454))
- Translating a long page no longer gives up after 45 seconds. The text on screen is translated first and each part appears as soon as it's ready, the toast shows how far along it is, and it only stops with an error when nothing has come back for 45 seconds. Thanks to [orisred](https://github.com/orisred). ([#465](https://github.com/ZigaoWang/zigzag/issues/465))
- The traffic lights and the buttons beside them sit midway between the top of the window and the address field, with as much room above them as below, instead of lower down.
- To help fix the Mac's Passwords list on macOS 26, Zigzag keeps a small log of its steps on your Mac, never your logins, in ~/Library/Logs/Zigzag/passwords.log. Help › Report a Problem includes it. ([#378](https://github.com/ZigaoWang/zigzag/issues/378))
- A swipe back or forward no longer fills its arrow partway and then empties it when your fingers stop. The arrow now fills only once you've swiped far enough, and with your fingers resting it stays exactly as it is. A quick flick let go while your fingers are still moving still goes back or forward. Thanks to [frarees](https://github.com/frarees). ([#377](https://github.com/ZigaoWang/zigzag/issues/377))
- In the space editor, a color swatch no longer grows under the pointer; a faint ring shows instead, as in Reader. ([#455](https://github.com/ZigaoWang/zigzag/issues/455))
- In Show All Tabs, a fine line shows under the search field while cards are scrolled under it, instead of the cards being cut off there. ([#458](https://github.com/ZigaoWang/zigzag/issues/458))
- What's New shows a fine line above its buttons while there are more notes below, and under its title once you've scrolled, instead of the notes being cut off there. ([#458](https://github.com/ZigaoWang/zigzag/issues/458))
- The close button in the find bar, and every other ✕ button, sits level with the buttons beside it instead of half a point low. ([#458](https://github.com/ZigaoWang/zigzag/issues/458))
- While an update downloads, its card in the sidebar keeps the same margin on the right as on the left. ([#458](https://github.com/ZigaoWang/zigzag/issues/458))
- The yes-or-no steps in the welcome window sit in the middle of the window, with no large empty gap above the buttons at the bottom. ([#458](https://github.com/ZigaoWang/zigzag/issues/458))
- Scrolling is smooth on a 120 Hz display on heavy pages, like GitHub when you're signed in. Since 0.9.3 beta 4, pages were made to draw up to 120 times a second; a heavy page can't finish drawing every 8 ms, so its scroll moved at an uneven mix of 60 and 120 steps a second and stuttered, where a light page kept up. Pages now draw as WebKit and Safari have them, steady at 60 while the scroll itself still moves at the display's full rate, which measures as smooth on the same page. Settings › Developer › Feature Flags › Prefer Page Rendering Updates near 60fps, off, brings the full drawing rate back. Thanks to [FammasMaz](https://github.com/FammasMaz). ([#394](https://github.com/ZigaoWang/zigzag/issues/394))
- The full-screen traffic lights come down with the menu bar without a gray bar of their own when the bar or sidebar is under them, and get a backing only when the page is. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#469](https://github.com/ZigaoWang/zigzag/issues/469))
- Translate Page works in Zigzag Mini, from the View menu or the page's right-click menu, with its notices over the Mini.
- OldTwitter's icons and fonts show on x.com: the extension's own files are now read at Zigzag's address, which the site's security policy allows, so its icon font, loading picture, list icons and tab icon appear instead of empty squares. A video inside a quoted tweet plays where it is and its controls play and pause it, and a click elsewhere on a quoted tweet opens only its own view. Thanks to [datarip](https://github.com/datarip).
- Zigzag no longer quits when you click without dragging while capturing an area.
- ⇧⌘C copies the page's link on every site, as in Arc. On a file page on GitHub, which uses the same keys to copy the file's raw text, it copied the file instead.
- With Ask before quitting on, only the Quit shortcut asks, as in Chrome: ⌘Q, or the keys you gave Quit Zigzag in Settings › Shortcuts. Choosing Quit Zigzag in the menu, or Quit in the Dock, quits right away. Quitting while files download still asks. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#441](https://github.com/ZigaoWang/zigzag/issues/441))
- Zigzag's own pages, like Settings, History and the archive, can't be dragged into Pinned, onto a pinned folder or page, or into Favorites, as ⌘D and the star already refused them. The tab stays where it was. Pin Tab and Add to Favorites aren't offered for them in the tab's menu or the command bar either. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#472](https://github.com/ZigaoWang/zigzag/issues/472))
- Lots of favorites no longer push the space's name over the bottom of the sidebar and hide your tabs. The favorites take at most half the sidebar's height, and past that they scroll in place, also while you drag a tab or favorite near their top or bottom edge.
- The same buttons look the same in more places. In the icon choices, Choose Image… and Use Site Icon are the soft pill buttons other panels use, their words lined up with the search field's. In Settings › Downloads, a rule's or file type's trash shows while you point at its row, as it does for extensions and profiles. The menu that fills in passwords highlights the row you're on as Zigzag's other menus do.
- Split views of three and four pages can be pinned and come back whole: every page, in the places you left them, when you open the pin, after a relaunch, when you unpin it and with ⌘Z. A pinned split's row looks and works the same as in the tab list: each page in it has its own ×, as in a split of tabs, which unloads only that page. Remove from Split View takes one page out of a pinned split of three or four, and the menus say Pin Split View and Unpin Split View for every size.
- A pinned split grows and comes apart by dragging, as a split of tabs does. Drop a tab or a pinned page on the left or right half of its row and it joins as a third or fourth page, the half it would take lit while you hold it there; at four pages the row only moves. Drag one page out by the strip above it: let go among the pinned pages and it stays pinned on its own there, let go among the tabs and it's a tab. The rest stay a pinned split, or one pinned page if only one is left. ⌘Z takes back each step.
- More of Zigzag looks and works the same way everywhere. The command bar's chosen result has the same soft wash as Settings. A space rule's match-type help opens in Zigzag's own panel and closes with Esc or a click outside. Show All Tabs' search shows the accent ring while you type, like every search field. A search that finds nothing says so in one line, "No tabs match “x”." and the like, in the same place in Settings, Show All Tabs, the icon grid, Passwords, History and the archive. The tour, the welcome, Import, the password menu and Show All Tabs use the same buttons as the rest of the app, and the password menu's highlight glides between rows like every other menu's.
- With Ask before quitting on, ⌘Q asks on a keyboard layout without Latin letters too, like Russian or Greek, where it quit at once. ([#441](https://github.com/ZigaoWang/zigzag/issues/441))
- An extension with access to a site reaches it when it sends its own headers without cookies, as password managers for a self-hosted server like Litewarden do with Vaultwarden. Zigzag sends such a request for it, without your cookies, where it used to fail because the server sent no CORS headers. Thanks to [Kronight](https://github.com/Kronight). ([#478](https://github.com/ZigaoWang/zigzag/issues/478))
- In full screen, dragging an empty part of the sidebar, the bar above the page or the strip over a split page no longer moves the window. In a window it still does. Thanks to [liverHawk](https://github.com/liverHawk). ([#483](https://github.com/ZigaoWang/zigzag/issues/483))
- Starting Zigzag with an extension that runs a large script on many sites, like uBlacklist, no longer fills gigabytes of memory and swap. WebKit kept a copy of the script for every site it runs on, in every page and extension process, up to 17 GB for uBlacklist's 1 MB script and its 193 Google sites. Zigzag now has WebKit keep one copy of each script, as Safari does. Thanks to [Kronight](https://github.com/Kronight). ([#485](https://github.com/ZigaoWang/zigzag/issues/485))
- On macOS 26, picking a login in the Mac's Passwords list should fill the username as well as the password. macOS 26 filled only the hidden password field Zigzag lays over the page, never the username field beside it, so Zigzag now uses the same kind of field for both, and waits a moment for a username that arrives after the password. If only the password comes back, the cursor is left in the empty username field, ready to type. Thanks to [frarees](https://github.com/frarees). ([#378](https://github.com/ZigaoWang/zigzag/issues/378))
- Text that shows up more than once on a page, like a menu repeated in the header and footer, is translated once, and text already translated goes straight in until you quit, so a site's next pages translate sooner. Thanks to [orisred](https://github.com/orisred). ([#465](https://github.com/ZigaoWang/zigzag/issues/465))
- Zigzag offers to translate each page in another language, not just the first one on a site. Closing the offer with its × stops it for that site while the window is open.
- After a translated page loads again, Translate translates it instead of acting as Show Original.
- The address bar's translate button is in the accent color while a page is being translated.
- A pop-up from a window kept on top opens over it, kept on top too, instead of behind it. From Zigzag Mini over a full-screen app, it opens over that app.
- A pop-up a page opens right after you click or press a key in it opens at once instead of asking where to go, in Zigzag Mini too. A page you went to doesn't count a click on the page before it.
- Extensions that manage sessions or tabs see the tabs and windows you closed. With the sessions permission, an extension gets the ones History › Recently Closed brings back, newest first, and can reopen one the same way; private windows' never show. ([#486](https://github.com/ZigaoWang/zigzag/issues/486))
- Extensions are told when the pins in a folder or space are put in a new order all at once rather than one moved, and when a browser import starts and finishes adding bookmarks, so they can wait for it instead of reacting to every new one. ([#487](https://github.com/ZigaoWang/zigzag/issues/487))
- An extension that messages a tab where its content script isn't running yet now gets Chrome's "Could not establish connection. Receiving end does not exist." error, so it can inject the script and try again, instead of getting no answer and waiting. A message from a content script or extension page that nothing in the extension listens for fails the same way. A message that a listener heard but didn't answer still comes back empty, without an error. ([#475](https://github.com/ZigaoWang/zigzag/issues/475))
- A `chrome-extension://` address opens that extension's page, as in Chrome: typed in the address bar, opened by the extension itself, or followed from one of its own pages, like Hotspot Shield's welcome and settings pages. One for an extension that isn't installed says so at once instead of waiting on a blank tab, and a website's link to one still goes nowhere. ([#475](https://github.com/ZigaoWang/zigzag/issues/475))
- A Firefox extension (.xpi) that asks to set a proxy, like a VPN built for Firefox, now says in its install sheet and in Settings › Extensions that setting a proxy with Firefox's proxy API won't work in Zigzag. Zigzag has nothing to run that API on, so such an extension can't send pages through its servers here. ([#475](https://github.com/ZigaoWang/zigzag/issues/475))
- A request an extension sends with bytes in its body and no type of its own, which Zigzag sends for it to keep a site's cookies or get past CORS, no longer goes out marked as form data. It carries the type the extension's request had, as in Chrome, so a server that reads the type doesn't take raw bytes, like a protobuf sign-in, for a form. ([#475](https://github.com/ZigaoWang/zigzag/issues/475))
- An extension that asks for a site while you use it, like uBlacklist when you add a subscription or turn on ruleset links, asks you first in Zigzag's sheet, as Chrome does. Allow gives it the site, after a restart too, and Don't Allow tells it no. It used to be told no without asking, so its buttons did nothing. Thanks to [Kronight](https://github.com/Kronight). ([#489](https://github.com/ZigaoWang/zigzag/issues/489))
- Importing from Arc keeps split views you pinned as split views, at the top of Pinned and inside folders, instead of separate pages. Pages in folders nested deeper than eight levels go in the eighth one instead of being left out. Importing again makes split views of pages an earlier import brought in, when they're still next to each other in one folder; pages you moved stay where they are. Thanks to [evannotfound](https://github.com/evannotfound). ([#391](https://github.com/ZigaoWang/zigzag/issues/391))
- A page that was still loading when the Mac switched to dark, or when its site's Dark page choice changed, now comes up in the new look. It used to stay light until you reloaded it or clicked a link, because the change never reached a page opening a new site.
- Watch on YouTube in a video embedded on another site opens in the space you chose for YouTube, as a link to it does, instead of in the space you're in. The same goes for other embeds' links that open a new tab, while a page's own pop-ups still stay with it. Thanks to [retorquere](https://github.com/retorquere). ([#286](https://github.com/ZigaoWang/zigzag/issues/286))
- Going back to a space no longer starts its YouTube video playing out loud. A tab that loads again on its own, because it had gone to sleep, its page had stopped, or it came back after Zigzag reopened, now waits for you to press play before anything with sound plays, as in Safari and Chrome. A page you open yourself still plays on its own, and one already playing keeps playing as you switch away and back. Thanks to [retorquere](https://github.com/retorquere). ([#493](https://github.com/ZigaoWang/zigzag/issues/493))
- Swap on a split's strip moves the two pages on screen right away. Before, only the sidebar row swapped until you clicked somewhere, so a click on one pane could pick the other page, and ⌘F opened the find bar over one pane while searching the other.
- Settings › General › On launch reads like the rest of Settings: Continue where you left off, or Open a new window. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#494](https://github.com/ZigaoWang/zigzag/issues/494))
- A link in an installed app like Gmail that opens a new tab goes to the browser instead of replacing the app, also when the site sends it through its own redirect page first. Links to the app's own pages still open in the app. Thanks to [retorquere](https://github.com/retorquere). ([#165](https://github.com/ZigaoWang/zigzag/issues/165))
- A tab restored after a restart, or woken from sleep, shows the site's page as it is now. It came back as Zigzag last loaded it, however long ago, so a site whose theme or sign-in had changed since, like GitHub set to its dark theme, showed its old look until you reloaded.
- Carrying a tab just past the sidebar onto the page no longer flips to the next space while the page is offering to open it there.
- With Settings › Tabs › Show a mini player when you leave Zigzag on, a video stays in its page when you move to another display and its window is still in view on its own. It moves into the mini player once that window is covered, minimized, hidden or its desktop is switched away. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#496](https://github.com/ZigaoWang/zigzag/issues/496))
- The address no longer flashes a cut-off name, like “…eloper.apple.com”, when you switch spaces or tabs and the new page has fewer buttons in the address bar.
- Two taps with a finger on a tab, a space's dot or the sidebar's edge do what a double-click does there: rename the tab, edit the space, put the usual width back.
- The translate button no longer shows on pages in a language or on a site you set to Never Translate. View › Translate Page still translates one when you want to.
- When a site opens a pop-up by itself, like a Sign in with Google window, the filled answer on Zigzag's question now opens it where it says in one click, and so does Return. Before, it only opened a list, so you clicked twice even for the choice it showed. The other places are in the menu from the arrow beside it, still one click away.
- View › Separate Tabs is now ⌃⌘\, so it no longer clashes with 1Password, which uses ⌥⌘\ everywhere. A key you set yourself in Settings › Shortcuts stays as it is.
- Every tab's, pinned page's and space's menu in the sidebar shows its keyboard shortcuts, not only the menu of the one you're on.
- Wording is the same across the app: Site Controls keeps its capitals in every sentence, the getting-started guide says choose for menu items, and the last straight apostrophes are curly. In Chinese, Choose, Custom, App and Site Controls read the same everywhere.
- Menus and buttons agree on names and keys: Copy Link, Unpin Tab and Move to Tabs show their keys on pinned pages and favorites, Close shows ⌘W on picked rows, Site Controls and Zigzag Mini's tooltips and note follow the keys you set in Settings › Shortcuts, the command bar says Settings… as the menu bar does, and Pin Tab in the menu bar is dimmed on pages that can't be pinned.
- What the address bar and menus show stays in step however you make a change. The pin star shows a pin or unpin made from a tab's menu, by dragging or with ⌘Z. File › Pin Tab and Pin Tab to Folder… are off on Settings and History, where the star isn't shown. The Reader button stays pressed while Reader is open over the other page of a split. A shortcut you change in Settings shows in the buttons' tooltips right away, in Zigzag Mini too. Always or Never Translate chosen in one window updates the translate button in the others and Settings › Translation. Settings › Privacy lists a site's choices as soon as Site Controls closes. A tab in a group that has Settings in it can still be added to Favorites from its menu.
- Scrolling a PDF could make Zigzag quit when the edge of a page came into view by a hair. Thanks to [ldhieu](https://github.com/ldhieu). ([#507](https://github.com/ZigaoWang/zigzag/issues/507))
- A split view's menu in the sidebar says Separate Tabs, as the View menu and the command bar do, instead of Separate Split View.

## [0.9.3] - 2026-11-21

Links from other apps open in Zigzag Mini, a site can have an icon of its own, a calmer space editor, an update card that shows its progress, every site choice editable on its own row, Open All in Tabs for pinned folders, cookies you can keep when clearing, space rules for paths of a site, Suspend Page, Check for Updates for extensions, extensions in private windows when you allow them, Firefox extensions, address bar keywords for extensions, tiles you can resize freely, pinning a page from its address, Zigzag's own right-click menus in the sidebar, and fixes for split views, closing and reopening tabs as in Chrome, smooth scrolling at 120 Hz, the Passwords list, tab keys, extension site access, full screen, passkeys, Proton Pass, Passbolt, ⌘-clicks on YouTube, pinned groups, Find on GitHub and more.

### New
- A download rule that runs a script shows it on the page: Running script while it works, then Ran script or Script failed with the script's last line, so a rule never runs out of sight. A rule that hands a link to an app, a download manager or your default browser says so once per session, after it worked. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#307](https://github.com/ZigaoWang/zigzag/pull/307))
- A site can have an icon of its own. Change Site Icon… in Site Controls' ⋯ menu opens the same icon choices as a tab's, with symbols, emoji and Choose Image…, and every tab, pinned tab, favorite and history row on the site shows it. A tab's own icon still wins, and Use Site Icon puts the site's icon back. Settings › Privacy › Sites lists it to forget, and in a private window it lasts until the window closes. Thanks to [bkonia](https://github.com/bkonia). ([#310](https://github.com/ZigaoWang/zigzag/issues/310))
- Settings › Privacy › Sites shows each choice made for a site on a row of its own, with the same control as in Site Controls and a × that forgets just that one, instead of one sentence and a single Forget. JavaScript and Extensions now sit on Site Controls' Permissions page beside the camera and the rest, and turning extensions off for a site is kept per profile. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#311](https://github.com/ZigaoWang/zigzag/issues/311), [#312](https://github.com/ZigaoWang/zigzag/issues/312), [#313](https://github.com/ZigaoWang/zigzag/issues/313), [#314](https://github.com/ZigaoWang/zigzag/issues/314))
- The space editor is simpler. One row of swatches holds Default (the colors the space was made with), six presets, the space's background picture and Custom, which opens the color wheel and Shade below it when you want a color of your own. Effects sits under the row, and Profile moves to the bottom as one row, with what profiles do in its tooltip. Background is a swatch now: click it to choose a picture, and the × on its corner takes the picture off.
- Settings › Extensions has each extension's Site access under its row: On All Sites, When You Click It or On Specific Sites, with the sites listed to add and remove. It's the same choice as Site Access in the extension's menu by the address. Thanks to [git-bhanu](https://github.com/git-bhanu). ([#324](https://github.com/ZigaoWang/zigzag/issues/324))
- Raindrop.io and other extensions that ask for sites only when they need them work once you choose On All Sites in their Site Access. That choice gave them no sites at all, so their requests to their own servers were blocked and Raindrop looked broken or signed out. Until you choose it, the menu no longer shows it as chosen. Thanks to [git-bhanu](https://github.com/git-bhanu). ([#324](https://github.com/ZigaoWang/zigzag/issues/324))
- AI apps can see a page the way a screen reader reads it, with `snapshot`, and act on what they find by ref: each link, button, field and menu has a short ref like `e12` that `click`, `type`, `scroll` and `press_key` take, rather than a guessed CSS selector. A ref stands for one element as it was, so when the page changes it or loads again, the app is told to look again instead of clicking something else. Snapshots only have what shows on the page: text a page hides from you is left out, a button is named by what it shows (or by its label, when all it shows is a sign like ×), links to other sites and words mixing alphabets are marked, and the page's words are quoted so they can't pass for Zigzag's. A click is refused when something covers what it's aimed at, as a cookie banner would for you, and `type` and `press_key` no longer use a field that's disabled or that the keyboard can't reach. No tool gives a card's details, a one-time code or the like any more, by the same rules Zigzag uses to never keep them for a sleeping tab, and what your saved details filled in is given only as filled until the app types it itself. ([#214](https://github.com/ZigaoWang/zigzag/issues/214))
- A pinned folder's right-click menu has Open All in Tabs, which opens every pinned tab in it and the folders inside it, in order, and shows the first. Past 10 it asks first, and ⌘Z closes them again. A folder with folders inside has Expand All and Collapse All too, for the whole tree at once. Thanks to [mrfragger](https://github.com/mrfragger). ([#343](https://github.com/ZigaoWang/zigzag/issues/343))
- Keep cookies for the sites you choose. Clear Cookies… signs you out of every other site and leaves these alone, and Clear cookies when Zigzag quits in Settings › Privacy clears the rest each time you quit. Turn on Keep cookies in a site's controls, or add a site in Settings › Privacy; one entry covers http, https and every subdomain. Thanks to [mrfragger](https://github.com/mrfragger). ([#334](https://github.com/ZigaoWang/zigzag/issues/334))
- A shortcut with the Hyper key (⌃⌥⇧⌘ together) shows one ✦ keycap instead of all four, in Settings › Shortcuts, the command bar and while you record one. Searching Settings for "hyper" finds them. Thanks to [JonasNowak](https://github.com/JonasNowak). ([#352](https://github.com/ZigaoWang/zigzag/pull/352))
- Pin a page from the page itself. A star at the right end of the address field pins the page you're on at the end of the space's Pinned pages, and is filled while the page is pinned; clicking it again unpins it, as ⌘D does. A link's right-click menu has Pin Link under the Open Link items, which pins the link without opening it, named after the link's text. Hold ⇧ on the star, on Pin Link or on a tab's Pin Tab, or press ⇧⌘D (File › Pin Tab to Folder…), to choose the top of Pinned, a folder in that space or a new one, and the page's name. A tab group or a split view pins and moves as one: the picker says Pin Group or Pin Split View, and a group goes into a folder as its own folder, with all of its tabs. The Pinned toast has a star in place of the pin and a menu to move the page to a folder, the top of Pinned or Favorites, or to unpin it; it moves the page in the space it was pinned in, even after you switch spaces, and ⌘Z takes each move back. Pin Link isn't in private windows, where nothing is pinned. The command bar's pin commands show a star too. ([#326](https://github.com/ZigaoWang/zigzag/issues/326))
- Different paths of one site can open in different spaces, like github.com/org1 in Work and github.com/org2 in Personal. Settings › Spaces lists the rules top to bottom and the first one that matches wins. Click a rule to edit it, right-click to turn it on or off, or drag it to change its priority. If one rule covers another, both show a warning. Paths ignore case. An address can be typed with a port, like localhost:3000, and the rule covers the site on every port. The sites you had become rules that open in the same spaces as before. Thanks to [pyoio](https://github.com/pyoio). ([#289](https://github.com/ZigaoWang/zigzag/issues/289))
- Sidebar size in Settings › Appearance has a Custom choice: pick it, then set the sidebar from 80% to 150% with − and +, or press the percentage to go back to 100%. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#361](https://github.com/ZigaoWang/zigzag/issues/361))
- The prompt to open an app says who's asking ("app.slack.com wants to open the Slack app."), with Cancel and Open Slack at the right and an Always allow checkbox instead of the This time menu. Other site questions use a Remember for this site checkbox the same way, and their buttons stack in a narrow window instead of getting cut off.
- The sidebar's right-click menus are shorter and in the same order everywhere. What only that row has comes first: Back to Pinned Page and Set Current Page as Pinned when a pinned tab has moved on from its page, and Separate Split View on a split, with Remove from Split View for one page of three or four. Then the page, where it's kept, where it's shown, its name and icon, and closing last. Move To holds New Window, Zigzag Mini and your spaces in one list, Add to Group and Add to Folder start with New, items that would do nothing are left out instead of dimmed, and the tab you're on shows its shortcuts. Right-clicking one half of a split row gives that page's menu. Translate is in View › Translate Page, Site Controls and the page's menu instead of the tab's. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#327](https://github.com/ZigaoWang/zigzag/issues/327))
- A site installed as an app has Site Controls at the right end of its toolbar, as in Zigzag Mini. It opens the same panel as in a browser window, for the app's page: its permissions, its switches, zoom and dark page, its extensions and the ⋯ menu with Clear Cookies and Data. What you choose is the site's, so its tabs in browser windows follow it too. An extension's popup still opens from a browser window, so clicking one here shows its menu. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#356](https://github.com/ZigaoWang/zigzag/issues/356))
- Extensions can run in private windows when you let them. Turn on Allow in private windows under an extension in Settings › Extensions; it's off for every extension until you do. An extension you allow there works in private windows as in others, and sees their tabs and downloads; the rest still see nothing of private browsing, and private windows still keep no history. ([#353](https://github.com/ZigaoWang/zigzag/issues/353))
- Collapse All Folders and Expand All Folders fold every pinned folder in a space at once. They're in the space's right-click menu, above its pinned tabs, and in the View menu. Thanks to [mrfragger](https://github.com/mrfragger). ([#343](https://github.com/ZigaoWang/zigzag/issues/343))
- Pop-up windows have Copy Link and Open in New Tab beside Keep on Top. Open in New Tab, or ⌘O, opens the page as a tab in the window that opened it, in a space of the profile it was signed in with, and closes the pop-up; a sign-in pop-up stays a pop-up unless you move it. Clicking the address selects the whole of it to copy, and right-clicking it gives Copy Link. Reload, Find, Zoom, Back and Forward, ⇧⌘C and the Web Inspector work in pop-up windows too.
- Settings › Appearance has a Sidebar position menu with Left and Right, in place of the Sidebar on the right switch, so it says which side the sidebar is on. View › Move Sidebar to Right and Left work as before. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#360](https://github.com/ZigaoWang/zigzag/issues/360))
- Each installed app in Settings › General has an Open button before Show in Finder. It opens the app as its Dock icon does, and brings its window forward if it's already open. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#355](https://github.com/ZigaoWang/zigzag/issues/355))
- The sidebar's edge and the lines between split pages are easier to catch: the pointer takes them, and shows the resize pointer, a few points to either side of the line, across the empty strip beside the sidebar's rows too. Less of the band reaches over a page's scroll bar, and the line moves from where it is instead of jumping to the pointer. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#362](https://github.com/ZigaoWang/zigzag/issues/362))
- Suspend Page in a tab's right-click menu, and File › Suspend Page for the tab you're on, puts its page to sleep the way Zigzag does on its own: the page is let go, where you were on it is kept, and clicking the tab loads it again. With several tabs picked it says Suspend 3 Pages. A page playing sound, in a call, in the mini player or holding text you typed stays awake and a note says why. The tab gets the dotted ring of a sleeping tab, and its hover card says you put it to sleep. Suspending the tab you're on takes you to the one you were on before, and one page of a split leaves the split while you stay on the other. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#342](https://github.com/ZigaoWang/zigzag/issues/342))
- Settings › Extensions has a Check for Updates button. It checks every extension from the Chrome Web Store now instead of waiting for the daily check, and says what came of it: all up to date, how many were updated, or how many couldn't be checked. An update that asks for more access waits for you as before, and when there's one, its review opens. ([#406](https://github.com/ZigaoWang/zigzag/issues/406))
- Settings › Tabs › ⌃Tab switches to chooses what Control-Tab does: Recent Tabs, the switcher of the tabs you used last, as before, or Next Tab in the Sidebar, which goes down the sidebar as in Chrome, with ⌃⇧Tab going up. ([#403](https://github.com/ZigaoWang/zigzag/issues/403))
- Firefox extensions install from a file: choose an **.xpi** in Settings › Extensions › Install from File…, the button that was Install from Folder… (folders still work). An add-on gets WebKit's own `browser` API, the same one Chrome extensions use, plus Firefox's `runtime.getBrowserInfo`. Firefox-only APIs, like containers, aren't there. Firefox extensions don't update on their own. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#277](https://github.com/ZigaoWang/zigzag/issues/277))
- Add to Firefox on addons.mozilla.org installs the add-on: Zigzag checks the file against the sha256 the store publishes, then shows the usual install sheet. Adding a newer version the same way replaces the one you have. To get that button, addons.mozilla.org pages are asked for as Firefox, whatever user agent you chose for them. An .xpi from any other site still downloads as a file. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#414](https://github.com/ZigaoWang/zigzag/issues/414))
- A site you allow can reach a program listening on this Mac, like the local agent an editor, a download helper or a companion app runs. Chrome and Firefox allow `http://localhost` and `ws://localhost` from a secure page; WebKit refuses it as mixed content, so Zigzag makes the request itself, as the site, and hands the answer back. It is off until you turn on Settings › Privacy › Allow websites to reach apps on this Mac and then the site's own Apps on This Mac switch in its Site Controls; nothing on the web can ask for either. Extensions reach programs on this Mac as they did before. With the setting on, each extension also gets an Apps on This Mac switch in Settings › Extensions, off by default, that lets its `http://localhost` requests through even without access to that address. Loopback only: not the local network, not another machine, not the ports browsers block, like 25 for mail, and not images, scripts or stylesheets. ([#321](https://github.com/ZigaoWang/zigzag/issues/321))
- In a split view of three or four pages, drag where the lines between the pages meet to resize both ways at once; the pointer shows the diagonal resize arrows there. In a grid of four, hold ⇧ while dragging the line between the columns to move only the part beside the pointer, so the top pages can split their width differently from the bottom ones. Once parted, each part drags on its own and snaps to the middle when let go near it, and Reset Tile Layout in the page's strip makes the grid even again. Dragging without ⇧ moves the whole line as before, and double-clicking a line still puts it back in the middle. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#316](https://github.com/ZigaoWang/zigzag/issues/316), [#309](https://github.com/ZigaoWang/zigzag/issues/309))
- Extensions' address bar keywords work, like Raindrop.io's "rd". In the command bar, type the keyword and a space or Tab: the extension's name shows in front of the field, what you type goes to the extension, and its suggestions show below. Return hands it to the extension, ⌘Return opens it in a tab behind, and ⌘⇧Return or ⌥Return in a new tab in front. Esc, or Delete with nothing typed, leaves the keyword. If two extensions use the same keyword, the first one installed gets it, and a keyword Zigzag already uses for a site search, like "yt" for YouTube, stays with the site. In private windows, only extensions allowed there have their keyword. Settings › Extensions no longer says the keyword won't work. Thanks to [git-bhanu](https://github.com/git-bhanu). ([#324](https://github.com/ZigaoWang/zigzag/issues/324))

### Fixed
- Pinning a group of tabs keeps the group whole: one pinned folder named after it, with its tabs in their order, instead of one pinned page per tab. Unpinning any of its pages brings the group back. ([#325](https://github.com/ZigaoWang/zigzag/issues/325))
- ⌘-clicking a video on YouTube always opens it in a new tab. Some ⌘-clicks went to the video in the tab you were on, because YouTube's own script followed the link there. Now a ⌘-click on a link opens it in a new tab whatever the page does with clicks. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#317](https://github.com/ZigaoWang/zigzag/issues/317))
- Each PDF opens in a helper of its own, as 0.9.2 meant: the build that shipped had all PDFs share one, so a PDF couldn't be kept apart from the others open at the same time.
- An extension's right-click menu shows its emoji and symbols, like 📋 and ⌘, instead of garbled letters like "ðŸ“‹". An extension with background scripts, as most Firefox add-ons have, had its text read in the wrong encoding. Thanks to [mrfragger](https://github.com/mrfragger). ([#277](https://github.com/ZigaoWang/zigzag/issues/277))
- An extension that turns its side panel on only for the tab you click it on, like ChatGPT's, opens the panel when you click its button, instead of the click doing nothing.
- Links from other apps open in Zigzag Mini by default, like Arc's Little Arc. ⌘O moves the page into a tab, and Settings › Zigzag Mini turns it off. The first time, a short note explains this and offers Use Tabs Instead. ([#246](https://github.com/ZigaoWang/zigzag/issues/246))
- Site Controls has a width of its own instead of the sidebar's, so its rows no longer get cut short or wrap in a narrow sidebar. From the sidebar it reaches past a narrow one over the page, and with the address bar above the page it opens under the address at its usual width. Thanks to [Tuszy42](https://github.com/Tuszy42). ([#335](https://github.com/ZigaoWang/zigzag/issues/335))
- Extensions that need a recent Chrome, like Heylogin, install from the Chrome Web Store instead of being called no longer available: Zigzag told the store it was Chrome 140. Thanks to [datarip](https://github.com/datarip). ([#336](https://github.com/ZigaoWang/zigzag/issues/336))
- Import from a file takes the bookmarks.html every browser exports, from Firefox, LibreWolf, Safari, Chrome and Edge. Its pages come over in a space of their own with their folders, as from a browser on this Mac. Thanks to [mrfragger](https://github.com/mrfragger). ([#330](https://github.com/ZigaoWang/zigzag/issues/330))
- The mini player's arrow back to its tab always does something: it finds the tab in whichever window has it now and brings that window forward, ends the card when the tab is already on screen, and closes the card when the tab is gone. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#333](https://github.com/ZigaoWang/zigzag/issues/333))
- An extension's popup takes focus when it opens, as in Chrome, so its buttons' tooltips and hover effects show right away. Before, they showed only after you clicked in it. When it closes, the keys go back to the page or field you were in. Thanks to [mrfragger](https://github.com/mrfragger). ([#277](https://github.com/ZigaoWang/zigzag/issues/277))
- Find on page marks every match, also text right in a button, a row laid out as a flex box or beside a block, like an author's name in GitHub's issue list. WebKit draws no highlight there, so the match showed for a moment and went; such matches now get a mark of their own. A match the page draws again is marked again within a second. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#329](https://github.com/ZigaoWang/zigzag/issues/329))
- Proton Pass's popup opens at its full size, with your items listed, instead of cut off below its search bar. In a popup, Zigzag answered Proton's check for whether it was open in a tab with the tab you were on, so it sized itself to fit a tab that wasn't there. Thanks to [JonasNowak](https://github.com/JonasNowak). ([#287](https://github.com/ZigaoWang/zigzag/issues/287))
- Proton Pass puts its icon in sign-in fields and offers your logins when you click one. Its script on the page stopped before finding any fields, on a browser function WebKit doesn't have (requestIdleCallback), which Zigzag now gives extensions as Chrome does. Thanks to [JonasNowak](https://github.com/JonasNowak). ([#287](https://github.com/ZigaoWang/zigzag/issues/287))
- An extension's popup lays its icons out as it does in Chrome. Zigzag was making every icon with no width of its own as wide as its row, so an icon beside a heading squeezed the heading to one letter a line, as in Dashlane's menu. Icons now keep the size their page gives them. ([#340](https://github.com/ZigaoWang/zigzag/issues/340))
- A mouse's back and forward side buttons work in Zigzag Mini and in installed apps' windows, not only in the browser window. Thanks to [Tuszy42](https://github.com/Tuszy42). ([#345](https://github.com/ZigaoWang/zigzag/issues/345))
- A password manager extension's passkeys keep working while a page is open. WebKit could let go of the page's passkey object and hand out a fresh one without the extension's hook on it, so a sign-in went to the browser instead of to Bitwarden and the like. Zigzag also steps aside for Strongbox as it does for 1Password and Bitwarden. Thanks to [bkonia](https://github.com/bkonia). ([#344](https://github.com/ZigaoWang/zigzag/issues/344))
- Swiping between spaces changes the window's color as you swipe, blending from one space's to the next with your fingers, and it goes back if you call the swipe off. Before, the color stayed the old space's until your fingers let go.
- Passkeys keep working after a sign-in page offered one in its username field, as GitHub's does. Reloading such a page, or asking for a passkey a second time, could get the request refused, and then every passkey on every site failed with no prompt until you restarted your Mac. If yours are failing now, restart once after updating. Thanks to [vandenbulckjean](https://github.com/vandenbulckjean). ([#348](https://github.com/ZigaoWang/zigzag/issues/348))
- Settings you change in an extension's popup stick. Strongbox's Fill switches showed the setting from before each click and came back the other way when you reopened them, because WebKit could read an extension's storage before an earlier save had finished. Now each extension's saves and reads finish in the order it made them, as in Chrome. Thanks to [bkonia](https://github.com/bkonia). ([#350](https://github.com/ZigaoWang/zigzag/issues/350))
- Dragging a group of tabs by its name up among your pinned tabs pins the whole group as one folder, as Pin Group and ⌘D do. The group's row couldn't be dropped among the pinned tabs at all, so it went back among the tabs. Dragging one tab of a group still pins just that tab. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#325](https://github.com/ZigaoWang/zigzag/issues/325))
- ⇧-clicking a file on GitHub opens it in Peek instead of moving the tab, and ⌥-clicking a link a page follows itself downloads it. A page that uses ⇧- or ⌥-click itself, like selecting a range of rows, still gets the click. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#322](https://github.com/ZigaoWang/zigzag/issues/322))
- The first ⌘, after Zigzag starts opens Settings right away instead of after a few seconds. Opening it read what every section lists, like website data, extensions and installed apps; now a section is read when you first open it or search. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#357](https://github.com/ZigaoWang/zigzag/issues/357))
- With your pinned tabs folded away, the pinned pages that are open show under their folder's name, set in as when unfolded, instead of one by one. A group pinned while they were folded looked like it had split into separate pins; it shows as its one folder now. Folders with no open page stay out of sight. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#325](https://github.com/ZigaoWang/zigzag/issues/325))
- Extensions like YouMind that check your sign-in from their background see you signed in once you sign in on their site, as in Chrome. When an extension asked its site for your account without saying to include cookies, WebKit left out the site's SameSite cookies, which most sign-ins use, so it kept showing its sign-in page.
- YouTube Music installed as an app goes on to the next song while its window is behind other windows or on another desktop. A covered window's page counted as hidden, where the next song can't start, so it stopped at the end of each one. A page playing sound with no video showing now counts as on screen while its window is covered, until it's been quiet for 30 seconds, in browser windows too; a playing video in a covered window is still hidden, so it doesn't keep drawing. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#199](https://github.com/ZigaoWang/zigzag/issues/199))
- With the sidebar hidden, a link you open in a new tab behind the page shows the new tab's own sidebar row instead of a note. It slides out from the sidebar's edge where the tab sits in the list, stays for a moment, then slides back in. Each link gets its own row, even several in quick succession, and the row shows the page's title and spinner as it loads instead of only the site's name. Click a row to go to its tab, or hover to keep them out. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#272](https://github.com/ZigaoWang/zigzag/issues/272))
- The outline on a pinned tab or favorite whose page is loaded is much fainter, a hint instead of a box, most of all in dark mode. Thanks to [drewbeck](https://github.com/drewbeck). ([#351](https://github.com/ZigaoWang/zigzag/issues/351))
- A tab's sound button sits right after its title, a space after the last letter, the size of the text and in its line, instead of at the end of the row where × goes. The speaker stays in the same place muted or playing. It shows only while the page plays sound or is muted, and clicking it mutes or unmutes the page. A favorite shows it as a small badge on its icon's corner.
- Folders from an import start collapsed, so a bookmarks file with a hundred folders is a short list instead of a long scroll. Folders you already had stay as they were. Thanks to [mrfragger](https://github.com/mrfragger). ([#343](https://github.com/ZigaoWang/zigzag/issues/343))
- Open All in Tabs opens a folder's pages as new tabs, where your new tabs go, and they all start loading so each is ready when you get to it. It used to open the pinned tabs in place, which looked like nothing happened. The pinned tabs stay as they are, and ⌘Z still closes the new tabs. Thanks to [mrfragger](https://github.com/mrfragger). ([#343](https://github.com/ZigaoWang/zigzag/issues/343))
- Peek's scroll bar stays slim on Macs that always show scroll bars, instead of a wide gray track along the card's edge. A page that styles its own scroll bars keeps them, and with scroll bars shown only while scrolling, and in tabs, pages keep the Mac's own, as in Safari.
- The page under Peek no longer reacts to the pointer while Peek is open. Moving over the card hovered links and started video previews on the page beneath it, and the link shown at the bottom could be that page's; now only the page in Peek sees the pointer, as in a tab. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#374](https://github.com/ZigaoWang/zigzag/issues/374))
- Swiping sideways on a page you've zoomed into with a pinch, or one that's a little wider than the window, scrolls it instead of going back or forward. A swipe only goes back or forward when it starts with the page already at its edge, as in Safari. Going back or forward also takes a longer swipe now, or a quick flick, and the arrow's ring fills as you swipe, all the way once letting go would go, so you can stop or swipe back before letting go. Thanks to [frarees](https://github.com/frarees). ([#377](https://github.com/ZigaoWang/zigzag/issues/377))
- A page's own Print button works in pop-up windows, like the one on an Apple Store invoice, and ⌘P prints in pop-up windows, Zigzag Mini and installed apps too. Pop-up windows didn't answer the page's request to print, and File › Print had nothing to print in those windows, so it only beeped.
- Passwords… in the password menu opens the Mac's list of passwords every time, and clicking away or pressing Escape closes it. It could close a moment after opening and then not open again, or stay over the page and keep coming back. Thanks to [frarees](https://github.com/frarees). ([#378](https://github.com/ZigaoWang/zigzag/issues/378))
- Switching away from a tab on Settings › Developer no longer freezes Zigzag for a couple of seconds. Its preview drew every feature flag's switch and shadow, also the ones scrolled out of sight, and its rows measured their switch several times each. Thanks to [hungraw](https://github.com/hungraw). ([#379](https://github.com/ZigaoWang/zigzag/issues/379))
- The buttons in Zigzag Mini's top strip have room between them, so their highlights no longer run together, and the address you edit there stays between the space's name and the buttons instead of running under them. In a narrow window the buttons step aside while you type. Pop-up windows and installed apps space their buttons the same way.
- Site Controls shows Keep cookies only while Clear cookies when Zigzag quits is on in Settings › Privacy. Without it, nothing clears unless you press Clear Cookies…, so the switch looked like it did nothing; the Keep cookies for these sites list in Settings is still there for that. Turning the setting on or off updates Site Controls while it's open. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#383](https://github.com/ZigaoWang/zigzag/issues/383))
- With dark pages on, the bar above a page Zigzag draws dark, like Shopify's checkout, is dark too instead of white. When part of a page's style couldn't be darkened, its white background underneath gave the bar its color though the page showed dark. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#250](https://github.com/ZigaoWang/zigzag/issues/250))
- Hovering or pressing the sidebar's buttons and rows shows in a white or very light space too. Their highlight was a wash of white, which can't show on white; by day it's a light shade of the space's color now, about as clear on every space, and a little clearer at night.
- Space icons at the bottom of the sidebar no longer move down when you click them. They show hover and press like the buttons beside them, and give a little around their middle as those do.
- A download rule that sends to a service names the place first and the method after it in brackets, as in "Files ending in .torrent go to 127.0.0.1 (load.start)", instead of "load.start · 127.0.0.1". The notice over the page says it the same way, and a site's kept answer under a rule reads "youtube.com: Hand Off". Thanks to [Lakeland97](https://github.com/Lakeland97). ([#367](https://github.com/ZigaoWang/zigzag/issues/367))
- The full-screen switch in Site Controls and Settings › Privacy › Sites is called Keep full screen in the window instead of Full screen fills the page, and under it Site Controls says what happens on the site now: Videos fill the page, not the screen, or Videos fill your screen. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#385](https://github.com/ZigaoWang/zigzag/issues/385))
- A password extension can fill a site's own sign-in sheet (HTTP Basic auth) from its popup. When you picked a login in the extension after Zigzag's sheet showed, nothing happened; now the first name and password an extension gives while the sheet is up signs you in and closes the sheet. Thanks to [Tuszy42](https://github.com/Tuszy42). ([#387](https://github.com/ZigaoWang/zigzag/issues/387))
- Extensions work on a page in Peek as they do in a tab. A Peek page wasn't a tab to extensions, so one like SponsorBlock could run on the page but not get answers from its background or find which tab it was in. Now it's a tab of its window, the active one while Peek is open, told when it opens, changes and closes; Open as Tab keeps it the same tab. In a private window, only extensions you allow there see it. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#374](https://github.com/ZigaoWang/zigzag/issues/374))
- A site shows the same icon in every tab, pinned tab, favorite and Zigzag Mini. Two GitHub tabs could show different icons, the octocat in one and GitHub's rounded home-screen icon in the other, depending on what loaded first. A site's own icon now always wins over its home-screen icon, which stands in only for a site with none of its own, and a page that changes its icon, as GitHub does for dark mode, changes it in its tab too. ([#386](https://github.com/ZigaoWang/zigzag/issues/386))
- Holding Delete on tabs picked in the sidebar closes them once, and the rest of the press no longer reaches the page, where it could delete text in a field. Delete in the sidebar acts only on rows picked with ⌘- or ⇧-click; after a plain click on a tab the keys stay with the page, and ⌘W closes it. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#375](https://github.com/ZigaoWang/zigzag/issues/375))
- A certificate you trust on the warning page for a local server is remembered in Settings › Developer. Add Site… beside the list opens a local HTTPS server to trust from its warning. Each port is remembered on its own, so a NAS with several HTTPS services keeps a separate choice for each. A NAS or a container reached at its network address stops asking on every launch. The page still says it isn’t secure. Remove beside the server brings the warning back. A public site’s choice still lasts one launch. Thanks to [datarip](https://github.com/datarip). ([#400](https://github.com/ZigaoWang/zigzag/issues/400))
- An extension set to When You Click It or On Specific Sites no longer runs on other sites. Changing an extension's site access while it was running left its content scripts on every site until Zigzag restarted. When You Click It now gives the extension only the tab you click it in, until that tab goes to another site or closes, as in Chrome, instead of keeping every site you clicked it on. An extension starts again when you take a site away from its site access; turning extensions off for a site keeps them running. Its background opens web sockets only to this Mac and the sites it has now.
- Settings › Developer’s lists keep the same spacing from the Add button to the first option row. Sites in Developer Mode used to sit closer than Page Sizes. Thanks to [datarip](https://github.com/datarip). ([#396](https://github.com/ZigaoWang/zigzag/issues/396))
- Services on one address keep their own icons. Two apps on one server, each on its own port, show their own favicon in their own tab. Before, the last one opened wore its icon in every tab on that address. Thanks to [datarip](https://github.com/datarip). ([#398](https://github.com/ZigaoWang/zigzag/issues/398))
- Typing in Settings' search no longer stutters, and switching to Settings › Shortcuts is quicker. Both made every shortcut's row again each time. Thanks to [hungraw](https://github.com/hungraw). ([#402](https://github.com/ZigaoWang/zigzag/issues/402))
- Extensions like SingleFile can save a page they build in a hidden page of their own. A file an extension makes as a blob address was downloaded from a page of Zigzag's, which WebKit doesn't let read it, so the download ended interrupted and the extension reported that as an error. It now starts in the extension's own page and saves as usual. Thanks to [datarip](https://github.com/datarip). ([#407](https://github.com/ZigaoWang/zigzag/issues/407))
- A site's own questions over its page, like "github.com says" with OK and Cancel, a sign-in or a certificate to pick, are light or dark as the page under them, as the camera and location card already was. In a light space a dark site's question stayed white, and it turns when the page does while it's up. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#300](https://github.com/ZigaoWang/zigzag/issues/300))
- Passbolt starts and its toolbar button works. Extensions whose background lives in a folder and loads its other scripts by name, as Passbolt does, couldn't find them in Zigzag, so the background never started and clicking the button did nothing. They now load from the background's own folder, as in Chrome. Thanks to [bkonia](https://github.com/bkonia). ([#393](https://github.com/ZigaoWang/zigzag/issues/393))
- Full screen is less likely to get stuck halfway, with the window draggable and no window buttons. Zigzag no longer moves the window buttons while macOS is still moving the window into or out of full screen, and if macOS gives up on full screen, the window gets its usual title bar and buttons back. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#401](https://github.com/ZigaoWang/zigzag/issues/401))
- Pin an extension from its right-click menu; clicking an extension's icon always opens it. In Site Controls a small pin button sat on the corner of each extension's icon, so a click meant to open the extension often pinned it instead. Pin to Address is now first in the menu, and a pinned extension shows a small pin mark that a click goes through.
- The × on a split view's row in the sidebar closes only the page it's on, as in Arc, instead of every page of the split. It sits on the part you point at, or on the page you're in; that tab closes and the other stays open as a tab of its own where the split's row was. A middle-click closes the page under the pointer the same way. Close Split View in the row's right-click menu closes them all, and ⌘Z puts a closed page back in its split. ([#404](https://github.com/ZigaoWang/zigzag/issues/404))
- ⌥⌘↓ and ⌥⌘↑, and ⇧⌘] and ⇧⌘[, go to the row below or above in the sidebar as you see it, and wrap around at the ends, as in Chrome and Arc. They went through pinned tabs in the order they were saved rather than the order shown, into pages in shut folders and tabs folded away in a group, and to both pages of a split one after the other, and they skipped pinned tabs that weren't open. A split is one stop now, showing the page of it you were on last. ([#403](https://github.com/ZigaoWang/zigzag/issues/403))
- View › Developer has Show Tools Above the Page and Hide Tools Above the Page, the same switch as Settings › Developer › Tools above the page, for the bar of developer tools above a page in Developer Mode: Copy Link, the console, Inspect Element, the page's look and size, reload and ⋯. Searching Settings for toolbar finds it too. The bar shows over a page in Developer Mode on its own; in split view each page's tools are in its Site Controls. ([#405](https://github.com/ZigaoWang/zigzag/issues/405))
- ⌘G and ⇧⌘G with the find bar closed bring it back and go to the next or previous match. ⌘G used to skip one.
- ⌘-clicking or middle-clicking a link inside a frame on a page opens it in a new tab, in the background or in front with ⇧, as everywhere else on the page. It used to load in the frame itself. A plain click still loads in the frame.
- Scrolling and animations in a space with frosted glass are smooth on a 120 Hz display. The window was see-through there, and macOS shows a see-through window 80 times a second, so a scroll stepped unevenly; now only clear glass needs it, and frosted spaces look the same at the display's full rate. Thanks to [FammasMaz](https://github.com/FammasMaz). ([#394](https://github.com/ZigaoWang/zigzag/issues/394))
- When a site asks to show notifications or use your camera, microphone or location, Remember for this site starts checked, so Allow or Don't Allow stays for the site, as in Chrome. It used to start unchecked, so the answer lasted only until the page reloaded: Gmail and Slack notifications stopped after a reload, and a call site asked for the camera again on every visit. Uncheck it to answer for this page only. Answers you already saved stay as they are, and private windows still remember nothing. ([#410](https://github.com/ZigaoWang/zigzag/issues/410))
- ⇧⌘R reloads the page ignoring the cache, as in Chrome and Arc, and Show Reader moves to ⌥⌘R; they used to be the other way around, as in Safari. Installed apps use ⇧⌘R for Reload Ignoring Cache too. Shortcuts you changed in Settings › Shortcuts stay as you set them, and if you had already given ⇧⌘R or ⌥⌘R to something else, it keeps them. ([#413](https://github.com/ZigaoWang/zigzag/issues/413))
- Closing the tab you're on goes to the tab below it, or the one above at the end of the list, as in Chrome. If the tab was opened from another and you haven't switched tabs since, it goes to the next tab that page opened, else back to that page. It used to go back to the page that opened it however long ago that was, else to the tab you were on before, so reading search results one by one with ⌘W kept going back to the search, and closing a link opened in the background could land on the last link opened. Moving the tab you're on to another space, another window or Zigzag Mini goes on the same way. Pinned tabs and favorites close as before. ([#412](https://github.com/ZigaoWang/zigzag/issues/412))
- ⇧⌘T brings back whatever you closed last anywhere in Zigzag, a tab or a whole window, as in Chrome. A tab goes back into its window if that's still open, else into the window you're in, and it's dimmed only when there's nothing left to bring back. It used to reopen only tabs closed in the window you were in, so it never brought back a closed window while another was open, and was dimmed in a window with no closed tabs. History › Reopen Closed Window is still there. A private window brings back only its own tabs, and nothing from a private window ever comes back in another. ([#411](https://github.com/ZigaoWang/zigzag/issues/411))
- Pages in a split view sit closer together while the page meets the window's edges: 4 points apart instead of 8, and an extension's side panel sits as close. The line between them is as easy to grab as before. With the page framed, the gap still matches the margin around it.
- The highlight under an icon button you point at or press shows clearly on every space color, black and other very dark ones included, where it was barely there. The sidebar's buttons, the space buttons, the strips on split pages, Peek, Zigzag Mini, pop-ups, installed apps, and the icon buttons in panels and Settings all use one rule: a white or black wash just strong enough to stand out from the color under it, and a little stronger when pressed.
- Thin rounded fields have round ends again, like the address you edit in Zigzag Mini's strip. Its ends came to a point because its corners were rounder than half its height.
- On a split view's row in the sidebar, the × sits inside the page it closes. Point at a page and its part lights up with its own ×, named Close and the page's title; on the row you're in, the page you're in shows it. It used to sit alone at the row's end, where it looked like it closed the whole split. A part too narrow for its icon and the × shows the × in its icon's place while you point at it.
- Clicking the address in a split view page's strip edits it in a field the address's own size and place, light or dark with the page, as in Zigzag Mini's strip. It used to open as a taller white box over the strip's buttons, whatever the page's color.
- Clicking a pop-up window's address shows it selected in the same address field as Zigzag Mini's and split view's strips, with the same type and selection color, instead of as plain text.
- A swipe back or forward taps the trackpad once when the arrow fills, however fast you swipe. At a medium speed the arrow could fill and empty over and over near the point where letting go goes back, tapping each time. Once filled, it now stays filled until you swipe a little way back or stop short after a flick, and letting go does what the arrow shows. Thanks to [frarees](https://github.com/frarees). ([#377](https://github.com/ZigaoWang/zigzag/issues/377))
- OldTwitter works on x.com again. Its request signing uses a sandbox page that X's security policy blocks in WebKit. Zigzag now runs the extension's own sandbox script in a content world of its own, with no extension APIs, so the site's policy is left alone. Thanks to [datarip](https://github.com/datarip). ([#417](https://github.com/ZigaoWang/zigzag/issues/417))
- Passwords… in the password menu works on the first click and opens the Mac's list at the field, without macOS's small Passwords menu flashing first. A double-click no longer puts the cursor in the next field or opens the list in the corner of the screen. The list closes when you scroll, go back or forward, switch tabs, or move or resize the window, as in Safari. Passwords… now takes a click as soon as the menu shows; the rows that fill a login still wait half a second, so a page can't get one picked with a click aimed elsewhere. Thanks to [frarees](https://github.com/frarees). ([#378](https://github.com/ZigaoWang/zigzag/issues/378))
- In a split view of four pages, ⇧-dragging the line between the rows moves only the part beside the pointer, so a page can be taller or shorter than the one beside it, as ⇧ already did for the line between the columns. One line is parted at a time: while the other is parted, ⇧ moves this one whole. A parted part snaps to the middle or to the other part, whichever is nearer, and the guide shows where it will land. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#426](https://github.com/ZigaoWang/zigzag/issues/426))
- A link's right-click menu starts with Open Link in New Tab, then New Window, Private Window and Peek, as in Chrome. Open Link, which opens it in the tab you're on, moves below them instead of being first, where it did what a click already does. Thanks to [retorquere](https://github.com/retorquere). ([#419](https://github.com/ZigaoWang/zigzag/issues/419))
- The space icons at the bottom of the sidebar line up. Each one sits in the middle of its key at the same size, so a flame, a book and a star read as one row, and an emoji no longer sits higher or lower than a symbol.
- A favorite's icon stays square and in the middle of its tile at every sidebar width, instead of growing a point and sitting half a point off.
- Extension icons in Site Controls' grid sit on whole points, so the rows below the first are as sharp as the first.
- Settings › Privacy › Site Permissions shows its sites again, right under its heading. In beta 6 the list was drawn a whole list's height lower, under a second Site Permissions heading, so the section looked empty, and the Allow websites to reach apps on this Mac switch was missing. A change made in Site Controls now also shows in Settings while it's open, in any window. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#420](https://github.com/ZigaoWang/zigzag/issues/420))
- In a split row too narrow for a page's title and its speaker side by side, the speaker is a small badge on the page's icon, as on a favorite, so the title stays and the speaker lines up with the icon. Click it to mute or unmute, as before. In a part with only its icon, pointing at it shows a favorite's small × in the part's corner instead of putting the × where the icon was, so the icon and its speaker stay.
- Picking a login in the Mac's Passwords list fills the username too, not only the password, on macOS 26 and earlier. Thanks to [frarees](https://github.com/frarees). ([#378](https://github.com/ZigaoWang/zigzag/issues/378))
- The Mac's Passwords list closes when you scroll the page, go back or forward, or click elsewhere on macOS 26 and earlier, and its search field takes typing every time you open it, not only the first. Thanks to [frarees](https://github.com/frarees). ([#378](https://github.com/ZigaoWang/zigzag/issues/378))
- The password menu under a field hides as soon as you start scrolling, even with the pointer on it, instead of once the scroll ends. A click in the field it's already open for leaves it open instead of closing and opening it again. Thanks to [frarees](https://github.com/frarees). ([#378](https://github.com/ZigaoWang/zigzag/issues/378))
- The note that 1Password is waiting for you in its app shows only right after you use 1Password: its button, its popup, its shortcut, or a login field you're filling. It shows in the window where you did that. 1Password reconnecting on its own, after the Mac wakes or the extension restarts, no longer brings it up while you're doing something else.
- Get Extensions in Settings › Extensions and in the extensions menu offers Firefox Add-ons beside the Chrome Web Store, and with no extensions yet Settings names both. On an extension's page on addons.mozilla.org the install button says Add to Zigzag instead of Add to Firefox, as the Chrome Web Store's does. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#423](https://github.com/ZigaoWang/zigzag/issues/423), [#424](https://github.com/ZigaoWang/zigzag/issues/424))
- Add to Firefox on addons.mozilla.org opens the install sheet every time. Zigzag now checks the click and the file Firefox Add-ons publishes as you click, instead of when the file starts arriving, when the tab's address could already have moved on and the .xpi landed in Downloads instead. If the store doesn't answer, it's asked once more, and if it still doesn't, a notice says so instead of saving the file. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#429](https://github.com/ZigaoWang/zigzag/issues/429))
- Adding an extension from addons.mozilla.org asks once, in the install sheet, as on the Chrome Web Store, instead of asking first whether the site may download files. Other downloads, from that site or any other, ask as before, and a Block you chose for the site still applies. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#428](https://github.com/ZigaoWang/zigzag/issues/428))
- The downloads panel is wide enough for its own words. With a narrow sidebar, Open Downloads Folder no longer ends in "…", and a download's status line shows whole; the panel reaches a little over the page when it needs the room. A long file name still shortens in the middle. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#430](https://github.com/ZigaoWang/zigzag/issues/430))
- ⌥⌘← and ⌥⌘→ always switch spaces, even on a page that uses those keys itself, as the tab and window keys already did. Before, a page that used them got them first and the space stayed.
- Close Tabs Below is listed in Settings › Shortcuts and can have a shortcut of yours. It was meant to be there but was left out, so it could never get one.
- A tab's speaker goes away once its sound stops. A video whose sound goes through the page's own audio, as TikTok's embedded player does, kept the speaker on long after you paused it, though nothing played, and kept its card at the bottom of the sidebar in place of the tab really playing. The tab could also not be put to sleep then, as if it still played.
- 1Password's menu in a sign-in field comes up again after the browser has sat for a while, and it fills the password on the next step of a sign-in like Apple's. Its background could stop and not start again when a page asked it something, so the menu and the fill waited until you clicked 1Password's button. Zigzag now starts it when a page's message goes unanswered, for every extension.
- The note that 1Password is waiting for you in its app no longer turns up while you type in a search box or any other field on a page. It shows only when you've just used 1Password itself: its button, its menu in a page, or a sign-in or password field.
- A swipe back or forward that arms with a quick flick no longer shows its ring jump to full and then drop back when your fingers stop. The ring now follows how far you've swiped, and the arrow turning filled is what says letting go will go back or forward, so stopping short after a flick only takes the fill away. Thanks to [frarees](https://github.com/frarees). ([#377](https://github.com/ZigaoWang/zigzag/issues/377))
- A private window no longer adds to Favorites or renames, files or moves pinned tabs and their folders; it leaves your saved pages as they are.
- A space rule for a path of a site now also takes the site's www. address, as rules for a whole domain already did: github.com/org1 matches www.github.com/org1, and a rule written with www. matches the bare address too.
- The space editor says when Clear glass is showing as Frosted: on battery or in Low Power Mode, a line under Glass explains it, and goes away when you plug in or turn Low Power Mode off.
- A menu opened from a button on the right side of a window, like Get Extensions in Settings › Extensions, now opens inward, lined up with the button's right edge, instead of hanging past it.
- Signing in to Passbolt from its toolbar button works, instead of spinning and then saying "Authentication is required to continue". Passbolt sends its sign-in as form data, which Zigzag left to WebKit, and WebKit dropped the session cookie your Passbolt server sent back, so the next request looked signed out. Form data, files and other non-text bodies an extension sends to a site it has access to now keep that site's cookies, as text already did and as in Chrome. Thanks to [bkonia](https://github.com/bkonia). ([#393](https://github.com/ZigaoWang/zigzag/issues/393))
- Extensions that list your open tabs now see the tabs in every space of a window, as Chrome lists every tab in a window. They saw only the space in front, and none at all while it was a space on another profile, so an extension looking for its own page or the tab you're on could find nothing. A tab in a private window is still listed only to extensions allowed there, and its address and title only to extensions allowed to read them. An extension that acts on every tab in a window, like one that closes duplicates or saves all your tabs, now reaches the tabs in your other spaces there too, as it would in Chrome.
- Picking a login in the Mac's Passwords list fills the username as well as the password on macOS 26 and earlier. macOS fills the username only into a field it has paired with the password field, and it never paired the one Zigzag lays over the page, so only the password went in. Thanks to [frarees](https://github.com/frarees). ([#378](https://github.com/ZigaoWang/zigzag/issues/378))
- The tab you're on keeps its own soft shadow after it moves between Pinned and Tabs, for example when you pin it with the star. The shadow it lifts with while it glides stayed behind, larger and darker, and could sit apart from the row, below it.
- Both knobs of a gradient on the space editor's color wheel drag again. With two pale colors close together near the middle, a press on the second knob took hold of the first one instead; now the knob nearer the pointer is the one that moves.
- Clicking the Custom swatch in the space editor always shows the color wheel and Shade. Clicked while they were already out, it folded them away, and with Effects open below there was no sign of how to bring them back.
- The space editor opens next to what you opened it from. Edit Space… in the menu of the space's name at the top of the sidebar opened it down by the space icons at the bottom; it now opens beside the name. From a space icon or the + it rises from the bottom as before, and from the menu bar or the command bar it opens beside the space's name. However tall it gets, with the color wheel and Effects open, it stays inside the window, and the wheel gets a little smaller in a short window.
- Every right-click menu in the sidebar, on tabs, pinned tabs, folders, favorites, split views and spaces, is now Zigzag's own menu, like the one from + and empty space, with an icon on every item and the keyboard shortcuts you've set. Move To and the other lists open beside their item.
- Site Controls keeps one margin all around and an even rhythm down the panel. The space under the last row was about half the space at the sides; now the top, bottom and sides match, sections sit the same distance apart, and This Site and Extensions sit the same way over their rows. The ⋯ button, the chevrons and the folded extension icons line up with the switches' right edge.
- Change Icon's face in the sidebar's menus and Site Controls stays an outline in dark mode, like the icons beside it. macOS draws that face filled in dark mode, so it stood out as a solid gray disc.
- A right-click menu near the bottom of the window slides up only as far as it needs to, as macOS's menus do, instead of opening wholly above the pointer. Its first items stay right by the pointer, so Separate Split View or Reload Page is a short move away wherever you click.
- Choose Image… and Use Site Icon under the icon grid line up with the search field above them, and the grid's panel keeps the same margin below them as at its sides. Their hover fill reached out toward the panel's edge and nearly touched its bottom corners.
- The numbers that holding ⌘ or ⌃ shows stay up while you keep holding it and press ⌘1–⌘9 or ⌃1–⌃9, following the tab or space you went to, so you can go on to the next. They went away at the first number. Any other key, a click or letting go still hides them, and a quick ⌘1 never shows them.
- Icons in buttons sit on the screen's pixels where their ink is centered, instead of snapping to the nearest whole point, so some no longer sit half a point off.
- In a split view, the reload button on each page's strip lines up with back and forward instead of sitting a little low.
- A split view page's strip keeps as much room above its buttons and address as below them, instead of sitting half a point high.
- A split view page on plain http shows the not-secure mark in its strip's address, as the sidebar's address does.
- A local file open in a split view shows its name in its strip's address instead of "file:", and History and Settings show their names too.
- A folder's or group's name in the sidebar takes the space's own ink, as the pinned pages and tabs under it do, instead of plain black or white.
- Renaming a tab, folder or group in the sidebar keeps the name in the row's own ink while you type, instead of turning it plain black or white.
- In a split view, a toast like Link copied shows below the pages' strips instead of over their buttons, as the find bar does.
- Renaming a tab, folder or group in the sidebar keeps the name on its line instead of dropping it half a point as editing starts.
- The space's name at the top of the sidebar starts on the same line as the icons and the Tabs label below it. At row size it sat a point to the right, and a large name half a point.
- The Tabs label in the sidebar starts on the icons' line instead of half a point to the right.
- In the command bar, the Tab key shown beside Search Wikipedia and the other site searches ends where the Return key on the chosen result does, instead of 2 points further in.
- Peek names a local file by its name in its strip, as the sidebar does, instead of showing nothing beside the icon.
- A confirmation's message lines up with its title instead of starting 2 points further in, in sheets and forms alike.
- What's New lines up the app icon's edge with the headings and points under it, instead of sitting 5 points in.
- A toast with an icon, like the zoom level's, keeps as much room after its words as before its icon, instead of 3 points more on the right.
- Reader on a local file names it in its header and in Read the original at the end, instead of leaving them blank.
- In the welcome window's yes-or-no steps, the answer you didn't pick keeps its outline. It lost it as soon as the button was drawn again, so Show Ads and Not Now read as plain text beside the picked answer.
- The welcome window's Skip sits on the same line as the progress dots, instead of 3 points below them.
- The welcome window's Back starts on the card's left edge, as Continue ends on its right one, instead of 3 points in.
- In the welcome window's Pin the sites you use, each site's icon and name sit in the middle of its tile, so a picked tile's tint has even room above and below them. They sat 4 points from its top and 11 from its bottom.
- In the welcome window's import step, a browser's hover fill is rounded on every row, as the list's box is, and Stay signed in to your sites has the same corners. Only the first row's top was rounded, by the box clipping it, and every other fill had square corners against the lines between rows.
- In the column of Settings, the Translation symbol is drawn at the size of the others. It was half as wide again as the rest, 23 points against about 16.
- In the Import window, a browser whose count runs to two lines, like Chrome with its extensions, gets a row tall enough for them. The second line ran out of its row, onto the edge of the chosen row's tint.

## [0.9.2] - 2026-11-18

Sites that always open in the space you choose, Zap Element and Edit Style to hide parts of a site or restyle it, an Archive list, download rules that hand links and files to other apps, tabs shared between windows, JavaScript off per site, a History menu like Safari's, and smooth scrolling on high refresh rate displays.

### New
- Download rules, in Settings › Downloads, hand a download or a link to another app, a script or a download manager like aria2, Motrix or yt-dlp, by what its address matches. Add Rule starts with the ready-made rules, the App field lists your apps, and scripts can live in one Scripts folder. In Settings, each rule reads as a sentence, like "Files ending in .torrent go to aria2", and rules are dragged into order. A rule's handoff asks the first time, with This time, Always on this site or Always for the rule, and Settings › Downloads lists what each rule remembers. An Open URL rule with a web address can open it in Zigzag, in this tab, a new tab or Zigzag Mini, instead of your default browser. Zigzag asks before it hands anything off, and whatever no rule matches is saved as before. See [docs/download-rules.md](https://github.com/ZigaoWang/zigzag/blob/main/docs/download-rules.md). Thanks to [Lakeland97](https://github.com/Lakeland97). ([#191](https://github.com/ZigaoWang/zigzag/issues/191))
- Double-clicking the empty space below your tabs opens a new tab, as in Arc. The top of the sidebar still works like a title bar, and Settings › Appearance › Double-click the sidebar for a new tab turns it off. ([#262](https://github.com/ZigaoWang/zigzag/issues/262))
- With Full screen videos fill set to The Page, a video filling the page shows a button at its top corner, while the pointer moves, that takes it into the screen's own full screen. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#257](https://github.com/ZigaoWang/zigzag/issues/257))
- Drag a tab onto a split's row in the sidebar to add it as a third or fourth page, as dragging one tab onto another makes a split. It takes a quarter on the side of the row you drop it on, and four make a grid. ⌘Z puts it back.
- The bottom of the sidebar shows a Now Playing card for every tab playing sound in the background, up to three, instead of only one, so you can pause or mute each of them when several start at once. A new card goes on top, so the others stay put. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#274](https://github.com/ZigaoWang/zigzag/issues/274))
- Settings › Appearance › Page zoom sets the zoom every website opens at, as in Chrome and Safari. A site you zoom with ⌘+ or ⌘− keeps its own zoom, and Actual Size goes back to the default. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#273](https://github.com/ZigaoWang/zigzag/issues/273))
- With the sidebar hidden, a link you open in a new tab behind the page, with a ⌘-click, a middle click or Open Link in New Tab, shows a note at the sidebar's edge for a moment with the new tab's icon and title. Click it to go to the tab. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#272](https://github.com/ZigaoWang/zigzag/issues/272))
- The History menu works more like Safari's: Recently Closed lists the tabs and windows you closed lately, to bring back any one of them, followed by the pages you visited today and a submenu for each of the last seven days. Click a page to open it in the tab you're on, or ⌘-click it for a new tab. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#271](https://github.com/ZigaoWang/zigzag/issues/271))
- The ⌘T bar can be dragged anywhere in the window, over the sidebar too, by its edge or the space around its text, as in Raycast, and it stays where you put it. While you drag, guides show where it opens by default, the middle of the window and its usual height, and it snaps onto them so getting back is easy. Double-click its edge to put it back. Thanks to [miateo](https://github.com/miateo). ([#280](https://github.com/ZigaoWang/zigzag/issues/280))
- With Protect IP address from WebRTC on, a site that tries to use WebRTC as it loads, as Google Meet does, no longer just breaks without a word: a notice over the page says the site tried to use WebRTC, which you've blocked, with Allow for This Site to allow it and reload the page. It shows once a page, never for a frame inside it, and not again this session once you close it. Thanks to [bkonia](https://github.com/bkonia) and [Lakeland97](https://github.com/Lakeland97). ([#276](https://github.com/ZigaoWang/zigzag/issues/276))
- Settings › Downloads can send files of a type to a folder of their own, or open them in your Mac's app once they're saved, like PDFs in Preview. Open works only for safe types: apps, scripts, installers, archives, disk images, web pages and links to other places are always just saved. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#263](https://github.com/ZigaoWang/zigzag/issues/263))
- With Settings › Appearance › Address bar above the page on, the address is the same quiet pill split view's pages have: the site, centered over the page, opening right where it is when you click it or press ⌘L. Back, forward and reload stay on the left, and Reader, pinned extensions and Site Controls on the right. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#275](https://github.com/ZigaoWang/zigzag/issues/275))
- Settings › Tabs › Windows share a space’s tabs lets every window on the same space list the same open tabs, as in Arc, instead of each window having tabs of its own. Each window still shows its own tab; a page is on screen in one window at a time, so choosing one that's open in the other window shows Show Here, which brings it over still loaded. Opening, closing, moving, nesting, grouping and splitting tabs shows in every window, and closing a window closes none of them. Private windows keep their own tabs. Turning it on joins the windows' tabs up, and turning it off gives each window the tabs it has; no tab is lost either way. It's off unless you turn it on. Thanks to [miateo](https://github.com/miateo). ([#162](https://github.com/ZigaoWang/zigzag/issues/162))
- Every question a site asks, for the camera, microphone, location, notifications, opening an app, screen sharing and where a pop-up opens, now uses one card over the page, with This time or Always on this site. A no is kept like a yes, so a site you refused stops asking. A pop-up asks whether to open in This Tab, a New Tab or Zigzag Mini and remembers it. A site with a question waiting shows a dot on its tab, and Site Controls lists every permission a site has asked about, with Ask, Allow and Block. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#253](https://github.com/ZigaoWang/zigzag/pull/253))
- JavaScript can be turned off for every site or one site, as in Chrome. Settings › Privacy › JavaScript sets it for all sites, Allowed or Not Allowed, and the JavaScript row in Site Controls gives the site you're on its own choice, which reloads the page. A site that's off says so in that row, so a page that looks broken is easy to explain. Zigzag's own pages and features keep working, a private window's choice lasts for that tab only, and Settings › Privacy › Sites lists each site's choice to forget. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#282](https://github.com/ZigaoWang/zigzag/issues/282))
- Settings › Privacy › Ask before a site downloads files, off by default, has a site's first download ask first, as Safari does. Allow can be kept for the site, and Site Controls has a Downloads row with Ask, Allow and Block. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#256](https://github.com/ZigaoWang/zigzag/pull/256))
- In Zigzag Mini, an installed web app, or a window whose sidebar is hidden, a site's question that's waiting for you shows as a soft line along the window's edge. Click it to bring the window forward and answer. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#284](https://github.com/ZigaoWang/zigzag/pull/284))
- A site can always open in a space you choose, like Arc's Air Traffic Control. Set Open in in Site Controls, or add sites in Settings › Spaces › Sites in Spaces, and a link to that site or its subdomains opens there as a new tab, wherever it comes from: another app, the command bar, the address or a link in another space. A small note says where it went. A space with its own profile keeps the site's cookies apart, like a Firefox container. Redirects, sign-ins and a page's own pop-ups stay where they are, and private windows are left alone, as is Zigzag Mini until you move its page into Zigzag. A removed space's sites open in any space again. Thanks to [retorquere](https://github.com/retorquere). ([#286](https://github.com/ZigaoWang/zigzag/issues/286))
- Settings › Spaces › Give new spaces their own profile, off by default, gives a space you make a profile of its own, with its own sign-ins, extensions and history, so you don't have to make one by hand for each. The profile is named after the space, takes the name you type while you name it, and has the space's color when no other profile has it. The space's editor still lets you pick another profile, and spaces you already have, spaces from an import and private windows are left as they are. Thanks to [pyoio](https://github.com/pyoio). ([#291](https://github.com/ZigaoWang/zigzag/issues/291))
- A space with no page open shows a soft wash of its own color, a lighter version of its sidebar, instead of plain white or black. The space's editor has a new Background row: Choose Image… puts a picture of your own behind the wordmark, and Remove takes it away again. Zigzag keeps its own copy, sized for your screen, so the picture stays even if you move or delete the original. Private windows stay plain.
- Settings › Passwords › Password manager chooses who saves and fills your passwords: Zigzag, or Apple’s iCloud Passwords extension. Choosing iCloud Passwords adds the extension, with the usual sheet, pins its button by the address and turns off Zigzag’s own saving and filling in that profile, so the two never both offer. Click the extension’s button and enter the code from macOS to connect it. Choosing Zigzag again puts saving and filling back as they were and leaves the extension installed, to remove in Settings › Extensions if you like. Adding the extension yourself from the Chrome Web Store offers once to switch. The Passwords window is there either way. Thanks to [bkonia](https://github.com/bkonia). ([#248](https://github.com/ZigaoWang/zigzag/issues/248))
- A site that asks for a certificate to identify you, as some organizations' Outlook and Microsoft sign-ins and intranets do, gets one from your Keychain, as in Safari. A sheet over the page lists the certificates the site would take, with who issued each and when it expires, and Always use this certificate for the site, on by default, so it isn't asked again. Settings › Privacy › Sites lists the certificate each site uses, to forget. A certificate that's gone or expired is asked for again, Cancel goes on without one, and private windows always ask, keeping the choice only until they close. To add a certificate, open its .p12 file in Keychain Access; macOS may ask once to let Zigzag use its key. Thanks to [ldhieu](https://github.com/ldhieu). ([#297](https://github.com/ZigaoWang/zigzag/issues/297))
- After you click in the sidebar, ⌘A selects every tab in the Tabs section, as in Arc and Finder, so you can close, move, pin or split them all at once. Tabs inside a shut group or under a folded tab stay unselected, and Esc lets go. ⌘A in the page, the address field or a rename field still selects text there. Thanks to [Kevoin](https://github.com/Kevoin). ([#302](https://github.com/ZigaoWang/zigzag/issues/302))
- Archived tabs have a list of their own, like Arc's Archive. History › Show Archive, or Show Archive in the command bar, opens it: the tabs that tidied themselves away, by the day they went, each with its site and the space it came from. Click one to open it again in that space. It has a search field and Clear Archive, which the toast's Undo puts back. With Settings › Tabs › Archive tabs you haven’t used off, it says so, with a button to turn it on. Private windows' tabs are never archived.
- A tab, pinned tab or favorite can use an image of your own as its icon. Change Icon… in its menu has Choose Image…, which takes an SVG, PNG, JPEG, HEIC, PDF or ICNS file up to 1 MB, and Use Site Icon puts the site's icon back. Zigzag keeps its own copy, so the icon stays if you move or delete the file, and an SVG is drawn safely, with no scripts and nothing loaded from elsewhere. Thanks to [bkonia](https://github.com/bkonia). ([#303](https://github.com/ZigaoWang/zigzag/issues/303))
- Copy Link leaves out tracking parameters like utm_source, and pastes as the page's title linked where rich text is accepted.
- Zap Element, like Arc's Boosts, hides parts of a site you don't want to see. Choose it from the ⋯ menu in Site Controls, point at a banner, a sidebar or a pop-up, and click it: it's gone, and stays gone each time you visit the site. Press Esc when you're done. Site Controls shows how many are zapped, with Restore All to bring them back, and Settings › Privacy › Sites lists them to forget. In a private window, what you zap lasts until the window closes.
- Edit Style…, in the ⋯ menu of Site Controls, gives a site CSS of your own, like an Arc Boost: the page shows it as you type, and it's there each time you visit. Leave it empty to turn it off. It's plain CSS only, with no imported style sheets, scripts or web addresses, so a style you paste can't load anything or send anything anywhere. Site Controls has a Custom style row while a site has one, Settings › Privacy › Sites lists the site as boosted to forget, and a private window's style lasts until the window closes.

### Fixed
- Bitwarden works on macOS 15, instead of saying right away that WebAssembly isn't supported. The WebKit in macOS 15 ignores an extension's permission to run WebAssembly, so Bitwarden's vault code, which needs it, was refused. Zigzag now gives such extensions that permission in a form this WebKit keeps, with the same limits on where their scripts load from. macOS 26 and later weren't affected. Thanks to [ldhieu](https://github.com/ldhieu). ([#298](https://github.com/ZigaoWang/zigzag/issues/298))
- Scrolling and animations stay smooth on high refresh rate displays. Pages now draw at the screen's full rate, up to 120 times a second on a ProMotion display, as in Chrome, instead of at most 60, which made a site's own smooth scrolling, its animations and anything moving as you scroll look stuttery. Settings › Developer › Feature Flags › Prefer Page Rendering Updates near 60fps brings back the old rate.
- A light site with a dark bar across its top, like star-history.com, is no longer drawn half dark with dark pages off or not at work, with its text dark gray on a dark background and its fields and charts white. Zigzag took the bar for the whole page being dark and loaded the site on a dark background from then on, so turning the site's Dark page row to Off didn't help. A site already taken for dark is put right the next time it's opened.
- Turning off Correct Spelling Automatically, in Edit › Spelling and Grammar or a text field's right-click menu, holds for every page, window and relaunch, as in Safari, instead of only the page you turned it off in. The same goes for Check Spelling While Typing, Check Grammar With Spelling and Edit › Substitutions. Until you choose, pages correct spelling as your Mac does, as set in System Settings › Keyboard › Text Input. Thanks to [abclint](https://github.com/abclint). ([#296](https://github.com/ZigaoWang/zigzag/issues/296))
- A split view's row in the sidebar shows each page's title, like a tab's: every page gets an equal part with its icon and title, a thin line between them. The close button comes up when you point at the row, as on a tab, and in the split you're on, the page you're in has the darker title. When the sidebar is too narrow for titles, each page shows its icon alone.
- Importing from Arc keeps Favorites with the profiles of its displayed spaces, leaving behind other Macs' synced Favorites and older copies of their lists. Repeated pages are added only once per profile. Thanks to [adagradschool](https://github.com/adagradschool). ([#290](https://github.com/ZigaoWang/zigzag/pull/290))
- In full screen, with the sidebar shown and Borderless page on, the page's corners are square where it meets the edges of the screen, instead of round with a wedge of the sidebar's color showing at the top and bottom right corners, most noticeably with no page open or while one loads. In a window the page's corners follow the window's own, however rounded macOS draws them. Thanks to [alextend](https://github.com/alextend). ([#283](https://github.com/ZigaoWang/zigzag/issues/283))
- HLTV (hltv.org) no longer shows its betting ads: the columns beside the page, the picture behind it that opened a betting site when clicked, and the banners and odds boxes by the logo and in the side columns. News, matches, scores and videos are as before. Thanks to [alextend](https://github.com/alextend). ([#283](https://github.com/ZigaoWang/zigzag/issues/283))
- In full screen, the close, minimize and full screen buttons that come down with the menu bar have a bar behind them again, instead of floating over the page when the sidebar is hidden.
- An address typed without http:// or https://, like localtest.me:3000 for a development server, opens over http when the site can't be reached securely, as in Chrome, Safari and Firefox. Zigzag still tries https first, and goes to http only when nothing answers securely: never past a certificate warning, and never for a site that asked to be reached only securely. The same goes for an address you paste, drop on the address bar or open from selected text. ([#252](https://github.com/ZigaoWang/zigzag/issues/252))
- Security hardening: a page a site sends as a download is always saved, never shown as one of its pages; an extension can replace only files it downloaded itself, and a replaced file goes to the Trash; the address keeps showing the page you're on while a reload is redirected elsewhere; a name and password saved for a site are sent only on that site's own pages, never to something from another site embedded in a page; an extension from the Chrome Web Store is installed only when the store itself signed it, as in Chrome; an extension's own listeners never hear what its user scripts send; an AI app's action can't land after you press Stop; copied passwords and keys stay out of clipboard history and are cleared when Zigzag quits; Passwords locks when you lock the screen; a site whose rules only allow a short PIN isn't given a "strong" password; page pictures and tab history are readable by you alone; and each PDF opens in a sandboxed helper of its own.
- An extension that reconnects to itself in a loop on every page, as two Sound Booster extensions did, no longer keeps Zigzag busy. After a few seconds of it, Zigzag lets it try only now and then on that page, notes it once in the extensions log, and says which extension it is, with Turn Off… to turn it off on that site or everywhere. Other extensions, and the same one on other pages, aren't affected.
- The mini player follows a feed of short videos, like Douyin or TikTok: when the next video starts playing, it moves to it instead of showing a black picture. Thanks to [alextend](https://github.com/alextend). ([#267](https://github.com/ZigaoWang/zigzag/issues/267))
- Importing from Arc keeps Arc's profiles. When your Arc spaces are on more than one Arc profile, each of Arc's own profiles comes over as a Zigzag profile with its name (or goes into the one already called that), with its spaces, its Favorites, its history and its sign-ins; spaces on Arc's default profile go to the profile you import into. Importing again adds nothing twice, and with one Arc profile everything comes over as before. Thanks to [miateo](https://github.com/miateo). ([#279](https://github.com/ZigaoWang/zigzag/issues/279))
- Proton Pass works: its window no longer says your browser is having difficulties activating it and asks you to update, and it opens to its sign-in. It hides its extension API from other scripts once it starts, and that cut it off from its own messages in Zigzag. Thanks to [JonasNowak](https://github.com/JonasNowak). ([#287](https://github.com/ZigaoWang/zigzag/issues/287))
- The Import window's Import button no longer goes off the bottom when you choose Chrome. The window grows to fit what you choose while the screen has room, and when it doesn't, the browsers and choices scroll while Import and Not Now stay at the bottom. Thanks to [tachebleue](https://github.com/tachebleue). ([#293](https://github.com/ZigaoWang/zigzag/issues/293))
- A site's question card, for the camera, location, notifications, pop-ups and the rest, is now light or dark as the page under it, as the bar above a page is, and its This time menu with it. In a space with a light color it stayed light on a dark site or with your Mac in dark mode. It turns when the page does, while it's up. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#300](https://github.com/ZigaoWang/zigzag/issues/300))
- Zigzag no longer quits unexpectedly when a tab in the background is put to sleep or closed just as its site sends it on to another site, as it did a couple of minutes after a Mac woke. A tab whose page is still on its way now waits for it to arrive before it sleeps, and a page Zigzag lets go of is closed a moment later rather than right away, out of the way of WebKit. Thanks to [rcoopr](https://github.com/rcoopr). ([#305](https://github.com/ZigaoWang/zigzag/issues/305))
- An update now has one home, the card at the bottom of the sidebar. After Check for Updates…, the card shows the download filling with how much has come, then the update being prepared, then Restart once it's ready, instead of a toast and the card saying the same thing at once. The card shows the whole version, and with the sidebar hidden it sits in the same corner of the window.
- Clicking iCloud Passwords' Enable Password AutoFill under a sign-in field opens the extension's code entry, as clicking its button does, instead of doing nothing. Thanks to [bkonia](https://github.com/bkonia). ([#248](https://github.com/ZigaoWang/zigzag/issues/248))
- An extension whose Mac app is optional, like Better Passwords, works without it: it no longer shows "Invalid call to runtime.connectNative()", and Zigzag no longer says it needs its app. Thanks to [bkonia](https://github.com/bkonia). ([#248](https://github.com/ZigaoWang/zigzag/issues/248))

## [0.9.1] - 2026-11-16

Protection for your IP address from WebRTC, a smarter Clear that keeps split views whole and shows what it will close, favorites that show their state, the space's name kept in view, a long list of security hardening, and text and controls aligned to the pixel across the app.

### New
- Protect IP address from WebRTC, in Settings › Privacy, keeps sites from learning your real IP address through WebRTC while you use a proxy or VPN. When it's on, WebRTC is off except on sites you allow: Site Controls › Permissions has a WebRTC row on every site, and a site that starts a call without it asks to Allow and Reload. Calls on Meet, Zoom, Teams or Discord work once the site is allowed. It's off unless you turn it on, and a private window follows it without remembering what you allow there. ([#229](https://github.com/ZigaoWang/zigzag/issues/229))
- Right-clicking selected text that's a web address but not a link, like example.com in a post, offers Open and Open in New Tab, as Chrome's Go to does. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#234](https://github.com/ZigaoWang/zigzag/issues/234))
- Disable Images and Disable Styles, under ⋯ among the developer tools, in View › Developer and the command bar, show how a page in Developer Mode holds up without its pictures or without its CSS. Like the other choices they're that tab's alone, except that a tab a page opens shares Disable Images with it: turned on or off in either, it is in both, and ⋯ shows it in each. ([#141](https://github.com/ZigaoWang/zigzag/issues/141))
- Turn on Settings › Tabs › Show a mini player when you leave Zigzag, and a video you're watching keeps playing in Zigzag's mini player over other apps when you switch to another app or desktop for more than a moment. Come back to its tab and it goes back in its page; come back to another tab and it plays on until you go to its tab. A muted or paused video, and Picture in Picture you started yourself, stay as they are. It's off unless you turn it on. Thanks to [alextend](https://github.com/alextend). ([#238](https://github.com/ZigaoWang/zigzag/issues/238))
- Groups of tabs: pick some tabs (⌘-click or ⇧-click their rows) and choose Group Tabs, or New Group with Tab on one tab, and they become a folder in the Tabs part of the sidebar, as pinned tabs have. It opens and closes with a click, renames from its menu, and keeps its tabs together: drag tabs onto it or among its tabs to put them in, drag them out to take them out, or drag the whole group somewhere else. Its menu also has Ungroup, Move to Space and Close Group, which closes its tabs, with Undo. Groups come back when you open Zigzag again, Clear keeps or closes a group as one, split views work inside one, and a group with no tabs left goes. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#209](https://github.com/ZigaoWang/zigzag/issues/209))
- A new tab comes into the sidebar the way a closed one leaves it: the tabs below glide down to make room and its row opens as it fades in, whether you opened it with the keyboard, the pointer or a link. The same goes for a tab moved in and for a folder or group opening. With Reduce Motion it only fades in.
- The address bar above the page shows the page's whole address, the site's name dark and the rest gray, as there's room for it; pop-up windows and Zigzag Mini do the same when they're wide enough. The sidebar keeps the site's name alone. A long address loses the end of its path first, never the site's name.
- The camera and the microphone are two permissions in Site Controls: a site asks for each on its own, one question after the other (a no to the first, or a Block for either, settles it without asking the other), and a call that wants both is allowed only when you've allowed both. Sites you allowed both before keep both. ([#243](https://github.com/ZigaoWang/zigzag/issues/243))
- Find on Page (⌘F) highlights every match on the page at once, in a soft yellow (amber on a dark page), with the one you're on in a stronger orange. A tick for each match runs along the page's right edge, over the scroll bar, so you can see where they all are; click one to go to that match. The marks follow the page as it changes and go away when you close the bar. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#244](https://github.com/ZigaoWang/zigzag/issues/244))
- The first time a link from another app or a script opens as a new tab, Zigzag offers once to open such links in Zigzag Mini instead. Use Zigzag Mini turns that on and moves the page into a Zigzag Mini window; it's also in Settings › Zigzag Mini. ([#246](https://github.com/ZigaoWang/zigzag/issues/246))
- Find on Page (⌘F) works in Zigzag Mini, with the same bar and marks as in a browser window. ([#246](https://github.com/ZigaoWang/zigzag/issues/246))
- Zigzag Mini opens at the size you last made it. ([#246](https://github.com/ZigaoWang/zigzag/issues/246))
- An update that's ready shows at the foot of the sidebar, in every window, with its version and a Restart that restarts into it with your windows and tabs as they were. Close it and it waits until Zigzag quits, as before; Zigzag › Check for Updates… reads Restart to Update meanwhile, and Settings › General says the version is ready. Zigzag now looks for updates every few hours and after your Mac wakes, quietly, and when a newer version comes out while one is waiting, the newer one takes its place. Check for Updates… answers in a toast instead of a window.

### Fixed
- Text across Zigzag sits exactly in the middle of its buttons, fields and rows, measured by its capital letters, with icons lined up beside it and even spacing: the sidebar, panels, prompts, toasts, Settings, History and the other windows. Some of it sat up to a point low.
- Clear, above the tabs in the sidebar, treats a split view as one: it stays while you've used any of its pages lately and closes whole, never leaving half of it behind, and a split with a playing page or a pinned page in it stays. A tab with tabs nested under it stays or goes with them, folded ones included. A tab you left a few minutes ago no longer counts as one you haven't used in a while.
- Pointing at Clear, or reaching it with Tab, dims the tabs it would close and says what it will do, like Close 3 tabs you haven't used in a while or Close the last 2 tabs, leaving the space empty. After each click, what the next one would close shows as soon as the closed tabs have gone. A split's row dims as one, both pages, and fades with age as its newest page does.
- A paused video in the mini player no longer shows the page's own video controls over the card's, on sites that use the browser's built-in controls. ([#230](https://github.com/ZigaoWang/zigzag/issues/230))
- Permissions in Site Controls says when a site hasn't asked for anything yet, instead of showing an empty page, and has no Reset Permissions while there's nothing to reset. ([#232](https://github.com/ZigaoWang/zigzag/issues/232))
- Reader pressed while a page is still loading waits for it and opens once it's loaded, instead of saying there's no article over a blank page. Press it again to call it off. ([#233](https://github.com/ZigaoWang/zigzag/issues/233))
- Translating a Chinese Wikipedia page translates it once, as Simplified Chinese, then says it's translated. Text in Traditional Chinese on it, like the language variant menu, no longer starts a second translation that brings up macOS's Download Languages sheet, and neither does the site's next page in Traditional. The download sheet now only comes up when you ask to translate a page whose language isn't on your Mac yet. ([#231](https://github.com/ZigaoWang/zigzag/issues/231))
- The Apple Store's checkout shows one Apple Pay mark in its payment options, instead of the Apple Pay logo drawn over the Apple logo and Pay. ([#235](https://github.com/ZigaoWang/zigzag/issues/235))
- Security hardening for pages, pop-ups, links, downloads, the address and secure connections.
- The space's name stays at the top of the sidebar while you scroll the pinned tabs and tabs under it, as Arc keeps it, with the fine line under it while the list is scrolled. Rows pass under it rather than showing through.
- Favorites show which are open, as tabs do: one whose page is open is a brighter tile with a fine edge, one that isn't stays flat, with its icon in full color either way, and the one you're on has the selected tab's card.
- A favorite that moved on from its page shows it, as a pinned tab does with Original / Current page: the tile shows the icon of the page it's on now with the favorite's own icon small on its corner, pointing at it names both, and Back to Favorite's Page in its menu takes it back, in a split favorite too.
- A tab's or pinned tab's title no longer moves or gets cut shorter when the pointer brings up its close or back button: the button shows over the title's faded end.
- Open in from Zigzag Mini, into a window that had just opened with its command bar, closes the bar instead of leaving it over the page.
- Pop-up windows center their window buttons in the bar at the top, fill to the bottom edge without a strip of the bar's color, and mark a page that isn't secure with the open padlock the address uses.
- With Protect IP address from WebRTC on, Site Controls no longer counts WebRTC as blocked on every site or offers Reset Permissions for it. Permissions still has the WebRTC row, so a site can be allowed before a call, under a line saying the site hasn't asked for anything when it hasn't. ([#229](https://github.com/ZigaoWang/zigzag/issues/229))
- Pausing from the mini player keeps the sidebar's Now Playing card, showing Play, for as long as the video is in the mini player, and the mini player shows its play button while paused, with the pointer away. The card's play button and the mini player's now play and pause the same way.
- The Now Playing card fades out a long title at its end, as sidebar rows do, instead of cutting it with an ellipsis, and Open Downloads Folder lines up with the file names above it in the Downloads panel.
- Show All Tabs turns dark or light with the rest of Zigzag while it's open, instead of keeping the light color behind white text. Its cards show each page as it looks now, not a picture taken before light or dark changed.
- The space editor shows a space that follows your Mac at the shade the sidebar has, light by day and deep at night, and moves with it when light or dark changes while the editor is open.
- In Settings › Zigzag Mini, the New Zigzag Mini row is as tall as its one line of text needs, with its keys in the middle of it.
- On the History page, Clear History lines up with the times under it, a sitting on one site no longer says how many pages twice, and pages visited after midnight show as Tonight while it's still night.
- Enter Full Screen in Settings › Shortcuts shows the Globe key with F, as the menu bar does, instead of F alone.
- In Simplified Chinese, sentences in Appearance and Privacy no longer have an extra space between them, and Developer Mode's description no longer splits a word across two lines.
- Switches that are off stand out from the page in dark mode, on a lighter gray track as macOS draws them, instead of nearly vanishing into it.
- Menus in a group of settings are the same width, so they line up down the page, like Sidebar size, Favorites per row and Dark pages in Appearance.
- General no longer offers Restore from before the last update when there was no update, as after Zigzag first starts with a new data folder.
- Zigzag uses about 9 MB less memory: the list of sites that only allow secure connections is read in place when a certificate warning needs it, instead of loaded at launch.
- VoiceOver reads Zigzag's own buttons, switches, menus and rows by name, like Back, Downloads or a tab's title, and says which tab is current. They came through as pictures named after their icons, and some had no name at all.
- What's New opens over the page, below the bar above it, instead of across the address and the developer tools.
- An extension's popup opened from the sidebar stays inside the window, instead of hanging past its left edge.
- In onboarding, the note that no other browsers were found sits in the middle of its card.
- Install as App's name field shows it's ready for typing in light mode too, as it does in dark. In the sheet for adding an extension, a site's name no longer breaks across two lines at a hyphen.
- Show All Tabs in a private window no longer takes a new picture of every tab loaded in the background each time it opens, on a Mac in light mode.
- Site Controls, opened under the address with the sidebar on the right, stays under the address when the window is resized, instead of being cut off at the window's edge.
- An extension's popup from its button pinned in the address stays under the button when the popup changes size after the address moved.
- The warning for a site whose certificate it signed itself, like a router's reached at 192.168.1.1, says the certificate is self-signed instead of being for a different address. A certificate made out to an IP address counts for that address.
- Two sentences joined in English keep the space between them when the first ends in a closing quotation mark.
- A pop-up from a private window keeps the WebRTC choice made in the tab that opened it after that tab is closed.
- Pages marked with an old language code, like iw for Hebrew or in for Indonesian, are offered translation from the right language.
- In dark mode, buttons filled with the space's color, like Allow on a site's question and Done in What's New, have dark text that reads on them, instead of white text that was hard to read.
- The offer to translate a page no longer shows over History or Settings.
- A site's question and Save password? take turns at the top of the page instead of showing one over the other, and a toast that comes while one is up shows under it. What's New closes when you switch tabs, and makes way for Install as App and other sheets instead of staying under them.
- Simplified Chinese reads more naturally across Settings, Site Controls and onboarding.
- Calendar and Drive in the welcome window, and the Laptop, Desktop and Full HD page sizes in the developer tools, are named in your language.
- A tab showing an error page, like a certificate warning, shows a warning icon instead of the icon of the page before it.
- Buttons that can't be used yet, like Use Default Colors in the space editor, keep their text readable.
- History lists a PDF by its file name instead of its site.
- A PDF at an address without a file name, like a download link, is called by the name its site gave it, in its tab and in History, or by the site when it gave none, instead of the last part of the address.
- A favorite or pinned tab made while its page was still loading, like en.wikipedia.org on its way to its Main Page, no longer shows as moved on from its page once it gets there. A favorite that did move on shows its own icon until the new page's icon is known, instead of a placeholder.
- Sign-in fields no longer show the key icon when Fill saved passwords is off in Settings › Passwords, or when a password manager extension like Bitwarden or 1Password is on, where it sat over the extension's own icon. ([#236](https://github.com/ZigaoWang/zigzag/issues/236))
- Space icons at the bottom of the sidebar follow Settings › Appearance › Sidebar size at every size, a step bigger than before at Small and Medium, and keep their size when you have many spaces: the row scrolls instead of shrinking them. Thanks to [alextend](https://github.com/alextend). ([#238](https://github.com/ZigaoWang/zigzag/issues/238))
- DeepSeek no longer asks you to check your browser extensions in a tab that opened before ad blocking had its lists, or beside an ad blocker extension. Its blocked telemetry now always gets an empty answer while blocking is on, so nothing is sent. ([#208](https://github.com/ZigaoWang/zigzag/issues/208))
- Backspace no longer takes a page back when no text field has the focus, as in Safari and Chrome. It still removes the rows you've picked in the sidebar.
- Panels, menus, toasts, sheets and a site's dialogs come and go with one calm, consistent motion. A page's dialog fades in and out like the other sheets, the dimming behind a sheet or a peek fades with it, a tab's preview and the password menu grow out of what they belong to, a click right after closing one reaches what's under it, and Reduce Motion is respected.
- History starts a new heading when the time of day changes, so pages from the evening are no longer listed under "Yesterday morning" after a long day of browsing.
- Downie and other extensions that add their right-click menu items once, when they're installed, keep them after you quit and reopen Zigzag, as in Chrome. Clicking Downie's button sends the page to Downie, asking first, instead of opening the extension's settings, and the question comes from the site you're on, so Always Open works there. ([#239](https://github.com/ZigaoWang/zigzag/issues/239))
- Protect IP address from WebRTC asks a site about calls only once: Don't Allow is kept as the site's Block, and a question you put away isn't asked again in any tab until Zigzag reopens. The switch stays in Site Controls.
- Swiping back or forward on a page shows a plain gray backdrop beside it, in light or dark, with a soft shadow along the page's edge, instead of a strip of the page's own colors that could show odd bands. The round arrow stays inside the page's card, never hanging over the sidebar, the next pane or the window's edge.
- Zigzag no longer asks you to add it in 1Password while 1Password works with it. The note now shows only when 1Password really turns Zigzag away, and not again once 1Password has connected that session.
- The window's buttons at the top left stay put when you switch tabs or a page loads. The green one could jump up and to the left for a moment.
- A page saved on your Mac that a script or another app opens, like a chart from Python's `webbrowser.open("file:///…/plot.html")`, opens in Zigzag (or Zigzag Mini) instead of nothing. Only HTML, SVG and PDF files, never folders or other files.
- Translating a page translates a title or short line in Chinese, Japanese, Russian or another script that names something in English, like a GitHub issue titled 类似Little Arc功能, instead of leaving it as it was because it read a little like English.
- A sign-in page in Zigzag Mini that sends you back to the app that opened it closes once that app opens, and a link that goes straight to an app no longer leaves an empty Zigzag Mini window behind. ([#246](https://github.com/ZigaoWang/zigzag/issues/246))

- A one-page PDF stays in the middle with Two Pages on, instead of sitting alone on the right like a book's first page.
- A strong password from Use Strong Password stays in Passwords until a newer one for the same account takes its place, however long the site takes to confirm it. Unconfirmed ones are no longer deleted after two weeks.
- Fill from My Card fills the name, email and address fields around the one you're in on pages without a form, and in fields inside a page's own components. When nothing on the page can take your card, it says so.
- In the password menu, the arrow keys move between rows as soon as it opens. Only Return waits a moment.
- Install from Folder… and the extensions that come with apps show their sheet in the window Settings is in, never in another window, and no longer do nothing when Settings is the only window.
- An extension can open its side panel when you click in a page and its script on that page passes the click on, as in Chrome.
- An extension's background can connect to an app on your Mac, or to a site its manifest names, as in Chrome.
- An extension installed from a folder keeps the companion-app access it had.
- An AI app's long tool call is no longer cut off when many other connections open meanwhile.
- When another app holds the AI apps' port, Zigzag replaces the key only if an AI app may have been given it, not on every launch.
- A file you go to always downloads, however soon after another: a link you pasted that redirects to the file, a "your download starts in 5 seconds" page, or a pop-up that opens straight to it. A page starting download after download on its own is still held back, and now a toast says so instead of nothing happening.
- Asking for the camera or microphone no longer asks to use WebRTC first and reloads the page: WebRTC is only offered when a site starts a call.
- Protect IP address from WebRTC covers pop-up windows too, each with its site's own choice, and a call started in one asks in the window that opened it.
- Long titles in the sidebar fade out at their end, the same at rest and with the pointer over the row, instead of switching from "…" to a fade.
- Clear's tooltip says "Close all 2 tabs" while you're on a favorite or pinned page, since none of the tabs is yours, and names a split view as one, like Close the other split view.
- Reader pressed on another tab while it waits for a page to load opens for that tab, instead of only calling off the wait.
- Open on selected text keeps the parentheses that belong to the address, like en.wikipedia.org/wiki/Mercury_(planet).
- A site's question to open an app no longer has to wait because another site asked a few seconds earlier.
- Dark Pages can read a page's style sheets behind an HTTP proxy that looks up addresses itself.
- The offer to translate a page stays with the page it was made for: opening another tab, or going to another page, takes it away, so an English page no longer says it's in Chinese because the tab before it was. A page that says which language it's in is taken at its word unless most of its text is clearly in another, so an English article quoting some Chinese stays English. The offer and the find bar beside it are now the same height, on one line.
- A certificate warning says what's actually wrong under Details: that the certificate expired, and on which day, isn't valid yet, is for a different address, is signed by the site itself, or comes from an issuer your Mac doesn't trust. An expired certificate used to be described as one for a different address.
- PDFs are dark only where web pages would be: with Dark pages in Settings › Appearance or the site's Dark page choice, following the window's own light or dark look. A PDF no longer opens dark in a light window. The moon in the PDF's bar still switches that PDF.
- Site Controls opened from the sidebar lines up exactly with the address above it, on both sides, so the favorite under it no longer peeks out at its corner.
- The SHA-256 fingerprint on the certificate page breaks into even lines of pairs, each ending on its colon, so no line starts with one.
- A long download name or command bar title no longer cuts shorter when you point at its row or move onto it, and a cut download name shows whole in a tooltip. Not secure in Site Controls and a failed extension install read clearly on light backgrounds, and a profile without extensions no longer says 0 extensions.
- A window Zigzag reopens shows its tab, address and split view from its first frame, instead of a blank address for a moment.
- The spaces in Switch Space… (⌥⌘S) have their names in the middle of their rows.
- Check for Updates… no longer says Checking for updates… for good: it answers, or the toast goes within a minute and a half, and an update that's ready is only let go for a newer one Zigzag will really get.
- Find on page uses less power on pages that keep changing, like YouTube, X or a live chat, and rests while you're in another window.
- Titles extensions give their right-click menu items as you select text are no longer saved to disk, nothing from a private window is, and saving the items no longer slows Zigzag down.
- A page opened from a file loose in your home folder can read only that file, not the files around it.
- With Reader on, Esc while the ⌃Tab switcher is up puts the switcher away and leaves Reader open, instead of closing Reader under it. The ⌃Tab switcher and Show All Tabs picture a tab in Reader as it shows, the article and not the page under it.
- Now Playing in the sidebar shows Pause while its video plays and Play while it's paused, for a muted or silent video in the mini player too, and changes as you play or pause it from the page, the mini player or a media key.
- Translating a page after closing macOS's Download Languages sheet without downloading now says the language isn't downloaded, with Translate to bring the sheet back, instead of saying to try again in a moment.
- Password saved stays long enough to see after the Save password? prompt slides away, and toasts with Undo, like Closed 3 tabs, Removed pinned pages or History cleared, stay 7 seconds instead of 4, longer while the pointer is on them.
- Ad blocking's site filters are built once the filter lists have all downloaded, together with their scriptlets. On a first launch they could be built a moment early, from the lists that had come and the copy of Zigzag's own fixes in the app, and then built again. ([#129](https://github.com/ZigaoWang/zigzag/issues/129))
- Restart to Update says it couldn't check for updates when Zigzag can't install the update right then, instead of doing nothing.
- Find on page marks the matches in text that shows up as you open a section, like an accordion or Show more, not only in text a page adds.
- A page's preview no longer comes up beside the menu when you right-click it in the sidebar.
- ⌘Z after Use Zigzag Mini takes the whole choice back: the page goes back to its tab, and links from other apps open as tabs again.
- A folder in the sidebar opens and closes like an accordion, its pages unfolding and folding together, instead of the rows below it sliding over them.
- A site with a dark design of its own whose Dark page you set to Off no longer flashes white while it loads, with the bar above it white until the page draws: once Zigzag has seen it dark, it loads on its own dark. A light site still loads as it did. ([#250](https://github.com/ZigaoWang/zigzag/issues/250))

## [0.9.0] - 2026-11-14

Split view with up to four pages, sites installed as apps of their own, the sidebar on either side, and tabs that move between windows as they are. Dark pages now use Dark Reader, ad blocking adds uBlock Origin's filter lists, cookie pop-ups are turned down for you, Site Controls is rebuilt, and pictures and PDFs from websites are read in sandboxed helpers.

### New
- The Now Playing card at the bottom of the sidebar can be hidden: point at it and click the close button at its end, or right-click it for Hide. The tab keeps playing, and the card comes back when that tab moves on to another page, or for another tab that starts playing. The card is laid out as a tab's row now, the same height, columns and buttons, and follows Settings › Appearance › Sidebar size. ([#223](https://github.com/ZigaoWang/zigzag/issues/223))
- The mini player grows out of the video as you leave its tab, where it used to show up all at once in its corner once it had landed. With no video's place to grow from, it comes out of its own corner. ([#224](https://github.com/ZigaoWang/zigzag/issues/224))
- The mini player's buttons all light up under the pointer and give when pressed, as Zigzag's other buttons do, with the same wash as its site name, clear over any video. ([#224](https://github.com/ZigaoWang/zigzag/issues/224))
- The mini player can be turned off from its own right-click menu with Turn Off Mini Player; the video keeps playing in its tab, and a toast says where to turn it on again, with Undo. The setting in Settings › Tabs is now called Show a mini player when you switch tabs. Right-clicking the player also has Back to the site, Play or Pause, Minimize and Close. ([#224](https://github.com/ZigaoWang/zigzag/issues/224))
- Site Controls says whether the connection is secure in a small line under the site's name instead of a row of its own: Secure connection, quiet, or Not secure or Partly secure in orange. Clicking it still shows the certificate. ([#221](https://github.com/ZigaoWang/zigzag/issues/221))
- Zigzag Mini has Back, Forward and Reload after the traffic lights, as a browser window does: Back and Forward dim when there's no page that way, Reload turns into Stop while the page loads, and right-clicking Back or Forward lists the pages that way. ([#213](https://github.com/ZigaoWang/zigzag/issues/213))
- Your extensions are in Site Controls itself, under its actions, instead of on a page of their own: click one to open its popup or run it, as its toolbar button would, with its badge on it. One that can't work on the site you're on (no access, When You Click It, or extensions off there) is dimmed and says why when you point at it, and right-clicking one gives its menu. The Extensions header folds them to a strip of their first icons, each still one click away, and opens them again; up to three show as rows with their names, and more as a grid of icons, each named when you point at it. It starts open with up to four extensions and folded with more, until you choose. The switch for whether extensions run on a site is now with This Site's other switches. ([#215](https://github.com/ZigaoWang/zigzag/issues/215))
- Right-clicking a page, or a tab in the sidebar, has Translate to English (in the language you read), and Show Original once it's translated, without opening Site Controls. It translates whatever language Zigzag thought the page was in, and says so when nothing on it needed translating. Zigzag also notices more pages in other languages: it goes by the paragraphs you see rather than the site's menus or the language the page claims, and checks again on pages that draw their text late or change without loading. Thanks to [bkonia](https://github.com/bkonia). ([#218](https://github.com/ZigaoWang/zigzag/issues/218))
- AI apps can wait for a page and press keys in it. `wait_for` waits until some text or an element shows or goes, or the page finishes loading, for up to 30 seconds, and stops when the tab closes or loads another page, or when you press Stop. `press_key` presses Enter, Escape, Tab, the arrows and other keys as your keyboard would, so Enter submits a form and Tab moves to the next field; keys only reach the page, never Zigzag's shortcuts, and never type into password fields. ([#214](https://github.com/ZigaoWang/zigzag/issues/214))
- Importing from Arc brings each space's open tabs too, in Arc's order, with split views side by side. They wait to load until you click them, so hundreds of tabs don't all load at once, and importing again doesn't open a tab twice. Open Tabs, beside Spaces and Pinned Tabs in the Import window, leaves them behind. Thanks to [alextend](https://github.com/alextend). ([#210](https://github.com/ZigaoWang/zigzag/issues/210))
- Space icons at the bottom of the sidebar are bigger, and follow Settings › Appearance › Sidebar size: a little bigger at Medium than before, and clearly bigger at Large. Thanks to [alextend](https://github.com/alextend). ([#210](https://github.com/ZigaoWang/zigzag/issues/210))
- Stored by Websites, in Settings › Privacy (Website Data with more than one profile), has a search by its heading that finds a site as you type, marking what matched, and says so when nothing does. Each site shows how much it keeps, the list can be sorted by name or by size, and Remove All… clears every site's data, or only the sites a search shows, after asking. A site's Remove is the trash on its row when you point at it, as on other Settings rows. ([#207](https://github.com/ZigaoWang/zigzag/issues/207))
- Feature Flags, at the end of Settings › Developer, lists the WebKit feature flags your Mac's WebKit has, as Safari's Develop › Feature Flags does: each with its switch, WebKit's name for it and a line about it, under Stable, Preview, Testable and Developer, with Mature, Unstable and Internal under Show All, and a search by name or key. Only the flags you change are kept, marked Changed, and the rest follow WebKit's defaults; Reset to Defaults puts every one back. Changes apply to pages you open or reload, and Reload All Tabs is beside it. It's there while Developer Mode is on. Thanks to [micsama](https://github.com/micsama) for the idea and [vandenbulckjean](https://github.com/vandenbulckjean) for the Developer section. ([#173](https://github.com/ZigaoWang/zigzag/issues/173))
- Release notes follow the app's language; Chinese notes for 0.9.0 and earlier releases.
- A space's editor, which also opens for every new space, says that spaces on the same profile share sign-ins, history and extensions, and its Profile menu has New Profile: a profile of the space's own, named after it, in one click. With more than one profile, the space switcher and a space's menu show which profile each space is on, as the sidebar does. Thanks to [spongehah](https://github.com/spongehah). ([#201](https://github.com/ZigaoWang/zigzag/issues/201))
- Developer Mode is turned on and off from Turn On Developer Mode in Site Controls' ⋯ menu, the command bar or View › Developer (⌥⇧⌘D), and is no longer also a switch in Site Controls' list, which is for everyone. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#198](https://github.com/ZigaoWang/zigzag/issues/198))
- Dark page, in Site Controls, is one dropdown instead of two switches: Automatic follows Settings › Appearance › Dark pages, On and Off hold for that site whatever the setting says, and Force Dark draws a site dark even when it looks dark already. Under it, Automatic says whether it's on now. Choices you made before stay as they were. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#134](https://github.com/ZigaoWang/zigzag/issues/134))
- Turning Dark page Off for a site asks it for its light look, so a site that follows your Mac's light or dark shows light even with your Mac dark. Where dark pages are off, pages follow your Mac's light or dark, not your space's colors or a private window's. A theme you picked on the site itself is the site's to keep, and stays as you picked it. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#134](https://github.com/ZigaoWang/zigzag/issues/134))
- Open apps is a site permission like the camera's. When a page wants to open an app, like the App Store or Zoom, Zigzag asks with Open (this time), Always Open (that app, from now on) and Don’t Open. Once a site has asked, Permissions in its Site Controls and Settings › Privacy › Sites have an Open apps row with Ask, Allow and Block, and Block keeps every app closed for that site. Addresses you type or open yourself still open their app right away. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#192](https://github.com/ZigaoWang/zigzag/issues/192))
- Install from Folder…, in Settings › Extensions, installs a Chrome extension from a folder on your Mac. It replaces Load Unpacked…, which only showed with Developer mode on. ([#194](https://github.com/ZigaoWang/zigzag/issues/194))
- Settings › Extensions finds Chrome extensions that come inside apps on your Mac, like StopTheMadness Pro from the App Store, and lists them under From Apps on This Mac with an Install button. The extension is read from inside the app and never changed, so the app's updates update it too. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#194](https://github.com/ZigaoWang/zigzag/issues/194))
- Settings › Privacy › Sites lists each site's permissions under it, with Ask, Allow and Block as in its Site Controls, so you can change or take one back without opening the site. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#174](https://github.com/ZigaoWang/zigzag/issues/174))
- Show in Finder, on each installed app's row in Settings › General and in the app's own File menu, shows the app selected in its folder. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#165](https://github.com/ZigaoWang/zigzag/issues/165))
- Drag a link, an address or some text onto the address, in the sidebar, the bar above the page, a split page's strip or Zigzag Mini: a link or an address opens there, and other text is searched for with your search engine. A ring around the address shows where it lands. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#182](https://github.com/ZigaoWang/zigzag/issues/182))
- Sidebar size, in Settings › Appearance, makes the sidebar Small, Medium or Large, as macOS's own Sidebar icon size does: the tabs, folders, space names, favorites and the address grow or shrink together, text, icons and rows alike, and change as you choose. Medium is the size it has always been. Thanks to [rocavence](https://github.com/rocavence). ([#183](https://github.com/ZigaoWang/zigzag/issues/183))
- New tabs can open next to the tabs you already have from the same site: choose Next to Tabs from the Same Site for New tabs open in Settings › Tabs. A link, a page from the command bar or a link from another app goes right after the last tab from its site, in the same group if that tab is nested under another, and a page from a site with no tabs open goes where your earlier choice put it. Thanks to [bkonia](https://github.com/bkonia). ([#188](https://github.com/ZigaoWang/zigzag/issues/188))
- Developer Mode, as in Arc, for the sites you build. Turn it on for any site with Turn On Developer Mode in its Site Controls' ⋯ menu or the command bar, or View › Developer › Turn On Developer Mode for This Site (⌥⇧⌘D). It takes effect at once, and a toast says so with Undo. `localhost` and `127.0.0.1` are in Developer Mode to begin with, and Settings › Developer lists every site in it. A tab in Developer Mode has a small hammer on the corner of its icon in the sidebar, in the space's own color, and so does a favorite; pointing at it shows the site. The bar above its page shows the page's whole address in monospaced type, Copy Link, and its tools in groups: the JavaScript console with a count of the page's errors, Inspect Element, the page's look and size, and reloading ignoring the cache or after clearing the site's cache or cookies. In a split, or with Tools above the page off, they're in the site's controls, and all of them are in View › Developer and the command bar. Private windows can't turn it on or off. Turn Developer Mode off in Settings › Developer and none of it shows. Thanks to [vandenbulckjean](https://github.com/vandenbulckjean). ([#141](https://github.com/ZigaoWang/zigzag/issues/141))
- Page Size gives a page in Developer Mode the size of a real device (iPhone, Pixel, Galaxy, iPad), a laptop or desktop window, or a size of your own, either way up. The sizes are in the bar above the page, in View › Developer › Page Size and in the command bar by name, and Toggle Page Size (⌥⇧⌘M) goes between the last size the page had and filling the window. The page sits on a backdrop with its edges drawn and its size beside the button: its name, and its width and height to click and type into, ↑ and ↓ stepping them by a point (by ten with ⇧). The Web Inspector docks beside it. Drag the grips at its right edge, bottom or corner to another size. A size larger than the window is laid out at that size and shown smaller, whole, with how large beside the button (“1920 × 1080 at 54%”). Add your own sizes in Settings › Developer. Thanks to [vandenbulckjean](https://github.com/vandenbulckjean). ([#141](https://github.com/ZigaoWang/zigzag/issues/141))
- Page Appearance asks a page in Developer Mode for its light or dark look whatever the Mac's is, and Show Print Styles lays it out as it would print. Under ⋯ are Disable JavaScript, Outline Every Element, a user agent of Safari on iPhone or iPad, Chrome or Firefox, sent only to the site in Developer Mode, Open In another browser, and Open on Your Phone, a QR code of the page's address on your network, localhost given as this Mac's address there. Each choice is that tab's alone, set aside while it's on another site and gone when it closes. Thanks to [vandenbulckjean](https://github.com/vandenbulckjean). ([#141](https://github.com/ZigaoWang/zigzag/issues/141))
- Trust certificates of servers on this Mac, in Settings › Developer and off until you turn it on, opens an https development server on this Mac that uses its own certificate without the warning, for the certificate it first shows. Thanks to [vandenbulckjean](https://github.com/vandenbulckjean). ([#141](https://github.com/ZigaoWang/zigzag/issues/141))
- Use Default Colors, in the space editor beside Effects and in a space's right-click menu, gives a space back the colors it was made with, following your Mac's light and dark again, with no gradient, see-through or grain. It's there once the colors have changed, and ⌘Z undoes it. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#190](https://github.com/ZigaoWang/zigzag/issues/190))
- Split view takes up to four tabs. Drag a tab over the page: its edges place it in a half, its corners in a quarter, and a preview with a small label shows where it lands. Three tabs are a half and two quarters, four a grid; the lines between them drag, and the group is one row in the sidebar that comes back after a restart. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#160](https://github.com/ZigaoWang/zigzag/issues/160))
- In split view, drag a page by its strip to move it: onto another page and the two swap places, onto a page's edges or corners and it takes that half or quarter, onto the sidebar's tabs and it leaves the split as a tab of its own, and out of the window and it opens in a new one (hold Option for Zigzag Mini). Esc calls it off, and ⌘Z puts it back. ([#160](https://github.com/ZigaoWang/zigzag/issues/160))
- Zoom Pane enlarges one page of a split over the others for a moment, without moving anything: ⇧-click its part of the row in the sidebar, use the button in its strip, or press ⇧⌘↩. Click beside it, press Esc or zoom it again and it goes back. ([#160](https://github.com/ZigaoWang/zigzag/issues/160))
- Each page in split view has its own Site Controls, from the button at the end of the address in its strip, or its ⋯ when the strip is narrow. The Site Controls button by the sidebar's address is for the page you're in. ([#160](https://github.com/ZigaoWang/zigzag/issues/160))
- A split's row in the sidebar shows three or four icons evenly, pointing at one names its page, and double-clicking renames the page you clicked. ([#160](https://github.com/ZigaoWang/zigzag/issues/160))
- Install as App, in the File menu and the ⋯ menu of a site's controls, makes the site an app of its own in your Applications folder, with its icon in the Dock and in ⌘Tab. It opens right away in its own window, signed in as you are in Zigzag, and a link to another site opens in Zigzag. Settings › General lists your apps, to remove one. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#165](https://github.com/ZigaoWang/zigzag/issues/165))
- An installed app's toolbar takes the site's own color, as web apps do in Chrome and Safari, with the app's name in the middle. Hide it for just the page, with the window's buttons over it, from View › Hide Toolbar, a right-click on the toolbar, or the app's Toolbar switch in Settings › General. ([#165](https://github.com/ZigaoWang/zigzag/issues/165))
- An installed app has menus of its own while its window is in front: Hide and Quit name it, ⌘Q quits just that app, and the browser's New Tab and the rest aren't there. ([#165](https://github.com/ZigaoWang/zigzag/issues/165))
- The sidebar can sit on the right: turn on Sidebar on the right in Settings › Appearance, or choose View › Move Sidebar to Right. The page moves left, the window's buttons stay at its top left, panels and the mini player follow, and a hidden sidebar comes out from the right edge. The Show Sidebar button moves to the right end of the bar above the page and stays in one place whether the sidebar is shown or hidden. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#166](https://github.com/ZigaoWang/zigzag/issues/166))
- Dark pages are drawn by [Dark Reader](https://darkreader.org)'s engine, with its fixes for thousands of sites. A site's own colors are made dark one by one, instead of the page being turned over with a filter and patched up afterward, so sites written with newer kinds of colors, like Cloudflare's dashboard, no longer stay mostly light. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#134](https://github.com/ZigaoWang/zigzag/issues/134))
- Force dark, in a site's controls, draws a site dark even when it looks dark already, for one that leaves parts of itself light. ([#134](https://github.com/ZigaoWang/zigzag/issues/134))
- Ad blocking also uses uBlock Origin's filter lists, matched by Ghostery's open source adblocker engine. Zigzag downloads the lists and keeps them up to date on its own, so YouTube and other sites that change how they serve ads keep working without waiting for a Zigzag update. On YouTube they replace Zigzag's own script, which could stop a video at "Something went wrong. Please try again later." ([#129](https://github.com/ZigaoWang/zigzag/issues/129))
- Cookie pop-ups are answered with no for you: Zigzag turns down the cookies a site's consent pop-up asks for, or hides one that only needs hiding, and never says yes. It knows OneTrust, Cookiebot, Didomi, Sourcepoint and over a thousand more, through DuckDuckGo's [Autoconsent](https://github.com/duckduckgo/autoconsent), the same rules DuckDuckGo's browsers use. Choose Leave Alone for Cookie banners in Settings › Privacy to answer them yourself, or turn it on or off for one site in its controls, which say "Rejected on this site" once it has. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#175](https://github.com/ZigaoWang/zigzag/issues/175))
- Site Controls is rebuilt. Its first page shows the site, the quick actions, the switches for the page you're on, and one line each for Connection, Permissions and Extensions with what's there at a glance ("Secure", "2 allowed"). Each opens a page of its own in the same panel, with a way back. Zoom is − 100% +, and clicking the percentage puts the page back to 100%. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#174](https://github.com/ZigaoWang/zigzag/issues/174))
- Connection in Site Controls shows the site's certificate chain, from the site up to the root: who each certificate was issued to and by, when it's valid, its key and SHA-256 fingerprint, and whether macOS trusts it. A plain http page just says Not secure. ([#174](https://github.com/ZigaoWang/zigzag/issues/174))
- Permissions in Site Controls lists the camera and microphone, location, notifications and pop-ups once a site has asked for them, each set to Ask, Allow or Block. Blocked pop-ups are blocked without a notice, and Reset Permissions forgets every answer the site was given. Extensions lists your extensions, whether each runs on the site, and Manage Extensions. ([#174](https://github.com/ZigaoWang/zigzag/issues/174))
- Zigzag Mini's bar takes the page's color, as an installed app's toolbar does, so a dark site isn't topped by a light bar, and the page meets it edge to edge.
- The mini player can leave the window: drag it anywhere on screen, over other apps too, and it stays on top on every space, as Picture in Picture does. Let go outside the window and it rests in the screen's nearest corner; over the window, in the page's corner as before. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#172](https://github.com/ZigaoWang/zigzag/issues/172))
- A video's full screen can fill just its page, with the sidebar and the rest of the window still there: choose The Page for Full screen videos fill in Settings › Tabs, or turn on Full screen fills the page in a site's controls, for YouTube alone say. In a split, the video fills its own part. Esc, or the player's own button, leaves it. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#168](https://github.com/ZigaoWang/zigzag/issues/168))
- Tabs move between windows as they are, without loading again: drag a tab into another window's sidebar, where a line shows where it lands, or onto its page. Let go outside Zigzag and it opens in a window of its own. A window left with no tabs closes, as in Chrome, and ⌘Z brings the tabs back. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#167](https://github.com/ZigaoWang/zigzag/issues/167))
- Open in Zigzag Mini, in a tab's right-click menu, moves the page into a Zigzag Mini window as it is, history and all, and ⌘Z puts the tab back. Hold Option as you drag a tab out of the window to do the same. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#164](https://github.com/ZigaoWang/zigzag/issues/164))
- In the icon choices for a space, a folder or a tab, type a name like "cat" or "rocket" in the field under the grid to find matching emoji. Click one or press Return to pick it, and Esc goes back to the icons. Letters used to vanish as you typed. Thanks to [thekevinbrown](https://github.com/thekevinbrown). ([#163](https://github.com/ZigaoWang/zigzag/issues/163))
- Middle-click the address to close the tab you're on, as a middle-click on its row in the sidebar does. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#171](https://github.com/ZigaoWang/zigzag/issues/171))
- A sleeping tab's preview says why it sleeps and about how much memory that freed, like "Asleep to save memory. Freed about 180 MB." Its icon has a thin, even dashed ring instead of chunky dots. ([#140](https://github.com/ZigaoWang/zigzag/issues/140))
- The "Zigzag updated" note goes away by itself after 15 seconds, like a notification, and stays while your pointer is on it. What's New is still in the Help menu.
- In Change Icon, the first choice shows the site's own icon, so it's clear that it puts the site's icon back.

### Fixed
- Tampermonkey works again once its popup has been opened. The open popup cut off every connection its scripts made to it, so they kept reconnecting, hundreds of times a second, and their menu commands never showed.
- In split view with the address bar above the page and Borderless page off, each page and its strip of buttons and address are one card, in the page's own color, instead of a strip floating on the window over the page. The strip's buttons keep clear of the card's corners, and its address field fills the room between them.
- Dark pages in the PDF viewer keep their pictures as they are: a photo is no longer shown as a negative. Text and lines still go dark, and so does a scanned page. ([#226](https://github.com/ZigaoWang/zigzag/issues/226))
- A page's question to open an app comes up in Zigzag Mini or an installed app's window, over its own page. It used to come up in a browser window behind, so claude.ai's Open Claude seemed to do nothing in Zigzag Mini.
- The hidden sidebar comes out sooner when you reach for the window's edge, and also when another screen sits beside the window and the pointer runs a little onto it. ([#206](https://github.com/ZigaoWang/zigzag/issues/206))
- The hidden sidebar no longer flickers as it slides out or back: it could show for one frame where it was headed, out or gone, before sliding there, which looked like it opened, closed and opened again. ([#206](https://github.com/ZigaoWang/zigzag/issues/206))
- A page's button that opens an app, like claude.ai's Open Claude after signing in, always asks when you click it, even right after an earlier question from the page was put off.
- Web apps hear their keyboard shortcuts before Zigzag's menus, as in Safari and Chrome: ⌘A and ⌘B in Google Docs, ⌘K in Slack, Linear and Notion, ⌘[ to indent, and the rest. Only the browser's own keys stay Zigzag's whatever the page wants (new and closed tabs, windows, the address, reload, spaces, quitting), and shortcuts you changed in Settings › Shortcuts stay the browser's on their new keys. ([#219](https://github.com/ZigaoWang/zigzag/issues/219))
- A page's own Print button works, as in Safari: a school report card's or a receipt's Print brings up the print panel on the window, as ⌘P does, and the page waits until you've printed or canceled.
- Zigzag Mini has Site Controls, the same button as by a browser window's address, at the right of its strip before Keep on Top, so you can turn Dark page on or off for a site, set its zoom, ad blocking or permissions, and clear its data, without opening the page in a browser window first. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#225](https://github.com/ZigaoWang/zigzag/issues/225))
- Site Controls' Certificate page scrolls when its details are taller than the window has room for, its back button and title staying at the top; choosing another certificate in the chain no longer leaves its details cut off at the panel's edge. ([#220](https://github.com/ZigaoWang/zigzag/issues/220))
- A quick move to the window's edge, with the desktop or another display beside it, brings the hidden sidebar out in one slide. It could run on past the edge and send the sidebar back before your hand came back, or go out too far for the window to notice it at all; now the pointer has a moment to come back, and the sidebar stays out. ([#206](https://github.com/ZigaoWang/zigzag/issues/206))
- Animations share one set of timings: presses and hovers answer in about a tenth of a second, small changes like a switch take a moment longer, panels and menus grow out of what opened them and leave quicker than they came, and the sidebar, notices and the window's layout slide on one curve. Switching spaces fades the window's color, gradient and grain together, a switch's knob and color move in step, and nothing bounces. With Reduce Motion, nothing travels: things crossfade, or change at once. ([#217](https://github.com/ZigaoWang/zigzag/issues/217))
- Security fixes from a private report: pictures from websites and PDFs are each read in a sandboxed helper, user scripts run apart from the extension that installed them, ad blocking only runs scriptlets this version knows, a page can't open another app without asking, a certificate you visit anyway shows as not secure, Stop really cuts off AI apps, and extension packages and permissions are checked more strictly.
- Clicks, scrolls and the pointer over Site Controls and Zigzag's other panels stay in the panel: the tabs under it no longer light up, a sideways scroll no longer switches spaces behind it, and pressing on the panel never drags the window. ([#216](https://github.com/ZigaoWang/zigzag/issues/216))
- Rows in Site Controls, like the certificate chain's, sit a little apart, so the chosen one and the one under the pointer no longer run together.
- Importing from Arc brings only what you choose: Spaces and Pinned Tabs, Bookmarks and Open Tabs each bring their own part, open tabs without their spaces go to a space of the same name or the one you're in, and tabs you closed in Arc stay closed. ([#210](https://github.com/ZigaoWang/zigzag/issues/210))
- Each tab translates on its own, in Peek too: starting a translation in another tab no longer stops the first, its notice shows only while you're on that page, and a page that can't be translated goes back to its own text instead of staying half done. ([#218](https://github.com/ZigaoWang/zigzag/issues/218))
- An extension that sends a message to a tab gets the first answer, instead of waiting forever when a user script on the page is listening but never answers.
- Screen sharing in a web meeting can share a single window, not only a whole screen. When a site asks to share your screen, Zigzag offers Share Window… and Share Screen…, as Safari does, and macOS's picker comes up for the one you chose. ([#211](https://github.com/ZigaoWang/zigzag/issues/211))
- A video in Picture in Picture stays on screen when you switch to another app or desktop, floating over everything as it does in Safari, until you close it. It used to go behind the next app and stay on the desktop it started on. Thanks to [alextend](https://github.com/alextend). ([#210](https://github.com/ZigaoWang/zigzag/issues/210))
- A space with no tabs shows the empty page card, with its shadow and its own color apart from the sidebar's, instead of the sidebar's color running across the whole window. Thanks to [alextend](https://github.com/alextend). ([#210](https://github.com/ZigaoWang/zigzag/issues/210))
- The Import window with no other browser on the Mac says No other browsers found on this Mac, and offers Choose File… for a passwords .csv or Safari's export. Its choices used to pile up in the window's top-left corner. ([#212](https://github.com/ZigaoWang/zigzag/issues/212))
- Every page of a split view has the same rounded corners on all four sides, whichever edge of the window, gap or bar it meets: side by side, stacked, three or four pages, with the sidebar on either side and in full screen. The corners along the window's edge were square, and in full screen they didn't match the others. ([#203](https://github.com/ZigaoWang/zigzag/issues/203))
- A split's row in the sidebar lines up with the tabs around it: each page's icon sits where a tab's does, the first right under the icons above it, with titles where there's room, and the page you're in is shown lit in the row you're on. The same in the pinned list and folders, at every sidebar size. ([#203](https://github.com/ZigaoWang/zigzag/issues/203))
- A split view of three or four pages pins, becomes a favorite and goes into a folder as a split of two does: one row in the sidebar, or one favorite with a small icon for each page placed as the pages are, that opens every page laid out as before, comes back after a restart, and unpins or moves back to Tabs as it was. Pinning one used to pin a single page and leave the others behind, and ⌘Z then left a page missing; one ⌘Z now puts every page back where it was. Double-click a page in a pinned split's row to rename that page. ([#203](https://github.com/ZigaoWang/zigzag/issues/203))
- Show All under Stored by Websites opens at once and the list scrolls smoothly, even with thousands of sites. Before, every site's row was made at once, with a hitch on the click and a slow scroll. ([#207](https://github.com/ZigaoWang/zigzag/issues/207))
- 中语智汇 (web.zyamoy.com) and other sites that need FingerprintJS 2 to start open again instead of staying blank. Ad and tracker blocking stops that library, and these sites gave up without it; now they get a harmless stand-in that tells them nothing about your Mac. ([#202](https://github.com/ZigaoWang/zigzag/issues/202))
- DeepSeek no longer tells you to check your browser extensions. Ad and tracker blocking stops its telemetry, and it took that as an ad blocker getting in the way; now the blocked telemetry gets an empty answer inside the page, so nothing is sent and the site works as usual. ([#208](https://github.com/ZigaoWang/zigzag/issues/208))
- Tabs that come back after you quit and reopen Zigzag no longer look loaded before they are. A tab whose page isn't running now looks the same however it got there: in the Tabs list it has the thin dashed ring a sleeping tab has, and a pinned page or favorite has its open edge only while its page is loaded. Its hover card says why: asleep to save memory, or not loaded since Zigzag reopened. Clicking it loads it, as before. ([#205](https://github.com/ZigaoWang/zigzag/issues/205))
- A page that goes full screen no longer starts with a band along its top, so sites that measure themselves when full screen starts get their real size.
- Settings › Extensions names what won’t work for an extension, like “Side panel and notifications won’t work in Zigzag.”, instead of “2 features won’t work here” with the names hidden in a tooltip.
- The hidden sidebar slides out the same way however fast you move to the window's edge. A quick move could run on past the edge, so the sidebar came out, went back and came out again; now a quick move counts as meaning it, and the sidebar comes out in one smooth slide, as with a slow one. Touching the edge on the way somewhere else still leaves it hidden. ([#206](https://github.com/ZigaoWang/zigzag/issues/206))
- Dark pages notice when a site switches its own theme. A site that starts dark and turns light from its own theme menu is drawn dark, and one that turns dark is left as it is, without reloading. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#134](https://github.com/ZigaoWang/zigzag/issues/134))
- The bar above the page, split view's strips and Zigzag Mini's bar follow a page that changes color after it loads, like a dark app drawn over a white page or a site switching its theme, instead of staying white. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#134](https://github.com/ZigaoWang/zigzag/issues/134))
- YouTube Music goes on to the next song in a tab you're not looking at. It stopped at the end of each song, stuck loading until you paused and played again: a page out of the window can't load its next song, so a tab playing sound now stays in the window, out of sight, and the mini player keeps a page there as its card goes between two songs. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#199](https://github.com/ZigaoWang/zigzag/issues/199))
- After Set as Default in Settings › General, the button changes as soon as macOS confirms, instead of needing a second click. Thanks to [ze-mu-zhou](https://github.com/ze-mu-zhou). ([#195](https://github.com/ZigaoWang/zigzag/issues/195))
- Translate translates every part of a page that isn't in your language, not only a page that's all in another one. An English page with a paragraph of Chinese or a quote in Japanese has just those translated, and a page in Chinese keeps its English code as it is. It says the page is already in your language only when all of it is. Translating another page in the same language in one window, or a page you went to from a translated one, works too. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#197](https://github.com/ZigaoWang/zigzag/issues/197))
- The Motrix extension pairs with the Motrix app. Pair said it couldn't connect before it reached the app: the extension didn't recognize the address Zigzag gives its own files, and now it gets Chrome's for the one check that needs it.
- The sidebar slides out smoothly when it's hidden, in full screen too.
- The sidebar that slides out is the same color as when it's shown, in see-through spaces too.
- Tampermonkey BETA works as the stable Tampermonkey does. It stopped as it started, so its popup never loaded and no script ever ran. Now it starts, a script's .user.js address opens its install page, and its scripts run, on sites that allow no inline scripts too. ([#200](https://github.com/ZigaoWang/zigzag/issues/200))
- With the sidebar on the right and the address bar in the sidebar, the page runs up to the top of the window as it does beside a left sidebar, with no strip above it. The window's buttons sit at the start of the sidebar's top row, then the sidebar button, with back, forward and reload at its end, the same row as on the left. With the address bar above the page, they stay at the start of that bar. ([#166](https://github.com/ZigaoWang/zigzag/issues/166))
- Installing an extension with no background page, like some that only change pages, no longer quits Zigzag. ([#194](https://github.com/ZigaoWang/zigzag/issues/194))
- Switching Borderless page with Settings open no longer leaves Settings laid out for the size it had: a scroll bar's strip beside the list of sections, a white band under it, and the switches out of line with the search field. Settings now moves with its page as the page takes or gives up its margin, and the page's corners and shadow follow the move instead of jumping to where they end. Thanks to [vandenbulckjean](https://github.com/vandenbulckjean). ([#184](https://github.com/ZigaoWang/zigzag/issues/184))
- A permission set to Ask asks every time, as in Safari: answering a site's question for the camera, microphone, location or notifications holds for that page only, and the site asks again on its next visit. Allow and Block are kept, chosen in Site Controls, Settings › Privacy, or the address bar's camera button with Always Allow on This Site. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#174](https://github.com/ZigaoWang/zigzag/issues/174))
- Find on page counts exactly the matches it goes through, as Safari does: hidden text, scripts and words running across two paragraphs no longer count, and matches in frames do. The count is read again when the page finishes loading. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#180](https://github.com/ZigaoWang/zigzag/issues/180))
- A zoomed page of a split goes back in its place when the pages swap, move or change layout, as it does when one comes or goes. ([#160](https://github.com/ZigaoWang/zigzag/issues/160))
- With the address bar above the page and a split stacked, zooming the top page no longer brings back the bar's own buttons and address beside it. ([#160](https://github.com/ZigaoWang/zigzag/issues/160))
- The mini player goes to the screen's corner while its window is on another space, instead of the corner of a window you can't see, and letting it go where that window would be no longer snaps it there. Closing the window while the player has the keyboard no longer brings that window forward for a moment. ([#172](https://github.com/ZigaoWang/zigzag/issues/172))
- Peek takes the page's own color around it, as split view's pages do, so a page drawn dark no longer has a light strip across its top. ([#134](https://github.com/ZigaoWang/zigzag/issues/134))
- An extension's items in a page's right-click menu show once, not twice (Bitwarden's, for one). Thanks to [rocavence](https://github.com/rocavence). ([#186](https://github.com/ZigaoWang/zigzag/issues/186))
- Restarting to install an update brings back everything that was open, Zigzag Mini windows included, with your windows, spaces, tabs and splits saved the moment the update restarts Zigzag.
- A site that's dark on its own gives the bar above it, Zigzag Mini's bar and an installed app's toolbar its dark again with dark pages off, instead of white. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#134](https://github.com/ZigaoWang/zigzag/issues/134))
- With the sidebar on the right and the address bar beside the tabs, the strip above the page no longer holds the window's buttons alone: back, forward and reload sit right after them, as in the bar above the page. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#181](https://github.com/ZigaoWang/zigzag/issues/181))
- A long site name in Site Controls no longer loses its start ("…mini.google.com"): it shrinks a little to show whole, its subdomains quieter than the domain that says whose site it is, and only when there's still no room do whole subdomains give way, never the domain itself. The full name is in its tooltip and for VoiceOver. Peek, Zigzag Mini, a split page's strip and an installed app's bar keep a site's domain whole too, and a long profile name that's cut short shows in full on hover. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#189](https://github.com/ZigaoWang/zigzag/issues/189))
- With the address above the page, a zoomed pane in split view keeps its strip, with its address and buttons, on top of it, instead of leaving it behind in the bar. ([#160](https://github.com/ZigaoWang/zigzag/issues/160))
- Site Controls opened from a pane in split view closes when the panes move, as when the split ends, a pane is zoomed or two swap, instead of staying where the pane's strip was. ([#160](https://github.com/ZigaoWang/zigzag/issues/160))
- With Site Controls or Downloads left open in one window, the button in another window opens them there on the first click, instead of only closing the other window's. Link previews and Esc in Reader no longer wait on a panel open in another window.
- An installed app opened again right after its window closed, from the Dock or Finder, opens its window, instead of leaving its Dock icon with no window. ([#165](https://github.com/ZigaoWang/zigzag/issues/165))
- Dragging a pinned page's pane out of the window in split view no longer opens an empty window and unloads the pinned page. Pinned pages belong to every window, so it stays where it is. ([#160](https://github.com/ZigaoWang/zigzag/issues/160))
- In Show All Tabs, a split of a pinned page and a tab shows both pages on its card, each on its own side, and the card is the one picked when you're on the pinned page. It showed only the tab.
- Zigzag no longer crashes going back, forward or to a link after a while of browsing with an extension on. Each change of site could give the extension's scripts one more copy, until there were too many to hand a new page. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#178](https://github.com/ZigaoWang/zigzag/issues/178))
- With dark pages on, a site with a dark look of its own, like GitHub or YouTube Music, is left exactly as it is, even with little on the page, instead of being painted partly light. It no longer flashes white before its dark theme shows, on the first visit or after a restart, and the bar above it is dark too. Zigzag remembers which sites are dark for each profile, and forgets them when you clear the site's data or History. ([#134](https://github.com/ZigaoWang/zigzag/issues/134))
- In split view, a mouse's back and forward buttons and a swipe go back or forward in the page under the pointer, which becomes the page you're in, instead of in whichever page you were last in. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#170](https://github.com/ZigaoWang/zigzag/issues/170))
- The strip over each page in split view reads clearly on dark pages: its address and buttons turn light, as the bar above the page does. ([#160](https://github.com/ZigaoWang/zigzag/issues/160))
- With the sidebar hidden, moving the pointer across the window's edge on its way somewhere else, like a display on that side, no longer pulls the sidebar out and leaves it there. It opens when the pointer rests at the edge or just past it, and goes once the pointer is well away. It also no longer slides in under the address while you're editing it, under Site Controls or Downloads, or under the command bar. Thanks to [vandenbulckjean](https://github.com/vandenbulckjean) for the fix. ([#176](https://github.com/ZigaoWang/zigzag/issues/176))
- Show All Tabs opens smoothly, the first time too, and closes onto another tab without a pause.
- Peek's top strip is as slim as a split view's and its frame thinner, so the page gets more room. Pages in Peek keep their own scrollbars, as in Safari, instead of one Peek put on every page, always showing.
- Notes at the top of the page slide back up when they go, the way they came down, instead of vanishing. Notes with a button, like Undo or Pin This Page, have a close button, and the note after closing a pinned tab is shorter.
- In a short window, the list of sections in Settings scrolls instead of running off the bottom. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#169](https://github.com/ZigaoWang/zigzag/issues/169))
- In Settings › Privacy, the Block ads and trackers switch stays at the right edge when you turn it on or off.
- Extensions know about pinned tabs and favorites as soon as they open, so 1Password's passkeys and other extension features work on them instead of failing with "Tab not found".
- Cloudflare's "verify you are human" check (Turnstile) no longer logs an error each time it renews, as on linux.do.

## [0.8.6] - 2026-11-12

### New
- Settings' sections sit under headings: Browser, Tools, Privacy & Security and Advanced.

### Fixed
- On macOS 27, sign-in fields show the key icon and open the Mac's AutoFill panel even when a password manager like Dashlane or 1Password does the filling instead of Zigzag, so its logins can be picked there. ([#57](https://github.com/ZigaoWang/zigzag/issues/57))
- ⌘Z and ⇧⌘Z reach the page first, so web apps like Google Sheets undo their own changes. Zigzag's own undo for the sidebar still works when the page lets the key pass. Thanks to [Lakeland97](https://github.com/Lakeland97).
- Google Sheets stays sharp instead of turning blurry a moment after it opens: pages now know the size of the window they're in. ([#161](https://github.com/ZigaoWang/zigzag/issues/161))
- With dark pages on, new tabs and tabs waking from sleep no longer flash white, and a site's saved dark colors are checked on the first frame. Thanks to [Lakeland97](https://github.com/Lakeland97). ([#134](https://github.com/ZigaoWang/zigzag/issues/134))
- The loading line is back along the top of the page; 0.8.5 drew it at the bottom.
- In Change Icon, clicking the chosen icon again or deleting the emoji puts the site's own icon back. ([#153](https://github.com/ZigaoWang/zigzag/issues/153))

## [0.8.5] - 2026-11-12

### New
- AI apps can use Zigzag over MCP, if you turn it on in Settings › Automation: list, open and read your tabs, take screenshots, click and type. It only works on this Mac, needs a key, and never touches private windows, passwords or Zigzag's own pages. A tab an app is using says so, with Stop. Copy Setup and Copy Prompt get an app connected in one paste. ([#99](https://github.com/ZigaoWang/zigzag/issues/99))
- Settings is grouped, and Automation has its own pane. ([#99](https://github.com/ZigaoWang/zigzag/issues/99))
- Give a tab, pinned tab or favorite its own emoji or symbol: right-click › Change Icon…, and Use Site Icon to go back. ([#153](https://github.com/ZigaoWang/zigzag/issues/153))
- Dark pages draw a light site in a dark version of its own colors after your first visit, so photos and colors stay true and the page is dark from the first frame. The old filter is still there for sites it can't read. ([#134](https://github.com/ZigaoWang/zigzag/issues/134))
- Dark pages handle pictures in frames, web components and backgrounds better, and there's a Pure black option. ([#134](https://github.com/ZigaoWang/zigzag/issues/134))
- The mini player resizes from any edge or corner, snaps to the page's corners (hold ⌘ to place it anywhere), remembers its size and place, and takes Space and Esc. ([#156](https://github.com/ZigaoWang/zigzag/issues/156))
- On the Chrome Web Store, the store's own button reads Add to Zigzag and installs through Zigzag. Thanks to [philigrin](https://github.com/philigrin) for working out how. ([#130](https://github.com/ZigaoWang/zigzag/issues/130))
- Closing a tab whose nested tabs are folded away closes them too, with Undo. ([#155](https://github.com/ZigaoWang/zigzag/issues/155))

### Fixed
- Folders shut again when their pages are open. ([#154](https://github.com/ZigaoWang/zigzag/issues/154))
- The mini player only follows a video you were watching, not a muted preview on the page you left. ([#156](https://github.com/ZigaoWang/zigzag/issues/156))
- Two-finger swipes go back and forward the way your Mac scrolls, as in Safari. Thanks to [philigrin](https://github.com/philigrin). ([#147](https://github.com/ZigaoWang/zigzag/issues/147))
- Pages embedded from sites you've never opened get their cookies, so shared chat artifacts and similar embeds open. Thanks to [vandenbulckjean](https://github.com/vandenbulckjean). ([#143](https://github.com/ZigaoWang/zigzag/issues/143))
- A Web Inspector docked to the side stays with its own tab and isn't covered by the address bar. Thanks to [vandenbulckjean](https://github.com/vandenbulckjean). ([#148](https://github.com/ZigaoWang/zigzag/issues/148))
- With the bar above the page, showing and hiding the sidebar slides smoothly and the address keeps room at its end. Thanks to [vandenbulckjean](https://github.com/vandenbulckjean). ([#151](https://github.com/ZigaoWang/zigzag/issues/151))
- 1Password connects to its Mac app when your only Chrome-family browser is Vivaldi, Arc or a beta. ([#145](https://github.com/ZigaoWang/zigzag/issues/145))

## [0.8.4] - 2026-11-11

### New
- Passwords… opens your Mac's AutoFill panel right at the page's field, and macOS fills the login in. It's also in a field's right-click menu under AutoFill, and on the key icon in sign-in fields. ([#132](https://github.com/ZigaoWang/zigzag/issues/132))
- YouTube ads are blocked without touching YouTube's own dialogs or scrolling. If you use an ad blocker extension like uBlock Origin Lite or AdGuard, it takes over on YouTube. ([#129](https://github.com/ZigaoWang/zigzag/issues/129))
- Importing from Chrome or another browser with several profiles brings each profile over as its own space, named after it. Importing again adds to the same spaces. ([#131](https://github.com/ZigaoWang/zigzag/issues/131))
- Help › Keyboard Shortcuts opens the list of shortcuts. ([#122](https://github.com/ZigaoWang/zigzag/issues/122))
- Settings search finds startup, homepage, dark mode and default browser settings by the words you'd use. ([#121](https://github.com/ZigaoWang/zigzag/issues/121))
- Tabs that Zigzag put to sleep show a dotted ring round their icon, like Chrome, and say why when you point at them. ([#140](https://github.com/ZigaoWang/zigzag/issues/140))

### Fixed
- A background tab is never put to sleep for using a lot of energy without warning: Zigzag says it'll sleep in 2 minutes, with Keep Awake to leave it alone. A quiet tab is no longer blamed for another tab's work. ([#140](https://github.com/ZigaoWang/zigzag/issues/140))
- With a proxy running on your Mac (like Clash), a mistyped address says Zigzag can't open the site and names the proxy, instead of blaming the network. An empty server error shows an error page instead of a blank one. ([#137](https://github.com/ZigaoWang/zigzag/issues/137))
- The getting started guide matches the app: the overview shows real pages, the guide stays inside the window, and each step names the shortcut you set. ([#133](https://github.com/ZigaoWang/zigzag/issues/133))
- A pinned page in a split shows as one row in the sidebar. ([#114](https://github.com/ZigaoWang/zigzag/issues/114))
- Narrow split panes keep the address and the close button. ([#115](https://github.com/ZigaoWang/zigzag/issues/115))
- Switches fill with your accent color when they're on. ([#116](https://github.com/ZigaoWang/zigzag/issues/116))
- Site Controls offers Get Extensions when you have none. ([#117](https://github.com/ZigaoWang/zigzag/issues/117))
- Chinese says 个人资料 for profiles everywhere, and the translate row names the language. ([#118](https://github.com/ZigaoWang/zigzag/issues/118))
- New Space reads the same everywhere. ([#119](https://github.com/ZigaoWang/zigzag/issues/119))
- History shows the time once, on each row. ([#120](https://github.com/ZigaoWang/zigzag/issues/120))
- Site data labels lost a stray full stop. ([#122](https://github.com/ZigaoWang/zigzag/issues/122))
- The command bar lists Settings once, and rows don't repeat their title in grey. ([#135](https://github.com/ZigaoWang/zigzag/issues/135), [#136](https://github.com/ZigaoWang/zigzag/issues/136))
- Zigzag Mini's recent list leaves out pages that failed to load. ([#136](https://github.com/ZigaoWang/zigzag/issues/136))

## [0.8.3] - 2026-11-11

### New
- The sidebar's + button and a right-click on empty sidebar space open Zigzag's own menu: New Tab, New Folder and New Space…, with their shortcuts. ([#100](https://github.com/ZigaoWang/zigzag/issues/100))
- Zigzag follows Increase Contrast and Reduce Transparency: lines, edges and quiet text get stronger, and panels go solid. ([#105](https://github.com/ZigaoWang/zigzag/issues/105))
- Claude's side panel opens in Zigzag, so you can sign in and chat with it. ([#112](https://github.com/ZigaoWang/zigzag/issues/112))

### Fixed
- YouTube scrolls again after its ad blocker warning is hidden. ([#113](https://github.com/ZigaoWang/zigzag/issues/113))
- A minimized mini player keeps playing a muted or silent video. ([#111](https://github.com/ZigaoWang/zigzag/issues/111))
- The ⌃Tab switcher stays on the page beside the sidebar, with many tabs in rows. ([#110](https://github.com/ZigaoWang/zigzag/issues/110))
- Site Controls never leaves an action alone on a row, and its site switches are spaced like the rest of Zigzag. ([#104](https://github.com/ZigaoWang/zigzag/issues/104))
- Delete buttons in Settings show when you point at a row, the same everywhere. ([#101](https://github.com/ZigaoWang/zigzag/issues/101))
- Settings › Passwords reads more clearly with more than one profile, the Shortcuts hint wraps in a narrow window, and Chinese uses one word for filling. ([#106](https://github.com/ZigaoWang/zigzag/issues/106), [#107](https://github.com/ZigaoWang/zigzag/issues/107), [#108](https://github.com/ZigaoWang/zigzag/issues/108))
- Saving your session skips writes that would change nothing. ([#89](https://github.com/ZigaoWang/zigzag/issues/89))

## [0.8.2] - 2026-11-11

### Fixed
- Split view with the address bar above the page has one set of controls: each page's own bar moves into the top row, instead of repeating back, reload and the address. ([#97](https://github.com/ZigaoWang/zigzag/issues/97))
- iCloud Passwords and other extensions that talk to an app on your Mac stay connected in every profile, instead of asking for a new code after a couple of minutes. ([#98](https://github.com/ZigaoWang/zigzag/issues/98))
- Passwords… stays open until you pick a login or move on, instead of closing straight away. ([#96](https://github.com/ZigaoWang/zigzag/issues/96))
- A pinned page you've opened shows under its folder even when the folder is shut, as in Arc. ([#94](https://github.com/ZigaoWang/zigzag/issues/94))
- Holding ⌥⌘ and dragging moves the window from anywhere in it, Settings and an empty window included. ([#95](https://github.com/ZigaoWang/zigzag/issues/95))
- Zigzag starts a little faster, and a freeze note from Help › Report a Problem says what was running. ([#89](https://github.com/ZigaoWang/zigzag/issues/89))

## [0.8.1] - 2026-11-11

### New
- Keep tabs awake: a switch in Site Controls keeps a site's tabs from sleeping in the background. Sites you keep awake are listed in Settings › Privacy › Sites. ([#91](https://github.com/ZigaoWang/zigzag/issues/91))
- Passwords… in the password menu opens the Passwords app and password manager apps like Dashlane and 1Password, and fills the login you pick. On macOS 27, sign-in fields show the key icon. ([#57](https://github.com/ZigaoWang/zigzag/issues/57))
- Right-click empty space in the sidebar for New Tab, New Folder and New Space, and the + button offers New Space or New Folder, even with a single space. ([#87](https://github.com/ZigaoWang/zigzag/issues/87))

### Fixed
- Zigzag no longer stalls with many tabs open. Dark pages, extension badges, memory warnings, saving, history and site icons stopped holding it up, and a freeze note in Help › Report a Problem now says what was running. ([#89](https://github.com/ZigaoWang/zigzag/issues/89))
- Favorites keep their page when you leave them: an everyday memory warning from macOS no longer puts them to sleep, and a busy favorite is pointed out instead. A page that does come back returns to where you were, forums like Discourse included. ([#65](https://github.com/ZigaoWang/zigzag/issues/65), [#88](https://github.com/ZigaoWang/zigzag/issues/88))
- Extensions stay signed in after you sign in on their website, and can sign out. Thanks to [sheauhuu](https://github.com/sheauhuu) for the fix. ([#93](https://github.com/ZigaoWang/zigzag/issues/93))
- A private window no longer saves a site's ad blocking or dark page choice. ([#92](https://github.com/ZigaoWang/zigzag/issues/92))

## [0.8.0] - 2026-11-11

### New
- Profiles: give a space its own sign-ins, extensions, history and favorites, so two accounts on one site or two wallets live side by side. Spaces on the same profile share everything, and with one profile nothing changes. Choose a space's profile in its editor, where New Profile… makes one. Thanks to [vandenbulckjean](https://github.com/vandenbulckjean) for building it. ([#61](https://github.com/ZigaoWang/zigzag/issues/61))
- Dark pages: Settings › Appearance can draw light websites dark, always or when your Mac is dark, with a switch for each site in Site Controls. Sites with their own dark theme are left as they are, and pictures and video keep their colors. ([#53](https://github.com/ZigaoWang/zigzag/issues/53))
- Nested tabs: turn on Settings › Tabs › Open ⌘-clicked links under their tab, and links you open in a new tab sit under the page they came from, folded away when you like. Closing the page moves its tabs up instead of closing them. ([#58](https://github.com/ZigaoWang/zigzag/issues/58))
- A playing video follows you in a mini player when you switch tabs. It shows just the video, without the site's own controls. Drag it anywhere in the window, minimize it to keep listening, or click its site name to go back. ([#17](https://github.com/ZigaoWang/zigzag/issues/17), [#69](https://github.com/ZigaoWang/zigzag/issues/69), [#71](https://github.com/ZigaoWang/zigzag/issues/71))
- With the address bar above the page, the bar takes the page's own color and reads as one card with it. Thanks to [philigrin](https://github.com/philigrin) for building it. ([#56](https://github.com/ZigaoWang/zigzag/issues/56))
- Reader sets the article in one calm column, with its source, author and reading time on top, and Find searches the article. ([#47](https://github.com/ZigaoWang/zigzag/issues/47))
- Each page in split view has its own close button, which leaves the other page. ([#70](https://github.com/ZigaoWang/zigzag/issues/70))
- Keep on Top: pin a pop-up or Zigzag Mini, or choose Window › Keep on Top, and it stays above your other apps. ([#72](https://github.com/ZigaoWang/zigzag/issues/72))

### Fixed
- YouTube no longer turns gray and stops taking clicks after its ad blocker warning is hidden. ([#86](https://github.com/ZigaoWang/zigzag/issues/86))
- Sound Booster, Shazam and other extensions hear streamed tabs like YouTube, and an extension asking for a tab another one is already listening to says which one has it. ([#45](https://github.com/ZigaoWang/zigzag/issues/45))
- The password menu opens when you click a field, even where the site lays its hint over the field, picking a login fills it, and sign-up fields list your saved logins under Use Strong Password. ([#68](https://github.com/ZigaoWang/zigzag/issues/68))
- Muting a tab leaves a call's camera and microphone as they were, the speaker shows the page's real state, and a favorite playing sound can be muted from its tile. ([#66](https://github.com/ZigaoWang/zigzag/issues/66))
- Favorites stay loaded when you leave them, unless your Mac is short of memory. ([#65](https://github.com/ZigaoWang/zigzag/issues/65))
- With the address bar above the page, the bar shows a sidebar button while the sidebar is hidden, lines up with the page, and stays still as the sidebar slides. ([#67](https://github.com/ZigaoWang/zigzag/issues/67))
- Picture in Picture's Return button brings its tab back from any tab. Thanks to [micsama](https://github.com/micsama) for the fix. ([#59](https://github.com/ZigaoWang/zigzag/issues/59))
- VoiceOver and the keyboard can open a space's menu in Settings again. Thanks to [vandenbulckjean](https://github.com/vandenbulckjean) for the fix. ([#54](https://github.com/ZigaoWang/zigzag/issues/54))
- Text typed into pages keeps its dashes and quotes, and your own text replacements work again. ([#49](https://github.com/ZigaoWang/zigzag/issues/49), [#52](https://github.com/ZigaoWang/zigzag/issues/52))
- Extensions that look for Chrome's named tab and window constants, like Coupert, work. ([#63](https://github.com/ZigaoWang/zigzag/issues/63))
- A tab that goes from one site to another drops the last site's icon. ([#69](https://github.com/ZigaoWang/zigzag/issues/69))
- Profiles and private windows keep to themselves: Reader, site icons, search suggestions, dark pages, Download Again and extension options no longer carry anything across. ([#76](https://github.com/ZigaoWang/zigzag/issues/76), [#81](https://github.com/ZigaoWang/zigzag/issues/81), [#82](https://github.com/ZigaoWang/zigzag/issues/82), [#83](https://github.com/ZigaoWang/zigzag/issues/83), [#84](https://github.com/ZigaoWang/zigzag/issues/84), [#85](https://github.com/ZigaoWang/zigzag/issues/85))
- Nested tabs keep their place when you reopen closed tabs or split one, and a link opened under a folded tab unfolds it. ([#77](https://github.com/ZigaoWang/zigzag/issues/77), [#78](https://github.com/ZigaoWang/zigzag/issues/78), [#79](https://github.com/ZigaoWang/zigzag/issues/79))
- The bar above the page takes the right color after leaving a page drawn dark. ([#75](https://github.com/ZigaoWang/zigzag/issues/75))
- Settings and the browser's menus, tooltips and previews are more consistent, and Find a Setting finds the new settings. ([#74](https://github.com/ZigaoWang/zigzag/issues/74), [#80](https://github.com/ZigaoWang/zigzag/issues/80))

## [0.7.9] - 2026-11-10

### New
- Bring everything over from more browsers: Orion, Helium, Comet, Yandex, Naver Whale, Chromium, Thorium, Chrome Beta, Dev and Canary, Brave Beta and Nightly, and Firefox Developer Edition and Nightly. Only the browsers on your Mac are listed. ([#41](https://github.com/ZigaoWang/zigzag/issues/41), [#46](https://github.com/ZigaoWang/zigzag/issues/46))
- Settings › Appearance › Address bar above the page: back, forward, reload and the address move into a slim bar above the page. Thanks to [philigrin](https://github.com/philigrin) for the idea. ([#20](https://github.com/ZigaoWang/zigzag/issues/20))
- Pin up to three extensions next to the address: hover an extension in Site Controls and click its pin. Thanks to [vandenbulckjean](https://github.com/vandenbulckjean) for building it. ([#22](https://github.com/ZigaoWang/zigzag/issues/22))
- Hold ⌃ to see each space's number for ⌃1–9, as holding ⌘ shows the tabs'. ([#43](https://github.com/ZigaoWang/zigzag/issues/43))
- Hold ⌥⌘ and drag anywhere on a page to move the window, handy with a borderless page and the sidebar hidden. ⌥⌘ double-click zooms it. ([#40](https://github.com/ZigaoWang/zigzag/issues/40))

### Fixed
- Rabby unlocks and reaches websites. Thanks to [vandenbulckjean](https://github.com/vandenbulckjean) for the fix. ([#12](https://github.com/ZigaoWang/zigzag/issues/12))
- Error pages say what happened in plain words, keep the site's name whole, and offer what fits: Try Again, Go Back, or Reload for a page that stopped. Details holds the exact error, ready to copy, and a page that failed while you were offline loads again once you're back online. ([#39](https://github.com/ZigaoWang/zigzag/issues/39))
- Clear keeps the tabs from what you're working on now. What counts as recent follows your own pace, so it no longer leaves only one or two tabs. ([#42](https://github.com/ZigaoWang/zigzag/issues/42))
- Hovering a tab shows and hides its highlight at once, and the find bar (⌘F) drops down from the top and goes back up. ([#44](https://github.com/ZigaoWang/zigzag/issues/44))
- Extensions see each tab's site icon, as in Sound Booster's list of tabs, and an extension that can't hear a streamed tab, as on YouTube, says so instead of failing quietly. ([#45](https://github.com/ZigaoWang/zigzag/issues/45))

## [0.7.8] - 2026-11-10

### New
- After an update, Zigzag says so and offers What's New, and the note waits until you've seen it. The notes show their links, credits and issue numbers. ([#33](https://github.com/ZigaoWang/zigzag/issues/33))
- Panels, menus, toasts, sheets and the find bar (⌘F) come and go with short, quiet motion that shows where they came from. The command bar and switching tabs stay instant, and Reduce Motion turns it all into a simple fade. ([#37](https://github.com/ZigaoWang/zigzag/issues/37))

### Fixed
- Swiping sideways in web apps like Excel scrolls the sheet instead of going back, even inside embedded frames, and a scroll that starts mid-sheet stays a scroll at the edge, as in Chrome. ([#38](https://github.com/ZigaoWang/zigzag/issues/38))
- Swiping on a PDF goes back and forward, as on any page. ([#36](https://github.com/ZigaoWang/zigzag/issues/36))
- Links Zigzag opens itself, like those in About, open in a tab instead of Zigzag Mini, and closing a Zigzag Mini you used alongside your windows keeps you in Zigzag. ([#34](https://github.com/ZigaoWang/zigzag/issues/34))
- A long site name keeps its start and its ending, in the address and Site Controls. ([#35](https://github.com/ZigaoWang/zigzag/issues/35))
- A dialog's title lines up with the text under it.

## [0.7.7] - 2026-11-10

### New
- Settings › Tabs › Swipe to go back and forward: turn it off and websites get every two-finger swipe. ([#30](https://github.com/ZigaoWang/zigzag/issues/30))

### Fixed
- Tabs you leave in the background stay as they were. They sleep after an hour out of sight instead of 15 minutes (after 15 minutes once more than 20 are awake, and after 5 only while your Mac is low on memory), and never while they have something you typed in them. ([#32](https://github.com/ZigaoWang/zigzag/issues/32))
- A tab that loads again comes back where you were, with the text you'd typed, but never passwords or card details. ([#32](https://github.com/ZigaoWang/zigzag/issues/32))
- When a page reloads because it used too much memory, or your Mac ran low, Zigzag says so. ([#32](https://github.com/ZigaoWang/zigzag/issues/32))
- A busy background tab gets three minutes, not one, before it's put to sleep for using a lot of energy. ([#32](https://github.com/ZigaoWang/zigzag/issues/32))
- A full-screen video keeps the whole screen, with no frozen strips, and going back to its tab doesn't take it out of full screen. Swiping over it no longer goes back a page. ([#31](https://github.com/ZigaoWang/zigzag/issues/31))
- Typing in the command bar never waits on your history, however big it is. History results and address completion join the list as they arrive. Thanks to [zemu](https://github.com/ze-mu-zhou) for measuring it. ([#29](https://github.com/ZigaoWang/zigzag/issues/29))

## [0.7.6] - 2026-11-10

### New
- Bring your extensions over from Chrome, Arc, Brave, Edge and other Chromium browsers. In Import (⇧⌘I), choose Extensions: you see each one with what they'll be able to do together, confirm once, and Zigzag adds them from the Chrome Web Store one at a time. ([#23](https://github.com/ZigaoWang/zigzag/issues/23))
- AppleScript: scripts, Shortcuts and AI agents can list windows and tabs, read a page's title, address and text, open, switch and close tabs, and go back, forward or reload, written the way Safari and Chrome take them. Running JavaScript in pages is off until you turn on Settings › General › Allow JavaScript from Apple Events, and private windows are never reachable. Examples are in [docs/automation.md](https://github.com/ZigaoWang/zigzag/blob/main/docs/automation.md). ([#26](https://github.com/ZigaoWang/zigzag/issues/26))

### Fixed
- Kondo works: its web app reaches the extension, and adding a LinkedIn account finishes. ([#25](https://github.com/ZigaoWang/zigzag/issues/25))
- Extensions that listen for cookie changes are told which cookie changed, and cookies saved by a Chrome-based browser can be set again.
- An extension's own page inside a website can reach its background, as in Chrome.

## [0.7.5] - 2026-11-10

### New
- Settings has its own sections for Appearance, Tabs, Search and Zigzag Mini, so General keeps just the basics. ([#28](https://github.com/ZigaoWang/zigzag/issues/28))

### Fixed
- Picture in Picture works on Bilibili, and sites' own Picture in Picture buttons work everywhere. Thanks to [micsama](https://github.com/micsama) for finding the cause and writing the fix. ([#18](https://github.com/ZigaoWang/zigzag/issues/18))
- In full screen, the window buttons no longer flash on the sidebar as it slides out. Thanks to [philigrin](https://github.com/philigrin). ([#21](https://github.com/ZigaoWang/zigzag/pull/21))
- 1Password and other extensions keep working after Zigzag restarts. Before, from the second launch on, their popup could spin forever. Thanks to [philigrin](https://github.com/philigrin) for tracking it down and writing the fix. ([#15](https://github.com/ZigaoWang/zigzag/issues/15))
- Swiping sideways in web apps that pan with two fingers, like Canva or Figma, moves around the page instead of going back. ([#27](https://github.com/ZigaoWang/zigzag/issues/27))
- Pinching always reaches the page, for maps and editors that zoom with it. ⌘⇧\ still shows all your tabs.
- What you type in the command bar is always the first row, so Return searches for it; Zigzag's commands come right under it.
- ← and → no longer play the error sound on pages that use them themselves, like seeking on YouTube.

### Security
- A page can't open Zigzag's Settings or History, in a new tab or by going back.
- A tab a page opens shows no address until a page really arrives in it, so it can't pose as another site.
- Visit Anyway on a certificate warning needs your own click on that warning.
- The password menu opens only when you click or tab into a field, and ignores clicks for its first moment. Logins from other parts of a site wait behind their own row.
- Zigzag offers to save only passwords you typed. A site's sign-in sheet fills in only the password saved for that exact address, and Fill from My Card fills only the fields you can see.
- Extensions stay out of private windows, and listen to a tab's sound only after you use them on that tab.
- An extension asks before it gets more access after you install it, opens downloads only after a click, and packages that hold file links aren't installed.
- Camera, microphone and location answers for a site embedded in another stay with that page.
- The Pop-up Blocked notice and other notices ignore clicks for their first half second, so a page can't time a misclick onto them.
- Exported passwords can't run as spreadsheet formulas, imported Chrome cookies keep their cross-site protection, and copies left by an interrupted import are cleared at launch.

## [0.7.4] - 2026-11-09

### New
- Zigzag Mini follows Settings › General › Borderless page: borderless, the page fills the window under the slim strip; otherwise it sits in a thin frame of your space's color.

### Fixed
- A link clicked in another app opens only Zigzag Mini. Your browser windows stay exactly where they were instead of coming up behind it, and closing it takes you back to the app you were in.
- One Esc closes Zigzag Mini, even on sites that keep Esc for themselves, like a search page with its cursor in an empty box. In a box you've typed in, or with a site's own dialog open, the first Esc goes there.
- Swiping back or forward in Zigzag Mini shows the same arrow as in a tab.
- An extension that listens to a tab (tabCapture) now hears only that tab. When a tab's sound can't be reached on its own, as with streamed video, the capture stops and the tab's sound comes back, instead of hearing everything Zigzag plays, other tabs and private windows included. Thanks to [zemu](https://github.com/ze-mu-zhou) for reporting it and writing the fix.

## [0.7.3] - 2026-11-09

### New
- 1Password, Bitwarden and other password extensions can fill a site's own sign-in box, the one a router, a test server or an admin page asks with, as they do in Chrome. When none answers, Zigzag's sign-in sheet offers the passwords you've saved for the site. ([#13](https://github.com/ZigaoWang/zigzag/issues/13))
- Drag a space's icon along the bottom of the sidebar to change the order of your spaces.
- The disk image welcomes you on Zigzag's own sky, sharp on Retina screens.

### Fixed
- Switching to Zigzag with ⌘Tab always brings its windows back; sometimes they stayed hidden.
- Importing a profile again after deleting its space brings the space back with its pages. Before, Import could show the last import's result and bring nothing over.
- Importing the same history again says nothing new came over, instead of counting it all again.

Thanks to [@philigrin](https://github.com/philigrin) for #13.

## [0.7.2] - 2026-11-09

### New
- Zigzag Mini takes after Arc's Little Arc: a slim strip in your space's color with the page's site in the middle, the space it belongs to on the left (click it to pick another), and Copy Link and Open in Work ⌘O, named for that space, on the right. The page sits in a thin frame of the space's color. A link from another app opens only Zigzag Mini, over the app you clicked it in, and your browser windows stay where they were until you want them. Closing it takes you back to that app.
- A mouse's side buttons go back and forward.
- Settings › General can leave the trackpad pinch to websites, for maps and games like GeoGuessr that zoom with it. ⌘⇧\ still shows all tabs.
- Settings › Shortcuts shows an × beside a shortcut when you point at it: click it and the command has no shortcut, for one that gets in a website's way.

### Fixed
- Site permissions are kept for each exact site, its address's scheme, host and port together. Before, allowing the microphone, camera, location, notifications, pop-ups or opening an app for one port of a host allowed every other port of it too. Sites you had allowed ask once more. Thanks to [zemu](https://github.com/ze-mu-zhou) for reporting it.
- Right-click › Open Link in New Tab, Open Link in Peek and the new window items work on busy pages, like a forum's long topic list, where they could do nothing.
- In a text box, ⌘← and ⌘→ jump to the start and end of the line again, as on any Mac, instead of going back or forward a page. Away from a text box they still go back and forward.
- With the sidebar hidden, touching the window's left edge and coming straight back, as when clicking a website's own list along that side, no longer pulls the sidebar out. Going to the edge still opens it right away.

## [0.7.1] - 2026-11-09

### New
- The mini window is now Zigzag Mini, and looks like the rest of Zigzag: your space's color around it, the page in the same card as in your browser window, and its title on top. ⌃⌘N opens the command bar you know from ⌘T, with the same suggestions, and Return opens the page in Zigzag Mini right there. ⌘L changes the address, Esc closes it (while you're typing in a field or a site has its own dialog open, the first Esc goes to that), and ⌘O or the button at the top moves the page into your browser window without reloading. Settings › General has its own Zigzag Mini group.

### Fixed
- Control-Tab sits in the middle of the window. With many tabs the cards go into rows instead of shrinking, and the one you'll switch to is outlined. The arrow keys move in all four directions. ([#11](https://github.com/ZigaoWang/zigzag/issues/11))
- The space switcher (⌥⌘S) sits in the middle of the window too.

## [0.7.0] - 2026-11-09

### New
- Clear keeps the tabs you're working with and closes the ones you've drifted away from, with no fixed age to wait for: hover it to see which go, and Undo brings them all back.
- New tabs open next to the one you're on, and a link's tab right below its page, in order. Settings › General › Tabs can put them at the top, as before, or at the bottom.
- Hold ⌘ for a moment and each favorite and tab shows the number that jumps to it.
- A background tab that keeps working hard goes to sleep on its own and wakes where it was when you open it. Zigzag says so once per site, with Show Tab. Settings can turn it off.
- Settings can turn off the offer to pin the page a pinned tab moved to, for sites like DeepSeek where every new chat is a new address.
- Drop a pinned page on another pinned page to open them in split view, as tabs and favorites already do.
- Mini window: ⌃⌘N opens a small window for one quick page, and Open in Zigzag moves it into your browser window as a tab without reloading. Settings › General can open links from other apps in one, as Arc's Little Arc did.
- ⌥⌘S lists your spaces to pick one with the arrow keys, a number or a click. ([#11](https://github.com/ZigaoWang/zigzag/issues/11))
- Proxy extensions like FoxyProxy can send your browsing through a proxy server, with passwords and sites to skip. Proxy scripts (PAC) don't work yet, and the install sheet says so.
- Extensions that bring a search engine, like ChatGPT search, add it to Settings, and Zigzag asks before searching with it.
- The developer tools open on Chrome's keys: ⌥⌘I or F12 shows and hides the Web Inspector, ⌥⌘J opens the console and ⌥⌘C picks an element. Inspect Element is always last in a page's menu.

### Faster
- History search keeps up with your typing, however long your history.
- Folders of hundreds of imported bookmarks open at once, even with every folder open after an import.

### Fixed
- Bitwarden's autofill menu shows in login fields.
- 1Password's sign-in banner closes once you've signed in, on single-page and two-step logins too.
- Violentmonkey's buttons open its editor and dashboard, so new scripts can be made and saved, and its toolbar icon updates. Script links like Greasyfork's Install open its install page; with Tampermonkey on too, Tampermonkey takes them.
- Imported bookmarks keep up to eight levels of folders, and an open folder's arrow points down at every depth.
- Favorites' rows come out whole: four sit in one row, never three and one left alone below.
- The Site Controls button in the address field is as big as the toolbar's and easy to hit, and a long site name in the site panel ends with an ellipsis instead of being cut off.
- Toasts, the link preview and the Clear button have the same space at both ends.
- Undo after Clear brings back every tab it closed, in place, with a split view coming back as a split.
- Several tabs opened in the background beside yours keep the order they were opened in.
- Extensions that check their access to a local address with a port, as 1Password does, no longer fail there.
- Control-Tab switches tabs while a page has the focus, which it almost always does; before, it often did nothing. ([#11](https://github.com/ZigaoWang/zigzag/issues/11))
- Rabby starts again after Zigzag relaunches, instead of saying its background isn't responding. ([#12](https://github.com/ZigaoWang/zigzag/issues/12))
- When your network or proxy changes, sites connect afresh instead of reusing a remembered HTTP/3 route that could go around a VPN or proxy.

Thanks to [@maxacarvalho](https://github.com/maxacarvalho) for #11 and [@vandenbulckjean](https://github.com/vandenbulckjean) for #12, to neooo on LINUX DO for the Bitwarden and IPv6 reports, and to Philip and Harry on Product Hunt for asking for the mini window, proxy extensions and ChatGPT search.

## [0.6.2] - 2026-11-08

### Fixed
- Importing from Arc brings over everything in your sidebar, whether or not Arc's sync is on: each space's name, pinned tabs, folders like Imported From Chrome with every page inside, and Favorites, in Arc's order. Arc keeps several copies of the sidebar; Zigzag now reads them all and keeps the fullest, where before it could read a stale one and bring over empty or half-empty spaces.
- Importing from Arc again keeps Arc's folders in a space you already have, and puts back in their folders any pages an earlier import left loose.

## [0.6.1] - 2026-11-08

### New
- Ad blocking covers Chinese sites too: EasyList China joins EasyList and EasyPrivacy, so the banner walls on sites like ITDOG are gone. The lists are fresh as of November 8.
- The sidebar that slides out over the page is glass: the page shows softly through it, under your space's color. With Reduce Transparency on, it stays solid.
- Favorites fit the sidebar: fewer, larger tiles to a row when it's narrow, more when it's wide. Settings › General › Favorites per row picks a number instead.

### Fixed
- Importing from newer Arc brings each space's pinned tabs, folders and Favorites, instead of empty spaces.
- Favorites you haven't opened yet show their site's icon far more often, including sites that moved to a new address.
- Keys nothing uses, like the arrows at the end of a page, no longer make the error sound.
- Bitwarden works: it signs in without "Symbol.dispose is not defined", its vault loads instead of spinning, and its autofill keeps working. An extension's background now stays running while its popup or a tab is talking to it, as in Chrome, where WebKit stopped it after 30 seconds mid-conversation.
- When an import can't finish, its result says how far it got, instead of "You're all set", and its lines no longer overlap.
- In Chinese, two characters of a command's name are enough to find it in the command bar.
- Closing several cards in the tab overview shows "Closed N tabs" with Undo, as in the sidebar.

## [0.6.0] - 2026-11-08

### New
- Zigzag speaks Simplified Chinese. On a Mac set to Chinese it is in Chinese everywhere: menus, Settings, the sidebar, import and the welcome, extensions, passwords and the permission prompts, with dates and times written the Chinese way. To choose a language for Zigzag alone, pick it in Settings › General › Language, and Zigzag restarts in it.
- Picking several tabs works the way it does in Finder. Picked rows stay picked after you unpin, pin, file or drag them, so the next action applies to the same rows. ⌘W closes all of them in one step that ⌘Z brings back, and File › Close Tab says how many. Esc lets go, ⇧-click picks a run from the last row you ⌘-clicked, and ⌘A picks the rest of their section.
- Pinned pages can be removed from the sidebar, one or many at once, with Delete or Remove Pinned Page in the right-click menu, and undone.
- The right-click menu for picked rows says how many it acts on and does it to all of them: Close, Pin, Unpin, Add to Folder, Add to Favorites and Move to Space.

### Fixed
- Undo brings back every tab after closing more than fifty at once.
- Closing, unpinning or moving many tabs at once is quick, and redraws the window once.
- Shift-click on the tab overview picks a run of cards, as in the sidebar.
- In the welcome, staying signed in reads as a setting under the browsers instead of one more browser, and checked boxes are solid, with no dark ring.
- Translating a page reads its language again as you ask, waits while macOS downloads the language, and never leaves "Translating…" stuck: it goes with the page if you move on, and says so if no answer comes.
- Site controls have the same room under their last row as above their first.
- The Language menu lists each language once.

## [0.5.19] - 2026-11-08

### New
- Importing from Arc, Chrome, Edge, Brave, Dia, Vivaldi, Opera, Firefox or Zen can keep you signed in to your sites: your sign-ins come over from that browser on this Mac, with one Keychain prompt shared with passwords. Sites you're already signed in to here keep their own session, and private windows never get any.
- Dragging the sidebar's edge far enough closes it, as in other Mac apps, and dragging back out in the same drag opens it again.
- Site controls always offer Translate, so you can translate a page after the offer at the top has gone.
- A site that asked to show notifications can be allowed later from site controls, even if the question went before you answered it.
- New people start with small space names, a plain heading. Large and light is one right-click away on the name, and anyone who had large names keeps them.

### Fixed
- The tab you're on is a clean white card with a soft shadow, not an outlined box, by day and by night, and it slides under other tabs' titles rather than over them.
- New Tab in the sidebar is quieter, the space name and Tabs sit tighter, Clear matches Tabs, a folder's arrow lines up with the close buttons, and a row's highlight fades gently as the pointer leaves.
- Pressing a favorite or the address no longer flashes darker than it sits.
- In full screen the window buttons come down in a proper bar, not over the page.
- Toasts stay centered over the page when the sidebar or full screen changes, and the translate and default browser offers have a close button.
- Site controls are the sidebar's width whether it's shown or hidden.
- Installing Bitwarden no longer warns that its popup doesn't work: it opens.

## [0.5.18] - 2026-11-08

### New
- Tampermonkey works. Clicking Install on a script (Greasy Fork and other script sites) opens its install page, and your scripts run with their saved settings, cross-site requests and menu commands. Its popup lists the scripts on the page, and its dashboard shows each script's sites. Scripts also run on sites that allow no inline scripts, like GitHub, with no setting to change.
- Script managers have Chrome's user script API, so Violentmonkey starts and registers your scripts too.
- An extension's install sheet says when it can run scripts you add.
- Not yet: after you browse to another site in the same tab, Tampermonkey's popup can still list scripts from the page before (they don't run there), and Violentmonkey's install links don't open its install page.

### Fixed
- Extensions that keep a live connection to their server in the background no longer freeze, and their popups open when you click them.
- Turning an extension off and on again no longer tells it it was just installed, so Tampermonkey keeps your scripts switched on.
- Messages between an extension's own pages and its background arrive whole.
- Extensions that ask whether they have a permission Zigzag answers for itself get an answer, instead of stopping as they start.

## [0.5.17] - 2026-11-07

### New
- Built-in ad blocking reaches YouTube, the way established blockers do: ads are taken out of what YouTube sends before the page reads it, one that slips through plays unseen and unheard and is skipped, and YouTube's ad spaces and its note blaming a blocker are hidden. Allowing ads on YouTube turns it off.
- Chrome extensions can use much more, answered by Zigzag itself and only with the permissions they asked for:
  - History: search, add and remove, and hear about each visit. Private windows never show.
  - Bookmarks: your pinned pages, folders and favorites, read and changed as bookmarks.
  - Downloads: start, follow, pause, resume, show and open files. A name an extension gives stays inside Downloads.
  - Notifications, shown by macOS under the extension's name.
  - Side panels, docked beside the page like a second pane, opened from the extension's button.
  - Offscreen pages, for an extension's clipboard, audio and parsing work.
  - Signing in through the web, in a small window of its own.
  - The sound of the tab you're on, for Shazam, volume boosters and recorders, while the extension's popup is open or right after you click it. As in Chrome the tab goes quiet while captured and the extension plays it back, a few hundredths of a second behind the picture. On streamed video (YouTube and most video sites) Zigzag hears the sound it plays itself, after asking you once, and plays what the extension makes of it, so Shazam names songs and boosters boost there too. A note says it's listening.
  - Its own new tab page, in place of the command bar on ⌘T.
  - Top sites, idle state, your screens' sizes, reading aloud and keeping the Mac awake.
- An extension's install sheet says what these let it do, instead of listing them as missing.
- Every other Chrome extension API is there too, filled in from Chrome's own definitions: what Zigzag can't do yet says so to the extension, instead of stopping it as it starts. Of the most used extensions, ad blockers, password managers, Grammarly, Dark Reader, translators, Shazam and volume boosters work.
- Not yet: Claude can sign in and chat, but not act on pages, which needs Chrome's debugging protocol; Honey, LastPass and Tampermonkey still miss pieces, and AdBlock and Adblock Plus run without one of their features.

### Fixed
- A white box no longer shows over a full-screen video while an extension keeps a hidden page of its own.
- The guided tour's note stays over the tab overview, saying what to do there.
- Download PDF saves to Downloads like any file and flies into the Downloads button. The tab stays on the page you were reading, and the saved file opens there later. On a PDF already on your Mac, the button saves a copy.
- Claude signs in: claude.ai reaches the extension (a message to an extension that isn't installed fails at once, as in Chrome, so it moves on to the one you have), claude.ai shows inside Claude's side panel, and its background no longer stops on Chrome features WebKit lacks.
- Sites an extension lets message it can, with Chrome's names, and the extension learns which site sent each message.
- An extension asking for a tab's sound (Sound Booster) gets the tab, never your microphone, even on the rare page WebKit sets up late.
- An extension's popup closes when you open site controls, a menu, Downloads or the space editor, opens on every click, and a click on its button while it's open closes it.
- Shazam keeps listening through its own redraws, and its requests reach shazam.com: extensions' requests now tell servers what Zigzag really is, while their code still reads Chrome.
- Extensions that ask which of their pages are open get the answer, so Boost My Bass and others start their sound page.
- A tab is captured once at a time, as in Chrome, so moving a booster's slider no longer brings the tab's own sound back on top.
- Ad blockers keep blocking when WebKit doesn't know one kind of request or one rule they use, and Grammarly, Privacy Badger and OneTab no longer stop on settings or a cookie change.
- An extension that fails to start says why in the extensions log.
- An extension's own small window opens at the size it asks for, with its name on top, not as a whole browser window, and without its popup left over it.
- The Add to Zigzag bar shows the listing's own icon, also after moving from one listing to another.
- Stand-ins for extension features WebKit lacks now attach where WebKit names a feature without providing it.
- An unpacked extension in a linked folder or on another disk gets Zigzag's compatibility layer.

## [0.5.16] - 2026-11-07

### Fixed
- Extension popups and pages that don't choose a font use the system font, as in Chrome, instead of a serif.
- The Add to Zigzag bar on the Chrome Web Store shows the extension's icon on a rounded tile.
- An empty space's wordmark is lightly engraved into the space's color, and shows on black.

## [0.5.15] - 2026-11-07

### New
- Bookmarks imported from Chrome, Safari and Firefox keep their folders, nested as they were.
- ⌘J (Find › Jump to Selection) scrolls back to what you'd selected, as in Safari.
- Help › Zigzag on GitHub opens the source code.

### Fixed
- Web apps get their own shortcuts first: ⌘S commits in GitHub's editor, ⌘F searches a document, ⌘D duplicates in a design tool. When a page doesn't use one, Zigzag does what the menu says, so ⌘S still saves the page.
- Search suggestions are fetched without cookies, in every window.
- Downloads note the page they came from, so Get Info shows it under Where From.

## [0.5.14] - 2026-11-06

### New
- A new About window: the version, Release Notes, Acknowledgments, the website, the source code on GitHub, who made it, and the license.
- Acknowledgments lists every work Zigzag ships with and its license, and reads offline.
- Opened from the disk image or a download, Zigzag offers to move itself to Applications, where it can update itself.
- Right-click Zigzag in the Dock for a new window or a private one.
- A page handed off from your iPhone or another Mac opens in Zigzag.
- ⌘S saves the page, as in Safari.
- The space editor's color wheel, sliders and direction knob work from the keyboard, with Full Keyboard Access.
- In History, Delete removes the row you're on, and VoiceOver says so.

### Fixed
- A page can't make the address show another site while its own page stays on screen, in a tab or a pop-up.
- The address shows a long site name's end (the part that says whose it is), a port that isn't the usual one, and the site behind a page a script made.
- Extensions never see private windows, and never open tabs in them.
- A website can't send a tab into an extension's own pages, or to Zigzag's Settings or History.
- Frames and scripts can't save files to Downloads without a click.
- Visit Anyway on a certificate warning trusts the certificate you were warned about, not any that site shows later.
- A permission question ignores clicks on Allow for its first half second, so a click meant for the page can't land on it.
- Mail, phone and FaceTime links open by themselves only from a real click on the page in front. A question to open an app, asked from another site's frame, names that site and isn't remembered, and an answer given on a secure page doesn't carry over to an insecure one.
- Only the site you're on can ask for a password over its page; an image or frame from another site can't.
- A page can ask to show notifications only right after you click.
- Fill from My Card skips fields that are hidden, clipped, covered or far off the page.
- Reader and the PDF viewer fetch without cookies a link from another site wouldn't carry, and Reader keeps nothing from a private page.
- A page opened loose from Downloads can't read the rest of the folder.
- Other apps can hand Zigzag only web links and files.
- Clear History erases what it clears from the file, from the copies kept at updates, and from the sites noted for problem reports. Private windows leave no site names in that record.
- A second copy of Zigzag (one opened from the disk image) hands over to the one running instead of saving over its tabs.
- A busy page can't put off saving your tabs; they're saved within 10 seconds.
- If preferences are reset, a profile you've used never goes back through onboarding, which used to save an empty window over your tabs.
- A damaged history file is set aside and history starts afresh, instead of stopping quietly. A profile file that can't be read is set aside, never saved over, and a save that fails says so.
- A link opened while onboarding is still up isn't lost at the next launch.
- With Reduce Motion, switching spaces cross-fades instead of showing both lists at once.
- Bookmarking a page keeps its tab's title; only a site's home page is shortened to the site's name.
- ⌘Z goes to the page (Figma, Docs) once you've worked in it after a change in the sidebar.
- Undoing New Space closes its tabs the usual way, so ⇧⌘T brings them back.
- ⌘W on an empty space no longer closes the window and the tabs in its other spaces.
- Now Playing lets go of a tab closed in the background, and a closing tab's sound stops at once.
- A private window stays in its one space, and can't pin the page it's on in place of a pinned tab.
- A peeked link that downloads a file closes the peek, and a peek opened as a tab while its window closes goes with it.
- The energy warning's Close Tab closes the tab in whichever window holds it now.
- Retrying a download picks up in the same row and file, and a canceled or failed download leaves no partial file once cleared.
- Ad blocking changes only for a page that actually loads, not for a link opened in another tab.
- An address with @ in its path, like a YouTube channel's, opens instead of searching.
- A password file picked after an import brings its passwords over.
- Arc history comes over from every profile, with its latest visits.
- Importing thousands of bookmarks no longer freezes Zigzag.
- Exported passwords keep their one-time codes.
- A strong password made without a username never replaces another saved login.
- A sign-in inside another site's frame is offered for saving only once it worked.
- Passwords work in a copy built and signed by someone else.
- Zigzag uses less memory and energy: the sign-in menu lets go of closed pages, closed tabs let go of their pictures, download progress and the freeze watcher wake far less, Reader reads ahead only for the page in front, and the tab overview opens without decoding every picture.
- The same History search typed twice in a row reads your history once.
- Checking for battery power no longer risks a crash.
- The local network and Downloads folder prompts say why Zigzag asks, and Get Info shows Zigzag's copyright.
- A favorite's menu calls it a favorite, the whole-page screenshot has one name everywhere, the Reader tile says Show Reader, buttons that open a panel or a question end in "…", and a few descriptions in Settings and the guide read more clearly.
- VoiceOver reads the space editor's names and color choices correctly, and the error page as English.

## [0.5.13] - 2026-11-06

### New
- Help › Report a Problem writes a short report and attaches it to an email: your Zigzag and Mac, what went wrong lately and on which sites, crash and freeze reports, and extension errors. Never the pages' addresses, your tabs or history, and nothing is sent until you send it. Show Report lets you read it first.
- Zigzag keeps a record of what goes wrong as it happens, for that report: pages that didn't load or stopped, pop-ups blocked or opened, questions sites asked and your answers, errors pages threw, moments Zigzag froze, and whether it last quit unexpectedly. It stays on your Mac, and private windows never name their sites in it.
- Crash and freeze reports macOS collects for Zigzag are kept on your Mac for two weeks, to go with a report.
- Coming back from System Settings during setup checks browser access again by itself.

### Fixed
- An edited favorite opens its new address, not the old one.
- A slow History search can't show its results over a newer one.
- Pop-ups open whole on the display they belong on, never off screen.
- A pop-up that fails to load says why instead of staying blank.
- Links in a pop-up open as tabs in your window, not as more pop-ups.
- A pop-up asking to open an app shows the question in front instead of behind it.
- Page dialogs and sign-ins ask one at a time instead of stacking, and several asking for the same sign-in share one answer.
- Blocking a page's dialogs ends when the page reloads, as in Safari.
- Space dots keep a size you can click with many spaces, and scroll to keep yours in view.
- In the tab overview, a long space name ends in "…", the count sits right beside the name, and while searching it says how many match.
- The site panel's actions wrap into two rows in a narrow sidebar instead of cutting off their names.
- The rename panel fits small windows and waits for a name.
- Settings lists every site with a choice made for it, not just the first 40.
- What's New keeps keys from the window behind it, scrolls with the arrow keys and Space, and closes with ⌘W.
- In setup, checkmarks are readable in dark mode, and Safari's password note shows the file link it mentions.
- Show in Finder in Downloads can be reached from the keyboard and VoiceOver, VoiceOver names what's playing, and it reads menu items as you move through them.

## [0.5.12] - 2026-11-05

### New
- ⌘Z brings back pages you removed from History, and even a whole Clear History, with your archived tabs, places in PDFs and site icons. The "History cleared" notice has Undo too.
- Select everything in History with ⌘A, then press Delete to clear it. It asks first, and your cookies and passwords stay. While searching, only the results go.
- Site Data in Settings › Privacy lists every site that keeps cookies, saved data or a cache on this Mac, with Remove for each one.
- Reduce motion in Settings › General: things appear in place instead of sliding or growing, for Zigzag alone.
- The getting-started guide shows each step being done right in your window: a cursor drags a tab into Split View, Shift-clicks a link and clicks +, and two fingertips swipe between spaces. Rings and demos keep going until you do the step. They replace the videos.
- A new step in the guide: see all your tabs with ⇧⌘\ or a pinch.
- The guide can be closed for good with its ×. Help › Getting Started brings it back.
- Open pinned pages show a fine edge, as favorites do, so you can tell which are loaded.

### Changed
- Titles show in normal case everywhere: History, Settings, Downloads, What's New and the rest.
- The tab you're on stands out more in the sidebar.
- Confirmations ease in and out, even when a key opened them.
- The guide names the tab to drag into Split View, and opens its own page for it.

### Fixed
- Teams Assignments loads. Sign-ins that check in a hidden frame now get their cookies, as in Chrome and Arc; private windows still keep none.
- Allowing a blocked pop-up no longer breaks the sign-in or payment it was for: the page's own button, clicked again, opens a real pop-up.
- A page that opens a blank pop-up and fills it in afterward now says when it's blocked.
- In setup, the answer you picked is readable in dark mode.
- Back to Pinned Page goes back to the pinned page instead of unloading it.
- The × on a favorite holding two pages unloads both.
- Close Other Tabs and Close Tabs Below keep the tab's split partner, from the sidebar and the command bar alike.
- A peek goes away when you switch tabs or spaces, or open the tab overview.
- Esc keeps a new space once you've named it or picked its look.
- Edit Space is off in private windows.
- Show All Downloads shows them, instead of opening Finder.
- A download that fails says so, with Try Again, and a download's notice shows only in a window of its kind, private or not.
- Removing an extension from its own menu asks first, as Settings does.
- Reset All for shortcuts asks first.
- A notice with Undo stays while the pointer is on it.
- The same actions have the same names everywhere, like Mute Tab and Rename Favorite.

## [0.5.11] - 2026-11-05

### Fixed
- Pinching in to open the tab overview no longer leaves the page shrunk and shifted toward the corner. The page now shrinks with your fingers and flows straight into its card.
- Pop-ups you've allowed for a site open as real pop-up windows, so sign-ins and permission steps finish, like the "Almost there!" step in Teams Assignments.

## [0.5.10] - 2026-11-05

### Fixed
- Swiping between spaces no longer catches: the next space is ready before you swipe, and its list slides in the moment you let go.
- The tab overview shows the space's color exactly as the window does, gradient and grain included.
- The tab overview shows space names as you typed them, with no lowercasing.
- Grain is even across the whole window, with no repeating pattern.

## [0.5.9] - 2026-11-05

### New
- New looks for spaces in the space editor, in two rows: white, black, clear and smoky glass, deep charcoal, espresso, oxblood, pine and slate, then paper with grain and soft fades like oat, butter, clay, rose, matcha, mint and sky, with a frosted glass to finish. Each one is a spot on the color wheel with a shade and effects, so after picking one you can adjust it from there.

### Changed
- A space's name shows exactly as you typed it, with no lowercasing.
- Shade runs all the way from pure white to true black.

### Fixed
- A black space keeps light text and a white space keeps dark text, whatever your Mac's light or dark setting.
- Grain shows on dark colors too, not only light ones.
- The loading bar keeps moving while a slow page loads, instead of stopping partway.

## [0.5.8] - 2026-11-04

### New
- The getting-started guide is a clear dark bar at the bottom of the page, with big instructions and the keys to press in your space's color. While you type, it sits right under the address bar.
- New short videos in the guide for the steps that are hard to put in words: Shift-clicking a link, dragging a tab into a split, making a space and going back.
- Large Space Names can be turned on or off from a space's right-click menu.

### Changed
- Onboarding no longer has the screen explaining how Zigzag works. The guide shows it in the browser instead.

### Fixed
- The pinned tab you're on is a light card again, not a dark one.
- Typing a new space's name replaces "Space 2" instead of adding to it.
- An empty see-through space shows its glass across the whole window, and a split view's gap no longer shows the desktop behind it.
- The sidebar on Clear glass is a little clearer.
- The guide skips one step per click, never asks you to drag a tab that's already in a split, and its cards sit where ⌘T's bar opens.

## [0.5.7] - 2026-11-04

### New
- Onboarding shows how Zigzag works for anyone coming from Chrome or Safari: where your tabs are, where to type, and your everyday sites.
- The getting-started guide is easier to follow, with bigger instructions, a step count and a clearer highlight on what to click.
- A setting for large space names: keep the big lowercase name, or show it as a plain heading.
- Clear glass switches to frosted on battery or in Low Power Mode, and back when you plug in.
- In the tab overview, ⌘1 to ⌘9 open a card, and more cards fit at once.

### Fixed
- The custom search address only shows when Custom is chosen.
- Onboarding's yes-or-no questions show which answer is picked.

## [0.5.6] - 2026-11-04

### New
- More search engines: Startpage, Perplexity, Yahoo, Baidu and Yandex, or your own with Custom.

### Fixed
- Opening Settings from a private window no longer replaces your saved windows.
- Zigzag keeps your spaces if it finds settings from a newer version, and logging can't crash it on a full disk.
- Web pages can no longer tell which sites you've visited, and Clear History also clears the site icons it kept.
- A strong password only fills on the site it was made for.
- Clear runs one step per click, and folders inside folders keep their place when you add to or move them.
- Zigzag uses less energy: the window's glass rests when nothing shows through it or the tab overview is open, and blurs go still behind other apps.
- Search engines show their icons before you visit them, and Clear glass carries more of the space's color.
- Buttons on Zigzag's own pages use the space's color, and media controls use thin outline icons.

## [0.5.5] - 2026-11-04

### Fixed
- Zigzag uses much less energy with a see-through space: the glass only sits behind the sidebar, and pauses when the window can't be seen.
- Background timers wake the Mac less often.
- A see-through space shows its glass as soon as Zigzag opens.

## [0.5.4] - 2026-11-04

### New
- See-through spaces can use clear or frosted glass. Clear is the default on macOS 26 and later.
- The tab overview offers to close duplicate tabs, and shows which ones will close before you do.

### Changed
- The page meets the sidebar with a soft shadow.
- The space editor shows its preset colors at full strength, and Colors is now called Gradient.

### Fixed
- The toolbar buttons match, and the reload icon is redrawn.
- See-through spaces keep their color, and grain shows on clear glass.
- The tab overview matches the window's glass, closes when you open the address bar, and its close button shows on any page.
- Tabs without a preview show a tinted card instead of a blank one.
- Suggestions in the address bar use the current space's color.
- A space's icon lines up with its name.

## [0.5.3] - 2026-11-04

### New
- Folders can hold folders. Right-click a folder and choose New Folder Inside, or drag a folder onto another one. Closing a folder hides everything inside it. ([#6](https://github.com/ZigaoWang/zigzag/issues/6))
- Nested folders in Arc come over nested when you import. ([#6](https://github.com/ZigaoWang/zigzag/issues/6))

### Fixed
- The pinned tab you're on shows its button only when you point at it. ([#4](https://github.com/ZigaoWang/zigzag/issues/4))
- Back, forward, reload and the sidebar button match.
- GitHub, ChatGPT and other one-color icons show in History in dark mode.
- The Tabs label lines up with the edge of the sidebar.
- Searching in Settings is titled Results.

## [0.5.2] - 2026-11-04

### Changed
- Clicking the address edits it in place, at the field's own size, with suggestions the size of your tabs below it.
- Clear goes in steps, one click each: old tabs first, then every other tab, then the one you're on.
- The new tab bar is centered on the window again.

### Fixed
- Switching spaces no longer flickers the colors or the window's buttons.
- Typing a word that only relates to a command, like "contact", searches for it instead of running the command.
- A space's icon lines up with its name and with the icons below it, and space icons at the bottom of the sidebar are evenly spaced.

## [0.5.1] - 2026-11-03

### Fixed
- What's New shows its notes as plain words, without link code.
- The main button in every window, switches and the guided tour take your space's color. There's no orange accent anymore.
- Import, What's New and onboarding headings use the same light lowercase type as the rest of Zigzag, and pages name themselves without the wordmark beside them.
- Searching a site from the address bar shows its name and a thin rule instead of a colored capsule, and the address bar opens centered over the page.
- Import's choices are simpler, and the browser you pick is softly highlighted.
- Permission prompts use a thin icon and a lighter title.
- A space's icon sits with its name and shows small at the bottom of the sidebar.
- A download flies into its button on a slow, high arc.
- A tab that leaves Settings for a page shows the page's own icon.
- Small fixes to Settings and the space editor.

## [0.5.0] - 2026-11-03

### New
- A new look across Zigzag: each space fills the window with its own soft color, the tab you're on is a card that slides as you switch, and rows, favorites and panels move calmly into place.
- Pick a space's color from a row of curated colors, including pure white and pure black, or use the wheel. Gradients and see-through are tucked under effects.
- The address bar, Downloads, Site Controls, Settings and History share one look: your space's color, light large titles, plain rows and thin line icons.
- The address bar does more: type a few letters for actions like pin, split, move to another space or close other tabs. ([#3](https://github.com/ZigaoWang/zigzag/issues/3))
- The page meets the window's edges beside the sidebar. Turn off Borderless page in Settings to float it again.
- Beta updates: try new versions first, on your own tabs and data. Your profile is saved before every update, so one can be undone.
- The address bar fills in sites you've been to as you type, so "wiki" becomes wikipedia.org and Return goes there.
- Drag and drop works the same everywhere: in the tab list, favorites and Settings. What you pick up stays put, faint, and a see-through copy follows you. A line shows where it will land, and nothing else moves out of the way.
- Drop a tab on the middle of another tab, a pinned tab or a favorite to open them side by side. A split view can be a favorite, and you can separate it again from its menu.
- A split view moves as one: into favorites, pinned tabs, another space or another window.
- Drag a favorite among your pinned tabs to pin it, onto a space's dot to move it there, or into another window's sidebar. Hold on a dot, or at the sidebar's edge, to switch spaces while you drag.
- Folders and spaces can have an icon, any symbol or emoji. ([#1](https://github.com/ZigaoWang/zigzag/issues/1), [#7](https://github.com/ZigaoWang/zigzag/issues/7))
- Settings opens as a tab beside your pages, with search across every section.
- History groups visits into sessions and sites.
- A closed tab comes back into its split view. Separate Tabs is ⌥⌘\.

### Changed
- Your spaces show as quiet dots at the bottom of the sidebar, the one you're in a short pill.
- Clicking a space's name folds its pinned tabs. Edit the space from its menu.
- A switch that's on takes your space's color.
- Swiping between spaces no longer catches as the new space's page comes in.
- The tab overview stands on the same color and see-through as the sidebar, and names each space the way the sidebar does.
- Names and titles share one light, lowercase type across the sidebar, pages, panels and the address bar.
- After you clear tabs, Clear goes away until you move off the tab list, so a second click can't close the tabs you kept.
- Favorites have bigger icons, and an open one has a fine edge. Point at it to close it.
- Swiping back or forward holds while your fingers rest, so you can keep reading before you let go.
- Permission requests hang from the site's address and go away when the site does.
- Find stays with its tab. Esc closes it from the page, and ⌘F again closes it.
- Click a space's name to edit it, and its chevron to fold its pinned tabs.
- Closing a tab goes back to the one you were on before it.
- Motion is quicker and calmer across the app, and Reduce Motion stops slides.

### Fixed
- Reordering spaces in Settings is smooth. ([#2](https://github.com/ZigaoWang/zigzag/issues/2))
- Reordering favorites and pinned tabs lands exactly where you drop. ([#5](https://github.com/ZigaoWang/zigzag/issues/5))
- Favicons are sharp, never blank, and a site's own icon wins over its home-screen tile. One-color icons take the sidebar's ink. ([#8](https://github.com/ZigaoWang/zigzag/issues/8))
- Undo puts tabs, pinned tabs and favorites back exactly as they were.
- A password is offered to save only after the site accepts it, and the prompt stays with its tab.
- A page's alerts stay with its tab and dim only that page.
- Contact autofill fills only visible fields on the site it was offered for.
- Links in Reader and PDFs open web pages only, and ask before opening an app.
- Extensions can't widen the site access you gave them.
- Pages that fail to load stay out of history. Clear History also clears archived tabs.
- Replacing a file with a download keeps the old one until the new one is done.
- Windows come back once and at their own size after a restart.
- Return never confirms a destructive action, and never approves an extension while you type in a page.
- Private windows stay private: links opened in a new window open privately, and their pages can't be pinned or favorited.
- Closing one half of a split no longer leaves a blank pane, and closing a page opened from a split puts the one it came from back.
- Clicking the Dock icon brings back a minimized window instead of opening another. ⇧⌘T works with no window open.
- ⌘← and ⌘→ in a text field move the cursor instead of going back or forward.
- Esc in the address bar works over Peek and permission questions, and Undo there takes back only what you typed.
- Typing in Chinese, Japanese or another input method no longer closes the space editor on Esc.
- Emoji like ❤️ and ☀️ work as folder and space icons.
- Back, forward and reload line up.
- Favorites and pinned tabs can be renamed, middle-click closes any row, and ⌘1 to ⌘9 count the rows you see.

Thanks to [@evannotfound](https://github.com/evannotfound) for reporting #1, #2, #3, #5, #7 and #8.

## [0.3.1] - 2026-10-31

### New
- Turn off search suggestions in Settings › General, and nothing you type in the address bar leaves your Mac for them.

### Changed
- A small sideways nudge of a mouse wheel over the sidebar switches spaces. One turn moves one space.

### Fixed
- A page with its own icon, like a Claude artifact, no longer replaces its site's icon on your favorites and tabs.

## [0.3.0] - 2026-10-31

### New
- The all-tabs view (⇧⌘\) shows every space at once. Your page zooms into its card, typing filters, arrow keys and Return open a tab, and you can drag a tab into another space.
- Clear closes faded tabs first and keeps today's. Point at it to see which tabs it will close.
- Full keyboard access: with it turned on in System Settings, Tab reaches Zigzag's own buttons and switches.

### Changed
- Buttons, prompts and highlights keep your space's own color in light and dark, whatever the color.
- Permission and app questions use your space's color.
- Favorites keep one tile size, four to a row. Ones that aren't loaded are faded instead of marked.
- Full-page screenshots of pages that scroll inside themselves include the site's bar.
- Error pages explain what went wrong in plain words.
- Settings: Spaces rows match the rest, and wording, icons, corners and text sizes are consistent across the app.
- VoiceOver reads buttons and switches by their names, and announces notices and find results.

### Fixed
- Dropping a folder or tab into another space keeps you in that space.
- A web page can no longer turn off certificate warnings for another site.
- The traffic lights stay in the corner when the window is resized.
- Closing find clears the highlight on the page.
- ⌘W and ⇧⌘W work in Settings, Passwords and Import.
- A camera or app question never hides behind What's New.
- A page you're reading isn't replaced by an error page when something fails later.
- Private windows keep to themselves: no space switcher, and they can't change your spaces.
- History search no longer sends what you type to your search engine.
- The command bar fits short windows, and its arrow keys wrap around.
- Clearing the last hour of history keeps the place you were at in older PDFs.
- Downloads still show up with Reduce Motion on.
- Typing a name in Chinese or Japanese no longer finishes it early.

## [0.2.1] - 2026-10-30

### New
- Drag a folder in the sidebar to move it with its pages, or hold it over a space's dot to move it to that space.
- Full-page screenshots also capture pages that scroll inside themselves, like web apps and pages shown in a frame.

### Changed
- Swiping between spaces follows your fingers: swipe a little and come back, or let go past a third of the way, or flick, to switch.
- Permission and app questions are simpler: the app's own icon, Allow, and a box to always allow on that site.
- Settings is easier to find your way around: each setting has an icon, General is in sections, and ad blocking is under Privacy.
- Clear has more room above New Tab.

### Fixed
- A button that opens a page in a new tab no longer also says a pop-up was blocked.
- The energy note no longer blames an extension like 1Password for a busy page, and only shows for tabs in the background.
- Settings no longer stutters as it grows for the Shortcuts pane.

## [0.2.0] - 2026-10-30

### New
- Passkeys work, with Touch ID or your phone, as in Safari.
- PDFs open in Zigzag's own viewer: pages and contents down the side, jump to a page, two pages side by side, dark pages, find and save. A PDF reopens on the page you left it at.
- History opens as a page in a tab (⌘Y), grouped by day, with search.
- Take a screenshot of a whole page with ⇧⌘2, or from the site panel. It's copied, ready to paste or save.
- Pin a split view and it stays a split: both pages in one row, and clicking it opens them side by side.
- Search in the all-tabs view (⇧⌘\), and close tabs there with ×.
- A cleaner site panel, with your actions and extensions in one row of buttons.
- Permission requests show on the page that asked, with Allow This Time.

### Changed
- Zigzag's code is now open source under the Apache License 2.0, instead of the Functional Source License. The Zigzag name, icon and logo stay trademarks, so forks use their own.
- Every shortcut except ⌘T now animates, so you can see what ⌘W and the others changed.
- Clear sits on its own line above your tabs, away from New Tab.

### Fixed
- Back on a tab a link opened closes it and takes you back to the page you came from, as in Safari and Chrome.
- With the sidebar hidden or in full screen, downloads, Downloads and extension popups show in the right place.
- Links that open an app, like a meeting link, ask first, and open straight away on sites you've said yes to.
- 1Password wakes up less, no longer opens its welcome page when it's slow, and works in sign-in windows.
- Clicking Clear again after your tabs are gone leaves the space empty instead of opening a pinned page.
- Tab previews no longer get stuck on screen.
- In split view, find sits over the page it's searching.
- Favorites and pinned tabs show their icon as soon as it arrives.
- Selecting the address no longer looks cut off, and PDFs and files are named after the file.
- Zigzag uses less energy in the background: idle pages in other spaces sleep, and animations and timers pause when you can't see them.

## [0.1.12] - 2026-10-27

### New
- Choose where downloads are saved, or have Zigzag ask each time, from the ⋯ menu in the downloads panel (it's also in Settings › General).
- Move to New Window in a tab's right-click menu, and Move Tab to New Window and Add to Favorites in the File menu.

### Fixed
- The downloads panel matches the site panel: flat, in your space's color, and as wide as the sidebar.
- Animations settle without bouncing, and nothing pulses on a loop.
- Pinned tabs are called pinned tabs everywhere, in menus, undo, notices and Settings.
- A direct link to a video or song plays instead of showing an error page.
- Back and forward swipes work more reliably: a swipe that's a bit diagonal or a bit short still counts, three-finger swipes work, and a carousel no longer blocks them unless it can really scroll.
- A tab that moves to another site shows that site's icon, not the last one's.
- Searching history (⌘Y) never shows a blank bar: with no match, it offers to search the web.
- Menu items that need a page are off when there isn't one, and Reader and Translate say Hide Reader and Show Original when they're on.
- VoiceOver reads buttons by their current names and knows when they're unavailable.

## [0.1.11] - 2026-10-27

### New
- Pick several tabs and pinned tabs with ⌘-click or ⇧-click, then drag them into a folder together, or right-click to add them to a folder, pin them or close them.
- New folders start at the top of your pinned tabs.
- A space with no tabs shows its own color instead of a blank white page.
- Swiping back and forward moves the page with your fingers, with the arrow waiting at its edge.
- A light tap on the trackpad when something you drag snaps onto a folder, a space, a split or Favorites, and when a swipe lands on the next space.

### Fixed
- The back and forward arrow never gets left on screen, and a quick flick counts.
- The downloads button is always at the bottom of the sidebar, even before your first download.
- Settings opens straight to each pane, and the window fits what's in it.
- About Zigzag is the standard Mac About window, with links to the website, the release notes and the license.

## [0.1.10] - 2026-10-27

### New
- A new getting-started screen: one step at a time on Zigzag's blue, with a simple question where a question will do.
- Passwords is in the Zigzag menu, next to Settings (⌥⌘K).

### Fixed
- Importing from many browsers: the list scrolls, so the Import button stays in view.
- Making Zigzag your default browser asks once instead of twice.
- Warnings, like an import that needs another try, are easier to read.
- What's New is wider, so notes read in fewer lines.
- In Settings, Add Space no longer sits on top of the list of spaces.

## [0.1.9] - 2026-10-27

### New
- Folders for pinned tabs. Right-click a pinned tab and choose Add to New Folder, or drag pinned tabs onto a folder. Arc's folders come over as folders when you import.
- Clear, at the top of your tabs: the first click closes every tab in the space except the one you're on, the second closes that one too. Undo brings them back.
- A download flies up and lands in the downloads button, which opens to show it come in.
- Downloads show a preview of images and PDFs, the site each file came from, and the time left.
- Swiping back and forward is quicker: an arrow slides in as you swipe, and letting go moves right away.
- In the command bar, ⌥↩ opens a page in a new tab even when it's already open somewhere.
- Pressing esc while naming a new space cancels it.
- The getting-started guide ends by showing how to switch between spaces.

### Fixed
- The current space's dot is a clear pill at the bottom of the sidebar, readable on any space's color.
- A download that fails says why, like being offline or the connection dropping, and a file you've since deleted or moved offers to download it again.
- Sites no longer offer push notifications that can't work in Zigzag ("Couldn't turn on notifications"); they use ordinary notifications instead.

## [0.1.8] - 2026-10-26

### New
- A new guide for getting started: a short video for each step, showing the keys to press, in one calm card in the corner.
- The space editor has four kinds: Color, Gradient, Mono for white to black, and Glass, which lets your desktop show through.
- Panels, prompts and notices open with smooth motion, and pinning or unpinning a tab carries it to its new place. The ⌘T bar still appears instantly.
- Separate Tabs puts a split view back into two tabs, from the button on each pane, the sidebar, or the View menu.
- Show All Tabs shows a split as one card, with both pages side by side.
- In Reader, ⌘+ and ⌘− make the text bigger or smaller, and the column is wider, with Narrow, Medium and Wide in the text settings.
- Zigzag asks before quitting, so ⌘Q never closes everything by accident. Press ⌘Q again to quit, or turn it off in Settings.
- After an update, Zigzag tells you what's new. Find it again in Help › What's New in Zigzag.
- A History window (⇧⌘Y): every page by day, with search, and you can remove one page or clear the last hour, today or everything.
- Fill your name, email, phone and address into forms from your card in Contacts.
- Screen sharing in Meet, Zoom and Teams.
- Reopen Closed Window, Save Page As, and Share in the File menu.
- Right-click a link to open it in a new or private window; right-click Back or Forward to jump several pages.
- A blocked pop-up says so, with a button to open it.
- Pause a download and resume it later, even after quitting Zigzag.
- Choose where downloads go, drag a finished download out into Finder, and the list stays after a restart.
- Settings › Privacy lists each site's choices, so you can forget just one.
- Find shows where you are, like 3 of 12.

### Fixed
- Importing starts with the browser you actually use, and every profile of it you've used lately, already checked. If macOS needs your OK to read it, Import asks for it and carries on.
- Passwords from Chrome and other browsers come over reliably. If some can't be opened, the import says so and offers to try again.
- Saved passwords are offered across a site's parts, as in Safari and Chrome: one saved on www.netflix.com fills on netflix.com.
- Saved passwords are offered as soon as a sign-in page opens with its email box ready, like Google's.
- Imported passwords keep being offered after you add a password manager extension.
- A sign-in with nothing saved for it says so, so you can look it up, and if you skipped importing, it offers to bring your passwords over.
- 1Password fills sign-in pop-ups, and no longer keeps your Mac busy after it's used.
- A tab you just left is no longer unloaded right away, so it doesn't reload when you come back.
- Text in the sidebar stays readable on every color: Zigzag picks light or dark by what actually reads better, at both ends of a gradient.
- Tabs in Show All Tabs fill their cards, instead of sitting in black bars.
- With the sidebar hidden, a split view's pages meet in the middle, with no gap.
- The site panel and downloads keep the slid-out sidebar open until you close them.
- The slid-out sidebar keeps your space's gradient and grain.
- The command bar keeps its margins in a narrow window.
- Right-click › Download Image and Download Linked File work.
- A site with a certificate problem explains why, and lets you visit a site you trust anyway.
- Export as PDF makes real pages.
- The offline page reloads by itself when you're back online.

## [0.1.7] - 2026-10-26

### New
- ⌃S shows and hides the sidebar, so ⌘S goes back to sites that save with it, like Google Docs and Figma.
- A link that leaves a pinned tab's site opens in a new tab, so your pinned Gmail is still Gmail when you come back. Signing in still happens in the pinned tab.
- In split view, a link that opens a new tab opens in that pane, so the split stays on screen.

### Fixed
- First run says to click the sites you use, and each browser's summary fits on one line.
- In Reader, ⌘⇧-click opens a tab in front, like on every page.

## [0.1.6] - 2026-10-26

### New
- Borderless: hide the sidebar and the page fills the whole window, with no frame around it. The sidebar slides out from the edge to move the window. Turn it off in Settings › Spaces.
- The page's corners square off as the sidebar slides away, and round again as it comes back.
- Double-click the sidebar to zoom the window, like a title bar.
- First run picks a color, gradient or glass with the same controls as the space editor.
- The empty downloads panel says what it's for, with a button for the Downloads folder.

### Fixed
- The space editor opens beside the sidebar, so it never covers your tabs or the dot you're editing.
- Google Search shows its own icon again, instead of the Maps pin.

## [0.1.5] - 2026-10-26

### New
- Spaces can be a color, a gradient, or glass you can see the desktop through.
- A new color wheel: every dot is the color your space will be, light in the middle and deeper toward the edge. Deep colors turn the window dark on their own.
- Presets from white to black, and gradients that look good from the start.
- Grain for any space, and a knob to turn a gradient's direction.
- Bigger back, forward, reload and sidebar buttons.
- Open favorites show a dot, and close from a badge on their corner.
- A pinned tab can keep the page you wandered to as its new page.
- A new install window in the DMG.

### Fixed
- Signing in to Google and other sites no longer stops at a passkey prompt asking for Bluetooth. They go straight to the password step.
- The selected option in a switch never gets cut off.

## [0.1.4] - 2026-10-25

### New
- Web notifications: sites like Gmail, Slack and Calendar can notify you (you choose per site).
- Tabs can tidy themselves: optionally archive tabs you haven't used, and find them again from the address bar.
- Sites can ask for your location, with the same prompt as the camera.
- Optionally ask where to save each download, and a download now flies into the Downloads button.
- Send Feedback in the Help menu.

### Fixed
- Opening a link with no window open no longer replaces your saved session, and links from other apps never open in a private window.
- ⌘← and ⌘→ no longer navigate away while you're typing.
- The address bar tells addresses from searches better (node.js, user@example.com) and keeps ports like localhost:3000.
- In-page navigations (YouTube videos, GitHub files) are recorded in history.
- Many sidebar, split view, undo and tab-overview fixes; ⌘1–9 now count favorites and pinned tabs.
- Reader opens instantly, with a new design.

## [0.1.3] - 2026-10-25

### New
- The first public release: signed and notarized, with updates that install themselves.

[Unreleased]: https://github.com/ZigaoWang/zigzag/compare/v0.9.5...HEAD
[0.10.0]: https://github.com/ZigaoWang/zigzag/compare/v0.9.5...HEAD
[0.9.5]: https://github.com/ZigaoWang/zigzag/compare/v0.9.4...v0.9.5
[0.9.4]: https://github.com/ZigaoWang/zigzag/compare/v0.9.3...v0.9.4
[0.9.3]: https://github.com/ZigaoWang/zigzag/compare/v0.9.2...v0.9.3
[0.9.2]: https://github.com/ZigaoWang/zigzag/compare/v0.9.1...v0.9.2
[0.9.1]: https://github.com/ZigaoWang/zigzag/compare/v0.9.0...v0.9.1
[0.9.0]: https://github.com/ZigaoWang/zigzag/compare/v0.8.6...v0.9.0
[0.8.6]: https://github.com/ZigaoWang/zigzag/compare/v0.8.5...v0.8.6
[0.8.5]: https://github.com/ZigaoWang/zigzag/compare/v0.8.4...v0.8.5
[0.8.4]: https://github.com/ZigaoWang/zigzag/compare/v0.8.3...v0.8.4
[0.8.3]: https://github.com/ZigaoWang/zigzag/compare/v0.8.2...v0.8.3
[0.8.2]: https://github.com/ZigaoWang/zigzag/compare/v0.8.1...v0.8.2
[0.8.1]: https://github.com/ZigaoWang/zigzag/compare/v0.8.0...v0.8.1
[0.8.0]: https://github.com/ZigaoWang/zigzag/compare/v0.7.9...v0.8.0
[0.7.9]: https://github.com/ZigaoWang/zigzag/compare/v0.7.8...v0.7.9
[0.7.8]: https://github.com/ZigaoWang/zigzag/compare/v0.7.7...v0.7.8
[0.7.7]: https://github.com/ZigaoWang/zigzag/compare/v0.7.6...v0.7.7
[0.7.6]: https://github.com/ZigaoWang/zigzag/compare/v0.7.5...v0.7.6
[0.7.5]: https://github.com/ZigaoWang/zigzag/compare/v0.7.4...v0.7.5
[0.7.4]: https://github.com/ZigaoWang/zigzag/compare/v0.7.3...v0.7.4
[0.7.3]: https://github.com/ZigaoWang/zigzag/compare/v0.7.2...v0.7.3
[0.7.2]: https://github.com/ZigaoWang/zigzag/compare/v0.7.1...v0.7.2
[0.7.1]: https://github.com/ZigaoWang/zigzag/compare/v0.7.0...v0.7.1
[0.7.0]: https://github.com/ZigaoWang/zigzag/compare/v0.6.2...v0.7.0
[0.6.2]: https://github.com/ZigaoWang/zigzag/compare/v0.6.1...v0.6.2
[0.6.1]: https://github.com/ZigaoWang/zigzag/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/ZigaoWang/zigzag/compare/v0.5.19...v0.6.0
[0.5.19]: https://github.com/ZigaoWang/zigzag/compare/v0.5.18...v0.5.19
[0.5.18]: https://github.com/ZigaoWang/zigzag/compare/v0.5.17...v0.5.18
[0.5.17]: https://github.com/ZigaoWang/zigzag/compare/v0.5.16...v0.5.17
[0.5.16]: https://github.com/ZigaoWang/zigzag/compare/v0.5.15...v0.5.16
[0.5.15]: https://github.com/ZigaoWang/zigzag/compare/v0.5.14...v0.5.15
[0.5.14]: https://github.com/ZigaoWang/zigzag/compare/v0.5.13...v0.5.14
[0.5.13]: https://github.com/ZigaoWang/zigzag/compare/v0.5.12...v0.5.13
[0.5.12]: https://github.com/ZigaoWang/zigzag/compare/v0.5.11...v0.5.12
[0.5.11]: https://github.com/ZigaoWang/zigzag/compare/v0.5.10...v0.5.11
[0.5.10]: https://github.com/ZigaoWang/zigzag/compare/v0.5.9...v0.5.10
[0.5.9]: https://github.com/ZigaoWang/zigzag/compare/v0.5.8...v0.5.9
[0.5.8]: https://github.com/ZigaoWang/zigzag/compare/v0.5.7...v0.5.8
[0.5.7]: https://github.com/ZigaoWang/zigzag/compare/v0.5.6...v0.5.7
[0.5.6]: https://github.com/ZigaoWang/zigzag/compare/v0.5.5...v0.5.6
[0.5.5]: https://github.com/ZigaoWang/zigzag/compare/v0.5.4...v0.5.5
[0.5.4]: https://github.com/ZigaoWang/zigzag/compare/v0.5.3...v0.5.4
[0.5.3]: https://github.com/ZigaoWang/zigzag/compare/v0.5.2...v0.5.3
[0.5.2]: https://github.com/ZigaoWang/zigzag/compare/v0.5.1...v0.5.2
[0.5.1]: https://github.com/ZigaoWang/zigzag/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/ZigaoWang/zigzag/compare/v0.3.1...v0.5.0
[0.3.1]: https://github.com/ZigaoWang/zigzag/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/ZigaoWang/zigzag/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/ZigaoWang/zigzag/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/ZigaoWang/zigzag/compare/v0.1.12...v0.2.0
[0.1.12]: https://github.com/ZigaoWang/zigzag/compare/v0.1.11...v0.1.12
[0.1.11]: https://github.com/ZigaoWang/zigzag/compare/v0.1.10...v0.1.11
[0.1.10]: https://github.com/ZigaoWang/zigzag/compare/v0.1.9...v0.1.10
[0.1.9]: https://github.com/ZigaoWang/zigzag/compare/v0.1.8...v0.1.9
[0.1.8]: https://github.com/ZigaoWang/zigzag/compare/v0.1.7...v0.1.8
[0.1.7]: https://github.com/ZigaoWang/zigzag/compare/v0.1.6...v0.1.7
[0.1.6]: https://github.com/ZigaoWang/zigzag/compare/v0.1.5...v0.1.6
[0.1.5]: https://github.com/ZigaoWang/zigzag/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/ZigaoWang/zigzag/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/ZigaoWang/zigzag/releases/tag/v0.1.3
