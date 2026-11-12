import Foundation
import WebKit

/// The sites dark pages saw dark on their own (#134), kept for each profile beside its palettes, so a site's pages start
/// on its own dark from its first moment, the next time and after a restart too, rather than going through the filter
/// first: GitHub's dark, turned white by it, showed for half a second on the first visit of every session.
///
/// For each site: the dark its page was drawn on, which a page of it starts on until it's looked at, and the mark its
/// own dark look sets on the page's root by script (a class of "dark", or data-theme="dark"), if it sets one, so its
/// dark style applies from the first sheet. Only a mark the site was seen setting itself is kept, never one it doesn't use.
///
/// It's a list of sites you've been to, so it goes with them as palettes do: clearing a site's cache or cookies takes
/// it, clearing all of either or all of History takes them all, and clearing History since a time takes the ones seen
/// since. Never for a private window, which learns nothing and is given nothing.
@MainActor
enum DarkSeen {
    struct Site: Codable, Equatable {
        /// The page's own dark, "#0d1117".
        var color: String?
        /// The mark its dark look puts on the root (`mark` in dark-pages.js): "class:dark", "attr:data-theme=dark".
        var marker: String?
        /// When it was first seen dark, or last changed.
        var date: Date
    }

    static let fileName = "Seen Dark.plist"
    /// Sites kept for each profile: the ones longest unchanged go first.
    static let maxSites = 1000

    private static var loaded: [String: [String: Site]] = [:]
    private static var disk: DispatchQueue { DarkPalettes.disk }

    private static func file(_ scope: String) -> URL? { DarkPalettes.folder(scope)?.appendingPathComponent(fileName) }

    /// A profile's sites seen dark (`DarkPages.nativeScope`); none for a private window.
    static func sites(in scope: String?) -> [String: Site] {
        guard let scope else { return [:] }
        if let known = loaded[scope] { return known }
        let read = file(scope).flatMap { try? Data(contentsOf: $0) }.flatMap { try? PropertyListDecoder().decode([String: Site].self, from: $0) } ?? [:]
        loaded[scope] = read
        return read
    }

    static func site(_ site: String?, in scope: String?) -> Site? {
        guard let site else { return nil }
        return sites(in: scope)[site]
    }

    /// Keeps a site, or lets it go (nil), and writes the profile's list off the main thread.
    static func set(_ site: String, _ value: Site?, in scope: String) {
        var all = sites(in: scope)
        guard all[site] != value else { return }
        all[site] = value
        if all.count > maxSites {
            for old in all.sorted(by: { $0.value.date < $1.value.date }).prefix(all.count - maxSites) { all[old.key] = nil }
        }
        loaded[scope] = all
        write(all, scope: scope)
    }

    private static func write(_ all: [String: Site], scope: String) {
        guard let url = file(scope) else { return }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = all.isEmpty ? nil : try? encoder.encode(all)
        disk.async {
            guard let data else { try? FileManager.default.removeItem(at: url); return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Lets go of a profile's sites: one site's (covering its subdomains, and the site it's under), the ones seen
    /// since a time, or all.
    static func forget(scope: String, site: String? = nil, since: Date? = nil) {
        let all = sites(in: scope)
        let kept: [String: Site]
        if let site {
            kept = all.filter { key, _ in !(key == site || key.hasSuffix("." + site) || site.hasSuffix("." + key)) }
        } else if let since {
            kept = all.filter { $0.value.date < since }
        } else {
            kept = [:]
        }
        guard kept.count != all.count || (site == nil && since == nil) else { return }
        loaded[scope] = kept
        write(kept, scope: scope)
    }

    /// Waits for the list to be written (tests).
    static func settle() { disk.sync {} }

    /// Forgets what's been read, so the next look reads the file again (tests).
    static func reload() { loaded = [:] }
}
