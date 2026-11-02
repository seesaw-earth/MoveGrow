// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
//
// Windowed spectral features per limb channel (reference: spectral.py). Run on RAW keypoints.

import Foundation

enum MotorChannel: String, CaseIterable, Codable {
    case L_arm, R_arm, L_leg, R_leg
    var joint: Int {
        switch self {
        case .L_arm: return MJ.leftWrist
        case .R_arm: return MJ.rightWrist
        case .L_leg: return MJ.leftAnkle
        case .R_leg: return MJ.rightAnkle
        }
    }
    var contra: MotorChannel {
        switch self {
        case .L_arm: return .R_arm
        case .R_arm: return .L_arm
        case .L_leg: return .R_leg
        case .R_leg: return .L_leg
        }
    }
    var side: String { rawValue.hasPrefix("L") ? "L" : "R" }
}

struct SpectralBand {
    var hp: Double, lp: Double?
    var searchLo: Double, searchHi: Double
    var refLo: Double, refHi: Double?
    var win: Double, hop: Double, excl: Double, bw: Double

    static let fast = SpectralBand(hp: 4.0, lp: 14.0, searchLo: 4.5, searchHi: 13.5, refLo: 4.5, refHi: 14.0,
                                   win: 2.0, hop: 0.5, excl: 1.0, bw: 0.75)
    static let slow = SpectralBand(hp: 0.4, lp: 6.0, searchLo: 0.75, searchHi: 4.5, refLo: 0.5, refHi: 6.0,
                                   win: 4.0, hop: 1.0, excl: 0.5, bw: 0.35)
    static func named(_ name: String) -> SpectralBand { name == "fast" ? .fast : .slow }
}

struct SpectralRow {
    var channel: MotorChannel
    var t0: Double, t1: Double
    var valid: Bool
    var features: [String: Double]
    var startIndex: Int
}

struct SpectralResult {
    var rows: [SpectralRow]
    var abstain: String?
    var hop: Double
    var searchLo: Double, searchHi: Double
}

enum MotorSpectral {
    static func bandFilter(_ x: [Double], fs: Double, hp: Double, lp: Double?) -> [Double] {
        let nyq = 0.5 * fs
        let sos: SOS
        if let lp, lp < nyq * 0.95 { sos = .butter(order: 4, low: hp / nyq, high: lp / nyq) }
        else { sos = .butter(order: 4, low: hp / nyq, high: nil) }
        return sos.filtfilt(x)
    }

    /// One-sided Hann periodogram summed over the two coordinate columns.
    static func psd(_ u: ArraySlice<Double>, _ v: ArraySlice<Double>, fs: Double, nfft: Int) -> (f: [Double], P: [Double]) {
        let n = u.count
        let w = MM.hanning(n)
        let wsum = MM.npSum(w.map { $0 * $0 })
        var P = [Double](repeating: 0, count: nfft / 2 + 1)
        for col in [u, v] {
            var mean = 0.0
            for x in col { mean += x }
            mean /= Double(n)
            let xs = col.enumerated().map { ($0.element - mean) * w[$0.offset] }
            let pw = MotorFFT.rfftPower(xs, nfft: nfft)
            for k in 0..<P.count {
                var p = pw[k] / (fs * wsum)
                if k > 0 && k < P.count - 1 { p *= 2 }
                P[k] += p
            }
        }
        let val = 1.0 / (Double(nfft) * (1.0 / fs))   // np.fft.rfftfreq
        let f = (0..<P.count).map { Double($0) * val }
        return (f, P)
    }

