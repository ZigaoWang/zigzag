## What

<!-- What this changes for the person using Zigzag. One change per pull request. -->

## Why

<!-- The reason, and the issue it's for. -->

Fixes #

## Behavior changes

<!-- None, or each way something that already worked now works differently. -->

None.

## How I tested it

<!-- The steps you took in the app, and on which macOS version. -->

## Screenshots

<!-- For UI changes: before and after, in light and dark. Delete this section otherwise. -->

## Checklist

- [ ] The app builds and `TEST_RUNNER_ZIGZAG_TEST_VAULT=memory xcodebuild test -project Zigzag.xcodeproj -scheme Zigzag` passes.
- [ ] Logic I changed has tests in `ZigzagTests`.
- [ ] A changelog line under `[Unreleased]` in `CHANGELOG.md` (English only).
- [ ] `specs/` updated if behavior changed.
- [ ] New or changed strings use `String(localized:comment:)` with a comment that says where they show (English only is fine; translations are filled in before release).
- [ ] UI changes use Zigzag's own controls from `Zigzag/Design`, with screenshots in light and dark.
