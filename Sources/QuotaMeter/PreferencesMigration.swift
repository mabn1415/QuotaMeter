import Foundation

/// Read only the known application keys; never copy a whole preferences domain.
enum PreferencesMigration {
    static let marker = "quotaMeterLegacyPreferencesImported"
    static let keys = ["intervalMinutes", "displayWeekly", "onboardingV29Completed"]

    static func apply(to defaults: UserDefaults, legacy: [String: Any]?) {
        guard !defaults.bool(forKey: marker) else { return }
        for key in keys where defaults.object(forKey: key) == nil {
            if let value = legacy?[key] { defaults.set(value, forKey: key) }
        }
        defaults.set(true, forKey: marker)
    }
}
