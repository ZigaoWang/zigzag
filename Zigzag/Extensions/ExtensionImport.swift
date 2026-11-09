import Foundation

/// Adding the extensions brought over from another browser: each downloaded and checked first, so the one question
/// shows what they really are, then added one at a time, each loaded before the next starts. Loading dozens at once
/// once froze the whole Mac.
///
/// The steps are passed in, so the order and what a failure does can be checked without the network.
enum ExtensionImport {
    struct Failure: Hashable {
        let found: ChromiumExtensions.Found
        /// One plain line ("Not in the Chrome Web Store any more.").
        let reason: String
    }

    struct Steps<Prepared> {
        /// Download, verify and read one, without adding it.
        var prepare: (String) async -> Result<Prepared, ExtensionStore.InstallError>
        /// Add one already prepared, and load it. Returns its name.
        var finish: (Prepared) async -> Result<String, ExtensionStore.InstallError>
        /// Throw away one prepared but not added.
        var discard: (Prepared) -> Void
        /// A breath between one extension loading and the next, so each settles first.
        var pause: Duration = .milliseconds(400)
    }

    /// Gets each one ready, in order. Stopped (the window closed), what was ready is thrown away.
    static func prepare<P>(_ found: [ChromiumExtensions.Found], with steps: Steps<P>,
                           progress: (Int) -> Void = { _ in }) async -> (ready: [(ChromiumExtensions.Found, P)], failed: [Failure]) {
        var ready: [(ChromiumExtensions.Found, P)] = [], failed: [Failure] = []
        for (index, item) in found.enumerated() {
            if Task.isCancelled {
                ready.forEach { steps.discard($0.1) }
                return ([], failed)
            }
            progress(index)
            switch await steps.prepare(item.id) {
            case .success(let prepared): ready.append((item, prepared))
            case .failure(let error): failed.append(Failure(found: item, reason: error.reason))
            }
        }
        return (ready, failed)
    }

    /// Adds the prepared ones, one after another. Stopped, the rest are thrown away, never half added.
    static func install<P>(_ ready: [(ChromiumExtensions.Found, P)], with steps: Steps<P>,
                           progress: (Int, ChromiumExtensions.Found) -> Void = { _, _ in }) async -> (added: [(ChromiumExtensions.Found, String)], failed: [Failure]) {
        var added: [(ChromiumExtensions.Found, String)] = [], failed: [Failure] = []
        for (index, (item, prepared)) in ready.enumerated() {
            if index > 0, steps.pause > .zero { try? await Task.sleep(for: steps.pause) }
            if Task.isCancelled {
                ready[index...].forEach { steps.discard($0.1) }
                break
            }
            progress(index, item)
            switch await steps.finish(prepared) {
            case .success(let name): added.append((item, name.isEmpty ? item.name : name))
            case .failure(let error): failed.append(Failure(found: item, reason: error.reason))
            }
        }
        return (added, failed)
    }

    /// Zigzag's own install path: the same download, signature check, package checks and loading as adding one
    /// from the store's page. `profile`: the one they're added to.
    static func store(in profile: Profile) -> Steps<ExtensionStore.PreparedInstall> {
        Steps(prepare: { await ExtensionStore.prepareInstall($0) },
              finish: { await ExtensionStore.finishInstall($0, in: profile) },
              discard: { ExtensionStore.discard($0) })
    }
}
