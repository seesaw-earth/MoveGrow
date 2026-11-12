// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
//
// Review player: the video with the skeleton, event navigation and frame stepping — modelled on
// RodentFlow's review screen. The skeleton is redrawn on every display frame from the player's
// own clock (TimelineView); the parameter timeline is in ParameterTimeline.swift.

import SwiftUI
import AVFoundation
import UIKit

// MARK: - Player

/// Playback position (≈ 12 updates per second while playing). Kept apart from the player model so
/// only the cursor, read-out, navigator and skeleton follow it — not the whole review screen.
@MainActor final class PlayerClock: ObservableObject {
    @Published var time: Double = 0
}

@MainActor final class ReviewPlayerModel: ObservableObject {
    let player: AVPlayer
    let clock = PlayerClock()
    private(set) var duration: Double
    @Published private(set) var isPlaying = false
    @Published private(set) var rate: Float = 1
    private var observer: Any?
    private var statusObservation: NSKeyValueObservation?
    private var ready = false
    private var segmentEnd: Double?
    /// Start playing once the pending seek has landed.
    private var playAfterSeek = false

    var time: Double { clock.time }

    init(url: URL, duration: Double) {
        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        self.duration = max(0.1, duration)
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 12), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t) }
        }
        // Seeks wait until the item can serve them (QA1820); a seek asked for earlier is kept.
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let isReady = item.status == .readyToPlay
            let length = item.duration.seconds
            Task { @MainActor [weak self] in
                guard let self, isReady, !self.ready else { return }
                self.ready = true
                if length.isFinite, length > 0 { self.duration = length }
                if self.chaseTarget != nil { self.seekToChaseTarget() }
            }
        }
    }

    private func tick(_ t: CMTime) {
        let playing = player.rate != 0
        if playing != isPlaying { isPlaying = playing }
        // While a seek is pending the player still reports the old position: don't let the cursor jump back.
        guard !seekInFlight, chaseTarget == nil else { return }
        let s = t.seconds.isFinite ? t.seconds : 0
        if abs(s - clock.time) > 1e-4 { clock.time = s }
        if playing, let end = segmentEnd, s >= end - 0.03 {
            segmentEnd = nil
            pause()
        }
    }

    /// Exact position for drawing: read from the player while it plays.
    var displayTime: Double {
        guard isPlaying, !seekInFlight else { return clock.time }
        let t = player.currentTime().seconds
        return t.isFinite ? t : clock.time
    }

    func stop() {
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        statusObservation = nil
    }

    func pause() {
        player.pause()
        segmentEnd = nil
        playAfterSeek = false
        if isPlaying { isPlaying = false }
    }

    func toggle() {
        if player.rate != 0 || playAfterSeek {
            pause()
            return
        }
        segmentEnd = nil
        let atEnd = clock.time >= duration - 0.1
            || player.currentItem.map { $0.duration.isNumeric && CMTimeCompare($0.currentTime(), $0.duration) >= 0 } ?? false
        if atEnd {
            playAfterSeek = true
            seek(0)
        } else {
            startPlaying()
        }
    }

    /// Plays one section and stops at its end (playback starts once the seek has landed).
    func playSegment(_ start: Double, _ end: Double) {
        player.pause()
        segmentEnd = min(duration, max(start + 0.2, end))
        playAfterSeek = true
        seek(start)
    }

    private func startPlaying() {
        player.playImmediately(atRate: rate)
        isPlaying = true
    }

    // "Chase time" seeking (Apple QA1820): a new seek never cancels the one in flight, so
    // dragging along the timeline keeps showing frames instead of restarting the decoder.
    private var chaseTarget: CMTime?
    private var chaseTolerance = CMTime.zero
    private var seekInFlight = false

    /// `precise: false` lets the decoder land up to 0.1 s away (fast while scrubbing).
    func seek(_ t: Double, precise: Bool = true) {
        let c = min(max(0, t), duration)
        clock.time = c
        chaseTarget = CMTime(seconds: c, preferredTimescale: 600)
        chaseTolerance = precise ? .zero : CMTime(seconds: 0.1, preferredTimescale: 600)
        if ready, !seekInFlight { seekToChaseTarget() }
    }

    private func seekToChaseTarget() {
        guard let target = chaseTarget else { return }
        chaseTarget = nil
        seekInFlight = true
        let tolerance = chaseTolerance
        player.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.seekInFlight = false
                if self.chaseTarget != nil {
                    self.seekToChaseTarget()
                } else if self.playAfterSeek {
                    self.playAfterSeek = false
                    self.startPlaying()
                }
            }
        }
    }

    func step(frames: Int, fps: Double) {
        pause()
        seek(clock.time + Double(frames) / max(fps, 1))
    }

    func setRate(_ r: Float) {
        rate = r
        if player.rate != 0 { player.rate = r }
    }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    final class PlayerUIView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> PlayerUIView {
        let v = PlayerUIView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        v.backgroundColor = .black
        return v
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {}
}

