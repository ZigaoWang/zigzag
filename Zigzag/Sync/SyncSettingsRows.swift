import AppKit

/// Settings › General › Sync with iCloud: the switch, and under it how sync is doing.
final class SyncSettingsRows {
    let toggle = Toggle()
    let row: FormRow
    let statusRow: FormRow
    private let action = PillButton(title: "")
    private let secondAction = PillButton(title: "")
    /// The page lays itself out again when the status line changes size.
    var onLayout: (() -> Void)?
    private var token: SignalToken?
    private var timer: Timer?
    private let sync: ICloudSync

    init(sync: ICloudSync = .shared) {
        self.sync = sync
        row = FormRow(title: String(localized: "Sync with iCloud", comment: "A setting in Settings › General: syncs spaces, pinned tabs, favorites and settings between your Macs through iCloud."),
                      detail: String(localized: "Your spaces, pinned tabs, favorites and settings on every Mac signed in to your iCloud.",
                                     comment: "Explanation under “Sync with iCloud” in Settings › General."),
                      control: toggle)
        row.keywords = String(localized: "icloud sync cloud macs devices mac computers", comment: "Words that find the Sync with iCloud setting with Find a setting in Settings. Not shown.")
        // In a stack, so the line has the whole row when there's no button.
        statusRow = FormRow(title: "", control: NSStackView(views: [secondAction, action]))
        statusRow.isIndented = true
        statusRow.titleColor = Tokens.Color.textSecondary
        toggle.isOn = sync.isOn
        toggle.onChange = { [weak self] on in self?.switched(on) }
        action.onClick = { [weak self] _ in self?.act() }
        secondAction.onClick = { [weak self] _ in self?.confirmRemoveEverywhere() }
        token = sync.changed.observe { [weak self] in self?.refresh() }
        // "Last synced 2 minutes ago" keeps its minutes.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        refresh()
    }

    isolated deinit { timer?.invalidate() }

    private var host: NSView? { row.window?.contentView }

    private func switched(_ on: Bool) {
        guard on else { sync.turnOff(); refresh(); return }
        guard let host else { toggle.isOn = false; return }
        let sheet = Self.turnOnSheet
        ConfirmSheet.show(in: host, title: sheet.title, message: sheet.message, confirmTitle: sheet.confirm) { [weak self] confirmed in
            guard let self else { return }
            if confirmed { self.sync.turnOn() } else { self.toggle.isOn = false }
            self.refresh()
        }
    }

    typealias Sheet = (title: String, message: String, confirm: String)

    /// Turning it on: what syncs, what doesn't, and that it merges.
    static var turnOnSheet: Sheet {
        (String(localized: "Sync with iCloud?", comment: "Title of the sheet shown when Sync with iCloud is turned on in Settings › General."),
         String(localized: "Your spaces, profiles, pinned tabs, folders, favorites, live folders and settings sync through your own iCloud. Open tabs, history, passwords, website data, extensions and downloads stay on this Mac. What’s here and what’s in iCloud are put together: where something is in both, the newer edit wins, and nothing is removed without asking. A backup is saved first.",
                comment: "Message of the sheet shown when Sync with iCloud is turned on in Settings › General. Passwords already sync through iCloud Keychain."),
         String(localized: "Continue", comment: "Button of the sheet shown when Sync with iCloud is turned on: turns it on."))
    }

    static var removeSheet: Sheet {
        (String(localized: "Remove your library from iCloud?", comment: "Title of the sheet behind Remove from iCloud… in Settings › General."),
         String(localized: "Your spaces, pinned tabs, favorites and settings are removed from iCloud and stop syncing on all your Macs. Everything on this Mac stays as it is.",
                comment: "Message of the sheet behind Remove from iCloud… in Settings › General."),
         String(localized: "Remove", comment: "Button of the sheet behind Remove from iCloud… in Settings › General: removes the synced library from iCloud."))
    }

    #if DEBUG
    static var sheets: [(name: String, sheet: Sheet)] {
        [("turn on", turnOnSheet), ("remove", removeSheet), ("remove everywhere", removeEverywhereSheet([.page: 16, .space: 1]))]
    }
    #endif

    private func confirmRemoveEverywhere() {
        guard case .removalsHeld(let counts, _) = sync.status, let host else { return }
        let sheet = Self.removeEverywhereSheet(counts)
        ConfirmSheet.show(in: host, title: sheet.title, message: sheet.message, confirmTitle: sheet.confirm, destructive: true) { [weak self] confirmed in
            guard confirmed, let self else { return }
            self.sync.sendRemovals()
            self.refresh()
        }
    }

