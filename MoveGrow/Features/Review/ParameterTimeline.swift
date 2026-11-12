// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
//
// The parameter timeline: time on the x axis, one track per parameter, all sharing the same axis
// and the playback cursor —
//   Arms / Legs     distal speed (torso lengths per second), left solid, right dashed
//   Elbows / Knees  joint angle in degrees (180 = straight), left solid, right dashed
//   3D only (videos analysed with InstantHMR):
//   Hips            hip angle (shoulder–hip–knee, 180 = in line with the trunk)
//   Hands ↑ / Feet ↑ height in front of the torso plane (lifted towards the camera when on the back)
//   Hands ↔         distance between the wrists
//   Legs ⇄          up = the legs bend and stretch together, down = they alternate
//   Sync            up = the four limbs speed up and slow down together
//   Balance         (left − right) / (left + right) for arms (solid) and legs (dashed); up = left more
//   Head            head direction; up = turned to the baby's left, down = right
//   Motion          overall movement (mean of the four limb speeds)
//   Tracked         where the body was clearly tracked
//   Events          observations (bars) and milestones (diamonds)
// The tracks are one equatable Canvas, drawn only when the data changes; the cursor and its value
// dots are a separate Canvas that follows the playback clock. Chips choose which groups of tracks are
// shown (speed and angles by default). The panel ignores touches, so the page scrolls freely, except
// while "Hold to move" is held: then dragging on the panel (or along the button) moves the cursor.

import SwiftUI

/// Groups of tracks the parent can show or hide.
enum ParamGroup: String, CaseIterable, Identifiable {
    case speed, angles, lift, coordination, balance, motion
    var id: String { rawValue }

    var title: String {
        switch self {
        case .speed: return tr("Speed")
        case .angles: return tr("Angles")
        case .lift: return tr("Lift")
        case .coordination: return tr("Coordination")
        case .balance: return tr("Left and right")
        case .motion: return tr("Motion")
        }
    }

    var needs3D: Bool { self == .lift || self == .coordination }
    static let defaults: Set<ParamGroup> = [.speed, .angles]
    static let storageKey = "parameterGroups"

    static func decode(_ raw: String) -> Set<ParamGroup> {
        Set(raw.split(separator: ",").compactMap { ParamGroup(rawValue: String($0)) })
    }

    static func encode(_ set: Set<ParamGroup>) -> String {
        allCases.filter(set.contains).map(\.rawValue).joined(separator: ",")
    }
}

enum ParamRow: CaseIterable {
    case arms, legs, elbows, knees, hips, handLift, footLift, handGap, legPattern, sync, balance, head, motion, tracked, events

    /// Rows only a 3D (InstantHMR) digest has data for.
    var needs3D: Bool {
        switch self {
        case .hips, .handLift, .footLift, .handGap, .legPattern, .sync: return true
        default: return false
        }
    }

    /// The rows drawn for a digest (3D rows only when it has them).
    static func rows(for g: ReviewDigest?) -> [ParamRow] {
        allCases.filter { !$0.needs3D || g?.is3D == true }
    }

    /// The group a row belongs to; nil = always shown (tracked, events).
    var group: ParamGroup? {
        switch self {
        case .arms, .legs: return .speed
        case .elbows, .knees, .hips: return .angles
        case .handLift, .footLift: return .lift
        case .handGap, .legPattern, .sync: return .coordination
        case .balance, .head: return .balance
        case .motion: return .motion
        case .tracked, .events: return nil
        }
    }

    var title: String {
        switch self {
        case .arms: return tr("Arms")
        case .legs: return tr("Legs")
        case .elbows: return tr("Elbows")
        case .knees: return tr("Knees")
        case .hips: return tr("Hips")
        case .handLift: return tr("Hands ↑")
        case .footLift: return tr("Feet ↑")
        case .handGap: return tr("Hands ↔")
        case .legPattern: return tr("Legs ⇄")
        case .sync: return tr("Sync")
        case .balance: return tr("L · R")
        case .head: return tr("Head")
        case .motion: return tr("Motion")
        case .tracked: return tr("Tracked")
        case .events: return tr("Events")
        }
    }

