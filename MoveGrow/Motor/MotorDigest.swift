// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
//
// Review digest: the compact time series behind the review screen (timeline lanes, body map,
// balance, range of motion, movement curve). Computed once per analysis pass and stored as
// `<id>.review.json` (series packed as Float32), so opening a memory never re-processes the track.
// Videos analysed with InstantHMR get it from the 3D track (InstantHMR/HMRKinematics.swift), which
// also fills the 3D-only fields; YOLO videos get it here from the 2D track, with the same smoothed
// series, body frame, limb speeds and activity thresholds as the rule engine.

import Foundation

/// Float series stored as little-endian Float32 (base64 in JSON). NaN = no data.
struct PackedSeries: Codable, Hashable {
    var values: [Float]

    init(_ values: [Float]) { self.values = values }

    init(from decoder: Decoder) throws {
        let data = try decoder.singleValueContainer().decode(Data.self)
        values = data.withUnsafeBytes { raw in
            (0..<(raw.count / 4)).map { i in
                Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)))
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var data = Data(capacity: values.count * 4)
        for v in values {
            var le = v.bitPattern.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        var c = encoder.singleValueContainer()
        try c.encode(data)
    }

    var count: Int { values.count }
    subscript(i: Int) -> Float { i >= 0 && i < values.count ? values[i] : .nan }
}

struct ReviewDigest: Codable, Hashable {
    static let currentVersion = 3
    static let angleKeys = ["elbow_L", "elbow_R", "knee_L", "knee_R"]

    var version = ReviewDigest.currentVersion
    /// Time of the first bin's start and the bin length (seconds).
    var start: Double
    var bin: Double
    var count: Int
    var analysisFPS: Double
    /// Fraction (0…1) of frames per bin with a usable body pose and acceptable light.
    var coverage: PackedSeries
    /// Distal speed (wrist / ankle, body frame), torso lengths per second; keys = MotorChannel raw values.
    var speed: [String: PackedSeries]
    /// Fraction (0…1) of frames per bin above the rule engine's activity threshold.
    var active: [String: PackedSeries]
    /// Elbow and knee angles in degrees (180 = straight).
    var angle: [String: PackedSeries]
    /// sin(head yaw): > 0 face turned to the baby's left, < 0 to the right.
    var headYaw: PackedSeries
    /// Mean of the four distal speeds (quantity of motion).
    var motion: PackedSeries
    /// Per-bin (left − right) / (left + right) of distal speed over a ~1.5 s window; > 0 left moved more.
    var armBalanceSeries: PackedSeries
    var legBalanceSeries: PackedSeries
    var activeFraction: [String: Double]
    /// 5th and 95th percentile angle over the recording.
    var angleRange: [String: [Double]]
    /// (left − right) / (left + right) of movement per minute; > 0 left moved more.
    var armBalance: Double?
    var legBalance: Double?
    var trackedFraction: Double
    /// Head direction share of tracked time: [left, middle, right].
    var headTurn: [Double]
    /// 95th percentile of binned limb speed, for colour scaling across lanes.
    var speedScale: Double

    // 3D only (InstantHMR); nil for videos analysed in 2D.
    /// "instanthmr-3d" when made from the 3D track.
    var source: String? = nil
    /// Hip angle in degrees (shoulder–hip–knee; 180 = thigh in line with the trunk), keys hip_L / hip_R.
    var hip: [String: PackedSeries]? = nil
    /// 5th and 95th percentile hip angle over the recording.
    var hipRange: [String: [Double]]? = nil
    /// Hand / foot height in front of the torso plane (towards the camera when lying on the back),
    /// torso lengths; keys = MotorChannel raw values.
    var lift: [String: PackedSeries]? = nil
    /// 90th percentile of that height per limb.
    var liftP90: [String: Double]? = nil
    /// Distance between the wrists, torso lengths.
    var handGap: PackedSeries? = nil
    /// Share of tracked time with the wrists closer than 0.3 torso lengths.
    var handsTogether: Double? = nil
    /// Correlation of left and right knee motion over ~2 s: +1 the legs move together, −1 they alternate.
    var legPhase: PackedSeries? = nil
    var legPhaseMean: Double? = nil
    /// Mean correlation of the four limb speeds over ~2 s: near 1, all limbs speed up and slow down together.
    var sync: PackedSeries? = nil
    var syncMean: Double? = nil

