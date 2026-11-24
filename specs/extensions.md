# Extensions

## Installing
- A Chrome Web Store listing → its button reads Add to Zigzag, or Remove from Zigzag once it's in, in any language.
  Test: WebStoreButtonTests.theButtonSaysZigzagsOwnWordsByWhichButtonItIs
- Add to Zigzag there → Zigzag downloads it, shows its review sheet and installs it, and the store hears it was added.
  Test: WebStoreButtonTests.addingAnswersAsChromeDoesAndTellsTheStore
- Only the store's own page, in the tab itself → can add or remove; a frame or another site gets no answer.
  Test: WebStoreButtonTests.onlyTheStoresOwnPageIsHeard
- The store in a private window → gets no answer and can't install.
  Test: WebStoreButtonTests.privateWindowsGetNoAnswer
- A Firefox Add-ons listing → Add to Firefox reads Add to Zigzag; themes and other buttons keep their words.
  Test: AddonsStoreButtonTests.theInstallButtonSaysZigzagAndNothingElseChanges
- Click Add to Zigzag there → it counts only as a real click on that store's page, for the store's own file.
  Test: AddonsMozillaPageTests.theClickIsReadFromThePageItWasMadeOn
- The file that click starts → installs only if it's the current file the store names and matches the hash it publishes; another file is a plain download.
  Test: AddonsMozillaPageTests.anAMOPackageMustMatchTheHashTheStorePublishes
- That click → skips the download question and goes straight to the install sheet; a kept download Block for the site still stops it.
  Test: AddonsMozillaPageTests.aCheckedClickAsksOnlyInTheInstallSheet
- Install from File… in Settings › Extensions → takes a .xpi file or a folder with a manifest.json.
  Test: FirefoxInstallTests.installingAnXPIRecordsItsKindGeckoIDAndOpaqueID
- A .xpi that asks for the proxy permission → its sheet and its row in Settings say Firefox's proxy API won't work in Zigzag.
  Test: FirefoxLimitTests.aFirefoxProxyExtensionSaysItsProxyWontWork

## Settings › Extensions
- Each extension → a box headed by its name, version and switch, with Apps on This Mac, Site access and Allow in private windows inside; folded when more than three are installed.
  Test: SettingsFoldingTests.eachExtensionIsABoxWithItsSettingsInside

## Updates
- Extensions from the Chrome Web Store → checked once a day; ones from a .xpi or a folder aren't.
  Test: FirefoxInstallTests.onlyTheStoresOwnPackagesAreAskedForUpdates
- Check for Updates in Settings › Extensions → checks now and says what happened.
  Test: CRXPackageTests.checkForUpdatesSaysWhatHappened
- An update that asks for nothing new → replaces the running version; one that asks for more, or changes the search engine, Zigzag's pages or outside messaging → waits for your approval.
  Test: ExtensionSecurityTests.updatesThatTakeOverMoreWait
- A folder extension whose manifest now asks for more → gets only what you allowed before.
  Test: ExtensionSecurityTests.aFolderThatNowAsksForMoreWaitsForThePerson

## Site Access
- Site Access in Settings › Extensions → On All Sites, On Click or On Specific Sites.
  Test: SettingsSiteAccessTests.theMenuSetsSiteAccess
- On Specific Sites → a list you add sites to and remove them from; choosing it again later starts an empty list.
  Test: SettingsSiteAccessTests.specificSitesAreAddedAndRemoved
- On Click → a click gives that tab the site until it leaves the site or closes; other tabs on the site don't get it.
  Test: SiteAccessContentScriptTests.contentScriptsFollowSiteAccess
- Extensions off for a site in Site Controls → their scripts stay out there at once, no restart, and the extension keeps running elsewhere.
  Test: SiteAccessContentScriptTests.anOffSiteNeedsNoRestart
- An extension asking for a site its site access doesn't cover (`permissions.request`) right after you used it → the more-access sheet asks; Allow grants it, Don't Allow or no recent use answers false.
  Test: ExtensionPermissionRequestTests.sitesOutsideAccessAreAskedAbout
- A site you allowed it → kept under any site access, until the extension removes it or you choose another site access; a site where extensions are off stays off.
  Test: ExtensionPermissionRequestTests.allowedSitesAreGrantedUnderAnySiteAccess

