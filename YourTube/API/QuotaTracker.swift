import Foundation
import Observation

/// Tracks YouTube Data API quota consumption against the 10,000 units/day
/// default allowance.
///
/// A full 100-channel feed refresh costs ~102 units, so normal use isn't close
/// to the ceiling — but a bug that turns a paginated read into a loop would
/// burn the day's quota in seconds, so it's worth counting.
///
/// Note the quota resets at midnight US Pacific, not local midnight.
@Observable
@MainActor
final class QuotaTracker {
    static let dailyLimit = 10_000

    private let defaults: UserDefaults
    private let usedKey = "quota.unitsUsed"
    private let periodKey = "quota.periodStart"

    private(set) var unitsUsedToday: Int
    private(set) var periodStart: Date

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.unitsUsedToday = defaults.integer(forKey: usedKey)
        self.periodStart = defaults.object(forKey: periodKey) as? Date ?? .distantPast
        rolloverIfNeeded()
    }

    var remaining: Int { max(0, Self.dailyLimit - unitsUsedToday) }

    func record(units: Int) {
        rolloverIfNeeded()
        unitsUsedToday += units
        defaults.set(unitsUsedToday, forKey: usedKey)
    }

    private func rolloverIfNeeded() {
        let current = Self.currentPeriodStart()
        guard current > periodStart else { return }
        periodStart = current
        unitsUsedToday = 0
        defaults.set(0, forKey: usedKey)
        defaults.set(current, forKey: periodKey)
    }

    /// Midnight in US Pacific, which is when Google rolls the quota over.
    static func currentPeriodStart(now: Date = .now) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .gmt
        return calendar.startOfDay(for: now)
    }
}
