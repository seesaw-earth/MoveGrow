// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
//
// Pictures instead of paragraphs: a body map of how much each limb moved, left–right balance
// gauges, the movement curve, joint range bars and observation tiles (all curves over time are
// also in ParameterTimeline). Every number comes from the review digest (MotorDigest.swift), so
// it agrees with the rule engine. Longer explanations appear only on demand (observation details).

import SwiftUI
import Charts

// MARK: - Card shell

struct ReviewCard<Content: View>: View {
    let title: String
    var trailing: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.mgInk)
                Spacer()
                if let trailing {
                    Text(trailing).font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            content
        }
        .mgCard(padding: 14)
    }
}

/// Small progress ring, optionally with a short number in the middle.
struct StatRing: View {
    let value: Double
    var label: String? = nil
    var tint: Color = Color.mgSage
    var size: CGFloat = 38

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.18), lineWidth: 4)
            Circle().trim(from: 0, to: max(0.02, min(1, value)))
                .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.3), value: value)
            if let label {
                Text(label).font(.system(size: size * 0.28, weight: .semibold).monospacedDigit()).foregroundStyle(tint)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Body map

/// The baby figure on its back, seen from above (its left on the right of the picture); each limb glows
/// in its colour, stronger the more of the observed time it was moving, and arcs by the head show how
/// much of the time it was turned to each side.
struct BodyMapCard: View {
    let digest: ReviewDigest

    private func share(_ limb: Limb) -> Double? { digest.activeFraction[limb.rawValue] }

    var body: some View {
        ReviewCard(title: tr("Activity")) {
            HStack(alignment: .center, spacing: 16) {
                Canvas { ctx, size in draw(&ctx, size) }
                    .frame(width: 160, height: 196)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Limb.allCases) { limb in
                        let percent: String = share(limb).map { L10n.percent($0) } ?? "—"
                        let spoken: String = share(limb).map { tr("%@ of the time moving", L10n.percent($0)) } ?? tr("not seen")
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(limb.short)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(limb.color)
                                .frame(minWidth: 44, alignment: .leading)
                            Text(percent)
                                .font(.title3.weight(.semibold).monospacedDigit())
                                .foregroundStyle(Color.mgInk)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(limb.name + ": " + spoken)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        var share: [Limb: Double] = [:]
        for limb in Limb.allCases { share[limb] = self.share(limb) }
        BabyFigure.drawActivity(&ctx, size: size, share: share, headTurn: digest.headTurn)
    }
}

// MARK: - Balance

struct BalanceCard: View {
    let digest: ReviewDigest

    var body: some View {
        ReviewCard(title: tr("Left and right")) {
            VStack(spacing: 14) {
                gauge(value: digest.armBalance, label: tr("Arms"))
                gauge(value: digest.legBalance, label: tr("Legs"))
            }
        }
    }

    /// −1 … +1, where + means the left side moved more. Drawn with the baby's left on the right,
    /// as in the body map.
    private func gauge(value: Double?, label: String) -> some View {
        let v: Double? = value.map { max(-1, min(1, $0)) }
        let tint: Color = Self.tint(v)
        let shown: String = Self.shortValue(v)
        let spoken: String = Self.spokenValue(v)
        return HStack(spacing: 10) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(minWidth: 52, alignment: .leading)
            Text(tr("R")).font(.caption.weight(.bold)).foregroundStyle(Limb.rightArm.color)
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07)).frame(height: 10)
                    Capsule().fill(Color.mgSage.opacity(0.18)).frame(width: w * 0.2, height: 10).offset(x: w * 0.4)
                    Rectangle().fill(Color.primary.opacity(0.25)).frame(width: 1.5, height: 16).offset(x: w / 2 - 0.75)
                    if let v {
                        Circle().fill(tint).frame(width: 18, height: 18)
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                            .shadow(color: .black.opacity(0.15), radius: 1.5)
                            .offset(x: (0.5 + 0.5 * v) * w - 9)
                    }
                }
                .frame(height: 18)
                .frame(maxHeight: .infinity)
            }
            .frame(height: 22)
            Text(tr("L")).font(.caption.weight(.bold)).foregroundStyle(Limb.leftArm.color)
            Text(shown)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
                .frame(minWidth: 42, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(spoken)
    }

    private static func tint(_ v: Double?) -> Color {
        guard let v else { return Color.secondary }
        if abs(v) <= 0.2 { return Color.mgSage }
        return abs(v) <= 0.4 ? Color.mgGold : Color.orange
    }

    private static func shortValue(_ v: Double?) -> String {
        guard let v else { return "—" }
        return abs(v) < 0.05 ? tr("Even") : L10n.percent(abs(v))
    }

    private static func spokenValue(_ v: Double?) -> String {
        guard let v else { return tr("Not enough data") }
        if abs(v) < 0.05 { return tr("Balanced") }
        return v > 0 ? tr("Left side moved %@ more", L10n.percent(abs(v))) : tr("Right side moved %@ more", L10n.percent(abs(v)))
    }
}

