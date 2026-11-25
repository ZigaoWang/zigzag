import AppKit

/// Restoring a backup: merged into what's here, as importing Arc again is. Spaces are matched by ID, then by name in
/// the same profile; pages by address within their space, favorites within their profile. Nothing here is removed or
/// renamed, and the same backup restored twice adds nothing the second time.
extension ZigzagBackup {
    struct Merge {
        var contents: Library.Contents
        /// The backup's space and profile IDs, to the ones here.
        var spaceIDs: [UUID: UUID] = [:]
        var profileIDs: [UUID: UUID] = [:]
        var pinned = 0
        var favorites = 0
        var spaces = 0
    }

    /// `icons`: image icons as restored, old icon string to new; an image icon not in it is left off. `backgrounds`
    /// likewise for space pictures, by file name.
    func merged(into contents: Library.Contents, icons: [String: String] = [:], backgrounds: [String: String] = [:]) -> Merge {
        var merge = Merge(contents: contents)
        var directory = contents.directory

        for profile in profiles {
            if profile.isDefault || directory.profile(profile.id) != nil {
                merge.profileIDs[profile.id] = profile.id
            } else if directory.deleting.contains(where: { $0.id == profile.id }) {
                // Being erased here: what was on it goes to the first profile.
                merge.profileIDs[profile.id] = Profile.defaultID
            } else {
                let name = ProfileDirectory.freshName(profile.name ?? profile.displayName, taken: directory.all.map(\.displayName))
                directory.add(name: name, color: profile.color, id: profile.id, created: profile.created ?? Date())
                merge.profileIDs[profile.id] = profile.id
            }
        }
        func profileHere(_ id: UUID?) -> UUID { id.flatMap { merge.profileIDs[$0] } ?? Profile.defaultID }

        var pageIDs = Set(contents.favorites.map(\.id) + contents.spaces.flatMap { $0.bookmarks.map(\.id) })
        var folderIDs = Set(contents.spaces.flatMap { ($0.folders ?? []).map(\.id) })
        func icon(_ icon: String?) -> String? {
            guard let icon, PageImageIcon.isImage(icon) else { return icon }
            return icons[icon]
        }

        let backupSpaceIDs = Set(spaces.map(\.id))
        var matched: Set<UUID> = []
        for space in spaces {
            let profile = profileHere(spaceProfiles[space.id.uuidString])
            let name = space.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let index = merge.contents.spaces.firstIndex { $0.id == space.id } ?? merge.contents.spaces.firstIndex {
                !matched.contains($0.id) && !backupSpaceIDs.contains($0.id) && directory.profileID(ofSpace: $0.id) == profile
                    && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == name
            }
            var look = space
            look.bookmarks = []
            look.folders = nil
            look.pinnedSplits = nil
            look.icon = icon(space.icon)
            look.backgroundImage = space.backgroundImage.flatMap { backgrounds[$0] }
            if let index {
                var here = merge.contents.spaces[index]
                matched.insert(here.id)
                // A space of that name with nothing pinned yet (a new Mac's first) takes the backup's look too.
                if here.id != space.id, here.bookmarks.isEmpty, (here.folders ?? []).isEmpty {
                    look.id = here.id
                    here = look
                }
                merge.pinned += Self.mergePages(of: space, into: &here, pageIDs: &pageIDs, folderIDs: &folderIDs, icon: icon)
                merge.contents.spaces[index] = here
                merge.spaceIDs[space.id] = here.id
            } else {
                merge.pinned += Self.mergePages(of: space, into: &look, pageIDs: &pageIDs, folderIDs: &folderIDs, icon: icon)
                merge.contents.spaces.append(look)
                directory.assign(space: look.id, to: profile)
                merge.spaceIDs[space.id] = look.id
                merge.spaces += 1
            }
        }

        for route in siteRoutes {
            guard let space = merge.spaceIDs[route.spaceID],
                  !merge.contents.siteRoutes.contains(where: { $0.id == route.id || ($0.site == route.site && $0.match == route.match) }) else { continue }
            var copy = route
            copy.spaceID = space
            merge.contents.siteRoutes.append(copy)
        }

        var knownFavorites: [UUID: Set<String>] = [:]
        for favorite in contents.favorites { knownFavorites[directory.profileID(ofFavorite: favorite.id), default: []].insert(TabManager.pinnedKey(favorite.url)) }
        var favoriteIDs: [UUID: UUID] = [:]
        for favorite in favorites {
            let profile = profileHere(favoriteProfiles[favorite.id.uuidString])
            let key = TabManager.pinnedKey(favorite.url)
            guard knownFavorites[profile]?.contains(key) != true else { continue }
            var copy = favorite
            copy.id = Self.fresh(favorite.id, in: &pageIDs)
            copy.icon = icon(favorite.icon)
            merge.contents.favorites.append(copy)
            directory.assign(favorite: copy.id, to: profile)
            knownFavorites[profile, default: []].insert(key)
            favoriteIDs[favorite.id] = copy.id
            merge.favorites += 1
        }
        for split in favoriteSplits {
            let ids = split.ids.compactMap { favoriteIDs[$0] }
            guard ids.count == split.ids.count, let pair = split.pair(of: ids) else { continue }
            merge.contents.favoriteSplits.append(PinnedSplit(layout: pair))
        }
        merge.contents.directory = directory
        return merge
    }

