// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
//
// The 3D page's baby figure: a soft, toy-like baby drawn from InstantHMR's 3D keypoints. A big round
// head with a face, a mint romper, chubby arms and legs, and mittens and socks in the side colours
// (blue = the baby's left, coral = the baby's right). Every joint is where the analysis put it; the app
// only adds the thickness of the body, shaped like a baby's: a big skull with the ears low and towards
// the back, a short neck to the base of the skull, a trunk as wide as the shoulders (acromions) and hips
// (from the video's own measurements), and legs leaving the romper at the hip joints at the trunk's lower
// corners. The trunk is the convex hull of a shoulder girdle, a tummy and a pelvis ellipsoid; the rest
// are spheres and tapered capsules. All are projected like the
// skeleton (orthographic, turned by yaw and pitch), shaded softly and painted far to near,
// over a mat (lying) or a round rug (sitting, standing, walking) with soft shadows that show how high
// hands and feet are lifted. Used by the review screen's 3D tab and, in a resting pose with glowing
// limbs, by the Activity card.

import SwiftUI
import simd

/// The baby's proportions (m): shoulder-to-hip distance (the unit of every thickness), and the distances
/// between the shoulder joints and between the hip joints (nil when not measured).
struct BodyShape: Sendable, Equatable {
    var torso: Float
    var shoulders: Float?
    var hips: Float?

    static let unknown = BodyShape(torso: 0.18, shoulders: nil, hips: nil)
}

/// A piece of a limb: upper arm or thigh, forearm or shin, mitten or foot.
enum LimbPiece: Hashable {
    case upper(Limb), lower(Limb), end(Limb)

    static let all: [LimbPiece] = Limb.allCases.flatMap { [LimbPiece.upper($0), .lower($0), .end($0)] }
}

// MARK: - Palette

/// Colours of the figure (pastels that stay the same in dark mode) and of its scene (adapting).
enum BabyPalette {
    struct Material {
        let base: Color
        let light: Color
        let shade: Color
        let line: Color
    }

    private static func fixed(_ v: UInt32) -> Color { Color(light: v, dark: v) }

    static let romper = Material(base: fixed(0xBFE3AE), light: fixed(0xE6F6DC), shade: fixed(0x92C47E), line: fixed(0x77A866))
    static let skin = Material(base: fixed(0xFFDAC6), light: fixed(0xFFF1E8), shade: fixed(0xF1B497), line: fixed(0xD9977B))
    /// The baby's left: a pastel of the app's left-side blue (mgSeries1).
    static let left = Material(base: fixed(0xA9D3F6), light: fixed(0xE0F1FF), shade: fixed(0x7DB4E5), line: fixed(0x6697C9))
    /// The baby's right: a pastel of the right-side coral (mgSeries2).
    static let right = Material(base: fixed(0xFBB89C), light: fixed(0xFFE3D6), shade: fixed(0xEE9172), line: fixed(0xD27858))
    static let ink = fixed(0x3B332D)
    static let blush = fixed(0xF39A98)
    static let mouth = fixed(0xC7655D)
    static let hair = fixed(0xC39A6E)
    static let hairLine = fixed(0xA67C52)
    static let sprout = fixed(0x6FA663)

    static let backgroundTop = Color(light: 0xEEF5E8, dark: 0x232B24)
    static let backgroundBottom = Color(light: 0xFBF6EE, dark: 0x161513)
    static let mat = Color(light: 0xFFFDF9, dark: 0x2C342D)
    static let matEdge = Color(light: 0xEBDDCF, dark: 0x1E241F)
    static let stitch = Color(light: 0xE9C7BF, dark: 0x4A5A49)
    static let dotA = Color(light: 0xDDEFD3, dark: 0x37443A)
    static let dotB = Color(light: 0xFBE2DC, dark: 0x463734)
    static let shadow = Color(light: 0x55654F, dark: 0x000000)
}

// MARK: - Body frame

/// Hips, shoulders and the trunk's axes in one frame, as in HMRKinematics: u towards the baby's left,
/// v towards the head, w = u × v out of the chest (s: at the shoulders, h: at the hips).
private struct BodyAxes {
    let hips: SIMD3<Float>
    let shoulders: SIMD3<Float>
    let v: SIMD3<Float>
    let us: SIMD3<Float>, ws: SIMD3<Float>
    let uh: SIMD3<Float>, wh: SIMD3<Float>

    init?(_ point: (Int) -> SIMD3<Float>) {
        let ls = point(MHR70.leftShoulder), rs = point(MHR70.rightShoulder)
        let lh = point(MHR70.leftHip), rh = point(MHR70.rightHip)
        guard [ls, rs, lh, rh].allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { return nil }
        hips = (lh + rh) / 2
        shoulders = (ls + rs) / 2
        guard simd_length(shoulders - hips) > 1e-4 else { return nil }
        v = simd_normalize(shoulders - hips)
        us = orthogonal(ls - rs, to: v)
        uh = orthogonal(lh - rh, to: v)
        ws = simd_cross(us, v)
        wh = simd_cross(uh, v)
    }

    /// Out of the chest, for the whole trunk.
    var w: SIMD3<Float> { unit(ws + wh) }
}

private func unit(_ v: SIMD3<Float>) -> SIMD3<Float> {
    let n = simd_length(v)
    return n > 1e-6 ? v / n : .zero
}

private func orthogonal(_ v: SIMD3<Float>, to axis: SIMD3<Float>) -> SIMD3<Float> {
    unit(v - axis * simd_dot(v, axis))
}

// MARK: - Floor

/// The mat (lying) or round rug (sitting, standing, walking) under the figure: one plane for the whole
/// video, in the camera frame, found from the body's average orientation. Held babies get none.
struct BabyFloor: Sendable {
    var origin: SIMD3<Float>
    /// From the floor towards the baby.
    var normal: SIMD3<Float>
    var ex: SIMD3<Float>
    var ey: SIMD3<Float>
    /// The direction the light travels, for the shadows.
    var light: SIMD3<Float>
    var size: SIMD2<Float>
    var round: Bool

