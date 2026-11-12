// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
//
// The pictures of the welcome pages and the recording tips. They are drawn with the app's own baby
// figure (BabyFigure.swift), so what a parent sees before the first video is the baby they will meet
// in the 3D tab: the resting baby, kicking and waving gently on its mat, seen by the camera (two ways
// to add a video; not yet / all set), or from its side with the phone held above it (no perfect angle
// needed). No image files: SwiftUI Canvas only, in the app's palette, light and dark.
//
// The same poses, views and sizes are drawn by Research/onboarding-preview (a port of BabyFigure to
// JavaScript), which is how these pictures were looked at before the app was built.

import SwiftUI
import simd

// MARK: - The baby

/// The onboarding's baby: BabyFigure's resting pose, moving a little, on the mat BabyFloor would find.
enum OnboardingBaby {
    static let rest: [SIMD3<Float>] = BabyFigure.restingPose
    static let shape: BodyShape = BabyFigure.measure { rest[$0] }
    static let hips: SIMD3<Float> = (rest[MHR70.leftHip] + rest[MHR70.rightHip]) / 2
    /// The body's extent around the hips at rest (the figure's scale, so it does not pulse with the kicks).
    static let radius: Float = rest.filter { $0.x.isFinite }.map { simd_length($0 - hips) }.max() ?? 0.27

    /// 0 → 1 → 0 once per `period` seconds.
    private static func wave(_ t: Double, _ period: Double, _ phase: Double) -> Float {
        Float(0.5 - 0.5 * cos(2 * Double.pi * (t / period + phase)))
    }

