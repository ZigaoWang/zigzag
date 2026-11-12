import Foundation

/// The sizes the developer tools offer for a page (#141): a few devices to begin with, and your own, kept in
/// Settings › Developer. A size is the page's own area in points, as a site's styles see it.
enum PageSizes {
    nonisolated struct Size: Codable, Equatable, Sendable {
        var name: String
        var width: Int
        var height: Int

        var size: CGSize { CGSize(width: width, height: height) }
        /// "393 × 852", as the bar above the page and the list say it.
        var dimensions: String { PageSizes.dimensions(size) }
    }

    private static let key = "DeveloperPageSizes"
    /// The list before you change it. Nothing is written until you do. Real devices by name, as browsers' device
    /// toolbars list them, each at the size its browser lays a page out at (CSS pixels, upright): the phones and
    /// tablets people check a site on most, then two common laptop windows and a full HD screen.
    static let seed = [Size(name: "iPhone SE", width: 375, height: 667), Size(name: "iPhone 16", width: 393, height: 852),
                       Size(name: "iPhone 16 Pro Max", width: 440, height: 956), Size(name: "Pixel 7", width: 412, height: 915),
                       Size(name: "Galaxy S24", width: 360, height: 780), Size(name: "iPad mini", width: 744, height: 1133),
                       Size(name: "iPad Air", width: 820, height: 1180), Size(name: "iPad Pro 13″", width: 1032, height: 1376),
                       Size(name: "Laptop", width: 1280, height: 800), Size(name: "Desktop", width: 1440, height: 900),
                       Size(name: "Full HD", width: 1920, height: 1080)]
    /// The least and the most a page's side can be: narrower than any phone, and no larger than a page ever is.
    static let limits = 200...8000

    /// In the order they were added.
    static var all: [Size] {
        get {
            guard let data = DeveloperTools.defaults.data(forKey: key), let sizes = try? JSONDecoder().decode([Size].self, from: data) else { return seed }
            // Whatever was kept, only sizes a page can be.
            return sizes.filter { limits.contains($0.width) && limits.contains($0.height) && !$0.name.isEmpty }
        }
        set {
            DeveloperTools.defaults.set(try? JSONEncoder().encode(newValue), forKey: key)
            DeveloperTools.changed.send()
        }
    }

    /// Plain figures, as a stylesheet has them: 1280, never 1,280.
    nonisolated static func dimensions(_ size: CGSize) -> String {
        String(localized: "\(String(Int(size.width))) × \(String(Int(size.height)))", comment: "A page's size in points, width then height, like “393 × 852”.")
    }

    /// A size from what you typed into Add Size or Custom Size: whole numbers within `limits`, else nil.
    static func size(width: String, height: String) -> CGSize? {
        func side(_ text: String) -> Int? {
            guard let value = Int(text.trimmingCharacters(in: .whitespaces)), limits.contains(value) else { return nil }
            return value
        }
        guard let w = side(width), let h = side(height) else { return nil }
        return CGSize(width: w, height: h)
    }

    /// Adds a size to the list. One with the same name takes the old one's place.
    static func add(_ size: Size) {
        let name = size.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, limits.contains(size.width), limits.contains(size.height) else { return }
        var list = all.filter { $0.name != name }
        list.append(Size(name: name, width: size.width, height: size.height))
        all = list
    }

    static func remove(_ size: Size) {
        var list = all
        guard list.contains(size) else { return }
        list.removeAll { $0 == size }
        all = list
    }

    /// The listed size a page of `size` is, either way up.
    static func named(_ size: CGSize?) -> Size? {
        guard let size else { return nil }
        return all.first { $0.size == size || $0.size == CGSize(width: size.height, height: size.width) }
    }

    /// A listed size's id among the command bar's commands, by its place in the list.
    static func commandID(_ index: Int) -> String { "developer-size:\(index)" }
    static func size(commandID: String) -> Size? {
        guard commandID.hasPrefix("developer-size:"), let index = Int(commandID.dropFirst("developer-size:".count)) else { return nil }
        let sizes = all
        return sizes.indices.contains(index) ? sizes[index] : nil
    }

    /// A listed size in a menu: its name, then its width and height.
    static func menuTitle(_ size: Size) -> String {
        String(localized: "\(size.name), \(size.dimensions)", comment: "A size in the Page Size menu of the developer tools above the page: its name, then its width and height, like “iPhone, 393 × 852”.")
    }

    /// The size Toggle Page Size gives a page that never had one: the first phone listed, or the first size.
    static var firstToggled: CGSize? {
        let sizes = all
        return (sizes.first { min($0.width, $0.height) < 500 } ?? sizes.first)?.size
    }

    /// A listed size as a command: named as Page Size names it, with its width and height.
    static func commandTitle(_ size: Size) -> String {
        String(localized: "Page Size: \(size.name), \(size.dimensions)", comment: "A command in the command bar, on a development site: gives the page a listed size. The size's name, then its width and height, like “Page Size: iPhone 16, 393 × 852”.")
    }
}
