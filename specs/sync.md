# Sync with iCloud

## Turning it on and off
- A new Zigzag, or one updated → Settings › General › Sync with iCloud is off, with nothing under it, and nothing touches iCloud.
  Test: SyncTests.theStatusLineSaysWhatSyncIsDoing
- Turn on Sync with iCloud → a sheet says what syncs, what stays on this Mac, and that it merges; Continue turns it on, Cancel leaves it off.
  No test yet.
- Continue → a Zigzag backup of this Mac's library is saved in Backups first, then the first sync merges this Mac with iCloud.
  Test: SyncTests.aBackupIsSavedBeforeTheFirstSync
- The backup can't be saved (a full disk) → sync stays off and says so; nothing goes to iCloud.
  Test: SyncTests.withoutABackupSyncStaysOff
- Turn it off → everything stays on this Mac as it is, and iCloud keeps its copy.
  No test yet.
- Remove from iCloud…, then Remove → iCloud's copy is removed for every Mac and sync turns off; this Mac keeps everything. Another Mac syncing with it turns sync off too and keeps its own.
  No test yet.

## What syncs
- Spaces → their name, color, glass, icon, order and profile.
  Test: SyncTests.editsToDifferentThingsBothArrive
- Profiles → their name, color and order, matched by name on a second Mac; never their sign-ins, history or other website data.
  Test: SyncTests.profilesAndTheirFavoritesSync
  Test: SyncTests.aSecondMacsProfileOfTheSameNameIsTheSameProfile
- Pinned pages and folders → title, address, emoji or symbol, order, nesting, and whether a folder is open; a pinned split stays a split.
  Test: SyncTests.foldersNestingIconsAndFoldStateSync
  Test: SyncTests.aPinnedSplitStaysASplit
- Favorites → each profile's, in their order.
  Test: SyncTests.profilesAndTheirFavoritesSync
- A live folder → its source, its count and its name, never the pages it fetched; each Mac fetches its own.
  Test: SyncTests.aLiveFolderSyncsItsSourceNotItsPages
- Settings → preferences about how Zigzag behaves, sites in spaces, and per-site choices like zaps, compatibility mode, zoom and dark pages; never ones about this Mac (window sizes, the download folder, the update channel, debug switches) or what lets other apps in.
  Test: SyncTests.onlyPreferencesTravelNeverWhatIsAboutThisMac
- Site permissions (camera, microphone, location, notifications, pop-ups, downloads), scripts allowed on a site where they're off, password filling and clearing cookies on quit → stay on each Mac. A grant is made on the Mac it's for, as in Safari; password filling follows the password app each Mac has; clearing cookies on quit turned on elsewhere would sign you out here. Blocking scripts on a site does travel.
  Test: SyncTests.permissionsPasswordFillingAndCookieClearingStayOnEachMac
- Open tabs, history, cookies and website data, passwords, extensions, downloads, picture icons and space pictures → stay on this Mac. Passwords sync through iCloud Keychain as before.
  Test: SyncTests.onlyPreferencesTravelNeverWhatIsAboutThisMac

## The first sync
- A second Mac with its own library → merged, never replaced: a space of the same name on the same profile, a folder of the same name in the same place and a pinned page with the same address in the same place are one, as iCloud has them, and what's only on this Mac is added beside where it was.
  Test: SyncTests.theFirstSyncMergesDuplicatesByNameAndAddress
  Test: SyncTests.aSecondMacsFirstSpaceIsMatchedByNameNotCopied
- Two pinned pages or favorites whose addresses differ only after the # (a web app's views) → stay two.
  Test: SyncTests.pinsThatDifferOnlyAfterTheHashStayTwo
- Sync turned on on two Macs at the same moment, both finding iCloud empty → for an hour after, their profiles, spaces, folders, pages and favorites are matched by name and address as they arrive, and each pair becomes one on both Macs. A space of the same name made on purpose on the other Mac in that hour is taken for the same one too.
  Test: SyncTests.twoMacsTurningSyncOnAtOnceMakeNoCopies
- Something iCloud doesn't have → added to iCloud, never removed from this Mac.
  Test: SyncTests.theFirstSyncNeverRemovesWhatIsOnlyHere
- Sync turned on again, or iCloud's copy reset → merged again, and nothing is added twice. A Mac that was offline during a reset matches its items as before the reset, even renamed ones, and nothing is copied; but as in any first sync, iCloud's version of what matched wins, so what that Mac changed offline is lost, and what it removed offline comes back from the Mac that sent first.
  Test: SyncTests.aResetWhileAnotherMacWasOfflineAddsNoCopies
  Test: SyncTests.turningSyncOnAgainAddsNothingTwice