// MARK: - Movement over time

/// Quantity of motion over the recording; tap or drag to jump the video there.
struct MotionCard: View {
    let digest: ReviewDigest
    let duration: Double
    /// Not observed here: only the cursor follows playback; the chart is equatable on its data.
    let player: ReviewPlayerModel

    var body: some View {
        ReviewCard(title: tr("Movement")) {
            MotionChart(digest: digest, duration: duration, player: player)
                .equatable()
                .frame(height: 110)
        }
    }

    struct Bar: Identifiable {
        let id: Int
        let t0: Double
        let t1: Double
        let v: Double
    }

    /// At most ~200 bars (aggregated bins), gaps left empty.
    static func points(_ g: ReviewDigest) -> [Bar] {
        let group = max(1, g.count / 200)
        var out: [Bar] = []
        var i = 0
        while i < g.count {
            var sum = 0.0, k = 0
            for j in i..<min(g.count, i + group) where g.motion[j].isFinite { sum += Double(g.motion[j]); k += 1 }
            if k > 0 {
                out.append(Bar(id: i, t0: g.start + Double(i) * g.bin, t1: g.start + Double(min(g.count, i + group)) * g.bin, v: sum / Double(k)))
            }
            i += group
        }
        return out
    }
}

/// The chart itself does not observe the player; only the cursor overlay does.
private struct MotionChart: View, Equatable {
    let digest: ReviewDigest
    let duration: Double
    let player: ReviewPlayerModel

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.duration == b.duration && a.digest.count == b.digest.count && a.digest.bin == b.digest.bin
            && a.digest.analysisFPS == b.digest.analysisFPS && a.digest.speedScale == b.digest.speedScale
    }

    var body: some View {
        Chart(MotionCard.points(digest)) { b in
            RectangleMark(xStart: .value("Start", b.t0), xEnd: .value("End", b.t1),
                          yStart: .value("Zero", 0), yEnd: .value("Movement", b.v))
                .foregroundStyle(LinearGradient(colors: [Color.mgSage.opacity(0.55), Color.mgSage], startPoint: .bottom, endPoint: .top))
        }
        .chartXScale(domain: 0...max(duration, 0.1))
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel { if let s = value.as(Double.self) { Text(clock(s)) } }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                ChartCursor(player: player, ticker: player.clock, proxy: proxy,
                            plot: proxy.plotFrame.map { geo[$0] } ?? geo.frame(in: .local), duration: duration)
            }
        }
        .accessibilityLabel(tr("Movement over time"))
    }
}

/// Playback cursor and scrubbing on top of a time chart (x axis 0…duration).
struct ChartCursor: View {
    let player: ReviewPlayerModel
    @ObservedObject var ticker: PlayerClock
    let proxy: ChartProxy
    let plot: CGRect
    let duration: Double

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.clear).contentShape(Rectangle())
            if let x = proxy.position(forX: ticker.time) {
                Rectangle().fill(Color.mgInk).frame(width: 2, height: plot.height)
                    .offset(x: plot.minX + x - 1, y: plot.minY)
            }
        }
        .scrubbing(width: plot.width, offset: plot.minX) { fraction, final in
            if !final { player.pause() }
            player.seek(fraction * max(duration, 0.1), precise: final)
        }
    }
}

// MARK: - Range of motion

