# Changelog

Every release of Zigzag, newest first. The app shows the notes for the version you're running, and
[zigzagbrowser.com/release-notes](https://zigzagbrowser.com/release-notes) shows them all.

## [Unreleased]

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

[Unreleased]: https://github.com/ZigaoWang/zigzag/compare/v0.3.0...HEAD
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
