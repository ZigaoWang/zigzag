# Downloads

## Where files go
- A download → saved straight to Downloads, or the folder picked in Settings › Downloads while it's still there; Ask Each Time shows the save sheet instead.
  No test yet.
- Two files with one name, even started together → the second gets a name of its own, like "report 2.pdf"; nothing is overwritten.
  Test: DownloadRuleTests.aDestinationIsReadAsAPlaceToSave

## What a page may save
- A file sent as an attachment, or one Zigzag can't show → saved; web pages and anything else it can show open as pages.
  Test: DownloadPolicyTests.anAttachmentIsSavedNotShown
- A file you went to yourself (a click, a typed or pasted address, and its redirects) → always saves.
  Test: DownloadPolicyTests.whereYouSentThePageAlwaysSaves
- A download nobody clicked for → one goes through, then more are blocked for 30 seconds unless you click or type.
  Test: DownloadPolicyTests.downloadsNobodyClickedForDontComeInAStream

## Asking before a site downloads
- Out of the box → off; sites download without a question.
  Test: SitePermissionsPolicyTests.askingBeforeADownloadIsOffByDefault
- Ask before a site downloads files, in Settings › Privacy → a site's first file asks; Allow with Remember is kept, so its next one doesn't.
  Test: SitePermissionsPolicyTests.askingOnceKeepsTheAnswerForTheSite
- A Block kept for a site → its downloads stop, with asking off too.
  Test: SitePermissionsPolicyTests.aStoredBlockWinsWithTheSettingOff

## The downloads panel
- The sidebar's download button → the five newest downloads, and Open Downloads Folder at the bottom.
  No test yet.
- A download starting → the panel opens on just that one, with Show All Downloads for the rest; it closes six seconds after the file is done unless you're using it.
  No test yet.
- The panel's width → wide enough for every label, at the narrowest sidebar, in English and Chinese.
  Test: DownloadsPanelLayoutTests.everyLabelFitsAtTheNarrowestSidebar
- A row → the file's icon, name and progress or size; Pause and Cancel while coming in, Show in Finder when done, Try Again when a failed one can be, Download Again when the file was moved or deleted.
  No test yet.

## Download rules
- Rules in Settings › Downloads → the first one that matches, top to bottom, takes the download.
  Test: DownloadRuleTests.firstMatchWinsTopToBottom
- A rule that hands downloads to an app, a script or a service → asks first: Don't Allow, Save in Zigzag or Hand Off.
  No test yet.
- Always for the rule on that question → the answer holds on every site.
  Test: DownloadRuleTests.aRulesOwnAnswerStandsForEverySite
- A tab in the background or Zigzag behind another app → no question; the file saves in Zigzag unless an answer was kept.
  Test: DownloadRuleTests.aQuestionIsOnlyAskedWhereItCanBeSeen
- A site's cookies → go along only for the page's own site or a link you clicked.
  Test: DownloadRuleTests.cookiesGoOnlyToThePagesOwnSiteOrAClick
- A file type rule → saves those files to its folder, or saves them and opens them in the Mac's app.
  Test: DownloadRuleTests.aDestinationIsTheFirstThatMatches
- Open for apps, scripts, installers, archives and web pages → never opens them; they're only saved.
  Test: DownloadRuleTests.anOpenNeverTakesAnAppScriptOrArchive

## Video on a page
- A streamed video on x.com with OldTwitter → Download Video saves the mp4 the page lists, not the playlist, in WebKit's place.
  Test: VideoMenuTests.aStreamShowsOneDownloadVideo
- A video whose source is already a file → WebKit's own Download Video, with nothing added beside it.
  Test: VideoMenuTests.aFileIsLeftToWebKit

## Firefox add-ons
- Add to Zigzag on addons.mozilla.org → the .xpi goes to the install sheet, not to Downloads.
  Test: DownloadPolicyTests.firefoxPackagesAreInstalledNotSaved
- An .xpi from any other site, or another file than the store names → a plain download.
  Test: AddonsMozillaPageTests.onlyTheStoresOwnDownloadPathIsAPackage

## Private windows
- A private window's downloads → listed only in private windows, gone from the list when the last one closes; the files stay.
  No test yet.
- A download rule → runs in private windows only when allowed there.
  Test: DownloadRuleTests.privateWindowsRunOnlyTheRulesLetIn
- Allow with Remember on a private window's download question → holds for that page; nothing is kept for the site.
  Test: SitePermissionsPolicyTests.aDownloadDenyIsKeptForTheSiteAndAPrivateTabKeepsNothing

## Extensions
- An extension's download → shows in Downloads like any other, under a plain file name that stays in the folder.
  Test: ExtensionBridgeTests.downloadNamesCantClimbOut
- An extension saving a blob: → only one it made itself, read from its own page.
  Test: ExtensionBridgeTests.blobDownloadsKnowWhichExtensionMadeThem
- An extension → sees only its own profile's downloads, and a private window's only when allowed there.
  Test: ExtensionBridgeTests.privateDownloadsOnlyToAnExtensionAllowedThere