// MARK: - Skeleton

enum SkeletonDrawing {
    /// Bones as MJ index pairs.
    static let bones: [(Int, Int)] = BodyJoint.connections.compactMap { pair in
        guard let a = MJ.index[pair.0.rawValue], let b = MJ.index[pair.1.rawValue] else { return nil }
        return (a, b)
    }

    /// Draws bones and joints; `joint(j)` returns normalised (x, y, confidence) in the displayed frame.
    static func draw(_ ctx: inout GraphicsContext, in rect: CGRect, minConfidence: Float = 0.3,
                     scale: CGFloat = 1, joint: (Int) -> (x: Float, y: Float, c: Float)) {
        func point(_ j: Int) -> CGPoint? {
            let p = joint(j)
            guard p.c >= minConfidence, p.x.isFinite, p.y.isFinite, p.x >= 0, p.x <= 1, p.y >= 0, p.y <= 1 else { return nil }
            return CGPoint(x: rect.minX + CGFloat(p.x) * rect.width, y: rect.minY + CGFloat(p.y) * rect.height)
        }
        var bonesPath = Path()
        for (a, b) in bones {
            guard let p = point(a), let q = point(b) else { continue }
            bonesPath.move(to: p)
            bonesPath.addLine(to: q)
        }
        ctx.stroke(bonesPath, with: .color(.black.opacity(0.35)), style: StrokeStyle(lineWidth: 5 * scale, lineCap: .round, lineJoin: .round))
        ctx.stroke(bonesPath, with: .color(Color.mgSkeleton), style: StrokeStyle(lineWidth: 3 * scale, lineCap: .round, lineJoin: .round))
        var dots = Path()
        for j in 0..<MJ.count {
            guard let p = point(j) else { continue }
            let r: CGFloat = ([MJ.leftWrist, MJ.rightWrist, MJ.leftAnkle, MJ.rightAnkle].contains(j) ? 4.5 : 3) * scale
            dots.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        }
        ctx.fill(dots, with: .color(.white))
        ctx.stroke(dots, with: .color(Color.mgSage), lineWidth: 1.5 * scale)
    }
}

