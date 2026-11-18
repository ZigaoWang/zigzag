import Foundation
import JavaScriptCore
import Testing
@testable import Zigzag

/// ConnectGuard, which throttles content scripts reconnecting in a loop, on a fake clock against a stand-in `chrome.runtime`.
struct ExtensionStormTests {
    /// The guard on a stand-in runtime. `connects` counts connects; `ports` holds them with `close()`; with `turnAway` set the background closes each port right after opening.
    private func world() throws -> JSContext {
        let context = try #require(JSContext())
        context.exceptionHandler = { _, value in Issue.record("JavaScript: \(value?.toString() ?? "?")") }
        context.evaluateScript("""
        var t = 0, timers = [], reports = [], connects = 0, ports = [], turnAway = false;
        var later = (f, ms) => timers.push({ at: t + Math.max(0, ms || 0), f });
        // Runs every timer due within `ms`, in order, moving the clock to each.
        var advance = (ms) => {
          const end = t + ms;
          for (;;) {
            timers.sort((a, b) => a.at - b.at);
            const next = timers[0];
            if (!next || next.at > end) break;
            timers.shift();
            t = Math.max(t, next.at);
            next.f();
          }
          t = end;
        };
        var runtime = {
          connect(info) {
            connects++;
            const gone = [], messages = [];
            const port = {
              name: info && info.name, sent: [], open: true,
              onMessage: { addListener: (f) => messages.push(f), removeListener: () => {} },
              onDisconnect: { addListener: (f) => gone.push(f), removeListener: () => {} },
              postMessage(m) { port.sent.push(m); },
              disconnect() { port.open = false; },
              close() { if (!port.open) return; port.open = false; gone.forEach((f) => f(port)); },
              say(m) { messages.forEach((f) => f(m, port)); },
            };
            ports.push(port);
            if (turnAway) later(() => port.close(), 1);
            return port;
          },
        };
        """)
        context.evaluateScript(ConnectGuard.source)
        context.evaluateScript("var guard = __zigzagConnectGuard(runtime, () => t, later, (r) => reports.push(r));")
        return context
    }

    private func number(_ context: JSContext, _ script: String) -> Int {
        Int(context.evaluateScript(script)?.toInt32() ?? -1)
    }

    /// Sound Booster's store sync loop: reopens the port as soon as the background closes it.
    private let loop = """
    var reconnects = 0;
    turnAway = true;
    function connectBackground() {
      const port = runtime.connect({ name: 'sync_' + reconnects });
      port.onDisconnect.addListener(() => { reconnects++; connectBackground(); });
    }
    connectBackground();
    """

    @Test func aReconnectLoopIsHeldBackAndSaidOnce() throws {
        let context = try world()
        context.evaluateScript(loop)
        // 1000/s still passes for the first seconds, like a short burst.
        context.evaluateScript("advance(3000)")
        #expect(context.evaluateScript("guard.isHeld()")?.toBool() == false)
        #expect(number(context, "connects") > 2500)
        context.evaluateScript("advance(3000)")
        #expect(context.evaluateScript("guard.isHeld()")?.toBool() == true)
        #expect(number(context, "reports.length") == 1)
        #expect(context.evaluateScript("reports[0].kind")?.toString() == "connect")
        #expect(number(context, "reports[0].perSecond") > ConnectGuard.perSecond)
        // Throttled: a handful per minute, backing off up to the max wait.
        let before = number(context, "connects")
        context.evaluateScript("advance(60000)")
        let during = number(context, "connects") - before
        #expect(during >= 3 && during <= 10)
        #expect(number(context, "guard.gap()") == ConnectGuard.maxGap)
        // The loop still runs, slowly; logged once.
        #expect(number(context, "guard.waiting()") == 1)
        context.evaluateScript("advance(120000)")
        #expect(number(context, "reports.length") == 1)
    }

    @Test func normalRatesAreLeftAlone() throws {
        let context = try world()
        // 40/s for 30 s (many frames, Tampermonkey): under the limit, all pass through as real ports.
        context.evaluateScript("""
        var same = 0;
        for (let i = 0; i < 1200; i++) { const p = runtime.connect({ name: 'n' + i }); if (p === ports[ports.length - 1]) same++; advance(25); }
        """)
        #expect(number(context, "same") == 1200)
        #expect(number(context, "connects") == 1200)
        #expect(context.evaluateScript("guard.isHeld()")?.toBool() == false)
        #expect(number(context, "reports.length") == 0)
    }