    var height: CGFloat {
        switch self {
        case .arms, .legs: return 34
        case .elbows, .knees, .hips, .handLift, .footLift, .balance, .motion: return 28
        case .head, .handGap, .legPattern, .sync: return 22
        case .tracked: return 7
        case .events: return 16
        }
    }

    /// Value range drawn by the track (fixed per kind, so videos can be compared by eye).
    func range(_ g: ReviewDigest) -> (lo: Double, hi: Double) {
        switch self {
        case .arms, .legs, .motion: return (0, max(0.3, g.speedScale * 1.1))
        case .elbows, .knees, .hips: return (40, 180)
        case .handLift, .footLift: return (-0.3, 1.2)
        case .handGap: return (0, 2)
        case .balance, .head, .legPattern, .sync: return (-1, 1)
        case .tracked, .events: return (0, 1)
        }
    }
}

/// One line on a track (values already smoothed for display).
struct ParamSeries {
    var values: [Float]
    var color: Color
    var dashed: Bool

    subscript(i: Int) -> Float { i >= 0 && i < values.count ? values[i] : .nan }
}

/// Every track's lines, smoothed once (≈1 s) so curves read as movement, not frame jitter.
struct ParamData {
    let digest: ReviewDigest
    let rows: [ParamRow]
    let lines: [ParamRow: [ParamSeries]]

    init(_ g: ReviewDigest) {
        digest = g
        let visible = ParamRow.rows(for: g)
        rows = visible
        let k = max(1, Int((1.0 / g.bin).rounded()))
        var out: [ParamRow: [ParamSeries]] = [:]
        for row in visible {
            out[row] = ParamLayout.series(row, g).map { s in
                var smoothed = s
                // The balance and coordination series are already windowed; the rest get a ≈1 s centred mean.
                if row != .balance && row != .legPattern && row != .sync { smoothed.values = ParamLayout.smooth(s.values, k) }
                return smoothed
            }
        }
        lines = out
    }
}

enum ParamLayout {
    /// Room for the track names (Spanish ones are longer).
    static var labelWidth: CGFloat { L10n.language == .spanish ? 64 : 48 }
    static let gap: CGFloat = 5
    static let axisHeight: CGFloat = 16

    static func height(_ rows: [ParamRow]) -> CGFloat {
        rows.reduce(0) { $0 + $1.height } + gap * CGFloat(rows.count) + axisHeight
    }

    static func rows(width: CGFloat, _ rows: [ParamRow]) -> [(row: ParamRow, rect: CGRect)] {
        var y: CGFloat = 0
        return rows.map { row in
            defer { y += row.height + gap }
            return (row: row, rect: CGRect(x: labelWidth, y: y, width: max(1, width - labelWidth), height: row.height))
        }
    }

    static func x(_ t: Double, duration: Double, width: CGFloat) -> CGFloat {
        labelWidth + CGFloat(min(max(0, t / max(duration, 0.1)), 1)) * max(1, width - labelWidth)
    }

    static func y(_ v: Double, in rect: CGRect, range: (lo: Double, hi: Double)) -> CGFloat {
        let f = (min(max(v, range.lo), range.hi) - range.lo) / max(1e-9, range.hi - range.lo)
        return rect.maxY - CGFloat(f) * rect.height
    }

    static func smooth(_ x: [Float], _ k: Int) -> [Float] { SeriesMath.smooth(x, k) }

