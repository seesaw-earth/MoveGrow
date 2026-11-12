// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
//
// Growth tab: kinematic parameters across videos and days. One point per video (or the mean of
// each day), by date or by the baby's (corrected) age, for activity, speed, left–right balance,
// joint range, head direction and overall movement, and — for videos analysed in 3D (InstantHMR) —
// lift of hands and feet, hip range and coordination. Tap or drag on the chart to pick a point;
// underneath, how each line changed from the first to the last point. The data and the chart are
// shared with the PNG export (GrowthExport.swift).

import SwiftUI
import Charts

enum TrendMetric: String, CaseIterable, Identifiable {
    case activity, speed, balance, range, head, motion, lift, hips, coordination
    var id: String { rawValue }

    var title: String {
        switch self {
        case .activity: return tr("Activity")
        case .speed: return tr("Speed")
        case .balance: return tr("Left and right")
        case .range: return tr("Joint range")
        case .head: return tr("Head turning")
        case .motion: return tr("Overall movement")
        case .lift: return tr("Lift")
        case .hips: return tr("Hip range")
        case .coordination: return tr("Coordination")
        }
    }

    /// What the numbers mean, in words.
    var subtitle: String {
        switch self {
        case .activity: return tr("Share of the time each limb was moving")
        case .speed: return tr("Typical hand and foot speed, in torso lengths per second")
        case .balance: return tr("Above 0: the left side moved more. The band around 0 is balanced.")
        case .range: return tr("Elbow and knee range, in degrees")
        case .head: return tr("Share of the time the head was turned to each side")
        case .motion: return tr("Typical amount of movement, in torso lengths per second")
        case .lift: return tr("How far hands and feet rise in front of the body (90th percentile), in torso lengths. 3D videos only.")
        case .hips: return tr("Hip angle range (shoulder–hip–knee), in degrees. 3D videos only.")
        case .coordination: return tr("Legs: above 0 they bend and stretch together, below 0 they alternate. Sync: how much the four limbs speed up and slow down together. 3D videos only.")
        }
    }

    var isPercent: Bool { self == .activity || self == .head }

    /// A value as shown on the axis and beside the lines ("42%", "0.35", "+0.20", "85°").
    func format(_ v: Double, signed: Bool = false) -> String {
        switch self {
        case .activity, .head: return L10n.percent(v / 100)
        case .range, .hips: return "\(Int(v.rounded()))°"
        case .speed, .motion, .balance, .lift, .coordination:
            let text = L10n.number(abs(v))
            if signed || self == .balance || self == .coordination { return v > 0.005 ? "+" + text : (v < -0.005 ? "−" + text : L10n.number(0)) }
            return text
        }
    }

    /// A change from the first to the last point ("+12 points" for percentages).
    func formatChange(_ d: Double) -> String {
        switch self {
        case .activity, .head:
            let n = Int(d.rounded())
            return n == 0 ? tr("no change") : tr("%@ pts", (n > 0 ? "+" : "−") + "\(abs(n))")
        case .range, .hips:
            let n = Int(d.rounded())
            return n == 0 ? tr("no change") : (n > 0 ? "+" : "−") + "\(abs(n))°"
        default:
            return abs(d) < 0.005 ? tr("no change") : format(d, signed: true)
        }
    }

    struct Line {
        var key: String
        var title: String
        var color: Color
        var dashed: Bool
        var value: (SessionKinematics) -> Double?
    }

