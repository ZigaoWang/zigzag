# Translation

## The offer
- A page in one of the languages in System Settings › Language & Region, or the one Settings › Translation translates into → no offer, unless that language is set to Always Translate.
  Test: PageTranslatorTests.aPageInAnyOfYourLanguagesIsntForeign
- An English page marked `lang="en-IN"`, or with no `lang` → read as English.
  Test: PageTranslatorTests.anEnglishPageMarkedEnINIsEnglish
- An English page marked with another language (`hi`, `IN`) → still English; `lang` only counts when the text agrees.
  Test: PageTranslatorTests.aWrongLangOnAnEnglishPageIsNotBelieved
- An English page with a few words in Hindi or Chinese → English.
  Test: PageTranslatorTests.anEnglishPageWithAFewHindiAndChineseWordsIsEnglish
- A Chinese site whose posts are in English → English.
  Test: PageTranslatorTests.aChinesePageOfEnglishPostsIsEnglish
- A list of language names in their own scripts (हिंदी, मराठी, বাংলা and more) → never read as one of them.
  Test: PageTranslatorTests.aLanguagePickerOnAShortEnglishPageIsNotHindi

## A page that changes
- Text added or changed while a page shows translated (more of a feed, comments opened) → translated too, only what's new; code, fields, what you're editing and `translate="no"` stay as they are, and Zigzag's own translations never come back to be translated again.
  Test: PageTranslatorTests.textAddedOrChangedWhileTranslatedIsTranslatedToo
- Another route of the same page (pushState) → still translated, and its text is translated as it arrives. Show Original puts back all of it, including what was translated later, and stops following the page.
  Test: PageTranslatorTests.aNewRouteIsTranslatedAndShowOriginalPutsAllOfItBack
  Test: PageTranslatorTests.aTranslatedPageStaysTranslatedOnARouteOfItsOwn
- A long page → translated all the way down, a round at a time, what's on and near the screen first.
  Test: PageTranslatorTests.aLongPageIsTranslatedAllTheWayDownWhatsOnScreenFirst
