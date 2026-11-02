// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
//
// Speed-based descriptors: activity bouts, left/right use, brief synchronous bursts (reference: events.py).

import Foundation

struct LimbActivity: Codable, Equatable {
    var observedS: Double
    var nBouts: Int
    var boutsPerMin: Double
    var activeFrac: Double
    var pathPerMin: Double
    var medianSpeed: Double
    var meanConf: Double
    var kicksPerMin: Double?
}

struct ActivitySummary {
    var limbs: [MotorChannel: LimbActivity]
    var session: [String: Double]     // arm_asym_index, arm_abs_asym_index, ...
    var armLessSide: String
    var legLessSide: String
}

struct BurstEvent {
    var t0: Double, t1: Double, durS: Double, peakSpeed: Double, preLevel: Double
    var bilateralPair: Bool, axialDev: Double, sudden: Bool, limbs: [MotorChannel]
}

struct BurstCluster {
    var nEvents: Int, t0: Double, t1: Double, medianIntervalS: Double, intervalCV: Double, medianDurS: Double
}

struct BurstSummary {
    var events: [BurstEvent]
    var nSudden: Int
    var clusters: [BurstCluster]
    var threshold: Double
    var best: BurstCluster?
    var surrogateP: Double
    var largestCluster: Int { best?.nEvents ?? 0 }
}

enum MotorEvents {
    /// Distal-joint speeds in torso lengths per second (body frame), plus a noise-floor estimate.
    static func limbSpeeds(_ s: MotorSeries, _ bf: MotorBodyFrame, smoothS: Double = 0.10) -> (limbs: [MotorChannel: [Double]], head: [Double], noise: Double) {
        let win = max(1, MM.pyRound(smoothS * s.fs))
        func speed(_ j: Int) -> [Double] {
            let u = MM.movingAverage(bf.bu[j], win), v = MM.movingAverage(bf.bv[j], win)
            let gu = MM.gradient(u, 1.0 / s.fs), gv = MM.gradient(v, 1.0 / s.fs)
            return (0..<u.count).map { (gu[$0] * gu[$0] + gv[$0] * gv[$0]).squareRoot() }
        }
        var limbs: [MotorChannel: [Double]] = [:]
        for ch in MotorChannel.allCases { limbs[ch] = speed(ch.joint) }
        let head = speed(MJ.nose)
        var ref: [Double] = []
        for j in [MJ.leftShoulder, MJ.rightShoulder, MJ.leftHip, MJ.rightHip] { ref += speed(j) }
        return (limbs, head, MM.nanMedian(ref))
    }

    static func hysteresis(_ x: [Double], on: Double, off: Double) -> [Bool] {
        var state = false
        return x.map { v in
            if !v.isFinite { state = false }
            else if state && v < off { state = false }
            else if !state && v > on { state = true }
            return state
        }
    }

    static func activity(_ s: MotorSeries, speeds: [MotorChannel: [Double]], noise: Double,
                         kneeL: [Double], kneeR: [Double],
                         on onBase: Double = 0.18, off offBase: Double = 0.10, minBoutS: Double = 0.4) -> ActivitySummary {
        let fs = s.fs
        let on = max(onBase, 3.0 * noise), off = max(offBase, 2.0 * noise)
        var limbs: [MotorChannel: LimbActivity] = [:]
        for ch in MotorChannel.allCases {
            let sp = speeds[ch]!
            let valid = sp.map { !$0.isNaN }
            let act = hysteresis(sp, on: on, off: off)
            let bouts = MM.runs(act).filter { Double($0.1 - $0.0) / fs >= minBoutS }
            let obsS = Double(valid.filter { $0 }.count) / fs
            let path = MM.nanSum(sp) / fs
            let validAct = (0..<sp.count).filter { valid[$0] }
            let activeFrac = validAct.isEmpty ? Double.nan : Double(validAct.filter { act[$0] }.count) / Double(validAct.count)
            let jc = s.conf[ch.joint]
            var la = LimbActivity(observedS: obsS, nBouts: bouts.count,
                                  boutsPerMin: obsS > 0 ? Double(bouts.count) / (obsS / 60) : .nan,
                                  activeFrac: activeFrac,
                                  pathPerMin: obsS > 0 ? path / (obsS / 60) : .nan,
                                  medianSpeed: valid.contains(true) ? MM.nanMedian(sp) : .nan,
                                  meanConf: MM.npMean(jc))
            if ch == .L_leg || ch == .R_leg {
                let ka = ch == .L_leg ? kneeL : kneeR
                var kicks = 0
                for (a, b) in bouts {
                    let seg = ka[a..<b]
                    if seg.filter({ $0.isFinite }).count > 3, MM.nanMax(seg) - MM.nanMin(seg) >= 25 { kicks += 1 }
                }
                la.kicksPerMin = obsS > 0 ? Double(kicks) / (obsS / 60) : .nan
            }
            limbs[ch] = la
        }
        func ai(_ a: Double, _ b: Double) -> Double { (a + b) > 0 ? (a - b) / (a + b) : .nan }
        var session: [String: Double] = [:]
        var less: [String: String] = [:]
        for (limb, L, R) in [("arm", MotorChannel.L_arm, MotorChannel.R_arm), ("leg", .L_leg, .R_leg)] {
            let l = limbs[L]!, r = limbs[R]!
            let idx = ai(l.pathPerMin, r.pathPerMin)
            session["\(limb)_asym_index"] = idx
            session["\(limb)_conf_diff"] = abs(l.meanConf - r.meanConf)
            session["\(limb)_min_observed_s"] = min(l.observedS, r.observedS)
            session["\(limb)_active_s"] = l.activeFrac * l.observedS + r.activeFrac * r.observedS
            session["\(limb)_abs_asym_index"] = idx.isFinite ? abs(idx) : .nan
            less[limb] = idx < 0 ? "L" : "R"
        }
        session["_on"] = on; session["_off"] = off; session["_noise_speed"] = noise
        return ActivitySummary(limbs: limbs, session: session, armLessSide: less["arm"]!, legLessSide: less["leg"]!)
    }