/// Skeleton over the playing video, redrawn every display frame while playing.
struct SkeletonOverlay: View {
    @ObservedObject var player: ReviewPlayerModel
    @ObservedObject var ticker: PlayerClock
    let track: PoseTrack?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !player.isPlaying)) { _ in
            let t = player.isPlaying ? player.displayTime : ticker.time
            Canvas { ctx, size in
                guard let track, let i = Self.nearest(track, t) else { return }
                SkeletonDrawing.draw(&ctx, in: CGRect(origin: .zero, size: size), scale: size.width > 500 ? 1.3 : 1) { j in
                    (track.x(i, j), track.y(i, j), track.conf(i, j))
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// Nearest analysed frame (binary search); nothing across a detector gap.
    static func nearest(_ track: PoseTrack, _ time: Double) -> Int? { track.frame(near: time) }
}

// MARK: - Timeline

/// Something to mark and jump to on the timeline.
struct TimelineEvent: Identifiable, Hashable {
    enum Tint: Hashable { case info, note, discuss, safety, expected, milestone }
    var id: String
    /// Filter group (rule id, or "milestones").
    var group: String
    var t0: Double
    var t1: Double
    var tint: Tint
    /// What it is, shown on the video when the scrubber reaches it.
    var title: String = ""

    var color: Color { Self.color(tint) }

    static func color(_ tint: Tint) -> Color {
        switch tint {
        case .info: return .secondary
        case .note: return Color.mgSage
        case .discuss: return .orange
        case .safety: return .red
        case .expected: return .green
        case .milestone: return Color.mgGold
        }
    }
}

enum Limb: String, CaseIterable, Identifiable {
    case leftArm = "L_arm", rightArm = "R_arm", leftLeg = "L_leg", rightLeg = "R_leg"
    var id: String { rawValue }
    var color: Color {
        switch self {
        case .leftArm: return Color.mgSeries1
        case .rightArm: return Color.mgSeries2
        case .leftLeg: return Color.mgSeries3
        case .rightLeg: return Color.mgSeries4
        }
    }
    var isLeft: Bool { self == .leftArm || self == .leftLeg }
    var isArm: Bool { self == .leftArm || self == .rightArm }
    var name: String {
        switch self {
        case .leftArm: return tr("Left arm")
        case .rightArm: return tr("Right arm")
        case .leftLeg: return tr("Left leg")
        case .rightLeg: return tr("Right leg")
        }
    }
    /// For pills, legends and lane labels: "L arm" / "左臂" / "Brazo izq.".
    var short: String {
        switch self {
        case .leftArm: return tr("L arm")
        case .rightArm: return tr("R arm")
        case .leftLeg: return tr("L leg")
        case .rightLeg: return tr("R leg")
        }
    }
}

extension View {
    /// Tap to jump; horizontal drags scrub, vertical ones are left to the enclosing ScrollView.
    /// `action(fraction, final)` — `final` is true on tap and when the drag ends.
    func scrubbing(width: CGFloat, offset: CGFloat = 0, action: @escaping (Double, Bool) -> Void) -> some View {
        func fraction(_ x: CGFloat) -> Double { Double(min(max(0, (x - offset) / max(width, 1)), 1)) }
        return self
            .gesture(SpatialTapGesture().onEnded { v in action(fraction(v.location.x), true) })
            .simultaneousGesture(DragGesture(minimumDistance: 8)
                .onChanged { v in
                    guard abs(v.translation.width) > abs(v.translation.height) else { return }
                    action(fraction(v.location.x), false)
                }
                .onEnded { v in
                    guard abs(v.translation.width) > abs(v.translation.height) else { return }
                    action(fraction(v.location.x), true)
                })
    }
}

// MARK: - Read-out, navigation and controls

/// Time, and which limbs are moving right now (a pill lights up).
struct ReviewReadout: View {
    let player: ReviewPlayerModel
    @ObservedObject var ticker: PlayerClock
    let digest: ReviewDigest?

    var body: some View {
        let bin = digest?.bin(at: ticker.time)
        // Longer limb names (Spanish) drop the total length first.
        ViewThatFits(in: .horizontal) {
            row(bin, showDuration: true)
            row(bin, showDuration: false)
        }
    }

    private func row(_ bin: Int?, showDuration: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(clock(ticker.time)).font(.title3.weight(.semibold).monospacedDigit())
            if showDuration {
                Text(clock(player.duration)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            HStack(spacing: 5) {
                ForEach(Limb.allCases) { limb in
                    let share = bin.flatMap { b in digest?.active[limb.rawValue].map { Double($0[b]) } } ?? .nan
                    let on = share.isFinite && share >= 0.5
                    Text(limb.short)
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(on ? Color.white : (share.isFinite ? limb.color : Color.secondary.opacity(0.4)))
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(on ? limb.color : limb.color.opacity(share.isFinite ? 0.12 : 0.04), in: Capsule())
                        .animation(.easeOut(duration: 0.15), value: on)
                        .accessibilityLabel(on ? tr("%@, moving", limb.name) : tr("%@, still", limb.name))
                }
            }
        }
    }
}

/// A legend chip / filter for event navigation.
struct EventGroup: Identifiable, Hashable {
    var id: String
    var title: String
    var tint: TimelineEvent.Tint
}

/// Previous / next event, with the legend chips as the filter.
struct EventNavigator: View {
    let player: ReviewPlayerModel
    @ObservedObject var ticker: PlayerClock
    let events: [TimelineEvent]
    let groups: [EventGroup]
    @Binding var filter: String?

    private var starts: [Double] {
        events.filter { filter == nil || $0.group == filter }.map(\.t0).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !groups.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        chip(title: tr("All"), tint: nil, selected: filter == nil) { filter = nil }
                        ForEach(groups) { g in
                            chip(title: g.title, tint: TimelineEvent.color(g.tint),
                                 selected: filter == g.id) { filter = filter == g.id ? nil : g.id }
                        }
                    }
                }
            }
            let s = starts
            let t = ticker.time
            let next = s.firstIndex { $0 > t + 0.05 }
            let previous = s.lastIndex { $0 < t - 0.05 }
            HStack {
                Button { if let previous { jump(s[previous]) } } label: {
                    Image(systemName: "chevron.backward").frame(width: 44, height: 36)
                }
                .disabled(previous == nil)
                .accessibilityLabel(tr("Previous event"))
                Spacer()
                Text(s.isEmpty ? "—" : "\(next ?? s.count) / \(s.count)")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button { if let next { jump(s[next]) } } label: {
                    Image(systemName: "chevron.forward").frame(width: 44, height: 36)
                }
                .disabled(next == nil)
                .accessibilityLabel(tr("Next event"))
            }
            .font(.headline)
            .background(Color.primary.opacity(0.05), in: Capsule())
        }
    }

    private func jump(_ t: Double) {
        let end = events.first { $0.t0 == t }?.t1 ?? t + 3
        player.playSegment(max(0, t - 0.5), end + 0.5)
    }

    private func chip(title: String, tint: Color?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let tint { Circle().fill(tint).frame(width: 8, height: 8) }
                Text(title).font(.caption.weight(.semibold)).lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 30)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(selected ? Color.mgSage : Color.primary.opacity(0.07), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct ReviewControls: View {
    @ObservedObject var player: ReviewPlayerModel
    let fps: Double
    var onBookmark: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            button("gobackward.5", tr("Back 5 seconds")) { player.seek(player.time - 5) }
            button("backward.frame", tr("Previous frame")) { player.step(frames: -1, fps: fps) }
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 50))
                    .symbolRenderingMode(.hierarchical)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(maxWidth: .infinity)
            .accessibilityLabel(player.isPlaying ? tr("Pause") : tr("Play"))
            button("forward.frame", tr("Next frame")) { player.step(frames: 1, fps: fps) }
            Menu {
                Picker(tr("Speed"), selection: Binding(get: { player.rate }, set: { player.setRate($0) })) {
                    Text(verbatim: "0.25×").tag(Float(0.25))
                    Text(verbatim: "0.5×").tag(Float(0.5))
                    Text(verbatim: "1×").tag(Float(1))
                    Text(verbatim: "2×").tag(Float(2))
                }
                Button(tr("Save a milestone here"), action: onBookmark)
            } label: {
                Text(player.rate == 1 ? "1×" : String(format: "%g×", player.rate))
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .accessibilityLabel(tr("Playback speed and options"))
        }
        .foregroundStyle(Color.mgSage)
    }

    private func button(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.title3).frame(maxWidth: .infinity, minHeight: 50)
        }
        .accessibilityLabel(label)
    }
}