    /// A direction between two directions (limb lengths stay as they are).
    private static func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ k: Float) -> SIMD3<Float> {
        simd_normalize(a + (b - a) * k)
    }

    /// The resting baby `time` seconds into a slow loop: the legs kick in turn (knee up, then out),
    /// the forearms wave. `nil` is the still resting pose. Camera frame, metres, like every 3D track.
    static func pose(at time: Double?) -> [SIMD3<Float>] {
        var p = rest
        guard let t = time else { return p }
        let left = SIMD3<Float>(1, 0, 0)
        for isLeft in [true, false] {
            let s: Float = isLeft ? 1 : -1
            let hip = isLeft ? MHR70.leftHip : MHR70.rightHip
            let knee = isLeft ? MHR70.leftKnee : MHR70.rightKnee
            let ankle = isLeft ? MHR70.leftAnkle : MHR70.rightAnkle
            let heel = isLeft ? MHR70.leftHeel : MHR70.rightHeel
            let bigToe = isLeft ? MHR70.leftBigToe : MHR70.rightBigToe
            let smallToe = isLeft ? MHR70.leftSmallToe : MHR70.rightSmallToe

            // legs: thigh 10.6 cm, shin 8.2 cm (the resting pose's own lengths)
            let k: Float = wave(t, 2.4, isLeft ? 0 : 0.45)
            let thighUp = SIMD3<Float>(s * 0.060, 0.045, -0.085)
            let thighOut = SIMD3<Float>(s * 0.034, 0.100, -0.020)
            let shinUp = SIMD3<Float>(s * -0.030, 0.060, 0.045)
            let shinOut = SIMD3<Float>(s * 0.004, 0.082, -0.006)
            let toeUp = SIMD3<Float>(s * 0.10, 0.55, -0.80)
            let toeOut = SIMD3<Float>(s * 0.15, 0.85, -0.50)
            let thigh: SIMD3<Float> = mix(thighUp, thighOut, k)
            let shin: SIMD3<Float> = mix(shinUp, shinOut, k)
            let toe: SIMD3<Float> = mix(toeUp, toeOut, k)
            let kneePoint: SIMD3<Float> = p[hip] + thigh * Float(0.106)
            let anklePoint: SIMD3<Float> = kneePoint + shin * Float(0.082)
            p[knee] = kneePoint
            p[ankle] = anklePoint
            p[heel] = anklePoint - toe * Float(0.015)
            p[bigToe] = anklePoint + toe * Float(0.06) - left * Float(0.008)
            p[smallToe] = anklePoint + toe * Float(0.05) + left * Float(0.018)

            // forearms: 8.3 cm, the hand 3.4 cm further along
            let elbow = isLeft ? MHR70.leftElbow : MHR70.rightElbow
            let wrist = isLeft ? MHR70.leftWrist : MHR70.rightWrist
            let knuckle = isLeft ? MHR70.leftMiddleKnuckle : MHR70.rightMiddleKnuckle
            let a: Float = wave(t, 3.1, isLeft ? 0.3 : 0.75)
            let foreRest = SIMD3<Float>(s * 0.008, -0.080, -0.020)
            let foreLifted = SIMD3<Float>(s * 0.050, -0.058, -0.045)
            let fore: SIMD3<Float> = mix(foreRest, foreLifted, a)
            let wristPoint: SIMD3<Float> = p[elbow] + fore * Float(0.083)
            p[wrist] = wristPoint
            p[knuckle] = wristPoint + fore * Float(0.034)
        }
        return p
    }

    /// The pose turned about the mat's normal (the camera's z axis) through the resting hips.
    static func turned(_ p: [SIMD3<Float>], by angle: Double) -> [SIMD3<Float>] {
        guard angle != 0 else { return p }
        let c = Float(cos(angle)), s = Float(sin(angle))
        return p.map { (q: SIMD3<Float>) -> SIMD3<Float> in
            guard q.x.isFinite else { return q }
            let x: Float = q.x - hips.x
            let y: Float = q.y - hips.y
            return SIMD3<Float>(hips.x + x * c - y * s, hips.y + x * s + y * c, q.z)
        }
    }

    /// The mat under the resting baby, as BabyFloor.make places it for a baby on its back (0.34 torso
    /// lengths behind the trunk, a little more mat above the head), turned with the baby.
    static func mat(turnedBy angle: Double = 0) -> BabyFloor {
        let L: Float = shape.torso
        let c = Float(cos(angle)), s = Float(sin(angle))
        let normal = SIMD3<Float>(0, 0, -1)
        let ex = SIMD3<Float>(c, s, 0)
        let ey = SIMD3<Float>(-s, c, 0)
        let under = SIMD3<Float>(hips.x, hips.y, hips.z + 0.34 * L)
        let origin: SIMD3<Float> = under - ey * (0.25 * L)
        let bias = SIMD3<Float>(0.35, 0.55, 0.45)
        let across: SIMD3<Float> = bias - normal * simd_dot(bias, normal)
        let light: SIMD3<Float> = simd_normalize(across - normal)
        return BabyFloor(origin: origin, normal: normal, ex: ex, ey: ey, light: light,
                         size: SIMD2<Float>(3.6 * L, 4.8 * L), round: false)
    }

    /// Draws the mat and the baby. `turn` spins both on the mat; `yaw` and `pitch` are the 3D tab's view
    /// angles (0, 0 = as the camera sees them); `fill` and `offset` (fractions of the size) place them.
    static func draw(_ ctx: inout GraphicsContext, size: CGSize, time: Double?, turn: Double = 0, yaw: Double = 0,
                     pitch: Double = 0, fill: Double = 0.36, offset: CGSize = .zero) {
        let p = turned(pose(at: time), by: turn)
        let center = CGPoint(x: size.width * (0.5 + offset.width), y: size.height * (0.5 + offset.height))
        BabyFigure.render(&ctx, size: size, point: { p[$0] }, radius: radius, shape: shape,
                          floor: mat(turnedBy: turn), yaw: yaw, pitch: pitch, fill: Float(fill), center: center)
    }
}

// MARK: - Building blocks

/// Seconds since the picture appeared, about 30 times a second while `active`. With Reduce Motion the
/// picture holds one moment instead.
struct ArtClock<Content: View>: View {
    let active: Bool
    let content: (Double) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    init(active: Bool, @ViewBuilder content: @escaping (Double) -> Content) {
        self.active = active
        self.content = content
    }

    var body: some View {
        if reduceMotion {
            content(0.9)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !active)) { timeline in
                content(timeline.date.timeIntervalSince(start))
            }
        }
    }
}

/// The baby on its mat. `camera` paints the ground of a camera picture (sage to sand) instead of the
/// 3D tab's background.
struct BabyScene: View {
    var time: Double? = nil
    var turn: Double = 0
    var yaw: Double = 0
    var pitch: Double = 0
    var fill: Double = 0.36
    var offset: CGSize = .zero
    var camera = false

