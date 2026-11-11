import Foundation
import JavaScriptCore
import Testing
@testable import Zigzag

/// A background with a companion app connected stays running, as in Chrome. WebKit stops one whose ports have been
/// quiet for two minutes, and with it the app's helper: iCloud Passwords in a profile you'd left lost its pairing and
/// asked for a new code.
@MainActor
struct NativeKeepAliveTests {
    /// The background opens a port to Zigzag as it starts and answers every beat on it: the answer is what WebKit
    /// counts as the background being busy.
    @Test func backgroundAnswersEachBeat() throws {
        let context = JSContext()!
        context.evaluateScript("""
        var __ports = [];
        function Port(name) {
          this.name = name; this.listeners = []; this.sent = [];
          this.onMessage = { addListener: (f) => this.listeners.push(f) };
          this.postMessage = (m) => this.sent.push(m);
          this.receive = (m) => this.listeners.forEach((f) => f(m));
          __ports.push(this);
        }
        var chrome = { runtime: { connectNative: (name) => new Port(name) } };
        \(ExtensionShims.nativeKeepAlive)
        """)
        #expect(context.exception == nil)
        #expect(context.evaluateScript("__ports.map((p) => p.name).join()")?.toString() == ExtensionShims.keepAliveHost)
        #expect(context.evaluateScript("__ports[0].sent.length")?.toInt32() == 0)
        context.evaluateScript("__ports[0].receive(1); __ports[0].receive(1)")
        #expect(context.evaluateScript("__ports[0].sent.length")?.toInt32() == 2)
    }

    /// Without the API (a page that can't message apps) it stays out of the way.
    @Test func keepAliveNeedsNoAPI() {
        let context = JSContext()!
        context.evaluateScript("var chrome = {};\n\(ExtensionShims.nativeKeepAlive)")
        #expect(context.exception == nil)
    }

    /// Beats come well inside WebKit's two quiet minutes.
    @Test func beatsComeBeforeWebKitStopsTheBackground() {
        guard #available(macOS 15.4, *) else { return }
        #expect(NativeMessagingHost.keepAwakeInterval < 120 / 2)
    }

    /// Every service-worker background gets it.
    @Test func everyBackgroundPreludeKeepsAwake() throws {
        for id in ["pejdijmoenmkgeppbflobdenhhabjlaj", ExtensionStore.onePasswordID] {
            let prelude = try #require(ExtensionShims.shim(for: id)?.backgroundPrelude)
            #expect(prelude.contains(ExtensionShims.nativeKeepAlive))
        }
    }

    /// A background that starts again opens its new port before WebKit says the old one closed; that late word
    /// leaves the new one in place. Each profile keeps its own, so two copies of an extension never share one.
    @Test func lateCloseOfAnOldPortKeepsTheNewOne() {
        final class Port {}
        var ports = KeepAlivePorts<Port>()
        let old = Port(), new = Port(), other = Port()
        ports.opened(old, for: "a")
        ports.opened(other, for: "b")
        ports.opened(new, for: "a")
        ports.closed(old, for: "a")
        #expect(ports.port(for: "a") === new)
        #expect(ports.port(for: "b") === other)
        ports.closed(new, for: "a")
        #expect(ports.port(for: "a") == nil)
    }
}