// MARK: - Scrubber on the video

/// What the scrubber has just reached: shown on the video for a moment, then it fades.
@MainActor final class ScrubCaption: ObservableObject {
    @Published private(set) var event: TimelineEvent?
    private var hide: Task<Void, Never>?

    /// Shows `event` (or keeps it shown) and fades it `after` seconds without a new call.
    func show(_ event: TimelineEvent, after: Double = 1.6) {
        if self.event?.id != event.id {
            withAnimation(.easeOut(duration: 0.15)) { self.event = event }
        }
        schedule(after)
    }

    /// The scrubber moved off the event: fade a little sooner.
    func leave() { if event != nil { schedule(0.8) } }

    private func schedule(_ seconds: Double) {
        hide?.cancel()
        hide = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.35)) { self?.event = nil }
        }
    }
}

/// The caption on the video: the event's colour, name and time.
struct ScrubCaptionView: View {
    @ObservedObject var caption: ScrubCaption

    var body: some View {
        ZStack {
            if let e = caption.event {
                HStack(spacing: 7) {
                    Circle().fill(e.color).frame(width: 9, height: 9)
                        .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1))
                    Text(e.title.isEmpty ? tr("Event") : e.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    Text(verbatim: clock(e.t0))
                        .font(.caption.monospacedDigit())
                        .opacity(0.8)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.black.opacity(0.6), in: Capsule())
                .padding(.top, 10)
                .padding(.horizontal, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .accessibilityElement(children: .combine)
            }
        }
        .allowsHitTesting(false)
    }
}

