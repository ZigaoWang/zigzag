import Foundation

/// The tools Zigzag offers, what each takes, and the rules on where they may act. All plain data, so it's the same
/// on the network's queue and the main actor, and tested on its own.
nonisolated enum MCPTools {
    static let readDefault = 20_000, readMax = 100_000, readMin = 500
    static let linksDefault = 200, linksMax = 1_000
    static let waitDefault = 5_000, waitMax = 30_000, waitMin = 100

    private static let tabID: JSON = ["type": "integer", "minimum": 1,
                                      "description": "The tab's id from list_tabs. Leave it out for the tab in front."]

    private static func tool(_ name: String, _ title: String, _ description: String, properties: [String: JSON] = [:],
                             required: [String] = [], readOnly: Bool = false, destructive: Bool = false) -> JSON {
        var schema: [String: JSON] = ["type": "object", "properties": .object(properties), "additionalProperties": false]
        if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
        return ["name": .string(name), "title": .string(title), "description": .string(description), "inputSchema": .object(schema),
                "annotations": ["readOnlyHint": .bool(readOnly), "destructiveHint": .bool(destructive), "openWorldHint": true]]
    }

    static let definitions: [JSON] = [
        tool("list_tabs", "List Tabs", "Lists the open tabs in Zigzag's windows, front window first: id, title, url, whether each is the active tab, its window (1 is in front) and space. Private windows are never listed.",
             readOnly: true),
        tool("open_tab", "Open Tab", "Opens a web page (http or https) in a new tab of the front window and waits for it to load.",
             properties: ["url": ["type": "string", "description": "The page's address."],
                          "background": ["type": "boolean", "description": "Open it without switching to it. Default false."]],
             required: ["url"]),
        tool("activate_tab", "Activate Tab", "Switches to a tab, and to its space, in its window.", properties: ["id": tabID], required: ["id"]),
        tool("close_tab", "Close Tab", "Closes a tab.", properties: ["id": tabID], required: ["id"], destructive: true),
        tool("navigate", "Navigate", "Loads a web page (http or https) in a tab and waits for it.",
             properties: ["id": tabID, "url": ["type": "string", "description": "The page's address."]], required: ["url"]),
        tool("go_back", "Go Back", "Goes back a page in a tab.", properties: ["id": tabID]),
        tool("go_forward", "Go Forward", "Goes forward a page in a tab.", properties: ["id": tabID]),
        tool("reload", "Reload", "Reloads a tab's page.", properties: ["id": tabID]),
        tool("read_page", "Read Page", "The page's title, url and readable text, and its form fields (password values are never included).",
             properties: ["id": tabID, "max_chars": ["type": "integer", "minimum": .int(readMin), "maximum": .int(readMax),
                                                      "description": "Most text to give back. Default \(readDefault)."]],
             readOnly: true),
        tool("get_links", "Get Links", "The links on the page: their text and address.",
             properties: ["id": tabID, "max": ["type": "integer", "minimum": 1, "maximum": .int(linksMax), "description": "Most links to give back. Default \(linksDefault)."]],
             readOnly: true),
        tool("screenshot", "Screenshot", "A PNG picture of the page as it shows now. The tab must be on screen: activate it first.",
             properties: ["id": tabID], readOnly: true),
        tool("click", "Click", "Clicks an element, found by CSS selector or by the text it shows (a link, a button). Give one of the two.",
             properties: ["id": tabID, "selector": ["type": "string", "description": "A CSS selector."],
                          "text": ["type": "string", "description": "Text the element shows, matched exactly first, then in part, ignoring case."]]),
        tool("type", "Type", "Types text into a field found by CSS selector, or picks a <select>'s option by its text. Never into password fields.",
             properties: ["id": tabID, "selector": ["type": "string", "description": "A CSS selector for the field."],
                          "text": ["type": "string", "description": "What to type."],
                          "clear": ["type": "boolean", "description": "Replace what's in the field. Default true."],
                          "submit": ["type": "boolean", "description": "Submit its form afterwards, as Return would. Default false."]],
             required: ["selector", "text"]),
        tool("scroll", "Scroll", "Scrolls the page, or an element in it, by a number of points: positive down, negative up.",
             properties: ["id": tabID, "dy": ["type": "number", "description": "Points to scroll."],
                          "selector": ["type": "string", "description": "A CSS selector for a scrolling element. Leave it out for the page."]],
             required: ["dy"]),
        tool("wait_for", "Wait For", "Waits until something holds on the page, or the time runs out: some text shows (text) or goes (text_gone), an element matching a CSS selector shows (selector) or goes (selector_gone), or the page finishes loading (load). Give one of them. Ends with an error if the tab closes or loads another page first.",
             properties: ["id": tabID,
                          "text": ["type": "string", "description": "Text to wait for on the page, ignoring case and spacing."],
                          "text_gone": ["type": "string", "description": "Text to wait to disappear from the page."],
                          "selector": ["type": "string", "description": "A CSS selector to wait for a visible element matching it."],
                          "selector_gone": ["type": "string", "description": "A CSS selector to wait until no visible element matches it."],
                          "load": ["type": "boolean", "description": "true to wait for the page to finish loading."],
                          "timeout_ms": ["type": "integer", "minimum": .int(waitMin), "maximum": .int(waitMax),
                                         "description": "How long to wait, in milliseconds. Default \(waitDefault)."]],
             readOnly: true),
        tool("press_key", "Press Key", "Presses a key in the page, as the person would on the keyboard: in the element that has the focus, or in the one a CSS selector finds, focused first. Keys: Enter, Escape, Tab, Backspace, Delete, ArrowUp, ArrowDown, ArrowLeft, ArrowRight, Home, End, PageUp, PageDown, Space, or one character. Modifiers can be given as \"Shift+Tab\" or in modifiers. Keys only reach the page, never Zigzag's own shortcuts, and never type into password fields.",
             properties: ["id": tabID,
                          "key": ["type": "string", "description": "The key, like Enter, Shift+Tab, ArrowDown or a."],
                          "modifiers": ["type": "array", "items": ["type": "string", "enum": ["shift", "alt", "ctrl", "meta"]],
                                        "description": "Modifier keys held down with it."],
                          "selector": ["type": "string", "description": "A CSS selector for an element to focus first. Leave it out for the element that has the focus."]],
             required: ["key"]),
    ]

    static let names = definitions.compactMap { $0["name"]?.string }
}