    private enum Action { case none, openSettings, remove, bringBack }
    private var current: Action = .none

    private func act() {
        switch current {
        case .openSettings:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings")!)
        case .remove:
            guard let host else { return }
            let sheet = Self.removeSheet
            ConfirmSheet.show(in: host, title: sheet.title, message: sheet.message, confirmTitle: sheet.confirm, destructive: true) { [weak self] confirmed in
                guard confirmed, let self else { return }
                Task {
                    _ = await self.sync.removeFromICloud()
                    self.refresh()
                }
            }
        case .bringBack:
            sync.bringBackRemovals()
            refresh()
        case .none:
            break
        }
    }

    /// The status line and its button for what sync is doing now. Removals held come first, with what else is going on.
    static func describe(_ status: ICloudSync.Status, hasCopy: Bool, now: Date = Date()) -> (text: String, detail: String, action: String?, second: String?) {
        guard case .removalsHeld(let counts, let other) = status else {
            let shown = describeOne(status, hasCopy: hasCopy, now: now)
            return (shown.text, shown.detail, shown.action, nil)
        }
        let held = String(localized: "Removed on this Mac at once: \(SyncKind.list(counts))",
                          comment: "Status under Sync with iCloud in Settings › General, and a toast, when many spaces, pinned tabs or favorites went missing at once at launch or when sync was turned on (an old copy of the library put back, say). The placeholder lists them, like “16 pinned tabs and 1 space”.")
        let explanation = String(localized: "They’re hidden here and stay in iCloud until you choose. Restore brings them back here; Remove Everywhere removes them from iCloud and your other Macs too.",
                                 comment: "Explanation under “Removed on this Mac at once” in Settings › General. Restore and Remove Everywhere are the two buttons beside it. The rest keeps syncing.")
        var besides = ""
        switch other {
        case .notSignedIn, .otherAccount, .restricted, .full, .offline, .notEntitled, .failed: besides = describeOne(other, hasCopy: hasCopy, now: now).text
        default: break
        }
        return (held, Words.sentences(besides, explanation),
                String(localized: "Restore", comment: "Button beside “Removed on this Mac at once” in Settings › General: brings them back from iCloud."),
                String(localized: "Remove Everywhere", comment: "Button beside “Removed on this Mac at once” in Settings › General: removes them from iCloud and the other Macs too, after asking."))
    }

    /// Asked before Remove Everywhere: how many of what.
    static func removeEverywhereSheet(_ counts: [SyncKind: Int]) -> Sheet {
        (String(localized: "Remove \(SyncKind.list(counts)) from iCloud and every Mac?",
                comment: "Title of the sheet behind Remove Everywhere in Settings › General. The placeholder lists what was removed on this Mac at once, like “16 pinned tabs and 1 space”."),
         String(localized: "This can’t be undone.", comment: "Message of the sheet behind Remove Everywhere in Settings › General."),
         String(localized: "Remove", comment: "Button of the sheet behind Remove Everywhere in Settings › General: removes them from iCloud and every Mac."))
    }

