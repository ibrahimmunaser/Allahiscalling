import ManagedSettings
import ManagedSettingsUI
import UIKit

/// Styles the Screen Time shield Apple shows over a guarded app: title
/// "Allah Is Calling", the current prayer as the subtitle, and Answer /
/// Decline as the two buttons. This is Apple's own shield view — only
/// labels, colors, an icon and a blur style are customizable (no custom
/// SwiftUI/UIKit view is possible here).
class ShieldConfigurationExtension: ShieldConfigurationDataSource {
    private let deepGreen = UIColor(red: 0x0E / 255, green: 0x3B / 255, blue: 0x2E / 255, alpha: 1)
    private let gold = UIColor(red: 0xC9 / 255, green: 0xA2 / 255, blue: 0x4B / 255, alpha: 1)
    private let ivory = UIColor(red: 0xF7 / 255, green: 0xF4 / 255, blue: 0xEC / 255, alpha: 1)

    private func configuration() -> ShieldConfiguration {
        let prayer = GuardShared.currentPrayerName
        return ShieldConfiguration(
            backgroundBlurStyle: .systemMaterialDark,
            backgroundColor: deepGreen,
            icon: UIImage(systemName: "building.columns.fill"),
            title: ShieldConfiguration.Label(text: "Allah Is Calling", color: ivory),
            subtitle: ShieldConfiguration.Label(
                text: "It's time for \(prayer). This app will stay closed for a few more minutes.",
                color: ivory.withAlphaComponent(0.9)
            ),
            primaryButtonLabel: ShieldConfiguration.Label(text: "Answer", color: deepGreen),
            primaryButtonBackgroundColor: gold,
            secondaryButtonLabel: ShieldConfiguration.Label(text: "Decline", color: .systemRed)
        )
    }

    override func configuration(shielding application: Application) -> ShieldConfiguration {
        configuration()
    }

    override func configuration(
        shielding application: Application,
        in category: ActivityCategory
    ) -> ShieldConfiguration {
        configuration()
    }

    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        configuration()
    }

    override func configuration(
        shielding webDomain: WebDomain,
        in category: ActivityCategory
    ) -> ShieldConfiguration {
        configuration()
    }
}
