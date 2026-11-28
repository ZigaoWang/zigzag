import AppKit
import Foundation
import Testing
import WebKit
@testable import Zigzag

/// The camera and the microphone as two switches (#545): each device the page uses has a button of its own, and a
/// click silences that device without ending the call.
@MainActor
@Suite(.serialized)
struct CaptureToggleTests {
    @Test func mutingIsNotStopping() {
        // Muted is still in use: the page keeps its device, so the button stays to pick it up again.
        #expect(CaptureToggle.shows(.active))
        #expect(CaptureToggle.shows(.muted))
        #expect(!CaptureToggle.shows(.none))
        #expect(CaptureToggle.isMuted(.muted))
        #expect(!CaptureToggle.isMuted(.active))
        #expect(!CaptureToggle.isMuted(.none))
    }
}

/// The address bar's side of it: one button per device, pressed while the page has it and slashed while it's muted.
@MainActor
struct AddressCaptureTests {
    private func address() -> AddressView {
        AddressView(frame: NSRect(x: 0, y: 0, width: 400, height: Tokens.Sidebar.addressHeight))
    }

    @Test func eachDeviceHasItsOwnButton() {
        let address = address()
        address.setCapture(camera: true, microphone: true)
        #expect(!address.cameraButton.isHidden)
        #expect(!address.microphoneButton.isHidden)
        #expect(address.cameraButton.symbol == "video.fill")
        #expect(address.microphoneButton.symbol == "mic.fill")
        #expect(address.cameraButton.isSelected && address.microphoneButton.isSelected)
        #expect(address.cameraButton.toolTip?.hasPrefix("Camera") == true)
        #expect(address.microphoneButton.toolTip?.hasPrefix("Microphone") == true)
        #expect(address.cameraButton.accessibilityLabel() == "Camera")
        #expect(address.microphoneButton.accessibilityLabel() == "Microphone")
    }

    @Test func aMutedDeviceShowsASlashAndStaysInTheBar() {
        let address = address()
        address.setCapture(camera: true, microphone: true, cameraMuted: true, microphoneMuted: true)
        // Muted is not gone: the button is still there, and one click turns the device back on.
        #expect(!address.cameraButton.isHidden && !address.microphoneButton.isHidden)
        #expect(address.cameraButton.symbol == "video.slash")
        #expect(address.microphoneButton.symbol == "mic.slash")
        #expect(!address.cameraButton.isSelected && !address.microphoneButton.isSelected)
        #expect(address.cameraButton.toolTip == "Camera Muted")
        #expect(address.microphoneButton.toolTip == "Microphone Muted")
    }

    @Test func oneDeviceTakesOneButtonsRoom() {
        let address = address()
        let none = address.buttonsWidth
        address.setCapture(camera: true, microphone: false)
        let cameraOnly = address.buttonsWidth
        address.setCapture(camera: true, microphone: true)
        #expect(cameraOnly == none + AddressView.buttonSide + 2)
        #expect(address.buttonsWidth == none + (AddressView.buttonSide + 2) * 2)
    }
}

/// A tab row says when its page holds a device, so a call running in another tab isn't invisible.
@MainActor
struct RowCaptureDotTests {
    private func row(_ tab: Tab) -> TabRowView {
        let row = TabRowView(frame: NSRect(x: 0, y: 0, width: 240, height: Tokens.Sidebar.rowHeight))
        row.configure(tab: tab)
        row.layoutSubtreeIfNeeded()
        return row
    }

    @Test func aTabHoldingADeviceSaysSo() {
        let tab = Tab(url: nil, title: "Call", spaceID: UUID())
        let row = row(tab)
        #expect(!row.showsCapture)
        tab.debugShowCapture(camera: .active)
        row.layoutSubtreeIfNeeded()
        #expect(row.showsCapture)
        tab.debugShowCapture()
        row.layoutSubtreeIfNeeded()
        #expect(!row.showsCapture)
    }

    @Test func aMutedDeviceStillCounts() {
        let tab = Tab(url: nil, title: "Call", spaceID: UUID())
        // Muting a device doesn't stop the page holding it, so the row still says a device is live.
        tab.debugShowCapture(camera: .muted)
        let row = row(tab)
        #expect(row.showsCapture)
        #expect(tab.isUsingCamera && tab.isCameraMuted && tab.holdsCapture)
    }
}