    /// Head-to-shoulder distance and projected torso length (both shrink with neck/trunk flexion).
    static func axialSignals(_ bf: MotorBodyFrame) -> [[Double]] {
        let T = bf.valid.count
        let head = (0..<T).map { bf.bv[MJ.nose][$0] - 0.5 * (bf.bv[MJ.leftShoulder][$0] + bf.bv[MJ.rightShoulder][$0]) }
        let torso = bf.LRaw.map { $0 / bf.LSession }
        return [head, torso]
    }

    struct BurstParams {
        var absSpeed, relSpeed, syncTolS: Double
        var minLimbs: Int
        var minDurS, maxDurS, preQuietRatio, minIntervalS, maxIntervalS: Double
        var maxMedianIntervalS: Double
        var requirePair: Bool, requireAxial: Bool
        var minAxial: Double

        init(_ p: [String: Double]) {
            absSpeed = p["abs_speed"] ?? 0.8; relSpeed = p["rel_speed"] ?? 4; syncTolS = p["sync_tol_s"] ?? 0.15
            minLimbs = Int(p["min_limbs"] ?? 3); minDurS = p["min_dur_s"] ?? 0.25; maxDurS = p["max_dur_s"] ?? 3
            preQuietRatio = p["pre_quiet_ratio"] ?? 0.35; minIntervalS = p["min_interval_s"] ?? 2
            maxIntervalS = p["max_interval_s"] ?? 60; maxMedianIntervalS = p["max_median_interval_s"] ?? .infinity
            requirePair = (p["require_pair"] ?? 1) > 0.5; requireAxial = (p["require_axial"] ?? 0) > 0.5
            minAxial = p["min_axial"] ?? 0
        }
    }

