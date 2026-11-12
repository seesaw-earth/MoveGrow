// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
//
// Kinematics from InstantHMR's 3D keypoints: the review digest (timeline, body map, balance, ranges)
// and, through it, the Growth-tab summary. Body joints only — finger points are never used.
//
// Body frame, per frame: origin at the torso centroid (shoulders and hips), u towards the baby's LEFT,
// v cranial (hip midpoint → shoulder midpoint), w = u × v out of the chest. Lengths are in torso lengths
// (the recording's median shoulder-midpoint-to-hip-midpoint distance), so neither the camera's distance
// nor the baby's size changes the numbers. Unlike the 2D digest, nothing is projected: speeds include
// motion towards and away from the camera, angles are true 3D angles.
// Foundation only.

import Foundation

enum HMRKinematics {
    static let source = "instanthmr-3d"
    /// Wrists closer than this (torso lengths) count as hands together.
    static let handsTogetherGap = 0.3

    private typealias P = MHR70

    /// Per-frame axis vectors and positions are kept as three parallel [Double] arrays (x, y, z).
    private struct V3 {
        var x: [Double], y: [Double], z: [Double]
        init(_ n: Int) { x = [Double](repeating: .nan, count: n); y = x; z = x }
        subscript(_ i: Int) -> (Double, Double, Double) { (x[i], y[i], z[i]) }
    }

