# Site permissions

## Questions
- A site asks for notifications, the camera, the microphone, your location, your screen or to open an app → a card at the top of its page, Don't Allow first and the main yes last.
  Test: PermissionPromptTests.denyComesFirstAndTheProminentYesLast
- A site asks to use WebRTC with Protect IP address from WebRTC on → the same card as the rest, Don't Allow and Allow with Remember, and the page reloads into its answer. Allow takes effect on that reload; a page that already has `RTCPeerConnection` can't be handed it back.
  Test: WebRTCChoiceTests.aFreshSiteReadsAsk
  Test: WebRTCChoiceTests.aKeptChoiceReadsBack
- A page calls `Notification.requestPermission()` → it gets a promise of the answer, never an error, even as it loads.
  Test: WebNotificationsTests.askingReturnsAPromise
- Camera and microphone → two questions, one answer each; a call that wants both gets them only if both are allowed.
  Test: SiteControlsPermissionTests.aRequestForBothTakesTwoAnswers
- Screen sharing → Don't Allow, Share Screen… or Share Window…, then macOS's own picker.
  Test: SitePermissionsPolicyTests.screenSharingOffersThreeActionsAndKeepsThem
- A link to an app (zoommtg:) → Cancel or Open, with "Always allow <site> to open <app>".
  Test: PermissionPromptTests.theAppQuestionPutsCancelFirstAndOpenLast
- A pop-up the page opens without a click → asks where: this tab, a new tab or Zigzag Mini, or not at all; a clicked one opens at once.
  Test: SitePermissionsPolicyTests.everyPopupActionIsADistinctStandingAnswer
- The pop-up question's filled answer → one click (or Return) answers with the choice it shows.
  Test: PermissionPromptTests.aClickOnTheMainPartAnswersWithTheShownChoice
- The chevron beside it → opens the other choices without answering; one click on a choice answers with it.
  Test: PermissionPromptTests.aChoiceFromTheMenuAnswersWithIt
- Either part in the question's first half second → takes no click.
  Test: PermissionPromptTests.theFirstHalfSecondTakesNoClickOnEitherPart
- A download → no question by default; with asking turned on in Settings, a site's first download asks.
  Test: SitePermissionsPolicyTests.askingBeforeADownloadIsOffByDefault

## Location
- Allow on a location question → the first time, macOS asks once whether Zigzag may use your location and lists it under Location Services; the page then gets your position.
  Test: PageLocationTests.eachPoolGetsTheSourceOnce
- Location Services off for the whole Mac, or refused for Zigzag → the page gets an error at once, not a wait that never ends.
  Test: PageLocationTests.locationServicesOffForTheMacAnswersWithAnError

## What's kept
- Remember → starts checked for notifications, camera, microphone and location; unchecked for screen, downloads and pop-ups.
  Test: PermissionPromptTests.chromeKeptQuestionsStartWithRememberChecked
- Answer without Remember → it holds for that page until it navigates or reloads; nothing is kept for the site.
  Test: SiteControlsPermissionTests.aQuestionsAnswerHoldsForThePageOnly
- Answer with Remember → Allow or Don't Allow is kept for the site.
  Test: SitePermissionsPolicyTests.alwaysStoresADenyToo
- A site is its scheme, host and port → http and https, or localhost:3000 and :3001, keep their own answers.
  Test: SiteOriginPermissionTests.anAnswerStaysWithItsOrigin
- A frame from another site → asks as itself on that page; the page's Block holds it back, the page's Allow never lets it in.
  Test: SiteControlsPermissionTests.aFrameFromElsewhereOnlyFollowsBlock
- Always allow on an app question → that one app; Don't Allow stays with its app; a Block for the site covers every app.
  Test: SiteControlsPermissionTests.anAnsweredDenyStaysWithItsApp

## Changes while a page is open
- A permission changed in Site Controls → the page that is open gets the change at once, without a reload: a Block ends the camera and microphone, fails a location watch, closes WebRTC's calls and refuses its constructor, and takes notifications away; an Allow hands the right back the same way.
  Test: LivePermissionsTests.whatCanBeCutLive
  Test: LivePermissionsTests.aBlockReachesThePagesOfThatSiteOnly
  Test: LivePermissionsTests.allowingAgainReachesThePageWithoutAReload
