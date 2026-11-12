import AppKit
import Testing
@testable import Zigzag

/// Open on Your Phone (#141): the address a phone on the same network reaches the page at, and its QR code.
@MainActor
struct PhoneLinkTests {
    @Test func aPageOnThisMacIsGivenAtTheMacsNetworkAddress() {
        let page = URL(string: "http://localhost:5173/admin/users?tab=2#top")!
        #expect(PhoneLink.url(for: page, lanAddress: "192.168.1.20")?.absoluteString == "http://192.168.1.20:5173/admin/users?tab=2#top")
        #expect(PhoneLink.url(for: URL(string: "https://127.0.0.1:8443/")!, lanAddress: "10.0.0.7")?.absoluteString == "https://10.0.0.7:8443/")
        #expect(PhoneLink.url(for: URL(string: "http://app.localhost:3000/")!, lanAddress: "10.0.0.7")?.host() == "10.0.0.7")
        // No network address: nothing a phone could open.
        #expect(PhoneLink.url(for: page, lanAddress: nil) == nil)
    }

    @Test func anyOtherPageIsGivenAsItIs() {
        let lan = URL(string: "http://192.168.1.20:8080/")!
        #expect(PhoneLink.url(for: lan, lanAddress: "10.0.0.7") == lan)
        let staging = URL(string: "https://staging.example.com/")!
        #expect(PhoneLink.url(for: staging, lanAddress: nil) == staging)
        #expect(PhoneLink.url(for: URL(string: "file:///tmp/index.html")!, lanAddress: "10.0.0.7") == nil)
    }

    @Test func onlyAPrivateNetworksAddressIsGiven() {
        for address in ["10.1.2.3", "172.16.0.1", "172.31.255.1", "192.168.0.5"] { #expect(PhoneLink.isPrivate(address), "\(address)") }
        for address in ["172.32.0.1", "8.8.8.8", "169.254.1.1", "127.0.0.1", "fe80::1", "192.168.1"] { #expect(!PhoneLink.isPrivate(address), "\(address)") }
        // Wi-Fi or Ethernet before a VPN's or a virtual machine's bridge.
        #expect(PhoneLink.pick([("utun3", "10.8.0.2"), ("bridge100", "192.168.64.1"), ("en0", "192.168.1.20")]) == "192.168.1.20")
        #expect(PhoneLink.pick([("bridge100", "192.168.64.1"), ("utun3", "10.8.0.2")]) == "192.168.64.1")
        #expect(PhoneLink.pick([]) == nil)
        // Whatever this Mac has is one of those.
        if let mine = PhoneLink.lanAddress() { #expect(PhoneLink.isPrivate(mine)) }
    }

    @Test func theCodeIsSharpAndSquare() throws {
        let image = try #require(PhoneLink.qrImage(for: "http://192.168.1.20:5173/", side: PhoneLinkSheet.codeSide))
        #expect(image.size == NSSize(width: PhoneLinkSheet.codeSide, height: PhoneLinkSheet.codeSide))
        let pixels = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        // Drawn at twice the points or more, whole pixels per module, for a Retina screen.
        #expect(pixels.width >= Int(PhoneLinkSheet.codeSide) && pixels.width == pixels.height)
    }

    @Test func itsAToolOfADevelopmentPage() {
        #expect(DeveloperTool(commandID: DeveloperTool.phone.commandID) == .phone)
        #expect(DeveloperTool.menuItems.contains(.phone) && DeveloperBarTools.moreTools.contains(.phone))
        #expect(DeveloperTool.isOffered(.phone, isOn: true, isDevelopment: true, url: URL(string: "http://localhost:3000/"), isPrivate: true))
        #expect(!DeveloperTool.isOffered(.phone, isOn: true, isDevelopment: false, url: URL(string: "https://example.com/"), isPrivate: false))
    }
}