## Private windows
- A new extension → off in private windows until Allow in private windows is on for it in Settings › Extensions.
  Test: PrivateWindowAccessTests.theSwitchIsOffAtFirstAndKeepsItsChoice
- An extension not allowed there → a private tab tells it nothing: no address, no title, no buttons or menu items.
  Test: ExtensionSecurityTests.privateTabsTellExtensionsNothing
- The same extension in another profile → off there until allowed again.
  Test: PrivateWindowAccessTests.anotherProfileAsksAgain

## In the address
- Pin to Address in an extension's menu → its button joins the address; Unpin from Address takes it out.
  Test: SiteExtensionsTests.theMenuPinsAndUnpinsToTheAddress
- A pinned extension's tile in Site Controls → wears a pin mark.
  Test: SiteExtensionsTests.thePinMarkFollowsThePins
- Pinning → up to three; a new pin goes to the left of the others.
  Test: AddressTests.atMostThreeExtensionsArePinned
- A chrome-extension://<id>/… address, typed or given by an extension → opens that extension's page; an extension that isn't installed → "This extension isn't here".
  Test: ChromeExtensionAddressTests.chromesAddressBecomesZigzagsOwn
- A website's link to a chrome-extension:// address → goes nowhere; only Zigzag and the extension's own pages open them.
  Test: ChromeExtensionAddressTests.aWebsiteCantSendATabThere

## Keywords
- Type an extension's keyword and a space → the address bar hands what follows to that extension.
  Test: ExtensionOmniboxTests.onlyTheKeywordAndASpaceEnterIt
- A keyword one of Zigzag's site searches already uses ("yt") → stays the site search's.
  Test: ExtensionOmniboxTests.aSiteSearchKeepsItsKeyword
- An extension whose background is asleep → it's started and hears what was typed meanwhile.
  Test: ExtensionOmniboxTests.anAsleepBackgroundIsWokenAndHearsWhatItMissed

## Saving pages
- An extension with pageCapture saves a tab (`chrome.pageCapture.saveAsMHTML`) → it gets a Blob of MHTML, as in Chrome: the page first, then its stylesheets, pictures and frames, each with the address it came from.
  Test: PageCaptureTests.aRealPageComesOutWithItsStylesheetImageAndFrame
- Scripts, and frames with no address of their own (about:blank, srcdoc) → left out of the file; Chrome's MHTML has no scripts either.
  Test: PageCaptureTests.scriptsAndFramesWithNoAddressStayOut
- The tab → found by what the extension's `tabs.get` and `windows.get` say of it, matched only by the addresses of tabs it may save, so it can't test a guess at another tab's; none, or two windows that read the same → not found.
  Test: PageCaptureTests.theTabIsFoundByWhatTheExtensionWasToldOfIt
- A page on a site the extension can't access or where extensions are off, a file, or one of Zigzag's own pages → refused.
  Test: PageCaptureTests.onlyWebPagesOnSitesItHasAreSaved
- A frame from a site the extension can't access → left out, with everything in it.
  Test: PageCaptureTests.aFrameLeftOutTakesItsPartsWithIt
- Something the page loaded → in the file only if it's a picture, a stylesheet or a font, from whichever site; so a tag or a redirect pointing at a private address brings nothing back.
  Test: PageCaptureTests.onlyPicturesStylesAndFontsGoIn
- A page's title or a part's address or type → can't add a header of its own to the file.
  Test: PageCaptureTests.thePageCannotWriteHeadersOfItsOwn
- A failure with a callback → the callback gets undefined and reads it in runtime.lastError, as in Chrome.
  Test: PageCaptureTests.aFailureIsLastErrorForACallback

## Background
- A page's message to an extension unanswered after 3 seconds → Zigzag starts that extension's background, at most once every 10 seconds.
  Test: ExtensionStormTests.anUnansweredMessageAsksForTheBackgroundOnce
- A message to a tab or frame where no content script listens → fails with "Could not establish connection. Receiving end does not exist.", as in Chrome; one a listener heard and didn't answer → undefined, no error.
  Test: ExtensionScriptTests.aTabMessageNothingHearsFails
- A content script's or page's message that none of the extension's pages listens for → fails the same way.
  Test: ExtensionScriptTests.aRuntimeMessageNothingHearsFails