    static func make(track t: HMRTrack, context: RecordingContext, torso L: Float) -> BabyFloor? {
        let lying: Bool
        switch context {
        case .supine, .prone: lying = true
        case .sitting, .standing, .walking: lying = false
        case .held, .other: return nil
        }
        var frames: [(index: Int, body: BodyAxes)] = []
        let stride = max(1, t.count / 400)
        for i in Swift.stride(from: 0, to: t.count, by: stride) where t.valid[i] {
            if let b = BodyAxes({ t.point3D(i, $0) }) { frames.append((i, b)) }
        }
        guard !frames.isEmpty else { return nil }
        let count = Float(frames.count)
        let mean = frames.reduce(SIMD3<Float>.zero) { $0 + (lying ? $1.body.w : $1.body.v) } / count
        var n: SIMD3<Float> = simd_length(mean) > 0.5 ? simd_normalize(mean) : (lying ? SIMD3(0, 0, -1) : SIMD3(0, -1, 0))
        if lying && n.z > 0 { n = -n }                       // the mat is on the far side from the camera

        // Lowest body point along the normal (10th percentile over the video): the back on a mat, the
        // feet (or the seat) on a rug.
        let feet = [MHR70.leftAnkle, MHR70.rightAnkle, MHR70.leftHeel, MHR70.rightHeel,
                    MHR70.leftBigToe, MHR70.rightBigToe, MHR70.leftSmallToe, MHR70.rightSmallToe]
        let trunk = [MHR70.leftShoulder, MHR70.rightShoulder, MHR70.leftHip, MHR70.rightHip]
        var lows: [Float] = []
        for (i, b) in frames {
            var points = (lying ? trunk : feet).map { t.point3D(i, $0) }
            if !lying { points.append(b.hips - b.v * 0.42 * L) }
            if let low = points.map({ simd_dot($0, n) }).filter(\.isFinite).min() { lows.append(low) }
        }
        guard !lows.isEmpty else { return nil }
        lows.sort()
        let d = lows[lows.count / 10] - (lying ? 0.34 : 0.10) * L

        let hips = frames.map { $0.body.hips }
        let meanHips = hips.reduce(SIMD3<Float>.zero, +) / count
        var origin = meanHips - n * (simd_dot(meanHips, n) - d)
        let hint: SIMD3<Float> = lying ? SIMD3(0, 1, 0) : SIMD3(0, 0, 1)     // down the picture / away
        var ey = hint - n * simd_dot(hint, n)
        if simd_length(ey) < 0.3 { ey = SIMD3<Float>(1, 0, 0) - n * n.x }
        ey = unit(ey)
        let ex = simd_cross(n, ey)
        let xs = hips.map { simd_dot($0, ex) }, ys = hips.map { simd_dot($0, ey) }
        let spreadX = (xs.max() ?? 0) - (xs.min() ?? 0), spreadY = (ys.max() ?? 0) - (ys.min() ?? 0)
        let size: SIMD2<Float>
        if lying {
            size = SIMD2(3.6 * L + spreadX, 4.8 * L + spreadY)
            origin -= ey * 0.25 * L                          // a little more mat above the head
        } else {
            let r = min(9 * L, 4.6 * L + max(spreadX, spreadY))
            size = SIMD2(r, r)
        }
        let bias = SIMD3<Float>(0.35, 0.55, 0.45)            // light from the upper left, a little behind the camera
        let light = unit(-n + (bias - n * simd_dot(bias, n)))
        return BabyFloor(origin: origin, normal: n, ex: ex, ey: ey, light: light, size: size, round: !lying)
    }

    /// Where the light puts `p` on the floor (floor coordinates, m) and how high `p` is above it.
    func shadow(_ p: SIMD3<Float>) -> (point: CGPoint, height: Float) {
        let q = p + light * (simd_dot(origin - p, normal) / simd_dot(light, normal))
        return (CGPoint(x: CGFloat(simd_dot(q - origin, ex)), y: CGFloat(simd_dot(q - origin, ey))), simd_dot(p - origin, normal))
    }

    /// The shadow of a body vector, in floor coordinates.
    func shadow(vector a: SIMD3<Float>) -> CGVector {
        let a2 = a - light * (simd_dot(a, normal) / simd_dot(light, normal))
        return CGVector(dx: CGFloat(simd_dot(a2, ex)), dy: CGFloat(simd_dot(a2, ey)))
    }
}

// MARK: - Projection

/// The 3D view's turn (yaw about the camera's vertical axis, then pitch) and orthographic projection.
private struct Projector {
    let root: SIMD3<Float>
    let c1: Float, s1: Float, c2: Float, s2: Float
    let scale: Float
    let center: CGPoint

    init(root: SIMD3<Float>, yaw: Double, pitch: Double, scale: Float, center: CGPoint) {
        self.root = root
        c1 = Float(cos(yaw)); s1 = Float(sin(yaw)); c2 = Float(cos(pitch)); s2 = Float(sin(pitch))
        self.scale = scale
        self.center = center
    }

    /// A direction in view space (x right, y down, z away from the viewer).
    func vec(_ d: SIMD3<Float>) -> SIMD3<Float> {
        let x1 = c1 * d.x + s1 * d.z
        let z1 = -s1 * d.x + c1 * d.z
        return SIMD3(x1, c2 * d.y - s2 * z1, s2 * d.y + c2 * z1)
    }

    func view(_ p: SIMD3<Float>) -> SIMD3<Float> { vec(p - root) }
    func screen(_ v: SIMD3<Float>) -> CGPoint {
        CGPoint(x: center.x + CGFloat(scale * v.x), y: center.y + CGFloat(scale * v.y))
    }
    func point(_ p: SIMD3<Float>) -> CGPoint { screen(view(p)) }
    func onScreen(_ d: SIMD3<Float>) -> CGVector {
        let v = vec(d)
        return CGVector(dx: CGFloat(scale * v.x), dy: CGFloat(scale * v.y))
    }
    /// Maps a flat design (x along `east`, y along `north`, metres) at `p` onto the screen.
    func patch(at p: SIMD3<Float>, east: SIMD3<Float>, north: SIMD3<Float>) -> CGAffineTransform {
        let o = point(p), e = onScreen(east), n = onScreen(north)
        return CGAffineTransform(a: e.dx, b: e.dy, c: n.dx, d: n.dy, tx: o.x, ty: o.y)
    }
}

/// Towards the light, in view space (up and to the left, in front).
private let viewLight = simd_normalize(SIMD3<Float>(-0.5, -0.75, -0.45))
private let screenLight: CGVector = {
    let l = simd_normalize(SIMD2<Float>(viewLight.x, viewLight.y))
    return CGVector(dx: CGFloat(l.x), dy: CGFloat(l.y))
}()

// MARK: - Screen shapes

/// An ellipse on screen (semi-axes a ≥ b): a projected ellipsoid's outline, and every part's shading frame.
private struct Oval {
    var center: CGPoint
    var angle: CGFloat
    var a: CGFloat
    var b: CGFloat

    /// The ellipse spanned by projected semi-axes (orthographic projection of an ellipsoid).
    init(center: CGPoint, axes: [CGVector]) {
        var m11: CGFloat = 0, m12: CGFloat = 0, m22: CGFloat = 0
        for v in axes {
            m11 += v.dx * v.dx; m12 += v.dx * v.dy; m22 += v.dy * v.dy
        }
        let half = (m11 + m22) / 2
        let disc = max(0, half * half - (m11 * m22 - m12 * m12)).squareRoot()
        let l1 = half + disc, l2 = max(half - disc, 1e-6)
        if abs(m12) > 1e-9 {
            angle = atan2(m12, l1 - m22)
        } else {
            angle = m11 >= m22 ? 0 : .pi / 2
        }
        self.center = center
        a = max(l1, 1e-6).squareRoot()
        b = l2.squareRoot()
    }

    init(center: CGPoint, angle: CGFloat, a: CGFloat, b: CGFloat) {
        self.center = center; self.angle = angle; self.a = a; self.b = b
    }

    var transform: CGAffineTransform {
        CGAffineTransform(translationX: center.x, y: center.y).rotated(by: angle).scaledBy(x: max(a, 0.5), y: max(b, 0.5))
    }

    var path: Path { Path(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2)).applying(transform) }

    /// Points around the outline.
    func points(_ n: Int = 48) -> [CGPoint] {
        let c = cos(angle), s = sin(angle)
        return (0..<n).map { k in
            let t = 2 * CGFloat.pi * CGFloat(k) / CGFloat(n)
            let x = a * cos(t), y = b * sin(t)
            return CGPoint(x: center.x + x * c - y * s, y: center.y + x * s + y * c)
        }
    }
}

/// The convex hull of points (Andrew's monotone chain) as a closed path. The orthographic image of the
/// convex hull of two ellipsoids is the convex hull of their images, so this draws a 3D egg exactly.
private func hullPath(_ points: [CGPoint]) -> Path {
    let pts = points.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
    guard pts.count >= 3 else { return Path() }
    func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
    }
    var lower: [CGPoint] = [], upper: [CGPoint] = []
    for q in pts {
        while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], q) <= 0 { lower.removeLast() }
        lower.append(q)
    }
    for q in pts.reversed() {
        while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], q) <= 0 { upper.removeLast() }
        upper.append(q)
    }
    var path = Path()
    path.addLines(Array(lower.dropLast()) + Array(upper.dropLast()))
    path.closeSubpath()
    return path
}

