# Zigzag

**Feels great. Weighs nothing.**

The lightweight browser for Mac.

![Zigzag](docs/screenshot.png)

Zigzag is a Mac browser with a sidebar, spaces, and a page that floats, built from scratch in Swift and AppKit
on Safari's engine (WebKit). It's light on memory and battery, and engine security updates come straight from
Apple with macOS. There's no account and no servers: nothing is sent to us.

- Spaces, each with its own tabs and color.
- A command bar for tabs, history and search. Type "you", press Tab, and search YouTube right from it.
- Shift-click a link to peek at it; drag a tab onto the page to split it.
- Reader, for just the words.
- Built-in ad and tracker blocking.
- A password manager in your Mac's Keychain, synced only through your own iCloud.
- One-click import from Arc, Chrome, Safari, Dia, Edge, Brave and Firefox: spaces, pinned tabs, bookmarks,
  history and passwords.
- Chrome extensions, installed straight from the Chrome Web Store, for the many that can work outside Chrome.

## Download

[Download Zigzag for Mac](https://zigzagbrowser.com/download). It's free, needs macOS 15.4 or later, and
updates itself.

## Status

Zigzag is in **beta**. The current version is **0.1.2**. It's ready to use every day, but you'll probably find
rough edges. Found a bug, a site that breaks, or something that feels off? Use **Help › Send Feedback…** in the
app, [open an issue](https://github.com/ZigaoWang/zigzag/issues/new/choose), or write to a@zigao.wang.

## Build from source

You need Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
xcodegen generate
open Zigzag.xcodeproj
```

Then run the **Zigzag** scheme. Debug builds are a separate app, "Zigzag Dev", with their own settings and
data, so they never touch the Zigzag you use every day. To sign a build yourself, set your own team in
`project.yml` (`DEVELOPMENT_TEAM`) and generate the project again.

Run the tests with:

```sh
xcodebuild test -scheme Zigzag
```

`project.yml` is the source of truth for the project: after adding or removing files, run `xcodegen generate`
again.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). To report a security issue, see [SECURITY.md](SECURITY.md); please
don't open a public issue for it.

## License

Zigzag is source available under the Functional Source License (FSL-1.1-MIT). Each version becomes MIT licensed two years after its release. Forks and contributions are welcome.

See [LICENSE](LICENSE) for the full terms, and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the work
of others that Zigzag uses, including EasyList and EasyPrivacy by The EasyList authors (CC BY-SA 3.0).

Zigzag isn't affiliated with The Browser Company.
