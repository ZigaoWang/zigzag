import Foundation
import IOKit.ps

/// Whether to go easy on energy: on battery, or in Low Power Mode. Clear glass gives way to frosted meanwhile, and
/// comes back when you plug in. `changed` fires when either changes.
@MainActor
enum PowerSaving {
    static let changed = Notification.Name("PowerSavingChanged")

    static var isOn: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled || onBattery }

    /// Whether the Mac is running on its battery right now.
    nonisolated static var onBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeRetainedValue() as String? else { return false }
        return type == kIOPSBatteryPowerValue
    }

    private static var started = false

    /// Starts watching the power source and Low Power Mode.
    static func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            NotificationCenter.default.post(name: changed, object: nil)
        }
        if let source = IOPSNotificationCreateRunLoopSource({ _ in
            DispatchQueue.main.async { NotificationCenter.default.post(name: PowerSaving.changed, object: nil) }
        }, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }
}
