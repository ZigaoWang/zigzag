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
- A click or key in the page since the last download nobody clicked for → the next one the page starts goes through, even after it waited on its server.
  Test: DownloadPolicyTests.aClickInThePageCountsForItsNextDownload
- A hidden frame handing over a file the page made after your click (an export) → saved under the name the server gives, like the page's own download; a burst of them is held back the same way.
  Test: DownloadPolicyTests.aFrameSavesLikeThePageItIsIn
  Test: PageDownloadsTests.aHiddenFrameHandingOverAnExportSaves
  Test: PageDownloadsTests.aHiddenFrameNobodyClickedForSavesOnceThenAfterAClick
- A download held back → a note says the page's download was blocked; a frame's says a frame in the page started it.
  Test: DownloadPolicyTests.aFramesFileAnswersToTheFramesOwnSites
- A page's own file (a blob: or data: link with a download name, revoked right after its click, or never added to the page) → saved under that name.
  Test: PageDownloadsTests.aBlobRevokedRightAfterItsClickSaves
  Test: PageDownloadsTests.aDataAddressSavesUnderItsName
  Test: PageDownloadsTests.anAnchorNeverAddedToThePageSaves
- A page's file made after it fetched something, with no click left → saved under its download name.
  Test: PageDownloadsTests.aFetchedBlobClickedAfterAnAwaitSaves
- A page's own file opened in a new window, or a form answered with an attachment → saved.
  Test: PageDownloadsTests.aBlobOpenedInANewWindowSaves
  Test: PageDownloadsTests.aFormPostAnsweredWithAnAttachmentSaves
- A download link to another origin → opens like any link; the download name only counts on the page's own origin, as in Chrome and Safari.
  Test: PageDownloadsTests.anotherOriginsDownloadLinkOpens

## Asking before a site downloads
- Out of the box → off; sites download without a question.
  Test: SitePermissionsPolicyTests.askingBeforeADownloadIsOffByDefault
- Ask before a site downloads files, in Settings › Privacy → a site's first file asks; Allow with Remember is kept, so its next one doesn't.
  Test: SitePermissionsPolicyTests.askingOnceKeepsTheAnswerForTheSite
- A Block kept for a site → its downloads stop, with asking off too.
  Test: SitePermissionsPolicyTests.aStoredBlockWinsWithTheSettingOff
- A frame's file → asks as the page's own would, naming the page's site; a Block kept for the frame's site or the page's stops it, with asking off too.
  Test: PageDownloadsTests.aHiddenFrameAsksWhenAskingIsOn
  Test: PageDownloadsTests.aBlockForTheFramesSiteOrThePagesStopsAFramesFile
  Test: DownloadPolicyTests.aFramesFileAnswersToTheFramesOwnSites

## The downloads panel
- The sidebar's download button → the downloads from the last hour and any under way or paused, newest at the top, at most five, or the newest alone when none is that recent; Show All Downloads at the bottom for the earlier ones, or Open Downloads Folder when there are none.
  Test: DownloadsPanelListTests.openedYourselfItListsTheRecentOnesNewestFirst
- Show All Downloads → every download, newest at the top, as many as fit above the button (five at least, twelve at most), and Open Downloads Folder at the bottom.
  Test: DownloadsPanelListTests.showAllListsAsManyAsFitNewestFirst
- While something downloads, the button's circle → a progress ring that reads on every space color, light or dark: a 2pt ring over a full track as heavy, on the icon's own circle and centered on its arrow, in the space's accent where it stands out from the sidebar and its ink where it wouldn't; it eases forward, then fills, fades and shows a check when done.
  Test: DownloadsRingTests.theRingAndItsTrackLieOnTheIconsCircle
  Test: DownloadsRingTests.theProgressReadsOnEverySpaceColor
  Test: DownloadsRingTests.theTrackShowsAndTheProgressStandsApartFromIt
- A download starting → the panel opens on just that one, with Show All Downloads for the rest; it closes six seconds after the file is done unless you're using it.
  No test yet.
- A download finishing in the window you're using → the panel opens again on just that file, marked Just downloaded, with any still coming in and Show All Downloads for the rest; it closes six seconds later unless you're using it. Over the command bar or another panel it doesn't open.
  Test: DownloadsPanelListTests.aFinishedDownloadIsShownAloneWithTheRestBehindShowAll
- The panel's width → wide enough for every label, at the narrowest sidebar, in English and Chinese.
  Test: DownloadsPanelLayoutTests.everyLabelFitsAtTheNarrowestSidebar