    var body: some View {
        Canvas { ctx, size in
            if camera {
                ctx.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .linearGradient(Gradient(colors: [Color.mgSageSoft, Color.mgCard]),
                                               startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            } else {
                BabyFigure.drawBackground(&ctx, size: size)
            }
            OnboardingBaby.draw(&ctx, size: size, time: time, turn: turn, yaw: yaw, pitch: pitch, fill: fill, offset: offset)
        }
    }
}

/// A camera picture as the recorder shows it: 9 : 16, with the recorder's dashed guide, green once
/// everything is in place. `good` = the whole baby in the middle; otherwise too close and off to one
/// side, a hand and both feet outside the picture.
struct ViewfinderArt: View {
    var good: Bool
    var time: Double?
    var width: CGFloat

    var body: some View {
        let corner = width * 0.1
        BabyScene(time: time, fill: good ? 0.50 : 0.74, offset: good ? .zero : CGSize(width: 0.20, height: 0.22), camera: true)
            .frame(width: width, height: width * 16 / 9)
            .overlay {
                RoundedRectangle(cornerRadius: corner * 0.8)
                    .strokeBorder(good ? Color.green : Color.white, style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                    .shadow(color: .black.opacity(good ? 0 : 0.3), radius: 1)
                    .padding(.horizontal, width * 30 / 310)
                    .padding(.vertical, width * 42 / 310)
            }
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(Color.mgInk.opacity(0.1), lineWidth: 1))
    }
}

// MARK: - Page 1: record here, or bring videos from Photos

struct TwoWaysArt: View {
    var width: CGFloat
    var active = true

    var body: some View {
        let u = width / 326
        VStack(spacing: 12 * u) {
            ZStack(alignment: .topLeading) {
                album(u).offset(x: 180 * u, y: 70 * u)
                ArtClock(active: active) { t in phone(t, u) }
                    .offset(x: 8 * u, y: 3 * u)
            }
            .frame(width: width, height: 268 * u, alignment: .topLeading)
            .accessibilityHidden(true)
            HStack(alignment: .top, spacing: 0) {
                caption(tr("Record"), tr("Up to 3 minutes"))
                    .frame(width: 154 * u)
                caption(tr("From Photos"), tr("Up to %lld videos at a time", BatchImporter.maxVideos))
                    .frame(width: 172 * u)
            }
        }
        .frame(width: width)
    }

    /// The recorder: the baby in the camera picture, a red dot and a running clock.
    private func phone(_ t: Double, _ u: CGFloat) -> some View {
        BabyScene(time: t, fill: 0.50, offset: CGSize(width: 0, height: 0.03), camera: true)
            .frame(width: 122 * u, height: 246 * u)
            .clipShape(RoundedRectangle(cornerRadius: 19 * u, style: .continuous))
            .overlay(alignment: .top) {
                HStack(spacing: 5) {
                    Circle().fill(Color.red).frame(width: 8, height: 8)
                    Text(verbatim: clock(12 + t))
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.45), in: Capsule())
                .padding(.top, 10 * u)
            }
            .padding(8 * u)
            .background(RoundedRectangle(cornerRadius: 26 * u, style: .continuous).fill(BabyPalette.mat))
            .overlay(RoundedRectangle(cornerRadius: 26 * u, style: .continuous).strokeBorder(Color.mgSage.opacity(0.35), lineWidth: 1.5))
    }

    /// Three videos from Photos, the one on top chosen (as in the album's Select mode).
    private func album(_ u: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            thumbnail(0.2, u).rotationEffect(.degrees(-9)).offset(x: -18 * u, y: 14 * u)
            thumbnail(2.0, u).rotationEffect(.degrees(8)).offset(x: 18 * u, y: -22 * u)
            thumbnail(0.9, u)
                .overlay(alignment: .bottomTrailing) {
                    Text(verbatim: "0:42")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(.black.opacity(0.6), in: Capsule())
                        .padding(9 * u)
                }
                .overlay(alignment: .topLeading) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.mgSage)
                        .padding(9 * u)
                }
        }
    }

    private func thumbnail(_ moment: Double, _ u: CGFloat) -> some View {
        BabyScene(time: moment, fill: 0.40, offset: CGSize(width: 0, height: 0.03), camera: true)
            .frame(width: 118 * u, height: 118 * u)
            .clipShape(RoundedRectangle(cornerRadius: 14 * u, style: .continuous))
            .padding(4 * u)
            .background(RoundedRectangle(cornerRadius: 17 * u, style: .continuous).fill(BabyPalette.mat))
            .overlay(RoundedRectangle(cornerRadius: 17 * u, style: .continuous).strokeBorder(Color.mgInk.opacity(0.08), lineWidth: 1))
    }

    private func caption(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.headline).foregroundStyle(Color.mgInk)
            Text(detail).font(.footnote).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Page 2: not yet / all set

