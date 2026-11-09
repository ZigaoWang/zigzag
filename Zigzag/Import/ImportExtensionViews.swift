import AppKit
import WebKit

/// Something in the Import window's list, measured at the width it will have.
protocol ImportListItem: NSView {
    func preferredHeight(for width: CGFloat) -> CGFloat
}

/// The extensions coming over, as one row under the browsers: getting them ready, adding each in turn, and at the
/// end what was added and what couldn't be, each with why.
final class ImportExtensionsRow: NSView, ImportListItem {
    enum State {
        case preparing(Int, of: Int)
        case adding(String, Int, of: Int)
        case finished(added: [String], failed: [ExtensionImport.Failure], declined: Bool)
    }

    var state = State.preparing(0, of: 0) { didSet { refresh() } }

    private let icon = NSImageView()
    private let name = Label(String(localized: "Extensions", comment: "Choice in the Import window: bring extensions over from the Chrome Web Store."),
                             font: Tokens.Font.body(.medium), color: Tokens.Color.textPrimary)
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let check = NSImageView()
    private let spinner = RibbonView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.image = Tokens.Symbol.image("puzzlepiece.extension", size: Tokens.TypeSize.title)
        icon.contentTintColor = Tokens.Color.icon
        icon.imageScaling = .scaleProportionallyDown
        detail.font = Tokens.Font.small()
        detail.textColor = Tokens.Color.textSecondary
        detail.isSelectable = false
        spinner.color = Brand.Theme.brand.accent
        [icon, name, detail, check, spinner].forEach { addSubview($0) }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    private var textX: CGFloat { Tokens.Space.x3 + Tokens.Space.x8 + Tokens.Space.x3 }

    func preferredHeight(for width: CGFloat) -> CGFloat {
        let textWidth = width - textX - Tokens.Space.x3 - Tokens.Space.x8
        let detailHeight = detail.stringValue.isEmpty ? 0 : ceil(detail.sizeThatFits(NSSize(width: textWidth, height: 800)).height)
        return max(Tokens.Space.x12 + Tokens.Space.x2, Tokens.Space.x3 + name.lineHeight + 2 + detailHeight + Tokens.Space.x3)
    }

    private func refresh() {
        spinner.stopLooping()
        spinner.isHidden = true
        check.isHidden = true
        switch state {
        case .preparing(let index, let total):
            detail.stringValue = String(localized: "Getting \(index + 1) of \(total) ready…",
                                        comment: "Import window, under Extensions while each is downloaded and checked before you're asked: which one, then how many.")
            spinner.isHidden = false
            spinner.startLooping()
        case .adding(let extensionName, let index, let total):
            detail.stringValue = String(localized: "Adding \(extensionName), \(index + 1) of \(total)…",
                                        comment: "Import window, under Extensions while they're added one at a time: the extension's name, which one, then how many.")
            spinner.isHidden = false
            spinner.startLooping()
        case .finished(let added, let failed, let declined):
            var lines: [String] = []
            if !added.isEmpty {
                lines.append(String(localized: "Added \(Words.list(added)).", comment: "Import window, under Extensions once they're added: their names, like “Dark Reader and Grammarly”."))
            } else if declined {
                lines.append(String(localized: "Didn’t add any extensions.", comment: "Import window, under Extensions after choosing Don’t Add."))
            }
            if !failed.isEmpty {
                lines.append(String(localized: "Couldn’t add these:", comment: "Import window, under Extensions, before the ones that couldn't be added, each on its own line with why."))
                lines += failed.map {
                    String(localized: "import.extension-failure", defaultValue: "\($0.found.name): \($0.reason)", comment: "Import window, one extension that couldn't be added: its name, then why, like “Not in the Chrome Web Store any more.”")
                }
            }
            detail.stringValue = lines.joined(separator: "\n")
            check.isHidden = false
            check.image = Tokens.Symbol.image(failed.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill", size: Tokens.TypeSize.title)
            check.contentTintColor = failed.isEmpty ? Tokens.Color.success : Tokens.Color.warning
        }
        superview?.needsLayout = true
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let pad = Tokens.Space.x3, side = Tokens.Space.x8
        icon.frame = NSRect(x: pad, y: pad, width: side, height: side)
        let textWidth = bounds.width - textX - pad - Tokens.Space.x8
        name.frame = NSRect(x: textX, y: pad, width: textWidth, height: name.lineHeight)
        detail.preferredMaxLayoutWidth = textWidth
        let detailHeight = ceil(detail.sizeThatFits(NSSize(width: textWidth, height: 800)).height)
        detail.frame = NSRect(x: textX, y: name.frame.maxY + 2, width: textWidth, height: detailHeight)
        let indicator = NSRect(x: bounds.width - pad - Tokens.Space.x5, y: pad + (side - Tokens.Space.x5) / 2, width: Tokens.Space.x5, height: Tokens.Space.x5)
        check.frame = indicator
        spinner.frame = indicator.insetBy(dx: 2, dy: 2)
    }
}

/// The one question before extensions from another browser are added: each by its icon and name, with what
/// won't work here, then what they'll be able to do together, in the install sheet's words.
final class ImportExtensionsReview: NSView, ImportListItem {
    private struct Item {
        let icon = NSImageView()
        let name: Label
        let limits: NSTextField?
    }