struct RangeCard: View {
    let digest: ReviewDigest

    private struct Row: Identifiable {
        let id: String
        let name: String
        let lo: Double
        let hi: Double
        let color: Color
    }

    private var rows: [Row] {
        let meta: [(String, String, Color)] = [("elbow_L", tr("L elbow"), Limb.leftArm.color), ("elbow_R", tr("R elbow"), Limb.rightArm.color),
                                              ("knee_L", tr("L knee"), Limb.leftLeg.color), ("knee_R", tr("R knee"), Limb.rightLeg.color)]
        var out = meta.compactMap { key, name, color -> Row? in
            guard let r = digest.angleRange[key], r.count == 2 else { return nil }
            return Row(id: key, name: name, lo: r[0], hi: r[1], color: color)
        }
        // 3D videos: hips too (shoulder–hip–knee).
        for (key, name, color) in [("hip_L", tr("L hip"), Limb.leftLeg.color), ("hip_R", tr("R hip"), Limb.rightLeg.color)] {
            if let r = digest.hipRange?[key], r.count == 2 { out.append(Row(id: key, name: name, lo: r[0], hi: r[1], color: color)) }
        }
        return out
    }

    var body: some View {
        let rows = rows
        if !rows.isEmpty {
            ReviewCard(title: tr("Joint range"), trailing: "0–180°") {
                Chart(rows) { r in
                    BarMark(xStart: .value("From", r.lo), xEnd: .value("To", r.hi), y: .value("Joint", r.name), height: .fixed(12))
                        .foregroundStyle(r.color)
                        .cornerRadius(6)
                        .annotation(position: .trailing, spacing: 4) {
                            Text(verbatim: "\(Int(r.lo))–\(Int(r.hi))°").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                }
                .chartXScale(domain: 0...200)
                .chartXAxis {
                    AxisMarks(values: [0, 90, 180]) { _ in
                        AxisGridLine()
                        AxisValueLabel()
                    }
                }
                .frame(height: CGFloat(rows.count) * 30 + 24)
            }
        }
    }
}

// MARK: - Observations

extension MotorFinding {
    var tint: TimelineEvent.Tint {
        if status == .expectedForAge { return .expected }
        switch severity {
        case .info: return .info
        case .note: return .note
        case .discuss: return .discuss
        case .safety: return .safety
        }
    }
}

/// Tiles for what was noticed; how many checks were clear or couldn't run, underneath.
struct ObservationTiles: View {
    let report: MotorReport
    let refining: Bool
    var onSelect: (MotorFinding) -> Void
    var onShowList: () -> Void

