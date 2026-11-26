# Sync with iCloud

## Turning it on and off
- A new Zigzag, or one updated → Settings › General › Sync with iCloud is off, with nothing under it, and nothing touches iCloud.
  Test: SyncTests.theStatusLineSaysWhatSyncIsDoing
- Turn on Sync with iCloud → a sheet says what syncs, what stays on this Mac, and that it merges; Continue turns it on, Cancel leaves it off.
  No test yet.
- Continue → a Zigzag backup of this Mac's library, with every preference sync carries, is saved in Backups first, then the first sync merges this Mac with iCloud. Restoring it adds back whatever is missing; it doesn't undo renames or remove what the merge added.
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
- Sync turned on on two Macs at the same moment, both finding iCloud empty → each leaves a record of what it sent, and from those records alone every Mac matches the two copies of each profile, space, folder, pinned page and favorite by name and address, one to one, the same way, keeping one of each, however late each reads. What either Mac adds afterwards, and anything on a Mac that joined when iCloud already had a library, is never matched this way.
  Test: SyncTests.twoMacsTurningSyncOnAtOnceMakeNoCopies
  Test: SyncTests.twoFirstSyncsAtOnceAgreeHoweverLateOneReads
  Test: SyncTests.aSecondMacJoiningNormallyKeepsItsOwnDuplicatePins
- Something iCloud doesn't have → added to iCloud, never removed from this Mac.
  Test: SyncTests.theFirstSyncNeverRemovesWhatIsOnlyHere
- iCloud's copy reset, or sync turned on again after it was removed from iCloud → merged again, and nothing is added twice. A Mac that was offline during a reset matches its items as before the reset, even renamed ones, and nothing is copied; but as in any first sync, iCloud's version of what matched wins, so what that Mac changed offline is lost, and what it removed offline comes back from the Mac that sent first.
  Test: SyncTests.aResetWhileAnotherMacWasOfflineAddsNoCopies
  Test: SyncTests.turningSyncOnAgainAddsNothingTwice
- Sync turned off, things changed, and turned on again → what changed only on this Mac is kept, what changed only in iCloud is taken, and what changed on both goes to the later edit, this Mac's counting from when its library was last saved. What was removed here is removed everywhere, many at once held as at launch; what was removed in iCloud is removed here. Nothing is added twice. Turned on in another account, or after iCloud's copy was removed, it merges afresh as a first sync.
  Test: SyncTests.turningSyncOffRenamingAndOnAgainAddsNoCopy
  Test: SyncTests.turningSyncOnAgainKeepsWhatChangedOnEachSideWhileOff
  Test: SyncTests.turningSyncOnAgainAfterRemoveFromICloudMergesAfresh
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
  Test: SyncTests.aProfileRemovedElsewhereAndReadInPartsKeepsItsSpace
- A favorite removed on purpose from a profile that's removed later → stays removed; only what was removed with the profile, in the same fetch or the one just before, comes back with it.
  Test: SyncTests.aFavoriteRemovedOnPurposeDoesntComeBackWithItsProfileLater
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
- Signed in to a different iCloud account → sync stops and says so; this Mac's library is never sent to that account until sync is turned off and on again, even when its sync state couldn't be read.
  Test: SyncTests.anotherAccountIsNeverSyncedWithoutAsking
  Test: SyncTests.aStateFileThatCouldntBeReadStillKnowsTheAccount
- iCloud full, unreachable or unavailable → says so in plain words; changes wait on this Mac.
  Test: SyncTests.theStatusLineSaysWhatSyncIsDoing
- iCloud unreachable or refusing a request (an outage, a flaky network, an account not ready yet) → Zigzag tries again on its own after 30 seconds, then twice as long each time up to 30 minutes, never sooner than iCloud asks; at once when the network comes back, the account changes or the Mac wakes. It stops when sync is turned off.
  Test: SyncTests.aFirstSyncICloudRefusesIsTriedAgainUntilItGoesThrough
  Test: SyncTests.theWaitDoublesUpToHalfAnHourAndIsNeverSoonerThanICloudAsks
  Test: SyncTests.iCloudRefusingOrLosingARequestShowsItTriesAgain
  Test: SyncTests.theNetworkComingBackTriesAtOnceButNotInALoop
  Test: SyncTests.turningSyncOffStopsTryingAgain
