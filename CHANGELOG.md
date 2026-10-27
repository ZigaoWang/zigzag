# Changelog

Every release of Zigzag, newest first. The app shows the notes for the version you're running, and
[zigzagbrowser.com/changelog](https://zigzagbrowser.com/changelog) shows them all.

## [0.1.11] - 2026-10-27

### New
- Pick several tabs and pinned tabs with ⌘-click or ⇧-click, then drag them into a folder together, or right-click to add them to a folder, pin them or close them.
- New folders start at the top of your pinned tabs.
- A space with no tabs shows its own color instead of a blank white page.

### Fixed
- Settings opens straight to each pane, and the window fits what's in it.
- About Zigzag is simpler, with links to the website, the source and the license.

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

[0.1.11]: https://github.com/ZigaoWang/zigzag/compare/v0.1.10...v0.1.11
[0.1.10]: https://github.com/ZigaoWang/zigzag/compare/v0.1.9...v0.1.10
[0.1.9]: https://github.com/ZigaoWang/zigzag/compare/v0.1.8...v0.1.9
[0.1.8]: https://github.com/ZigaoWang/zigzag/compare/v0.1.7...v0.1.8
[0.1.7]: https://github.com/ZigaoWang/zigzag/compare/v0.1.6...v0.1.7
[0.1.6]: https://github.com/ZigaoWang/zigzag/compare/v0.1.5...v0.1.6
[0.1.5]: https://github.com/ZigaoWang/zigzag/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/ZigaoWang/zigzag/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/ZigaoWang/zigzag/releases/tag/v0.1.3