/// Outline of the convex hull of two circles: a tapered capsule.
private func capsulePath(_ a: CGPoint, _ ra: CGFloat, _ b: CGPoint, _ rb: CGFloat) -> Path {
    let dx = b.x - a.x, dy = b.y - a.y
    let length = (dx * dx + dy * dy).squareRoot()
    if length <= abs(ra - rb) + 1e-6 {                       // one circle inside the other
        let (c, r) = ra >= rb ? (a, ra) : (b, rb)
        return Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    }
    let beta = atan2(dy, dx)
    let theta = acos(max(-1, min(1, (ra - rb) / length)))    // outward normals at beta ± theta
    let steps = 14
    var path = Path()
    for k in 0...steps {                                     // around b, through beta
        let t = beta + theta - 2 * theta * CGFloat(k) / CGFloat(steps)
        let q = CGPoint(x: b.x + rb * cos(t), y: b.y + rb * sin(t))
        if k == 0 { path.move(to: q) } else { path.addLine(to: q) }
    }
    for k in 0...steps {                                     // around a, through beta + pi
        let t = beta - theta - (2 * .pi - 2 * theta) * CGFloat(k) / CGFloat(steps)
        path.addLine(to: CGPoint(x: a.x + ra * cos(t), y: a.y + ra * sin(t)))
    }
    path.closeSubpath()
    return path
}

// MARK: - Figure

enum BabyFigure {
    /// The baby's proportions over the video (medians, so the figure keeps one shape).
    static func measure(_ t: HMRTrack) -> BodyShape {
        var torso: [Float] = [], shoulders: [Float] = [], hips: [Float] = []
        let stride = max(1, t.count / 400)
        for i in Swift.stride(from: 0, to: t.count, by: stride) where t.valid[i] {
            let point = { (j: Int) in t.point3D(i, j) }
            guard let b = BodyAxes(point) else { continue }
            torso.append(simd_length(b.shoulders - b.hips))
            shoulders.append(simd_length(point(MHR70.leftShoulder) - point(MHR70.rightShoulder)))
            hips.append(simd_length(point(MHR70.leftHip) - point(MHR70.rightHip)))
        }
        return BodyShape(torso: median(torso) ?? 0.18, shoulders: median(shoulders), hips: median(hips))
    }

    /// The proportions of one pose (the Activity card's resting baby).
    static func measure(_ p: (Int) -> SIMD3<Float>) -> BodyShape {
        guard let b = BodyAxes(p) else { return BodyShape(torso: 0.18, shoulders: nil, hips: nil) }
        return BodyShape(torso: simd_length(b.shoulders - b.hips),
                         shoulders: simd_length(p(MHR70.leftShoulder) - p(MHR70.rightShoulder)),
                         hips: simd_length(p(MHR70.leftHip) - p(MHR70.rightHip)))
    }

    private static func median(_ values: [Float]) -> Float? {
        let v = values.filter(\.isFinite).sorted()
        return v.isEmpty ? nil : v[v.count / 2]
    }

    /// Mitten and sock colours, for the legend.
    static let leftColor = BabyPalette.left.base
    static let rightColor = BabyPalette.right.base