/// Two camera pictures side by side with the recorder's own words under them: too close, a hand and
/// the feet outside the picture; and the whole baby in the middle.
struct FramingArt: View {
    var width: CGFloat
    var active = true

    var body: some View {
        let w = min(168, (width - 20) / 2)
        ArtClock(active: active) { t in
            HStack(alignment: .top, spacing: 20) {
                column(good: false, t, w)
                column(good: true, t, w)
            }
        }
        .frame(width: width)
        .accessibilityElement(children: .combine)
    }

    private func column(good: Bool, _ t: Double, _ w: CGFloat) -> some View {
        VStack(spacing: 8) {
            ViewfinderArt(good: good, time: t, width: w)
                .accessibilityHidden(true)
            Text(good ? tr("You’re all set.") : tr("Keep both hands and feet in view."))
                .font(.footnote.weight(good ? .semibold : .regular))
                .foregroundStyle(good ? Color.mgSage : Color.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: w)
    }
}

// MARK: - Page 3: no perfect angle needed

/// The baby on its mat seen from its side, and the phone held straight above it or a little to either
/// side: all three see the whole baby.
struct AnglesArt: View {
    var width: CGFloat
    var active = true

    var body: some View {
        ArtClock(active: active) { t in
            Canvas { ctx, size in
                BabyFigure.drawBackground(&ctx, size: size)
                let sway = 8 * sin(2 * Double.pi * t / 9)              // the mat turns a little, slowly
                OnboardingBaby.draw(&ctx, size: size, time: t, turn: (-70 + sway) * Double.pi / 180,
                                    pitch: -58 * Double.pi / 180, fill: 0.27, offset: CGSize(width: 0, height: 0.20))
                Self.drawPhones(&ctx, size: size)
            }
        }
        .frame(width: width, height: width * 286 / 326)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityHidden(true)
    }

    /// A dotted arc over the baby with three phones on it, each looking down at the baby.
    private static func drawPhones(_ ctx: inout GraphicsContext, size: CGSize) {
        let u = size.width / 326
        let baby = CGPoint(x: size.width * 0.5, y: size.height * 0.70)
        let radius = size.height * 0.56
        func onArc(_ degrees: Double) -> CGPoint {
            let a = (degrees - 90) * Double.pi / 180
            return CGPoint(x: baby.x + radius * CGFloat(cos(a)), y: baby.y + radius * CGFloat(sin(a)))
        }
        var arc = Path()
        arc.addArc(center: baby, radius: radius, startAngle: .degrees(-144), endAngle: .degrees(-36), clockwise: false)
        ctx.stroke(arc, with: .color(Color.mgSage.opacity(0.5)), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [1, 7]))

        let places: [Double] = [-40, 0, 40]
        for degrees in places {                                        // what each phone sees
            let phone = onArc(degrees)
            var cone = Path()
            cone.move(to: phone)
            cone.addLine(to: CGPoint(x: baby.x - 70 * u, y: baby.y + 6 * u))
            cone.addLine(to: CGPoint(x: baby.x + 70 * u, y: baby.y + 6 * u))
            cone.closeSubpath()
            let strength: Double = degrees == 0 ? 0.22 : 0.14
            let fade = Gradient(stops: [.init(color: Color.mgSage.opacity(strength), location: 0),
                                        .init(color: Color.mgSage.opacity(0), location: 0.85)])
            ctx.fill(cone, with: .linearGradient(fade, startPoint: phone, endPoint: baby))
        }
        for degrees in places {                                        // the phones, seen edge-on
            let phone = onArc(degrees)
            var g = ctx
            g.translateBy(x: phone.x, y: phone.y)
            g.rotate(by: .degrees(degrees))
            let slab = Path(roundedRect: CGRect(x: -21 * u, y: -6 * u, width: 42 * u, height: 12 * u), cornerRadius: 4.5 * u)
            g.fill(slab, with: .color(BabyPalette.mat))
            g.stroke(slab, with: .color(Color.mgInk.opacity(0.75)), lineWidth: 1.5)
            let lens = Path(roundedRect: CGRect(x: -15 * u, y: 5 * u, width: 9 * u, height: 4 * u), cornerRadius: 2 * u)
            g.fill(lens, with: .color(Color.mgInk.opacity(0.75)))
        }
    }
}