- A download that stops arriving → the ring and the row keep the progress it last reached, not the figure from before it stopped, because the throttle that keeps the panel to four updates a second sends the last sample it held when that second ends.
  Test: ProgressThrottleTests.theLastSampleOfAStallIsTheOneThatArrives
  Test: ProgressThrottleTests.aReportAfterTheWindowSendsAtOnceAndDropsTheFoldedOne
- A download completing → the whole ring at once, even inside that second.
  Test: ProgressThrottleTests.theFinishIsNeverHeldBack
- A row → the file's icon, name and progress or size; Pause and Cancel while coming in, Show in Finder when done, Try Again when a failed one can be, Download Again when the file was moved or deleted.
  No test yet.

## Download rules
- Rules in Settings › Downloads → the first one that matches, top to bottom, takes the download.
  Test: DownloadRuleTests.firstMatchWinsTopToBottom
- Each rule in Settings › Downloads → a box headed by its name, switch, Change and Delete, its saved answers inside; dragging the box changes the order, and a rule with no answers is a box with no chevron.
  Test: SettingsLazyBuildTests.eachDownloadRuleIsABoxWithItsAnswersInside
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
- A handoff rule by file type → sends every download whose own name ends in one of its extensions, whatever its address says; links have no name, so they never match.
  Test: DownloadRuleTests.aFileTypeHandoffMatchesTheDownloadsNameAndNeverALink
- A rule's Hand off set to File → Zigzag saves the download in Downloads first, then hands the saved file to the action; a link still hands off its address.
  Test: DownloadRuleTests.onlyDownloadsHandOffASavedFile
- A File handoff's templates → `{file}` is the saved file's path and `{file_url}` its file URL, while `{link}` stays the address.
  Test: DownloadRuleTests.fileTokensAreTheSavedFileAndNothingWithoutOne
- `{file_raw}` → the saved file's own bytes, base64, for a service that loads the metafile itself; an XML-RPC body sends it as `<base64>` and a JSON-RPC body as base64 text.
  Test: DownloadRuleTests.aFileTokenIsBytesInABody
  Test: DownloadRuleTests.anxmlrpcBodyCarriesTheFileAsBase64
  Test: DownloadRuleTests.aJsonBodyCarriesTheBytesAsBase64Text
- `{file_raw}` with no saved file → the handoff fails and says why, rather than sending an empty value the service refuses obscurely.
  Test: DownloadRuleTests.aRuleThatSendsBytesSaysSoWhenThereAreNone
- `{file_raw}` on a file past 16 MB → refused by size without reading it, since a rule may catch something far bigger than a metafile.
  Test: DownloadRuleTests.aFileTooLargeToSendIsRefusedRatherThanRead
- `{file_raw}` anywhere but a JSON-RPC or XML-RPC rule's parameters → empty, so a script, an Open URL template or a folder never reads the file.
  Test: DownloadRuleTests.onlyAServicesParametersReadTheFile
  Test: DownloadRuleTests.aFileTokenInsideTextStillSaysWhenThereIsNoFile
- A JSON-RPC or XML-RPC rule's username and password → kept in the Keychain with the address they were entered for and sent as `Authorization: Basic`; an address with `user:pass@` has them moved there.
  Test: DownloadRuleTests.endpointCredentialsKeepAnyPasswordAndOnlyTheirAddress
  Test: DownloadRuleTests.anEndpointHandsItsCredentialsOver
- Send to rTorrent → catches `.torrent` files and hands over the metafile itself with `load.raw_start`, so a tracker's cookie-based passkey works.
  Test: DownloadRuleTests.theRTorrentPresetSendsTheMetafileItself
- A rule saved before Hand off existed → keeps handing off its URL.
  Test: DownloadRuleTests.aFileHandoffIsOptInAndOlderRulesKeepTheURL
- A File handoff whose download fails or is cancelled → nothing is handed off. A download you cancel or remove says nothing; only a failure says the download didn't finish.
  Test: DownloadRuleTests.aCancelledFileHandoffSaysNothing
- A site that refuses the download after Hand Off → its File handoff is dropped at once.
  Test: DownloadRuleTests.aRefusedDownloadDropsItsFileHandoff
- Open for apps, scripts, installers, archives and web pages → never opens them; they're only saved.
  Test: DownloadRuleTests.anOpenNeverTakesAnAppScriptOrArchive

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
