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

## Keywords
- Type an extension's keyword and a space → the address bar hands what follows to that extension.
  Test: ExtensionOmniboxTests.onlyTheKeywordAndASpaceEnterIt
- A keyword one of Zigzag's site searches already uses ("yt") → stays the site search's.
  Test: ExtensionOmniboxTests.aSiteSearchKeepsItsKeyword
- An extension whose background is asleep → it's started and hears what was typed meanwhile.
  Test: ExtensionOmniboxTests.anAsleepBackgroundIsWokenAndHearsWhatItMissed

## Background
- A page's message to an extension unanswered after 3 seconds → Zigzag starts that extension's background, at most once every 10 seconds.
  Test: ExtensionStormTests.anUnansweredMessageAsksForTheBackgroundOnce
- A message to a tab or frame where no content script listens → fails with "Could not establish connection. Receiving end does not exist.", as in Chrome; one a listener heard and didn't answer → undefined, no error.
  Test: ExtensionScriptTests.aTabMessageNothingHearsFails
- A content script's or page's message that none of the extension's pages listens for → fails the same way.
  Test: ExtensionScriptTests.aRuntimeMessageNothingHearsFails