    var body: some View {
        let shown = report.shown
        let checked = report.findings.filter { $0.status == .notDetected }.count
        let skipped = report.findings.filter { $0.status == .abstained && !(refining && $0.family == "rhythm") }.count
        ReviewCard(title: tr("Noticed")) {
            if shown.isEmpty {
                Text(tr("Nothing stood out")).font(.subheadline.weight(.semibold)).foregroundStyle(Color.mgInk)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(shown) { f in
                        Button { onSelect(f) } label: { tile(f) }.buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: 8) {
                Button(action: onShowList) {
                    Text(checked == 1 ? tr("1 check clear") : tr("%lld checks clear", checked))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.mgSageSoft, in: Capsule())
                }
                if skipped > 0 {
                    Button(action: onShowList) {
                        Text(skipped == 1 ? tr("1 couldn’t run") : tr("%lld couldn’t run", skipped))
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                    }
                }
                if refining {
                    Text(tr("Refining…")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.mgInk)
        }
    }

    private func tile(_ f: MotorFinding) -> some View {
        let color = TimelineEvent.color(f.tint)
        return HStack(alignment: .top, spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8).padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(f.name.text).font(.caption.weight(.semibold)).foregroundStyle(Color.mgInk).lineLimit(3)
                if !f.events.isEmpty {
                    Text(f.events.count == 1 ? tr("once") : tr("%lld times", f.events.count))
                        .font(.caption2.weight(.semibold)).foregroundStyle(color)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(color.opacity(0.25)))
    }
}

/// Everything about one observation, on demand: what was seen, replay, why it is mentioned,
/// what to do, sources and a clip to share.
struct ObservationDetailSheet: View {
    let finding: MotorFinding
    let rule: MotorRule?
    let sources: [String: MotorSource]
    let videoURL: URL
    let duration: Double
    var play: (Double, Double) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let color = TimelineEvent.color(finding.tint)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(finding.name.text).font(.mgTitle).foregroundStyle(Color.mgInk)
                        if let badge { Text(badge).font(.subheadline.weight(.semibold)).foregroundStyle(color) }
                    }
                    if let message = finding.message?.text, !message.isEmpty {
                        Text(message).font(.subheadline)
                    }
                    if !finding.events.isEmpty {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                            ForEach(Array(finding.events.sorted { $0.t0 < $1.t0 }.prefix(12).enumerated()), id: \.offset) { _, e in
                                Button {
                                    play(max(0, e.t0 - 0.5), min(duration, e.t1 + 0.5))
                                    dismiss()
                                } label: {
                                    Text(clock(e.t0))
                                        .font(.subheadline.weight(.semibold).monospacedDigit())
                                        .frame(maxWidth: .infinity, minHeight: 36)
                                        .background(color.opacity(0.12), in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(tr("Play from %@", clock(e.t0)))
                                .contextMenu { share(e) }
                            }
                        }
                    }
                    if finding.severity >= .discuss, finding.status != .expectedForAge, let first = finding.events.min(by: { $0.t0 < $1.t0 }) {
                        share(first).buttonStyle(.borderedProminent).tint(color)
                    }
                    if let explain = rule?.explain?.text {
                        section(tr("Why it’s mentioned"), explain)
                    }
                    if let followup = rule?.followup?.text, finding.status != .expectedForAge {
                        section(tr("What you can do"), followup)
                    }
                    let cited = (rule?.sources ?? []).compactMap { sources[$0] }
                    if !cited.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(tr("Sources")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(cited, id: \.self) { s in
                                if let url = URL(string: s.url) { Link(s.cite, destination: url).font(.caption2) } else { Text(s.cite).font(.caption2) }
                            }
                        }
                    }
                    Text(tr("Descriptive, from body landmarks. Not a diagnosis.")).font(.caption2).foregroundStyle(.secondary)
                }
                .padding()
            }
            .background(Color.mgPaper)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(tr("Done")) { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private var badge: String? {
        if finding.status == .expectedForAge { return tr("Common at this age") }
        switch finding.severity {
        case .discuss: return tr("Worth mentioning to your doctor")
        case .safety: return tr("Talk to a doctor soon")
        default: return nil
        }
    }

    private func section(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Color.mgSage)
            Text(text).font(.footnote).fixedSize(horizontal: false, vertical: true)
        }
        .mgCard(padding: 12)
    }

    private func share(_ e: MotorEvent) -> some View {
        let start = max(0, e.t0 - 2), end = min(duration, e.t1 + 2)
        return ShareLink(item: VideoClipExport(source: videoURL, start: start, end: end),
                         preview: SharePreview(tr("MoveGrow clip %1$@–%2$@", clock(start), clock(end)))) {
            Text(tr("Share clip"))
        }
    }
}

/// Checks with nothing noted, and checks that could not run here (with the reason).
struct CheckListSheet: View {
    let report: MotorReport
    let refining: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let checked = report.findings.filter { $0.status == .notDetected }
        let skipped = report.findings.filter { $0.status == .abstained && !(refining && $0.family == "rhythm") }
        NavigationStack {
            List {
                if !checked.isEmpty {
                    Section {
                        ForEach(checked) { f in Text(f.name.text).foregroundStyle(Color.mgInk) }
                    } header: { Text(tr("Nothing noted (%lld)", checked.count)) }
                }
                if !skipped.isEmpty {
                    Section {
                        ForEach(skipped) { f in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(f.name.text).font(.subheadline.weight(.semibold))
                                if let reason = f.abstainReason?.text, !reason.isEmpty {
                                    Text(reason).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: { Text(tr("Couldn’t run on this video (%lld)", skipped.count)) }
                }
            }
            .mgListBackground()
            .navigationTitle(tr("Checks"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(tr("Done")) { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
