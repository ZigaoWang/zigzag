# Releasing Zigzag

How versions are numbered, what goes into each kind of release, and what has to be true before one ships.

## Version numbers

Zigzag uses semantic versions, `MAJOR.MINOR.PATCH`:

- **Patch** (1.0.1): bug fixes only. No new features, no new settings, no new strings unless a fix needs one.
- **Minor** (1.1.0): new features and improvements, every few weeks. Most releases are minors.
- **Major** (2.0.0): a deliberate overhaul. Rare; there's no schedule for it.

Before a stable version, its betas are `1.1.0-beta.1`, `beta.2` and so on, on the beta feed (Settings › General › Beta
updates). The build number (`CURRENT_PROJECT_VERSION`) goes up by one with every build that ships, beta or stable.

## What each release needs

Every release, beta or stable:

- `scripts/test.sh` passes in full.
- `python3 scripts/check-strings.py` passes: every shipped language has every string and its release notes.
- The version's section in `CHANGELOG.md` lists every user-facing change, with its issue link, and every translated
  changelog under `docs/i18n/changelog` has the same items.

A stable minor also needs:

- At least one beta, and a final beta that takes only fixes (the release candidate).
- No open issue labeled `regression` or `severity: critical` for that milestone.
- The release candidate out for long enough with no new regressions reported. A week is the usual minimum.
- Updating tested from the previous stable, not only from the last beta, and data from older versions still loading.

## Patch releases

A patch fixes what can't wait for the next minor: a crash, lost data, a security problem, or a core feature that broke.

- If `main` holds only fixes since the last stable, release from `main`.
- If `main` already has unfinished features, branch from the last stable tag (`release/1.1`), cherry-pick the fixes,
  release from that branch, and keep the fixes on `main` too.

## Bugs and labels

- `regression`: something that used to work. It blocks the stable release it was found in.
- `severity: critical`: crashes, data loss, security, or a core feature unusable. Fixed in a patch.
- `severity: high`: a feature broken for many people. Fixed in the next release.
- Everything else goes into a minor when it's ready.

Every fixed bug gets a test that fails without the fix, so it stays fixed.