    var lines: [Line] {
        func limbs(_ f: @escaping (SessionKinematics, Limb) -> Double?) -> [Line] {
            Limb.allCases.map { limb in
                Line(key: limb.rawValue, title: limb.short, color: limb.color, dashed: !limb.isLeft, value: { f($0, limb) })
            }
        }
        switch self {
        case .activity:
            return limbs { k, l in k.activeFraction[l.rawValue].map { $0 * 100 } }
        case .speed:
            return limbs { k, l in k.medianSpeed[l.rawValue] }
        case .range:
            let keys: [Limb: (String, String)] = [.leftArm: ("elbow_L", tr("L elbow")), .rightArm: ("elbow_R", tr("R elbow")),
                                                  .leftLeg: ("knee_L", tr("L knee")), .rightLeg: ("knee_R", tr("R knee"))]
            return Limb.allCases.map { limb in
                let (key, title) = keys[limb]!
                return Line(key: key, title: title, color: limb.color, dashed: !limb.isLeft,
                            value: { k in k.angleRange[key].flatMap { $0.count == 2 ? $0[1] - $0[0] : nil } })
            }
        case .balance:
            return [Line(key: "arms", title: tr("Arms"), color: Color.mgInk, dashed: false, value: { $0.armBalance }),
                    Line(key: "legs", title: tr("Legs"), color: Color.mgInk.opacity(0.6), dashed: true, value: { $0.legBalance })]
        case .head:
            return [Line(key: "left", title: tr("To the left"), color: Limb.leftArm.color, dashed: false,
                         value: { $0.headTurn.count == 3 ? $0.headTurn[0] * 100 : nil }),
                    Line(key: "right", title: tr("To the right"), color: Limb.rightArm.color, dashed: true,
                         value: { $0.headTurn.count == 3 ? $0.headTurn[2] * 100 : nil })]
        case .motion:
            return [Line(key: "motion", title: tr("Overall"), color: Color.mgSage, dashed: false, value: { $0.motionMedian })]
        case .lift:
            return limbs { k, l in k.liftP90?[l.rawValue] }
        case .hips:
            return [(Limb.leftLeg, "hip_L", tr("L hip")), (Limb.rightLeg, "hip_R", tr("R hip"))].map { limb, key, title in
                Line(key: key, title: title, color: limb.color, dashed: !limb.isLeft,
                     value: { k in k.hipRange?[key].flatMap { $0.count == 2 ? $0[1] - $0[0] : nil } })
            }
        case .coordination:
            return [Line(key: "legs", title: tr("Legs together"), color: Color.mgInk, dashed: false, value: { $0.legPhase }),
                    Line(key: "sync", title: tr("Sync"), color: Color.mgSage, dashed: true, value: { $0.sync })]
        }
    }
}

/// The points behind the trend charts: one per analysed video, or the mean of each day.
struct TrendData {
    struct Entry: Identifiable {
        var id: String
        var x: Double
        var date: Date
        var memoryIDs: [UUID]
        var kinematics: [SessionKinematics]
        /// Dated roughly by the parent ("about 6 weeks old"): drawn as an open circle.
        var approximate = false
    }

    struct Point: Identifiable {
        var id: String
        var entry: String
        var line: String
        var x: Double
        var y: Double
        var color: Color
        var dashed: Bool
        var approximate: Bool
    }

    static let secondsPerDay = 86_400.0

    let entries: [Entry]
    let byAge: Bool
    let byDay: Bool

    /// `since` keeps only videos filmed from that date on.
    init(memories: [Memory], baby: Baby?, byDay: Bool, byAge: Bool, since: Date? = nil) {
        self.byDay = byDay
        self.byAge = byAge && baby != nil
        let analysed = memories.filter { m in m.kinematics != nil && !m.needsDate && (since.map { m.date >= $0 } ?? true) }
            .sorted { $0.date < $1.date }
        let useAge = self.byAge
        func x(_ date: Date) -> Double {
            if useAge, let baby { return baby.analysisWeeks(on: date) }
            return date.timeIntervalSinceReferenceDate / Self.secondsPerDay
        }
        if byDay {
            let days = Dictionary(grouping: analysed) { Calendar.current.startOfDay(for: $0.date) }
            entries = days.keys.sorted().map { day in
                let ms = days[day] ?? []
                return Entry(id: "d\(day.timeIntervalSinceReferenceDate)", x: x(day.addingTimeInterval(12 * 3600)), date: day,
                             memoryIDs: ms.map(\.id), kinematics: ms.compactMap(\.kinematics),
                             approximate: ms.allSatisfy(\.dateIsApproximate))
            }
        } else {
            entries = analysed.map { m in
                Entry(id: m.id.uuidString, x: x(m.date), date: m.date, memoryIDs: [m.id], kinematics: [m.kinematics!],
                      approximate: m.dateIsApproximate)
            }
        }
    }

    var hasApproximate: Bool { entries.contains(where: \.approximate) }

    func value(_ line: TrendMetric.Line, _ e: Entry) -> Double? {
        let v = e.kinematics.compactMap(line.value).filter { $0.isFinite }
        return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
    }

    func points(_ metric: TrendMetric) -> [Point] {
        var out: [Point] = []
        for line in metric.lines {
            for e in entries {
                guard let v = value(line, e) else { continue }
                out.append(Point(id: "\(line.key)|\(e.id)", entry: e.id, line: line.key, x: e.x, y: v, color: line.color,
                                 dashed: line.dashed, approximate: e.approximate))
            }
        }
        return out
    }

