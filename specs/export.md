# Export

## Bookmarks file
- File › Export Your Data… with Bookmarks file on → an HTML bookmarks file other browsers import: one folder per space in the sidebar's order, its pinned pages and folders nested as in the sidebar, a split's pages one after another, an empty folder at the top of its level, and favorites in a Zigzag Favorites folder, which no importer folds away.
  Test: ExportTests.theBookmarksFileNestsAsTheSidebarAndReadsBackThroughTheImporter
- Titles, folder names and addresses with `&`, `<`, `>` or `"` → escaped, and read back as they were.
  Test: ExportTests.theBookmarksFileNestsAsTheSidebarAndReadsBackThroughTheImporter
- More than one profile → a folder per profile around its own favorites and spaces; with Open tabs on, each space's open tabs in an Open Tabs folder inside it.
  Test: ExportTests.eachProfileIsAFolderWithItsOwnFavoritesAndSpaces
- Private windows' tabs → never exported.
  Test: ExportTests.privateWindowsTabsAreLeftOut
- The save panel → offers "Zigzag Bookmarks <date>.html" or "Zigzag Backup <date>.zigzagbackup"; with both chosen, a folder, and a file already there gets a number after its name.
  Test: ExportTests.defaultNamesCarryTheDate

## Zigzag backup
- A backup → reads back with its spaces, favorites, icons, history and settings as they were written.
  Test: ExportTests.aBackupReadsBackAsItWasWritten
- A backup from a newer Zigzag, or a file that isn't one → not read; the Import window says why.
  Test: ExportTests.aNewerOrForeignFileIsNotRead
- Settings in a backup → preferences and site settings only, never passwords, keys, counters or what lets other apps in; a backup that names more only ever restores those.
  Test: ExportTests.settingsCarryPreferencesNeverSecretsOrCounters

## Restoring
- Choose File… in the Import window with a backup → its spaces, pinned tabs, folders, splits and favorites are added; restoring it again adds nothing.
  Test: ExportTests.restoringTwiceAddsNothingTheSecondTime
- A space that's still here → gains only the pages it doesn't have, in the folders they were in.
  Test: ExportTests.aSpaceThatsStillHereGainsOnlyWhatItLacks
- Pinned pages or favorites whose addresses differ only after the # → both come back.
  Test: ExportTests.pinsThatDifferOnlyAfterTheHashAreBothRestored
- A new Mac's first space, of the same name and with nothing pinned → takes the backup's look and pages, not a second copy.
  Test: ExportTests.aNewMacsFirstSpaceTakesTheBackupsLook
- Profiles → come back with their spaces and favorites.
  Test: ExportTests.profilesComeBackWithTheirSpacesAndFavorites
- A page whose ID is taken here → comes back under a new one.
  Test: ExportTests.pagesWhoseIDsAreTakenGetNewOnes
- A backup whose settings differ from yours → the Import window asks whether to use them or keep yours.
  No test yet.
- Double-click a backup in Finder → the Import window asks before restoring it; it never opens as a page.
  Test: ExportTests.aBackupOpenedFromFinderGoesToTheImportWindowNeverATab
- A backup opened from Finder → nothing changes until the question is answered.
  Test: ExportTests.aBackupOpenedFromFinderAsksBeforeRestoring
