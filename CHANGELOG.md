# Changelog

Every release of Zigzag, newest first. The app shows the notes for the version you're running, and
[zigzagbrowser.com/release-notes](https://zigzagbrowser.com/release-notes) shows them all.

## [Unreleased]

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

[Unreleased]: https://github.com/ZigaoWang/zigzag/compare/v0.5.13...HEAD
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