    static func drawBackground(_ ctx: inout GraphicsContext, size: CGSize) {
        ctx.fill(Path(CGRect(origin: .zero, size: size)),
                 with: .linearGradient(Gradient(colors: [BabyPalette.backgroundTop, BabyPalette.backgroundBottom]),
                                       startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
    }

    /// Draws the scene for frame `i` of a track: background, floor with shadows, then the figure.
    static func draw(_ ctx: inout GraphicsContext, size: CGSize, track: HMRTrack, frame i: Int, radius: Float,
                     shape: BodyShape, floor: BabyFloor?, yaw: Double, pitch: Double, zoom: Double = 1) {
        drawBackground(&ctx, size: size)
        render(&ctx, size: size, point: { track.point3D(i, $0) }, radius: radius, shape: shape, floor: floor, yaw: yaw, pitch: pitch,
               fill: Float(0.36 * zoom),
               headOrder: headOrder(track: track, frame: i, yaw: yaw, pitch: pitch, torso: shape.torso))
    }

    /// Whether each limb piece is in front of the head at frame `i` (true) or behind it (false).
    ///
    /// Painting far to near compares centres, so a hand next to the head — at about the head's depth, and
    /// touching the drawn head, which is rounder than a real one — would flip in front and behind with every
    /// small movement. Instead the piece's depth relative to the head's centre is averaged over ±0.17 s,
    /// and the piece goes behind the head only once it is clearly behind it (more than 0.12 torso lengths
    /// deeper), and comes back in front once it is no longer deeper than the head's centre; in between it
    /// stays as it was. The decision is run over the two seconds before `i`, so a frame always looks the
    /// same, playing or scrubbed. (Simulated with 4 mm of depth noise: a hand resting beside the head
    /// changed sides 3 times a minute instead of several hundred.)
    static func headOrder(track: HMRTrack, frame i: Int, yaw: Double, pitch: Double, torso L: Float) -> [LimbPiece: Bool] {
        guard i >= 0, i < track.count else { return [:] }
        let history = 2.0, half = 0.17
        let behindAt = 0.12 * L, frontAt: Float = 0, startAt = 0.06 * L
        let turn = Projector(root: .zero, yaw: yaw, pitch: pitch, scale: 1, center: .zero)
        var frames: [Int] = []
        var k = i
        while k >= 0 && track.times[i] - track.times[k] <= history + half {
            if track.valid[k] { frames.append(k) }
            k -= 1
        }
        frames.reverse()
        // Depth of each piece's centre behind the head's centre (> 0: deeper), per frame.
        let relative: [[LimbPiece: Float]] = frames.map { (k: Int) -> [LimbPiece: Float] in
            let point = { (j: Int) in track.point3D(k, j) }
            guard let body = BodyAxes(point) else { return [:] }
            let a = Anchors(point, body: body, L: L)
            let headZ = turn.vec(a.head).z
            var out: [LimbPiece: Float] = [:]
            for (piece, axis) in a.pieces {
                let dz = turn.vec((axis.0 + axis.1) / 2).z - headZ
                if dz.isFinite { out[piece] = dz }
            }
            return out
        }
        var state: [LimbPiece: Bool] = [:]
        for (n, k) in frames.enumerated() where track.times[i] - track.times[k] <= history {
            for piece in LimbPiece.all {
                var sum: Float = 0, count: Float = 0
                var m = n
                while m >= 0 && track.times[k] - track.times[frames[m]] <= half {
                    if let d = relative[m][piece] { sum += d; count += 1 }
                    m -= 1
                }
                m = n + 1
                while m < frames.count && track.times[frames[m]] - track.times[k] <= half {
                    if let d = relative[m][piece] { sum += d; count += 1 }
                    m += 1
                }
                guard count > 0 else { continue }
                let d = sum / count
                if let front = state[piece] {
                    if front && d > behindAt { state[piece] = false } else if !front && d < frontAt { state[piece] = true }
                } else {
                    state[piece] = d < startAt
                }
            }
        }
        return state
    }

    /// Where the head is on screen (for drawings around it).
    struct Layout {
        var headCenter: CGPoint
        var headRadius: CGFloat
    }

    /// Draws a pose (MHR70 points, camera frame, metres) far to near over an optional floor. `fill` is the
    /// share of the shorter side that `radius` (the body's extent around the hips) takes; `glow` puts a
    /// soft halo in each limb's colour, stronger the larger its value (0...1).
    @discardableResult
    static func render(_ ctx: inout GraphicsContext, size: CGSize, point: (Int) -> SIMD3<Float>, radius: Float,
                       shape: BodyShape, floor: BabyFloor?, yaw: Double, pitch: Double, fill: Float = 0.36,
                       center: CGPoint? = nil, glow: [Limb: Double] = [:], headOrder: [LimbPiece: Bool] = [:]) -> Layout? {
        guard let body = BodyAxes(point) else { return nil }
        let L = shape.torso
        let root = body.hips + (body.shoulders - body.hips) * 0.6    // turn about the middle (the head is big)
        let scale = Float(min(size.width, size.height)) * fill / max(radius, 0.05)
        let view = Projector(root: root, yaw: yaw, pitch: pitch, scale: scale,
                             center: center ?? CGPoint(x: size.width / 2, y: size.height / 2))
        var figure = FigureBuilder(view: view, shape: shape)
        figure.build(point, body: body)
        let outline = CGFloat(min(2.2, max(0.8, 0.022 * L * scale)))

        // Limb pieces that overlap the head keep the side of it they were given (see headOrder).
        if let headDepth = figure.headDepth, !headOrder.isEmpty {
            for (piece, front) in headOrder {
                let members = figure.parts.indices.filter { figure.parts[$0].piece == piece }
                let overlaps = members.contains { k in
                    guard figure.parts[k].path != nil else { return false }
                    let o = figure.parts[k].oval
                    let dx = o.center.x - figure.headCenter.x, dy = o.center.y - figure.headCenter.y
                    return (dx * dx + dy * dy).squareRoot() < figure.headRadius + max(o.a, o.b)
                }
                guard overlaps else { continue }
                for k in members {
                    let d = figure.parts[k].depth
                    figure.parts[k].sortDepth = front ? min(d, headDepth - 0.02 * L) : max(d, headDepth + 0.02 * L)
                }
            }
        }

        if let floor { drawFloor(&ctx, floor: floor, view: view, L: L, shadows: figure.shadows) }
        for limb in Limb.allCases {
            guard let f = glow[limb], f.isFinite else { continue }
            let amount = min(1, max(0, f))
            let paths = figure.parts.filter { $0.limb == limb }.compactMap(\.path)
            guard !paths.isEmpty else { continue }
            var halo = ctx
            halo.opacity = 0.18 + 0.6 * amount
            halo.addFilter(.blur(radius: 2 + 4 * amount))
            halo.drawLayer { g in
                for p in paths {
                    g.stroke(p, with: .color(limb.color), style: StrokeStyle(lineWidth: 5 + 9 * amount, lineJoin: .round))
                    g.fill(p, with: .color(limb.color))
                }
            }
        }
        // Far to near; ties (pieces held at the head) keep their own order.
        for part in figure.parts.sorted(by: { ($0.sortDepth ?? $0.depth, $0.depth) > ($1.sortDepth ?? $1.depth, $1.depth) }) {
            if let path = part.path, let material = part.material {
                shade(&ctx, path: path, oval: part.oval, material: material)
                ctx.stroke(path, with: .color(material.line.opacity(0.9)), style: StrokeStyle(lineWidth: outline, lineJoin: .round))
            }
            switch part.decal {
            case let .face(center, r, forward, left, up)?:
                if let path = part.path { drawFace(&ctx, view: view, center: center, R: r, f: forward, l: left, up: up, clip: path) }
            case let .sprout(spot, east, north, out, extent)?:
                if let path = part.path { drawSprout(&ctx, view: view, spot: spot, east: east, north: north, out: out, size: extent, clip: path) }
            case let .tuft(base, r, forward, up)?:
                drawTuft(&ctx, view: view, base: base, R: r, f: forward, up: up, outline: outline)
            case let .legOpening(region, thigh)?:
                var cover = ctx
                cover.clip(to: region)
                shade(&cover, path: thigh.union(thigh.strokedPath(StrokeStyle(lineWidth: outline * 1.8))),
                      oval: part.oval, material: BabyPalette.romper)
                var edge = ctx
                edge.clip(to: thigh)
                edge.stroke(region, with: .color(BabyPalette.romper.line.opacity(0.9)), style: StrokeStyle(lineWidth: outline, lineJoin: .round))
            case nil:
                break
            }
        }
        return Layout(headCenter: figure.headCenter, headRadius: figure.headRadius)
    }

    // MARK: Activity card

    /// A baby on its back seen from above (its left on the right of the picture): arms in a W, legs a
    /// little frog-like. Camera frame, metres; only the points the figure uses are set.
    static let restingPose: [SIMD3<Float>] = {
        var p = [SIMD3<Float>](repeating: SIMD3(.nan, .nan, .nan), count: HMRTrack.J)
        let z: Float = 0.80
        p[MHR70.leftHip] = SIMD3(0.040, 0.060, z); p[MHR70.rightHip] = SIMD3(-0.040, 0.060, z)
        p[MHR70.leftShoulder] = SIMD3(0.068, -0.110, z); p[MHR70.rightShoulder] = SIMD3(-0.068, -0.110, z)
        let head = SIMD3<Float>(0, -0.185, z - 0.005)
        let forward = simd_normalize(SIMD3<Float>(0, -0.12, -1)), left = SIMD3<Float>(1, 0, 0)
        p[MHR70.leftEar] = head + left * 0.05
        p[MHR70.rightEar] = head - left * 0.05
        p[MHR70.nose] = head + forward * 0.065
        for (s, side) in [(Float(1), true), (Float(-1), false)] {
            let (el, wr, kn, an) = side ? (MHR70.leftElbow, MHR70.leftWrist, MHR70.leftKnee, MHR70.leftAnkle)
                                        : (MHR70.rightElbow, MHR70.rightWrist, MHR70.rightKnee, MHR70.rightAnkle)
            let (knuckle, heel, big, small) = side ? (MHR70.leftMiddleKnuckle, MHR70.leftHeel, MHR70.leftBigToe, MHR70.leftSmallToe)
                                                   : (MHR70.rightMiddleKnuckle, MHR70.rightHeel, MHR70.rightBigToe, MHR70.rightSmallToe)
            p[el] = SIMD3(s * 0.132, -0.058, z - 0.01)
            p[wr] = SIMD3(s * 0.140, -0.138, z - 0.03)
            p[knuckle] = SIMD3(s * 0.138, -0.172, z - 0.035)
            p[kn] = SIMD3(s * 0.092, 0.138, z - 0.05)
            p[an] = SIMD3(s * 0.068, 0.214, z - 0.03)
            let toe = simd_normalize(SIMD3<Float>(s * 0.15, 0.8, -0.6))
            p[heel] = p[an] - toe * 0.015
            p[big] = p[an] + toe * Float(0.06) - left * Float(0.008)
            p[small] = p[an] + toe * Float(0.05) + left * Float(0.018)
        }
        return p
    }()

    /// The resting baby with each limb glowing by how much of the time it moved, and arcs by the head
    /// for how much of the time it was turned to each side (`headTurn`: left, middle, right).
    static func drawActivity(_ ctx: inout GraphicsContext, size: CGSize, share: [Limb: Double], headTurn: [Double]) {
        let p = restingPose
        let hips = (p[MHR70.leftHip] + p[MHR70.rightHip]) / 2
        let radius = p.filter { $0.x.isFinite }.map { simd_length($0 - hips) }.max() ?? 0.27
        guard let layout = render(&ctx, size: size, point: { p[$0] }, radius: radius, shape: measure { p[$0] },
                                  floor: nil, yaw: 0, pitch: 0, fill: 0.40,
                                  center: CGPoint(x: size.width / 2, y: size.height / 2 + 0.03 * size.height),
                                  glow: share) else { return }
        let turn = headTurn.count == 3 ? headTurn : [0, 0, 0]
        let r = layout.headRadius + 6
        for (side, amount, color) in [(1.0, turn[0], Limb.leftArm.color), (-1.0, turn[2], Limb.rightArm.color)] where amount > 0.02 {
            var arc = Path()
            let middle = side > 0 ? 0.0 : 180.0
            let half = 15 + 55 * amount
            arc.addArc(center: layout.headCenter, radius: r, startAngle: .degrees(middle - half), endAngle: .degrees(middle + half), clockwise: false)
            ctx.stroke(arc, with: .color(color.opacity(0.35 + 0.65 * amount)), style: StrokeStyle(lineWidth: 4, lineCap: .round))
        }
    }

    /// Fills a part with a soft radial shading: light towards the upper left, shade at the far rim.
    private static func shade(_ ctx: inout GraphicsContext, path: Path, oval: Oval, material: BabyPalette.Material) {
        let a = max(oval.a, 0.5), b = max(oval.b, 0.5), big = max(a, b)
        let c = cos(-oval.angle), s = sin(-oval.angle)
        let lx = (screenLight.dx * c - screenLight.dy * s) * 0.42 * big / a
        let ly = (screenLight.dx * s + screenLight.dy * c) * 0.42 * big / b
        var local = ctx
        let t = oval.transform
        local.concatenate(t)
        let gradient = Gradient(stops: [.init(color: material.light, location: 0),
                                        .init(color: material.base, location: 0.45),
                                        .init(color: material.shade, location: 1)])
        local.fill(path.applying(t.inverted()), with: .radialGradient(gradient, center: CGPoint(x: lx, y: ly), startRadius: 0, endRadius: 1.5))
    }

    // MARK: floor

    private static func drawFloor(_ ctx: inout GraphicsContext, floor: BabyFloor, view: Projector, L: Float, shadows: [ShadowShape]) {
        let facing = -view.vec(floor.normal).z                // the floor's baby side towards the viewer
        let alpha = Double(min(1, max(0, facing * 5)))
        guard alpha > 0 else { return }
        func transform(_ offset: Float) -> CGAffineTransform {
            let o = view.point(floor.origin + floor.normal * offset)
            let x = view.onScreen(floor.ex), y = view.onScreen(floor.ey)
            return CGAffineTransform(a: x.dx, b: x.dy, c: y.dx, d: y.dy, tx: o.x, ty: o.y)
        }
        let w = CGFloat(floor.size.x), h = CGFloat(floor.size.y), l = CGFloat(L)
        func outline(inset: CGFloat) -> Path {
            let rect = CGRect(x: -w / 2 + inset, y: -h / 2 + inset, width: w - 2 * inset, height: h - 2 * inset)
            return floor.round ? Path(ellipseIn: rect) : Path(roundedRect: rect, cornerRadius: max(0.05 * l, 0.5 * l - inset))
        }
        let onTop = transform(0)
        let top = outline(inset: 0).applying(onTop)

        var layer = ctx
        layer.opacity = alpha
        layer.drawLayer { g in
            g.fill(outline(inset: 0).applying(transform(-0.07 * L)), with: .color(BabyPalette.matEdge))
            g.fill(top, with: .color(BabyPalette.mat))
            // dots
            var dotsA = Path(), dotsB = Path()
            let step = 0.8 * l, r = 0.07 * l
            let n = Int((max(w, h) / 2 / step).rounded(.up)) + 1
            for iy in -n...n {
                for ix in -n...n {
                    let x = CGFloat(ix) * step + ((iy & 1) == 1 ? step / 2 : 0), y = CGFloat(iy) * step
                    guard abs(x) <= w / 2, abs(y) <= h / 2 else { continue }
                    let dot = CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)
                    if (ix + iy) & 1 == 0 { dotsA.addEllipse(in: dot) } else { dotsB.addEllipse(in: dot) }
                }
            }
            var inside = g
            inside.clip(to: top)
            inside.fill(dotsA.applying(onTop), with: .color(BabyPalette.dotA))
            inside.fill(dotsB.applying(onTop), with: .color(BabyPalette.dotB))
            // stitched border
            g.stroke(outline(inset: 0.15 * l).applying(onTop), with: .color(BabyPalette.stitch),
                     style: StrokeStyle(lineWidth: 1.3, lineCap: .round, dash: [4, 3.5]))
            // shadows: near the floor darker and sharper, lifted parts lighter and softer
            var near: [Path] = [], high: [Path] = []
            for shape in shadows {
                let (path, height) = shape.shadow(on: floor)
                if height < 0.45 * L { near.append(path) } else { high.append(path) }
            }
            for (paths, opacity, blur) in [(near, 0.24, 0.07), (high, 0.13, 0.17)] where !paths.isEmpty {
                var s = inside
                s.opacity = opacity
                s.addFilter(.blur(radius: CGFloat(blur * Double(L * view.scale))))
                s.drawLayer { shadowLayer in
                    for p in paths { shadowLayer.fill(p.applying(onTop), with: .color(BabyPalette.shadow)) }
                }
            }
        }
    }

    // MARK: decals

    /// A point on the head sphere at latitude/longitude (degrees; longitude towards the baby's left),
    /// with the surface's east and north directions there.
    private static func spot(_ c: SIMD3<Float>, _ R: Float, _ f: SIMD3<Float>, _ l: SIMD3<Float>, _ up: SIMD3<Float>,
                             lat: Float, lon: Float) -> (point: SIMD3<Float>, normal: SIMD3<Float>, east: SIMD3<Float>, north: SIMD3<Float>) {
        let la = lat * .pi / 180, lo = lon * .pi / 180
        let around = cos(lo) * f + sin(lo) * l
        let d = cos(la) * around + sin(la) * up
        let east = unit(-sin(lo) * f + cos(lo) * l)
        let north = unit(up * cos(la) - sin(la) * around)
        return (c + d * R, d, east, north)
    }

    /// How much of a surface feature with normal `d` faces the viewer (0 = edge-on or behind).
    private static func visibility(_ view: Projector, _ d: SIMD3<Float>) -> Double {
        Double(min(1, max(0, (-view.vec(d).z - 0.05) / 0.25)))
    }

    /// A unit direction on a surface patch whose image points towards the light.
    private static func towardLight(_ view: Projector, east: SIMD3<Float>, north: SIMD3<Float>) -> CGPoint? {
        let e = view.onScreen(east), n = view.onScreen(north)
        let det = e.dx * n.dy - e.dy * n.dx
        let unitScale = CGFloat(view.scale)
        guard abs(det) > 0.05 * unitScale * unitScale else { return nil }
        let hx = (screenLight.dx * n.dy - screenLight.dy * n.dx) / det
        let hy = (e.dx * screenLight.dy - e.dy * screenLight.dx) / det
        let k = (hx * hx + hy * hy).squareRoot()
        return k > 0 ? CGPoint(x: hx / k, y: hy / k) : nil
    }

    private static func drawFace(_ ctx: inout GraphicsContext, view: Projector, center c: SIMD3<Float>, R: Float,
                                 f: SIMD3<Float>, l: SIMD3<Float>, up: SIMD3<Float>, clip: Path) {
        var g = ctx
        g.clip(to: clip)
        let r = CGFloat(R)
        // cheeks
        for lon: Float in [48, -48] {
            let s = spot(c, R, f, l, up, lat: -30, lon: lon)
            let a = visibility(view, s.normal)
            guard a > 0 else { continue }
            var cheek = g
            cheek.concatenate(view.patch(at: s.point, east: s.east, north: s.north))
            cheek.scaleBy(x: 1, y: 0.72)
            cheek.fill(Path(ellipseIn: CGRect(x: -0.19 * r, y: -0.19 * r, width: 0.38 * r, height: 0.38 * r)),
                       with: .radialGradient(Gradient(colors: [BabyPalette.blush.opacity(0.55 * a), BabyPalette.blush.opacity(0)]),
                                             center: .zero, startRadius: 0, endRadius: 0.19 * r))
        }
        // eyes, with a highlight towards the light
        for lon: Float in [28, -28] {
            let s = spot(c, R, f, l, up, lat: -10, lon: lon)
            let a = visibility(view, s.normal)
            guard a > 0 else { continue }
            var eye = g
            eye.concatenate(view.patch(at: s.point, east: s.east, north: s.north))
            eye.fill(Path(ellipseIn: CGRect(x: -0.085 * r, y: -0.105 * r, width: 0.17 * r, height: 0.21 * r)),
                     with: .color(BabyPalette.ink.opacity(a)))
            if let h = towardLight(view, east: s.east, north: s.north) {
                let x = 0.03 * r * h.x, y = 0.045 * r * h.y, d = 0.03 * r
                eye.fill(Path(ellipseIn: CGRect(x: x - d, y: y - d, width: 2 * d, height: 2 * d)), with: .color(.white.opacity(0.95 * a)))
            }
        }
        let lineWidth = max(1.0, CGFloat(0.03 * R * view.scale))
        // ears: a little curl where each ear meets the head
        for lon: Float in [86, -86] {
            let s = spot(c, R, f, l, up, lat: -8, lon: lon)
            let a = visibility(view, s.normal)
            guard a > 0 else { continue }
            let k: CGFloat = lon > 0 ? 1 : -1
            var curl = Path()
            curl.move(to: CGPoint(x: -0.05 * r * k, y: 0.11 * r))
            curl.addCurve(to: CGPoint(x: -0.04 * r * k, y: -0.09 * r),
                          control1: CGPoint(x: 0.10 * r * k, y: 0.13 * r), control2: CGPoint(x: 0.10 * r * k, y: -0.11 * r))
            g.stroke(curl.applying(view.patch(at: s.point, east: s.east, north: s.north)),
                     with: .color(BabyPalette.skin.line.opacity(0.8 * a)), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        }
        // nose
        let nose = spot(c, R, f, l, up, lat: -22, lon: 0)
        let noseAlpha = visibility(view, nose.normal)
        if noseAlpha > 0 {
            var n = g
            n.concatenate(view.patch(at: nose.point, east: nose.east, north: nose.north))
            n.fill(Path(ellipseIn: CGRect(x: -0.05 * r, y: -0.035 * r, width: 0.1 * r, height: 0.07 * r)),
                   with: .color(BabyPalette.skin.shade.opacity(0.9 * noseAlpha)))
        }
        // a small smile
        let mouth = spot(c, R, f, l, up, lat: -38, lon: 0)
        let mouthAlpha = visibility(view, mouth.normal)
        if mouthAlpha > 0 {
            var smile = Path()
            smile.move(to: CGPoint(x: -0.10 * r, y: 0.035 * r))
            smile.addQuadCurve(to: CGPoint(x: 0.10 * r, y: 0.035 * r), control: CGPoint(x: 0, y: -0.07 * r))
            g.stroke(smile.applying(view.patch(at: mouth.point, east: mouth.east, north: mouth.north)),
                     with: .color(BabyPalette.mouth.opacity(mouthAlpha)),
                     style: StrokeStyle(lineWidth: max(1.2, CGFloat(0.035 * R * view.scale)), lineCap: .round))
        }
    }

    /// A little two-leaf sprout printed on the front of the romper.
    private static func drawSprout(_ ctx: inout GraphicsContext, view: Projector, spot: SIMD3<Float>, east: SIMD3<Float>,
                                   north: SIMD3<Float>, out: SIMD3<Float>, size: Float, clip: Path) {
        let a = visibility(view, out)
        guard a > 0 else { return }
        var g = ctx
        g.clip(to: clip)
        g.concatenate(view.patch(at: spot + out * size, east: east, north: north))
        let k = CGFloat(size * 0.32)
        let color = BabyPalette.sprout.opacity(0.9 * a)
        var stem = Path()
        stem.move(to: CGPoint(x: 0, y: -0.55 * k))
        stem.addQuadCurve(to: CGPoint(x: 0, y: 0.25 * k), control: CGPoint(x: 0.05 * k, y: -0.1 * k))
        g.stroke(stem, with: .color(color), style: StrokeStyle(lineWidth: 0.12 * k, lineCap: .round))
        for side: CGFloat in [1, -1] {
            var leaf = Path()
            leaf.move(to: CGPoint(x: 0, y: 0.2 * k))
            leaf.addQuadCurve(to: CGPoint(x: side * 0.65 * k, y: 0.6 * k), control: CGPoint(x: side * 0.15 * k, y: 0.75 * k))
            leaf.addQuadCurve(to: CGPoint(x: 0, y: 0.2 * k), control: CGPoint(x: side * 0.5 * k, y: 0.1 * k))
            g.fill(leaf, with: .color(color))
        }
    }

    /// One curl of hair on top of the head.
    private static func drawTuft(_ ctx: inout GraphicsContext, view: Projector, base: SIMD3<Float>, R: Float,
                                 f: SIMD3<Float>, up: SIMD3<Float>, outline: CGFloat) {
        let p1: SIMD3<Float> = base + up * (0.32 * R) - f * (0.10 * R)
        let p2: SIMD3<Float> = base + up * (0.42 * R) + f * (0.30 * R)
        let p3: SIMD3<Float> = base + up * (0.16 * R) + f * (0.26 * R)
        var curl = Path()
        curl.move(to: view.point(base))
        curl.addCurve(to: view.point(p3), control1: view.point(p1), control2: view.point(p2))
        let width = max(1.5, CGFloat(0.075 * R * view.scale))
        ctx.stroke(curl, with: .color(BabyPalette.hairLine), style: StrokeStyle(lineWidth: width + outline * 1.6, lineCap: .round))
        ctx.stroke(curl, with: .color(BabyPalette.hair), style: StrokeStyle(lineWidth: width, lineCap: .round))
    }
}

// MARK: - Building the parts

private enum Decal {
    case face(center: SIMD3<Float>, radius: Float, forward: SIMD3<Float>, left: SIMD3<Float>, up: SIMD3<Float>)
    case sprout(spot: SIMD3<Float>, east: SIMD3<Float>, north: SIMD3<Float>, out: SIMD3<Float>, size: Float)
    case tuft(base: SIMD3<Float>, radius: Float, forward: SIMD3<Float>, up: SIMD3<Float>)
    case legOpening(region: Path, thigh: Path)
}

private struct Part {
    var path: Path?
    var oval: Oval
    var material: BabyPalette.Material?
    /// View depth (larger = farther); parts are painted far to near.
    var depth: Float
    var decal: Decal?
    /// The limb this part belongs to (for the Activity card's glow).
    var limb: Limb?
    /// The limb piece it belongs to (for keeping hands steadily in front of or behind the head).
    var piece: LimbPiece?
    /// Depth used for painting when it differs from `depth` (a piece held in front of or behind the head).
    var sortDepth: Float?
}

/// The head, and the axis of each limb piece as drawn, for one frame. Shared by the figure and by the
/// head-order decision, so both see the same geometry.
private struct Anchors {
    let head: SIMD3<Float>
    /// Where the neck meets the skull: below the ears and a little behind them.
    let skullBase: SIMD3<Float>
    let R: Float
    let f: SIMD3<Float>, l: SIMD3<Float>, up: SIMD3<Float>
    var pieces: [LimbPiece: (SIMD3<Float>, SIMD3<Float>)] = [:]

    init(_ p: (Int) -> SIMD3<Float>, body: BodyAxes, L: Float) {
        let earL = p(MHR70.leftEar), earR = p(MHR70.rightEar), nose = p(MHR70.nose)
        let earMid = (earL + earR) / 2
        let headOK = [earL, earR, nose].allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
        l = headOK ? unit(earL - earR) : body.us
        var forward = headOK ? orthogonal(nose - earMid, to: l) : body.ws
        if simd_length(forward) < 0.5 { forward = orthogonal(body.ws, to: l) }
        f = forward
        up = simd_cross(f, l)
        R = 0.45 * L
        // A baby's ear canals sit low and towards the back of the head: more skull above and in front.
        let cranium: SIMD3<Float> = earMid + up * (0.22 * R) + f * (0.08 * R)
        head = headOK ? cranium : body.shoulders + body.v * (0.55 * L)
        let skull: SIMD3<Float> = earMid - up * (0.15 * R) - f * (0.20 * R)
        skullBase = headOK ? skull : head - up * (0.6 * R)

        for (limb, sh, el, wr, knuckle) in [(Limb.leftArm, MHR70.leftShoulder, MHR70.leftElbow, MHR70.leftWrist, MHR70.leftMiddleKnuckle),
                                            (Limb.rightArm, MHR70.rightShoulder, MHR70.rightElbow, MHR70.rightWrist, MHR70.rightMiddleKnuckle)] {
            let s = p(sh), e = p(el), w = p(wr)
            var hand = p(knuckle) - w
            if !(simd_length(hand) >= 0.05 * L) { hand = unit(w - e) * 0.3 * L }   // also when not finite
            pieces[.upper(limb)] = (s, e)
            pieces[.lower(limb)] = (e, w)
            pieces[.end(limb)] = (w + hand * 0.25, w + hand)
        }
        for (limb, hp, kn, an, heel, big, small) in [(Limb.leftLeg, MHR70.leftHip, MHR70.leftKnee, MHR70.leftAnkle, MHR70.leftHeel, MHR70.leftBigToe, MHR70.leftSmallToe),
                                                     (Limb.rightLeg, MHR70.rightHip, MHR70.rightKnee, MHR70.rightAnkle, MHR70.rightHeel, MHR70.rightBigToe, MHR70.rightSmallToe)] {
            let h = p(hp), k = p(kn), a = p(an)
            pieces[.upper(limb)] = (h, k)
            pieces[.lower(limb)] = (k, a)
            let heelEnd: SIMD3<Float> = p(heel) * Float(0.6) + a * Float(0.4)
            let toes: SIMD3<Float> = (p(big) + p(small)) * Float(0.5)
            pieces[.end(limb)] = (heelEnd, toes)
        }
    }
}

/// What casts a shadow on the floor.
private enum ShadowShape {
    case ball(SIMD3<Float>, Float)
    case capsule(SIMD3<Float>, SIMD3<Float>, Float, Float)
    case ellipsoid(SIMD3<Float>, [SIMD3<Float>])
    /// The convex hull of ellipsoids (the trunk).
    case hull([(center: SIMD3<Float>, axes: [SIMD3<Float>])])

    /// The shadow outline in floor coordinates, and the height of the part above the floor.
    func shadow(on floor: BabyFloor) -> (Path, Float) {
        switch self {
        case let .ball(c, r):
            let (q, h) = floor.shadow(c)
            let rr = CGFloat(r)
            return (Path(ellipseIn: CGRect(x: q.x - rr, y: q.y - rr, width: 2 * rr, height: 2 * rr)), h)
        case let .capsule(a, b, ra, rb):
            let (qa, ha) = floor.shadow(a), (qb, hb) = floor.shadow(b)
            return (capsulePath(qa, CGFloat(ra), qb, CGFloat(rb)), (ha + hb) / 2)
        case let .ellipsoid(c, axes):
            let (q, h) = floor.shadow(c)
            return (Oval(center: q, axes: axes.map { floor.shadow(vector: $0) }).path, h)
        case let .hull(parts):
            var points: [CGPoint] = []
            var height: Float = 0
            for part in parts {
                let (q, h) = floor.shadow(part.center)
                points += Oval(center: q, axes: part.axes.map { floor.shadow(vector: $0) }).points()
                height += h / Float(max(1, parts.count))
            }
            return (hullPath(points), height)
        }
    }
}

private struct FigureBuilder {
    let view: Projector
    let L: Float
    let shape: BodyShape
    var parts: [Part] = []
    var shadows: [ShadowShape] = []
    var headCenter: CGPoint = .zero
    var headRadius: CGFloat = 0
    var headDepth: Float?
    var trunkPath = Path()
    var trunkOval = Oval(center: .zero, angle: 0, a: 1, b: 1)

    init(view: Projector, shape: BodyShape) {
        self.view = view
        self.shape = shape
        L = shape.torso
    }

    private mutating func ellipsoid(_ c: SIMD3<Float>, _ axes: [SIMD3<Float>], _ m: BabyPalette.Material,
                                    shadow: Bool = true) -> Part {
        let oval = Oval(center: view.point(c), axes: axes.map { view.onScreen($0) })
        if shadow { shadows.append(.ellipsoid(c, axes)) }
        return Part(path: oval.path, oval: oval, material: m, depth: view.view(c).z)
    }

    private mutating func capsule(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ ra: Float, _ rb: Float, _ m: BabyPalette.Material,
                                  shadow: Bool = true) -> Part {
        let va = view.view(a), vb = view.view(b)
        let pa = view.screen(va), pb = view.screen(vb)
        let s = CGFloat(view.scale)
        let dx = pb.x - pa.x, dy = pb.y - pa.y
        let length = (dx * dx + dy * dy).squareRoot()
        let rmax = CGFloat(max(ra, rb)) * s
        let oval = Oval(center: CGPoint(x: (pa.x + pb.x) / 2, y: (pa.y + pb.y) / 2),
                        angle: length > 1e-6 ? atan2(dy, dx) : 0, a: max(length / 2 + rmax, rmax), b: rmax)
        if shadow { shadows.append(.capsule(a, b, ra, rb)) }
        return Part(path: capsulePath(pa, CGFloat(ra) * s, pb, CGFloat(rb) * s), oval: oval, material: m,
                    depth: (va.z + vb.z) / 2)
    }

    private mutating func ball(_ c: SIMD3<Float>, _ r: Float, _ m: BabyPalette.Material, shadow: Bool = true) -> Part {
        let v = view.view(c), p = view.screen(v)
        let rr = CGFloat(r * view.scale)
        if shadow { shadows.append(.ball(c, r)) }
        return Part(path: Path(ellipseIn: CGRect(x: p.x - rr, y: p.y - rr, width: 2 * rr, height: 2 * rr)),
                    oval: Oval(center: p, angle: 0, a: rr, b: rr), material: m, depth: v.z)
    }

    mutating func build(_ p: (Int) -> SIMD3<Float>, body: BodyAxes) {
        let H = body.hips, T = body.shoulders - body.hips, v = body.v
        let romper = BabyPalette.romper, skin = BabyPalette.skin

        // trunk: the convex hull of the shoulder girdle (its width from the shoulders, its top from the
        // acromions), a round tummy and the pelvis around the hip joints, each turned with its own line.
        // The arms leave it at the upper corners, the legs at the lower ones, as in a baby's skeleton.
        let shoulderWidth = shape.shoulders ?? 0.8 * L, hipWidth = shape.hips ?? 0.45 * L
        let acromL = p(MHR70.leftAcromion), acromR = p(MHR70.rightAcromion)
        let acromOK = [acromL, acromR].allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
        let acromionMid: SIMD3<Float> = (acromL + acromR) * 0.5
        let acromionFallback: SIMD3<Float> = body.shoulders + v * (0.03 * L)
        let acromion: SIMD3<Float> = acromOK ? acromionMid : acromionFallback
        let across = orthogonal(body.us + body.uh, to: v)
        let out = simd_cross(across, v)
        // (Split into small steps: one big literal of vector arithmetic is too slow for the type checker.)
        let girdleWidth: Float = max(0.46 * shoulderWidth, 0.28 * L)
        let tummyWidth: Float = max(0.44 * L, 0.5 * hipWidth + 0.10 * L)
        let pelvisWidth: Float = 0.5 * hipWidth + 0.13 * L
        let girdleCenter: SIMD3<Float> = acromion - v * (0.16 * L)
        let tummyForward: SIMD3<Float> = (body.ws + body.wh) * (0.015 * L)
        let tummyCenter: SIMD3<Float> = H + T * Float(0.45) + tummyForward
        let pelvisCenter: SIMD3<Float> = H - v * (0.03 * L)
        let girdleAxes: [SIMD3<Float>] = [body.us * girdleWidth, v * (0.18 * L), body.ws * (0.27 * L)]
        let tummyAxes: [SIMD3<Float>] = [across * tummyWidth, v * (0.42 * L), out * (0.36 * L)]
        let pelvisAxes: [SIMD3<Float>] = [body.uh * pelvisWidth, v * (0.17 * L), body.wh * (0.31 * L)]
        let blobs: [(center: SIMD3<Float>, axes: [SIMD3<Float>])] = [
            (center: girdleCenter, axes: girdleAxes),
            (center: tummyCenter, axes: tummyAxes),
            (center: pelvisCenter, axes: pelvisAxes),
        ]
        var trunkParts: [Part] = []
        for blob in blobs { trunkParts.append(ellipsoid(blob.center, blob.axes, romper, shadow: false)) }
        shadows.append(.hull(blobs))
        // shading frame: the ellipsoid closest to the whole trunk
        let shadingAxes: [SIMD3<Float>] = [across * (0.42 * L), v * (0.62 * L), out * (0.34 * L)]
        let shadingCenter: SIMD3<Float> = H + T * Float(0.42)
        trunkOval = Oval(center: view.point(shadingCenter), axes: shadingAxes.map { view.onScreen($0) })
        trunkPath = hullPath(trunkParts.flatMap { $0.oval.points() })
        parts.append(Part(path: trunkPath, oval: trunkOval, material: romper,
                          depth: trunkParts.map(\.depth).reduce(0, +) / Float(trunkParts.count),
                          decal: .sprout(spot: H + T * Float(0.50), east: across, north: v, out: out, size: 0.37 * L)))

        // head: a big sphere with the ears low and towards the back; a short, chubby neck from the base of
        // the neck to the base of the skull. Painted trunk, neck, head.
        let a = Anchors(p, body: body, L: L)
        let center = a.head, R = a.R, f = a.f, l = a.l, up = a.up
        let neckPoint = p(MHR70.neck)
        let neckBase = neckPoint.x.isFinite && neckPoint.y.isFinite && neckPoint.z.isFinite ? neckPoint : body.shoulders + v * 0.04 * L
        var neck = capsule(neckBase, a.skullBase, 0.17 * L, 0.16 * L, skin, shadow: false)
        var head = ball(center, R, skin)
        headCenter = head.oval.center
        headRadius = head.oval.a
        head.depth -= 0.08 * L                                   // drawn over the shoulders it touches
        headDepth = head.depth
        neck.depth = head.depth + 5e-4
        parts.append(neck)
        head.decal = .face(center: center, radius: R, forward: f, left: l, up: up)
        parts.append(head)
        for side: Float in [1, -1] {                             // ears peek out from behind the head
            var ear = ball(center + l * side * 0.95 * R - up * 0.08 * R, 0.22 * R, skin, shadow: false)
            ear.depth = head.depth + 1e-4
            parts.append(ear)
        }
        let tuftBase = center + up * 0.96 * R + f * 0.12 * R
        parts.append(Part(path: nil, oval: Oval(center: .zero, angle: 0, a: 1, b: 1), material: nil,
                          depth: view.view(tuftBase).z - 0.25 * R,
                          decal: .tuft(base: tuftBase, radius: R, forward: f, up: up)))

        // arms: short romper sleeves, mittens
        for (limb, colour) in [(Limb.leftArm, BabyPalette.left), (Limb.rightArm, BabyPalette.right)] {
            guard let upperAxis = a.pieces[.upper(limb)], let lowerAxis = a.pieces[.lower(limb)],
                  let endAxis = a.pieces[.end(limb)] else { continue }
            let (s, e) = upperAxis, (e2, w) = lowerAxis, (m0, m1) = endAxis
            var upper = capsule(s, e, 0.115 * L, 0.10 * L, skin)
            var sleeve = capsule(s, s + (e - s) * 0.42, 0.14 * L, 0.13 * L, romper, shadow: false)
            sleeve.depth = upper.depth - 1e-4
            var forearm = capsule(e2, w, 0.10 * L, 0.085 * L, skin)
            var mitten = capsule(m0, m1, 0.095 * L, 0.115 * L, colour)
            upper.piece = .upper(limb); sleeve.piece = .upper(limb); forearm.piece = .lower(limb); mitten.piece = .end(limb)
            for item in [upper, sleeve, forearm, mitten] {
                var part = item
                part.limb = limb
                parts.append(part)
            }
        }

        // legs: out of the romper a little below the hip joint, socks
        for (limb, colour) in [(Limb.leftLeg, BabyPalette.left), (Limb.rightLeg, BabyPalette.right)] {
            guard let upperAxis = a.pieces[.upper(limb)], let lowerAxis = a.pieces[.lower(limb)],
                  let endAxis = a.pieces[.end(limb)] else { continue }
            let (h, k) = upperAxis, (k2, ankle) = lowerAxis, (heel, toes) = endAxis
            var thigh = capsule(h, k, 0.165 * L, 0.13 * L, skin)
            // The romper's leg opening: where the thigh's root lies over the trunk, it is covered again
            // with romper, and the edge of the opening is drawn across the thigh.
            let hip = view.point(h), r = CGFloat(0.21 * L * view.scale)
            let region = trunkPath.intersection(Path(ellipseIn: CGRect(x: hip.x - r, y: hip.y - r, width: 2 * r, height: 2 * r)))
            var opening = Part(path: nil, oval: trunkOval, material: nil, depth: thigh.depth - 1e-4,
                               decal: thigh.path.map { Decal.legOpening(region: region, thigh: $0) })
            opening.piece = .upper(limb)
            var shin = capsule(k2, ankle, 0.13 * L, 0.10 * L, skin)
            var foot = capsule(heel, toes, 0.10 * L, 0.10 * L, colour)
            var cuff = ball(ankle, 0.11 * L, colour, shadow: false)
            cuff.depth = min(cuff.depth, foot.depth + 1e-4)
            thigh.piece = .upper(limb); shin.piece = .lower(limb); foot.piece = .end(limb); cuff.piece = .end(limb)
            for item in [thigh, opening, shin, foot, cuff] {
                var part = item
                part.limb = limb
                parts.append(part)
            }
        }
        // A part with a point the model did not give (not finite) is left out.
        parts.removeAll { !$0.depth.isFinite }
    }
}
