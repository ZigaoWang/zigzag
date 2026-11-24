# Contributing to Zigzag

Thanks for helping. Bug reports, fixes and ideas are all welcome. For anything bigger than a small fix, and for
any change to how something already works, please open an issue or comment on the existing one first, so we can
agree on the shape of it before you spend time on code.

Security problems don't go in issues or pull requests: see [SECURITY.md](SECURITY.md) for how to report them
privately.

## Build and run

You need macOS 15.4 or later, Xcode 27 or later and XcodeGen. Before the first build, set your own
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
TEST_RUNNER_ZIGZAG_TEST_VAULT=memory xcodebuild test -project Zigzag.xcodeproj -scheme Zigzag
```

`scripts/test.sh` runs the same tests split across six test processes, in about a minute; `--only Suite` runs one suite.

The tests run inside a Debug build of Zigzag. `ZIGZAG_TEST_VAULT=memory`, which xcodebuild passes on through its
`TEST_RUNNER_` prefix, gives that build a password vault held in memory for the run, so it never reads, writes or
asks for passwords in your keychain. It works the same when you launch a Debug build by hand.

Logic you add or change needs tests in `ZigzagTests`, especially importing, passwords, extensions and anything
that parses data from outside. Test fixtures must be made up: never commit real logins, browsing data or
profiles.

Two fixtures aren't in the repository, and `.gitignore` keeps them out: `ZigzagTests/Fixtures/custom-progress-bar.crx`,
a real Chrome Web Store package that a few `CRXPackageTests` use (see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)),
and `ZigzagTests/Fixtures/ublock-scriptlets.json`, uBlock Origin's scriptlets for one `AdFiltersTests` test. Without
them those tests are skipped and everything else runs. Don't commit them.

## Code style

- **Match the surrounding code.** Read the file you're changing and follow its naming, structure and comments.
  A code comment is one short, factual line, and only where the code doesn't say it already.
- **Zigzag's own drawn controls.** New UI uses the controls in `Zigzag/Design` (`Controls.swift`,
  `ConfirmSheet.swift` and friends) and the values in `Tokens.swift` for spacing, type, color and motion, not
  stock AppKit buttons, alerts or sheets.
- **Light and dark.** Every screen must look right in both. Use the dynamic colors in `Tokens.Color`.
- **US English** in code, comments and everything people read in the app ("color", "favorite").
- Keep debug-only code inside `#if DEBUG`, so it never ships in a release build.
- Privacy first: nothing a person browses, types or saves leaves their Mac unless they ask for it.

## Behavior

Most people come to Zigzag from Chrome or Arc, so their behavior is the default: a shortcut, a menu order or what
happens when a tab closes should work the way those users expect, unless an issue agreed otherwise.

[specs/](specs/) lists how Zigzag behaves today, one line per behavior, each naming the test that checks it.

- A change to existing behavior is stated plainly in the changelog line (what it did before, what it does now), and
  the matching line in `specs/` is updated in the same pull request.
- A bug fix that brings back behavior `specs/` already describes doesn't touch `specs/`.
- Don't remove an option, a look or a shortcut people may have chosen. If something has to change, keep the old way
  as a choice, and ask in the issue first.
- Settled, so please open an issue before reopening: Pin and Favorites keep their names (#354), and Zigzag has no
  built-in AI assistant, only the optional, off-by-default MCP server for AI apps (#99).

## Localization

Zigzag speaks English, Simplified Chinese, and Traditional Chinese. Every word people read goes through
`String(localized: "…", comment: "…")`, with a comment that says where it appears. After adding or changing
strings, build, bring the catalog in step and add Simplified Chinese in `Zigzag/Resources/Localizable.xcstrings`:

```sh
xcodebuild -project Zigzag.xcodeproj -scheme Zigzag -derivedDataPath build/dev build
scripts/sync-strings.sh build/dev
```

`LocalizationTests` requires Simplified Chinese and checks the formatting of both translations where present.
Traditional Chinese is welcome but optional: leave untranslated entries out so they use the English source.
See the [Simplified Chinese](docs/i18n/glossary.md) and [Traditional Chinese](docs/i18n/glossary.zh-Hant.md)
glossaries for wording and typography. If you can't write the Simplified Chinese, say so in the pull request.

Add each release's section to [CHANGELOG.md](CHANGELOG.md) and [CHANGELOG.zh-Hans.md](CHANGELOG.zh-Hans.md).
[CHANGELOG.zh-Hant.md](CHANGELOG.zh-Hant.md) can follow later. Keep the same version, date, order, issue links
and credited names. Use `### 新功能` for New, `### 修复` for Fixed in Simplified Chinese, and `### 修正` in Traditional Chinese.
`WhatsNewTests` compares shipped Simplified Chinese notes with English and skips Unreleased. If the Traditional
Chinese notes for a version are incomplete or missing, the in-app What's New sheet shows its English notes.
Sparkle's pre-install notes still use Simplified Chinese for its single Chinese release-notes link.

## Commits and pull requests

- [Conventional Commits](https://www.conventionalcommits.org) without a scope: `feat: …`, `fix: …`, `docs: …`,
  `test: …`, `chore: …`. Subjects are short and plain, and say what changed for the person using Zigzag. `style:`
  is for code formatting only, never for how something looks.
- Add `(#N)` to the subject when the commit is for an issue, as in `fix: scripts check the page again once it has loaded (#26)`.
- **Small commits**, one logical change each.
- **Small, focused pull requests**: one feature or fix each, so it can be reviewed and tried in the app. A pull
  request that changes a lot at once, or moves code around while changing it, is hard to review and slow to land;
  split it up, and talk big changes through in an issue before you start.
- Don't add CI workflows or other files under `.github/workflows`.
- Write `Fixes #N` in the pull request so the issue closes with it.
- Every change people will notice gets a line under `## [Unreleased]`, in `### New` or `### Fixed`, in
  [CHANGELOG.md](CHANGELOG.md) and under the matching heading in [CHANGELOG.zh-Hans.md](CHANGELOG.zh-Hans.md).
  Add a Traditional Chinese line if you can. Write the Chinese as a person would say it, not word for word.
  End the line with the issue link, and separate several with ", ": `([#311](…), [#312](…))`.
- Make sure the app builds and the tests pass, and say in the pull request how you checked your change. For UI,
  add before and after screenshots in light and dark.
- Draft pull requests aren't reviewed for merge. Mark yours ready when it is.
- Before merging, a maintainer may push small fixes on top of your branch, such as wording, a missing Chinese string
  or a test, and say so when merging.

## License of contributions

Zigzag's code is licensed under the Apache License, Version 2.0; see [LICENSE](LICENSE). By contributing, you
agree that your contribution is licensed under the same terms, as described in section 5 of the license, and that
you have the right to contribute it. The Zigzag name, icon and logo stay outside the license; see
[TRADEMARKS.md](TRADEMARKS.md).
