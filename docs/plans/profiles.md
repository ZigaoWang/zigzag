# Profiles in Zigzag

Goal: a profile owns its extensions, sign-ins, history and favorites, and each space is attached to one profile, so two spaces can run two different wallets or two accounts of the same site. Saved passwords are one vault for every profile. Branch `feat/profiles`, a series of small commits on `main`. Ships once two wallets have been used side by side by hand and nothing changes for someone who never makes a second profile.

## What exists today

- A space (`SpaceInfo`) is a name, a look and its pinned pages. It owns no data.
- One extension world: `ExtensionHost.shared` holds one `WKWebExtensionController` with a fixed identifier, attached to every page that isn't private (`WebKitSetup.configure`). `ExtensionBridge.shared` and `ExtensionStore` key everything by the extension's ID alone.
- One website data store: every page that isn't private uses `WKWebsiteDataStore.default()`.
- One `History.sqlite`, one Keychain vault (the label "Zigzag"), one list of favorites, "the same in every space".
- A window shows several spaces, so a window can't stand for one profile. A tab can.

## What WebKit does (read from its headers and source, and tried with Rabby 0.94.15)

- Two `WKWebExtensionController`s can each load a context with the same `uniqueIdentifier` and `baseURL`. The "already loaded" and "base URL in use" checks are per controller. `Configuration(identifier:)` gives each its own storage folder (`WebExtensions/<UUID>/<extension id>/`), which is where `chrome.storage` lives.
- An extension's pages and its worker keep `localStorage` and IndexedDB in `configuration.webViewConfiguration.websiteDataStore`. `defaultWebsiteDataStore` is only what `browser.cookies` reads. Setting only the second leaves two copies of an extension sharing page data: tried, and they did. Both are set.
- When a context loads, WebKit removes `webkit-extension` data in that store for extensions the controller doesn't know. Two controllers on one store would erase each other's. One controller per store, always.
- `WKWebsiteDataStore(forIdentifier:)` is the store for a profile. `remove(forIdentifier:)` refuses while the store object or its network session is alive ("Data store is in use"), so removing a profile's data can need a relaunch. `allDataStoreIdentifiers` only lists folders.
- The private calls that let embedded sites keep their cookies (`WebKitSetup.allowCrossSiteCookies`) act on one store. They're made for each profile's store.
- `controller.extensionContext(for: URL)` is WebKit's own way from an extension page's address to its context.
- After a relaunch an extension's service worker in a named store only starts again once its old registration is forgotten there too (`WebsiteDataStore/<uuid>/Origins/…/ServiceWorkers`), as #14 does for the default store.

## Approach

### Recommended: one object per profile owns everything that's separate

