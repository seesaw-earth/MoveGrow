// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
//
// "When was this filmed?" — a calendar day, the baby's age in days, or roughly (about N weeks or
// months old, or sometime in a month). The card on top shows the result exactly as the album
// will; the date found in the video is always one tap away.

import SwiftUI

struct VideoDateSheet: View {
    @EnvironmentObject private var store: LocalStore
    @Environment(\.dismiss) private var dismiss

    enum Mode: Hashable { case day, age, rough }
    enum Rough: Hashable { case weeks, months, month }

    let memory: Memory
    private let baby: Baby?

    @State private var mode: Mode
    @State private var day: Date
    @State private var days: Int
    @State private var rough: Rough
    @State private var weeks: Int
    @State private var months: Int
    @State private var year: Int
    @State private var month: Int

    init(memory: Memory, baby: Baby?) {
        self.memory = memory
        self.baby = baby
        let cal = Calendar.current
        let ageDays = baby.map { VideoAge.days($0, memory.date) } ?? 0
        var mode = Mode.day, rough = Rough.weeks
        var days = ageDays, weeks = Int((Double(ageDays) / 7).rounded()), months = Int((Double(ageDays) / 30.44).rounded())
        var year = cal.component(.year, from: memory.date), month = cal.component(.month, from: memory.date)
        switch memory.dateSetting {
        case nil, .exact?: break
        case .daysOld(let n)?: mode = .age; days = n
        case .aboutWeeks(let w)?: mode = .rough; rough = .weeks; weeks = w
        case .aboutMonths(let m)?: mode = .rough; rough = .months; months = m
        case .inMonth(let y, let m)?: mode = .rough; rough = .month; year = y; month = m
        }
        // Start inside the pickers' ranges (a 4-day-old rounds to "1 week", but the wheel ends at 0).
        let maxDays = baby.map { VideoAge.daysOld($0) } ?? 0
        weeks = min(weeks, maxDays / 7)
        months = min(months, Int(Double(maxDays) / 30.44))
        days = min(days, maxDays)
        _mode = State(initialValue: baby == nil && mode != .day ? .day : mode)
        _day = State(initialValue: memory.date)
        _days = State(initialValue: days)
        _rough = State(initialValue: rough)
        _weeks = State(initialValue: weeks)
        _months = State(initialValue: months)
        _year = State(initialValue: year)
        _month = State(initialValue: month)
    }

    // MARK: limits

    private var now: Date { Date() }
    private var maxDays: Int { baby.map { VideoAge.daysOld($0) } ?? 0 }
    private var dayRange: ClosedRange<Date> {
        let lo = baby.map { Calendar.current.startOfDay(for: $0.birthday) } ?? .distantPast
        return min(lo, now)...now
    }
    private var years: [Int] {
        let cal = Calendar.current
        let first = cal.component(.year, from: baby?.birthday ?? memory.date)
        return Array(min(first, year)...max(cal.component(.year, from: now), year))
    }

    // MARK: result

    /// What Save stores (nil only when an age is needed and there is no birthday).
    private var setting: DateSetting? {
        switch mode {
        case .day: return .exact(date: Self.keepingTime(of: memory.filmedDate, on: day))
        case .age: return baby == nil ? nil : .daysOld(days: days)
        case .rough:
            switch rough {
            case .weeks: return baby == nil ? nil : .aboutWeeks(weeks: weeks)
            case .months: return baby == nil ? nil : .aboutMonths(months: months)
            case .month: return .inMonth(year: year, month: month)
            }
        }
    }

    private var preview: Memory? {
        guard let s = setting, let d = s.resolved(birthday: baby?.birthday) else { return nil }
        var m = memory
        m.dateSetting = s
        m.date = d
        return m
    }

