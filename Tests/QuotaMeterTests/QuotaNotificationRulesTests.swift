import XCTest
@testable import QuotaMeter

final class QuotaNotificationRulesTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    func testCrossingSeveralThresholdsReturnsOnlyLowestCrossedThreshold() {
        let previous = usage(at: base, fiveHour: limit(52, reset: base.addingTimeInterval(7200)))
        let current = usage(at: base.addingTimeInterval(180), fiveHour: limit(14, reset: base.addingTimeInterval(7200)))
        XCTAssertEqual(QuotaNotificationRules.events(previous: previous, current: current), [
            .threshold(period: .fiveHour, threshold: 15, remaining: 14,
                       resetAt: base.addingTimeInterval(7200))
        ])
    }

    func testDetectsFiveHourResetFromRecoveryAndNewResetTime() {
        let previous = usage(at: base, fiveHour: limit(4, reset: base.addingTimeInterval(60)))
        let current = usage(at: base.addingTimeInterval(180), fiveHour: limit(100, reset: base.addingTimeInterval(18_180)))
        XCTAssertEqual(QuotaNotificationRules.events(previous: previous, current: current), [
            .reset(period: .fiveHour, remaining: 100, resetAt: base.addingTimeInterval(18_180))
        ])
    }

    func testSmallIncreaseDoesNotLookLikeReset() {
        let previous = usage(at: base, fiveHour: limit(40, reset: base.addingTimeInterval(7200)))
        let current = usage(at: base.addingTimeInterval(180), fiveHour: limit(44, reset: base.addingTimeInterval(7380)))
        XCTAssertTrue(QuotaNotificationRules.events(previous: previous, current: current).isEmpty)
    }

    func testRepeatedSnapshotDoesNotNotify() {
        let previous = usage(at: base, fiveHour: limit(20, reset: base.addingTimeInterval(7200)))
        let current = usage(at: base, fiveHour: limit(10, reset: base.addingTimeInterval(7200)))
        XCTAssertTrue(QuotaNotificationRules.events(previous: previous, current: current).isEmpty)
    }

    private func limit(_ remaining: Double, reset: Date) -> Limit {
        Limit(remainingPercent: remaining, resetAt: reset)
    }

    private func usage(at date: Date, fiveHour: Limit? = nil, weekly: Limit? = nil) -> Usage {
        Usage(fetchedAt: date, source: "test", fiveHour: fiveHour, weekly: weekly)
    }
}