    private static func fresh(_ id: UUID, in used: inout Set<UUID>) -> UUID {
        let new = used.contains(id) ? UUID() : id
        used.insert(new)
        return new
    }

    /// Adds `source`'s pinned pages that `here` doesn't have, with their folders and splits. Returns how many.
    private static func mergePages(of source: SpaceInfo, into here: inout SpaceInfo, pageIDs: inout Set<UUID>, folderIDs: inout Set<UUID>,
                                   icon: (String?) -> String?) -> Int {
        var known = Set(here.bookmarks.map { TabManager.pinnedKey($0.url) })
        var added: [UUID: UUID] = [:]
        var list = here.bookmarks
        for page in source.bookmarks where known.insert(TabManager.pinnedKey(page.url)).inserted {
            var copy = page
            copy.id = fresh(page.id, in: &pageIDs)
            copy.icon = icon(page.icon)
            list.append(copy)
            added[page.id] = copy.id
        }

        var folders = here.folders ?? []
        var folderMap: [UUID: UUID] = [:]
        for folder in parentsFirst(source.folders ?? []) {
            let parent = folder.parentID.flatMap { folderMap[$0] }
            let pages = folder.bookmarkIDs.compactMap { added[$0] }
            if let same = folders.firstIndex(where: { $0.id == folder.id }) ?? folders.firstIndex(where: { $0.parentID == parent && $0.name == folder.name }) {
                folderMap[folder.id] = folders[same].id
                folders[same].bookmarkIDs += pages
            } else {
                var copy = folder
                copy.id = fresh(folder.id, in: &folderIDs)
                copy.parentID = parent
                copy.bookmarkIDs = pages
                copy.tucked = nil
                folders.append(copy)
                folderMap[folder.id] = copy.id
            }
        }

        var splits = here.pinnedSplits ?? []
        for split in source.pinnedSplits ?? [] {
            let ids = split.ids.compactMap { added[$0] }
            guard ids.count == split.ids.count, let pair = split.pair(of: ids) else { continue }
            splits.append(PinnedSplit(layout: pair))
        }
        let tidy = Library.tidied(list, folders, splits)
        here.bookmarks = tidy.bookmarks
        here.folders = tidy.folders.isEmpty && here.folders == nil ? nil : tidy.folders
        here.pinnedSplits = tidy.splits.isEmpty ? nil : tidy.splits
        return added.count
    }

    /// Each folder after the one it's in; a folder in a loop goes at the top level.
    private static func parentsFirst(_ folders: [BookmarkFolder]) -> [BookmarkFolder] {
        let ids = Set(folders.map(\.id))
        var result: [BookmarkFolder] = [], done: Set<UUID> = []
        var rest = folders
        while !rest.isEmpty {
            let ready = rest.filter { folder in folder.parentID.map { !ids.contains($0) || done.contains($0) } ?? true }
            guard !ready.isEmpty else {
                result += rest.map { var folder = $0; folder.parentID = nil; return folder }
                break
            }
            result += ready
            done.formUnion(ready.map(\.id))
            rest.removeAll { done.contains($0.id) }
        }
        return result
    }