    /// Picking the day the video already says changes nothing (and keeps its time of day).
    private var unchanged: Bool {
        mode == .day && memory.dateSetting == nil && !memory.needsDate && Calendar.current.isDate(day, inSameDayAs: memory.date)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section { resultCard }
                Section {
                    Picker(tr("Set by"), selection: $mode.animation(.snappy)) {
                        Text(tr("Date")).tag(Mode.day)
                        Text(tr("Age")).tag(Mode.age)
                        Text(tr("Roughly")).tag(Mode.rough)
                    }
                    .pickerStyle(.segmented)
                    .listRowSeparator(.hidden)
                    switch mode {
                    case .day: dayPane
                    case .age: agePane
                    case .rough: roughPane
                    }
                } footer: {
                    footer
                }
                if let filmed = memory.filmedDate, memory.dateSetting != nil {
                    Section {
                        Button {
                            save(nil)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tr("Use the date from the video"))
                                Text(L10n.date(filmed, .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle(tr("When was this filmed?"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(tr("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("Save")) { unchanged ? dismiss() : save(setting) }
                        .disabled(setting == nil)
                }
            }
            .sensoryFeedback(.selection, trigger: mode)
        }
    }

    private var resultCard: some View {
        let m = preview ?? memory
        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(m.dateText).font(.headline).foregroundStyle(Color.mgInk)
                    .contentTransition(.numericText())
                if let age = m.ageText(baby) {
                    Text(age).font(.subheadline).foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }
            Spacer(minLength: 0)
        }
        .animation(.snappy, value: m.date)
        .accessibilityElement(children: .combine)
    }

    // MARK: panes

    private var dayPane: some View {
        DatePicker(tr("Day"), selection: $day, in: dayRange, displayedComponents: .date)
            .datePickerStyle(.graphical)
            .tint(Color.mgSage)
    }

    @ViewBuilder private var agePane: some View {
        if baby == nil {
            needsBirthday
        } else {
            HStack(spacing: 0) {
                Picker(tr("Days old"), selection: $days) {
                    ForEach(0...max(0, maxDays), id: \.self) { Text(verbatim: "\($0)").tag($0) }
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: 140)
                Text(days == 1 ? tr("day old") : tr("days old")).font(.title3).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .frame(height: 150)
        }
    }

    @ViewBuilder private var roughPane: some View {
        Picker(tr("Roughly"), selection: $rough.animation(.snappy)) {
            Text(tr("Weeks old")).tag(Rough.weeks)
            Text(tr("Months old")).tag(Rough.months)
            Text(tr("Month & year")).tag(Rough.month)
        }
        .pickerStyle(.segmented)
        .listRowSeparator(.hidden)
        switch rough {
        case .weeks, .months:
            if baby == nil {
                needsBirthday
            } else {
                let isWeeks = rough == .weeks
                HStack(spacing: 0) {
                    Picker(isWeeks ? tr("Weeks") : tr("Months"), selection: isWeeks ? $weeks : $months) {
                        ForEach(0...max(0, isWeeks ? maxDays / 7 : Int(Double(maxDays) / 30.44)), id: \.self) { Text(verbatim: "\($0)").tag($0) }
                    }
                    .pickerStyle(.wheel)
                    .frame(maxWidth: 110)
                    Text(isWeeks ? (weeks == 1 ? tr("week old") : tr("weeks old")) : (months == 1 ? tr("month old") : tr("months old")))
                        .font(.title3).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .frame(height: 150)
            }
        case .month:
            HStack(spacing: 0) {
                Picker(tr("Month"), selection: $month) {
                    ForEach(1...12, id: \.self) { Text(L10n.monthNames[$0 - 1]).tag($0) }
                }
                .pickerStyle(.wheel)
                Picker(tr("Year"), selection: $year) {
                    ForEach(years, id: \.self) { Text(String($0)).tag($0) }
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: 110)
            }
            .frame(height: 150)
        }
    }

    private var needsBirthday: some View {
        Text(tr("Add the birthday in Profile to date by age"))
            .font(.subheadline).foregroundStyle(.secondary)
    }

    @ViewBuilder private var footer: some View {
        switch mode {
        case .day: EmptyView()
        case .age: Text(tr("Counted from the birthday, and updated if you change it."))
        case .rough: Text(tr("Rough dates are marked “about” and drawn as open circles in Growth."))
        }
    }

    // MARK: saving

    private func save(_ s: DateSetting?) {
        do {
            try store.setDate(s, for: memory.id)
            dismiss()
        } catch {
            store.error = error.localizedDescription
        }
    }

    /// The chosen day at the time of day the video was filmed (noon when unknown).
    static func keepingTime(of filmed: Date?, on day: Date) -> Date {
        let cal = Calendar.current
        let t = filmed.map { cal.dateComponents([.hour, .minute, .second], from: $0) } ?? DateComponents(hour: 12, minute: 0, second: 0)
        return cal.date(bySettingHour: t.hour ?? 12, minute: t.minute ?? 0, second: t.second ?? 0, of: day) ?? day
    }
}
