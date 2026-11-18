import UniformTypeIdentifiers
import WebKit

/// Settings › Developer › Chrome DevTools (a preview): Chrome's own DevTools in place of WebKit's Web Inspector.
/// Chrome's frontend (DevToolsFrontend/, fetched by scripts/update-devtools-frontend.py) runs in a frame of WebKit's
/// inspector page, served from the app on `zigzag-devtools:`; devtools-bridge.js and devtools-adapter.js in that
/// page translate between the two protocols. Panels WebKit has nothing behind (Performance, Memory, Lighthouse)
/// stay empty.
@MainActor
enum ChromeDevTools {
    static var defaults: UserDefaults = .standard

    private static let key = "ChromeDevTools"

    /// Off until you turn it on. Takes effect the next time a Web Inspector opens.
    static var isOn: Bool {
        get { defaults.bool(forKey: key) }
        set {
            guard newValue != isOn else { return }
            defaults.set(newValue, forKey: key)
            DeveloperTools.changed.send()
        }
    }

    static let scheme = "zigzag-devtools"
    static let scriptMark = "// zigzag-chrome-devtools\n"

    /// The inspector's own configuration (WKUIDelegatePrivate `_webView:configurationForLocalInspector:`): where
    /// Chrome's frontend is served from.
    static func inspectorConfiguration() -> NSObject? {
        guard let type = NSClassFromString("_WKInspectorConfiguration") as? NSObject.Type else { return nil }
        let configuration = type.init()
        let selector = NSSelectorFromString("setURLSchemeHandler:forURLScheme:")
        guard configuration.responds(to: selector) else { return configuration }
        _ = configuration.perform(selector, with: FrontendFiles.shared, with: scheme)
        return configuration
    }

    /// The bridge and the translator, in the inspector's page from its start, with the choice written in.
    static func install(in controller: WKUserContentController) {
        let others = controller.userScripts.filter { !$0.source.hasPrefix(scriptMark) }
        if others.count != controller.userScripts.count {
            controller.removeAllUserScripts()
            others.forEach(controller.addUserScript)
        }
        controller.addUserScript(WKUserScript(source: scriptMark + adapter, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: bridgeSource(on: isOn), injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    static func bridgeSource(on: Bool) -> String {
        scriptMark + bridge.replacingOccurrences(of: "__CONFIG__", with: on ? "{\"on\": true}" : "{\"on\": false}")
    }

    private static func resource(_ name: String) -> String {
        Bundle.main.url(forResource: name, withExtension: "js").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }

    private static let adapter = resource("devtools-adapter")
    private static let bridge = resource("devtools-bridge")
    static let host = resource("devtools-host")
}

/// Chrome's frontend, file by file, from the app: its page with our stand-in for Chrome's browser added first.
final class FrontendFiles: NSObject, WKURLSchemeHandler {
    @MainActor static let shared = FrontendFiles()

    static let root = Bundle.main.resourceURL?.appendingPathComponent("DevToolsFrontend", isDirectory: true)

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let (data, type) = Self.file(at: url.path) else {
            if let url = task.request.url {
                #if DEBUG
                debugLog("devtools: no file for \(url.path)")
                #endif
                task.didReceive(HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!)
            }
            task.didFinish()
            return
        }
        let headers = ["Content-Type": type, "Content-Length": String(data.count)]
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    /// A file of the frontend and its type, never one outside its folder.
    nonisolated static func file(at path: String) -> (Data, String)? {
        guard let root else { return nil }
        let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
        if relative == "zigzag-host.js" {
            return MainActor.assumeIsolated { (Data(ChromeDevTools.host.utf8), "text/javascript; charset=utf-8") }
        }
        let file = root.appendingPathComponent(relative).standardizedFileURL
        guard file.path.hasPrefix(root.standardizedFileURL.path + "/"), var data = try? Data(contentsOf: file) else { return nil }
        if relative == "devtools_app.html", let page = String(data: data, encoding: .utf8) {
            data = Data(withHost(page).utf8)
        }
        return (data, mimeType(of: file))
    }

    /// Chrome's page with our host and Chrome's compatibility layer before its modules, as Chrome's browser loads it.
    nonisolated static func withHost(_ page: String) -> String {
        let first = "<script src=\"./zigzag-host.js\"></script><script src=\"./devtools_compatibility.js\"></script>"
        guard let module = page.range(of: "<script type=\"module\"") else { return page }
        return page.replacingCharacters(in: module.lowerBound..<module.lowerBound, with: first)
    }

    nonisolated static func mimeType(of file: URL) -> String {
        switch file.pathExtension {
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "html": return "text/html; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "wasm": return "application/wasm"
        default: return UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        }
    }
}