    private static func describeOne(_ status: ICloudSync.Status, hasCopy: Bool, now: Date) -> (text: String, detail: String, action: String?) {
        let remove = String(localized: "Remove from iCloud…", comment: "Button beside the status of Sync with iCloud in Settings › General: removes the synced library from iCloud, after asking.")
        switch status {
        case .off:
            return hasCopy ? (String(localized: "Not syncing", comment: "Status under Sync with iCloud in Settings › General while it's off and iCloud still has a copy."), "", remove) : ("", "", nil)
        case .syncing:
            return (String(localized: "Syncing…", comment: "Status under Sync with iCloud in Settings › General."), "", remove)
        case .synced(let date):
            guard let date, now.timeIntervalSince(date) >= 60 else {
                return (String(localized: "Up to date", comment: "Status under Sync with iCloud in Settings › General: everything has synced."), "", remove)
            }
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = Words.locale
            formatter.unitsStyle = .full
            let ago = formatter.localizedString(for: date, relativeTo: now)
            return (String(localized: "Last synced \(ago)", comment: "Status under Sync with iCloud in Settings › General. The placeholder says how long ago, like “2 minutes ago”."), "", remove)
        case .notSignedIn:
            return (String(localized: "Not signed in to iCloud", comment: "Status under Sync with iCloud in Settings › General."), "",
                    String(localized: "Open System Settings", comment: "Button beside “Not signed in to iCloud” in Settings › General: opens Apple Account in System Settings."))
        case .otherAccount:
            return (String(localized: "Signed in to a different iCloud account", comment: "Status under Sync with iCloud in Settings › General: this Mac's iCloud account changed since sync was turned on."),
                    String(localized: "Turn sync off and on again to merge with this account. Nothing on this Mac has changed.", comment: "Explanation under “Signed in to a different iCloud account” in Settings › General."), nil)
        case .restricted:
            return (String(localized: "iCloud isn’t available on this Mac", comment: "Status under Sync with iCloud in Settings › General: iCloud is turned off by a profile or Screen Time."), "", nil)
        case .full:
            return (String(localized: "iCloud is full", comment: "Status under Sync with iCloud in Settings › General: the iCloud storage is used up."),
                    String(localized: "Changes wait on this Mac until there’s room.", comment: "Explanation under “iCloud is full” in Settings › General."), remove)
        case .offline:
            return (String(localized: "Can’t reach iCloud. Zigzag tries again.", comment: "Status under Sync with iCloud in Settings › General: no connection, or iCloud is busy."), "", nil)
        case .removedElsewhere:
            return (String(localized: "Removed from iCloud on another Mac", comment: "Status under Sync with iCloud in Settings › General."),
                    String(localized: "Sync is off. Everything on this Mac stays as it is.", comment: "Explanation under “Removed from iCloud on another Mac” in Settings › General."), nil)
        case .backupFailed:
            return (String(localized: "Couldn’t save a backup first, so sync is still off.", comment: "Status under Sync with iCloud in Settings › General, when turning it on couldn't save the backup it makes first (the disk is full, say)."), "", nil)
        case .notEntitled:
            return (String(localized: "This copy of Zigzag can’t use iCloud", comment: "Status under Sync with iCloud in Settings › General, for a build signed without iCloud."), "", nil)
        case .failed(let message):
            return (String(localized: "iCloud couldn’t sync: \(message)", comment: "Status under Sync with iCloud in Settings › General. The placeholder is iCloud's own explanation."), "", remove)
        case .removalsHeld(_, let other):
            return describeOne(other, hasCopy: hasCopy, now: now)
        }
    }

    func refresh() { show(sync.status, isOn: sync.isOn, hasCopy: sync.hasCopy) }

    /// The rows for a status: the switch, the line under it and its button.
    func show(_ status: ICloudSync.Status, isOn: Bool, hasCopy: Bool) {
        let shown = Self.describe(status, hasCopy: hasCopy)
        toggle.isOn = isOn
        let was = (statusRow.isAvailable, statusRow.titleText, statusRow.detailText, action.isHidden, secondAction.isHidden)
        statusRow.isAvailable = !shown.text.isEmpty
        statusRow.titleText = shown.text
        statusRow.detailText = shown.detail
        action.isHidden = shown.action == nil
        if let title = shown.action { action.title = title }
        secondAction.isHidden = shown.second == nil
        if let title = shown.second { secondAction.title = title }
        let held = if case .removalsHeld = status { true } else { false }
        current = shown.action == nil ? .none : status == .notSignedIn ? .openSettings : held ? .bringBack : .remove
        if was != (statusRow.isAvailable, statusRow.titleText, statusRow.detailText, action.isHidden, secondAction.isHidden) { onLayout?() }
    }

    #if DEBUG
    /// Every status the line can show, for the layout tests and pictures.
    static let everyStatus: [(name: String, status: ICloudSync.Status, isOn: Bool, hasCopy: Bool)] = [
        ("off", .off, false, false), ("off with a copy", .off, false, true), ("syncing", .syncing, true, true),
        ("up to date", .synced(Date()), true, true), ("last synced", .synced(Date().addingTimeInterval(-120)), true, true),
        ("not signed in", .notSignedIn, true, true), ("other account", .otherAccount, true, true), ("restricted", .restricted, true, true),
        ("full", .full, true, true), ("offline", .offline, true, true), ("removed elsewhere", .removedElsewhere, false, false),
        ("not entitled", .notEntitled, true, false), ("backup failed", .backupFailed, false, false), ("failed", .failed("The request timed out."), true, true),
        ("removals held", .removalsHeld([.page: 16, .space: 1], .synced(Date())), true, true),
        ("removals held, offline", .removalsHeld([.page: 16, .folder: 2], .offline), true, true),
    ]
    #endif
}
