import Foundation
import Testing
@testable import Zigzag

@MainActor
struct InPageMiniPolicyTests {
    @Test func theSettingIsOffUntilTurnedOn() {
        let name = "InPageMiniPolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removeScratchSuite(name) }
        #expect(InPageMiniSettings.isEnabled(in: defaults) == false)
        InPageMiniSettings.setEnabled(true, in: defaults)
        #expect(InPageMiniSettings.isEnabled(in: defaults))
        InPageMiniSettings.setEnabled(false, in: defaults)
        #expect(InPageMiniSettings.isEnabled(in: defaults) == false)
    }

    @Test func docksOnlyInAFrontWindow() {
        func dock(enabled: Bool = true, key: Bool = true, visible: Bool = true,
                  mini: Bool = false, space: Bool = true) -> Bool {
            InPageMiniPolicy.shouldDock(enabled: enabled, windowIsKey: key, windowIsVisible: visible,
                                        windowIsMiniaturized: mini, windowIsOnActiveSpace: space)
        }
        #expect(dock())
        #expect(!dock(enabled: false))
        #expect(!dock(key: false))
        #expect(!dock(visible: false))
        #expect(!dock(mini: true))
        #expect(!dock(space: false))
    }
}