    /// First → last change of each line.
    func changes(_ metric: TrendMetric) -> [(TrendMetric.Line, Double)] {
        guard let first = entries.first, let last = entries.last, entries.count > 1 else { return [] }
        return metric.lines.compactMap { line in
            guard let a = value(line, first), let b = value(line, last) else { return nil }
            return (line, b - a)
        }
    }

    var xDomain: ClosedRange<Double> {
        let xs = entries.map(\.x)
        let lo = xs.min() ?? 0, hi = xs.max() ?? 1
        let pad = max(0.5, (hi - lo) * 0.04)
        return (lo - pad)...(hi + pad)
    }

    func yDomain(_ metric: TrendMetric, _ pts: [Point]) -> ClosedRange<Double> {
        switch metric {
        case .activity, .head: return 0...100
        case .balance, .coordination: return -1...1
        default:
            let top = pts.map(\.y).max() ?? 1
            return 0...max(top * 1.15, (metric == .range || metric == .hips) ? 30 : 0.1)
        }
    }

    func axisLabel(_ x: Double) -> String {
        if byAge { return Baby.weeksLabel(x) }
        return L10n.monthDay(Date(timeIntervalSinceReferenceDate: x * Self.secondsPerDay))
    }

    /// "Mar 3 – Jun 1, 2026" for the dates covered.
    var periodText: String? {
        guard let a = entries.first?.date, let b = entries.last?.date else { return nil }
        let first = L10n.date(a), last = L10n.date(b)
        return first == last ? first : tr("%1$@ – %2$@", first, last)
    }
}

/// One trend chart. Interactive when given a selection binding.
struct TrendChart: View {
    let metric: TrendMetric
    let data: TrendData
    var selectedX: Binding<Double?>? = nil
    var pickedEntry: String? = nil
    var height: CGFloat = 200

    var body: some View {
        let pts = data.points(metric)
        let domain = data.xDomain
        let picked = pickedEntry.flatMap { id in data.entries.first { $0.id == id } }
        Chart {
            if metric == .balance {
                RectangleMark(xStart: .value("From", domain.lowerBound), xEnd: .value("To", domain.upperBound),
                              yStart: .value("Low", -0.2), yEnd: .value("High", 0.2))
                    .foregroundStyle(Color.mgSage.opacity(0.10))
                RuleMark(y: .value("Balanced", 0.0)).foregroundStyle(Color.secondary.opacity(0.5))
            }
            ForEach(pts) { p in
                LineMark(x: .value("When", p.x), y: .value("Value", p.y), series: .value("Line", p.line))
                    .foregroundStyle(p.color)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: p.dashed ? [5, 3] : []))
                    .interpolationMethod(.monotone)
                PointMark(x: .value("When", p.x), y: .value("Value", p.y))
                    .symbol {
                        let d: CGFloat = picked?.id == p.entry ? 11 : 7
                        if p.approximate {
                            Circle().strokeBorder(p.color, lineWidth: 1.8).background(Circle().fill(Color.mgPaper)).frame(width: d, height: d)
                        } else {
                            Circle().fill(p.color).frame(width: d, height: d)
                        }
                    }
            }
            if let picked {
                RuleMark(x: .value("Selected", picked.x))
                    .foregroundStyle(Color.mgInk.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: data.yDomain(metric, pts))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let x = value.as(Double.self) { Text(data.axisLabel(x)) }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let y = value.as(Double.self) { Text(metric.format(y)) }
                }
            }
        }
        .chartXSelection(value: selectedX ?? .constant(nil))
        .frame(height: height)
        .accessibilityLabel(metric.title)
    }
}

/// Line samples (solid = left, dashed = right) and, when needed, the open circle for rough dates.
struct TrendLegend: View {
    let metric: TrendMetric
    var approximate = false

