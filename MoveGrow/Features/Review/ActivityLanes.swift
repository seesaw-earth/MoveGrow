// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
//
// Activity map: a compact overview under the parameter timeline — tracking, the four limbs as
// colour strips (stronger = faster), head direction and events — with the same cursor and
// scrubbing.

import SwiftUI

/// Lanes: tracking, four limbs (colour strength = speed), head direction, events.
struct TimelineBars: View, Equatable {
    let digest: ReviewDigest?
    let events: [TimelineEvent]
    let duration: Double

    static let coverageHeight: CGFloat = 5
    static let limbHeight: CGFloat = 13
    static let headHeight: CGFloat = 16
    static let eventHeight: CGFloat = 16
    static let gap: CGFloat = 3
    static var height: CGFloat { coverageHeight + 4 * limbHeight + headHeight + eventHeight + 6 * gap }

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.duration == b.duration && a.events == b.events && a.digest?.count == b.digest?.count
            && a.digest?.bin == b.digest?.bin && a.digest?.speedScale == b.digest?.speedScale && a.digest?.analysisFPS == b.digest?.analysisFPS
    }

    var body: some View {
        Canvas { ctx, size in
            let w = size.width
            let d = max(duration, 0.1)
            func x(_ t: Double) -> CGFloat { CGFloat(min(max(0, t / d), 1)) * w }
            var y: CGFloat = 0
            let back = Color.primary.opacity(0.06)

            // Tracking ribbon.
            ctx.fill(Path(roundedRect: CGRect(x: 0, y: y, width: w, height: Self.coverageHeight), cornerRadius: 2), with: .color(back))
            if let g = digest {
                var tracked = Path()
                for i in 0..<g.count where g.coverage[i] >= 0.5 {
                    let t = g.start + Double(i) * g.bin
                    tracked.addRect(CGRect(x: x(t), y: y, width: max(1, x(t + g.bin) - x(t)), height: Self.coverageHeight))
                }
                ctx.fill(tracked, with: .color(Color.mgSage.opacity(0.55)))
            }
            y += Self.coverageHeight + Self.gap

            // Limb lanes: one path per opacity level instead of one fill per bin.
            for limb in Limb.allCases {
                let row = CGRect(x: 0, y: y, width: w, height: Self.limbHeight)
                ctx.fill(Path(roundedRect: row, cornerRadius: 3), with: .color(back))
                if let g = digest, let speed = g.speed[limb.rawValue] {
                    let levels = 8
                    var paths = [Path](repeating: Path(), count: levels)
                    for i in 0..<g.count {
                        let v = Double(speed[i])
                        guard v.isFinite, v > 0 else { continue }
                        let level = min(levels - 1, Int((pow(min(1, v / g.speedScale), 0.7) * Double(levels)).rounded(.down)))
                        let t = g.start + Double(i) * g.bin
                        paths[level].addRect(CGRect(x: x(t), y: y, width: max(1, x(t + g.bin) - x(t)), height: Self.limbHeight))
                    }
                    for level in 0..<levels {
                        ctx.fill(paths[level], with: .color(limb.color.opacity(0.12 + 0.88 * Double(level + 1) / Double(levels))))
                    }
                }
                y += Self.limbHeight + Self.gap
            }

            // Head direction: up = turned to the baby's left, down = right.
            let mid = y + Self.headHeight / 2
            ctx.fill(Path(roundedRect: CGRect(x: 0, y: y, width: w, height: Self.headHeight), cornerRadius: 3), with: .color(back))
            if let g = digest {
                var left = Path(), right = Path()
                for i in 0..<g.count {
                    let v = Double(g.headYaw[i])
                    guard v.isFinite, abs(v) > 0.08 else { continue }
                    let t = g.start + Double(i) * g.bin
                    let h = CGFloat(min(1, abs(v))) * (Self.headHeight / 2 - 1)
                    let r = CGRect(x: x(t), y: v > 0 ? mid - h : mid, width: max(1, x(t + g.bin) - x(t)), height: h)
                    if v > 0 { left.addRect(r) } else { right.addRect(r) }
                }
                ctx.fill(left, with: .color(Limb.leftArm.color.opacity(0.8)))
                ctx.fill(right, with: .color(Limb.rightArm.color.opacity(0.8)))
            }
            var axis = Path()
            axis.move(to: CGPoint(x: 0, y: mid)); axis.addLine(to: CGPoint(x: w, y: mid))
            ctx.stroke(axis, with: .color(Color.primary.opacity(0.15)), lineWidth: 0.5)
            y += Self.headHeight + Self.gap

            // Events: observations as bars, milestones as diamonds.
            ctx.fill(Path(roundedRect: CGRect(x: 0, y: y, width: w, height: Self.eventHeight), cornerRadius: 3), with: .color(back))
            for e in events {
                let x0 = x(e.t0), x1 = max(x0 + 3, x(e.t1))
                if e.tint == .milestone {
                    let cx = (x0 + x1) / 2, cy = y + Self.eventHeight / 2, r: CGFloat = 5
                    var p = Path()
                    p.move(to: CGPoint(x: cx, y: cy - r)); p.addLine(to: CGPoint(x: cx + r, y: cy))
                    p.addLine(to: CGPoint(x: cx, y: cy + r)); p.addLine(to: CGPoint(x: cx - r, y: cy)); p.closeSubpath()
                    ctx.fill(p, with: .color(e.color))
                } else {
                    ctx.fill(Path(roundedRect: CGRect(x: x0, y: y + 3, width: x1 - x0, height: Self.eventHeight - 6), cornerRadius: 3),
                             with: .color(e.color))
                }
            }
        }
    }
}