    /// Lines for each track (raw bins; see ParamData for the smoothed ones).
    static func series(_ row: ParamRow, _ g: ReviewDigest) -> [ParamSeries] {
        func s(_ key: String, _ color: Color, _ dashed: Bool) -> ParamSeries? {
            g.speed[key].map { ParamSeries(values: $0.values, color: color, dashed: dashed) }
        }
        func a(_ key: String, _ color: Color, _ dashed: Bool) -> ParamSeries? {
            g.angle[key].map { ParamSeries(values: $0.values, color: color, dashed: dashed) }
        }
        func h(_ key: String, _ color: Color, _ dashed: Bool) -> ParamSeries? {
            g.hip?[key].map { ParamSeries(values: $0.values, color: color, dashed: dashed) }
        }
        func l(_ limb: Limb, _ dashed: Bool) -> ParamSeries? {
            g.lift?[limb.rawValue].map { ParamSeries(values: $0.values, color: limb.color, dashed: dashed) }
        }
        func one(_ p: PackedSeries?, _ color: Color) -> [ParamSeries] {
            p.map { [ParamSeries(values: $0.values, color: color, dashed: false)] } ?? []
        }
        switch row {
        case .arms: return [s(Limb.leftArm.rawValue, Limb.leftArm.color, false), s(Limb.rightArm.rawValue, Limb.rightArm.color, true)].compactMap { $0 }
        case .legs: return [s(Limb.leftLeg.rawValue, Limb.leftLeg.color, false), s(Limb.rightLeg.rawValue, Limb.rightLeg.color, true)].compactMap { $0 }
        case .elbows: return [a("elbow_L", Limb.leftArm.color, false), a("elbow_R", Limb.rightArm.color, true)].compactMap { $0 }
        case .knees: return [a("knee_L", Limb.leftLeg.color, false), a("knee_R", Limb.rightLeg.color, true)].compactMap { $0 }
        case .hips: return [h("hip_L", Limb.leftLeg.color, false), h("hip_R", Limb.rightLeg.color, true)].compactMap { $0 }
        case .handLift: return [l(.leftArm, false), l(.rightArm, true)].compactMap { $0 }
        case .footLift: return [l(.leftLeg, false), l(.rightLeg, true)].compactMap { $0 }
        case .handGap: return one(g.handGap, Color.mgInk)
        case .legPattern: return one(g.legPhase, Color.mgInk)
        case .sync: return one(g.sync, Color.mgSage)
        case .balance: return [ParamSeries(values: g.armBalanceSeries.values, color: Color.mgInk, dashed: false),
                               ParamSeries(values: g.legBalanceSeries.values, color: Color.mgInk.opacity(0.6), dashed: true)]
        case .motion: return [ParamSeries(values: g.motion.values, color: Color.mgSage, dashed: false)]
        case .head, .tracked, .events: return []
        }
    }

    static func tickStep(_ duration: Double) -> Double { SeriesMath.tickStep(duration) }
}