    private var items: [Item] = []
    private let heading: Label
    private var lines: [(NSImageView, NSTextField)] = []

    init(_ ready: [(ChromiumExtensions.Found, ExtensionStore.PreparedInstall)]) {
        heading = Label(ready.count == 1 ? String(localized: "It will be able to", comment: "Heading over the list of what an extension can do, in the sheet that asks before adding it.")
                                         : String(localized: "Together they’ll be able to", comment: "Import window, heading over what the extensions about to be added can do, all of them together."),
                        font: Tokens.Font.small(.medium), color: Tokens.Color.textSecondary)
        super.init(frame: .zero)
        for (found, prepared) in ready {
            let info = prepared.extensionInfo
            let name = Label(info.displayName ?? found.name, font: Tokens.Font.body(.medium), color: Tokens.Color.textPrimary)
            name.lineBreakMode = .byTruncatingTail
            var limits: NSTextField?
            if !prepared.report.limits.isEmpty {
                // As the install sheet says it, one sentence with the names in lower case.
                let names = prepared.report.limits.map { $0.prefix(1).lowercased() + $0.dropFirst() }
                let list = Words.list(names)
                let text = NSTextField(wrappingLabelWithString: String(localized: "Won’t work in Zigzag: \(list).",
                                                                       comment: "In the extension install sheet. The placeholder lists features the extension uses that Zigzag lacks, like “side panel and notifications”."))
                text.font = Tokens.Font.small()
                text.textColor = Tokens.Color.textSecondary
                text.isSelectable = false
                limits = text
            }
            let item = Item(name: name, limits: limits)
            if let image = info.icon(for: NSSize(width: 24, height: 24)) {
                item.icon.image = image
            } else {
                item.icon.image = Tokens.Symbol.image("puzzlepiece.extension")
                item.icon.contentTintColor = Tokens.Color.icon
            }
            item.icon.imageScaling = .scaleProportionallyUpOrDown
            [item.icon, item.name].forEach { addSubview($0) }
            if let limits { addSubview(limits) }
            items.append(item)
        }
        let report = ExtensionReport(combining: ready.map(\.1.report))
        if !report.abilities.isEmpty { addSubview(heading) }
        for line in report.abilities {
            let symbol = NSImageView(image: Tokens.Symbol.image(line.symbol))
            symbol.contentTintColor = Tokens.Color.icon
            let text = NSTextField(wrappingLabelWithString: line.text)
            text.font = Tokens.Font.body()
            text.textColor = Tokens.Color.textPrimary
            text.isSelectable = false
            addSubview(symbol)
            addSubview(text)
            lines.append((symbol, text))
        }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    func preferredHeight(for width: CGFloat) -> CGFloat { arrange(width: width, place: false) }

    override func layout() {
        super.layout()
        _ = arrange(width: bounds.width, place: true)
    }

    /// Top to bottom: the extensions, then what they can do. Returns the height it takes.
    private func arrange(width: CGFloat, place: Bool) -> CGFloat {
        func set(_ view: NSView, _ rect: NSRect) { if place { view.frame = rect } }
        let side: CGFloat = 24, textX = side + Tokens.Space.x3
        var y: CGFloat = Tokens.Space.x1
        for item in items {
            set(item.icon, NSRect(x: 0, y: y, width: side, height: side))
            let nameY = y + (side - item.name.lineHeight) / 2
            set(item.name, NSRect(x: textX, y: nameY, width: width - textX, height: item.name.lineHeight))
            var bottom = y + side
            if let limits = item.limits {
                limits.preferredMaxLayoutWidth = width - textX
                let h = ceil(limits.sizeThatFits(NSSize(width: width - textX, height: 200)).height)
                set(limits, NSRect(x: textX, y: nameY + item.name.lineHeight + 2, width: width - textX, height: h))
                bottom = max(bottom, nameY + item.name.lineHeight + 2 + h)
            }
            y = bottom + Tokens.Space.x3
        }
        guard !lines.isEmpty else { return y }
        y += Tokens.Space.x2
        set(heading, NSRect(x: 0, y: y, width: width, height: heading.lineHeight))
        y += heading.lineHeight + Tokens.Space.x2
        for (symbol, text) in lines {
            let textWidth = width - Tokens.Space.x6
            text.preferredMaxLayoutWidth = textWidth
            let h = ceil(text.sizeThatFits(NSSize(width: textWidth, height: 200)).height)
            // The symbol sits on the first line, however many lines the text takes.
            let firstLine = ceil(text.font?.boundingRectForFont.height ?? Tokens.Space.x4)
            set(symbol, NSRect(x: 0, y: y, width: Tokens.Space.x4, height: min(firstLine, h)))
            set(text, NSRect(x: Tokens.Space.x6, y: y, width: textWidth, height: h))
            y += h + Tokens.Space.x2
        }
        return y
    }
}
