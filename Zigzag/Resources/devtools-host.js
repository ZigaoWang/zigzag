// Runs in Chrome's DevTools frontend before its own scripts (ChromeDevTools.swift serves it), standing in for the
// DevToolsHost that Chrome's browser gives it. Protocol messages and anything the frontend asks of its browser go
// to the inspector page around it (devtools-bridge.js), which talks to WebKit.
(() => {
    const toBridge = (message) => parent.postMessage(message, "*");
    const waiting = new Map();
    let lastAsk = 0;
    const ask = (method, args) => new Promise((resolve) => {
        const id = ++lastAsk;
        waiting.set(id, resolve);
        toBridge({zz: "host", id, method, args});
    });
    const tell = (method, args = []) => toBridge({zz: "host", method, args});

    window.addEventListener("message", (event) => {
        if (event.source !== parent || !event.data || !event.data.zz) return;
        const data = event.data;
        if (data.zz === "cdp") window.DevToolsAPI.dispatchMessage(data.message);
        else if (data.zz === "reply") {
            const resolve = waiting.get(data.id);
            waiting.delete(data.id);
            if (resolve) resolve(data.result);
        } else if (data.zz === "show") showView(data.view);
    });

    async function showView(view) {
        const UI = await import("./ui/legacy/legacy.js");
        UI.ViewManager.ViewManager.instance().showView(view);
    }

    // ⇧⌘D moves it between the right and the bottom, as in Chrome; WebKit does the docking.
    document.addEventListener("keydown", (event) => {
        if (event.metaKey && event.shiftKey && !event.altKey && !event.ctrlKey && event.code === "KeyD") {
            event.preventDefault();
            event.stopPropagation();
            tell("toggleDockSide");
        }
    }, true);

    // What the frontend asks of its browser, by name. Anything not here is answered with nothing.
    const embedder = {
        dispatchProtocolMessage: ([message]) => toBridge({zz: "cdp", message}),
        getPreferences: () => ask("getPreferences", []),
        getPreference: ([name]) => ask("getPreference", [name]),
        setPreference: (args) => tell("setPreference", args),
        removePreference: (args) => tell("removePreference", args),
        clearPreferences: () => tell("clearPreferences"),
        getHostConfig: () => ({}),
        getSyncInformation: () => ({isSyncActive: false, arePreferencesSynced: false}),
        canShowSurvey: () => ({canShowSurvey: false}),
        showSurvey: () => ({surveyShown: false}),
        setIsDocked: () => undefined,
        loadCompleted: () => {
            // Menus drawn by the frontend itself: there's no browser here to draw them.
            window.DevToolsAPI.setUseSoftMenu(true);
            tell("loadCompleted");
        },
        requestFileSystems: () => window.DevToolsAPI.fileSystemsLoaded([]),
        loadNetworkResource: ([url]) => ask("loadNetworkResource", [url]),
        closeWindow: () => tell("closeWindow"),
        bringToFront: () => tell("bringToFront"),
        openInNewTab: (args) => tell("openInNewTab", args),
        inspectedURLChanged: (args) => tell("inspectedURLChanged", args),
    };

    window.DevToolsHost = {
        platform: () => "mac",
        isHostedMode: () => false,
        zoomFactor: () => 1,
        copyText: (text) => tell("copyText", [text]),
        showContextMenuAtPoint: () => {},
        isolatedFileSystem: () => null,
        upgradeDraggedFileSystemPermissions: () => {},
        sendMessageToEmbedder(json) {
            const {id, method, params = []} = JSON.parse(json);
            const handler = embedder[method];
            const result = handler ? handler(params) : undefined;
            if (method === "dispatchProtocolMessage") return;
            Promise.resolve(result).then((value) => window.DevToolsAPI.embedderMessageAck(id, value));
        },
    };
})();
