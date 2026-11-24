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