- Sync turned off, something renamed, and turned on again → the renamed space, folder or page is matched as it was before, taking iCloud's version, never added again.
  Test: SyncTests.turningSyncOffRenamingAndOnAgainAddsNoCopy
- This Mac's library couldn't be read and Zigzag started afresh → merged again as on a first sync, so iCloud fills it in; nothing is removed from iCloud.
  Test: SyncTests.aLibraryThatCouldntBeReadIsFilledFromICloudNotEmptiedInto
- Zigzag quit before the first sync finished → the next start reads all of iCloud again before merging.
  Test: SyncTests.aFirstSyncCutShortReadsICloudAgainFromTheStart

## Two Macs at once
- Edits to different things on two Macs → both arrive on both.
  Test: SyncTests.editsToDifferentThingsBothArrive
- The same thing edited on two Macs → the later edit wins on both.
  Test: SyncTests.theLastEditToOnePageWins
- A page moved on one Mac while another pins a new one → both keep their places.
  Test: SyncTests.aMoveAndAnInsertAtOnceBothKeepTheirPlaces
- Preferences changed on two Macs → each keeps the later value of each preference.
  Test: SyncTests.preferencesMeetKeyByKey
- Site rules or pinned splits changed on two Macs at once → each Mac's changes are kept, rule by rule and split by split.
  Test: SyncTests.siteRulesAndSplitsEditedOnTwoMacsKeepBoth
- Many pages added at one spot → only the places around it change, never the whole list's, so other Macs' edits to the rest aren't overwritten.
  Test: SyncTests.aMoveChangesOnlyThePlaceOfWhatMoved
- Edits made offline → sent when the Mac is back online, merged with what changed meanwhile.
  Test: SyncTests.editsMadeOfflineArriveWhenBackOnline
- Something removed on one Mac → removed on the other.
  Test: SyncTests.removalsReachTheOtherMac
- A folder removed on one Mac while a page is filed into it on another → the page stays, at the top level of its space.
  Test: SyncTests.aPageAddedToAFolderRemovedElsewhereMovesToTheTopOfItsSpace
- A space removed on one Mac while a page is pinned in it on another → the page stays, in the first space.
  Test: SyncTests.aSpaceRemovedElsewhereKeepsAPageJustPinnedInIt
- A page removed on one Mac while it's edited on another → the edited page comes back.
  Test: SyncTests.aPageEditedHereComesBackWhenRemovedElsewhere
- A profile removed on one Mac → stays on the others with its spaces, favorites, settings, sign-ins and website data, and from then on it's that Mac's own and no longer syncs. Its spaces keep syncing.
  Test: SyncTests.aProfileRemovedOnAnotherMacStaysHereWithItsSpaces
  Test: SyncTests.aProfilesFavoritesRemovedBeforeItStayWithItHere
- A preference too big for iCloud (long styles for many sites) → stays on this Mac and isn't replaced by another Mac's; the rest still sync.
  Test: SyncTests.aPreferenceTooBigForICloudStaysOnThisMac
- A pinned page too big for iCloud (a long data: address) → stays on this Mac and isn't sent, without asking iCloud again and again.
  Test: SyncTests.aRecordTooBigForICloudIsntSentAndStaysHere
- Nothing changed → nothing is sent.
  Test: SyncTests.onceSettledNothingMoreIsSent
- A thousand pinned pages → sync without a wait, and one edit sends one record.
  Test: SyncTests.aThousandPinnedPagesSyncQuickly
- Records a newer Zigzag wrote → read, and their new fields and kinds are kept when this Mac edits or removes around them.
  Test: SyncTests.olderAndNewerRecordsStillRead
  Test: SyncTests.aNewerZigzagsFieldsSurviveAnEditHere
  Test: SyncTests.aKindOnlyANewerZigzagKnowsIsLeftAlone

## iCloud's state
- Under the switch → Syncing…, Up to date, or Last synced and how long ago, with Remove from iCloud….
  Test: SyncTests.theStatusLineSaysWhatSyncIsDoing
- Not signed in to iCloud → says so, with Open System Settings; nothing on this Mac changes.
  Test: SyncTests.theStatusLineSaysWhatSyncIsDoing
- Signed in to a different iCloud account → sync stops and says so; this Mac's library is never sent to that account until sync is turned off and on again.
  Test: SyncTests.anotherAccountIsNeverSyncedWithoutAsking
- iCloud full, unreachable or unavailable → says so in plain words; changes wait on this Mac.
  Test: SyncTests.theStatusLineSaysWhatSyncIsDoing