- A kept answer changing → leaves the answer kept for the site alone, so the next load is already what you chose, with no question.
  Test: LivePermissionsTests.changingAKeptAnswerSaysWhatChanged
- A permission allowed → one line over the page saying where it can be changed: "Camera allowed. You can change this in Site Controls."
  Test: PermissionToastTests.aRememberedAnswerSaysItCanBeChanged
- Allowed for this page only → the line says so, where it can be changed, and that the page asks again next time.
  Test: PermissionToastTests.aPageOnlyAnswerSaysItCanBeChanged
- A private window → says nothing, since it keeps nothing.
- WebRTC in Site Controls → Ask, Allow or Block, like every other permission, and its choice reaches the open page the same way.
  Test: WebRTCChoiceTests.itsRowOffersAskLikeEveryOtherPermission
  Test: WebRTCChoiceTests.backToAskForgetsTheKeptChoice

## Private windows
- Answer in a private window → nothing is kept for the site, Remember or not.
  Test: SitePermissionsPolicyTests.aPrivateWindowKeepsNothing
- Site Controls in a private window → no note of which sites asked.
  Test: SiteControlsPermissionTests.aPrivateWindowNotesNothing

## Site Controls
- A permission row → shows once the site has asked this session or has an answer kept.
  Test: SiteControlsPermissionTests.noRowUntilTheSiteAsks
- Ask, Allow or Block on a row → Allow and Block are kept for the site; Ask forgets.
  Test: SiteControlsPermissionTests.allowAndBlockAreKeptAndAskForgets
- A kept Allow or Block → wins over an answer given on the page.
  Test: SiteControlsPermissionTests.aKeptChoiceComesBeforeThePagesAnswer
- Reset Permissions → the site asks again for everything, and its rows go.
  Test: SiteControlsPermissionTests.resetReturnsTheSiteToNoRows

## Settings › Privacy › Site Permissions
- Every choice kept for a site → listed there; a change in Site Controls shows in Settings and back.
  Test: SettingsSitePermissionsTests.aChangeInEitherShowsInTheOther
- Forget on a site's row → every choice made for that site goes.
  No test yet.
- Reset All… → after asking, every choice made for single sites goes, permissions and the rest.
  Test: SitePermissionsPolicyTests.forgetAllClearsBothStores
- Each site → a box headed by its name, how many choices it has and Forget, its choices inside; folded when more than three sites are listed, open otherwise.
  Test: SettingsFoldingTests.eachSiteIsABoxHeadedByItsNameAndHowManyChoices
- A box opened or folded → stays that way while Settings stays open, also when a choice in it changes.
  Test: SettingsFoldingTests.aFoldIsKeptWhileSettingsStaysOpen
- Find a setting matching a choice → that site's box opens to the rows that match.
  Test: SettingsFoldingTests.findASettingOpensTheBoxAMatchIsIn
- Eight or more sites → a search beside the heading narrows the list to the sites that match.
  Test: SettingsFoldingTests.manySitesGetASearchOfTheirOwn
- A permission's name or its choice in that search or Find a setting (camera, notifications, block) → every site with a matching choice, each under its own name, its box opened to the rows that match.
  Test: SettingsFoldingTests.aPermissionsNameFindsItsSites
- Zigzag in another language → the names and choices as its rows say them find the sites.
  Test: SettingsFoldingTests.aPermissionsNameFindsItsSitesInItsLanguage
- A box's header → a click, Space, → or ← opens or folds it, ↑ and ↓ move to the box above or below; VoiceOver reads it as a disclosure triangle.
  Test: FoldBoxTests.keysOpenFoldAndMoveBetweenBoxes

## Settings › Privacy › Stored by Websites (Settings › Website Data with more than one profile)
- A site → a box with its cookies and its cache inside, each with Clear… that asks first; the trash still removes everything the site keeps.
  Test: SiteDataListTests.aBoxIsADisclosureTriangleWithItsKindsInside
- Clearing one kind → the site stays listed with what's left, and goes once nothing is.
  Test: SiteDataListTests.clearingOneKindLeavesTheRestListed

## Apps on This Mac
- Out of the box → off; no site can reach programs listening on this Mac.
  Test: LocalReceiversTests.theSiteDoorIsOffUntilItIsTurnedOn
- Turned on in Settings › Privacy → a site still needs its own switch in Site Controls; both must be on.
  Test: LocalReceiversTests.theSiteDoorNeedsBothSwitches
