// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
//
// Numerical helpers for the motor rule engine. Foundation only (builds on iOS and Linux).
// Several functions deliberately reproduce NumPy/SciPy conventions (half-to-even rounding,
// pairwise summation, linear percentiles, `np.convolve(mode: "same")` alignment) so that the
// Swift engine matches the Python reference in Research/motor-rules bit-for-bit where it matters.

import Foundation

enum MM {
    /// Python `int(round(x))`: round half to even.
    @inline(__always) static func pyRound(_ x: Double) -> Int { Int(x.rounded(.toNearestOrEven)) }

    /// NumPy `np.mod` for floats (result takes the sign of the divisor).
    @inline(__always) static func pyMod(_ a: Double, _ b: Double) -> Double {
        var m = fmod(a, b)
        if m != 0, (b < 0) != (m < 0) { m += b }
        return m
    }

    /// NumPy pairwise summation for a contiguous 1-D float64 array (`np.sum`).
    static func npSum(_ a: [Double]) -> Double {
        a.withUnsafeBufferPointer { pairwise($0.baseAddress!, $0.count) }
    }

    private static func pairwise(_ a: UnsafePointer<Double>, _ n: Int) -> Double {
        if n < 8 {
            var res = 0.0
            for i in 0..<n { res += a[i] }
            return res
        } else if n <= 128 {
            var r = [a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7]]
            var i = 8
            while i < n - (n % 8) {
                r[0] += a[i]; r[1] += a[i + 1]; r[2] += a[i + 2]; r[3] += a[i + 3]
                r[4] += a[i + 4]; r[5] += a[i + 5]; r[6] += a[i + 6]; r[7] += a[i + 7]
                i += 8
            }
            var res = ((r[0] + r[1]) + (r[2] + r[3])) + ((r[4] + r[5]) + (r[6] + r[7]))
            while i < n { res += a[i]; i += 1 }
            return res
        } else {
            var n2 = n / 2
            n2 -= n2 % 8
            return pairwise(a, n2) + pairwise(a + n2, n - n2)
        }
    }

    static func npMean(_ a: [Double]) -> Double { a.isEmpty ? .nan : npSum(a) / Double(a.count) }

    /// `np.nansum` (NaN treated as zero, pairwise).
    static func nanSum(_ a: [Double]) -> Double { npSum(a.map { $0.isNaN ? 0 : $0 }) }

    /// Median of finite-or-not values, NaN ignored (`np.nanmedian`). Empty → NaN.
    static func nanMedian(_ a: [Double]) -> Double { median(a.filter { !$0.isNaN }) }

    /// `np.median` of values without NaN.
    static func median(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return .nan }
        let s = v.sorted()
        let n = s.count
        if n % 2 == 1 { return s[n / 2] }
        return (s[n / 2 - 1] + s[n / 2]) / 2
    }

    /// `np.nanpercentile(a, q)` with the default linear method (NumPy ≥ 1.22 `_lerp`).
    static func nanPercentile(_ a: [Double], _ q: Double) -> Double {
        let s = a.filter { !$0.isNaN }.sorted()
        guard !s.isEmpty else { return .nan }
        let n = s.count
        let virtualIndex = (q / 100) * Double(n - 1)
        let prev = min(max(Int(virtualIndex.rounded(.down)), 0), n - 1)
        let next = min(prev + 1, n - 1)
        let gamma = virtualIndex - Double(prev)
        let lo = s[prev], hi = s[next]
        let diff = hi - lo
        return gamma >= 0.5 ? hi - diff * (1 - gamma) : lo + diff * gamma
    }

    static func nanMax(_ a: ArraySlice<Double>) -> Double {
        var best = -Double.infinity, any = false
        for v in a where !v.isNaN { any = true; if v > best { best = v } }
        return any ? best : .nan
    }

    static func nanMin(_ a: ArraySlice<Double>) -> Double {
        var best = Double.infinity, any = false
        for v in a where !v.isNaN { any = true; if v < best { best = v } }
        return any ? best : .nan
    }

    /// `np.interp(x, xp, fp, left, right)` with increasing xp.
    static func interp(_ x: [Double], _ xp: [Double], _ fp: [Double], left: Double? = nil, right: Double? = nil) -> [Double] {
        let n = xp.count
        guard n > 0 else { return [Double](repeating: .nan, count: x.count) }
        let l = left ?? fp[0], r = right ?? fp[n - 1]
        var out = [Double](repeating: 0, count: x.count)
        for (i, xi) in x.enumerated() {
            if xi.isNaN { out[i] = .nan; continue }
            if xi < xp[0] { out[i] = l; continue }
            if xi > xp[n - 1] { out[i] = r; continue }
            if xi == xp[n - 1] { out[i] = fp[n - 1]; continue }
            // binary search j: xp[j] <= xi < xp[j+1]
            var lo = 0, hi = n - 1
            while hi - lo > 1 {
                let mid = (lo + hi) / 2
                if xp[mid] <= xi { lo = mid } else { hi = mid }
            }
            let slope = (fp[lo + 1] - fp[lo]) / (xp[lo + 1] - xp[lo])
            var v = slope * (xi - xp[lo]) + fp[lo]
            if v.isNaN { // NumPy falls back when the slope is not finite
                v = slope * (xi - xp[lo + 1]) + fp[lo + 1]
                if v.isNaN, fp[lo] == fp[lo + 1] { v = fp[lo] }
            }
            out[i] = v
        }
        return out
    }

    /// `np.searchsorted(a, v, side="left")`.
    static func searchSortedLeft(_ a: [Double], _ v: Double) -> Int {
        var lo = 0, hi = a.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if a[mid] < v { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// `np.unwrap` over a sequence.
    static func unwrap(_ p: [Double]) -> [Double] {
        guard p.count > 1 else { return p }
        var out = p
        var cum = 0.0
        for i in 1..<p.count {
            let dd = p[i] - p[i - 1]
            var ddmod = pyMod(dd + Double.pi, 2 * Double.pi) - Double.pi
            if ddmod == -Double.pi, dd > 0 { ddmod = Double.pi }
            var corr = ddmod - dd
            if abs(dd) < Double.pi { corr = 0 }
            cum += corr
            out[i] = p[i] + cum
        }
        return out
    }

    /// Centered rolling median ignoring NaN, edge-padded (`rolling_nanmedian` in the reference).
    static func rollingNanMedian(_ x: [Double], _ win: Int) -> [Double] {
        guard win > 1, !x.isEmpty else { return x }
        let h = win / 2
        let n = x.count
        var out = [Double](repeating: .nan, count: n)
        var buf = [Double]()
        buf.reserveCapacity(2 * h + 1)
        for i in 0..<n {
            buf.removeAll(keepingCapacity: true)
            for k in (i - h)...(i + h) {
                let v = x[min(max(k, 0), n - 1)]
                if !v.isNaN { buf.append(v) }
            }
            out[i] = median(buf)
        }
        return out
    }

    /// `np.convolve(x, ones(win), mode="same")` for len(x) >= win: window [i - win/2, i + win - 1 - win/2].
    static func boxSum(_ x: [Double], _ win: Int) -> [Double] {
        let n = x.count
        guard win > 1 else { return x }
        let left = win / 2, right = win - 1 - left
        var out = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var s = 0.0
            let a = max(0, i - left), b = min(n - 1, i + right)
            if a <= b { for k in a...b { s += x[k] } }
            out[i] = s
        }
        return out
    }

    /// NaN-aware centered moving average of one series (reference `moving_average`).
    static func movingAverage(_ x: [Double], _ win: Int) -> [Double] {
        guard win > 1 else { return x }
        let valid = x.map { !$0.isNaN }
        let num = boxSum(x.map { $0.isNaN ? 0 : $0 }, win)
        let den = boxSum(valid.map { $0 ? 1.0 : 0.0 }, win)
        var out = [Double](repeating: .nan, count: x.count)
        for i in 0..<x.count where valid[i] && den[i] > 0.5 * Double(win) {
            out[i] = num[i] / max(den[i], 1e-9)
        }
        return out
    }

    /// `np.gradient(x, dx)` along a 1-D series.
    static func gradient(_ x: [Double], _ dx: Double) -> [Double] {
        let n = x.count
        guard n >= 2 else { return [Double](repeating: .nan, count: n) }
        var g = [Double](repeating: 0, count: n)
        g[0] = (x[1] - x[0]) / dx
        g[n - 1] = (x[n - 1] - x[n - 2]) / dx
        if n > 2 { for i in 1..<(n - 1) { g[i] = (x[i + 1] - x[i - 1]) / (2.0 * dx) } }
        return g
    }

    /// Fill NaN by linear interpolation over the sample index (reference `_fill_nan`).
    static func fillNaN(_ x: [Double]) -> (filled: [Double], ok: [Bool]) {
        let ok = x.map { !$0.isNaN }
        let idx = x.indices.filter { ok[$0] }
        guard idx.count >= 2 else { return ([Double](repeating: 0, count: x.count), ok) }
        let xp = idx.map(Double.init), fp = idx.map { x[$0] }
        return (interp(x.indices.map(Double.init), xp, fp), ok)
    }

    /// `np.hanning(n)`.
    static func hanning(_ m: Int) -> [Double] {
        if m < 1 { return [] }
        if m == 1 { return [1] }
        return (0..<m).map { k in
            let n = Double(1 - m + 2 * k)
            return 0.5 + 0.5 * cos(Double.pi * n / Double(m - 1))
        }
    }

    /// Contiguous True runs as half-open [start, end) pairs.
    static func runs(_ mask: [Bool]) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        var start: Int?
        for (i, m) in mask.enumerated() {
            if m, start == nil { start = i }
            if !m, let s = start { out.append((s, i)); start = nil }
        }
        if let s = start { out.append((s, mask.count)) }
        return out
    }

    static func mergeRuns(_ rr: [(Int, Int)], gap: Int) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        for (a, b) in rr {
            if let last = out.last, a - last.1 <= gap { out[out.count - 1].1 = b } else { out.append((a, b)) }
        }
        return out
    }

    @inline(__always) static func clip(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        x.isNaN ? .nan : min(max(x, lo), hi)
    }

    /// NumPy `np.minimum` / `np.maximum` (NaN propagates).
    @inline(__always) static func nanPropMin(_ a: Double, _ b: Double) -> Double { (a.isNaN || b.isNaN) ? .nan : min(a, b) }
    @inline(__always) static func nanPropMax(_ a: Double, _ b: Double) -> Double { (a.isNaN || b.isNaN) ? .nan : max(a, b) }

    @inline(__always) static func degrees(_ r: Double) -> Double { r * (180.0 / Double.pi) }
}

/// Deterministic RNG shared bit-for-bit with the Python reference (surrogate lags).
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
