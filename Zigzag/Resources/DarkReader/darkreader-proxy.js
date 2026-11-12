// Dark Reader's proxy (https://darkreader.org, MIT; see THIRD_PARTY_NOTICES.md), from darkreader.js by
// scripts/update-darkreader.sh. Zigzag runs it in the page's own world when its Dark Reader asks (DarkPages.swift).
function injectProxy(
        enableStyleSheetsProxy,
        enableCustomElementRegistryProxy
    ) {
        document.dispatchEvent(
            new CustomEvent("__darkreader__inlineScriptsAllowed")
        );
        const cleaners = [];
        function cleanUp() {
            cleaners.forEach((clean) => clean());
            cleaners.splice(0);
        }
        function documentEventListener(type, listener, options) {
            document.addEventListener(type, listener, options);
            cleaners.push(() => document.removeEventListener(type, listener));
        }
        function disableConflictingPlugins() {
            const disableWPDarkMode = () => {
                if (window?.WPDarkMode?.deactivate) {
                    window.WPDarkMode.deactivate();
                }
            };
            disableWPDarkMode();
        }
        documentEventListener("__darkreader__cleanUp", cleanUp);
        documentEventListener(
            "__darkreader__disableConflictingPlugins",
            disableConflictingPlugins
        );
        function overrideProperty(cls, prop, overrides) {
            const proto = cls.prototype;
            const oldDescriptor = Object.getOwnPropertyDescriptor(proto, prop);
            if (!oldDescriptor) {
                return;
            }
            const newDescriptor = {...oldDescriptor};
            Object.keys(overrides).forEach((key) => {
                const factory = overrides[key];
                newDescriptor[key] = factory(oldDescriptor[key]);
            });
            Object.defineProperty(proto, prop, newDescriptor);
            cleaners.push(() =>
                Object.defineProperty(proto, prop, oldDescriptor)
            );
        }
        function override(cls, prop, factory) {
            overrideProperty(cls, prop, {value: factory});
        }
        function isDRElement(element) {
            return element?.classList?.contains("darkreader");
        }
        function isDRSheet(sheet) {
            return isDRElement(sheet.ownerNode);
        }
        const updateSheetEvent = new CustomEvent("__darkreader__updateSheet");
        const adoptedSheetChangeEvent = new CustomEvent(
            "__darkreader__adoptedStyleSheetChange"
        );
        const shadowDomAttachingEvent = new CustomEvent(
            "__darkreader__shadowDomAttaching",
            {bubbles: true}
        );
        const adoptedSheetOwners = new WeakMap();
        const adoptedDeclarationSheets = new WeakMap();
        function onAdoptedSheetChange(sheet) {
            const owners = adoptedSheetOwners.get(sheet);
            owners?.forEach((node) => {
                if (node.isConnected) {
                    node.dispatchEvent(adoptedSheetChangeEvent);
                } else {
                    owners.delete(node);
                }
            });
        }
        function reportSheetChange(sheet) {
            if (sheet.ownerNode && !isDRSheet(sheet)) {
                sheet.ownerNode.dispatchEvent(updateSheetEvent);
            }
            if (adoptedSheetOwners.has(sheet)) {
                onAdoptedSheetChange(sheet);
            }
        }
        function reportSheetChangeAsync(sheet, promise) {
            const {ownerNode} = sheet;
            if (
                ownerNode &&
                !isDRSheet(sheet) &&
                promise &&
                promise instanceof Promise
            ) {
                promise.then(() => ownerNode.dispatchEvent(updateSheetEvent));
            }
            if (adoptedSheetOwners.has(sheet)) {
                if (promise && promise instanceof Promise) {
                    promise.then(() => onAdoptedSheetChange(sheet));
                }
            }
        }
        override(
            CSSStyleSheet,
            "addRule",
            (native) =>
                function (selector, style, index) {
                    native.call(this, selector, style, index);
                    reportSheetChange(this);
                    return -1;
                }
        );
        override(
            CSSStyleSheet,
            "insertRule",
            (native) =>
                function (rule, index) {
                    const returnValue = native.call(this, rule, index);
                    reportSheetChange(this);
                    return returnValue;
                }
        );
        override(
            CSSStyleSheet,
            "deleteRule",
            (native) =>
                function (index) {
                    native.call(this, index);
                    reportSheetChange(this);
                }
        );
        override(
            CSSStyleSheet,
            "removeRule",
            (native) =>
                function (index) {
                    native.call(this, index);
                    reportSheetChange(this);
                }
        );
        override(
            CSSStyleSheet,
            "replace",
            (native) =>
                function (cssText) {
                    const returnValue = native.call(this, cssText);
                    reportSheetChangeAsync(this, returnValue);
                    return returnValue;
                }
        );
        override(
            CSSStyleSheet,
            "replaceSync",
            (native) =>
                function (cssText) {
                    native.call(this, cssText);
                    reportSheetChange(this);
                }
        );
        override(
            Element,
            "attachShadow",
            (native) =>
                function (options) {
                    this.dispatchEvent(shadowDomAttachingEvent);
                    return native.call(this, options);
                }
        );
        const shouldWrapHTMLElement =
            location.hostname === "baidu.com" ||
            location.hostname.endsWith(".baidu.com");
        if (shouldWrapHTMLElement) {
            override(
                Element,
                "getElementsByTagName",
                (native) =>
                    function (tagName) {
                        if (tagName !== "style") {
                            return native.call(this, tagName);
                        }
                        const getCurrentElementValue = () => {
                            const elements = native.call(this, tagName);
                            return Object.setPrototypeOf(
                                [...elements].filter(
                                    (element) =>
                                        element && !isDRElement(element)
                                ),
                                NodeList.prototype
                            );
                        };
                        let elements = getCurrentElementValue();
                        const nodeListBehavior = {
                            get: function (_, property) {
                                return getCurrentElementValue()[property];
                            }
                        };
                        elements = new Proxy(elements, nodeListBehavior);
                        return elements;
                    }
            );
        }
        const shouldProxyChildNodes = ["brilliant.org", "www.vy.no"].includes(
            location.hostname
        );
        if (shouldProxyChildNodes) {
            overrideProperty(Node, "childNodes", {
                get: (native) =>
                    function () {
                        const childNodes = native.call(this);
                        return Object.setPrototypeOf(
                            [...childNodes].filter((element) => {
                                return !isDRElement(element);
                            }),
                            NodeList.prototype
                        );
                    }
            });
        }
        function resolveCustomElement(tag) {
            customElements.whenDefined(tag).then(() => {
                document.dispatchEvent(
                    new CustomEvent("__darkreader__isDefined", {detail: {tag}})
                );
            });
        }
        documentEventListener("__darkreader__addUndefinedResolver", (e) =>
            resolveCustomElement(e.detail.tag)
        );
        if (enableCustomElementRegistryProxy) {
            override(
                CustomElementRegistry,
                "define",
                (native) =>
                    function (name, constructor, options) {
                        resolveCustomElement(name);
                        native.call(this, name, constructor, options);
                    }
            );
        }
        let blobURLAllowed = null;
        function checkBlobURLSupport() {
            if (blobURLAllowed != null) {
                document.dispatchEvent(
                    new CustomEvent("__darkreader__blobURLCheckResponse", {
                        detail: {blobURLAllowed}
                    })
                );
                return;
            }
            const svg =
                '<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"><rect width="1" height="1" fill="transparent"/></svg>';
            const bytes = new Uint8Array(svg.length);
            for (let i = 0; i < svg.length; i++) {
                bytes[i] = svg.charCodeAt(i);
            }
            const blob = new Blob([bytes], {type: "image/svg+xml"});
            const objectURL = URL.createObjectURL(blob);
            const image = new Image();
            image.onload = () => {
                blobURLAllowed = true;
                sendBlobURLCheckResponse();
            };
            image.onerror = () => {
                blobURLAllowed = false;
                sendBlobURLCheckResponse();
            };
            image.src = objectURL;
        }
        function sendBlobURLCheckResponse() {
            document.dispatchEvent(
                new CustomEvent("__darkreader__blobURLCheckResponse", {
                    detail: {blobURLAllowed}
                })
            );
        }
        documentEventListener(
            "__darkreader__blobURLCheckRequest",
            checkBlobURLSupport
        );
        if (enableStyleSheetsProxy) {
            overrideProperty(Document, "styleSheets", {
                get: (native) =>
                    function () {
                        let filteredSheetsCache = null;
                        let docSheets = null;
                        const didChange = (newSheets) => {
                            if (
                                !filteredSheetsCache ||
                                !docSheets ||
                                docSheets.length !== newSheets.length
                            ) {
                                return true;
                            }
                            for (let i = 0; i < docSheets.length; i++) {
                                if (docSheets[i] !== newSheets[i]) {
                                    return true;
                                }
                            }
                            return false;
                        };
                        const getCurrentValue = () => {
                            const nativeDocSheets = native.call(this);
                            if (!didChange(nativeDocSheets)) {
                                return filteredSheetsCache;
                            }
                            docSheets = Array.from(nativeDocSheets);
                            const filteredSheets = docSheets.filter(
                                (styleSheet) =>
                                    styleSheet.ownerNode &&
                                    !isDRSheet(styleSheet)
                            );
                            filteredSheets.item = (item) =>
                                filteredSheets[item];
                            filteredSheetsCache = Object.setPrototypeOf(
                                filteredSheets,
                                StyleSheetList.prototype
                            );
                            return filteredSheetsCache;
                        };
                        const styleSheetListBehavior = {
                            get: function (_, property) {
                                return getCurrentValue()[property];
                            }
                        };
                        return new Proxy(
                            getCurrentValue(),
                            styleSheetListBehavior
                        );
                    }
            });
        }
        const adoptedSheetsSourceProxies = new WeakMap();
        const adoptedSheetsProxySources = new WeakMap();
        const adoptedSheetsChangeEvent = new CustomEvent(
            "__darkreader__adoptedStyleSheetsChange"
        );
        const adoptedSheetOverrideCache = new WeakSet();
        const adoptedSheetsSnapshots = new WeakMap();
        const isDRAdoptedSheetOverride = (sheet) => {
            if (!sheet || !sheet.cssRules) {
                return false;
            }
            if (adoptedSheetOverrideCache.has(sheet)) {
                return true;
            }
            if (
                sheet.cssRules.length > 0 &&
                sheet.cssRules[0].selectorText?.startsWith("#__darkreader")
            ) {
                adoptedSheetOverrideCache.add(sheet);
                return true;
            }
            return false;
        };
        const areArraysEqual = (a, b) => {
            return a.length === b.length && a.every((x, i) => x === b[i]);
        };
        const onAdoptedSheetsChange = (node) => {
            const prev = adoptedSheetsSnapshots.get(node);
            const curr = (node.adoptedStyleSheets || []).filter(
                (s) => !isDRAdoptedSheetOverride(s)
            );
            adoptedSheetsSnapshots.set(node, curr);
            if (!prev || !areArraysEqual(prev, curr)) {
                curr.forEach((sheet) => {
                    if (!adoptedSheetOwners.has(sheet)) {
                        adoptedSheetOwners.set(sheet, new Set());
                    }
                    adoptedSheetOwners.get(sheet).add(node);
                    for (const rule of sheet.cssRules) {
                        const declaration = rule.style;
                        if (declaration) {
                            adoptedDeclarationSheets.set(declaration, sheet);
                        }
                    }
                });
                node.dispatchEvent(adoptedSheetsChangeEvent);
            }
        };
        const proxyAdoptedSheetsArray = (node, source) => {
            if (adoptedSheetsProxySources.has(source)) {
                return source;
            }
            if (adoptedSheetsSourceProxies.has(source)) {
                return adoptedSheetsSourceProxies.get(source);
            }
            const proxy = new Proxy(source, {
                deleteProperty(target, property) {
                    delete target[property];
                    return true;
                },
                set(target, property, value) {
                    target[property] = value;
                    if (property === "length") {
                        onAdoptedSheetsChange(node);
                    }
                    return true;
                }
            });
            adoptedSheetsSourceProxies.set(source, proxy);
            adoptedSheetsProxySources.set(proxy, source);
            return proxy;
        };
        [Document, ShadowRoot].forEach((ctor) => {
            overrideProperty(ctor, "adoptedStyleSheets", {
                get: (native) =>
                    function () {
                        const source = native.call(this);
                        return proxyAdoptedSheetsArray(this, source);
                    },
                set: (native) =>
                    function (source) {
                        if (adoptedSheetsProxySources.has(source)) {
                            source = adoptedSheetsProxySources.get(source);
                        }
                        native.call(this, source);
                        onAdoptedSheetsChange(this);
                    }
            });
        });
        const adoptedDeclarationChangeEvent = new CustomEvent(
            "__darkreader__adoptedStyleDeclarationChange"
        );
        ["setProperty", "removeProperty"].forEach((key) => {
            override(CSSStyleDeclaration, key, (native) => {
                return function (...args) {
                    const returnValue = native.apply(this, args);
                    const sheet = adoptedDeclarationSheets.get(this);
                    if (sheet) {
                        const owners = adoptedSheetOwners.get(sheet);
                        if (owners) {
                            owners.forEach((node) => {
                                node.dispatchEvent(
                                    adoptedDeclarationChangeEvent
                                );
                            });
                        }
                    }
                    return returnValue;
                };
            });
        });
    }