    static func digest(_ t: HMRTrack, lightOK: [Int64: Bool] = [:]) -> ReviewDigest? {
        let T = t.count
        guard T >= 4 else { return nil }
        var steps: [Double] = []
        for i in 1..<T {
            let d = t.times[i] - t.times[i - 1]
            if d.isFinite, d > 0 { steps.append(d) }
        }
        let dt = MM.nanMedian(steps)
        guard dt.isFinite, dt > 0 else { return nil }
        let fs = 1 / dt

        func point(_ i: Int, _ j: Int) -> (Double, Double, Double) {
            let p = t.point3D(i, j)
            return (Double(p.x), Double(p.y), Double(p.z))
        }

        // MARK: body frame

        var centroid = V3(T), uRaw = V3(T), vRaw = V3(T)
        var lengthRaw = [Double](repeating: .nan, count: T)
        var valid = [Bool](repeating: false, count: T)
        for i in 0..<T where t.valid[i] && (lightOK[AnalysisPlan.timeKey(t.times[i])] ?? true) {
            let ls = point(i, P.leftShoulder), rs = point(i, P.rightShoulder)
            let lh = point(i, P.leftHip), rh = point(i, P.rightHip)
            let all = [ls.0, ls.1, ls.2, rs.0, rs.1, rs.2, lh.0, lh.1, lh.2, rh.0, rh.1, rh.2]
            guard all.allSatisfy({ $0.isFinite }) else { continue }
            centroid.x[i] = (ls.0 + rs.0 + lh.0 + rh.0) / 4
            centroid.y[i] = (ls.1 + rs.1 + lh.1 + rh.1) / 4
            centroid.z[i] = (ls.2 + rs.2 + lh.2 + rh.2) / 4
            let v = ((ls.0 + rs.0 - lh.0 - rh.0) / 2, (ls.1 + rs.1 - lh.1 - rh.1) / 2, (ls.2 + rs.2 - lh.2 - rh.2) / 2)
            let len = norm(v)
            guard len > 1e-4 else { continue }
            lengthRaw[i] = len
            vRaw.x[i] = v.0; vRaw.y[i] = v.1; vRaw.z[i] = v.2
            uRaw.x[i] = (ls.0 - rs.0) + (lh.0 - rh.0)
            uRaw.y[i] = (ls.1 - rs.1) + (lh.1 - rh.1)
            uRaw.z[i] = (ls.2 - rs.2) + (lh.2 - rh.2)
            valid[i] = true
        }
        let validCount = valid.filter { $0 }.count
        guard validCount >= 4 else { return nil }
        let L = MM.nanMedian(lengthRaw)
        guard L.isFinite, L > 1e-4 else { return nil }

        // Axes smoothed over 0.5 s (the trunk turns slowly; this keeps limb speeds free of axis jitter).
        let axisWin = max(1, MM.pyRound(0.5 * fs))
        func smooth3(_ a: V3, _ win: Int) -> V3 {
            var o = a
            o.x = MM.movingAverage(a.x, win); o.y = MM.movingAverage(a.y, win); o.z = MM.movingAverage(a.z, win)
            return o
        }
        let us = smooth3(uRaw, axisWin), vs = smooth3(vRaw, axisWin)
        var U = V3(T), Vc = V3(T), W = V3(T)
        for i in 0..<T where valid[i] {
            var v = vs[i]
            if !(v.0.isFinite && v.1.isFinite && v.2.isFinite) { v = vRaw[i] }
            var u = us[i]
            if !(u.0.isFinite && u.1.isFinite && u.2.isFinite) { u = uRaw[i] }
            let vn = normalize(v)
            // u orthogonal to v (Gram–Schmidt), then w = u × v.
            let d = dot(u, vn)
            let un = normalize((u.0 - d * vn.0, u.1 - d * vn.1, u.2 - d * vn.2))
            let wn = cross(un, vn)
            guard [un.0, un.1, un.2, vn.0, vn.1, vn.2].allSatisfy({ $0.isFinite }) else { valid[i] = false; continue }
            U.x[i] = un.0; U.y[i] = un.1; U.z[i] = un.2
            Vc.x[i] = vn.0; Vc.y[i] = vn.1; Vc.z[i] = vn.2
            W.x[i] = wn.0; W.y[i] = wn.1; W.z[i] = wn.2
        }

        /// Joint j in body coordinates (torso lengths).
        func body(_ j: Int) -> V3 {
            var o = V3(T)
            for i in 0..<T where valid[i] {
                let p = point(i, j)
                let r = (p.0 - centroid.x[i], p.1 - centroid.y[i], p.2 - centroid.z[i])
                o.x[i] = dot(r, U[i]) / L
                o.y[i] = dot(r, Vc[i]) / L
                o.z[i] = dot(r, W[i]) / L
            }
            return o
        }

        // MARK: speeds and activity (same units and thresholds as the 2D digest)

        let speedWin = max(1, MM.pyRound(0.10 * fs))
        func speedOf(_ b: V3) -> [Double] {
            let s = smooth3(b, speedWin)
            let gx = MM.gradient(s.x, dt), gy = MM.gradient(s.y, dt), gz = MM.gradient(s.z, dt)
            return (0..<T).map { (gx[$0] * gx[$0] + gy[$0] * gy[$0] + gz[$0] * gz[$0]).squareRoot() }
        }
        let distal: [MotorChannel: Int] = [.L_arm: P.leftWrist, .R_arm: P.rightWrist, .L_leg: P.leftAnkle, .R_leg: P.rightAnkle]
        var bodyOf: [Int: V3] = [:]
        for j in [P.leftWrist, P.rightWrist, P.leftAnkle, P.rightAnkle, P.leftShoulder, P.rightShoulder, P.leftHip, P.rightHip] {
            bodyOf[j] = body(j)
        }
        var limbSpeed: [MotorChannel: [Double]] = [:]
        for (ch, j) in distal { limbSpeed[ch] = speedOf(bodyOf[j]!) }
        var ref: [Double] = []
        for j in [P.leftShoulder, P.rightShoulder, P.leftHip, P.rightHip] { ref += speedOf(bodyOf[j]!) }
        let noise = MM.nanMedian(ref)
        let on = max(0.18, 3.0 * (noise.isFinite ? noise : 0)), off = max(0.10, 2.0 * (noise.isFinite ? noise : 0))

        // MARK: angles, head, lift, hands

        let postureWin = max(1, MM.pyRound(0.2 * fs))
        func jointAngle(_ a: Int, _ b: Int, _ c: Int) -> [Double] {
            let raw: [Double] = (0..<T).map { i in
                guard valid[i] else { return .nan }
                let pa = point(i, a), pb = point(i, b), pc = point(i, c)
                let v1 = (pa.0 - pb.0, pa.1 - pb.1, pa.2 - pb.2), v2 = (pc.0 - pb.0, pc.1 - pb.1, pc.2 - pb.2)
                let nn = norm(v1) * norm(v2)
                guard nn > 1e-9 else { return .nan }
                return MM.degrees(acos(MM.clip(dot(v1, v2) / nn, -1, 1)))
            }
            return MM.movingAverage(raw, postureWin)
        }
        let angles: [String: [Double]] = [
            "elbow_L": jointAngle(P.leftShoulder, P.leftElbow, P.leftWrist),
            "elbow_R": jointAngle(P.rightShoulder, P.rightElbow, P.rightWrist),
            "knee_L": jointAngle(P.leftHip, P.leftKnee, P.leftAnkle),
            "knee_R": jointAngle(P.rightHip, P.rightKnee, P.rightAnkle),
        ]
        let hips: [String: [Double]] = [
            "hip_L": jointAngle(P.leftShoulder, P.leftHip, P.leftKnee),
            "hip_R": jointAngle(P.rightShoulder, P.rightHip, P.rightKnee),
        ]

        // Head direction relative to the trunk: nose minus ear midpoint, in the (u, w) plane.
        // sin(yaw) > 0: face turned to the baby's left (as in the 2D digest).
        let headRaw: [Double] = (0..<T).map { i in
            guard valid[i] else { return .nan }
            let nz = point(i, P.nose), le = point(i, P.leftEar), re = point(i, P.rightEar)
            let h = (nz.0 - (le.0 + re.0) / 2, nz.1 - (le.1 + re.1) / 2, nz.2 - (le.2 + re.2) / 2)
            let hu = dot(h, U[i]), hw = dot(h, W[i])
            let r = (hu * hu + hw * hw).squareRoot()
            return r > 1e-6 ? hu / r : .nan
        }
        let headYaw = MM.movingAverage(headRaw, postureWin)

        // Height of each hand and foot in front of the torso plane (w), torso lengths. Lying on the back,
        // this is how far the limb is lifted towards the camera / away from the mattress.
        var lift: [MotorChannel: [Double]] = [:]
        for (ch, j) in distal { lift[ch] = MM.movingAverage(bodyOf[j]!.z, postureWin) }

        let lw = bodyOf[P.leftWrist]!, rw = bodyOf[P.rightWrist]!
        let handGap = MM.movingAverage((0..<T).map { i in
            let d = (lw.x[i] - rw.x[i], lw.y[i] - rw.y[i], lw.z[i] - rw.z[i])
            return norm(d)
        }, postureWin)

        // MARK: binning (as MotorDigestBuilder)

        let duration = max(Double(T) / fs, (t.times.last ?? 0) - (t.times.first ?? 0))
        let framesPerBin = max(1, Int((max(0.25, duration / Double(MotorDigestBuilder.maxBins)) * fs).rounded()))
        let bin = Double(framesPerBin) / fs
        let n = max(1, (T + framesPerBin - 1) / framesPerBin)

        func binnedMean(_ x: [Double], minShare: Double = 0.5) -> [Float] {
            (0..<n).map { b in
                let lo = b * framesPerBin, hi = min(T, lo + framesPerBin)
                var sum = 0.0, k = 0
                for i in lo..<hi where x[i].isFinite { sum += x[i]; k += 1 }
                return Double(k) >= minShare * Double(hi - lo) && k > 0 ? Float(sum / Double(k)) : .nan
            }
        }
        func binnedShare(_ flag: [Bool], of base: [Bool]) -> [Float] {
            (0..<n).map { b in
                let lo = b * framesPerBin, hi = min(T, lo + framesPerBin)
                var k = 0, m = 0
                for i in lo..<hi where base[i] { m += 1; if flag[i] { k += 1 } }
                return m > 0 ? Float(Double(k) / Double(m)) : .nan
            }
        }
        let coverage: [Float] = (0..<n).map { b in
            let lo = b * framesPerBin, hi = min(T, lo + framesPerBin)
            return Float(Double((lo..<hi).filter { valid[$0] }.count) / Double(max(1, hi - lo)))
        }

        var speed: [String: PackedSeries] = [:], active: [String: PackedSeries] = [:]
        var activeFraction: [String: Double] = [:]
        var perMinute: [MotorChannel: Double] = [:]
        for ch in MotorChannel.allCases {
            guard let v = limbSpeed[ch], v.count == T else { continue }
            let finite = v.map { $0.isFinite }
            let act = MotorEvents.hysteresis(v, on: on, off: off)
            speed[ch.rawValue] = PackedSeries(binnedMean(v))
            active[ch.rawValue] = PackedSeries(binnedShare(act, of: finite))
            let observed = finite.filter { $0 }.count
            if observed > 0 {
                activeFraction[ch.rawValue] = Double((0..<T).filter { finite[$0] && act[$0] }.count) / Double(observed)
                perMinute[ch] = MM.nanSum(v) / fs / (Double(observed) / fs / 60)
            }
        }
        func balance(_ l: MotorChannel, _ r: MotorChannel) -> Double? {
            guard let a = perMinute[l], let b = perMinute[r], a + b > 0 else { return nil }
            return (a - b) / (a + b)
        }

        var angle: [String: PackedSeries] = [:], angleRange: [String: [Double]] = [:]
        for (key, v) in angles {
            angle[key] = PackedSeries(binnedMean(v))
            if let r = range(v) { angleRange[key] = r }
        }
        var hip: [String: PackedSeries] = [:], hipRange: [String: [Double]] = [:]
        for (key, v) in hips {
            hip[key] = PackedSeries(binnedMean(v))
            if let r = range(v) { hipRange[key] = r }
        }

        var turn = [0.0, 0.0, 0.0]
        for y in headYaw where y.isFinite { turn[y > 0.25 ? 0 : (y < -0.25 ? 2 : 1)] += 1 }
        let turnTotal = turn.reduce(0, +)

        let motionFrames: [Double] = (0..<T).map { i in
            var sum = 0.0, k = 0
            for ch in MotorChannel.allCases { if let v = limbSpeed[ch]?[i], v.isFinite { sum += v; k += 1 } }
            return k >= 2 ? sum / Double(k) : .nan
        }
        func smoothBins(_ x: [Float], _ k: Int) -> [Double] {
            let h = k / 2
            return (0..<x.count).map { i in
                var sum = 0.0, m = 0
                for j in max(0, i - h)...min(x.count - 1, i + h) where x[j].isFinite { sum += Double(x[j]); m += 1 }
                return m > 0 ? sum / Double(m) : .nan
            }
        }
        let kBins = max(1, Int((1.5 / bin).rounded()))
        func balanceSeries(_ l: MotorChannel, _ r: MotorChannel) -> PackedSeries {
            guard let a = speed[l.rawValue]?.values, let b = speed[r.rawValue]?.values else {
                return PackedSeries([Float](repeating: .nan, count: n))
            }
            let sa = smoothBins(a, kBins), sb = smoothBins(b, kBins)
            return PackedSeries((0..<n).map { i in
                let x = sa[i], y = sb[i]
                guard x.isFinite, y.isFinite, x + y > 0.05 else { return .nan }
                return Float((x - y) / (x + y))
            })
        }
        let binnedSpeeds = speed.values.flatMap { $0.values.map(Double.init) }
        let scale = MM.nanPercentile(binnedSpeeds, 95)

        // MARK: coordination over ~2 s windows

        let half = max(2, MM.pyRound(1.0 * fs))
        /// Pearson correlation of two series over frames lo..<hi (finite pairs only).
        func correlation(_ a: [Double], _ b: [Double], _ lo: Int, _ hi: Int, minStd: Double) -> Double {
            var xs: [Double] = [], ys: [Double] = []
            for i in lo..<hi where a[i].isFinite && b[i].isFinite { xs.append(a[i]); ys.append(b[i]) }
            guard xs.count >= max(8, (hi - lo) / 2) else { return .nan }
            let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
            var sxy = 0.0, sxx = 0.0, syy = 0.0
            for k in 0..<xs.count {
                let dx = xs[k] - mx, dy = ys[k] - my
                sxy += dx * dy; sxx += dx * dx; syy += dy * dy
            }
            let sx = (sxx / Double(xs.count)).squareRoot(), sy = (syy / Double(ys.count)).squareRoot()
            guard sx >= minStd, sy >= minStd else { return .nan }
            return sxy / (sxx * syy).squareRoot()
        }
        func window(_ b: Int) -> (Int, Int) {
            let c = b * framesPerBin + framesPerBin / 2
            return (max(0, c - half), min(T, c + half + 1))
        }
        // Left and right knees: +1 the legs bend and stretch together, −1 they alternate.
        let kneeVelL = MM.gradient(angles["knee_L"] ?? [], dt), kneeVelR = MM.gradient(angles["knee_R"] ?? [], dt)
        let legPhase: [Float] = (0..<n).map { b in
            guard kneeVelL.count == T, kneeVelR.count == T else { return .nan }
            let (lo, hi) = window(b)
            let r = correlation(kneeVelL, kneeVelR, lo, hi, minStd: 15)       // ≥ 15°/s: the legs are moving
            return r.isFinite ? Float(r) : .nan
        }
        // Four limb speeds: mean pairwise correlation (1 = all limbs speed up and slow down together).
        let channels = MotorChannel.allCases.compactMap { limbSpeed[$0] }
        let sync: [Float] = (0..<n).map { b in
            let (lo, hi) = window(b)
            guard channels.count == 4 else { return .nan }
            let moving = (lo..<hi).filter { motionFrames[$0].isFinite && motionFrames[$0] > on }.count
            guard moving >= (hi - lo) / 4 else { return .nan }
            var sum = 0.0, k = 0
            for a in 0..<4 {
                for c in (a + 1)..<4 {
                    let r = correlation(channels[a], channels[c], lo, hi, minStd: 0.02)
                    if r.isFinite { sum += r; k += 1 }
                }
            }
            return k >= 3 ? Float(sum / Double(k)) : .nan
        }

        var liftSeries: [String: PackedSeries] = [:], liftP90: [String: Double] = [:]
        for (ch, v) in lift {
            liftSeries[ch.rawValue] = PackedSeries(binnedMean(v))
            let p = MM.nanPercentile(v, 90)
            if p.isFinite { liftP90[ch.rawValue] = p }
        }
        let gapFinite = handGap.filter { $0.isFinite }
        let together = gapFinite.isEmpty ? nil : Double(gapFinite.filter { $0 < handsTogetherGap }.count) / Double(gapFinite.count)

        var out = ReviewDigest(start: t.times.first ?? 0, bin: bin, count: n, analysisFPS: fs,
                                  coverage: PackedSeries(coverage), speed: speed, active: active, angle: angle,
                                  headYaw: PackedSeries(binnedMean(headYaw)), motion: PackedSeries(binnedMean(motionFrames)),
                                  armBalanceSeries: balanceSeries(.L_arm, .R_arm), legBalanceSeries: balanceSeries(.L_leg, .R_leg),
                                  activeFraction: activeFraction, angleRange: angleRange,
                                  armBalance: balance(.L_arm, .R_arm), legBalance: balance(.L_leg, .R_leg),
                                  trackedFraction: Double(validCount) / Double(T),
                                  headTurn: turnTotal > 0 ? turn.map { $0 / turnTotal } : [0, 0, 0],
                                  speedScale: scale.isFinite ? max(0.3, scale) : 1)
        out.source = source
        out.hip = hip
        out.hipRange = hipRange
        out.lift = liftSeries
        out.liftP90 = liftP90
        out.handGap = PackedSeries(binnedMean(handGap))
        out.handsTogether = together
        out.legPhase = PackedSeries(legPhase)
        out.legPhaseMean = mean(legPhase)
        out.sync = PackedSeries(sync)
        out.syncMean = mean(sync)
        return out
    }

    // MARK: small vector helpers

    private static func dot(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
        a.0 * b.0 + a.1 * b.1 + a.2 * b.2
    }

    private static func norm(_ a: (Double, Double, Double)) -> Double { dot(a, a).squareRoot() }

    private static func normalize(_ a: (Double, Double, Double)) -> (Double, Double, Double) {
        let n = norm(a)
        return n > 1e-12 ? (a.0 / n, a.1 / n, a.2 / n) : (.nan, .nan, .nan)
    }

    private static func cross(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> (Double, Double, Double) {
        (a.1 * b.2 - a.2 * b.1, a.2 * b.0 - a.0 * b.2, a.0 * b.1 - a.1 * b.0)
    }

    /// 5th and 95th percentile, when there is data.
    private static func range(_ v: [Double]) -> [Double]? {
        let lo = MM.nanPercentile(v, 5), hi = MM.nanPercentile(v, 95)
        return lo.isFinite && hi.isFinite ? [lo, hi] : nil
    }

    private static func mean(_ v: [Float]) -> Double? {
        let f = v.filter { $0.isFinite }
        return f.isEmpty ? nil : Double(f.reduce(0, +)) / Double(f.count)
    }
}