/// A tool call, its arguments read and checked.
nonisolated enum MCPCommand: Equatable, Sendable {
    case listTabs
    case openTab(URL, background: Bool)
    case activate(Int)
    case close(Int)
    case navigate(Int?, URL)
    case goBack(Int?), goForward(Int?), reload(Int?)
    case read(Int?, maxChars: Int)
    case links(Int?, max: Int)
    case screenshot(Int?)
    case click(Int?, selector: String?, text: String?)
    case type(Int?, selector: String, text: String, clear: Bool, submit: Bool)
    case scroll(Int?, dy: Double, selector: String?)
    case waitFor(Int?, MCPWaitCondition, timeoutMs: Int)
    case pressKey(Int?, MCPKeyPress, selector: String?)

    /// The tab it names, if any. Nil also for "the tab in front".
    var tabID: Int? {
        switch self {
        case .listTabs, .openTab: nil
        case .activate(let id), .close(let id): id
        case .navigate(let id, _), .goBack(let id), .goForward(let id), .reload(let id), .read(let id, _), .links(let id, _),
             .screenshot(let id), .click(let id, _, _), .type(let id, _, _, _, _), .scroll(let id, _, _): id
        case .waitFor(let id, _, _), .pressKey(let id, _, _): id
        }
    }

    static func parse(_ name: String, _ arguments: [String: JSON]) -> Result<MCPCommand, MCPArgumentError> {
        guard let definition = MCPTools.definitions.first(where: { $0["name"]?.string == name }) else { return .failure(.init("Unknown tool: \(name)")) }
        let allowed = Set(definition["inputSchema"]?["properties"]?.object?.keys.map { $0 } ?? [])
        if let extra = arguments.keys.sorted().first(where: { !allowed.contains($0) }) {
            let takes = allowed.isEmpty ? "no arguments" : allowed.sorted().joined(separator: ", ")
            return .failure(.init("\(name) doesn't take \"\(extra)\". It takes \(takes)."))
        }
        let a = Arguments(arguments)
        do {
            switch name {
            case "list_tabs": return .success(.listTabs)
            case "open_tab": return .success(.openTab(try a.url("url"), background: try a.bool("background") ?? false))
            case "activate_tab": return .success(.activate(try a.requiredID()))
            case "close_tab": return .success(.close(try a.requiredID()))
            case "navigate": return .success(.navigate(try a.id(), try a.url("url")))
            case "go_back": return .success(.goBack(try a.id()))
            case "go_forward": return .success(.goForward(try a.id()))
            case "reload": return .success(.reload(try a.id()))
            case "read_page":
                return .success(.read(try a.id(), maxChars: try a.int("max_chars", in: MCPTools.readMin...MCPTools.readMax) ?? MCPTools.readDefault))
            case "get_links": return .success(.links(try a.id(), max: try a.int("max", in: 1...MCPTools.linksMax) ?? MCPTools.linksDefault))
            case "screenshot": return .success(.screenshot(try a.id()))
            case "click":
                let selector = try a.string("selector"), text = try a.string("text")
                guard (selector == nil) != (text == nil) else { throw MCPArgumentError("click takes a selector or a text, one of the two.") }
                return .success(.click(try a.id(), selector: selector, text: text))
            case "type":
                guard let selector = try a.string("selector") else { throw MCPArgumentError("type needs a selector.") }
                guard let text = try a.string("text", allowEmpty: true) else { throw MCPArgumentError("type needs a text.") }
                guard text.count <= 100_000 else { throw MCPArgumentError("text is too long.") }
                return .success(.type(try a.id(), selector: selector, text: text, clear: try a.bool("clear") ?? true, submit: try a.bool("submit") ?? false))
            case "scroll":
                guard let dy = arguments["dy"]?.number, dy.isFinite else { throw MCPArgumentError("scroll needs dy, a number of points.") }
                return .success(.scroll(try a.id(), dy: max(-100_000, min(100_000, dy)), selector: try a.string("selector")))
            case "wait_for":
                var conditions: [MCPWaitCondition] = []
                if let text = try a.string("text") { conditions.append(.text(text)) }
                if let text = try a.string("text_gone") { conditions.append(.textGone(text)) }
                if let selector = try a.string("selector") { conditions.append(.selector(selector)) }
                if let selector = try a.string("selector_gone") { conditions.append(.selectorGone(selector)) }
                if let load = try a.bool("load") {
                    guard load else { throw MCPArgumentError("load can only be true: leave it out to wait for something else.") }
                    conditions.append(.load)
                }
                guard conditions.count == 1, let condition = conditions.first else {
                    throw MCPArgumentError("wait_for takes one of text, text_gone, selector, selector_gone or load.")
                }
                if case .text(let text) = condition, text.count > 10_000 { throw MCPArgumentError("text is too long.") }
                if case .textGone(let text) = condition, text.count > 10_000 { throw MCPArgumentError("text_gone is too long.") }
                let timeout = try a.int("timeout_ms", in: MCPTools.waitMin...MCPTools.waitMax) ?? MCPTools.waitDefault
                return .success(.waitFor(try a.id(), condition, timeoutMs: timeout))
            case "press_key":
                guard let key = try a.string("key", allowEmpty: true), !key.isEmpty else { throw MCPArgumentError("press_key needs a key, like Enter or Tab.") }
                var modifiers: [String] = []
                if let value = arguments["modifiers"], value != .null {
                    guard let list = value.array, list.allSatisfy({ $0.string != nil }) else {
                        throw MCPArgumentError("modifiers must be a list of shift, alt, ctrl and meta.")
                    }
                    modifiers = list.compactMap(\.string)
                }
                switch MCPKeyPress.parse(key, modifiers: modifiers) {
                case .failure(let error): throw error
                case .success(let press): return .success(.pressKey(try a.id(), press, selector: try a.string("selector")))
                }
            default: return .failure(.init("Unknown tool: \(name)"))
            }
        } catch let error as MCPArgumentError {
            return .failure(error)
        } catch {
            return .failure(.init("\(error)"))
        }
    }

    private struct Arguments {
        let values: [String: JSON]
        init(_ values: [String: JSON]) { self.values = values }

        func id() throws -> Int? {
            guard let value = values["id"], value != .null else { return nil }
            guard let id = value.int ?? value.string.flatMap({ Int($0) }), id >= 1 else { throw MCPArgumentError("id must be a tab's id from list_tabs, a whole number.") }
            return id
        }

        func requiredID() throws -> Int {
            guard let id = try id() else { throw MCPArgumentError("id is needed: a tab's id from list_tabs.") }
            return id
        }

        func string(_ key: String, allowEmpty: Bool = false) throws -> String? {
            guard let value = values[key], value != .null else { return nil }
            guard let string = value.string else { throw MCPArgumentError("\(key) must be a string.") }
            if !allowEmpty, string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw MCPArgumentError("\(key) is empty.") }
            return string
        }

        func bool(_ key: String) throws -> Bool? {
            guard let value = values[key], value != .null else { return nil }
            guard let bool = value.bool else { throw MCPArgumentError("\(key) must be true or false.") }
            return bool
        }

        func int(_ key: String, in range: ClosedRange<Int>) throws -> Int? {
            guard let value = values[key], value != .null else { return nil }
            guard let int = value.int else { throw MCPArgumentError("\(key) must be a whole number.") }
            return min(max(int, range.lowerBound), range.upperBound)
        }

        func url(_ key: String) throws -> URL {
            guard let string = try string(key) else { throw MCPArgumentError("\(key) is needed.") }
            guard let url = MCPSafety.webAddress(string) else {
                throw MCPArgumentError("\(string) isn't a web address. Only http and https pages can be opened, never javascript:, file:, data: or Zigzag's own pages.")
            }
            return url
        }
    }
}

