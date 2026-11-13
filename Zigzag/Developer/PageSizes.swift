import Foundation

/// The sizes the developer tools offer for a page (#141): a few devices to begin with, and your own, kept in
/// Settings › Developer. A size is the page's own area in points, as a site's styles see it, and a device's has its
/// pixel ratio: how many of the screen's pixels it draws each of those with.
enum PageSizes {
    nonisolated struct Size: Codable, Equatable, Sendable {
        var name: String
        var width: Int
        var height: Int
        /// The device's pixel ratio, as a page there reads it (`devicePixelRatio`); nil for a size without one, which
        /// a page is shown at with the Mac's.
        var pixelRatio: Double? = nil

        var size: CGSize { CGSize(width: width, height: height) }
        /// "393 × 852", as the bar above the page and the list say it.
        var dimensions: String { PageSizes.dimensions(size) }
    }

    private static let key = "DeveloperPageSizes"
    /// The list before you change it. Nothing is written until you do. Real devices by name, as browsers' device
    /// toolbars list them, each at the size its browser lays a page out at (CSS pixels, upright): the phones and
    /// tablets people check a site on most, then two common laptop windows and a full HD screen.
    /// Each device's pixel ratio is its screen's (a laptop's is a Retina one; a desktop's and full HD's, 1).
    nonisolated static let seed = [Size(name: "iPhone SE", width: 375, height: 667, pixelRatio: 2), Size(name: "iPhone 16", width: 393, height: 852, pixelRatio: 3),
                       Size(name: "iPhone 16 Pro Max", width: 440, height: 956, pixelRatio: 3), Size(name: "Pixel 7", width: 412, height: 915, pixelRatio: 2.625),
                       Size(name: "Galaxy S24", width: 360, height: 780, pixelRatio: 3), Size(name: "iPad mini", width: 744, height: 1133, pixelRatio: 2),
                       Size(name: "iPad Air", width: 820, height: 1180, pixelRatio: 2), Size(name: "iPad Pro 13″", width: 1032, height: 1376, pixelRatio: 2),
                       Size(name: String(localized: "pagesize.laptop", defaultValue: "Laptop", comment: "A page size in the developer tools: a common laptop window, 1280 × 800."), width: 1280, height: 800, pixelRatio: 2),
                       Size(name: String(localized: "pagesize.desktop", defaultValue: "Desktop", comment: "A page size in the developer tools: a common desktop window, 1440 × 900."), width: 1440, height: 900, pixelRatio: 1),
                       Size(name: String(localized: "pagesize.fullhd", defaultValue: "Full HD", comment: "A page size in the developer tools: a full HD screen, 1920 × 1080."), width: 1920, height: 1080, pixelRatio: 1)]
    /// The least and the most a page's side can be: narrower than any phone, and no larger than a page ever is.
    static let limits = 200...8000
    /// The least and the most a pixel ratio can be: a plain screen's, to a little past any phone's.
    static let pixelRatioLimits = 1.0...4.0

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

    /// A pixel ratio from what you typed into Add Size: a number within `pixelRatioLimits`, "x" or "×" after it or
    /// not, with a point or a comma before its decimals, as you'd write it. Nil when it isn't one; blank is no ratio
    /// at all (`isPixelRatio`).
    static func pixelRatio(from text: String) -> Double? {
        var typed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: ",", with: ".")
        if typed.hasSuffix("x") || typed.hasSuffix("×") { typed = String(typed.dropLast()).trimmingCharacters(in: .whitespaces) }
        guard let value = Double(typed), value.isFinite, pixelRatioLimits.contains(value) else { return nil }
        return value
    }

    /// Whether what's typed is a pixel ratio, or nothing: a size needn't have one.
    static func isPixelRatio(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pixelRatio(from: text) != nil
    }

    /// A pixel ratio as the developer tools say it: "3×", "2.625×", in plain figures as a stylesheet has them.
    nonisolated static func pixelRatioText(_ ratio: Double) -> String {
        String(localized: "\(String(format: "%g", ratio))×", comment: "A page's pixel ratio, how many of the screen's pixels it draws each of its own with, like “3×” or “2.625×”.")
    }

    /// What Settings says of a listed size under its name: its width and height, and its pixel ratio when it has one.
    static func detail(_ size: Size) -> String {
        guard let ratio = size.pixelRatio else { return size.dimensions }
        return String(localized: "\(size.dimensions), \(pixelRatioText(ratio))", comment: "Under a page size's name in Settings › Developer: its width and height, then its pixel ratio, like “393 × 852, 3×”.")
    }

    /// Adds a size to the list. One with the same name takes the old one's place.
    static func add(_ size: Size) {
        let name = size.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, limits.contains(size.width), limits.contains(size.height) else { return }
        var list = all.filter { $0.name != name }
        list.append(Size(name: name, width: size.width, height: size.height, pixelRatio: size.pixelRatio.flatMap { pixelRatioLimits.contains($0) ? $0 : nil }))
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

nonisolated extension PageSizes.Size {
    private enum CodingKeys: String, CodingKey { case name, width, height, pixelRatio }

    /// A size as kept. One kept before sizes had pixel ratios says nothing of one, and a listed device's gets its
    /// own as it's read (`PageSizes.seed`), without the list being written; one kept since says it has none when it
    /// has none, and keeps none, whatever its name.
    init(from decoder: any Decoder) throws {
        let kept = try decoder.container(keyedBy: CodingKeys.self)
        name = try kept.decode(String.self, forKey: .name)
        width = try kept.decode(Int.self, forKey: .width)
        height = try kept.decode(Int.self, forKey: .height)
        if kept.contains(.pixelRatio) {
            pixelRatio = try kept.decodeIfPresent(Double.self, forKey: .pixelRatio)
        } else {
            let (name, width, height) = (name, width, height)
            pixelRatio = PageSizes.seed.first { $0.name == name && $0.width == width && $0.height == height }?.pixelRatio
        }
    }

    func encode(to encoder: any Encoder) throws {
        var kept = encoder.container(keyedBy: CodingKeys.self)
        try kept.encode(name, forKey: .name)
        try kept.encode(width, forKey: .width)
        try kept.encode(height, forKey: .height)
        if let pixelRatio { try kept.encode(pixelRatio, forKey: .pixelRatio) } else { try kept.encodeNil(forKey: .pixelRatio) }
    }
}