    private static func scan(_ t: [Double], fs: Double, _ S: [[Double]], thr: Double, _ p: BurstParams,
                             axial: [[Double]]?) -> (events: [BurstEvent], clusters: [BurstCluster], best: BurstCluster?, nSudden: Int) {
        let T = S[0].count
        let limbs = MotorChannel.allCases
        let strong = S.map { row in row.map { ($0.isNaN ? 0 : $0) > thr } }
        let tol = max(1, MM.pyRound(p.syncTolS * fs))
        let dil = strong.map { row -> [Bool] in
            MM.boxSum(row.map { $0 ? 1.0 : 0.0 }, 2 * tol + 1).map { $0 > 0 }
        }
        let sync = (0..<T).map { i in dil.reduce(0) { $0 + ($1[i] ? 1 : 0) } >= p.minLimbs }
        let ev = MM.mergeRuns(MM.runs(sync), gap: MM.pyRound(0.2 * fs))
        let speedMean = (0..<T).map { i -> Double in
            var s = 0.0, c = 0.0
            for r in S where !r[i].isNaN { s += r[i]; c += 1 }
            return c > 0 ? s / c : .nan
        }
        var events: [BurstEvent] = []
        for (a, b) in ev {
            let dur = Double(b - a) / fs
            guard dur >= p.minDurS, dur <= p.maxDurS else { continue }
            let preA = max(0, a - Int(2.0 * fs)), preB = max(0, a - Int(0.5 * fs))
            let pre = preA < preB ? Array(speedMean[preA..<preB]) : []
            let peak = MM.nanMax(speedMean[a..<b])
            let preLevel = pre.filter { $0.isFinite }.count > 3 ? MM.nanMedian(pre) : .nan
            let sudden = preLevel.isFinite && preLevel <= p.preQuietRatio * peak
            let lb = (0..<4).filter { k in strong[k][a..<b].contains(true) }.map { limbs[$0] }
            let set = Set(lb)
            let pair = (set.contains(.L_arm) && set.contains(.R_arm)) || (set.contains(.L_leg) && set.contains(.R_leg))
            var ax = Double.nan
            if let axial {
                let pa = max(0, a - Int(1.5 * fs)), pb = max(1, a - Int(0.2 * fs))
                var devs: [Double] = []
                for sig in axial {
                    let baseSeg = pa < pb ? Array(sig[pa..<min(pb, sig.count)]) : []
                    let base = baseSeg.contains { $0.isFinite } ? MM.nanMedian(baseSeg) : .nan
                    let segEnd = min(sig.count, b + Int(0.3 * fs))
                    let seg = sig[a..<segEnd]
                    if base.isFinite, seg.contains(where: { $0.isFinite }) {
                        devs.append(MM.nanMax(ArraySlice(seg.map { abs($0 - base) })))
                    }
                }
                ax = devs.max() ?? .nan
            }
            let axialOK = !p.requireAxial || (ax.isFinite && ax >= p.minAxial)
            events.append(BurstEvent(t0: t[a], t1: t[b - 1], durS: dur, peakSpeed: peak, preLevel: preLevel,
                                     bilateralPair: pair, axialDev: ax,
                                     sudden: sudden && axialOK && (pair || !p.requirePair), limbs: lb))
        }
        let sud = events.filter { $0.sudden }
        var groups: [[BurstEvent]] = []
        var cur: [BurstEvent] = []
        for e in sud {
            if let last = cur.last, p.minIntervalS <= e.t0 - last.t0, e.t0 - last.t0 <= p.maxIntervalS {
                cur.append(e)
            } else {
                if !cur.isEmpty { groups.append(cur) }
                cur = [e]
            }
        }
        if !cur.isEmpty { groups.append(cur) }
        let clusters = groups.map { c -> BurstCluster in
            let iv = zip(c.dropFirst(), c).map { $0.t0 - $1.t0 }
            let mean = iv.isEmpty ? Double.nan : MM.npMean(iv)
            var cv = Double.nan
            if iv.count > 1 {
                let sq = iv.map { ($0 - mean) * ($0 - mean) }
                cv = MM.npMean(sq).squareRoot() / mean
            }
            return BurstCluster(nEvents: c.count, t0: c[0].t0, t1: c[c.count - 1].t1,
                                medianIntervalS: iv.isEmpty ? .nan : MM.median(iv), intervalCV: cv,
                                medianDurS: MM.median(c.map { $0.durS }))
        }
        var best: BurstCluster?
        for c in clusters where c.medianIntervalS.isFinite && c.medianIntervalS <= p.maxMedianIntervalS {
            if best == nil || c.nEvents > best!.nEvents { best = c }
        }
        return (events, clusters, best, sud.count)
    }

    static func bursts(_ s: MotorSeries, speeds: [MotorChannel: [Double]], params p: BurstParams,
                       axial: [[Double]]?, nSurrogates: Int = 60, seed: UInt64 = 0) -> BurstSummary {
        let fs = s.fs
        let S = MotorChannel.allCases.map { speeds[$0]! }
        let pooled = MM.nanMedian(S.flatMap { $0 })
        let thr = max(p.absSpeed, p.relSpeed * pooled)
        let obs = scan(s.t, fs: fs, S, thr: thr, p, axial: axial)
        let stat = obs.best?.nEvents ?? 0
        let T = S[0].count
        let minShift = Int(5 * fs)
        var pval = 1.0
        if stat > 0, T > 4 * minShift {
            var rng = SplitMix64(seed: seed)
            let span = UInt64(T - 2 * minShift)
            var ge = 0
            for _ in 0..<nSurrogates {
                var rows = [S[0]]
                for i in 1..<4 {
                    let shift = minShift + Int(rng.next() % span)
                    rows.append(roll(S[i], shift))
                }
                if (scan(s.t, fs: fs, rows, thr: thr, p, axial: axial).best?.nEvents ?? 0) >= stat { ge += 1 }
            }
            pval = Double(1 + ge) / Double(1 + nSurrogates)
        }
        return BurstSummary(events: obs.events, nSudden: obs.nSudden, clusters: obs.clusters, threshold: thr,
                            best: obs.best, surrogateP: pval)
    }

    /// `np.roll(x, shift)`.
    static func roll(_ x: [Double], _ shift: Int) -> [Double] {
        let n = x.count
        guard n > 0 else { return x }
        let k = ((shift % n) + n) % n
        return Array(x[(n - k)...] + x[..<(n - k)])
    }
}
