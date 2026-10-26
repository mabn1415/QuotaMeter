import Foundation

enum QuotaPeriod: String, CaseIterable {
    case fiveHour
    case weekly

    var title: String {
        switch self {
        case .fiveHour: return "5 時間枠"
        case .weekly: return "週間枠"
        }
    }
}

enum QuotaNotificationEvent: Equatable {
    case threshold(period: QuotaPeriod, threshold: Int, remaining: Int, resetAt: Date?)
    case reset(period: QuotaPeriod, remaining: Int, resetAt: Date?)
}

enum QuotaNotificationRules {
    static let thresholds = [50, 20, 15, 10, 5, 0]

    static func events(previous: Usage, current: Usage) -> [QuotaNotificationEvent] {
        guard current.fetchedAt > previous.fetchedAt else { return [] }
        return [
            event(period: .fiveHour, previous: previous.fiveHour, current: current.fiveHour,
                  fetchedAt: current.fetchedAt),
            event(period: .weekly, previous: previous.weekly, current: current.weekly,
                  fetchedAt: current.fetchedAt)
        ].compactMap { $0 }
    }

    private static func event(period: QuotaPeriod, previous: Limit?, current: Limit?,
                              fetchedAt: Date) -> QuotaNotificationEvent? {
        guard let previous, let current else { return nil }
        let oldValue = previous.remainingPercent
        let newValue = current.remainingPercent
        let increase = newValue - oldValue
        let resetMovedForward: Bool
        if let oldReset = previous.resetAt, let newReset = current.resetAt {
            resetMovedForward = newReset.timeIntervalSince(oldReset) > 3600
        } else {
            resetMovedForward = false
        }
        let previousResetPassed = previous.resetAt.map { $0 <= fetchedAt.addingTimeInterval(300) } ?? false
        if increase >= 50 || (increase >= 10 && (resetMovedForward || previousResetPassed)) {
            return .reset(period: period, remaining: Int(newValue.rounded()), resetAt: current.resetAt)
        }

        let crossed = thresholds.filter { oldValue > Double($0) && newValue <= Double($0) }
        guard let threshold = crossed.min() else { return nil }
        return .threshold(period: period, threshold: threshold,
                          remaining: Int(newValue.rounded()), resetAt: current.resetAt)
    }
}