    var is3D: Bool { hip != nil }

    func time(ofBin i: Int) -> Double { start + (Double(i) + 0.5) * bin }
    func bin(at t: Double) -> Int? {
        let i = Int(((t - start) / bin).rounded(.down))
        return i >= 0 && i < count ? i : nil
    }
    var end: Double { start + Double(count) * bin }
}

enum MotorDigestBuilder {
    /// At most this many bins per recording (bins never shorter than 0.25 s).
    static let maxBins = 600

    static func make(track: PoseTrack, aspect: Double?) -> ReviewDigest? {
        guard let s = MotorSeries(track: track, aspect: aspect) else { return nil }
        // Same preprocessing as the rule engine's smoothed branch (MotorEngine.Env).
        var smooth = s
        let win = max(1, MM.pyRound(0.2 * s.fs))
        smooth.x = s.x.map { MM.movingAverage($0, win) }
        smooth.y = s.y.map { MM.movingAverage($0, win) }
        let bf = MotorBodyFrame(smooth)
        let sp = MotorEvents.limbSpeeds(smooth, bf)
        let posture = MotorPosture.features(bf)
        let on = max(0.18, 3.0 * sp.noise), off = max(0.10, 2.0 * sp.noise)

        let T = s.count
        guard T > 0, s.fs.isFinite, s.fs > 0 else { return nil }
        let valid = (0..<T).map { bf.valid[$0] && s.lightOK[$0] }
        let framesPerBin = max(1, Int((max(0.25, s.duration / Double(maxBins)) * s.fs).rounded()))
        let bin = Double(framesPerBin) / s.fs
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
            let v = sp.limbs[ch] ?? []
            guard v.count == T else { continue }
            let finite = v.map { $0.isFinite }
            let act = MotorEvents.hysteresis(v, on: on, off: off)
            speed[ch.rawValue] = PackedSeries(binnedMean(v))
            active[ch.rawValue] = PackedSeries(binnedShare(act, of: finite))
            let observed = finite.filter { $0 }.count
            if observed > 0 {
                activeFraction[ch.rawValue] = Double((0..<T).filter { finite[$0] && act[$0] }.count) / Double(observed)
                perMinute[ch] = MM.nanSum(v) / s.fs / (Double(observed) / s.fs / 60)
            }
        }
        func balance(_ l: MotorChannel, _ r: MotorChannel) -> Double? {
            guard let a = perMinute[l], let b = perMinute[r], a + b > 0 else { return nil }
            return (a - b) / (a + b)
        }

        var angle: [String: PackedSeries] = [:], angleRange: [String: [Double]] = [:]
        for key in ReviewDigest.angleKeys {
            let parts = key.split(separator: "_")
            guard parts.count == 2, let v = posture["\(parts[0])_angle_\(parts[1])"], v.count == T else { continue }
            angle[key] = PackedSeries(binnedMean(v))
            let lo = MM.nanPercentile(v, 5), hi = MM.nanPercentile(v, 95)
            if lo.isFinite, hi.isFinite { angleRange[key] = [lo, hi] }
        }

        let yaw = posture["head_yaw_sin"] ?? [Double](repeating: .nan, count: T)
        var turn = [0.0, 0.0, 0.0]
        for y in yaw where y.isFinite { turn[y > 0.25 ? 0 : (y < -0.25 ? 2 : 1)] += 1 }
        let turnTotal = turn.reduce(0, +)

        let motionFrames: [Double] = (0..<T).map { i in
            var sum = 0.0, k = 0
            for ch in MotorChannel.allCases { if let v = sp.limbs[ch]?[i], v.isFinite { sum += v; k += 1 } }
            return k >= 2 ? sum / Double(k) : .nan
        }
        /// NaN-aware centred moving mean over `k` bins.
        func smoothBins(_ x: [Float], _ k: Int) -> [Double] {
            let h = k / 2
            return (0..<x.count).map { i in
                var sum = 0.0, m = 0
                for j in max(0, i - h)...min(x.count - 1, i + h) where x[j].isFinite { sum += Double(x[j]); m += 1 }
                return m > 0 ? sum / Double(m) : .nan
            }
        }
        let k = max(1, Int((1.5 / bin).rounded()))
        func balanceSeries(_ l: MotorChannel, _ r: MotorChannel) -> PackedSeries {
            guard let a = speed[l.rawValue]?.values, let b = speed[r.rawValue]?.values else {
                return PackedSeries([Float](repeating: .nan, count: n))
            }
            let sa = smoothBins(a, k), sb = smoothBins(b, k)
            return PackedSeries((0..<n).map { i in
                let x = sa[i], y = sb[i]
                guard x.isFinite, y.isFinite, x + y > 0.05 else { return .nan }
                return Float((x - y) / (x + y))
            })
        }
        let binnedSpeeds = speed.values.flatMap { $0.values.map(Double.init) }
        let scale = MM.nanPercentile(binnedSpeeds, 95)

