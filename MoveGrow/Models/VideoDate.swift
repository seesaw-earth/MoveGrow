// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
//
// When a video was filmed. Normally the date comes from the video itself (or the moment it was
// recorded in the app). Parents can also set it themselves: a calendar day, the baby's age in
// days, or — when they only roughly remember — "about 6 weeks old" or "sometime in March 2026".
// Age-based dates follow the birthday if it is corrected later. `Memory.date` always holds the
// resolved date, so sorting, ages, observations and the Growth trends use it unchanged.

import Foundation

/// Where an automatically chosen date came from.
enum DateOrigin: String, Codable, Hashable {
    /// Recorded in the app: the moment of recording.
    case recorded
    /// Read from the video's own metadata.
    case metadata
    /// The video carried no date; the import time stands in until the parent sets one.
    case unknown
}

/// A date the parent chose.
enum DateSetting: Codable, Hashable {
    /// A calendar day (kept at the time of day it was filmed when known, otherwise noon).
    case exact(date: Date)
    /// N days after birth (0 = the day of birth).
    case daysOld(days: Int)
    /// About N weeks old.
    case aboutWeeks(weeks: Int)
    /// About N months old.
    case aboutMonths(months: Int)
    /// Sometime in a month.
    case inMonth(year: Int, month: Int)

    var isExact: Bool { if case .exact = self { return true } else { return false } }

    var isApproximate: Bool {
        switch self {
        case .exact, .daysOld: return false
        case .aboutWeeks, .aboutMonths, .inMonth: return true
        }
    }

    /// Computed from the birthday (so it moves when the birthday is edited).
    var followsBirthday: Bool {
        switch self {
        case .daysOld, .aboutWeeks, .aboutMonths: return true
        case .exact, .inMonth: return false
        }
    }

    var precision: DatePrecision {
        switch self {
        case .exact, .daysOld: return .day
        case .aboutWeeks: return .week
        case .aboutMonths, .inMonth: return .month
        }
    }

    /// The date used for sorting, ages and trends; nil when it needs a birthday and there is none.
    /// An exact day is kept as chosen; the others never fall before the day of birth or after today.
    func resolved(birthday: Date?, now: Date = Date(), calendar cal: Calendar = .current) -> Date? {
        func noon(_ d: Date) -> Date { cal.date(bySettingHour: 12, minute: 0, second: 0, of: d) ?? d }
        let born = birthday.map { cal.startOfDay(for: $0) }
        var out: Date
        switch self {
        case .exact(let d):
            return d
        case .daysOld(let n):
            guard let born, let d = cal.date(byAdding: .day, value: max(0, n), to: born) else { return nil }
            out = noon(d)
        case .aboutWeeks(let w):
            guard let born, let d = cal.date(byAdding: .day, value: max(0, w) * 7, to: born) else { return nil }
            out = noon(d)
        case .aboutMonths(let m):
            guard let born, let d = cal.date(byAdding: .month, value: max(0, m), to: born) else { return nil }
            out = noon(d)
        case .inMonth(let y, let m):
            guard let first = cal.date(from: DateComponents(year: y, month: m, day: 1)),
                  let month = cal.dateInterval(of: .month, for: first) else { return nil }
            // The middle of the month, kept inside the part of it after birth and before today.
            var lo = month.start, hi = month.end.addingTimeInterval(-1)
            if let born, born > lo { lo = born }
            if now < hi { hi = now }
            let mid = noon(cal.date(byAdding: .day, value: 14, to: month.start) ?? month.start)
            out = lo <= hi ? min(max(mid, lo), hi) : lo
        }
        if let born, out < born { out = born }
        return min(out, now)
    }
}

/// How finely a date is known.
enum DatePrecision: Int, Comparable, Hashable {
    case moment, day, week, month
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

extension Memory {
    var datePrecision: DatePrecision { dateSetting?.precision ?? .moment }
    var dateIsApproximate: Bool { dateSetting?.isApproximate ?? false }
    /// The video had no date of its own and the parent hasn't set one yet.
    var needsDate: Bool { dateSetting == nil && dateOrigin == .unknown }
    /// The date found in the video (or at recording), when there was one to go back to.
    var filmedDate: Date? { dateOrigin == .unknown ? nil : (capturedDate ?? (dateSetting == nil ? date : nil)) }