    var body: some View {
        // Wraps onto a second row when the names are long (Spanish).
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10, alignment: .leading)], alignment: .leading, spacing: 4) {
            ForEach(metric.lines, id: \.key) { line in
                HStack(spacing: 4) {
                    Canvas { ctx, size in
                        var p = Path()
                        p.move(to: CGPoint(x: 0, y: size.height / 2)); p.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                        ctx.stroke(p, with: .color(line.color), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: line.dashed ? [4, 3] : []))
                    }
                    .frame(width: 18, height: 8)
                    Text(line.title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if approximate {
                HStack(spacing: 4) {
                    Circle().strokeBorder(Color.secondary, lineWidth: 1.5).frame(width: 7, height: 7)
                    Text(tr("Rough date")).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Small coloured chips: a line's name and a value.
struct TrendChips: View {
    struct Chip: Identifiable {
        var id: String
        var title: String
        var color: Color
        var text: String
    }
    let chips: [Chip]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(chips) { chip in
                HStack(spacing: 5) {
                    Circle().fill(chip.color).frame(width: 8, height: 8)
                    Text(chip.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    Text(chip.text).font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(Color.mgInk).lineLimit(1)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color.primary.opacity(0.05), in: Capsule())
            }
        }
    }
}

struct KinematicTrendsSection: View {
    @EnvironmentObject private var store: LocalStore
    @Binding var metric: TrendMetric
    @Binding var byDay: Bool
    @Binding var byAge: Bool
    @State private var selectedX: Double?

    var body: some View {
        let data = TrendData(memories: store.album.memories, baby: store.album.baby, byDay: byDay, byAge: byAge)
        let entries = data.entries
        ReviewCard(title: tr("Movement over time"), trailing: entries.isEmpty ? nil : (entries.count == 1 ? tr("1 point") : tr("%lld points", entries.count))) {
            metricPicker
            Text(metric.subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if entries.count < 2 {
                Text(entries.isEmpty ? tr("No analysed videos yet") : tr("One more video to see a trend"))
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                let picked = nearest(entries)
                TrendChart(metric: metric, data: data, selectedX: $selectedX, pickedEntry: picked?.id)
                    .animation(.easeInOut(duration: 0.25), value: metric)
                TrendLegend(metric: metric, approximate: data.hasApproximate)
                selectionOrChange(data, picked)
            }
            HStack {
                Picker(tr("Points"), selection: $byDay) {
                    Text(tr("Each video")).tag(false)
                    Text(tr("Each day")).tag(true)
                }
                .pickerStyle(.segmented)
                if store.album.baby != nil {
                    Picker(tr("Axis"), selection: $byAge) {
                        Text(tr("Date")).tag(false)
                        Text(tr("Age")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 150)
                }
            }
        }
        .onChange(of: metric) { _, _ in selectedX = nil }
        .onChange(of: byDay) { _, _ in selectedX = nil }
        .onChange(of: byAge) { _, _ in selectedX = nil }
        .onAppear { store.backfillKinematics() }
    }

    private var metricPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(TrendMetric.allCases) { m in
                    Button { metric = m } label: {
                        Text(m.title)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .frame(minHeight: 30)
                            .foregroundStyle(metric == m ? Color.white : Color.mgInk)
                            .background(metric == m ? Color.mgSage : Color.primary.opacity(0.07), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(metric == m ? .isSelected : [])
                }
            }
        }
        .sensoryFeedback(.selection, trigger: metric)
    }

    private func nearest(_ entries: [TrendData.Entry]) -> TrendData.Entry? {
        guard let selectedX else { return nil }
        return entries.min { abs($0.x - selectedX) < abs($1.x - selectedX) }
    }

    /// The picked point's values (and a link to its video), or how each line changed overall.
    @ViewBuilder private func selectionOrChange(_ data: TrendData, _ picked: TrendData.Entry?) -> some View {
        if let e = picked {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    let single: Memory? = byDay ? nil : e.memoryIDs.first.flatMap { store.memory($0) }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(single?.dateText ?? L10n.date(e.date))
                            .font(.caption.weight(.semibold)).foregroundStyle(Color.mgInk)
                        if let age = single?.ageText(store.album.baby) ?? store.album.baby?.age(on: e.date) {
                            Text(age).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if byDay, e.memoryIDs.count > 1 {
                        Text(tr("%lld videos", e.memoryIDs.count)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if e.memoryIDs.count == 1, let id = e.memoryIDs.first {
                        NavigationLink(tr("Open video")) { MemoryDetailView(memoryID: id) }
                            .font(.caption.weight(.semibold))
                    }
                }
                TrendChips(chips: metric.lines.compactMap { line in
                    guard let v = data.value(line, e) else { return nil }
                    return TrendChips.Chip(id: line.key, title: line.title, color: line.color, text: metric.format(v))
                })
            }
        } else {
            let changes = data.changes(metric)
            if !changes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("From the first to the last point")).font(.caption).foregroundStyle(.secondary)
                    TrendChips(chips: changes.map { line, d in
                        TrendChips.Chip(id: line.key, title: line.title, color: line.color, text: metric.formatChange(d))
                    })
                }
            }
        }
    }
}