/// Lane names to the left of the timeline (the thin tracking lane needs none).
struct TimelineGutter: View {
    var body: some View {
        VStack(alignment: .trailing, spacing: TimelineBars.gap) {
            Color.clear.frame(width: 1, height: TimelineBars.coverageHeight)
            ForEach(Limb.allCases) { limb in
                Text(limb.short)
                    .foregroundStyle(limb.color)
                    .frame(height: TimelineBars.limbHeight)
            }
            Text(tr("Head")).frame(height: TimelineBars.headHeight)
            Text(tr("Events")).frame(height: TimelineBars.eventHeight)
        }
        .font(.system(size: 9, weight: .semibold))
        .lineLimit(1)
        .foregroundStyle(.secondary)
        .fixedSize()
        .accessibilityHidden(true)
    }
}

/// Timeline with the playback cursor: tap to jump, drag sideways to scrub (vertical drags scroll).
struct ReviewTimeline: View {
    let player: ReviewPlayerModel
    @ObservedObject var ticker: PlayerClock
    let digest: ReviewDigest?
    let events: [TimelineEvent]

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            TimelineGutter()
            GeometryReader { geo in
                let w = geo.size.width
                let d = player.duration
                ZStack(alignment: .topLeading) {
                    TimelineBars(digest: digest, events: events, duration: d).equatable()
                    Capsule()
                        .fill(Color.mgInk)
                        .frame(width: 2.5, height: TimelineBars.height + 6)
                        .offset(x: CGFloat(min(max(0, ticker.time / d), 1)) * w - 1.25, y: -3)
                        .shadow(color: .black.opacity(0.25), radius: 1)
                }
                .contentShape(Rectangle())
                .scrubbing(width: w) { fraction, final in
                    if !final { player.pause() }
                    player.seek(fraction * d, precise: final)
                }
            }
            .frame(height: TimelineBars.height)
        }
        .accessibilityElement()
        .accessibilityLabel(tr("Movement timeline"))
        .accessibilityValue(clock(ticker.time))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: player.seek(player.time + 5)
            case .decrement: player.seek(player.time - 5)
            @unknown default: break
            }
        }
    }
}
