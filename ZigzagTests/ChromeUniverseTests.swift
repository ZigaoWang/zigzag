import Foundation
import Testing
@testable import Zigzag

struct ChromeUniverseTests {
    @Test func storageAreasAreInTheUniverse() throws {
        let universe = try ChromeUniverse.load(bundle: .main)
        #expect(universe.contains("storage.local.get"))
        #expect(universe.contains("storage.sync.QUOTA_BYTES"))
        #expect(universe.contains("privacy.network.webRTCIPHandlingPolicy.get"))
    }
}
