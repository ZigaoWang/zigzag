# Contributing to Zigzag

Thanks for helping. Bug reports, fixes and ideas are all welcome. For anything bigger than a small fix, please
open an issue first so we can agree on the shape of it before you spend time on code.

## Build and run

You need Xcode 26 or later and XcodeGen.

```sh
brew install xcodegen
xcodegen generate
open Zigzag.xcodeproj
```

Run the **Zigzag** scheme. Debug builds are a separate app, "Zigzag Dev", with their own bundle ID, settings,
data and saved logins, so they never touch the Zigzag you use every day.

`project.yml` is the source of truth. `Zigzag.xcodeproj` is generated from it: after adding, removing or
renaming files, run `xcodegen generate` again, and change build settings in `project.yml`, not in Xcode.

## Tests

```sh
xcodebuild test -scheme Zigzag
```

Add or update tests in `ZigzagTests` for logic you change, especially importing, passwords and anything that
parses data from outside. Test fixtures must be made up: never commit real logins, browsing data or
profiles.

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

## Commits and pull requests

- [Conventional Commits](https://www.conventionalcommits.org): `feat: …`, `fix: …`, `docs: …`, `chore: …`,
  without a scope.
- **Small commits**, one logical change each, with a message that says what changed for the person using
  Zigzag.
- Make sure the app builds and the tests pass before you open a pull request, and say in it how you checked
  your change (including in light and dark, for UI).

## License of contributions

Zigzag is source available under the Functional Source License (FSL-1.1-MIT); see [LICENSE](LICENSE). By
contributing, you agree that your contribution is licensed under the same terms, including its conversion to
the MIT license two years after the release it ships in, and that you have the right to contribute it.
