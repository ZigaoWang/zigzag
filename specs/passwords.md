# Passwords

## The fill menu
- Click a sign-in field, its placeholder or the box around it → Zigzag's menu opens under it; a click elsewhere that the page answers by moving the cursor there doesn't open it.
  Test: PasswordMenuTests.aClickOnAPlaceholderOverTheFieldOpensTheMenu
- A field scrolled away or off the page → no menu, and nothing is filled into it.
  Test: PasswordMenuTests.aFieldOffThePageYouSeeGetsNoMenu
- A sign-in field inside a frame → no menu; only the page's own fields get one.
  No test yet.
- What it offers → logins saved for this exact address, newest used first, then one row for other parts of the site, which lists them once you pick it; Passwords… is always last, alone when nothing is saved.
  Test: SystemPasswordsTests.passwordsComesLastOnEverySignIn
- A new-password field → Use Strong Password first, then your logins; in a private window a note takes its place.
  Test: PasswordMenuTests.aNewPasswordFieldOffersAStrongOneAndYourLogins
- Start scrolling over the page or the menu → it goes at once; the glide of an earlier scroll leaves it.
  Test: SystemPasswordsTests.aScrollHidesTheMenuAsItStarts
- Switch tabs → the menu goes, and the Mac's list with it.
  No test yet.
- Zoom the page, resize the window or pane, or the page moves the field → the menu stays under the field, never over it.
  Test: PasswordMenuTests.theMenuFollowsAFieldThatMoves
- A pinched-in page → the menu opens under the field.
  Test: PasswordMenuTests.aPinchedPageStillPutsTheMenuUnderItsField

## Filling
- Pick a login → the username and password go into the fields you can see, under any placeholder; a field covered by something else stays empty.
  Test: PasswordMenuTests.aPasswordFillsUnderItsPlaceholder
- The page went to another site before the fill → nothing is filled, and a note says the page changed.
  Test: PasswordMenuTests.aPageThatMovedOnSaysSo

## Passwords… (the Mac's list)
- Passwords… → the Mac's own AutoFill list, opened on the field the menu was for.
  Test: SystemPasswordsTests.thePanelIsAskedForOnTheFieldTheMenuWasFor
- What you pick there → fills only the site it was asked for, in the tab in front, and is never offered for saving.
  Test: SystemPasswordsTests.onlyTheSiteItWasAskedForGetsIt
- Scroll the page → the list closes; the glide of an earlier scroll leaves it.
  Test: SystemPasswordsTests.theListClosesWhenThePageScrolls
- Go to another page, or the page changes its address → the list closes.
  Test: SystemPasswordsTests.theListClosesWhenThePageGoesElsewhere
- Move, resize, minimize or close the window → the list closes.
  Test: SystemPasswordsTests.theListClosesWhenTheWindowMovesOrResizes
- macOS 27's key icon → in sign-in fields only while Zigzag fills passwords and no password manager extension is on; a click opens the Mac's list.
  Test: SystemPasswordsTests.theKeyIconIsOnlyZigzagsWhenItFills
- The hidden field Zigzag lays over the page for the list → shows nothing, keeps nothing, and gives its text to no copy, drag, service or screen reader.
  Test: SystemPasswordsTests.thePasswordViewGivesItsTextToNothing

## Saving
- Sign in with a password you typed → once the site takes it, Save password? (or Update password?) at the top of the page; a wrong one, the form back empty, is never offered.
  Test: DialogPasswordFixesTests.failedSignInIsDropped
- A page that fills and sends its own password → nothing is offered.
  Test: PasswordSafetyTests.aPageCantOfferItsOwnPasswordForSaving
- Never → that site isn't asked again.
  Test: PasswordStoreTests.remembersNeverSaveForASite
- A private window → nothing is offered for saving, and a filled login isn't marked as used.
  No test yet.
- Use Strong Password → filled and saved at once as a pending login; the account's old password is replaced only after you say Update.
  Test: StrongPasswordTests.aStrongPasswordAsksBeforeReplacingTheOldOne

## Password managers
- A password manager extension on in a profile → Zigzag stops filling and offering to save there until you choose; passwords brought over from another browser still fill.
  Test: ProfileChoiceTests.zigzagStepsAsideForAPasswordManagerUntilYouChoose
- Choose iCloud Passwords → Zigzag's filling and saving turn off; choosing Zigzag again brings back what was on before.
  Test: ProfileChoiceTests.iCloudPasswordsTurnsZigzagOffAndZigzagComesBackAsItWas
- Password manager in Settings › Passwords → Zigzag, iCloud Passwords, then each password manager extension installed and on, by name; one turned off or removed isn't listed.
  Test: ProfileChoiceTests.passwordManagerExtensionsAreListedAfterICloudByName
