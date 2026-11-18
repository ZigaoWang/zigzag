import JavaScriptCore
import Testing
@testable import Zigzag

/// The script that gives the Web Inspector Chrome's look: on by default, and a script that parses either way.
@MainActor
struct ChromeInspectorTests {
    private func withDefaults(_ body: () throws -> Void) rethrows {
        let suite = "ChromeInspectorTests-\(UUID().uuidString)"
        let saved = ChromeInspector.defaults
        ChromeInspector.defaults = UserDefaults(suiteName: suite)!
        defer {
            ChromeInspector.defaults.removePersistentDomain(forName: suite)
            ChromeInspector.defaults = saved
        }
        try body()
    }

    @Test func onUntilTurnedOff() {
        withDefaults {
            #expect(ChromeInspector.isOn)
            ChromeInspector.isOn = false
            #expect(!ChromeInspector.isOn)
            #expect(ChromeInspector.defaults.object(forKey: "InspectorLikeChrome") as? Bool == false)
        }
    }

    @Test(arguments: [true, false]) func scriptIsFilledInAndParses(on: Bool) throws {
        let source = ChromeInspector.source(on: on)
        #expect(source.hasPrefix(ChromeInspector.scriptMark))
        #expect(!source.contains("__CONFIG__") && !source.contains("__CSS__"))
        #expect(source.contains(on ? "{\"on\": true}" : "{\"on\": false}"))
        #expect(source.contains("--zz-accent"))
        // A syntax error would leave the inspector as WebKit has it, silently.
        let context = try #require(JSContext())
        context.setObject(source, forKeyedSubscript: "source" as NSString)
        context.evaluateScript("new Function(source)")
        #expect(context.exception == nil)
    }
}
