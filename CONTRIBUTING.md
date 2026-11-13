# Contributing to Zigzag

Thanks for helping. Bug reports, fixes and ideas are all welcome. For anything bigger than a small fix, please
open an issue first so we can agree on the shape of it before you spend time on code.

## Build and run

You need macOS 15.4 or later, Xcode 26 or later and XcodeGen. Before the first build, set your own
`DEVELOPMENT_TEAM` and Debug `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml`, as the README's "Build from source"
says.

```sh
brew install xcodegen
xcodegen generate
open Zigzag.xcodeproj
```

Run the **Zigzag** scheme. Debug builds are a separate app, "Zigzag Dev", with their own bundle ID, settings,
data and saved logins, so they never touch the Zigzag you use every day.

`project.yml` is the source of truth. `Zigzag.xcodeproj` is generated from it: run `xcodegen generate` after
cloning and after adding, removing or renaming files, and change build settings in `project.yml`, not in Xcode.

## Tests

```sh
xcodebuild test -project Zigzag.xcodeproj -scheme Zigzag
```

Logic you add or change needs tests in `ZigzagTests`, especially importing, passwords, extensions and anything
that parses data from outside. Test fixtures must be made up: never commit real logins, browsing data or
profiles.

A few `CRXPackageTests` use a real Chrome Web Store package, `ZigzagTests/Fixtures/custom-progress-bar.crx`, that
isn't in the repository (see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)). Without it they're skipped and
everything else runs.

## Code style

- **Match the surrounding code.** Read the file you're changing and follow its naming, structure and comments.
  Comments say why, in plain sentences.
- **Zigzag's own drawn controls.** New UI uses the controls in `Zigzag/Design` (`Controls.swift`,
  `ConfirmSheet.swift` and friends) and the values in `Tokens.swift` for spacing, type, color and motion, not
  stock AppKit buttons, alerts or sheets.
- **Light and dark.** Every screen must look right in both. Use the dynamic colors in `Tokens.Color`.
- **US English** in code, comments and everything people read in the app ("color", "favorite").
- Keep debug-only code inside `#if DEBUG`, so it never ships in a release build.
- Privacy first: nothing a person browses, types or saves leaves their Mac unless they ask for it.

## Localization

Zigzag speaks English and Simplified Chinese. Every word people read goes through
`String(localized: "…", comment: "…")`, with a comment that says where it appears. After adding or changing
strings, build, bring the catalog in step and add the Chinese in `Zigzag/Resources/Localizable.xcstrings`:

```sh
xcodebuild -project Zigzag.xcodeproj -scheme Zigzag -derivedDataPath build/dev build
scripts/sync-strings.sh build/dev
```

`LocalizationTests` fails while any string has no Chinese. [docs/i18n/glossary.md](docs/i18n/glossary.md) has
the words to use and the typography rules. If you can't write the Chinese, say so in the pull request.

Release notes are localized too. Each release adds its section to [CHANGELOG.md](CHANGELOG.md) and the same
section in Chinese to [CHANGELOG.zh-Hans.md](CHANGELOG.zh-Hans.md), with the same version heading and date,
`### 新功能` and `### 修复` for New and Fixed, and the issue links and credited names left as they are. What's New
and the update window show the Chinese notes when Zigzag is in Chinese, and the English ones for a version that
has none; `scripts/release.sh` warns when the version it releases has no Chinese section.

## Commits and pull requests

- [Conventional Commits](https://www.conventionalcommits.org) without a scope: `feat: …`, `fix: …`, `docs: …`,
  `chore: …`. Subjects are short and plain, and say what changed for the person using Zigzag.
- Add `(#N)` to the subject when the commit is for an issue, as in `fix: scripts check the page again once it has loaded (#26)`.
- **Small commits**, one logical change each, and one change per pull request.
- Write `Fixes #N` in the pull request so the issue closes with it.
- Make sure the app builds and the tests pass, and say in the pull request how you checked your change. For UI,
  add screenshots in light and dark.

## License of contributions

Zigzag's code is licensed under the Apache License, Version 2.0; see [LICENSE](LICENSE). By contributing, you
agree that your contribution is licensed under the same terms, as described in section 5 of the license, and that
you have the right to contribute it. The Zigzag name, icon and logo stay outside the license; see
[TRADEMARKS.md](TRADEMARKS.md).
