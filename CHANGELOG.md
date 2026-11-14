# Changelog

Every release of Zigzag, newest first. The app shows the notes for the version you're running, and
[zigzagbrowser.com/release-notes](https://zigzagbrowser.com/release-notes) shows them all.

## [Unreleased]

### New
- The Now Playing card at the bottom of the sidebar can be hidden: point at it and click the close button at its end, or right-click it for Hide. The tab keeps playing, and the card comes back when that tab moves on to another page, or for another tab that starts playing. The card is laid out as a tab's row now, the same height, columns and buttons, and follows Settings › Appearance › Sidebar size. ([#223](https://github.com/ZigaoWang/zigzag/issues/223))

## [0.9.0] - 2026-11-12

Split view with up to four pages, sites installed as apps of their own, the sidebar on either side, and tabs that move between windows as they are. Dark pages now use Dark Reader, ad blocking adds uBlock Origin's filter lists, cookie pop-ups are turned down for you, and Site Controls is rebuilt.

### New
- Zigzag Mini has Back, Forward and Reload after the traffic lights, as a browser window does: Back and Forward dim when there's no page that way, Reload turns into Stop while the page loads, and right-clicking Back or Forward lists the pages that way. ([#213](https://github.com/ZigaoWang/zigzag/issues/213))
- Your extensions are in Site Controls itself, under its actions, instead of on a page of their own: click one to open its popup or run it, as its toolbar button would, with its badge on it. One that can't work on the site you're on (no access, When You Click It, or extensions off there) is dimmed and says why when you point at it, and right-clicking one gives its menu. The Extensions header folds them to a strip of their first icons, each still one click away, and opens them again; up to three show with their names, and many show two rows with Show All. It starts open with up to four extensions and folded with more, until you choose. The switch for whether extensions run on a site is now with This Site's other switches. ([#215](https://github.com/ZigaoWang/zigzag/issues/215))
- Right-clicking a page, or a tab in the sidebar, has Translate to English (in the language you read), and Show Original once it's translated, without opening Site Controls. It translates whatever language Zigzag thought the page was in, and says so when nothing on it needed translating. Zigzag also notices more pages in other languages: it goes by the paragraphs you see rather than the site's menus or the language the page claims, and checks again on pages that draw their text late or change without loading. Thanks to [bkonia](https://github.com/bkonia). ([#218](https://github.com/ZigaoWang/zigzag/issues/218))
- AI apps can wait for a page and press keys in it. `wait_for` waits until some text or an element shows or goes, or the page finishes loading, for up to 30 seconds, and stops when the tab closes or loads another page, or when you press Stop. `press_key` presses Enter, Escape, Tab, the arrows and other keys as your keyboard would, so Enter submits a form and Tab moves to the next field; keys only reach the page, never Zigzag's shortcuts, and never type into password fields. ([#214](https://github.com/ZigaoWang/zigzag/issues/214))
- Importing from Arc brings each space's open tabs too, in Arc's order, with split views side by side. They wait to load until you click them, so hundreds of tabs don't all load at once, and importing again doesn't open a tab twice. Open Tabs, beside Spaces and Pinned Tabs in the Import window, leaves them behind. Thanks to [alextend](https://github.com/alextend). ([#210](https://github.com/ZigaoWang/zigzag/issues/210))
- Space icons at the bottom of the sidebar are bigger, and follow Settings › Appearance › Sidebar size: a little bigger at Medium than before, and clearly bigger at Large. Thanks to [alextend](https://github.com/alextend). ([#210](https://github.com/ZigaoWang/zigzag/issues/210))
- A faint line over the sidebar's bottom bar shows while tabs run on under it, as a scroll edge does. Thanks to [alextend](https://github.com/alextend). ([#210](https://github.com/ZigaoWang/zigzag/issues/210))
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
- Animations share one set of timings: presses and hovers answer in about a tenth of a second, small changes like a switch take a moment longer, panels and menus grow out of what opened them and leave quicker than they came, and the sidebar, notices and the window's layout slide on one curve. Switching spaces fades the window's color, gradient and grain together, a switch's knob and color move in step, and nothing bounces. With Reduce Motion, nothing travels: things crossfade, or change at once. ([#217](https://github.com/ZigaoWang/zigzag/issues/217))
- Security fixes from a private report: pictures from websites are read in a sandboxed helper and web PDFs stay in WebKit's sandboxed viewer, user scripts run apart from the extension that installed them, ad blocking only runs scriptlets this version knows, a page can't open another app without asking, a certificate you visit anyway shows as not secure, Stop really cuts off AI apps, and extension packages and permissions are checked more strictly.
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

[Unreleased]: https://github.com/ZigaoWang/zigzag/compare/v0.5.17...HEAD
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
