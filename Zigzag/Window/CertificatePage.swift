import AppKit

/// Site Controls' certificate page, in the panel in place of the rest, under the panel's own header for it (a way back
/// and its title, which stay put while the page scrolls): whether macOS trusts the connection, the chain from the
/// site's certificate to the root (each one a row; the chosen one is shown below), and the chosen certificate's
/// issuer, validity, key and SHA-256 fingerprint. Plain rows and quiet labels, as the panel.
final class CertificatePage: NSView {
    /// Its height changed: another certificate of the chain was chosen, or the details came.
    var onResize: (() -> Void)?
    var details: CertificateDetails? {
        didSet {
            selected = 0
            rebuild()
        }
    }
    private var selected = 0

    static let title = String(localized: "Certificate", comment: "Title of the site panel's page about the site's certificate.")
    private let trustIcon = NSImageView()
    private let trust = Label("", font: Tokens.Font.body(), color: Tokens.Color.textPrimary)
    /// Why macOS doesn't trust it, in its own words.
    private let failure = CertificatePage.wrapping(Tokens.Font.small(), color: Tokens.Color.textSecondary)
    private let chainLabel = Label.section(String(localized: "Chain", comment: "Section label over the certificates from the site's up to the root, on the certificate page of the site panel."))
    private var chainRows: [ChainRow] = []
    private var fields: [(name: Label, value: Label)] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        trustIcon.imageScaling = .scaleNone
        [trustIcon, trust, failure, chainLabel].forEach { addSubview($0) }
        trust.stringValue = String(localized: "Checking…", comment: "On the certificate page of the site panel, while the certificate is read.")
        trust.textColor = Tokens.Color.textSecondary
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(Self.title)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    private static func wrapping(_ font: NSFont, color: NSColor) -> Label {
        let label = Label("", font: font, color: color)
        label.usesSingleLineMode = false
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.cell?.wraps = true
        label.cell?.truncatesLastVisibleLine = false
        return label
    }

    private static let dates: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private func rebuild() {
        chainRows.forEach { $0.removeFromSuperview() }
        guard let details else { return }
        trust.textColor = Tokens.Color.textPrimary
        trust.stringValue = details.isTrusted
            ? String(localized: "Certificate is valid", comment: "On the certificate page of the site panel: macOS trusts the site's certificate.")
            : String(localized: "Certificate isn’t trusted", comment: "On the certificate page of the site panel: macOS doesn't trust the site's certificate.")
        trustIcon.image = Tokens.Symbol.image(details.isTrusted ? "checkmark.seal" : "exclamationmark.triangle", size: Tokens.Symbol.row)
        trustIcon.contentTintColor = details.isTrusted ? Tokens.Color.icon : Tokens.Color.warning
        failure.stringValue = details.failure ?? ""
        failure.isHidden = details.failure == nil
        chainRows = details.chain.indices.map { index in
            let row = ChainRow(name: details.chain[index].name, role: Self.name(of: details.role(at: index)))
            row.onClick = { [weak self] _ in self?.choose(index) }
            addSubview(row)
            return row
        }
        chainLabel.isHidden = chainRows.isEmpty
        choose(0)
    }

    private static func name(of role: CertificateDetails.Role) -> String {
        switch role {
        case .site: String(localized: "Site", comment: "Beside the site's own certificate in the chain on the certificate page of the site panel.")
        case .intermediate: String(localized: "Intermediate", comment: "Beside a certificate between the site's and the root in the chain on the certificate page of the site panel.")
        case .root: String(localized: "Root", comment: "Beside the root certificate, the one macOS trusts, in the chain on the certificate page of the site panel.")
        }
    }

