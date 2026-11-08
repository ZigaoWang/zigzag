import AppKit

/// Where downloads go, as one menu shared by Settings and the downloads panel, so the two always agree: the folder
/// (with its own icon), Ask Each Time, and Choose Folder… to pick one.
enum DownloadPlace {
    static func configure(_ button: DropdownButton) {
        let folder = DownloadManager.folder
        let icon = NSWorkspace.shared.icon(forFile: folder.path)
        icon.size = NSSize(width: 16, height: 16)
        button.options = [DropdownButton.Option(title: FileManager.default.displayName(atPath: folder.path), image: icon),
                          DropdownButton.Option(title: String(localized: "Ask Each Time", comment: "Choice in the menu of where downloads go, in Settings and the downloads panel."), image: nil),
                          DropdownButton.Option(title: String(localized: "Choose Folder…", comment: "Choice in the menu of where downloads go, in Settings and the downloads panel."), image: nil)]
        button.selectedIndex = DownloadManager.asksWhereToSave ? 1 : 0
    }

    /// Applies a pick from the menu; Choose Folder… asks for a folder first. Every menu showing the choice is updated.
    static func pick(_ index: Int) {
        switch index {
        case 0: DownloadManager.asksWhereToSave = false
        case 1: DownloadManager.asksWhereToSave = true
        default:
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = String(localized: "Choose", comment: "Button of the panel that picks the downloads folder.")
            panel.message = String(localized: "Choose where downloads are saved.", comment: "Message of the panel that picks the downloads folder.")
            panel.directoryURL = DownloadManager.folder
            if panel.runModal() == .OK, let url = panel.url {
                DownloadManager.folder = url
                DownloadManager.asksWhereToSave = false
            }
        }
        changed.send(())
    }

    @MainActor static let changed = Signal<Void>()
}