- Turned off again → every site is shut out, whatever it was allowed.
  Test: LocalReceiversTests.theMasterSwitchShutsEverySiteDoor
- A port browsers refuse (25, 587 and the like) → stays blocked, for sites and extensions.
  Test: LocalReceiversTests.aBlockedPortNeverLeaves

## Certificates
- Visit anyway on a public site's certificate warning → trusted until Zigzag quits, a day at most.
  Test: CertificateTrustTests.anExceptionRunsOut
- Visit anyway on a local server (this Mac, a .local name, a home network address) → kept across launches in Settings › Developer, per port, until its certificate changes or you remove it; never from a private window.
  Test: CertificateTrustTests.aLocalServersCertificateIsRemembered

## User agent
- Nothing chosen for a site → its pages get Zigzag's own user agent, as before.
  Test: SiteUserAgentsTests.nothingChosenLeavesZigzagsOwn
- User agent in Site Controls → Default, Safari, Chrome, Firefox, then Custom… to type one.
  Test: SiteUserAgentsTests.theChoicesAreDefaultSafariChromeFirefox
- A choice for a site → its pages are sent that from their first load, in new tabs, Zigzag Mini and installed apps too; the open tab reloads with it.
  Test: SiteUserAgentsTests.aKeptChoiceIsSentFromTheFirstLoad
- A choice for a site → a page's new window or pop-up on it is sent that from its first request.
  Test: SiteUserAgentsTests.aNewWindowStartsWithTheSitesChoice
- A choice for a site → covers its subdomains; a subdomain's own choice wins, Safari included.
  Test: SiteUserAgentsTests.aSiteCoversItsSubdomainsAndTheMostSpecificWins
- Back to Default, or × in Settings › Privacy › Site Permissions → the site gets Zigzag's own again.
  Test: SiteUserAgentsTests.removalRestoresTheDefault
- A choice → kept across launches and listed in Settings › Privacy › Site Permissions.
  Test: SiteUserAgentsTests.choicesReadBack
- Custom… → the typed agent is trimmed to one line; an empty one, or one with characters a header can't carry, can't be used.
  Test: SiteUserAgentsTests.aTypedAgentIsTrimmedAndNeverEmpty
- Chrome and Firefox → named at a current version, one more every four weeks.
  Test: SiteUserAgentsTests.browserVersionsMoveOn
- Site Controls in a private window → no User agent row; its pages follow a choice kept for the site.
  Test: SiteUserAgentsTests.privateWindowsFollowKeptChoicesWithoutTheRow
- addons.mozilla.org → still asked for as Firefox, whatever is chosen.
  Test: SiteUserAgentsTests.theAddonsStoreIsStillAskedForAsFirefox

## Compatibility mode
- Compatibility mode on for a site in Site Controls → extensions, ad blocking, cookie banners, zapped elements and custom style are all off there and on its subdomains; other sites keep theirs.
  Test: SiteCompatibilityTests.onSetsEverythingAsideForThatSiteOnly
- Turned off again → the site's own choices for each come back exactly as they were; none of them changed while it was on.
  Test: SiteCompatibilityTests.offRestoresTheChoicesExactly
- Turned off on a subdomain of a site it's on for → off for that site too, as allowing ads is.
  Test: SiteCompatibilityTests.offOnASubdomainTakesTheCoveringSiteOff
- While it's on → Ad blocking, Cookie banners and Extensions show off and dimmed, saying it's compatibility mode; the zapped and Custom style rows say Off.
  Test: SiteCompatibilityTests.overriddenRowsShowOffAndDimmed
- While it's on → Site Controls by the address is in the accent, and says so in its tooltip and to VoiceOver.
  Test: SiteCompatibilityTests.siteControlsShowsItInTheAccent
- Turning it on or off → the page reloads once.
  No test yet.
- Turned on → kept across launches and listed in Settings › Privacy › Site Permissions, where × and Forget turn it off.
  Test: SiteCompatibilityTests.itIsKeptAndListedInSettings
- A private window → follows it with no row of its own, and keeps nothing new for the site.
  Test: SiteCompatibilityTests.privateWindowsFollowItAndKeepNothing
- Boosts saved before it existed → still load, with it off.
  Test: SiteCompatibilityTests.boostsSavedBeforeCompatibilityStillRead
