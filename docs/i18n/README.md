# Localizing Zigzag

Zigzag ships in English, Simplified Chinese (zh-Hans), Traditional Chinese (zh-Hant), Japanese (ja), Korean (ko),
German (de), French (fr), Italian (it), Spanish (es), Brazilian Portuguese (pt-BR), Russian (ru), Dutch (nl), Polish (pl)
and Turkish (tr). Every word people read is in
`Zigzag/Resources/Localizable.xcstrings`, and macOS's permission prompts are in `InfoPlist.xcstrings`.

## Adding a string

Write it with `String(localized:comment:)`. The comment says where the words appear and what any placeholder holds,
so a translator who never sees the screen can still get it right:

```swift
String(localized: "Close \(count) Tabs", comment: "Item in a tab's menu in the sidebar. The number is how many tabs are selected.")
```

Then build, bring the catalog in step, and add the Chinese:

```sh
xcodebuild -project Zigzag.xcodeproj -scheme Zigzag -derivedDataPath build/dev build
scripts/sync-strings.sh build/dev
```

`LocalizationTests` fails on a control, menu item, tooltip, accessibility label, alert or row set from a bare
literal. A literal that's meant (a brand, text that is only measured) goes in `ZigzagTests/LocalizationAllowlist.txt`
with a line saying why.

## One sentence per string

Each string is a whole sentence or label, with placeholders for what changes. Never build one from pieces: word order
and punctuation differ by language.

- `String(localized: "As a download: \(rule)")`, not `"\(String(localized: "As a download")): \(rule)"`.
- Two sentences in a row join with `Words.sentences(first, second)`, which leaves out the space after a full-width stop.
- Don't put one localized string inside another. Give each case its own string.

`LocalizationTests.noSentencesBuiltFromFragments` checks this.

## Plurals

Interpolate the number and let the catalog hold the forms (`one`, `other`, and whatever else the language needs).
Don't write a ternary for one and many in code:

```swift
String(localized: "\(count) tabs", comment: "…")   // the catalog's English has "%lld tab" for one
```

## Dates, times and numbers

Format them with Foundation, never by hand: `Date.formatted(…)`, `RelativeDateTimeFormatter`, `ByteCountFormatter`,
`count.formatted()`, `ListFormatter` for "a, b and c". Pass `Words.locale` so they follow the language Zigzag is
shown in. A formatted value goes into a string as a placeholder.

## The pseudo-locale

A debug build can show every string accented, bracketed and about 40% longer, so text that a longer language would
cut off, and text that skipped the catalog, both show up:

```sh
build/dev/Build/Products/Debug/Zigzag.app/Contents/MacOS/Zigzag -ZigzagPseudoLocalize YES
```

"Settings" reads "[Šéţţîñĝš ~~~~]". Words in plain English are hard-coded. `PseudoLocalizedLayoutTests` lays out the
sidebar, the top bar, the command bar, the site panel, every Settings pane, the main sheets and the menus this way and
fails on text cut off where it isn't meant to be. `scripts/test.sh` runs it in a test process of its own with
`ZIGZAG_PSEUDO_LOCALIZE=1`. The argument and the variable do nothing in a release build.

The same test lays the surfaces out in a real language, checking every word, and can save each one as a picture.
German and Russian are the longest:

```sh
TEST_RUNNER_ZIGZAG_TEST_LANGUAGE=de TEST_RUNNER_ZIGZAG_LAYOUT_SHOTS=/tmp/shots scripts/test.sh --only PseudoLocalizedLayoutTests
```

When something is cut off, fix the layout so it works for any language: let the row grow, wrap the text, or use the
control's own width. Text that is meant to fade or end in "…" (tab titles, addresses, a menu's choice that shows whole
in its tooltip) is left as it is.

## The glossary

Each language has a glossary in this folder: [Simplified Chinese](glossary.md),
[Traditional Chinese](glossary.zh-Hant.md), [Japanese](glossary.ja.md), [Korean](glossary.ko.md),
[German](glossary.de.md), [French](glossary.fr.md), [Italian](glossary.it.md), [Spanish](glossary.es.md),
[Brazilian Portuguese](glossary.pt-BR.md), [Russian](glossary.ru.md), [Dutch](glossary.nl.md),
[Polish](glossary.pl.md), [Turkish](glossary.tr.md). It lists Zigzag's words with the one translation each gets, the words
that were considered and not used, and the language's typography rules. Translate from it, and add a word to it
before using a new one.

## Adding a language

1. Write `docs/i18n/glossary.<lang>.md` first, from Apple's own words for that language in macOS and Safari.
2. Translate. Each translator writes `translations/<lang>.json`, never the catalogs:

   ```json
   {"language": "ko",
    "Localizable": {"New Tab": {"stringUnit": {"state": "translated", "value": "새 탭"}}, "…": {}},
    "InfoPlist": {"NSCameraUsageDescription": {"stringUnit": {"state": "translated", "value": "…"}}}}
   ```

   Each value has the same shape as the zh-Hans entry for that key: a `stringUnit`, `variations.plural`, or
   `substitutions`. Then fold the file in:

   ```sh
   scripts/merge-translations.py --check translations/ko.json   # report only
   scripts/merge-translations.py translations/ko.json
   ```

   It refuses a file with unknown or missing keys, a form that isn't `translated`, or format arguments that differ
   from the English, and says which. `--allow-missing` merges a partial file. Commit the file with the catalogs: it
   stays the record of that language, so a later fix goes into it and is merged again.
3. Have someone who didn't translate it review it against the glossary, in the app.
4. Run the pseudo-locale and the layout tests, then run the app in the language and take screenshots of the main
   surfaces. Fix anything cut off in the layout, not by shortening one translation.
5. Add `docs/readme/README.<lang>.md`, translated from `README.md`, and add it to the language line at the top of every README.
6. Add the language's own name to `AppLanguage.ownName` (Settings › General › Language), and its code to
   `knownRegions` in `Zigzag.xcodeproj/project.pbxproj`, `CFBundleLocalizations` in `project.yml` and
   `Zigzag/Info.plist`, and `LocalizationTests.translated`. The code is the one Xcode and Bundle use (`pt-BR`, not
   `pt_BR`). `LocalizationTests.everyLanguageKeepsNamesSymbolsAndPlurals` then checks it keeps product names,
   keyboard symbols and addresses, ends "…" items in "…", and has CLDR's plural forms.

## The release gate

`scripts/release.sh`, stable and beta, stops before building when any shipped language has a string that is missing,
empty, not `translated` (`new`, `needs_review`) or has the wrong format arguments, in either catalog. A shipped
language is one in `knownRegions` or with any string in a catalog. To see what's left:

```sh
scripts/check-strings.py          # every shipped language
scripts/check-strings.py ja       # one language, shipped or not
```
