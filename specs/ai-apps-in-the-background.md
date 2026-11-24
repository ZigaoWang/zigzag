# AI apps in the background

Settings › Automation › Run AI apps in the background (#214). Off until you turn it on, and only while Let AI apps use
Zigzag is on too. AI apps then work in an unseen window of their own, on the AI Apps profile.

## Turning it on
- Both switches on → AI apps work in the background; either off → they don't.
  Test: HeadlessTests.onlyWithBothSwitchesOn
- `--headless` with either switch off → Zigzag says why on stderr and exits; a running copy ignores the request.
  Test: HeadlessTests.notAskedForWhileOff
- `--headless` with both on and Zigzag closed → no Dock icon or window; your windows wait until you open Zigzag.
  Test: HeadlessTests.yourWindowsWait
- Running for AI apps alone, nothing asked for 30 minutes and nothing downloading → Zigzag quits.
  Test: HeadlessTests.goesAfterAWhileWithNothingToDo

## Their window
- An app opens a tab → it's in their window, parked out of sight, on the AI Apps space.
  Test: HeadlessTests.theirWindow
- Their window → shows and keeps tabs only in the AI Apps spaces.
  Test: HeadlessWindowSpacesTests.itKeepsToItsProfilesSpaces
- Show AI Apps Window → their window comes on screen with the same tabs; closing it hides it again.
  Test: ShowHeadlessWindowTests.outAndBackWithTheSameTabs
- A page there asks for a dialog, a file, a sign-in or a permission → answered no at once, and the app is told.
  Test: UnattendedPageTests.aPermissionAskedThereIsRefusedAndTold
- A page there asks for full screen → it fills its page only, never your screen.
  Test: NothingOfYoursTests.noFullScreenOrClipboardWrites
- A page there copies, cuts or writes the clipboard → refused.
  Test: NothingOfYoursTests.noFullScreenOrClipboardWrites
- A download there → into a Downloads folder in the AI Apps profile's data, out of your list and the Dock.
  Test: HeadlessTests.theirDownloadsHaveAFolderOfTheirOwn

## Your windows
- The AI Apps space → not in your sidebar, command bar, space menus, Settings › Spaces or a space's Profile menu.
  Test: HeadlessWindowSpacesTests.yourWindowsLeaveTheirSpaceOut

## Nothing of yours
- Saved sign-ins → never given to their pages.
  Test: NothingOfYoursTests.noSavedSignIn
- Client certificates → never given; the site goes on without one.
  Test: NothingOfYoursTests.noCertificate
- Passwords and My Card → never saved or filled there.
  Test: NothingOfYoursTests.noPasswordsOrCard
- Passkeys → their pages are told there are none.
  Test: NothingOfYoursTests.noPasskeys
- What you allowed a site → not given there; the site is asked, and so refused.
  Test: NothingOfYoursTests.noPermissionsYouGave
- Your download and link rules → none apply there.
  Test: NothingOfYoursTests.noRulesOfYours
- Your site routes → none send their pages out.
  Test: NothingOfYoursTests.noRoutesOfYours
- Apps on This Mac → never reached from their pages.
  Test: NothingOfYoursTests.noDoorToAppsOnThisMac
- Your Archive → their tabs never go there.
  Test: NothingOfYoursTests.noPlaceInYourArchive

## The profile
- Settings › Profiles → AI Apps is listed; its name can't be changed.
  Test: HeadlessProfileTests.itsNameStays
- Delete it while AI apps work in it → refused.
  Test: HeadlessProfileTests.itsNotRemovedWhileAIAppsUseIt
- Delete it → its space and routes to it go too; it's made anew when next needed.
  Test: HeadlessSpaceTests.madeOnceAndGoneWithItsProfile