- A password manager extension on while Zigzag neither saves nor fills → it shows checked, not Zigzag; with several, the one you chose.
  Test: ProfileChoiceTests.aPasswordManagerShowsCheckedWhileZigzagStepsAside
- Choose a password manager extension → Zigzag's saving and filling turn off; choosing Zigzag again brings them back on.
  Test: ProfileChoiceTests.choosingAPasswordManagerTurnsZigzagOffAndZigzagComesBackOn
- A password manager extension you chose, one Zigzag doesn't know by name → counts as on, while it's on: Zigzag stops filling and offering to save, shows no key icon and leaves passkeys to it.
  Test: ProfileChoiceTests.aChosenExtensionZigzagDoesntKnowCountsAsOn
- An extension that turns the browser's own password saving off, the Chrome way (chrome.privacy) → listed under Password manager and counted as one, in that profile; once it clears that, or is turned off or removed, it isn't.
  Test: ProfileChoiceTests.anExtensionThatTurnsSavingOffIsAPasswordManager
  Test: ProfileChoiceTests.turningOffOrRemovingAnExtensionForgetsWhatItSet
- Extensions that read that setting → as in Chrome: the one that set it controls it, the others see another does.
  Test: ProfileChoiceTests.passwordSavingReadsWhoControlsIt
  Test: ExtensionScriptTests.passwordSavingIsKeptByZigzag
  Test: ExtensionScriptTests.theBridgeSendsPasswordSavingToZigzag
- 1Password waiting on its app → "1Password is waiting for you" only after you used it or a field just before; a background connect never shows it.
  Test: CompanionAppNoticeTests.aBackgroundConnectWithNoUseNeverShowsIt

## Passkeys
- A site asks for a passkey while its page is waiting on one → the waiting request ends first, so the new one goes through.
  Test: PasskeyRequestsTests.aSecondRequestEndsTheWaitingOneFirst
- Click a field the site marks for passkeys (autocomplete "webauthn") while its page waits for one → the fill menu lists the passkeys saved on this Mac for that site, by name, before your logins; with Fill saved passwords off, the passkeys alone.
  Test: PasskeySuggestionsTests.passkeysComeFirstThenLoginsThenPasswords
- Which passkeys → only those for the page's own site or the parent domain it names, and only those the request allows; never another site's or a public suffix's, never in a frame, a new-password field, a page not served securely, or AI apps' profile.
  Test: PasskeyRequestsTests.aPageCantListAnotherSitesPasskeys
  Test: PasskeySuggestionsTests.whichSitesAPageMayAskFor
  Test: PasskeySuggestionsTests.whereTheMenuMayListPasskeys
- Pick a passkey → the page's waiting request asks the Mac for that one; the Mac's sheet asks for Touch ID and the site gets the sign-in it waited for. Closed without signing in, the page waits again.
  Test: PasskeyRequestsTests.aPickedPasskeyAnswersTheWaitingRequest
  Test: PasskeyRequestsTests.aCancelledSheetWaitsAgain
- Before macOS has been asked → the menu shows Use a Saved Passkey; picking it, or Allow… beside Passkeys in Settings › Passwords, shows macOS's prompt, and Zigzag is then listed in System Settings › Privacy & Security › Access web browser passkeys. Nothing asks by itself, at launch or on a page.
  Test: PasskeySuggestionsTests.notAskedOffersToAskAndAsksNothing
  Test: PasskeySuggestionsTests.eachAnswerIsKept
- Allowed → the menu comes back on the field with the site's passkeys; Settings › Passwords says so, with Open System Settings to change it.
  No test yet.
- Denied → no passkeys are listed and nothing is asked again; a site that asks for a passkey still gets the Mac's own sheet, as before.
  Test: PasskeySuggestionsTests.deniedListsNothing
- A password manager extension that brings its own passkeys on in the profile → Zigzag lists none there; iCloud Passwords doesn't count.
  Test: PasskeySuggestionsTests.whereTheMenuMayListPasskeys

## Site sign-in sheet
- A site asks for a name and password (HTTP sign-in) → a sheet on its tab; only the page's own site can ask, other sites' images and frames get nothing.
  Test: PasswordSafetyTests.savedSignInsAnswerOnlyTheirOwnSite
- One login saved for that exact address → comes filled in; several, or one from another part of the site, wait behind Saved Passwords.
  Test: PasswordSafetyTests.signInSheetFillsInOnlyThisAddresssLogin
- An extension that answers sign-ins (1Password) → its name and password sign in, before the sheet or while it's up.
  Test: SiteSignInTests.aLateNameAndPasswordFillsTheSheet