- iCloud unreachable or refusing a request (an outage, a flaky network, an account not ready yet) → Zigzag tries again on its own after 30 seconds, then twice as long each time up to 30 minutes, never sooner than iCloud asks; at once when the network comes back, the account changes or the Mac wakes. It stops when sync is turned off.
  Test: SyncTests.aFirstSyncICloudRefusesIsTriedAgainUntilItGoesThrough
  Test: SyncTests.theWaitDoublesUpToHalfAnHourAndIsNeverSoonerThanICloudAsks
  Test: SyncTests.iCloudRefusingOrLosingARequestShowsItTriesAgain
  Test: SyncTests.theNetworkComingBackTriesAtOnceButNotInALoop
  Test: SyncTests.turningSyncOffStopsTryingAgain
- Not signed in, iCloud restricted, iCloud full, or a Zigzag iCloud can't take → says so and doesn't try again on its own until the account or the network changes, or the Mac wakes.
  Test: SyncTests.anErrorWaitingWontFixWaitsForTheAccountOrNetwork
- Zigzag opened on a Mac that was off while things changed elsewhere → it fetches them as it connects, then sends what's waiting here, without waiting to be brought forward.
  Test: SyncTests.aMacStartedAfterItsFirstSyncFetchesWhatChangedWhileItWasAway
  Test: SyncTests.aFirstConnectionMergesThenSends
- The first sync on an iCloud that has no Zigzag library yet → this Mac's library goes up and makes it. iCloud's library gone after a sync (removed on another Mac, or iCloud's data deleted in System Settings), found by a fetch or a save → sync turns off here and says so, without trying again or making it again; this Mac keeps everything.
  Test: SyncTests.aFirstSyncIntoAnICloudWithoutTheZoneMergesWithNothing
  Test: SyncTests.aZoneRemovedAfterTheFirstSyncIsRemovedElsewhereNotTriedAgain
  Test: SyncTests.aSaveFindingTheZoneGoneNeverMakesItAgain
- Something changed on another Mac while Zigzag is open here → iCloud's push fetches it within seconds; pushes for other apps are ignored.
  Test: SyncTests.onlyZigzagsOwnPushesFromICloudFetch
- Zigzag quits in the middle of a fetch → what the fetch brought is saved with how far it read, and arrives at the next launch; nothing is skipped.
  Test: SyncTests.whatAFetchBroughtBeforeAQuitArrivesAfterIt
- No push arrives (CloudKit's scheduler refused it, or the Mac was off) → Zigzag reads the zone's changes itself, from where it last read, at launch, on waking, when brought forward after a minute away and every 15 minutes. A record read twice, or an older copy read late, changes nothing.
  Test: SyncTests.aMacStartedAfterItsFirstSyncFetchesWhatChangedWhileItWasAway
  Test: SyncTests.aRecordFetchedTwiceOrLateChangesNothing
- Edits made before sync connects (offline at launch, signed out for a while) or not yet sent when Zigzag quit → sent once it connects, from what this Mac knows is unsent, never only from the server's own queue.
  Test: SyncTests.editsMadeBeforeConnectingAreSentOnceConnected
- A page, folder or favorite read before its space, folder or profile (a send read halfway) → waits on this Mac until its parent arrives, and nothing is moved or sent back meanwhile. Each Mac sends spaces before folders before pages.
  Test: SyncTests.aPageArrivingBeforeItsSpaceWaitsForIt
- Something inside a space, folder or profile only a newer Zigzag can read → left as it is, never moved or rewritten here.
  Test: SyncTests.whatsInsideARecordANewerZigzagWroteIsLeftAlone
- A preference only a newer Zigzag knows, or one of a profile this Mac doesn't have → kept in iCloud as it is, never sent back as unset.
  Test: SyncTests.preferencesThisVersionDoesntKnowAreKeptAsTheyAre
- Many things removed here at once (an old Library.json put back from Time Machine, say: more than 10 of one kind, and more than a quarter of them) → nothing is sent; sync pauses and Settings says so, with Restore, which brings them back from iCloud and keeps what else changed here, and Remove Everywhere, which removes them from iCloud and the other Macs. A few removed by hand go up as usual.
  Test: SyncTests.aLibraryPutBackFromAnOldCopyIsntSentAsRemovals
  Test: SyncTests.manyRemovalsSentWhenAsked
- Profiles.json gone while iCloud has this Mac's other profiles → read as a file that couldn't be read, and merged again as on a first sync; no profile is removed from iCloud.
  Test: SyncTests.aMissingProfilesFileIsUnreadableNotEveryProfileRemoved
- A removal iCloud refuses because the record is already gone → taken as done, never asked again; one refused for another reason is asked again with the next sync.
  Test: SyncTests.aRemovalOfWhatsAlreadyGoneIsntAskedAgain