    /// Shows one certificate of the chain below it.
    private func choose(_ index: Int) {
        guard let details, details.chain.indices.contains(index) else { return }
        selected = index
        for (i, row) in chainRows.enumerated() { row.isSelected = i == index }
        fields.forEach { $0.name.removeFromSuperview(); $0.value.removeFromSuperview() }
        let certificate = details.chain[index]
        var pairs: [(String, String)] = []
        pairs.append((String(localized: "Issued to", comment: "On the certificate page of the site panel: whom the certificate was issued to."),
                      [certificate.name, certificate.organization].compactMap { $0 }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: "\n")))
        if let issuer = certificate.issuer {
            pairs.append((String(localized: "Issued by", comment: "On the certificate page of the site panel: who issued the certificate."), issuer))
        }
        if let from = certificate.validFrom {
            pairs.append((String(localized: "Valid from", comment: "On the certificate page of the site panel: the first day the certificate is valid."), Self.dates.string(from: from)))
        }
        if let until = certificate.validUntil {
            pairs.append((String(localized: "Valid until", comment: "On the certificate page of the site panel: the last day the certificate is valid."), Self.dates.string(from: until)))
        }
        if let type = certificate.keyType {
            let key = certificate.keyBits.map { String(localized: "\(type) \($0)-bit", comment: "A certificate's public key on the certificate page of the site panel: its type, then its size in bits, like “RSA 2048-bit”.") } ?? type
            pairs.append((String(localized: "Public key", comment: "On the certificate page of the site panel: the certificate's public key."), key))
        }
        pairs.append(("SHA-256", certificate.sha256))
        fields = pairs.map { name, value in
            let nameLabel = Label(name, font: Tokens.Font.small(), color: Tokens.Color.textTertiary)
            let valueLabel = Self.wrapping(Tokens.Font.body(), color: Tokens.Color.textPrimary)
            if name == "SHA-256" {
                // Pairs of figures, broken anywhere: it reads as a block, not a line cut short.
                valueLabel.font = Tokens.Font.small()
                valueLabel.lineBreakMode = .byCharWrapping
            }
            valueLabel.stringValue = value
            addSubview(nameLabel)
            addSubview(valueLabel)
            return (nameLabel, valueLabel)
        }
        needsLayout = true
        onResize?()
    }

    private func wrappedHeight(_ label: Label, width: CGFloat) -> CGFloat {
        ceil(label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 10_000)).height ?? label.lineHeight)
    }

    /// How tall it is at `width`, with the panel's padding at its sides and bottom; its top is under the header.
    func height(for width: CGFloat, pad: CGFloat) -> CGFloat { arrange(width: width, pad: pad, apply: false) }

    private var pad: CGFloat = Tokens.Space.x4

    override func layout() {
        super.layout()
        _ = arrange(width: bounds.width, pad: pad, apply: true)
    }

    @discardableResult
    private func arrange(width: CGFloat, pad: CGFloat, apply: Bool) -> CGFloat {
        if !apply { self.pad = pad }
        func place(_ view: NSView, _ rect: NSRect) { if apply { view.frame = rect } }
        let inner = width - pad * 2
        var y: CGFloat = 0
        let iconSide = Tokens.Metric.favicon
        place(trustIcon, NSRect(x: pad, y: y + (trust.lineHeight - iconSide) / 2, width: iconSide, height: iconSide))
        let trustX = pad + iconSide + Tokens.Space.x2
        place(trust, NSRect(x: trustX - Label.inset, y: y, width: width - pad - trustX + Label.inset * 2, height: trust.lineHeight))
        y += trust.lineHeight
        if !failure.isHidden {
            let w = width - pad - trustX
            let h = wrappedHeight(failure, width: w + Label.inset * 2)
            y += 2
            place(failure, NSRect(x: trustX - Label.inset, y: y, width: w + Label.inset * 2, height: h))
            y += h
        }

        if !chainRows.isEmpty {
            y += Tokens.Space.x5
            place(chainLabel, NSRect(x: pad - Label.inset, y: y, width: inner + Label.inset * 2, height: chainLabel.lineHeight))
            y += chainLabel.lineHeight + Tokens.Space.x2
            // A little room between rows, as the sidebar's have, so the chosen one's fill and the hovered one's never touch.
            for (i, row) in chainRows.enumerated() {
                if i > 0 { y += PanelLinkRow.gap }
                place(row, NSRect(x: pad - PanelLinkRow.outset, y: y, width: inner + PanelLinkRow.outset * 2, height: ChainRow.height))
                y += ChainRow.height
            }
        }
        if !fields.isEmpty {
            y += Tokens.Space.x4
            for (i, field) in fields.enumerated() {
                if i > 0 { y += Tokens.Space.x3 }
                place(field.name, NSRect(x: pad - Label.inset, y: y, width: inner + Label.inset * 2, height: field.name.lineHeight))
                y += field.name.lineHeight + 2
                let h = wrappedHeight(field.value, width: inner + Label.inset * 2)
                place(field.value, NSRect(x: pad - Label.inset, y: y, width: inner + Label.inset * 2, height: h))
                y += h
            }
        }
        return y + pad
    }

    #if DEBUG
    var debugState: [String: Any] {
        ["trust": trust.stringValue, "chain": chainRows.map(\.debugName), "fields": fields.map { "\($0.name.stringValue): \($0.value.stringValue)" }]
    }

    /// A certificate of the chain chosen, as a click on its row.
    func debugChoose(_ index: Int) { choose(index) }
    #endif
}

/// One certificate in the chain: its name, and what it is at the end.
private final class ChainRow: InteractiveView {
    static let height = Tokens.Page.rowHeight
    private let name: Label
    private let role: Label

    init(name text: String, role roleText: String) {
        name = Label(text, font: Tokens.Font.body(), color: Tokens.Color.textPrimary)
        name.lineBreakMode = .byTruncatingMiddle
        role = Label(roleText, font: Tokens.Font.small(), color: Tokens.Color.textTertiary)
        super.init(frame: .zero)
        pressScales = true
        layer?.cornerRadius = Tokens.Radius.row
        layer?.cornerCurve = .continuous
        [name, role].forEach { addSubview($0) }
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(text), \(roleText)")
        stateDidChange(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    var debugName: String { "\(name.stringValue) (\(role.stringValue))\(isSelected ? " *" : "")" }

    override func layout() {
        super.layout()
        let outset = PanelLinkRow.outset
        let roleWidth = role.textWidth
        role.frame = NSRect(x: bounds.width - outset - roleWidth + Label.inset, y: (bounds.height - role.lineHeight) / 2, width: roleWidth, height: role.lineHeight)
        let x = outset
        name.frame = NSRect(x: x - Label.inset, y: (bounds.height - name.lineHeight) / 2, width: max(0, role.frame.minX - Tokens.Space.x2 - x + Label.inset * 2), height: name.lineHeight)
    }

    override func stateDidChange(animated: Bool) { applyRowStyle(animated: animated) }
}
