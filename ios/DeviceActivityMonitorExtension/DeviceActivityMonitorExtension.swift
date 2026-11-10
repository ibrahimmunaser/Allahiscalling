import DeviceActivity
import ManagedSettings

/// Applies/lifts the "Allah is calling" shield for the 15-minute window
/// around each prayer. One `DeviceActivitySchedule` per prayer is armed by
/// the main app (see `AppGuardManager.swift`) with today's computed prayer
/// time; re-armed daily when prayer times are recalculated.
class DeviceActivityMonitorExtension: DeviceActivityMonitor {
    private let store = ManagedSettingsStore(named: .init("allahIsCallingGuard"))

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        guard GuardShared.enabled else { return }

        GuardShared.currentPrayerName = activity.rawValue

        let selection = GuardShared.loadSelection()
        store.shield.applications = selection.applicationTokens.isEmpty
            ? nil
            : selection.applicationTokens
        store.shield.applicationCategories = selection.categoryTokens.isEmpty
            ? nil
            : .specific(selection.categoryTokens)
        store.shield.webDomains = selection.webDomainTokens.isEmpty
            ? nil
            : selection.webDomainTokens
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        store.shield.applications = nil
        store.shield.applicationCategories = nil
        store.shield.webDomains = nil
    }
}
