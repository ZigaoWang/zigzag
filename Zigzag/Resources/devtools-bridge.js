// Runs in WebKit's Web Inspector page at document start when Settings › Developer › Chrome DevTools is on
// (ChromeDevTools.swift). WebKit's own inspector never builds: Chrome's DevTools fills the page instead, in a frame,
// and what the two sides say goes through ZigzagCDPAdapter (devtools-adapter.js).
(() => {
    const config = __CONFIG__;
    if (!config.on) return;

    const storeKey = "zigzag-devtools-preferences";
    const readPreferences = () => {
        try { return JSON.parse(localStorage.getItem(storeKey)) || {}; } catch { return {}; }
    };
    const preferences = readPreferences();
    const savePreferences = () => {
        try { localStorage.setItem(storeKey, JSON.stringify(preferences)); } catch {}
    };

    let frame = null;
    let frameLoaded = false;
    const toFrameQueue = [];
    const toFrame = (message) => {
        if (frameLoaded) frame.contentWindow.postMessage(message, "*");
        else toFrameQueue.push(message);
    };

    // The last messages each way, for a look from Zigzag's debug bridge (inspectorjs).
    const traffic = window.__zigzagDevToolsTraffic = [];
    const note = (line) => { traffic.push(line.slice(0, 300)); if (traffic.length > 400) traffic.shift(); };
    const adapter = new window.ZigzagCDPAdapter({
        sendToWebKit: (message) => InspectorFrontendHost.sendMessageToBackend(JSON.stringify(message)),
        sendToFrontend: (message) => {
            if (message.error) note(`✗ ${message.id} ${message.error.message}`);
            toFrame({zz: "cdp", message: JSON.stringify(message)});
        },
    });
    const fromFrontend = adapter.fromFrontend.bind(adapter);
    adapter.fromFrontend = (text) => {
        const message = typeof text === "string" ? JSON.parse(text) : text;
        note(`→ ${message.id} ${message.method}`);
        fromFrontend(message);
    };

    let dockSide = "right";
    const host = {
        getPreferences: () => preferences,
        getPreference: ([name]) => preferences[name],
        setPreference: ([name, value]) => { preferences[name] = value; savePreferences(); },
        removePreference: ([name]) => { delete preferences[name]; savePreferences(); },
        clearPreferences: () => { for (const name in preferences) delete preferences[name]; savePreferences(); },
        loadNetworkResource: () => ({statusCode: 404, success: false}),
        copyText: ([text]) => InspectorFrontendHost.copyText(text),
        closeWindow: () => InspectorFrontendHost.closeWindow(),
        bringToFront: () => InspectorFrontendHost.bringToFront(),
        openInNewTab: ([url]) => InspectorFrontendHost.openURLExternally(url),
        inspectedURLChanged: ([url]) => InspectorFrontendHost.inspectedURLChanged(url),
        toggleDockSide: () => InspectorFrontendHost.requestSetDockSide(dockSide === "right" ? "bottom" : "right"),
    };

    window.addEventListener("message", (event) => {
        if (!frame || event.source !== frame.contentWindow || !event.data || !event.data.zz) return;
        const data = event.data;
        if (data.zz === "cdp") adapter.fromFrontend(data.message);
        else if (data.zz === "host") {
            const handler = host[data.method];
            const result = handler ? handler(data.args || []) : undefined;
            if (data.id) toFrame({zz: "reply", id: data.id, result});
        }
    });

    // WebKit's page builds its inspector on DOMContentLoaded. Stopped here, before it does; what WebKit's app
    // side tells it (the dock side, View › Developer's commands) comes here instead.
    document.addEventListener("DOMContentLoaded", (event) => {
        event.stopImmediatePropagation();
        const api = window.InspectorFrontendAPI;
        for (const name of Object.keys(api)) {
            if (typeof api[name] === "function" && name !== "dispatch" && name !== "loadCompleted") api[name] = () => null;
        }
        api.dispatchMessageAsync = (message) => adapter.fromWebKit(typeof message === "string" ? JSON.parse(message) : message);
        api.dispatchMessage = api.dispatchMessageAsync;
        api.setDockSide = (side) => { dockSide = side; };
        api.setElementSelectionEnabled = (on) => { adapter.setInspecting(on); };
        api.showConsole = () => toFrame({zz: "show", view: "console"});
        api.showResources = () => toFrame({zz: "show", view: "sources"});
        api.showMainResourceForFrame = () => toFrame({zz: "show", view: "sources"});

        document.body.textContent = "";
        document.body.style.cssText = "margin:0;overflow:hidden;background:Canvas";
        frame = document.createElement("iframe");
        frame.src = "zigzag-devtools://devtools/devtools_app.html";
        frame.style.cssText = "position:fixed;inset:0;width:100%;height:100%;border:0";
        frame.addEventListener("load", () => {
            frameLoaded = true;
            toFrameQueue.splice(0).forEach((message) => frame.contentWindow.postMessage(message, "*"));
        });
        document.body.appendChild(frame);
        InspectorFrontendHost.loaded();
    }, true);
})();
