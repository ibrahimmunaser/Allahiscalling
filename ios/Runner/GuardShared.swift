import Foundation
#if canImport(FamilyControls)
import FamilyControls
#endif

/// Shared constants/helpers for App Guard on iOS (Screen Time shield),
/// compiled into the main app AND all three extension targets
/// (DeviceActivityMonitorExtension, ShieldConfigurationExtension,
/// ShieldActionExtension) — see `ios/scripts/setup_screen_time_targets.rb`,
/// which is what adds this one file to all four targets' Compile Sources.
///
/// The main app and its extensions run as separate processes; an App Group
/// container is the only way they can share the user's app/category
/// selection and the current prayer name.
enum GuardShared {
    /// Must also be enabled as an App Group capability (Signing & Capabilities)
    /// for the main app AND every extension target, and registered on the
    /// Apple Developer portal — this is a manual one-time setup step (see
    /// IOS_SCREEN_TIME_SETUP.md).
    static let appGroupId = "group.com.salahinvite.allahInvitesYouToSalah"

    static let defaults = UserDefaults(suiteName: appGroupId)

    private static let selectionKey = "guard_family_activity_selection_v1"
    private static let currentPrayerKey = "guard_current_prayer_name"
    private static let enabledKey = "guard_enabled"

    static var enabled: Bool {
        get { defaults?.bool(forKey: enabledKey) ?? false }
        set { defaults?.set(newValue, forKey: enabledKey) }
    }

    /// The prayer name for the guard window currently believed to be
    /// active, read by ShieldConfigurationExtension so the shield's
    /// subtitle can say e.g. "It's time for Dhuhr."; written by the main
    /// app whenever a guard window's schedule is (re)armed.
    static var currentPrayerName: String {
        get { defaults?.string(forKey: currentPrayerKey) ?? "Salah" }
        set { defaults?.set(newValue, forKey: currentPrayerKey) }
    }

    #if canImport(FamilyControls)
    @available(iOS 16.0, *)
    static func saveSelection(_ selection: FamilyActivitySelection) {
        guard let data = try? PropertyListEncoder().encode(selection) else { return }
        defaults?.set(data, forKey: selectionKey)
    }

    @available(iOS 16.0, *)
    static func loadSelection() -> FamilyActivitySelection {
        guard
            let data = defaults?.data(forKey: selectionKey),
            let selection = try? PropertyListDecoder().decode(FamilyActivitySelection.self, from: data)
        else {
            return FamilyActivitySelection()
        }
        return selection
    }
    #endif

    // "Decline" exemption needs no persisted state here: Apple's privacy
    // model never exposes a real app identifier to our process — only an
    // opaque ApplicationToken, handed to ShieldActionExtension for exactly
    // the app being unshielded. ShieldActionExtension removes that token
    // directly from ManagedSettingsStore().shield.applications; there is
    // nothing for the main app or the monitor extension to track.
}
