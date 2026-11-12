import AppKit
import CoreImage

/// Open on Your Phone (#141): the development page's address as a phone on the same network reaches it, and a QR code
/// of it to point the phone's camera at. A page on this Mac (localhost, 127.0.0.1) is reached at the Mac's address on
/// the network, with the same port, path and query; any other address is the phone's to reach as it is.
enum PhoneLink {
    /// The Mac's IPv4 address on its local network: Wi-Fi or Ethernet first (`en*`), on a private range, the
    /// interface up and not a loopback. Nil with no network a phone could share.
    static func lanAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var found: [(name: String, address: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            if isPrivate(text) { found.append((String(cString: entry.ifa_name), text)) }
        }
        return pick(found)
    }

    /// The address to give: Wi-Fi or Ethernet before anything else (a VPN's, a virtual machine's bridge), then by name.
    static func pick(_ found: [(name: String, address: String)]) -> String? {
        found.sorted { a, b in
            let ea = a.name.hasPrefix("en"), eb = b.name.hasPrefix("en")
            return ea != eb ? ea : a.name < b.name
        }.first?.address
    }

    /// An address on a private network (10/8, 172.16/12, 192.168/16): one a phone on the same Wi-Fi can reach.
    static func isPrivate(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (10, _), (192, 168): return true
        case (172, let b): return (16...31).contains(b)
        default: return false
        }
    }

    /// The page's address for a phone: a page on this Mac at `lanAddress` instead, everything else as it is. Nil for
    /// a page on this Mac when there's no network address to give.
    static func url(for page: URL, lanAddress: String?) -> URL? {
        guard ["http", "https"].contains(page.scheme?.lowercased() ?? "") else { return nil }
        guard ErrorPage.isOnThisMac(page) else { return page }
        guard let lanAddress, var parts = URLComponents(url: page, resolvingAgainstBaseURL: false) else { return nil }
        parts.host = lanAddress
        return parts.url
    }

    /// A QR code of `text`, `side` points square, its modules sharp: drawn without smoothing, with a quiet zone.
    static func qrImage(for text: String, side: CGFloat) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let code = filter.outputImage, code.extent.width > 0 else { return nil }
        let scale = max(1, floor(side * 2 / code.extent.width))
        let scaled = code.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: side, height: side))
    }
}

/// The sheet Open on Your Phone shows: the QR code, the address under it, and what the server needs.
enum PhoneLinkSheet {
    static let codeSide: CGFloat = 184

    @discardableResult
    static func show(in host: NSView, url: URL, onCopy: @escaping () -> Void) -> FormSheet {
        let code = NSImageView()
        code.image = PhoneLink.qrImage(for: url.absoluteString, side: codeSide)
        code.imageScaling = .scaleNone
        code.imageAlignment = .alignCenter
        code.setAccessibilityLabel(String(localized: "QR code of the address", comment: "VoiceOver name of the QR code in the Open on Your Phone sheet of the developer tools."))
        let address = NSTextField(labelWithString: url.absoluteString)
        address.font = Tokens.Font.figures(Tokens.TypeSize.body)
        address.textColor = Tokens.Color.textPrimary
        address.alignment = .center
        address.isSelectable = true
        address.lineBreakMode = .byTruncatingMiddle
        let note = String(localized: "Your phone needs to be on the same network as this Mac, and your development server needs to listen on it too, not only on localhost (for most, a host of 0.0.0.0).",
                          comment: "Under the address in the Open on Your Phone sheet of the developer tools. 0.0.0.0 is a server setting, kept as is.")
        return FormSheet.show(in: host, title: String(localized: "Open on Your Phone", comment: "Title of the developer tools' sheet with a QR code of the page's address for a phone on the same network."),
                              symbol: "qrcode",
                              message: String(localized: "Point your phone's camera at the code to open this page there.", comment: "Under the title of the Open on Your Phone sheet of the developer tools."),
                              rows: [FormSheet.Row(label: nil, view: code, height: codeSide + Tokens.Space.x2), FormSheet.Row(label: nil, view: address), .note(note)],
                              confirmTitle: String(localized: "Copy Address", comment: "Button in the Open on Your Phone sheet of the developer tools: copies the page's address for a phone.")) { confirmed in
            guard confirmed else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
            onCopy()
        }
    }
}