/// The tracks, axis and labels (no playback state: drawn only when the data changes).
struct ParameterTracks: View, Equatable {
    let data: ParamData?
    let rows: [ParamRow]
    let events: [TimelineEvent]
    let duration: Double
    private var digest: ReviewDigest? { data?.digest }

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.duration == b.duration && a.events == b.events && a.data?.digest.count == b.data?.digest.count
            && a.rows == b.rows
            && a.data?.digest.bin == b.data?.digest.bin && a.data?.digest.speedScale == b.data?.digest.speedScale
            && a.data?.digest.analysisFPS == b.data?.digest.analysisFPS
    }

    var body: some View {
        Canvas { ctx, size in
            let lines = data?.lines ?? [:]
            let w = size.width
            let d = max(duration, 0.1)
            func x(_ t: Double) -> CGFloat { ParamLayout.x(t, duration: d, width: w) }
            let back = Color.primary.opacity(0.05)
            let rows = ParamLayout.rows(width: w, self.rows)

            // Vertical grid at the axis ticks.
            let step = ParamLayout.tickStep(d)
            var grid = Path()
            var tick = 0.0
            while tick <= d + 1e-6 {
                grid.move(to: CGPoint(x: x(tick), y: 0))
                grid.addLine(to: CGPoint(x: x(tick), y: size.height - ParamLayout.axisHeight))
                tick += step
            }

            for (row, rect) in rows {
                ctx.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(back))
                let label = ctx.resolve(Text(row.title).font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary))
                ctx.draw(label, at: CGPoint(x: ParamLayout.labelWidth - 6, y: rect.midY), anchor: .trailing)
                guard let g = digest else { continue }
                let range = row.range(g)
                switch row {
                case .balance, .head, .legPattern, .sync, .handLift, .footLift:
                    var zero = Path()
                    let y0 = ParamLayout.y(0, in: rect, range: range)
                    zero.move(to: CGPoint(x: rect.minX, y: y0)); zero.addLine(to: CGPoint(x: rect.maxX, y: y0))
                    ctx.stroke(zero, with: .color(Color.primary.opacity(0.2)), lineWidth: 0.75)
                default:
                    break
                }
                switch row {
                case .head:
                    // Bars from the centre line: up = left, down = right.
                    var left = Path(), right = Path()
                    let y0 = ParamLayout.y(0, in: rect, range: range)
                    for i in 0..<g.count {
                        let v = Double(g.headYaw[i])
                        guard v.isFinite, abs(v) > 0.05 else { continue }
                        let t = g.start + Double(i) * g.bin
                        let y1 = ParamLayout.y(v, in: rect, range: range)
                        let r = CGRect(x: x(t), y: min(y0, y1), width: max(1, x(t + g.bin) - x(t)), height: abs(y1 - y0))
                        if v > 0 { left.addRect(r) } else { right.addRect(r) }
                    }
                    ctx.fill(left, with: .color(Limb.leftArm.color.opacity(0.75)))
                    ctx.fill(right, with: .color(Limb.rightArm.color.opacity(0.75)))
                case .motion:
                    // Filled area (gaps stay empty).
                    let motion = lines[.motion]?.first
                    var area = Path()
                    var open = false
                    var lastX: CGFloat = 0
                    for i in 0..<g.count {
                        let v = Double(motion?[i] ?? .nan)
                        let px = x(g.time(ofBin: i))
                        if v.isFinite {
                            let py = ParamLayout.y(v, in: rect, range: range)
                            if !open { area.move(to: CGPoint(x: px, y: rect.maxY)); open = true }
                            area.addLine(to: CGPoint(x: px, y: py))
                            lastX = px
                        } else if open {
                            area.addLine(to: CGPoint(x: lastX, y: rect.maxY)); area.closeSubpath(); open = false
                        }
                    }
                    if open { area.addLine(to: CGPoint(x: lastX, y: rect.maxY)); area.closeSubpath() }
                    ctx.fill(area, with: .linearGradient(Gradient(colors: [Color.mgSage.opacity(0.25), Color.mgSage.opacity(0.7)]),
                                                         startPoint: CGPoint(x: 0, y: rect.maxY), endPoint: CGPoint(x: 0, y: rect.minY)))
                case .tracked:
                    var tracked = Path()
                    for i in 0..<g.count where g.coverage[i] >= 0.5 {
                        let t = g.start + Double(i) * g.bin
                        tracked.addRect(CGRect(x: x(t), y: rect.minY, width: max(1, x(t + g.bin) - x(t)), height: rect.height))
                    }
                    ctx.fill(tracked, with: .color(Color.mgSage.opacity(0.55)))
                case .events:
                    break
                default:
                    break
                }
                for line in lines[row] ?? [] where row != .motion {
                    var p = Path()
                    var drawing = false
                    for i in 0..<g.count {
                        let v = Double(line[i])
                        guard v.isFinite else { drawing = false; continue }
                        let pt = CGPoint(x: x(g.time(ofBin: i)), y: ParamLayout.y(v, in: rect, range: range))
                        if drawing { p.addLine(to: pt) } else { p.move(to: pt); drawing = true }
                    }
                    ctx.stroke(p, with: .color(line.color),
                               style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round, dash: line.dashed ? [4, 3] : []))
                }
            }

            // Events track.
            if let rect = rows.first(where: { $0.row == .events })?.rect {
                for e in events {
                    let x0 = x(e.t0), x1 = max(x0 + 3, x(e.t1))
                    if e.tint == .milestone {
                        let cx = (x0 + x1) / 2, cy = rect.midY, r: CGFloat = 5
                        var p = Path()
                        p.move(to: CGPoint(x: cx, y: cy - r)); p.addLine(to: CGPoint(x: cx + r, y: cy))
                        p.addLine(to: CGPoint(x: cx, y: cy + r)); p.addLine(to: CGPoint(x: cx - r, y: cy)); p.closeSubpath()
                        ctx.fill(p, with: .color(e.color))
                    } else {
                        ctx.fill(Path(roundedRect: CGRect(x: x0, y: rect.minY + 3, width: x1 - x0, height: rect.height - 6), cornerRadius: 3),
                                 with: .color(e.color))
                    }
                }
            }

            ctx.stroke(grid, with: .color(Color.primary.opacity(0.07)), lineWidth: 0.5)

            // Time axis.
            let axisY = size.height - ParamLayout.axisHeight / 2
            tick = 0
            while tick <= d + 1e-6 {
                let label = ctx.resolve(Text(clock(tick)).font(.system(size: 9, weight: .medium).monospacedDigit()).foregroundColor(.secondary))
                let anchor: UnitPoint = tick == 0 ? .leading : (tick + step > d + 1e-6 ? .trailing : .center)
                ctx.draw(label, at: CGPoint(x: x(tick), y: axisY), anchor: anchor)
                tick += step
            }
        }
        .frame(height: ParamLayout.height(rows))
    }
}

