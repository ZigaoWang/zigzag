<p align="center">
  <img src="Zigzag/Resources/Assets.xcassets/AppIcon.appiconset/icon_256.png" width="88" alt="">
</p>

<h1 align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/wordmark-dark.svg">
    <img src="docs/wordmark-light.svg" width="280" alt="Zigzag">
  </picture>
</h1>

<p align="center">
  <b>Feels great. Weighs nothing.</b><br>
  The lightweight browser for Mac.
</p>

<p align="center">
  <a href="https://zigzagbrowser.com/download"><b>Download for Mac</b></a> ·
  <a href="https://zigzagbrowser.com">Website</a> ·
  <a href="https://github.com/ZigaoWang/zigzag/issues/new/choose">Report a bug</a> ·
  <a href="LICENSE">License</a>
</p>

<p align="center">
  Free · macOS 15.4 or later · Version 0.1.3 beta
</p>

![Zigzag](docs/screenshot.png)

## What it is

Zigzag is a Mac browser with a sidebar, spaces, and a page that floats. It's built from scratch in Swift on
Safari's engine, so it's light on memory and battery, and security updates for the engine come from Apple with
macOS. There's no account and no servers.

- **Spaces:** each with its own tabs and color.
- **Command bar:** find tabs, history and sites. Type "you", press Tab, and search YouTube right there.
- **Peek:** shift-click a link to read it over the page.
- **Split View:** drag a tab onto the page to open it beside.
- **Reader:** just the words and pictures.
- **Ad blocking:** built in.
- **Passwords:** kept in your Mac's Keychain, imported from any browser.
- **Import:** one click from Arc, Chrome, Safari, Dia, Edge, Brave or Firefox.
- **Chrome extensions:** most popular ones, straight from the Chrome Web Store.

## Status

Zigzag is in **beta**. It works well for everyday browsing, and updates install themselves.

Found a bug, a site that breaks, or something that feels off? Choose **Help › Send Feedback…** in the app,
[open an issue](https://github.com/ZigaoWang/zigzag/issues/new/choose), or email a@zigao.wang.

## Build from source

You need Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
git clone https://github.com/ZigaoWang/zigzag.git
cd zigzag
xcodegen generate
open Zigzag.xcodeproj
```

Run the **Zigzag** scheme. Debug builds run as a separate app, "Zigzag Dev", with their own data, so they never
touch the Zigzag you use. To sign builds yourself, set your team in `project.yml` (`DEVELOPMENT_TEAM`) and run
`xcodegen generate` again.

Tests:

```sh
xcodebuild test -scheme Zigzag
```

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md). For security problems, see
[SECURITY.md](SECURITY.md) and please don't open a public issue.

## License

Zigzag is source available under the [Functional Source License (FSL-1.1-MIT)](LICENSE). Each version becomes
MIT licensed two years after its release. Forks and contributions are welcome.

| You can | Until a version turns two, you can't |
|---|---|
| Read, build and run the code | Offer it, or something built from it, as a competing product |
| Fork it and change it | |
| Contribute back | |

Two years after each release, that version is under the [MIT license](https://opensource.org/license/mit)
with no restrictions. The [LICENSE](LICENSE) file has the full terms. Zigzag also uses work by others, including
EasyList and EasyPrivacy by The EasyList authors (CC BY-SA 3.0): see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Zigzag isn't affiliated with The Browser Company.
