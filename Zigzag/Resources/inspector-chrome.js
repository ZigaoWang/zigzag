// Runs inside WebKit's Web Inspector (its own page, not a site's) to make it look and act like Chrome's DevTools.
// ChromeInspector.swift writes in the setting and the stylesheet. Running it again only switches the look on or off.
(() => {
    const config = __CONFIG__;
    if (window.__zigzagChromeLook) {
        window.__zigzagChromeLook(config.on);
        return;
    }

    let style = null;
    function apply(on) {
        document.documentElement.classList.toggle("zz-chrome", on);
        if (on && !style) {
            style = document.createElement("style");
            style.id = "zigzag-chrome-look";
            style.textContent = __CSS__;
            (document.head || document.documentElement).appendChild(style);
        }
        if (style) style.disabled = !on;
    }
    window.__zigzagChromeLook = (on) => {
        config.on = on;
        apply(on);
        if (on) firstChromeSetup();
    };
    apply(config.on);

    if (typeof WI === "undefined" || !WI.Setting) return;

    // Chrome's Network columns (Name, Status, Type, Initiator, Size, Time, Waterfall): WebKit's own, less Domain.
    // Done once, so a column you show again stays shown.
    function firstChromeSetup() {
        const seeded = new WI.Setting("zigzag-chrome-seeded", false);
        if (seeded.value) return;
        const columns = new WI.Setting("network-table-column-visibility", {});
        columns.value = Object.assign({domain: false}, columns.value);
        seeded.value = true;
    }
    if (config.on) firstChromeSetup();

    // Docked on the right, as Chrome opens it, until you pick another side; then the side you picked, every time.
    const right = WI.DockConfiguration ? WI.DockConfiguration.Right : "right";
    const dockSide = new WI.Setting("zigzag-dock-side", right);
    let restored = false;
    function restore() {
        restored = true;
        const side = WI.dockConfiguration;
        if (!config.on || !WI._dockingAvailable || !side || side === dockSide.value) return;
        InspectorFrontendHost.requestSetDockSide(dockSide.value);
    }
    const updateDockedState = WI.updateDockedState;
    if (typeof updateDockedState === "function") {
        WI.updateDockedState = function(side) {
            const result = updateDockedState.apply(this, arguments);
            if (!restored) restore();
            // Undocked because the window is too small to dock isn't a choice to remember.
            else if (config.on && WI._dockingAvailable) dockSide.value = side;
            return result;
        };
    }
    if (WI.dockConfiguration) restore();
})();
