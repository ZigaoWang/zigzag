import AppKit

/// The developer tools' sheets for a page's size (#141): a size of your own for the page you're on, and a size
/// added to the list in Settings › Developer.
enum PageSizeSheet {
    private static func field(_ value: CGFloat?, placeholder: String) -> FilledField {
        let field = FilledField(placeholder: placeholder)
        if let value { field.stringValue = String(Int(value)) }
        return field
    }

    private static var widthLabel: String { String(localized: "Width", comment: "Label of the width field in the sheet that asks for a page's size, in points.") }
    private static var heightLabel: String { String(localized: "Height", comment: "Label of the height field in the sheet that asks for a page's size, in points.") }
    private static var limitsNote: String {
        String(localized: "In points, from \(String(PageSizes.limits.lowerBound)) to \(String(PageSizes.limits.upperBound)).", comment: "Note under the width and height fields in the sheet that asks for a page's size: the least and the most a side can be.")
    }

    /// View › Developer › Custom Page Size…: asks for a width and a height, starting from `current`.
    @discardableResult
    static func custom(in host: NSView, current: CGSize?, done: @escaping (CGSize) -> Void) -> FormSheet {
        let width = field(current?.width, placeholder: "393"), height = field(current?.height, placeholder: "852")
        return FormSheet.show(in: host, title: String(localized: "Custom Page Size", comment: "Title of the sheet that asks for a size of your own for the page, with the developer tools."), symbol: "ipad.and.iphone",
                              rows: [FormSheet.Row(label: widthLabel, view: width), FormSheet.Row(label: heightLabel, view: height), .note(limitsNote)],
                              confirmTitle: String(localized: "Set Size", comment: "Button that gives the page the size typed, in the sheet that asks for a page's size."),
                              canConfirm: { [weak width, weak height] in PageSizes.size(width: width?.stringValue ?? "", height: height?.stringValue ?? "") != nil }) { confirmed in
            guard confirmed, let size = PageSizes.size(width: width.stringValue, height: height.stringValue) else { return }
            done(size)
        }
    }

    /// Settings › Developer › Add Size…: a name, a width and a height, and the device's pixel ratio if you know it,
    /// added to the list.
    @discardableResult
    static func add(in host: NSView) -> FormSheet {
        let name = FilledField(placeholder: String(localized: "Name this size", comment: "Placeholder of the name field in the sheet that adds a page size to the list in Settings › Developer."))
        let width = field(nil, placeholder: "393"), height = field(nil, placeholder: "852")
        let ratio = FilledField(placeholder: String(localized: "The Mac's", comment: "Placeholder of the pixel ratio field in the sheet that adds a page size: left empty, the page is shown with the Mac's own pixel ratio."))
        let ratioLabel = String(localized: "Pixel ratio", comment: "Label of the field in the sheet that adds a page size for the device's pixel ratio, like 3 for an iPhone. Optional.")
        let ratioNote = String(localized: "A device's pixel ratio, like 3 for an iPhone, from \(String(format: "%g", PageSizes.pixelRatioLimits.lowerBound)) to \(String(format: "%g", PageSizes.pixelRatioLimits.upperBound)). Leave it empty for the Mac's.", comment: "Note under the pixel ratio field in the sheet that adds a page size: what it is, the least and the most it can be, and that it can be left empty.")
        return FormSheet.show(in: host, title: String(localized: "Add a Page Size", comment: "Title of the sheet that adds a page size to the list in Settings › Developer."), symbol: "ipad.and.iphone",
                              rows: [FormSheet.Row(label: nil, view: name), FormSheet.Row(label: widthLabel, view: width), FormSheet.Row(label: heightLabel, view: height), .note(limitsNote),
                                     FormSheet.Row(label: ratioLabel, view: ratio), .note(ratioNote)],
                              confirmTitle: String(localized: "Add", comment: "Button that adds the size, in the sheet that adds a page size."),
                              canConfirm: { [weak name, weak width, weak height, weak ratio] in
            !(name?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                && PageSizes.size(width: width?.stringValue ?? "", height: height?.stringValue ?? "") != nil
                && PageSizes.isPixelRatio(ratio?.stringValue ?? "")
        }) { confirmed in
            guard confirmed, let size = PageSizes.size(width: width.stringValue, height: height.stringValue) else { return }
            PageSizes.add(PageSizes.Size(name: name.stringValue, width: Int(size.width), height: Int(size.height), pixelRatio: PageSizes.pixelRatio(from: ratio.stringValue)))
        }
    }
}
