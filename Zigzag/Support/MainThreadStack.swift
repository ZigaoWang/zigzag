import Darwin
import os
import Foundation

/// What the main thread is doing right now, read from another thread: for a freeze note that says what Zigzag was
/// stuck in, not only for how long. The main thread is paused for the moment it takes to read its return addresses
/// (nothing is allocated meanwhile, so it can't be holding a lock this needs), then named once it runs again.
nonisolated enum MainThreadStack {
    struct Frame: Equatable, Sendable {
        /// The library or app it's in: "Zigzag", "WebKit", "AppKit".
        var image: String
        /// Its function, demangled and shortened; nil where the binary keeps no name for it.
        var symbol: String?
        /// Its place in the image, for looking up with the build's symbols when there's no name.
        var offset: UInt

        var isApp: Bool { image == MainThreadStack.appImage }
        var text: String { symbol.map { isApp ? $0 : "\($0) (\(image))" } ?? "\(image)+0x\(String(offset, radix: 16))" }
    }

    static let appImage = (Bundle.main.executableURL?.lastPathComponent).flatMap { $0.isEmpty ? nil : $0 } ?? "Zigzag"

    private static let deepest = 96

    /// The main thread, and where its stack is, as it said itself (`prepare`).
    private struct Main { let port: thread_act_t; let top: UInt; let bottom: UInt }
    private static let main = OSAllocatedUnfairLock<Main?>(initialState: nil)

    /// Called once on the main thread, before any `capture`.
    static func prepare() {
        guard Thread.isMainThread else { return }
        let me = pthread_self()
        let top = UInt(bitPattern: pthread_get_stackaddr_np(me))
        let found = Main(port: pthread_mach_thread_np(me), top: top, bottom: top - UInt(pthread_get_stacksize_np(me)))
        main.withLock { $0 = found }
    }

    /// The main thread's return addresses, innermost first; empty if it couldn't be read. From any thread but main.
    static func capture() -> [UInt] {
        #if arch(arm64)
        guard !Thread.isMainThread, let main = main.withLock({ $0 }) else { return [] }
        let port = main.port, top = main.top, bottom = main.bottom
        // Made before the pause: allocating while the main thread is stopped could wait on a lock it holds.
        let buffer = UnsafeMutablePointer<UInt>.allocate(capacity: deepest)
        defer { buffer.deallocate() }
        var count = 0
        guard thread_suspend(port) == KERN_SUCCESS else { return [] }
        var state = arm_thread_state64_t()
        var size = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let read = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(size)) { thread_get_state(port, ARM_THREAD_STATE64, $0, &size) }
        }
        if read == KERN_SUCCESS {
            buffer[0] = strip(UInt(state.__pc)); count = 1
            buffer[1] = strip(UInt(state.__lr)); count = 2
            var fp = strip(UInt(state.__fp))
            // Each frame starts with the one before it and where it returns to.
            while count < deepest, fp >= bottom, fp + 16 <= top, fp % 8 == 0 {
                let frame = UnsafePointer<UInt>(bitPattern: fp)!
                let next = strip(frame[0]), back = strip(frame[1])
                if back == 0 { break }
                buffer[count] = back
                count += 1
                // Stacks grow down: the caller's frame is always further up.
                guard next > fp else { break }
                fp = next
            }
        }
        thread_resume(port)
        return Array(UnsafeBufferPointer(start: buffer, count: count))
        #else
        return []
        #endif
    }

    /// Return addresses can carry a signature in their top bits.
    private static func strip(_ address: UInt) -> UInt { address & 0x0000_7FFF_FFFF_FFFF }

    /// Names each address: its image, and its function where the image says.
    static func frames(_ addresses: [UInt]) -> [Frame] {
        addresses.map { address in
            var info = Dl_info()
            // A return address points past the call; one back is inside it.
            guard dladdr(UnsafeRawPointer(bitPattern: max(address, 1) - 1), &info) != 0 else { return Frame(image: "?", symbol: nil, offset: address) }
            let image = info.dli_fname.map { URL(fileURLWithPath: String(cString: $0)).lastPathComponent } ?? "?"
            let offset = address - UInt(bitPattern: info.dli_fbase)
            let symbol = info.dli_sname.map { shortName(demangle(String(cString: $0))) }
            return Frame(image: image, symbol: symbol.flatMap { $0.isEmpty || $0.hasPrefix("<redacted") ? nil : $0 }, offset: offset)
        }
    }

    private typealias Demangle = @convention(c) (UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32) -> UnsafeMutablePointer<CChar>?
    private static let swiftDemangle: Demangle? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle").map { unsafeBitCast($0, to: Demangle.self) }

    private typealias CxaDemangle = @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UnsafeMutablePointer<Int32>?) -> UnsafeMutablePointer<CChar>?
    private static let cxaDemangle: CxaDemangle? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "__cxa_demangle").map { unsafeBitCast($0, to: CxaDemangle.self) }

    static func demangle(_ name: String) -> String {
        // C++ (WebKit's insides): "_ZN6WebKit11WebViewImpl19viewDidMoveToWindowEv" → "WebKit::WebViewImpl::viewDidMoveToWindow()".
        if name.hasPrefix("_Z"), let cxaDemangle {
            return name.withCString { pointer in
                var status: Int32 = 0
                guard let out = cxaDemangle(pointer, nil, nil, &status), status == 0 else { return name }
                defer { free(out) }
                return String(cString: out)
            }
        }
        let mangled = name.hasPrefix("_$s") || name.hasPrefix("$s") || name.hasPrefix("_T0")
        guard mangled, let swiftDemangle else { return name }
        return name.withCString { pointer in
            guard let out = swiftDemangle(pointer, strlen(pointer), nil, nil, 0) else { return name }
            defer { free(out) }
            return String(cString: out)
        }
    }

    /// "static Zigzag.BrowserWindowController.showPages(animated: Swift.Bool) -> ()" → "BrowserWindowController.showPages";
    /// a closure is named by the function it's in. Arguments and glue ("partial apply for", "thunk for") go, so a
    /// note stays short. Objective-C names stay as they are.
    static func shortName(_ name: String) -> String {
        var text = name.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("-[") || text.hasPrefix("+[") { return text }
        // A private function: "(isOurs in _1A2B3C)" → "isOurs".
        text = text.replacingOccurrences(of: #"\(([^()\s]+) in _[0-9A-Fa-f]+\)"#, with: "$1", options: .regularExpression)
        let prefixes = ["partial apply forwarder for ", "partial apply for ", "merged ", "specialized ", "reabstraction thunk helper from ",
                        "@objc ", "thunk for ", "static ", "dispatch thunk of ", "protocol witness for ", "@nonobjc ", "outlined ",
                        "async function pointer to ", "(1) suspend resume partial function for ", "(1) await resume partial function for "]
        var changed = true
        while changed {
            changed = false
            for prefix in prefixes where text.hasPrefix(prefix) {
                text.removeFirst(prefix.count)
                changed = true
            }
            // "generic specialization <…> of f" → f
            for kind in ["generic specialization <", "function signature specialization <"] where text.hasPrefix(kind) {
                guard let end = closing(in: text, from: text.index(text.startIndex, offsetBy: kind.count - 1)) else { continue }
                text = String(text[text.index(after: end)...])
                if text.hasPrefix(" of ") { text.removeFirst(4) }
                changed = true
            }
            // "closure #2 (Foo) -> () in f" → f: the closure is told by the function it's in.
            if text.hasPrefix("closure #") || text.hasPrefix("implicit closure #"), let range = topLevel(" in ", in: text) {
                text = String(text[range.upperBound...])
                changed = true
            }
        }
        // Its name, up to its arguments: a C++ template's or Swift's types can run to hundreds of characters.
        if let open = topLevelParen(in: text) { text = String(text[..<open]) }
        for module in [appImage + ".", "Zigzag."] where text.hasPrefix(module) { text.removeFirst(module.count) }
        return text
    }

    /// The `>` closing the `<` at `start`.
    private static func closing(in text: String, from start: String.Index) -> String.Index? {
        var depth = 0
        for index in text[start...].indices {
            if text[index] == "<" { depth += 1 } else if text[index] == ">" { depth -= 1; if depth == 0 { return index } }
        }
        return nil
    }

    /// Where `word` first appears outside any brackets.
    private static func topLevel(_ word: String, in text: String) -> Range<String.Index>? {
        var depth = 0
        var index = text.startIndex
        while index < text.endIndex {
            let c = text[index]
            if "(<[".contains(c) { depth += 1 } else if ")>]".contains(c) { depth = max(0, depth - 1) }
            if depth == 0, text[index...].hasPrefix(word) { return index..<text.index(index, offsetBy: word.count) }
            index = text.index(after: index)
        }
        return nil
    }

    /// Where a function's arguments start: its first `(` outside template brackets, past "(anonymous namespace)".
    private static func topLevelParen(in text: String) -> String.Index? {
        var depth = 0
        var index = text.startIndex
        while index < text.endIndex {
            let c = text[index]
            if c == "<" { depth += 1 } else if c == ">" { depth = max(0, depth - 1) }
            if c == "(", depth == 0, index > text.startIndex, !text[index...].hasPrefix("(anonymous namespace)") { return index }
            index = text.index(after: index)
        }
        return nil
    }

    /// Frames that only pass a call on: never what a note should name.
    static func isGlue(_ frame: Frame) -> Bool {
        guard let symbol = frame.symbol else { return false }
        let glue = ["MainActor.assumeIsolated", "Signal.send", "__CFRUNLOOP_", "_dispatch_", "__NSFireTimer", "__CFNOTIFICATION",
                    "_CFXRegistrationPost", "CFRunLoopRun", "_CFRunLoopRun", "__CFRunLoopDoTimer", "_NSSetObjectValueAndNotify",
                    "NSKeyValueNotifyObserver", "NSKeyValueDidChange", "-[NSObject(NSKeyValueObserverNotification)", "swift_task_", "_pthread_"]
        return glue.contains { symbol.hasPrefix($0) || symbol.contains($0) }
    }

    /// One line for a freeze note: the innermost of Zigzag's own frames that were running, outermost last, then
    /// what they were waiting in. "TabManager.select(_:) ← … | WebKit::…waitForMessage (WebKit)".
    static func summary(_ frames: [Frame], appFrames: Int = 4, systemFrames: Int = 2) -> String {
        guard let firstApp = frames.firstIndex(where: \.isApp) else {
            return frames.filter { !isGlue($0) }.prefix(systemFrames + 1).map(\.text).joined(separator: " ← ")
        }
        var own: [String] = []
        for frame in frames[firstApp...] where frame.isApp && !isGlue(frame) && frame.symbol != "main" {
            if own.last != frame.text { own.append(frame.text) }
            if own.count == appFrames { break }
        }
        // What Zigzag called into, and (when there's room) what that was doing at the very end: "a → b".
        let called = frames[..<firstApp].filter { !isGlue($0) }.map(\.text)
        var inside: [String] = []
        if systemFrames > 0, let entry = called.last { inside.append(entry) }
        if systemFrames > 1, let leaf = called.first, leaf != called.last { inside.append(leaf) }
        return own.joined(separator: " ← ") + (inside.isEmpty ? "" : " | in " + inside.joined(separator: " → "))
    }

    /// Waiting for something to do, in the run loop: none of Zigzag's code running (the app's `main` aside) and the
    /// thread asleep in the kernel. A look like this means the main thread wasn't stuck, only late to tick.
    static func isIdle(_ frames: [Frame]) -> Bool {
        guard let leaf = frames.first?.symbol, leaf.hasPrefix("mach_msg") else { return false }
        return !frames.contains { $0.isApp && $0.symbol != "main" }
    }

    /// Several looks during one freeze: the one most of them agree on (by where Zigzag's own code was), so a moment
    /// that happened to fall between two calls doesn't speak for the whole freeze.
    static func mostCommon(_ looks: [[Frame]]) -> [Frame]? {
        let keyed = looks.filter { !$0.isEmpty }.map { look in (key: summary(look, appFrames: 2, systemFrames: 0), look: look) }
        guard !keyed.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        for item in keyed { counts[item.key, default: 0] += 1 }
        let best = counts.max { a, b in a.value < b.value || (a.value == b.value && a.key > b.key) }?.key
        return keyed.first { $0.key == best }?.look
    }
}