nonisolated struct MCPArgumentError: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Where the tools may act: websites in your everyday windows, never a private window, Zigzag's own pages
/// (Settings, History), an extension's page or a file, and never a password field.
nonisolated enum MCPSafety {
    enum Refusal: Equatable {
        case privateWindow, ownPage, extensionPage, notAWebPage, emptyTab, stopped, errorPage, turnedOff
    }

    /// A web address to open: http or https only, with a host. A bare name like example.com gets https.
    static func webAddress(_ string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        var candidate = trimmed
        if !candidate.contains("://") {
            // "example.com/page", never "javascript:alert(1)" or "zigzag:settings".
            let head = candidate.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            guard head.contains("."), !head.contains("@"), head.range(of: #"^[A-Za-z0-9.-]+(:\d+)?$"#, options: .regularExpression) != nil else { return nil }
            candidate = "https://" + candidate
        }
        guard let url = URL(string: candidate), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host(), !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }

    /// Why a tool can't act on a tab showing `url`, or nil when it can.
    /// `errorPage`: the tab shows Zigzag's error or certificate warning page there, whose "Visit anyway" only
    /// the person may choose. `on`: AI apps are still allowed in Settings.
    static func refusal(url: URL?, isPrivate: Bool, stopped: Bool = false, errorPage: Bool = false, on: Bool = true,
                        needsPage: Bool = true) -> Refusal? {
        if !on { return .turnedOff }
        if isPrivate { return .privateWindow }
        if stopped { return .stopped }
        if errorPage { return .errorPage }
        guard let url, url.absoluteString != "about:blank" else { return needsPage ? .emptyTab : nil }
        switch url.scheme?.lowercased() ?? "" {
        case "http", "https": return nil
        case "zigzag": return .ownPage
        case "webkit-extension", "chrome-extension", "safari-web-extension": return .extensionPage
        default: return .notAWebPage
        }
    }

    static func message(_ refusal: Refusal) -> String {
        switch refusal {
        case .privateWindow: "That tab is in a private window. Zigzag keeps AI apps out of private windows."
        case .ownPage: "That tab shows one of Zigzag's own pages (Settings, History). AI apps can't use them."
        case .extensionPage: "That tab shows an extension's page. AI apps can't use extension pages."
        case .notAWebPage: "That tab doesn't show a website. Only http and https pages can be used."
        case .emptyTab: "That tab is empty. Navigate it to a page first."
        case .stopped: "The person using Zigzag stopped control of this tab. Leave it alone, or ask them first."
        case .errorPage: "That tab shows Zigzag's error or certificate warning page. AI apps can't use it; only the person can choose to go on. Go back, or open another page."
        case .turnedOff: "Zigzag's MCP server was turned off in Settings."
        }
    }

    /// A field whose value is a secret: never typed into, never read. Mirrors `isSecret` in the page script.
    static func isPasswordField(type: String?, autocomplete: String?) -> Bool {
        let type = (type ?? "").lowercased(), autocomplete = (autocomplete ?? "").lowercased()
        return type == "password" || autocomplete.contains("password")
    }

    /// A field whose value read_page leaves out: a password's, a card's number or code, a one-time code.
    /// Mirrors `hidesValue` in the page script.
    static func hidesValue(type: String?, autocomplete: String?) -> Bool {
        let autocomplete = (autocomplete ?? "").lowercased()
        return isPasswordField(type: type, autocomplete: autocomplete) || (type ?? "").lowercased() == "hidden"
            || ["cc-number", "cc-csc", "one-time-code"].contains { autocomplete.contains($0) }
    }
}
