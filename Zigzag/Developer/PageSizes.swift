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
    /// The list before you change it. Nothing is written until you do.
    static let seed = [Size(name: "iPhone SE", width: 375, height: 667), Size(name: "iPhone", width: 393, height: 852),
                       Size(name: "iPad mini", width: 744, height: 1133), Size(name: "iPad", width: 820, height: 1180),
                       Size(name: "Laptop", width: 1280, height: 800), Size(name: "Desktop", width: 1440, height: 900)]
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
}