    /// Fraction of band-passed multi-joint image motion explained by one similarity motion per frame.
    static func rigidR2(_ D: [[(Double, Double)]], _ pbar: [(Double, Double)]) -> Double {
        let n = pbar.count
        var cxm = 0.0, cym = 0.0
        for p in pbar { cxm += p.0; cym += p.1 }
        cxm /= Double(n); cym /= Double(n)
        // A rows: x-row [1, 0, -ry, rx], y-row [0, 1, rx, ry]
        var ata = [[Double]](repeating: [Double](repeating: 0, count: 4), count: 4)
        var rows: [[Double]] = []
        for p in pbar {
            let rx = p.0 - cxm, ry = p.1 - cym
            rows.append([1, 0, -ry, rx]); rows.append([0, 1, rx, ry])
        }
        for r in rows { for a in 0..<4 { for b in 0..<4 { ata[a][b] += r[a] * r[b] } } }
        var sse = 0.0, sst = 0.0
        for frame in D {
            var y = [Double](); y.reserveCapacity(2 * n)
            for d in frame { y.append(d.0); y.append(d.1) }
            var aty = [Double](repeating: 0, count: 4)
            for (i, r) in rows.enumerated() { for a in 0..<4 { aty[a] += r[a] * y[i] } }
            guard let coef = solve4(ata, aty) else { return .nan }
            for (i, r) in rows.enumerated() {
                var pred = 0.0
                for a in 0..<4 { pred += r[a] * coef[a] }
                let e = y[i] - pred
                sse += e * e; sst += y[i] * y[i]
            }
        }
        return sst > 0 ? 1 - sse / sst : 0
    }

