import XCTest
@testable import QuotaMeter

final class PreferencesMigrationTests: XCTestCase {
    func testImportsOnlyKnownKeysAndDoesNotOverwriteOrRepeat() {
        let domain = "local.quotameter.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(5, forKey: "intervalMinutes")
        PreferencesMigration.apply(to: defaults, legacy: [
            "intervalMinutes": 2, "displayWeekly": true,
            "onboardingV29Completed": true, "unrelatedSecret": "test-value"
        ])
        XCTAssertEqual(defaults.integer(forKey: "intervalMinutes"), 5)
        XCTAssertTrue(defaults.bool(forKey: "onboardingV29Completed"))
        XCTAssertTrue(defaults.bool(forKey: "displayWeekly"))
        XCTAssertNil(defaults.object(forKey: "unrelatedSecret"))
        defaults.set(false, forKey: "displayWeekly")
        PreferencesMigration.apply(to: defaults, legacy: ["displayWeekly": true])
        XCTAssertFalse(defaults.bool(forKey: "displayWeekly"))
    }
    func testFreshInstallAndStorageCompatibility() {
        let domain = "local.quotameter.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        PreferencesMigration.apply(to: defaults, legacy: nil)
        XCTAssertTrue(defaults.bool(forKey: PreferencesMigration.marker))
        XCTAssertNil(defaults.object(forKey: "intervalMinutes"))
        XCTAssertTrue(Storage.directory.path.hasSuffix("/Library/Application Support/AllowanceMonitor"))
    }
}
