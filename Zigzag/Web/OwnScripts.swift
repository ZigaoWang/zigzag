import WebKit

/// Taking some of Zigzag's own page scripts out of a web view's set, leaving every other script where it is.
///
/// WebKit's only public way is `removeAllUserScripts` and putting the rest back. But the set also holds what
/// extensions inject (WKWebExtension puts their content scripts there), and those came back as copies of Zigzag's
/// own, beside the ones the extension then put in again. With an extension on, a web view's set grew by a few hundred
/// kilobytes most times a page changed site, and every page made in a new process is sent the whole set: in time it
/// was more than WebKit could send, and Zigzag crashed going back, forward or to a link (#178).
enum OwnScripts {
    private static let removeOne = NSSelectorFromString("_removeUserScript:")

    /// Takes out the scripts `matching` picks. Returns how many there were.
    @discardableResult
    static func remove(from controller: WKUserContentController, where matching: (WKUserScript) -> Bool) -> Int {
        // Picked out first, into a list of Zigzag's own: the one WebKit hands over is its live set, and changes with it.
        let picked = controller.userScripts.filter(matching)
        guard !picked.isEmpty else { return 0 }
        if controller.responds(to: removeOne) {
            for script in picked { controller.perform(removeOne, with: script) }
        } else {
            let others = controller.userScripts.filter { !matching($0) }
            controller.removeAllUserScripts()
            others.forEach(controller.addUserScript)
        }
        return picked.count
    }
}