/// A timeline under the video: drag (or tap) to move through it; the events are small dots on it.
/// Reaching an event — the scrubber snaps to its dot when the finger is close — shows its name on the
/// video for a moment, with a light tick.
struct VideoScrubber: View {
    @ObservedObject var player: ReviewPlayerModel
    @ObservedObject var ticker: PlayerClock
    let events: [TimelineEvent]
    let caption: ScrubCaption
    @State private var dragging = false
    @State private var resume = false
    @State private var snapped: String?

    private static let snapDistance: CGFloat = 8

    var body: some View {
        HStack(spacing: 10) {
            Text(verbatim: clock(ticker.time))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
                .frame(minWidth: 40, alignment: .leading)
            GeometryReader { geo in
                let width = geo.size.width
                Canvas { ctx, size in draw(&ctx, size) }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in scrub(to: v.location.x, width: width, final: false) }
                            .onEnded { v in scrub(to: v.location.x, width: width, final: true) }
                    )
            }
            .frame(height: 30)
            Text(verbatim: clock(player.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
                .frame(minWidth: 40, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .accessibilityElement()
        .accessibilityLabel(tr("Video position"))
        .accessibilityValue(clock(ticker.time))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: player.seek(player.time + 5)
            case .decrement: player.seek(player.time - 5)
            @unknown default: break
            }
        }
    }

    private func x(_ t: Double, _ width: CGFloat) -> CGFloat {
        CGFloat(min(max(t / max(player.duration, 0.1), 0), 1)) * width
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let mid = size.height / 2, w = size.width
        let now = x(ticker.time, w)
        ctx.fill(Path(roundedRect: CGRect(x: 0, y: mid - 2, width: w, height: 4), cornerRadius: 2), with: .color(.white.opacity(0.25)))
        ctx.fill(Path(roundedRect: CGRect(x: 0, y: mid - 2, width: now, height: 4), cornerRadius: 2), with: .color(Color.mgSkeleton))
        // events: their span as a faint band, their start as a dot
        for e in events {
            let a = x(e.t0, w), b = max(a + 1, x(e.t1, w))
            ctx.fill(Path(CGRect(x: a, y: mid - 2, width: b - a, height: 4)), with: .color(e.color.opacity(0.45)))
        }
        for e in events {
            let a = x(e.t0, w)
            let r: CGFloat = snapped == e.id ? 5 : 3.5
            let dot = CGRect(x: a - r, y: mid - 9 - r, width: 2 * r, height: 2 * r)
            ctx.fill(Path(ellipseIn: dot), with: .color(e.color))
            ctx.stroke(Path(ellipseIn: dot), with: .color(.black.opacity(0.35)), lineWidth: 0.8)
        }
        let r: CGFloat = dragging ? 9 : 7
        let thumb = CGRect(x: now - r, y: mid - r, width: 2 * r, height: 2 * r)
        ctx.fill(Path(ellipseIn: thumb), with: .color(.white))
        ctx.stroke(Path(ellipseIn: thumb), with: .color(.black.opacity(0.25)), lineWidth: 1)
    }

    private func scrub(to location: CGFloat, width: CGFloat, final: Bool) {
        if !dragging {
            dragging = true
            resume = player.isPlaying
            player.pause()
        }
        var t = Double(min(max(location / max(width, 1), 0), 1)) * player.duration
        // Snap to an event's dot when the finger is close to it.
        let near = events.min { abs(x($0.t0, width) - location) < abs(x($1.t0, width) - location) }
        if let near, abs(x(near.t0, width) - location) <= Self.snapDistance {
            t = near.t0
            if snapped != near.id {
                snapped = near.id
                UISelectionFeedbackGenerator().selectionChanged()
            }
        } else {
            snapped = nil
        }
        player.seek(t, precise: final)
        // The event under the scrubber (the latest one started), if any.
        let here = events.filter { $0.t0 - 0.05 <= t && t <= max($0.t1, $0.t0 + 0.5) }.max { $0.t0 < $1.t0 }
        if let here { caption.show(here) } else { caption.leave() }
        if final {
            dragging = false
            snapped = nil
            if resume { player.toggle() }
        }
    }
}

