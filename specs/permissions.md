# Site permissions

## Questions
- A site asks for notifications, the camera, the microphone, your location, your screen or to open an app → a card at the top of its page, Don't Allow first and the main yes last.
  Test: PermissionPromptTests.denyComesFirstAndTheProminentYesLast
- Camera and microphone → two questions, one answer each; a call that wants both gets them only if both are allowed.
  Test: SiteControlsPermissionTests.aRequestForBothTakesTwoAnswers
- Screen sharing → Don't Allow, Share Screen… or Share Window…, then macOS's own picker.
  Test: SitePermissionsPolicyTests.screenSharingOffersThreeActionsAndKeepsThem
- A link to an app (zoommtg:) → Cancel or Open, with "Always allow <site> to open <app>".
  Test: PermissionPromptTests.theAppQuestionPutsCancelFirstAndOpenLast
- A pop-up the page opens without a click → asks where: this tab, a new tab or Zigzag Mini, or not at all; a clicked one opens at once.
  Test: SitePermissionsPolicyTests.everyPopupActionIsADistinctStandingAnswer
- A download → no question by default; with asking turned on in Settings, a site's first download asks.
  Test: SitePermissionsPolicyTests.askingBeforeADownloadIsOffByDefault

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
- Back to Default, or × in Settings › Privacy › Sites → the site gets Zigzag's own again.
  Test: SiteUserAgentsTests.removalRestoresTheDefault
- A choice → kept across launches and listed in Settings › Privacy › Sites.
  Test: SiteUserAgentsTests.choicesReadBack
- Custom… → the typed agent is trimmed to one line; an empty one, or one with characters a header can't carry, can't be used.
  Test: SiteUserAgentsTests.aTypedAgentIsTrimmedAndNeverEmpty
- Chrome and Firefox → named at a current version, one more every four weeks.
  Test: SiteUserAgentsTests.browserVersionsMoveOn
- Site Controls in a private window → no User agent row; its pages follow a choice kept for the site.
  Test: SiteUserAgentsTests.privateWindowsFollowKeptChoicesWithoutTheRow
- addons.mozilla.org → still asked for as Firefox, whatever is chosen.
  Test: SiteUserAgentsTests.theAddonsStoreIsStillAskedForAsFirefox
