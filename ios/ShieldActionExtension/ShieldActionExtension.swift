import ManagedSettings

/// Handles Answer / Decline taps on the Screen Time shield.
///
/// Answer closes the guarded app and leaves the shield in place — it will
/// reappear if the app is opened again before the window ends (mirrors the
/// Android guard screen's Answer behavior: go home, stay guarded).
///
/// Decline removes just this one app/category/domain's token from the
/// store for the rest of the current guard window, then returns the user
/// to it (mirrors Android's Decline: allow this app for now).
class ShieldActionExtension: ShieldActionDelegate {
    private let store = ManagedSettingsStore(named: .init("allahIsCallingGuard"))

    override func handle(
        action: ShieldAction,
        for application: ApplicationToken,
        completionHandler: @escaping (ShieldActionResponse) -> Void
    ) {
        switch action {
        case .primaryButtonPressed:
            completionHandler(.close)
        case .secondaryButtonPressed:
            if var apps = store.shield.applications {
                apps.remove(application)
                store.shield.applications = apps.isEmpty ? nil : apps
            }
            completionHandler(.defer)
        @unknown default:
            completionHandler(.close)
        }
    }

    override func handle(
        action: ShieldAction,
        for category: ActivityCategoryToken,
        completionHandler: @escaping (ShieldActionResponse) -> Void
    ) {
        switch action {
        case .primaryButtonPressed:
            completionHandler(.close)
        case .secondaryButtonPressed:
            if case .specific(var categories, except: let except) = store.shield.applicationCategories {
                categories.remove(category)
                store.shield.applicationCategories = categories.isEmpty && except.isEmpty
                    ? nil
                    : .specific(categories, except: except)
            }
            completionHandler(.defer)
        @unknown default:
            completionHandler(.close)
        }
    }

    override func handle(
        action: ShieldAction,
        for webDomain: WebDomainToken,
        completionHandler: @escaping (ShieldActionResponse) -> Void
    ) {
        switch action {
        case .primaryButtonPressed:
            completionHandler(.close)
        case .secondaryButtonPressed:
            if var domains = store.shield.webDomains {
                domains.remove(webDomain)
                store.shield.webDomains = domains.isEmpty ? nil : domains
            }
            completionHandler(.defer)
        @unknown default:
            completionHandler(.close)
        }
    }
}
