//
//  DictionarySchedule.swift
//  How often "Update automatically" asks GitHub for a newer community dictionary: Daily, Weekly or
//  Monthly (the user's choice; default MONTHLY, the cadence eigencrow's releases come out at - v26.08,
//  v26.09 ...). Pure logic, no app-group or bridge dependency, so `make userdict-test` compiles it as it
//  is. The store and the updater (App/DictionaryUpdater.swift) use `isDue`; nothing else decides.
//
//  iOS gives this app no background refresh, so a check happens when the app is opened or comes forward
//  and the chosen interval has passed since the last check - "Monthly" means "the first time the app
//  is opened a month or more after the last check".
//

import Foundation

enum DictionaryUpdateFrequency: String, CaseIterable, Identifiable, Sendable {
    case daily, weekly, monthly

    static let `default`: DictionaryUpdateFrequency = .monthly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        }
    }

    /// The nominal period, less a few hours of slack so that opening the app at about the same time of
    /// day (week, month) as last time still counts as due.
    var interval: TimeInterval {
        let hour: TimeInterval = 3600
        switch self {
        case .daily: return 24 * hour - 4 * hour
        case .weekly: return 7 * 24 * hour - 4 * hour
        case .monthly: return 30 * 24 * hour - 4 * hour
        }
    }

    /// The stored value, or the default for nothing stored / something unrecognised.
    init(stored: String?) {
        self = stored.flatMap(DictionaryUpdateFrequency.init(rawValue:)) ?? .default
    }
}

enum DictionarySchedule {
    /// Whether an automatic check should run now. Never when the switch or auto-update is off; always
    /// when there has never been a check; otherwise when the chosen interval has passed. A last check
    /// in the FUTURE (the clock was moved back) counts as due rather than blocking checks until then.
    static func isDue(enabled: Bool, autoUpdate: Bool, frequency: DictionaryUpdateFrequency,
                      lastCheck: Date?, now: Date) -> Bool {
        guard enabled, autoUpdate else { return false }
        guard let last = lastCheck else { return true }
        let elapsed = now.timeIntervalSince(last)
        if elapsed < 0 { return true }
        return elapsed >= frequency.interval
    }
}
