# Zapping

## Zapped elements
- Zap an element → it stays hidden on that site on every visit; zapping it again keeps it once.
  Test: SiteBoostsTests.zapsAreKeptForTheSite
- Zap an element → it's named by what it says about itself: its aria-label, title or alt, else its heading or first line of text.
  Test: SiteBoostsTests.zapsAreNamedByWhatTheElementSays
- A zap from before names were kept → named from its selector, like #list › li.
  Test: SiteBoostsTests.zapsKeptBeforeNamesStillRead
- The “3 zapped” row in Site Controls → lists each zapped element, newest first, with its name, its selector under it and ×.
  Test: SiteBoostsTests.aZapRowShowsItsNameAndSelector
- × on one zapped element → only that one shows again on the open page, without a reload; the rest stay hidden.
  Test: SiteBoostsTests.removingAZapShowsItOnTheOpenPage
- × on one zapped element → it stays shown on later visits; the others keep their order.
  Test: SiteBoostsTests.oneZapComesOffAndTheRestStayInOrder
- Settings › Privacy › Sites → lists the same zapped elements, each with its own ×.
  Test: SiteBoostsTests.settingsListsEachZapWithItsOwnRemove
- In a private window → zaps and their removal stay in that window.
  Test: SiteBoostsTests.aPrivateWindowKeepsItsOwnCopy