    /// Main date line: "Mar 3, 2026 at 4:12 PM", "Mar 3, 2026", "Around Mar 2026", "March 2026".
    var dateText: String {
        if needsDate { return tr("Date unknown") }
        switch dateSetting {
        case nil: return L10n.date(date, .abbreviated, time: .shortened)
        case .exact?, .daysOld?: return L10n.date(date)
        case .aboutWeeks?, .aboutMonths?: return tr("Around %@", L10n.monthYear(date, wide: false))
        case .inMonth?: return L10n.monthYear(date)
        }
    }

    /// Age line: "1 mo · 14 days", "45 days old", "About 6 weeks old" (with corrected age for babies born early).
    func ageText(_ baby: Baby?, corrected: Bool = true) -> String? {
        guard let baby, !needsDate else { return nil }
        let base: String
        switch dateSetting {
        case nil, .exact?: return baby.age(on: date, corrected: corrected)
        case .daysOld(let n)?: base = n == 1 ? tr("1 day old") : tr("%lld days old", n)
        case .aboutWeeks(let w)?: base = VideoAge.aboutWeeks(w)
        case .aboutMonths(let m)?: base = VideoAge.aboutMonths(m)
        case .inMonth?: base = VideoAge.about(days: VideoAge.days(baby, date))
        }
        guard corrected, baby.usesCorrectedAge(on: date), let w = baby.correctedWeeks(on: date) else { return base }
        let weeks = Baby.weeksLabel(w)
        return tr("%1$@ · corrected %2$@", base, dateIsApproximate ? tr("~%@", weeks) : weeks)
    }

    /// Short age for thumbnails: "12 d", "6 wk", "3 mo" ("≈" when approximate); nil without a birthday or date.
    func shortAge(_ baby: Baby?) -> String? {
        guard let baby, !needsDate else { return nil }
        let d = VideoAge.days(baby, date)
        let text: String
        if case .daysOld(let n)? = dateSetting { text = tr("%lld d", n) }
        else if d < 14 { text = tr("%lld d", d) }
        else if d < 91 { text = tr("%lld wk", d / 7) }
        else { let m = Int(Double(d) / 30.44); text = m == 1 ? tr("1 mo") : tr("%lld mo", m) }
        return dateIsApproximate ? tr("~%@", text) : text
    }
}

enum VideoAge {
    /// Whole days from the day of birth to `date` (0 on the birthday).
    static func days(_ baby: Baby, _ date: Date, calendar cal: Calendar = .current) -> Int {
        max(0, cal.dateComponents([.day], from: cal.startOfDay(for: baby.birthday), to: cal.startOfDay(for: date)).day ?? 0)
    }
    static func aboutWeeks(_ n: Int) -> String { n == 1 ? tr("About 1 week old") : tr("About %lld weeks old", n) }
    static func aboutMonths(_ n: Int) -> String { n == 1 ? tr("About 1 month old") : tr("About %lld months old", n) }
    /// Weeks under three months, months after.
    static func about(days d: Int) -> String {
        d < 91 ? aboutWeeks(Int((Double(d) / 7).rounded())) : aboutMonths(Int((Double(d) / 30.44).rounded()))
    }
    /// Days old today (upper bound for the "days after birth" picker).
    static func daysOld(_ baby: Baby, now: Date = Date()) -> Int { days(baby, now) }
}

/// Capture dates found in video files.
enum CaptureDate {
    /// Rejects the placeholder dates some files carry (a zeroed movie header reads as 1904 or 1970,
    /// and a wrong camera clock can be in the future).
    static func plausible(_ d: Date?, now: Date = Date()) -> Date? {
        guard let d, d.timeIntervalSince1970 > 946_684_800, d <= now.addingTimeInterval(86_400) else { return nil }
        return d
    }

    /// Parses QuickTime's "2026-03-03T16:12:45+0800" (and ISO 8601 variants) when a metadata item
    /// has no date value of its own.
    static func parse(_ s: String) -> Date? {
        let text = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: text) { return d }
        for format in ["yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = format
            if let d = f.date(from: text) { return d }
        }
        return nil
    }
}
