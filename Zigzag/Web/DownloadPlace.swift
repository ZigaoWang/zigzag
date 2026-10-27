import AppKit

/// Where downloads go, as one menu shared by Settings and the downloads panel, so the two always agree: the folder
/// (with its own icon), Ask Each Time, and Other… to pick a folder.
enum DownloadPlace {
    static func configure(_ button: MenuButton) {
        let folder = DownloadManager.folder
        let icon = NSWorkspace.shared.icon(forFile: folder.path)
        icon.size = NSSize(width: 16, height: 16)
        button.options = [MenuButton.Option(title: FileManager.default.displayName(atPath: folder.path), image: icon),
                          MenuButton.Option(title: "Ask Each Time", image: nil),
                          MenuButton.Option(title: "Other…", image: nil)]
        button.selectedIndex = DownloadManager.asksWhereToSave ? 1 : 0
    }

    /// Applies a pick from the menu; Other… asks for a folder first. Every menu showing the choice is updated.
    static func pick(_ index: Int) {
        switch index {
        case 0: DownloadManager.asksWhereToSave = false
        case 1: DownloadManager.asksWhereToSave = true
        default:
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Choose"
            panel.message = "Choose where downloads are saved."
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