    // MARK: Restoring

    /// File › Import with a backup chosen: merges it in, opens its open tabs (they wait to load), adds its history and,
    /// with `settings`, puts in its settings.
    static func restore(_ url: URL, settings useSettings: Bool) async -> ImportCoordinator.Summary {
        var summary = ImportCoordinator.Summary(source: url.lastPathComponent)
        let backup: ZigzagBackup
        switch read(url) {
        case .success(let read): backup = read
        case .failure(.newer):
            summary.problems.append(ImportProblem(message: String(localized: "\(url.lastPathComponent) was made by a newer Zigzag. Update Zigzag, then import it again.",
                                                                  comment: "Problem in the Import window, for a Zigzag backup. The placeholder is the file's name."), fix: .none))
            return summary
        case .failure(.unreadable):
            summary.problems.append(ImportProblem(message: String(localized: "\(url.lastPathComponent) isn’t a Zigzag backup Zigzag can read.",
                                                                  comment: "Problem in the Import window, for a Zigzag backup. The placeholder is the file's name."), fix: .none))
            return summary
        }

        let icons = await restoredIcons(backup.pageIcons)
        let backgrounds = restoredBackgrounds(backup.backgrounds)
        let library = Library.shared
        let merge = backup.merged(into: library.contents, icons: icons, backgrounds: backgrounds)
        library.importing(into: Profile.defaultID) { library.replaceContents(merge.contents) }
        summary.bookmarks = merge.pinned + merge.favorites
        summary.spaces = merge.spaces

        if let open = backup.openTabs {
            let rows = open.compactMap { space -> (space: UUID?, tabs: [ArcImporter.OpenTab])? in
                guard let here = merge.spaceIDs[space.spaceID] else { return nil }
                return (here, space.rows.map { ArcImporter.OpenTab(pages: $0.map { ArcImporter.OpenPage(url: $0.url, title: $0.title, customTitle: $0.customTitle) }) })
            }
            summary.tabs = ArcImporter.openInWindow(rows)
        }
        for profile in backup.history ?? [] {
            let here = merge.profileIDs[profile.profile] ?? Profile.defaultID
            summary.history += Profiles.shared.profile(here).history.importVisits(profile.visits.map { ($0.url, $0.title, $0.count, $0.lastVisit) })
        }
        if useSettings, let settings = backup.settings {
            apply(settings, to: .standard, profiles: Set(library.profiles.map(\.id)), icons: icons)
            if let engine = settings.searchEngine, engine != .fromExtension { library.searchEngine = engine }
            if let language = settings.language, Bundle.main.localizations.contains(language) { AppLanguage.chosen = language }
            summary.notes.append(String(localized: "Your settings came over too. Some take effect the next time Zigzag opens.",
                                        comment: "Note in the Import window after a Zigzag backup's settings were restored."))
        }
        return summary
    }

    /// Image icons kept again through the same safe reader as a picked image; one already here as it was keeps its name.
    private static func restoredIcons(_ icons: [String: Data]) async -> [String: String] {
        var result: [String: String] = [:]
        for (name, data) in icons {
            let old = PageImageIcon.prefix + name
            if PageImageIcon.isImage(old), (try? Data(contentsOf: PageImageIcon.folder.appendingPathComponent(name))) == data {
                result[old] = old
            } else if let new = try? await PageImageIcon.store(data) {
                result[old] = new
            }
        }
        return result
    }

    /// Space pictures kept again as a picked one is; one already here as it was keeps its name.
    private static func restoredBackgrounds(_ pictures: [String: Data]) -> [String: String] {
        var result: [String: String] = [:]
        guard !pictures.isEmpty, let scratch = try? ImportScratch.makeFolder("zigzag-import-") else { return result }
        defer { try? FileManager.default.removeItem(at: scratch) }
        for (name, data) in pictures where !name.contains("/") {
            if (try? Data(contentsOf: SpaceBackground.folder.appendingPathComponent(name))) == data { result[name] = name; continue }
            let file = scratch.appendingPathComponent(UUID().uuidString)
            guard (try? data.write(to: file)) != nil,
                  let new = SpaceBackground.store(file, for: UUID(), screen: SpaceBackground.screenPixels) else { continue }
            result[name] = new
        }
        return result
    }
}
