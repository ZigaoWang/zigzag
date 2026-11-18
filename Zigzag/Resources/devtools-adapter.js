// Translates between Chrome DevTools' protocol (CDP), spoken by Chrome's frontend, and WebKit's inspector protocol,
// spoken by the page. Runs in WebKit's inspector page with devtools-bridge.js, which carries the messages.
// Each CDP command is answered here, by a WebKit command or two, or locally where WebKit has nothing like it.
(() => {
window.ZigzagCDPAdapter = class {
    constructor({sendToWebKit, sendToFrontend}) {
        this.sendToWebKit = sendToWebKit;
        this.sendToFrontend = sendToFrontend;
        this.pageTarget = null;
        this.queue = [];
        // Ours start high so they never meet the few that WebKit's own page sent before the bridge took over.
        this.lastId = 1000000;
        this.pending = new Map();
        this.enabled = new Set();
        this.mainFrame = null;
        this.defaultContextId = null;
        this.styleIds = new Map();
        this.ruleIds = new Map();
        this.scriptURLs = new Map();
        this.requestTypes = new Map();
        this.lastConsoleEvent = null;
        this.exceptionId = 0;
        this.inspecting = false;
    }

    // From WebKit -------------------------------------------------------------------------------------------------

    fromWebKit(message) {
        if (message.method === "Target.targetCreated") return this.targetCreated(message.params.targetInfo);
        if (message.method === "Target.didCommitProvisionalTarget") return this.provisionalCommitted(message.params);
        if (message.method === "Target.targetDestroyed") return;
        if (message.method === "Target.dispatchMessageFromTarget") {
            if (message.params.targetId !== this.pageTarget) return;
            const inner = JSON.parse(message.params.message);
            if ("id" in inner) return this.answered(inner);
            return this.event(inner.method, inner.params || {});
        }
        if ("id" in message) this.answered(message);
    }

    targetCreated(info) {
        if (info.type !== "page") return;
        if (info.isProvisional) {
            // A page loading in a new process: it's paused until told to go on, and becomes ours on commit.
            if (info.isPaused) this.sendToWebKit({id: ++this.lastId, method: "Target.resume", params: {targetId: info.targetId}});
            return;
        }
        if (this.pageTarget) return;
        this.pageTarget = info.targetId;
        this.wk("Inspector.enable").catch(() => {});
        this.wk("Inspector.initialized").catch(() => {});
        const queued = this.queue;
        this.queue = [];
        queued.forEach((message) => this.fromFrontend(message));
    }

    // The page moved to another process: the same domains on again there, and the frontend told it's a new document.
    provisionalCommitted({oldTargetId, newTargetId}) {
        if (oldTargetId !== this.pageTarget) return;
        this.pageTarget = newTargetId;
        this.wk("Inspector.enable").catch(() => {});
        this.wk("Inspector.initialized").catch(() => {});
        this.toFrontend("Runtime.executionContextsCleared", {});
        for (const domain of this.enabled) this.enable(domain).catch(() => {});
        if (this.enabled.has("DOM")) this.toFrontend("DOM.documentUpdated", {});
    }

    answered(inner) {
        const waiting = this.pending.get(inner.id);
        if (!waiting) return;
        this.pending.delete(inner.id);
        if (inner.error) waiting.reject(inner.error);
        else waiting.resolve(inner.result || {});
    }

    wk(method, params = {}) {
        return new Promise((resolve, reject) => {
            const id = ++this.lastId;
            this.pending.set(id, {resolve, reject});
            const message = JSON.stringify({id, method, params});
            this.sendToWebKit({id: ++this.lastId, method: "Target.sendMessageToTarget", params: {targetId: this.pageTarget, message}});
        });
    }

    toFrontend(method, params) { this.sendToFrontend({method, params}); }

    // From Chrome's frontend --------------------------------------------------------------------------------------

    fromFrontend(text) {
        const message = typeof text === "string" ? JSON.parse(text) : text;
        if (!this.pageTarget) return this.queue.push(message);
        const reply = (body) => this.sendToFrontend(Object.assign({id: message.id}, message.sessionId ? {sessionId: message.sessionId} : {}, body));
        // Only the page itself: no frames in other processes, no workers.
        if (message.sessionId) return reply({error: {code: -32001, message: "Session not found"}});
        Promise.resolve()
            .then(() => this.command(message.method, message.params || {}))
            .then((result) => { if (result !== NEVER) reply({result: result || {}}); })
            .catch((error) => reply({error: {code: error && error.code || -32000, message: error && error.message || String(error)}}));
    }

    enable(domain) {
        this.enabled.add(domain);
        switch (domain) {
        case "Runtime": return Promise.all([this.wk("Runtime.enable"), this.wk("Console.enable")]);
        case "DOM": return this.wk("DOM.enable").catch(() => {});
        default: return this.wk(`${domain}.enable`);
        }
    }

    async command(method, p) {
        const handler = COMMANDS[method];
        if (handler) return handler.call(this, p);
        const [, name] = method.split(".");
        // Chrome's frontend turns on and sets up far more than WebKit has; a quiet yes keeps it going.
        if (name === "enable" || name === "disable" || /^set[A-Z]/.test(name) || OK.has(method)) return {};
        throw {code: -32601, message: `'${method}' wasn't found`};
    }

    // Events ------------------------------------------------------------------------------------------------------

    event(method, p) {
        const handler = EVENTS[method];
        if (handler) handler.call(this, p);
        else if (PASS.has(method)) this.toFrontend(method, p);
    }

    // Shapes ------------------------------------------------------------------------------------------------------

    object(o) {
        if (!o) return o;
        const r = {type: o.type, subtype: o.subtype, className: o.className, value: o.value, description: o.description, objectId: o.objectId};
        if (o.type === "number" && (o.value === undefined || o.value === null) && o.description) r.unserializableValue = o.description;
        if (o.type === "bigint") { r.unserializableValue = (o.description || "0").replace(/n?$/, "n"); delete r.value; }
        if (o.subtype === "class") delete r.subtype;
        if (o.preview) r.preview = this.preview(o.preview);
        return r;
    }

    preview(p) {
        if (!p) return p;
        return {
            type: p.type, subtype: p.subtype === "class" ? undefined : p.subtype, description: p.description,
            overflow: !!p.overflow,
            properties: (p.properties || []).map((x) => ({name: x.name, type: x.type, value: x.value, subtype: x.subtype, valuePreview: this.preview(x.valuePreview)})),
            entries: p.entries && p.entries.map((e) => ({key: this.preview(e.key), value: this.preview(e.value)})),
        };
    }

    // WebKit counts console lines from 1, Chrome from 0.
    stack(s) {
        if (!s) return undefined;
        const frames = Array.isArray(s) ? s : s.callFrames || [];
        return {callFrames: frames.map((f) => ({functionName: f.functionName || "", scriptId: String(f.scriptId || "0"), url: f.url || "", lineNumber: Math.max(0, (f.lineNumber || 1) - 1), columnNumber: Math.max(0, (f.columnNumber || 1) - 1)}))};
    }

    node(n) {
        if (!n) return n;
        const r = Object.assign({}, n, {backendNodeId: n.nodeId});
        delete r.layoutFlags;
        delete r.customElementState;
        delete r.contentSecurityPolicyHash;
        if (n.children) r.children = n.children.map((c) => this.node(c));
        if (n.contentDocument) r.contentDocument = this.node(n.contentDocument);
        if (n.shadowRoots) r.shadowRoots = n.shadowRoots.map((c) => this.node(c));
        if (n.templateContent) r.templateContent = this.node(n.templateContent);
        if (n.pseudoElements) r.pseudoElements = n.pseudoElements.map((c) => this.node(c));
        return r;
    }

    frame(f) {
        return {
            id: f.id, parentId: f.parentId, loaderId: f.loaderId, name: f.name, url: f.url, securityOrigin: f.securityOrigin,
            mimeType: f.mimeType, domainAndRegistry: "", secureContextType: /^https:|^http:\/\/(localhost|127\.)/.test(f.url) ? "Secure" : "InsecureScheme",
            crossOriginIsolatedContextType: "NotIsolated", gatedAPIFeatures: [], adFrameStatus: {adFrameType: "none"},
        };
    }

    frameTree(t, withResources) {
        const r = {frame: this.frame(t.frame)};
        if (withResources) r.resources = (t.resources || []).map((x) => ({url: x.url, type: resourceType(x.type), mimeType: x.mimeType, failed: x.failed, canceled: x.canceled}));
        if (t.childFrames) r.childFrames = t.childFrames.map((c) => this.frameTree(c, withResources));
        return r;
    }

    sheetHeader(h) {
        return {
            styleSheetId: h.styleSheetId, frameId: h.frameId, sourceURL: h.sourceURL, origin: origin(h.origin), title: h.title || "",
            disabled: !!h.disabled, isInline: !!h.isInline, isMutable: true, isConstructed: false, hasSourceURL: false,
            startLine: h.startLine || 0, startColumn: h.startColumn || 0, length: 0, endLine: h.startLine || 0, endColumn: h.startColumn || 0,
        };
    }

    // Chrome edits a style by its sheet and where it starts; WebKit by an id. Each style shown keeps that pairing.
    style(s) {
        if (!s) return undefined;
        const sheet = s.styleId && s.styleId.styleSheetId;
        if (sheet && s.range) this.styleIds.set(rangeKey(sheet, s.range), s.styleId);
        return {
            styleSheetId: sheet,
            cssProperties: (s.cssProperties || []).map((x) => ({
                name: x.name, value: x.value, important: x.priority === "important", implicit: !!x.implicit, text: x.text,
                parsedOk: x.parsedOk !== false, disabled: x.status === "disabled", range: x.range,
            })),
            shorthandEntries: (s.shorthandEntries || []).map((e) => ({name: e.name, value: e.value, important: e.priority === "important"})),
            cssText: s.cssText, range: s.range,
        };
    }

    rule(r) {
        const sheet = r.ruleId && r.ruleId.styleSheetId;
        if (sheet && r.selectorList.range) this.ruleIds.set(rangeKey(sheet, r.selectorList.range), r.ruleId);
        const rule = {
            styleSheetId: sheet, origin: origin(r.origin), style: this.style(r.style),
            selectorList: {
                text: r.selectorList.text,
                selectors: r.selectorList.selectors.map((s) => ({text: s.text, range: s.range, specificity: s.specificity && {a: s.specificity[0], b: s.specificity[1], c: s.specificity[2]}})),
            },
            media: [], containerQueries: [], supports: [], layers: [], scopes: [], ruleTypes: [],
        };
        for (const g of r.groupings || []) {
            const item = {text: g.text, range: g.range, styleSheetId: sheet};
            if (g.type.startsWith("media")) { rule.media.push(Object.assign(item, {source: g.type === "media-import-rule" ? "importRule" : "mediaRule", sourceURL: g.sourceURL})); rule.ruleTypes.push("MediaRule"); }
            else if (g.type === "supports-rule") { rule.supports.push(Object.assign(item, {active: true})); rule.ruleTypes.push("SupportsRule"); }
            else if (g.type === "container-rule") { rule.containerQueries.push(item); rule.ruleTypes.push("ContainerRule"); }
            else if (g.type.startsWith("layer")) { rule.layers.push(item); rule.ruleTypes.push("LayerRule"); }
            else if (g.type === "scope-rule") { rule.scopes.push(item); rule.ruleTypes.push("ScopeRule"); }
            else if (g.type === "style-rule") rule.ruleTypes.push("StyleRule");
        }
        return rule;
    }

    match(m) { return {rule: this.rule(m.rule), matchingSelectors: m.matchingSelectors}; }

    timing(t) {
        if (!t) return undefined;
        const ms = (v) => (typeof v === "number" && v >= 0 ? v : -1);
        return {
            requestTime: t.startTime, proxyStart: -1, proxyEnd: -1, dnsStart: ms(t.domainLookupStart), dnsEnd: ms(t.domainLookupEnd),
            connectStart: ms(t.connectStart), connectEnd: ms(t.connectEnd), sslStart: ms(t.secureConnectionStart),
            sslEnd: ms(t.secureConnectionStart) >= 0 ? ms(t.connectEnd) : -1, workerStart: -1, workerReady: -1,
            workerFetchStart: -1, workerRespondWithSettled: -1, sendStart: ms(t.requestStart), sendEnd: ms(t.requestStart),
            pushStart: 0, pushEnd: 0, receiveHeadersStart: ms(t.responseStart), receiveHeadersEnd: ms(t.responseStart),
        };
    }

    response(r) {
        if (!r) return r;
        return {
            url: r.url, status: r.status, statusText: r.statusText || "", headers: r.headers || {}, mimeType: r.mimeType || "",
            charset: "", requestHeaders: r.requestHeaders, connectionReused: false, connectionId: 0, encodedDataLength: 0,
            timing: this.timing(r.timing), fromDiskCache: r.source === "disk-cache" || r.source === "memory-cache",
            fromServiceWorker: r.source === "service-worker", fromPrefetchCache: false, responseTime: Date.now(),
            securityState: /^https:|^wss:/.test(r.url) ? "secure" : "neutral", remoteIPAddress: undefined,
        };
    }

    initiator(i) {
        if (!i) return {type: "other"};
        return {type: i.type === "parser" || i.type === "script" ? i.type : "other", url: i.url, lineNumber: typeof i.lineNumber === "number" ? Math.max(0, i.lineNumber - 1) : undefined, stack: this.stack(i.stackTrace)};
    }

    // Console messages: console.log and friends, uncaught errors, and the rest (network, security...).
    consoleMessage(m) {
        const timestamp = Date.now();
        if (m.source === "console-api") {
            return ["Runtime.consoleAPICalled", {
                type: consoleType(m.type, m.level),
                args: (m.parameters && m.parameters.length ? m.parameters : [{type: "string", value: m.text}]).map((o) => this.object(o)),
                executionContextId: this.defaultContextId || 1, timestamp, stackTrace: this.stack(m.stackTrace),
            }];
        }
        if (m.source === "javascript" && m.level === "error") {
            const top = this.stack(m.stackTrace);
            return ["Runtime.exceptionThrown", {timestamp, exceptionDetails: {
                exceptionId: ++this.exceptionId, text: "Uncaught", url: m.url,
                lineNumber: Math.max(0, (m.line || 1) - 1), columnNumber: Math.max(0, (m.column || 1) - 1), stackTrace: top,
                exception: m.parameters && m.parameters[0] ? this.object(m.parameters[0]) : {type: "object", subtype: "error", className: "Error", description: m.text},
                executionContextId: this.defaultContextId || 1,
            }}];
        }
        return ["Log.entryAdded", {entry: {
            source: LOG_SOURCES.has(m.source) ? m.source : "other", level: LOG_LEVELS[m.level] || "info", text: m.text,
            url: m.url, lineNumber: m.line ? m.line - 1 : undefined, stackTrace: this.stack(m.stackTrace),
            networkRequestId: m.networkRequestId, timestamp,
        }}];
    }

    async evaluateResult(promise) {
        const r = await promise;
        const result = {result: this.object(r.result)};
        if (r.wasThrown) result.exceptionDetails = {exceptionId: ++this.exceptionId, text: "Uncaught", lineNumber: 0, columnNumber: 0, exception: this.object(r.result)};
        return result;
    }

    // Chrome evaluates what you type before you press Return, promising the page no side effects. WebKit can't
    // promise that, so only a plain chain of names (document.body.children) is evaluated early.
    sideEffectFree(expression) { return /^[\w$.\s[\]'"`]*$/.test(expression); }

    async setInspecting(on) {
        this.inspecting = on;
        await this.wk("DOM.setInspectModeEnabled", {enabled: on, highlightConfig: HIGHLIGHT}).catch(() => {});
    }
};

const NEVER = Symbol("never answered");
const rangeKey = (sheet, range) => `${sheet}|${range.startLine}:${range.startColumn}`;
const origin = (o) => ({"user-agent": "user-agent", user: "injected", inspector: "inspector"})[o] || "regular";
const resourceType = (t) => ({StyleSheet: "Stylesheet", Beacon: "Ping"})[t] || t || "Other";
const LOG_SOURCES = new Set(["xml", "javascript", "network", "storage", "appcache", "rendering", "security", "deprecation", "worker", "violation", "intervention", "recommendation", "other"]);
const LOG_LEVELS = {log: "info", info: "info", warning: "warning", error: "error", debug: "verbose"};
const HIGHLIGHT = {showInfo: true, contentColor: {r: 111, g: 168, b: 220, a: 0.66}, paddingColor: {r: 147, g: 196, b: 125, a: 0.55}, borderColor: {r: 255, g: 229, b: 153, a: 0.66}, marginColor: {r: 246, g: 178, b: 107, a: 0.66}};
const highlightConfig = (c) => c ? {showInfo: c.showInfo !== false, contentColor: c.contentColor, paddingColor: c.paddingColor, borderColor: c.borderColor, marginColor: c.marginColor} : HIGHLIGHT;

function consoleType(type, level) {
    if (!type || type === "log") return {warning: "warning", error: "error", info: "info", debug: "debug"}[level] || "log";
    return {timing: "timeEnd", image: "log"}[type] || type;
}

function scopeType(type, index) {
    if (type === "closure") return index === 0 ? "local" : "closure";
    return {globalLexicalEnvironment: "script", nestedLexical: "block", functionName: "closure"}[type] || type;
}

function pauseReason(reason) {
    return {exception: "exception", assert: "assert", DOM: "DOM", Listener: "EventListener", XHR: "XHR", Fetch: "XHR", CSPViolation: "CSPViolation"}[reason] || "other";
}

// Answered with nothing, though they don't look like it.
const OK = new Set([
    "Runtime.runIfWaitingForDebugger", "Target.autoAttachRelated", "Page.addScriptToEvaluateOnNewDocument",
    "Page.bringToFront", "Overlay.hideHighlight", "Log.startViolationsReport", "Log.stopViolationsReport",
    "Runtime.addBinding", "Page.resetNavigationHistory", "Debugger.setBlackboxPatterns", "Debugger.setBlackboxedRanges",
    "Debugger.setAsyncCallStackDepth", "CSS.trackComputedStyleUpdates", "CSS.trackComputedStyleUpdatesForNode",
    "Network.clearAcceptedEncodingsOverride", "Network.setAttachDebugStack", "Audits.checkFormsIssues",
]);

// Events whose WebKit and Chrome shapes are the same.
const PASS = new Set([
    "DOM.attributeModified", "DOM.attributeRemoved", "DOM.characterDataModified", "DOM.childNodeCountUpdated",
    "DOM.childNodeRemoved", "DOM.documentUpdated", "DOM.inlineStyleInvalidated", "DOM.shadowRootPopped",
    "DOM.pseudoElementRemoved", "CSS.styleSheetRemoved", "CSS.styleSheetChanged", "CSS.mediaQueryResultChanged",
    "Page.frameDetached", "Page.frameStartedLoading", "Page.frameStoppedLoading", "Page.domContentEventFired",
    "Page.loadEventFired", "Page.frameScheduledNavigation", "Page.frameClearedScheduledNavigation",
    "Network.dataReceived", "Network.webSocketClosed", "Network.webSocketFrameError", "Debugger.resumed",
    "Debugger.breakpointResolved",
]);

const COMMANDS = {
    // Runtime and the console
    "Runtime.enable"() { return this.enable("Runtime").then(() => ({})); },
    "Runtime.evaluate"(p) {
        if (p.throwOnSideEffect && !this.sideEffectFree(p.expression)) {
            return {result: {type: "undefined"}, exceptionDetails: {exceptionId: ++this.exceptionId, text: "EvalError: Possible side-effect in debug-evaluate", lineNumber: 0, columnNumber: 0}};
        }
        return this.evaluateResult(this.wk("Runtime.evaluate", {
            expression: p.expression, objectGroup: p.objectGroup, includeCommandLineAPI: p.includeCommandLineAPI,
            doNotPauseOnExceptionsAndMuteConsole: !!p.silent, contextId: p.contextId, returnByValue: p.returnByValue,
            generatePreview: p.generatePreview, saveResult: false, emulateUserGesture: p.userGesture, awaitPromise: p.awaitPromise,
        }));
    },
    async "Runtime.callFunctionOn"(p) {
        let objectId = p.objectId;
        if (!objectId) objectId = (await this.wk("Runtime.evaluate", {expression: "globalThis", contextId: p.executionContextId, objectGroup: p.objectGroup})).result.objectId;
        return this.evaluateResult(this.wk("Runtime.callFunctionOn", {
            objectId, functionDeclaration: p.functionDeclaration,
            arguments: p.arguments && p.arguments.map((a) => (a.objectId ? {objectId: a.objectId} : {value: a.value})),
            doNotPauseOnExceptionsAndMuteConsole: !!p.silent, returnByValue: p.returnByValue, generatePreview: p.generatePreview,
            emulateUserGesture: p.userGesture, awaitPromise: p.awaitPromise,
        }));
    },
    async "Runtime.getProperties"(p) {
        const r = await this.wk("Runtime.getProperties", {objectId: p.objectId, ownProperties: p.ownProperties, generatePreview: p.generatePreview});
        let properties = (r.properties || r.result || []).map((d) => ({
            name: d.name, value: this.object(d.value), writable: d.writable, get: this.object(d.get), set: this.object(d.set),
            configurable: !!d.configurable, enumerable: !!d.enumerable, wasThrown: d.wasThrown, isOwn: d.isOwn, symbol: this.object(d.symbol),
        }));
        if (p.accessorPropertiesOnly) properties = properties.filter((d) => d.get || d.set);
        return {result: properties, internalProperties: (r.internalProperties || []).map((d) => ({name: d.name, value: this.object(d.value)}))};
    },
    "Runtime.releaseObject"(p) { return this.wk("Runtime.releaseObject", {objectId: p.objectId}); },
    "Runtime.releaseObjectGroup"(p) { return this.wk("Runtime.releaseObjectGroup", {objectGroup: p.objectGroup}); },
    "Runtime.discardConsoleEntries"() { return this.wk("Console.clearMessages"); },
    "Log.clear"() { return this.wk("Console.clearMessages"); },
    // Whether what's typed so far is a whole statement, so Return runs it rather than starting a new line.
    async "Runtime.compileScript"(p) {
        const r = await this.wk("Runtime.parse", {source: p.expression}).catch(() => ({result: "none"}));
        if (r.result === "none") return {};
        const text = r.result === "irrecoverable" ? `SyntaxError: ${r.message}` : "SyntaxError: Unexpected end of input";
        return {exceptionDetails: {exceptionId: ++this.exceptionId, text, lineNumber: 0, columnNumber: 0, exception: {type: "object", subtype: "error", className: "SyntaxError", description: text}}};
    },
    "Runtime.globalLexicalScopeNames"() { return {names: []}; },
    "Runtime.getIsolateId"() { return {id: "zigzag"}; },
    "Runtime.getHeapUsage"() { return {usedSize: 0, totalSize: 0}; },

    // Page
    "Page.enable"() { return this.enable("Page").then(() => ({})); },
    async "Page.getResourceTree"() {
        const r = await this.wk("Page.getResourceTree");
        this.mainFrame = r.frameTree.frame;
        return {frameTree: this.frameTree(r.frameTree, true)};
    },
    async "Page.getFrameTree"() {
        const r = await this.wk("Page.getResourceTree");
        return {frameTree: this.frameTree(r.frameTree, false)};
    },
    "Page.getResourceContent"(p) { return this.wk("Page.getResourceContent", {frameId: p.frameId, url: p.url}); },
    "Page.searchInResource"(p) { return this.wk("Page.searchInResource", p); },
    "Page.reload"(p) { return this.wk("Page.reload", {ignoreCache: !!p.ignoreCache}); },
    async "Page.navigate"(p) { await this.wk("Page.navigate", {url: p.url}); return {frameId: this.mainFrame ? this.mainFrame.id : "", loaderId: ""}; },
    "Page.getNavigationHistory"() {
        const url = this.mainFrame ? this.mainFrame.url : "";
        return {currentIndex: 0, entries: [{id: 0, url, userTypedURL: url, title: "", transitionType: "typed"}]};
    },
    "Page.getAppManifest"() { return {url: "", errors: []}; },
    "Page.getInstallabilityErrors"() { return {installabilityErrors: []}; },
    "Page.getAdScriptAncestry"() { return {}; },

    // Elements
    "DOM.enable"() { return this.enable("DOM").then(() => ({})); },
    async "DOM.getDocument"() { return {root: this.node((await this.wk("DOM.getDocument")).root)}; },
    "DOM.requestChildNodes"(p) { return this.wk("DOM.requestChildNodes", {nodeId: p.nodeId, depth: p.depth}); },
    "DOM.querySelector"(p) { return this.wk("DOM.querySelector", p); },
    "DOM.querySelectorAll"(p) { return this.wk("DOM.querySelectorAll", p); },
    "DOM.getOuterHTML"(p) { return this.wk("DOM.getOuterHTML", {nodeId: p.nodeId || p.backendNodeId}); },
    "DOM.setOuterHTML"(p) { return this.wk("DOM.setOuterHTML", p); },
    "DOM.setAttributeValue"(p) { return this.wk("DOM.setAttributeValue", p); },
    "DOM.setAttributesAsText"(p) { return this.wk("DOM.setAttributesAsText", p); },
    "DOM.removeAttribute"(p) { return this.wk("DOM.removeAttribute", p); },
    "DOM.removeNode"(p) { return this.wk("DOM.removeNode", p); },
    "DOM.setNodeName"(p) { return this.wk("DOM.setNodeName", p); },
    "DOM.setNodeValue"(p) { return this.wk("DOM.setNodeValue", p); },
    "DOM.moveTo"(p) { return this.wk("DOM.moveTo", p); },
    "DOM.undo"() { return this.wk("DOM.undo"); },
    "DOM.redo"() { return this.wk("DOM.redo"); },
    "DOM.markUndoableState"() { return this.wk("DOM.markUndoableState"); },
    "DOM.setInspectedNode"(p) { return this.wk("DOM.setInspectedNode", p); },
    "DOM.performSearch"(p) { return this.wk("DOM.performSearch", {query: p.query}); },
    "DOM.getSearchResults"(p) { return this.wk("DOM.getSearchResults", p); },
    "DOM.discardSearchResults"(p) { return this.wk("DOM.discardSearchResults", p); },
    "DOM.resolveNode"(p) { return this.wk("DOM.resolveNode", {nodeId: p.nodeId || p.backendNodeId, objectGroup: p.objectGroup}).then((r) => ({object: this.object(r.object)})); },
    "DOM.requestNode"(p) { return this.wk("DOM.requestNode", p); },
    "DOM.pushNodesByBackendIdsToFrontend"(p) { return {nodeIds: p.backendNodeIds}; },
    "DOM.pushNodeByPathToFrontend"(p) { return this.wk("DOM.pushNodeByPathToFrontend", p); },
    "DOM.getTopLayerElements"() { return {nodeIds: []}; },
    "DOM.highlightNode"(p) { return COMMANDS["Overlay.highlightNode"].call(this, p); },
    "DOM.hideHighlight"() { return this.wk("DOM.hideHighlight"); },
    "Overlay.highlightNode"(p) {
        const nodeId = p.nodeId || p.backendNodeId;
        if (!nodeId && !p.objectId) return {};
        return this.wk("DOM.highlightNode", {highlightConfig: highlightConfig(p.highlightConfig), nodeId, objectId: p.objectId});
    },
    "Overlay.hideHighlight"() { return this.wk("DOM.hideHighlight"); },
    "Overlay.setInspectMode"(p) { return this.setInspecting(p.mode !== "none").then(() => ({})); },

    // Styles
    "CSS.enable"() { return this.enable("CSS").then(() => ({})); },
    async "CSS.getMatchedStylesForNode"(p) {
        const [matched, inline] = await Promise.all([
            this.wk("CSS.getMatchedStylesForNode", {nodeId: p.nodeId, includePseudo: true, includeInherited: true}),
            this.wk("CSS.getInlineStylesForNode", {nodeId: p.nodeId}),
        ]);
        return {
            inlineStyle: this.style(inline.inlineStyle), attributesStyle: this.style(inline.attributesStyle),
            matchedCSSRules: (matched.matchedCSSRules || []).map((m) => this.match(m)),
            pseudoElements: (matched.pseudoElements || []).map((e) => ({pseudoType: e.pseudoId, matches: e.matches.map((m) => this.match(m))})),
            inherited: (matched.inherited || []).map((e) => ({inlineStyle: this.style(e.inlineStyle), matchedCSSRules: (e.matchedCSSRules || []).map((m) => this.match(m))})),
            inheritedPseudoElements: [], cssKeyframesRules: [], cssPositionTryRules: [], cssPropertyRules: [],
            cssPropertyRegistrations: [], cssFunctionRules: [],
        };
    },
    async "CSS.getInlineStylesForNode"(p) {
        const r = await this.wk("CSS.getInlineStylesForNode", {nodeId: p.nodeId});
        return {inlineStyle: this.style(r.inlineStyle), attributesStyle: this.style(r.attributesStyle)};
    },
    "CSS.getComputedStyleForNode"(p) { return this.wk("CSS.getComputedStyleForNode", {nodeId: p.nodeId}); },
    "CSS.getPlatformFontsForNode"() { return {fonts: []}; },
    "CSS.getMediaQueries"() { return {medias: []}; },
    "CSS.getEnvironmentVariables"() { return {environmentVariables: {}}; },
    "CSS.getAnimatedStylesForNode"() { return {}; },
    "CSS.getStyleSheetText"(p) { return this.wk("CSS.getStyleSheetText", p); },
    "CSS.setStyleSheetText"(p) { return this.wk("CSS.setStyleSheetText", p).then(() => ({})); },
    "CSS.forcePseudoState"(p) { return this.wk("CSS.forcePseudoState", p); },
    "CSS.createStyleSheet"(p) { return this.wk("CSS.createStyleSheet", {frameId: p.frameId}); },
    async "CSS.setStyleTexts"(p) {
        const styles = [];
        for (const edit of p.edits) {
            const styleId = this.styleIds.get(rangeKey(edit.styleSheetId, edit.range));
            if (!styleId) throw {message: "That style can't be edited"};
            styles.push(this.style((await this.wk("CSS.setStyleText", {styleId, text: edit.text})).style));
        }
        return {styles};
    },
    async "CSS.setRuleSelector"(p) {
        const ruleId = this.ruleIds.get(rangeKey(p.styleSheetId, p.range));
        if (!ruleId) throw {message: "That rule can't be edited"};
        const r = await this.wk("CSS.setRuleSelector", {ruleId, selector: p.selector});
        return {selectorList: this.rule(r.rule).selectorList};
    },
    // Chrome waits on this until a computed style changes; WebKit never says, so it waits on.
    "CSS.takeComputedStyleUpdates"() { return NEVER; },

    // Network
    "Network.enable"() { return this.enable("Network").then(() => ({})); },
    "Network.getResponseBody"(p) { return this.wk("Network.getResponseBody", {requestId: p.requestId}); },
    "Network.setCacheDisabled"(p) { return this.wk("Network.setResourceCachingDisabled", {disabled: p.cacheDisabled}).then(() => ({})); },
    async "Network.getCookies"() {
        const r = await this.wk("Page.getCookies");
        return {cookies: (r.cookies || []).map((c) => Object.assign({size: (c.name + c.value).length, priority: "Medium", sourceScheme: "Unset", sourcePort: -1}, c))};
    },

    // Sources
    "Debugger.enable"() { return this.enable("Debugger").then(() => ({debuggerId: "zigzag"})); },
    "Debugger.getScriptSource"(p) { return this.wk("Debugger.getScriptSource", {scriptId: p.scriptId}); },
    "Debugger.searchInContent"(p) { return this.wk("Debugger.searchInContent", p); },
    "Debugger.setBreakpointByUrl"(p) {
        return this.wk("Debugger.setBreakpointByUrl", {lineNumber: p.lineNumber, url: p.url, urlRegex: p.urlRegex, columnNumber: p.columnNumber, options: p.condition ? {condition: p.condition} : {}});
    },
    "Debugger.setBreakpoint"(p) { return this.wk("Debugger.setBreakpoint", {location: p.location, options: p.condition ? {condition: p.condition} : {}}); },
    "Debugger.removeBreakpoint"(p) { return this.wk("Debugger.removeBreakpoint", p); },
    "Debugger.getPossibleBreakpoints"() { return {locations: []}; },
    "Debugger.setBreakpointsActive"(p) { return this.wk("Debugger.setBreakpointsActive", p); },
    "Debugger.setSkipAllPauses"(p) { return this.wk("Debugger.setBreakpointsActive", {active: !p.skip}); },
    "Debugger.setPauseOnExceptions"(p) { return this.wk("Debugger.setPauseOnExceptions", {state: p.state === "caught" ? "all" : p.state}); },
    "Debugger.pause"() { return this.wk("Debugger.pause"); },
    "Debugger.resume"() { return this.wk("Debugger.resume"); },
    "Debugger.stepOver"() { return this.wk("Debugger.stepOver"); },
    "Debugger.stepInto"() { return this.wk("Debugger.stepInto"); },
    "Debugger.stepOut"() { return this.wk("Debugger.stepOut"); },
    "Debugger.continueToLocation"(p) { return this.wk("Debugger.continueToLocation", {location: p.location}); },
    "Debugger.evaluateOnCallFrame"(p) {
        if (p.throwOnSideEffect && !this.sideEffectFree(p.expression)) {
            return {result: {type: "undefined"}, exceptionDetails: {exceptionId: ++this.exceptionId, text: "EvalError: Possible side-effect in debug-evaluate", lineNumber: 0, columnNumber: 0}};
        }
        return this.evaluateResult(this.wk("Debugger.evaluateOnCallFrame", {
            callFrameId: p.callFrameId, expression: p.expression, objectGroup: p.objectGroup, includeCommandLineAPI: p.includeCommandLineAPI,
            doNotPauseOnExceptionsAndMuteConsole: !!p.silent, returnByValue: p.returnByValue, generatePreview: p.generatePreview,
        }));
    },
};

const EVENTS = {
    "Runtime.executionContextCreated"({context: c}) {
        const isDefault = c.type ? c.type === "normal" : !!c.isPageContext;
        if (isDefault && (!this.mainFrame || c.frameId === this.mainFrame.id || !this.defaultContextId)) this.defaultContextId = c.id;
        const frame = this.mainFrame && c.frameId === this.mainFrame.id ? this.mainFrame : null;
        this.toFrontend("Runtime.executionContextCreated", {context: {
            id: c.id, name: c.name || "", origin: frame ? frame.securityOrigin : "", uniqueId: String(c.id),
            auxData: {isDefault, type: isDefault ? "default" : "isolated", frameId: c.frameId},
        }});
    },
    "Console.messageAdded"({message}) {
        const [method, params] = this.consoleMessage(message);
        this.lastConsoleEvent = [method, params];
        this.toFrontend(method, params);
    },
    // Chrome's frontend counts repeats itself, from the message coming again.
    "Console.messageRepeatCountUpdated"() { if (this.lastConsoleEvent) this.toFrontend(...this.lastConsoleEvent); },
    "Inspector.inspect"({object, hints}) {
        this.toFrontend("Runtime.inspectRequested", {object: this.object(object), hints: hints || {}, executionContextId: this.defaultContextId || 1});
    },

    "Page.frameNavigated"({frame}) {
        if (!frame.parentId) {
            this.mainFrame = frame;
            this.toFrontend("Runtime.executionContextsCleared", {});
        }
        this.toFrontend("Page.frameNavigated", {frame: this.frame(frame), type: "Navigation"});
    },

    "DOM.setChildNodes"({parentId, nodes}) { this.toFrontend("DOM.setChildNodes", {parentId, nodes: nodes.map((n) => this.node(n))}); },
    "DOM.childNodeInserted"(p) { this.toFrontend("DOM.childNodeInserted", {parentNodeId: p.parentNodeId, previousNodeId: p.previousNodeId, node: this.node(p.node)}); },
    "DOM.shadowRootPushed"(p) { this.toFrontend("DOM.shadowRootPushed", {hostId: p.hostId, root: this.node(p.root)}); },
    "DOM.pseudoElementAdded"(p) { this.toFrontend("DOM.pseudoElementAdded", {parentId: p.parentId, pseudoElement: this.node(p.pseudoElement)}); },
    // An element picked on the page.
    "DOM.inspect"({nodeId}) {
        this.inspecting = false;
        this.toFrontend("Overlay.inspectNodeRequested", {backendNodeId: nodeId});
    },

    "CSS.styleSheetAdded"({header}) { this.toFrontend("CSS.styleSheetAdded", {header: this.sheetHeader(header)}); },

    "Network.requestWillBeSent"(p) {
        const type = resourceType(p.type);
        this.requestTypes.set(p.requestId, type);
        this.toFrontend("Network.requestWillBeSent", {
            requestId: p.requestId, loaderId: p.loaderId || "", documentURL: p.documentURL,
            request: {url: p.request.url, method: p.request.method, headers: p.request.headers || {}, postData: p.request.postData,
                      hasPostData: !!p.request.postData, initialPriority: "High", referrerPolicy: p.request.referrerPolicy || "strict-origin-when-cross-origin"},
            timestamp: p.timestamp, wallTime: p.walltime, initiator: this.initiator(p.initiator), redirectHasExtraInfo: false,
            redirectResponse: p.redirectResponse && this.response(p.redirectResponse), type, frameId: p.frameId, hasUserGesture: false,
        });
    },
    "Network.responseReceived"(p) {
        const type = resourceType(p.type);
        this.requestTypes.set(p.requestId, type);
        this.toFrontend("Network.responseReceived", {requestId: p.requestId, loaderId: p.loaderId || "", timestamp: p.timestamp, type, response: this.response(p.response), hasExtraInfo: false, frameId: p.frameId});
    },
    "Network.loadingFinished"(p) {
        const m = p.metrics || {};
        this.toFrontend("Network.loadingFinished", {requestId: p.requestId, timestamp: p.timestamp, encodedDataLength: (m.responseHeaderBytesReceived || 0) + (m.responseBodyBytesReceived || 0)});
    },
    "Network.loadingFailed"(p) {
        this.toFrontend("Network.loadingFailed", {requestId: p.requestId, timestamp: p.timestamp, type: this.requestTypes.get(p.requestId) || "Other", errorText: p.errorText || "", canceled: !!p.canceled});
    },
    // WebKit says it once; Chrome as a request that came from the cache.
    "Network.requestServedFromMemoryCache"(p) {
        const type = resourceType(p.resource.type);
        this.toFrontend("Network.requestWillBeSent", {
            requestId: p.requestId, loaderId: p.loaderId || "", documentURL: p.documentURL, request: {url: p.resource.url, method: "GET", headers: {}, initialPriority: "High", referrerPolicy: "strict-origin-when-cross-origin"},
            timestamp: p.timestamp, wallTime: Date.now() / 1000, initiator: this.initiator(p.initiator), type, frameId: p.frameId,
        });
        this.toFrontend("Network.requestServedFromCache", {requestId: p.requestId});
        if (p.resource.response) this.toFrontend("Network.responseReceived", {requestId: p.requestId, loaderId: p.loaderId || "", timestamp: p.timestamp, type, response: this.response(p.resource.response), frameId: p.frameId});
        this.toFrontend("Network.loadingFinished", {requestId: p.requestId, timestamp: p.timestamp, encodedDataLength: 0});
    },
    "Network.webSocketCreated"(p) { this.toFrontend("Network.webSocketCreated", {requestId: p.requestId, url: p.url}); },
    "Network.webSocketWillSendHandshakeRequest"(p) { this.toFrontend("Network.webSocketWillSendHandshakeRequest", {requestId: p.requestId, timestamp: p.timestamp, wallTime: p.walltime, request: {headers: (p.request && p.request.headers) || {}}}); },
    "Network.webSocketHandshakeResponseReceived"(p) { this.toFrontend("Network.webSocketHandshakeResponseReceived", {requestId: p.requestId, timestamp: p.timestamp, response: {status: p.response.status, statusText: p.response.statusText, headers: p.response.headers || {}}}); },
    "Network.webSocketFrameSent"(p) { this.toFrontend("Network.webSocketFrameSent", {requestId: p.requestId, timestamp: p.timestamp, response: {opcode: p.response.opcode, mask: p.response.mask, payloadData: p.response.payloadData}}); },
    "Network.webSocketFrameReceived"(p) { this.toFrontend("Network.webSocketFrameReceived", {requestId: p.requestId, timestamp: p.timestamp, response: {opcode: p.response.opcode, mask: p.response.mask, payloadData: p.response.payloadData}}); },

    "Debugger.scriptParsed"(p) {
        const url = p.sourceURL || p.url || "";
        this.scriptURLs.set(p.scriptId, url);
        this.toFrontend("Debugger.scriptParsed", {
            scriptId: p.scriptId, url, startLine: p.startLine, startColumn: p.startColumn, endLine: p.endLine, endColumn: p.endColumn,
            executionContextId: this.defaultContextId || 1, hash: String(p.scriptId), isLiveEdit: false, sourceMapURL: p.sourceMapURL,
            hasSourceURL: !!p.sourceURL, isModule: !!p.module, length: 0, scriptLanguage: "JavaScript", buildId: "",
        });
    },
    "Debugger.paused"(p) {
        this.toFrontend("Debugger.paused", {
            callFrames: (p.callFrames || []).map((f) => ({
                callFrameId: f.callFrameId, functionName: f.functionName || "", location: f.location,
                url: this.scriptURLs.get(f.location.scriptId) || "", this: this.object(f.this) || {type: "undefined"},
                scopeChain: (f.scopeChain || []).map((s, i) => ({type: scopeType(s.type, i), object: this.object(s.object), name: s.name})),
                canBeRestarted: false,
            })),
            reason: pauseReason(p.reason), data: p.data,
            hitBreakpoints: p.reason === "Breakpoint" && p.data && p.data.breakpointId ? [p.data.breakpointId] : [],
        });
    },
};
})();