- iCloud full → says so; changes wait on this Mac and are sent again after the same waits as when iCloud can't be reached, never at once.
  Test: SyncTests.aFullICloudIsTriedAgainWithTheUsualWaits
- Not signed in, iCloud restricted, or a Zigzag iCloud can't take → says so and doesn't try again on its own until the account or the network changes, or the Mac wakes.
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
- A folder moved to another space, read before its pages → the pages wait until they've moved too; nothing is left behind or sent back.
  Test: SyncTests.aFolderMovedToAnotherSpaceAndReadInPartsKeepsItsPages
- A split (or favorites side by side) read before its pages → the split shows once they arrive, and isn't sent back without them meanwhile.
  Test: SyncTests.aSplitReadBeforeItsPagesIsKept
- Something inside a space, folder or profile only a newer Zigzag can read → left as it is, never moved or rewritten here.
  Test: SyncTests.whatsInsideARecordANewerZigzagWroteIsLeftAlone
- A preference only a newer Zigzag knows, or one of a profile this Mac doesn't have → kept in iCloud as it is, never sent back as unset.
  Test: SyncTests.preferencesThisVersionDoesntKnowAreKeptAsTheyAre
- Zigzag opened, or sync turned on, with many things gone from the library at once (an old Library.json put back from Time Machine, say: more than 10 of one kind, and more than a quarter of them) → those removals aren't sent; everything else takes iCloud's version, so the old copy's stale titles and pins aren't sent either. A toast and Settings say so, with Restore, which brings them back from iCloud, and Remove Everywhere, which removes them from iCloud and the other Macs. Everything else keeps syncing meanwhile, each edit with its own time.
  Test: SyncTests.aLibraryPutBackFromAnOldCopyIsntSentAsRemovals
  Test: SyncTests.manyRemovalsSentWhenAsked
  Test: SyncTests.restoringAnOldCopyTakesICloudsVersionOfEverythingElse
  Test: SyncTests.anEditWhileRemovalsAreHeldKeepsItsOwnTime
- Zigzag opened with a Library.json older than the one sync last read (put back from a copy) → iCloud's version of everything, and nothing is sent.
  Test: SyncTests.aLibraryOlderThanTheOneLastSyncedSendsNothing
  Test: SyncTests.aClockOnceAheadDoesntMakeLaterLaunchesRollbacks
- Removing things by hand, however many (a space with all its pins) → sent at once; only a library found changed at launch or when sync is turned on is checked.
  Test: SyncTests.removingASpaceAndItsPinsByHandIsSentAtOnce
- Profiles.json gone while iCloud has this Mac's other profiles → read as a file that couldn't be read, and merged again as on a first sync; no profile is removed from iCloud.
  Test: SyncTests.aMissingProfilesFileIsUnreadableNotEveryProfileRemoved
- A removal iCloud refuses because the record is already gone → taken as done, never asked again; one refused for another reason is asked again with the next sync.
  Test: SyncTests.aRemovalOfWhatsAlreadyGoneIsntAskedAgain
- iCloud refuses a save as stale without sending its own version → Zigzag fetches it, merges, and sends again; the change isn't dropped.
  Test: SyncTests.aConflictWithoutTheServersVersionIsFetchedThenSentAgain
- Sync turned off while a fetch is on its way → what it brings changes nothing here.
  Test: SyncTests.aFetchStillOnItsWayWhenSyncIsTurnedOffChangesNothing
- Two fetches crossing, the older bringing a removal after the newer brought the record back → the removal is ignored. Zigzag runs one catch-up at a time.
  Test: SyncTests.aLateRemovalFromAFetchThatCrossedANewerOneIsIgnored
  Test: SyncTests.aRemovalAfterThisMacsOwnSaveIsntTakenForStale
- Zigzag quit right after an edit → the edit is read before quitting; one found at the next launch counts from when the library was last saved, never from the launch, so it doesn't beat a later edit on another Mac.
  Test: SyncTests.anEditFoundAtLaunchCountsFromWhenItWasMade
