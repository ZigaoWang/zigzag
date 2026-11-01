import Foundation
import Testing
@testable import Zigzag

/// A failed save says why when it's something you can fix, and stays short when it isn't.
struct SaveFailureTests {
    @Test func commonReasons() {
        #expect(SaveFailure.reason(for: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)) == "Not enough space on your Mac")
        #expect(SaveFailure.reason(for: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)) == "Zigzag isn’t allowed to save in that folder")
        #expect(SaveFailure.reason(for: NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY))) == "Another app is using the file")
        #expect(SaveFailure.reason(for: NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS))) == "That disk can’t be written to")
    }

    @Test func theReasonBeneath() {
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [NSUnderlyingErrorKey: underlying])
        #expect(SaveFailure.message("Couldn’t save the page", error) == "Couldn’t save the page. Not enough space on your Mac")
    }

    @Test func nothingUsefulToSay() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError)
        #expect(SaveFailure.reason(for: error) == nil)
        #expect(SaveFailure.message("Couldn’t save the PDF", error) == "Couldn’t save the PDF")
    }
}