    @Test func aShortBurstIsLeftAlone() throws {
        let context = try world()
        // 500 at once, a few quiet seconds, then another: never 5 s straight over the limit.
        context.evaluateScript("""
        for (let round = 0; round < 4; round++) {
          for (let i = 0; i < 500; i++) runtime.connect({ name: 'b' });
          advance(3000);
        }
        """)
        #expect(context.evaluateScript("guard.isHeld()")?.toBool() == false)
        #expect(number(context, "connects") == 2000)
        #expect(number(context, "reports.length") == 0)
    }

    @Test func aHeldPortStillCarriesMessagesBothWays() throws {
        let context = try world()
        context.evaluateScript(loop)
        context.evaluateScript("advance(6000)")
        #expect(context.evaluateScript("guard.isHeld()")?.toBool() == true)
        // The background keeps ports now.
        context.evaluateScript("""
        turnAway = false;
        var heard = [], closed = 0;
        var port = runtime.connect({ name: 'settled' });
        port.onMessage.addListener((m, p) => heard.push([m, p === port]));
        port.onDisconnect.addListener((p) => { closed++; });
        port.postMessage('early');
        """)
        #expect(context.evaluateScript("port.name")?.toString() == "settled")
        // Not through yet; queued messages wait.
        context.evaluateScript("advance(70000)")
        let real = "ports.find((p) => p.name === 'settled')"
        #expect(context.evaluateScript("\(real).sent[0]")?.toString() == "early")
        context.evaluateScript("\(real).say('hello')")
        #expect(context.evaluateScript("heard[0][0]")?.toString() == "hello")
        #expect(context.evaluateScript("heard[0][1]")?.toBool() == true)
        context.evaluateScript("port.postMessage('later')")
        #expect(context.evaluateScript("\(real).sent[1]")?.toString() == "later")
        context.evaluateScript("\(real).close()")
        #expect(number(context, "closed") == 1)
    }

    @Test func aPortThatStaysOpenEndsTheHoldingBack() throws {
        let context = try world()
        context.evaluateScript(loop)
        context.evaluateScript("advance(6000)")
        #expect(context.evaluateScript("guard.isHeld()")?.toBool() == true)
        // The background starts keeping ports: the next one passed stays open.
        context.evaluateScript("turnAway = false; advance(40000)")
        context.evaluateScript("advance(\(ConnectGuard.calm))")
        // After 10 s, new connects pass immediately.
        context.evaluateScript("var fresh = runtime.connect({ name: 'fresh' });")
        #expect(context.evaluateScript("fresh === ports[ports.length - 1]")?.toBool() == true)
        #expect(context.evaluateScript("guard.isHeld()")?.toBool() == false)
    }

    @Test func eachRuntimeIsGuardedOnce() throws {
        let context = try world()
        // The file runs once per manifest entry; a second install is a no-op.
        #expect(context.evaluateScript("__zigzagConnectGuard(runtime, () => t, later, () => {})")?.isNull == true)
        #expect(context.evaluateScript("runtime.connect.__zigzagGuard")?.toBool() == true)
    }

    @Test func theGuardRunsFirstInTheExtensionsOwnWorld() {
        let entries: [[String: Any]] = [
            ["matches": ["<all_urls>"], "js": ["content.js"], "all_frames": true],
            ["matches": ["<all_urls>"], "js": ["page.js"], "world": "MAIN"],
            ["matches": ["<all_urls>"], "css": ["look.css"]],
            ["matches": ["<all_urls>"], "js": [ConnectGuard.file, "again.js"]],
        ]
        let guarded = ConnectGuard.guarding(entries)
        #expect(guarded[0]["js"] as? [String] == [ConnectGuard.file, "content.js"])
        #expect(guarded[0]["all_frames"] as? Bool == true)
        #expect(guarded[1]["js"] as? [String] == ["page.js"])
        #expect(guarded[2]["js"] == nil)
        #expect(guarded[3]["js"] as? [String] == [ConnectGuard.file, "again.js"])
    }

    @Test func sitesTurnedOffStayInTheirProfile() {
        var state = ExtensionInstalls.State()
        state.offSites = ["youtube.com"]
        #expect(state.carried(enabled: true).offSites == nil)
    }
}