    private static func solve4(_ A: [[Double]], _ b: [Double]) -> [Double]? {
        var M = A, y = b
        let n = 4
        for c in 0..<n {
            var piv = c
            for r in (c + 1)..<n where abs(M[r][c]) > abs(M[piv][c]) { piv = r }
            if abs(M[piv][c]) < 1e-14 { return nil }
            M.swapAt(c, piv); y.swapAt(c, piv)
            for r in (c + 1)..<n {
                let f = M[r][c] / M[c][c]
                for k in c..<n { M[r][k] -= f * M[c][k] }
                y[r] -= f * y[c]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for r in stride(from: n - 1, through: 0, by: -1) {
            var s = y[r]
            for k in (r + 1)..<n { s -= M[r][k] * x[k] }
            x[r] = s / M[r][r]
        }
        return x
    }

    static let rigidJoints = [MJ.leftShoulder, MJ.rightShoulder, MJ.leftHip, MJ.rightHip, MJ.leftElbow, MJ.rightElbow,
                              MJ.leftWrist, MJ.rightWrist, MJ.leftKnee, MJ.rightKnee, MJ.leftAnkle, MJ.rightAnkle, MJ.nose]

    static func windows(_ s: MotorSeries, _ bf: MotorBodyFrame, band name: String, minValid: Double = 0.9,
                        torsoCm: Double = 20.0, unstable: [Bool]? = nil) -> SpectralResult {
        let cfg = SpectralBand.named(name)
        let fs = s.fs, nyq = 0.5 * fs
        let sLo = cfg.searchLo, sHi = min(cfg.searchHi, nyq - 0.5)
        let rLo = cfg.refLo
        let rHi = min(cfg.refHi ?? (nyq - 0.25), nyq - 0.25)
        if sHi <= sLo + 0.5 || cfg.hp >= nyq * 0.9 {
            return SpectralResult(rows: [], abstain: String(format: "sampling rate %.1f Hz too low for %@ band", fs, name),
                                  hop: cfg.hop, searchLo: sLo, searchHi: sHi)
        }
        let win = MM.pyRound(cfg.win * fs), hop = MM.pyRound(cfg.hop * fs)
        let nfft = Int(pow(2.0, ceil(log2(Double(max(256, 4 * win))))))
        let T = s.count
        var filtU: [MotorChannel: [Double]] = [:], filtV: [MotorChannel: [Double]] = [:], okMask: [MotorChannel: [Bool]] = [:]
        for ch in MotorChannel.allCases {
            let (fu, oku) = MM.fillNaN(bf.bu[ch.joint]), (fv, okv) = MM.fillNaN(bf.bv[ch.joint])
            filtU[ch] = bandFilter(fu, fs: fs, hp: cfg.hp, lp: cfg.lp)
            filtV[ch] = bandFilter(fv, fs: fs, hp: cfg.hp, lp: cfg.lp)
            okMask[ch] = (0..<T).map { oku[$0] && okv[$0] }
        }
        let rig = rigidJoints
        var rigX: [[Double]] = [], rigY: [[Double]] = [], rigOK: [[Bool]] = []
        for j in rig {
            rigX.append(bandFilter(MM.fillNaN(bf.px[j]).filled, fs: fs, hp: cfg.hp, lp: cfg.lp))
            rigY.append(bandFilter(MM.fillNaN(bf.py[j]).filled, fs: fs, hp: cfg.hp, lp: cfg.lp))
            rigOK.append(bf.px[j].map { $0.isFinite })
        }
        let cenX = bandFilter(MM.fillNaN(bf.cx).filled, fs: fs, hp: cfg.hp, lp: cfg.lp)
        let cenY = bandFilter(MM.fillNaN(bf.cy).filled, fs: fs, hp: cfg.hp, lp: cfg.lp)

        var rows: [SpectralRow] = []
        var specCache: [Int: (f: [Double], P: [Double])] = [:]   // key: channelIndex * 1_000_000 + start
        func spectrum(_ ch: MotorChannel, _ st: Int) -> (f: [Double], P: [Double]) {
            let key = MotorChannel.allCases.firstIndex(of: ch)! * 1_000_000 + st
            if let c = specCache[key] { return c }
            let r = psd(filtU[ch]![st..<(st + win)], filtV[ch]![st..<(st + win)], fs: fs, nfft: nfft)
            specCache[key] = r
            return r
        }
        var st = 0
        while st + win <= T {
            let t0 = s.t[st], t1 = s.t[st + win - 1]
            // rigid-motion test on joints valid through the window
            let full = (0..<rig.count).filter { k in (st..<(st + win)).allSatisfy { rigOK[k][$0] } }
            var r2 = Double.nan
            if full.count >= 6 {
                var D: [[(Double, Double)]] = []
                for t in st..<(st + win) { D.append(full.map { (rigX[$0][t], rigY[$0][t]) }) }
                let pbar: [(Double, Double)] = full.map { k in
                    var sx = 0.0, sy = 0.0, c = 0.0
                    for t in st..<(st + win) where bf.px[rig[k]][t].isFinite {
                        sx += bf.px[rig[k]][t]; sy += bf.py[rig[k]][t]; c += 1
                    }
                    return (sx / c, sy / c)
                }
                r2 = rigidR2(D, pbar)
            }
            var camSq = [Double]()
            camSq.reserveCapacity(win)
            for t in st..<(st + win) {
                let a: Double = cenX[t] * cenX[t]
                let b: Double = cenY[t] * cenY[t]
                camSq.append(a + b)
            }
            let camRms: Double = MM.npMean(camSq).squareRoot() / bf.LSession
            let windowUnstable = unstable.map { u in (st..<(st + win)).filter { u[$0] }.count * 2 > win } ?? false
            for ch in MotorChannel.allCases {
                let ok = okMask[ch]!
                let vfrac = Double((st..<(st + win)).filter { ok[$0] }.count) / Double(win)
                var feats: [String: Double] = ["valid_frac": vfrac, "rigid_r2": r2, "camera_rms": camRms]
                if vfrac < minValid || windowUnstable {
                    rows.append(SpectralRow(channel: ch, t0: t0, t1: t1, valid: false, features: feats, startIndex: st))
                    continue
                }
                let (f, P) = spectrum(ch, st)
                let df = f[1] - f[0]
                var k = -1
                var best = -Double.infinity
                for i in 0..<P.count where f[i] >= sLo && f[i] <= sHi && P[i] > best { best = P[i]; k = i }
                if k < 0 { k = 0 }
                var off = 0.0
                if k > 0, k < P.count - 1, P[k - 1] > 0, P[k + 1] > 0 {
                    let a = log(P[k - 1]), b = log(P[k]), c = log(P[k + 1])
                    let den = a - 2 * b + c
                    off = den != 0 ? 0.5 * (a - c) / den : 0
                }
                let f0 = f[k] + off * df
                let refVals = (0..<P.count).filter { f[$0] >= rLo && f[$0] <= rHi && abs(f[$0] - f0) > cfg.excl }.map { P[$0] }
                let med = refVals.isEmpty ? Double.nan : MM.median(refVals)
                let prom = (med.isFinite && med > 0) ? 10 * log10(P[k] / med) : Double.nan
                let varBand = MM.npSum((0..<P.count).filter { abs(f[$0] - f0) <= cfg.bw }.map { P[$0] }) * df
                let amp = 2.0 * (2.0 * varBand).squareRoot()
                let lag = f0 > 0 ? MM.pyRound(fs / f0) : 0
                var rho = Double.nan
                if lag > 0, lag < win - 2 {
                    let u = filtU[ch]!, v = filtV[ch]!
                    var mu = 0.0, mv = 0.0
                    for t in st..<(st + win) { mu += u[t]; mv += v[t] }
                    mu /= Double(win); mv /= Double(win)
                    var prod: [Double] = [], a2: [Double] = [], b2: [Double] = []
                    for t in st..<(st + win - lag) {
                        let xa = (u[t] - mu, v[t] - mv), xb = (u[t + lag] - mu, v[t + lag] - mv)
                        prod.append(xa.0 * xb.0); prod.append(xa.1 * xb.1)
                        a2.append(xa.0 * xa.0); a2.append(xa.1 * xa.1)
                        b2.append(xb.0 * xb.0); b2.append(xb.1 * xb.1)
                    }
                    let num = MM.npSum(prod), den = (MM.npSum(a2) * MM.npSum(b2)).squareRoot()
                    rho = den > 0 ? num / den : 0
                }
                let tot = MM.npSum((0..<P.count).filter { f[$0] >= rLo && f[$0] <= rHi }.map { P[$0] }) * df
                feats["peak_hz"] = f0
                feats["prominence_db"] = prom
                feats["amp_p2p"] = amp
                feats["amp_p2p_cm"] = amp * torsoCm
                feats["rhythmicity"] = rho
                feats["band_var"] = varBand
                feats["total_var"] = tot
                feats["peak_frac"] = tot > 0 ? varBand / tot : .nan
                rows.append(SpectralRow(channel: ch, t0: t0, t1: t1, valid: true, features: feats, startIndex: st))
            }
            st += hop
        }
        // contralateral power at this window's peak frequency
        var index: [String: Int] = [:]
        for (i, r) in rows.enumerated() { index["\(r.channel.rawValue)|\(r.startIndex)"] = i }
        for i in rows.indices where rows[i].valid {
            let r = rows[i]
            guard let oi = index["\(r.channel.contra.rawValue)|\(r.startIndex)"], rows[oi].valid else {
                rows[i].features["contra_ratio"] = .nan
                continue
            }
            let start = MM.pyRound((r.t0 - s.t[0]) * fs)
            let stop = min(start + win, T)
            guard stop - start == win else { rows[i].features["contra_ratio"] = .nan; continue }
            let (f, P) = start == r.startIndex ? spectrum(r.channel.contra, start)
                : psd(filtU[r.channel.contra]![start..<stop], filtV[r.channel.contra]![start..<stop], fs: fs, nfft: nfft)
            let peak = r.features["peak_hz"]!, bv = r.features["band_var"]!
            let pb = MM.npSum((0..<P.count).filter { abs(f[$0] - peak) <= cfg.bw }.map { P[$0] }) * (f[1] - f[0])
            rows[i].features["contra_ratio"] = bv > 0 ? pb / bv : .nan
        }
        return SpectralResult(rows: rows, abstain: nil, hop: cfg.hop, searchLo: sLo, searchHi: sHi)
    }
}