- **`Profile`**: its `WKWebsiteDataStore` (one object for the life of the app; certificate exceptions, sign-in prompts and downloads compare stores by identity), its `ExtensionHost` (made on first use), its `ExtensionInstalls` and its `HistoryStore`. `Profiles.shared` finds one from a space, a page or a controller. A tab reaches everything through `tab.profile`; nothing is ambient.
- **The first profile is what you have now.** It keeps the default store, the controller's identifier, `History.sqlite`, its preference keys and every file where it is. Nothing is migrated.
- **Where profiles are kept: `Profiles.json`**, a new file beside `Library.json`, with the profiles, which space is on which, and those being removed. An older Zigzag rewrites `Library.json` without keys it doesn't know; it never writes this file. Going back to an older version shows every space on the first profile, and coming forward again brings each back to its own. For the same reason another profile's extension state, favorites and history live in `Profiles/<uuid>/`, not inside files older versions rewrite.
- **Extensions:** `ExtensionHost(profile:)`, one bridge per host, so every table keyed by an extension's ID is right as it stands. `ExtensionCenter` keeps what belongs to the app: the gesture and menu observers, and passing tab and window events to the right host. An extension is told about its own profile's tabs only. `ExtensionStore` becomes `ExtensionPackages` (the downloaded versions, shared) and `ExtensionInstalls` (on or off, what it's allowed, pins: one per profile).
- **One rule for tabs: a tab's page is always in its space's profile.** `Tab.spaceID` is set in one place, which rebuilds the page in the other profile when the two differ, keeping its back and forward list. Moving a tab, changing a space's profile, undo and removing a profile all follow from it. Only a move you make yourself asks first.
- **History:** a file per profile. **Passwords:** one vault, shared. A vault per profile would be told apart by an ID that exists on one Mac only, so what iCloud Keychain synced couldn't be reached anywhere else, and removing a profile would delete synced logins. What is a profile's is whether Zigzag offers to save and fill there, since the reason to turn that off is a password manager extension, and extensions are a profile's. **Favorites:** each profile has its own, in its own order. They stay together in `Library.json`, so an older Zigzag still shows and keeps every one; whose each is, is in `Profiles.json` beside the spaces'.
- **Removing a profile** is written down first (`deleting` in `Profiles.json`), then done: its spaces move to the first profile, its extensions unload, its files and store go. Whatever WebKit still holds is removed at the next launch, before any store is opened. A store with no profile is never removed without asking.

Trade-offs, on purpose:

- A login saved while in one profile is offered in every profile, on the site it was saved for.
- Site permissions, sites where ads are allowed, zoom and site icons stay shared in this version.
- Importing from Arc brings its spaces into one profile. It doesn't remake Arc's profiles.

### Fallback: one profile's extensions at a time

If running the same extension in two controllers at once turns out not to hold up in daily use, only the profile of the space you're in keeps its extensions loaded, and switching to a space on another profile loads that one's. Sign-ins and history stay separate either way. Slower, and an extension stops hearing about tabs in the profile you left.

### Must be proven first (spike)

Done, with Rabby in two profiles: both copies load and run at once; `chrome.storage`, `localStorage` and a site's cookies are separate; each sees only its own profile's tabs; both come back after a relaunch.

Also tried, each with a debug command in the same test build:

1. A tab rebuilt in another store and controller keeps its back and forward list: Back returned to the page before.
2. A profile's extensions loaded after its page was made still reach that page: Rabby's `window.ethereum` appeared on the open page without a reload. So a profile's extensions can wait until the profile is first used.
3. One window told to two controllers, each given only its own tabs, worked throughout: each copy of Rabby listed its own profile's tabs.
4. `remove(forIdentifier:)` refuses while the app has opened the store ("Data store is in use") and works at launch before anything opens it. The controller's own `WebExtensions/<UUID>` folder stays behind either way, so Zigzag removes it.
5. A proxy set on one profile's store stops that profile's pages and leaves the other's alone.

Still to try by hand: two copies of 1Password's helper running at once.

## Steps

1. **Spikes**, the six above, on a branch that's thrown away.
2. **Changes you can't see**, each its own commit, the app the same before and after: the two renames (`ExtensionProfile` to `ExtensionShims`, `ProfileBackup` to `UpdateBackup`, so "profile" means one thing); a `Profile` that owns the default store and host; `WebKitSetup` building for a profile; `ExtensionCenter`; callers reaching extensions through their tab; a bridge per host; `ExtensionStore` split in two; `Tab.setSpace`; history opened per store; favorites as a set; shared pieces for the views (a sheet that asks you to type a name, a dropdown that can end with an action).
3. **The core:** `Profiles.json`; a store and controller per profile; pages, pop-ups, Zigzag Mini and Peek opening in their profile; extensions seeing their own profile; rebuilding a tab in another profile; installing per profile; forgetting service workers in every store; removing a profile.
4. **What you see first:** Settings › Profiles, the Profile row in a space's editor, the profile beside the space's name, Site Controls, the sections of Settings that are about one profile, choosing the profile an extension is added to, moving a tab between profiles, Zigzag Mini.
5. **Favorites** per profile.
6. **History** per profile, the History page and the command bar.
7. **Passwords:** saving and filling chosen per profile, the vault shared.
8. **Import** into the profile you choose.
9. **Release:** a CHANGELOG entry, the README's table, and "Profile" in the glossary.

## As built, where it differs from the above

- The History page shows the history of the profile its tab is in, and says whose it is. It has no profile menu of its own: open it in a space on the profile you want.
- Clearing a profile's history also clears what isn't kept by profile (site icons, places in PDFs, the notes of what went wrong lately), for every profile, so nothing cleared leaves a trace.
- The command bar suggests only the open pages, favorites, pinned tabs, archived tabs and history of the profile you're in.
- Removing a profile removes its favorites; the pages open from them become tabs in the first profile.
- Data on disk that belongs to no profile (a `Profiles.json` put back from an older backup, or one set aside as unreadable) is listed in Settings › Profiles under "Not Listed", to restore as a profile or delete. A restored profile gets its data back but not its spaces: which space was on it went with the file.
- The app's singletons (the library, the profile registry) read the real data folder, so tests don't construct them. What depends on them (removal, the command bar's filter, an extension's bookmarks) is checked by launching a test copy, not by unit tests; the rules themselves are pure functions with tests.
- A shared package and the first profile's choices about it share `Extensions/<id>/state.json`, each writer keeping its own keys; there is no `package.json`. The packages' side kept the name `ExtensionStore`.
- Settings, with more than one profile, ends its column with a group headed "For This Profile": a menu that chooses the profile, then Extensions and Website Data (the clearing and the per-site list that are in Privacy while there's one profile). A heading that names a profile shows that profile's things; one that names none is shared. ⌘, opens it on the profile of the space you're in. With one profile Settings is as it was.
- Choosing a profile in Settings to look at its extensions or website data opens that profile's store and starts its extensions. Listing profiles, in Settings or in a menu, never does.
- A profile something is still writing into (an import) can't be removed until that's done: `Profiles.remove` refuses, and the sheet says why.
- A profile's own preference keys (its pins, whether Zigzag saves and fills passwords there) are named in one place, `ProfileKey`; the first profile's are the names Zigzag has always used.

## Rules while doing it

- Never on the data you use: a test copy (`ZIGZAG_DATA_DIR`, `ZIGZAG_TEST_VAULT`) under its own bundle ID, since WebKit keys website and extension storage by it, on its own debug channel.
- Throwaway wallets only. No funds, no real recovery phrase.
- With one profile, nothing but Settings › Profiles and the editor's Profile row is new. Check it after every step.
- Conventional commits, one small change each, with tests for the logic it changes.
