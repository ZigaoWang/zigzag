import Foundation
import JavaScriptCore
import Testing
@testable import Zigzag

/// The palette script's own pieces (#134), run in JavaScriptCore as the page runs them: colors in and out of OKLCH,
/// contrast, the mapping, rewriting values and selectors, reading rules shaped like the CSSOM's, and the fingerprint.
@MainActor
struct DarkPaletteScriptTests {
    private func context() throws -> JSContext {
        let context = try #require(JSContext())
        let source = DarkPages.resource("dark-palette").trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!source.isEmpty)
        context.evaluateScript("var P = " + source + ";")
        #expect(context.exception == nil, "\(String(describing: context.exception))")
        return context
    }

    private func run(_ context: JSContext, _ js: String) -> JSValue {
        let value = context.evaluateScript(js)!
        #expect(context.exception == nil, "\(js): \(String(describing: context.exception))")
        return value
    }

    private func mapped(_ context: JSContext, _ color: String, _ role: String, black: Bool = false) -> String {
        run(context, "P.format(P.map(P.parse('\(color)'), '\(role)', \(black)))").toString()
    }

    @Test func colorsAreReadEveryCommonWay() throws {
        let c = try context()
        for (text, rgba) in [("#fff", "255,255,255,1"), ("#0969da", "9,105,218,1"), ("#00000080", "0,0,0,0.502"),
                             ("rgb(1, 2, 3)", "1,2,3,1"), ("rgba(1 2 3 / 50%)", "1,2,3,0.5"), ("hsl(0, 100%, 50%)", "255,0,0,1"),
                             ("white", "255,255,255,1")] {
            let parsed = run(c, "P.parse('\(text)').map((v) => Math.round(v * 1000) / 1000).join(',')").toString()
            #expect(parsed == rgba, "\(text)")
        }
        for text in ["var(--x)", "currentcolor", "inherit", "oklch(0.5 0.1 200)", ""] {
            #expect(run(c, "P.parse('\(text)') === null").toBool(), "\(text)")
        }
    }

    /// Known OKLCH values, and back again.
    @Test func oklchRoundTrips() throws {
        let c = try context()
        let red = run(c, "P.toOklch([255, 0, 0])").toArray() as? [Double] ?? []
        #expect(abs(red[0] - 0.628) < 0.001 && abs(red[1] - 0.2577) < 0.001 && abs(red[2] - 29.23) < 0.05)
        #expect(abs((run(c, "P.toOklch([255, 255, 255])[0]").toDouble()) - 1) < 0.0001)
        #expect(run(c, "P.toOklch([0, 0, 0])[0]").toDouble() < 0.0001)
        for color in ["[9, 105, 218]", "[31, 136, 61]", "[246, 248, 250]", "[128, 0, 128]"] {
            let back = run(c, "(() => { const o = P.toOklch(\(color)); return P.fromOklch(o[0], o[1], o[2]).map(Math.round).join(','); })()").toString()
            #expect("[" + (back ?? "") + "]" == color.replacingOccurrences(of: " ", with: ""))
        }
        // Out of gamut: chroma comes down, lightness and hue stay.
        let fitted = run(c, "(() => { const f = P.fromOklch(0.9, 0.4, 260); return f.every((v) => v >= 0 && v <= 255) && Math.abs(P.toOklch(f)[0] - 0.9) < 0.01; })()").toBool()
        #expect(fitted)
    }

    @Test func contrastIsWCAGs() throws {
        let c = try context()
        #expect(abs(run(c, "P.contrast([255, 255, 255], [0, 0, 0])").toDouble() - 21) < 0.01)
        #expect(abs(run(c, "P.contrast([0, 0, 0, 0], [255, 255, 255])").toDouble() - 1) < 0.01)
    }

    /// Surfaces go onto the ramp (white to its bottom, light grays up toward its raised end), black for Pure black.
    @Test func surfacesGoOntoTheDarkRamp() throws {
        let c = try context()
        #expect(mapped(c, "#ffffff", "background") == "#121212")
        #expect(mapped(c, "#ffffff", "background", black: true) == "#000000")
        let raised = run(c, "P.toOklch(P.map(P.parse('#eaeef2'), 'background', false))[0]").toDouble()
        #expect(raised > run(c, "P.toOklch([18, 18, 18])[0]").toDouble() && raised <= run(c, "P.toOklch([30, 30, 30])[0]").toDouble() + 0.01)
        // Already dark stays dark; a faint black tint becomes a faint white one; see-through stays see-through.
        #expect(mapped(c, "#24292f", "background") == "#24292f")
        #expect(mapped(c, "rgba(0,0,0,0.05)", "background") == "rgba(255, 255, 255, 0.05)")
        #expect(mapped(c, "rgba(255,255,255,0.8)", "background").hasSuffix(", 0.8)"))
    }

    /// Text is turned over and readable (AA) on the ramp's raised end; an accent keeps its hue.
    @Test func textIsFlippedAndKeptReadable() throws {
        let c = try context()
        for (color, black) in [("#1f2328", false), ("#656d76", false), ("#0969da", false), ("#cf222e", false), ("#0969da", true), ("#999999", false)] {
            let ratio = run(c, "P.contrast(P.map(P.parse('\(color)'), 'text', \(black)), P.ramp(\(black)).high)").toDouble()
            #expect(ratio >= 4.5, "\(color) \(black): \(ratio)")
        }
        let hues = run(c, "[P.toOklch(P.parse('#0969da'))[2], P.toOklch(P.map(P.parse('#0969da'), 'text', false))[2]]").toArray() as? [Double] ?? [0, 99]
        #expect(abs(hues[0] - hues[1]) < 3)
        // Light text (on a colored button) stays as it is.
        #expect(mapped(c, "#ffffff", "text") == "#ffffff")
        // An accent surface keeps its hue and chroma.
        let accent = run(c, "(() => { const a = P.toOklch(P.parse('#1f883d')), b = P.toOklch(P.map(P.parse('#1f883d'), 'background', false)); return Math.abs(a[2] - b[2]) < 3 && Math.abs(a[1] - b[1]) < 0.03; })()").toBool()
        #expect(accent)
    }

    /// Gradients' colors are mapped; anything showing a picture is left alone.
    @Test func valuesAreRewrittenButPicturesLeftAlone() throws {
        let c = try context()
        #expect(run(c, "P.rewrite('linear-gradient(#fff, rgba(240, 240, 240, 0.5))', 'background', false)").toString()
                == "linear-gradient(#121212, rgba(21, 21, 21, 0.5))")
        #expect(run(c, "P.rewrite('url(a.png), linear-gradient(#fff, #000)', 'background', false) === null").toBool())
        #expect(run(c, "P.rewrite('var(--white)', 'background', false) === null").toBool())
        #expect(run(c, "P.rewrite('inherit', 'text', false) === null").toBool())
    }

    /// One id stronger, the pseudo-element kept at the end, lists split only at the top.
    @Test func selectorsAreStrengthenedInPlace() throws {
        let c = try context()
        let boosted = run(c, "P.boost('a, b::before, c::-webkit-scrollbar-thumb:hover, :is(x, y) > z, p:after, [title=\"a,b\"]')").toString()
        #expect(boosted == #"a:not(#zigzag-dark), b:not(#zigzag-dark)::before, c:not(#zigzag-dark)::-webkit-scrollbar-thumb:hover, :is(x, y) > z:not(#zigzag-dark), p:not(#zigzag-dark):after, [title="a,b"]:not(#zigzag-dark)"#)
    }

    private static let rules = """
    const decl = (o) => Object.assign(Object.keys(o), { getPropertyValue(n) { return o[n] || ''; } });
    const rules = [
      { selectorText: ':root', style: decl({ '--bg': '#ffffff', '--fg': '#111111', '--rgb-bg': '255 255 255', '--hsl-bg': '0 0% 100%', '--alias': 'var(--bg)' }) },
      { selectorText: 'body', style: decl({ 'background-color': 'var(--alias)', color: 'var(--fg)' }) },
      { selectorText: '.x', style: decl({ 'background-color': 'rgb(var(--rgb-bg))', 'border-top-color': 'hsl(var(--hsl-bg))' }) },
      { selectorText: '.btn', style: decl({ color: 'var(--bg)' }) },
      { selectorText: '.y', style: decl({ background: 'var(--fg) url(a.png)', 'background-color': '' }) },
      { media: { mediaText: '(max-width: 600px)' }, cssRules: [{ selectorText: '.card', style: decl({ 'background-color': 'rgb(250, 250, 250)' }) }] },
      { media: { mediaText: '(prefers-color-scheme: dark)' }, cssRules: [{ selectorText: '.dark', style: decl({ 'background-color': '#000' }) }] },
      { name: 'keyframes', type: 7, cssRules: [{ keyText: '0%', style: decl({ color: '#000' }) }] },
    ];
    const state = P.start(); P.add(state, rules, []);
    const done = P.collect(state, () => true);
    const made = P.generate(state, false);
    """

    /// Custom properties come first, each mapped for what it's used for; channels (rgb(var(--x))) stay channels; a
    /// property used for something else gets its own color there; @media is kept, dark-scheme rules skipped.
    @Test func theSheetIsWrittenFromTheRules() throws {
        let c = try context()
        run(c, Self.rules)
        #expect(run(c, "done").toBool())
        let out = run(c, "made.rules").toArray() as? [String] ?? []
        #expect(out.first?.hasPrefix(":where(html)") == true)
        let root = out.first { $0.hasPrefix(":root") } ?? ""
        #expect(root.contains("--bg: #121212 !important"))
        #expect(root.contains("--rgb-bg: 18 18 18 !important"))
        // Light text on the page (--fg) is turned over.
        #expect(!root.contains("--fg: #111111"))
        #expect(out.firstIndex { $0.hasPrefix(":root") }! < out.firstIndex { $0.hasPrefix(".btn") }!)
        // --bg is a surface; as .btn's text it's mapped as text, white staying white.
        #expect(out.contains(".btn:not(#zigzag-dark) { color: #ffffff !important }"))
        #expect(out.contains { $0.hasPrefix("@media (max-width: 600px) { .card:not(#zigzag-dark)") })
        #expect(!out.contains { $0.contains(".dark") || $0.hasPrefix("0%") })
        // The alias carries its use back to --bg: a surface, not text.
        #expect(run(c, "state.uses['--bg']['=--alias'] === 1").toBool())
        #expect(run(c, "state.uses['--fg'].background >= 1").toBool())
    }

    @Test func collectingStopsWhenThereIsNoTimeLeftAndCarriesOn() throws {
        let c = try context()
        let done = run(c, """
            const decl = (o) => Object.assign(Object.keys(o), { getPropertyValue(n) { return o[n] || ''; } });
            const many = Array.from({ length: 1000 }, (_, i) => ({ selectorText: '.r' + i, style: decl({ color: '#000' }) }));
            const s = P.start(); P.add(s, many, []);
            let slices = 0;
            while (!P.collect(s, () => false)) slices++;
            [slices > 5, s.entries.length === 1000, s.entries[0].selector === '.r0']
            """).toArray() as? [Bool]
        #expect(done == [true, true, true])
    }

    @Test func theFingerprintFollowsTheStyle() throws {
        let c = try context()
        let a = run(c, "P.fingerprint(['h https://a/x.css 120', 'i 300'])").toString()
        #expect(a == run(c, "P.fingerprint(['h https://a/x.css 120', 'i 300'])").toString())
        #expect(a != run(c, "P.fingerprint(['h https://a/x.css 121', 'i 300'])").toString())
        #expect(a != run(c, "P.fingerprint(['i 300', 'h https://a/x.css 120'])").toString())
    }
}