        return ReviewDigest(start: s.t.first ?? 0, bin: bin, count: n, analysisFPS: s.fs,
                            coverage: PackedSeries(coverage), speed: speed, active: active, angle: angle,
                            headYaw: PackedSeries(binnedMean(yaw)), motion: PackedSeries(binnedMean(motionFrames)),
                            armBalanceSeries: balanceSeries(.L_arm, .R_arm), legBalanceSeries: balanceSeries(.L_leg, .R_leg),
                            activeFraction: activeFraction, angleRange: angleRange,
                            armBalance: balance(.L_arm, .R_arm), legBalance: balance(.L_leg, .R_leg),
                            trackedFraction: Double(valid.filter { $0 }.count) / Double(T),
                            headTurn: turnTotal > 0 ? turn.map { $0 / turnTotal } : [0, 0, 0],
                            speedScale: scale.isFinite ? max(0.3, scale) : 1)
    }
}

/// One recording's kinematics in a few numbers, kept in the album index so the Growth tab can
/// chart changes across videos and days without opening any file.
struct SessionKinematics: Codable, Hashable {
    static let currentVersion = 2
    var version = SessionKinematics.currentVersion
    /// Share of observed time each limb was moving (MotorChannel raw value → 0…1).
    var activeFraction: [String: Double]
    /// Median distal speed per limb, torso lengths per second.
    var medianSpeed: [String: Double]
    /// Elbow / knee angle, 5th and 95th percentile (degrees).
    var angleRange: [String: [Double]]
    var armBalance: Double?
    var legBalance: Double?
    /// Median overall movement (mean of the four limb speeds).
    var motionMedian: Double?
    var trackedFraction: Double
    /// Head direction share of tracked time: [left, middle, right].
    var headTurn: [Double]
    var analysisFPS: Double
    // 3D only (InstantHMR), see ReviewDigest.
    var source: String? = nil
    var hipRange: [String: [Double]]? = nil
    var liftP90: [String: Double]? = nil
    var handsTogether: Double? = nil
    var legPhase: Double? = nil
    var sync: Double? = nil
}

extension ReviewDigest {
    var session: SessionKinematics {
        func median(_ p: PackedSeries) -> Double? {
            let v = MM.nanMedian(p.values.map(Double.init))
            return v.isFinite ? v : nil
        }
        var speeds: [String: Double] = [:]
        for (k, p) in speed { if let m = median(p) { speeds[k] = m } }
        var k = SessionKinematics(activeFraction: activeFraction, medianSpeed: speeds, angleRange: angleRange,
                                  armBalance: armBalance, legBalance: legBalance, motionMedian: median(motion),
                                  trackedFraction: trackedFraction, headTurn: headTurn, analysisFPS: analysisFPS)
        k.source = source
        k.hipRange = hipRange
        k.liftP90 = liftP90
        k.handsTogether = handsTogether
        k.legPhase = legPhaseMean
        k.sync = syncMean
        return k
    }
}

/// Display helpers shared by the review timeline and the MP4 export.
enum SeriesMath {
    /// NaN-aware centred moving mean over `k` bins (a bin with no data stays empty).
    static func smooth(_ x: [Float], _ k: Int) -> [Float] {
        guard k > 1 else { return x }
        let h = k / 2
        return (0..<x.count).map { i in
            guard x[i].isFinite else { return .nan }
            var sum: Float = 0, m: Float = 0
            for j in max(0, i - h)...min(x.count - 1, i + h) where x[j].isFinite { sum += x[j]; m += 1 }
            return sum / m
        }
    }

    /// "Nice" tick spacing for about five labels.
    static func tickStep(_ duration: Double) -> Double {
        let steps: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        return steps.first { duration / $0 <= 6 } ?? 600
    }
}
