# Security

Zigzag is a browser and keeps people's passwords, so security reports matter a lot. Thank you for taking the
time to report one responsibly.

## Reporting a vulnerability

**Please don't open a public GitHub issue, discussion or pull request for a security vulnerability.** Report it
privately instead:

- **GitHub's private vulnerability reporting** (preferred): the repository's Security tab › Report a
  vulnerability, or [github.com/ZigaoWang/zigzag/security/advisories/new](https://github.com/ZigaoWang/zigzag/security/advisories/new).
  Only you and the maintainers can see it, and we can talk it through and work on the fix there.
- **Email**, if you'd rather not use GitHub: **a@zigao.wang**, with "Zigzag security" in the subject.

Please include:

- What the issue is and what an attacker could do with it.
- The Zigzag version and build (Zigzag › About Zigzag) and your macOS version.
- Steps to reproduce it, as small as you can make them. A test page or proof of concept helps a lot.
- Whether it needs anything unusual: a particular site, extension, setting or a local attacker.
- How you'd like to be credited, if at all.

Please don't include real passwords or personal data in your report. Use test accounts.

## What to expect

Zigzag has one maintainer, so these are aims rather than promises:

- An acknowledgment, usually within a few days.
- An initial assessment, and a plan if it's confirmed, usually within two weeks.
- Updates as the fix progresses. Fixes ship through Zigzag's automatic updates.
- Once the fixed version is out, a GitHub security advisory for the issue, and a line in the release notes. You're
  credited in both if you'd like to be.

Please give a reasonable time to fix the issue before disclosing it publicly; we'll agree on a date together.

## Supported versions

Security fixes go into the latest stable release and the current beta. Older versions don't get fixes, so
please check the issue on one of those two; Zigzag › Check for Updates… brings you up to date, and Settings ›
General › Beta updates chooses the beta channel.

## Scope

In scope: the Zigzag app and its code in this repository. That includes:

- The password manager, passkeys, autofill and import from other browsers.
- Extension support: installing from the Chrome Web Store, Firefox Add-ons or a folder, the Chrome APIs Zigzag adds, native
  messaging, and user scripts for script managers like Tampermonkey and Violentmonkey.
- AI apps over MCP: the local server, its key and how it's stored and copied, what tools can reach (private
  windows, passwords, Zigzag's own pages) and how page content is marked in tool results. AppleScript and
  JavaScript from Apple Events too.
- The sandboxed helpers that read pictures and PDFs from websites (ZigzagImageDecoder and ZigzagPDFRenderer).
- Secure connections: certificate warnings, Visit anyway, sites on the HSTS preload list, and trusting servers
  on this Mac in Developer Mode.
- Site permissions (camera, microphone, screen sharing, location, notifications, pop-ups, opening apps, WebRTC,
  JavaScript), the permission card that asks for them, and Protect IP address from WebRTC.
- Downloads, file types (Save and Open) and download rules, and links that open other apps.
- Private windows, profiles, Zigzag Mini and sites installed as apps.
- Content blocking, dark pages and cookie banner handling, including the filter lists and scriptlets Zigzag
  downloads.
- Updates: the Sparkle feed and its EdDSA signatures.

Out of scope:

- Bugs in WebKit or macOS themselves. Report those to [Apple](https://security.apple.com).
- Bugs in third-party extensions or in websites.
- Attacks that need you to be tricked into doing something unusual (social engineering), someone using your Mac
  while it's unlocked, or pasting code into a page's console yourself (self-XSS).

If you're not sure, report it anyway.

## Safe harbor

We won't pursue or support legal action against anyone for good-faith security research that follows this
policy: test only against your own accounts and data, don't harm other people or their data, and give us the
time to fix the issue before you disclose it.