/// Cursor line across all tracks, with a dot on every line at the current time.
private struct ParameterCursor: View {
    @ObservedObject var ticker: PlayerClock
    let data: ParamData?
    let rows: [ParamRow]
    let duration: Double

    var body: some View {
        let t = ticker.time
        Canvas { ctx, size in
            let cx = ParamLayout.x(t, duration: duration, width: size.width)
            var line = Path()
            line.move(to: CGPoint(x: cx, y: 0))
            line.addLine(to: CGPoint(x: cx, y: size.height - ParamLayout.axisHeight))
            ctx.stroke(line, with: .color(Color.mgInk.opacity(0.85)), lineWidth: 1.5)
            guard let data, let i = data.digest.bin(at: t) else { return }
            for (row, rect) in ParamLayout.rows(width: size.width, rows) {
                let range = row.range(data.digest)
                for s in data.lines[row] ?? [] {
                    let v = Double(s[i])
                    guard v.isFinite else { continue }
                    let y = ParamLayout.y(v, in: rect, range: range)
                    let dot = CGRect(x: cx - 3.5, y: y - 3.5, width: 7, height: 7)
                    ctx.fill(Path(ellipseIn: dot), with: .color(.white))
                    ctx.stroke(Path(ellipseIn: dot), with: .color(s.color), lineWidth: 2)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// The parameter timeline with its cursor, group chips and the "Hold to move" control.
struct ParameterTimeline: View {
    let player: ReviewPlayerModel
    let events: [TimelineEvent]
    private let data: ParamData?
    @AppStorage(ParamGroup.storageKey) private var groupsRaw = ParamGroup.encode(ParamGroup.defaults)
    @State private var holding = false
    /// Where the cursor was when the hold began, and whether the panel itself was dragged since.
    @State private var holdStart = 0.0
    @State private var panelUsed = false
    @State private var trackWidth: CGFloat = 300

    init(player: ReviewPlayerModel, digest: ReviewDigest?, events: [TimelineEvent]) {
        self.player = player
        self.events = events
        data = digest.map(ParamData.init)
    }

    private var is3D: Bool { data?.digest.is3D == true }
    private var groups: [ParamGroup] { ParamGroup.allCases.filter { !$0.needs3D || is3D } }
    private var selected: Set<ParamGroup> {
        let s = ParamGroup.decode(groupsRaw)
        return s.isEmpty ? ParamGroup.defaults : s
    }
    private var rows: [ParamRow] {
        (data?.rows ?? ParamRow.rows(for: nil)).filter { row in row.group.map(selected.contains) ?? true }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                legend
                Spacer(minLength: 4)
                holdButton
            }
            chips
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .topLeading) {
                    ParameterTracks(data: data, rows: rows, events: events, duration: player.duration).equatable()
                    ParameterCursor(ticker: player.clock, data: data, rows: rows, duration: player.duration)
                }
                .contentShape(Rectangle())
                .scrubbing(width: max(1, w - ParamLayout.labelWidth), offset: ParamLayout.labelWidth) { fraction, final in
                    guard holding else { return }
                    panelUsed = true
                    if !final { player.pause() }
                    player.seek(fraction * player.duration, precise: final)
                }
                // Not touchable unless "Hold to move" is held: touches go to the page (scrolling).
                .allowsHitTesting(holding)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.mgSage.opacity(holding ? 0.6 : 0), lineWidth: 1.5))
                .onAppear { trackWidth = max(1, w - ParamLayout.labelWidth) }
                .onChange(of: w) { _, nw in trackWidth = max(1, nw - ParamLayout.labelWidth) }
            }
            .frame(height: ParamLayout.height(rows))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tr("Movement parameters over time"))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: player.seek(player.time + 5)
                case .decrement: player.seek(player.time - 5)
                @unknown default: break
                }
            }
        }
    }

    /// Press and hold: the panel follows the finger; sliding along the button moves the cursor too.
    private var holdButton: some View {
        Text(holding ? tr("Moving") : tr("Hold to move"))
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .foregroundStyle(holding ? Color.white : Color.mgSage)
            .background(holding ? Color.mgSage : Color.mgSageSoft, in: Capsule())
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if !holding {
                            holding = true
                            panelUsed = false
                            holdStart = player.time
                            player.pause()
                        }
                        // Sliding along the button: the same scale as dragging the cursor on the panel.
                        if !panelUsed, abs(v.translation.width) > 8 {
                            let t = holdStart + Double(v.translation.width / trackWidth) * player.duration
                            player.seek(min(max(0, t), player.duration), precise: false)
                        }
                    }
                    .onEnded { v in
                        if !panelUsed, abs(v.translation.width) > 8 {
                            let t = holdStart + Double(v.translation.width / trackWidth) * player.duration
                            player.seek(min(max(0, t), player.duration), precise: true)
                        }
                        holding = false
                    }
            )
            .sensoryFeedback(.impact(weight: .light), trigger: holding)
            .accessibilityLabel(tr("Hold to move"))
            .accessibilityHint(tr("While you hold this, drag on the panel to move through the video."))
    }

    /// Which groups of tracks are shown.
    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(groups) { g in
                    let on = selected.contains(g)
                    Button {
                        var s = selected
                        if on { s.remove(g) } else { s.insert(g) }
                        if !s.isEmpty { groupsRaw = ParamGroup.encode(s) }
                    } label: {
                        Text(g.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .frame(minHeight: 28)
                            .foregroundStyle(on ? Color.white : Color.primary)
                            .background(on ? Color.mgSage : Color.primary.opacity(0.07), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
    }

    /// Solid = left, dashed = right.
    private var legend: some View {
        HStack(spacing: 14) {
            Spacer().frame(width: ParamLayout.labelWidth - 14)
            legendItem(tr("Left"), dashed: false)
            legendItem(tr("Right"), dashed: true)
            Spacer()
        }
        .accessibilityHidden(true)
    }

    private func legendItem(_ side: String, dashed: Bool) -> some View {
        HStack(spacing: 5) {
            Canvas { ctx, size in
                var p = Path()
                p.move(to: CGPoint(x: 0, y: size.height / 2)); p.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                ctx.stroke(p, with: .color(Color.secondary), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: dashed ? [4, 3] : []))
            }
            .frame(width: 22, height: 8)
            Text(side).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
        }
    }
}
