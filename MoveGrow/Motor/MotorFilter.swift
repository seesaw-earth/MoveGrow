// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
//
// FFT and Butterworth zero-phase filtering (SciPy `butter(..., output="sos")` + `sosfiltfilt`).

import Foundation

struct Cx {
    var re: Double, im: Double
    init(_ re: Double, _ im: Double = 0) { self.re = re; self.im = im }
    static func + (a: Cx, b: Cx) -> Cx { Cx(a.re + b.re, a.im + b.im) }
    static func - (a: Cx, b: Cx) -> Cx { Cx(a.re - b.re, a.im - b.im) }
    static func * (a: Cx, b: Cx) -> Cx { Cx(a.re * b.re - a.im * b.im, a.re * b.im + a.im * b.re) }
    static func * (a: Cx, s: Double) -> Cx { Cx(a.re * s, a.im * s) }
    static func / (a: Cx, b: Cx) -> Cx {
        let d = b.re * b.re + b.im * b.im
        return Cx((a.re * b.re + a.im * b.im) / d, (a.im * b.re - a.re * b.im) / d)
    }
    static prefix func - (a: Cx) -> Cx { Cx(-a.re, -a.im) }
    var abs2: Double { re * re + im * im }
    var magnitude: Double { (re * re + im * im).squareRoot() }
    /// Principal square root.
    var sqrt: Cx {
        let m = magnitude
        let r = ((m + re) / 2).squareRoot()
        let i = ((m - re) / 2).squareRoot()
        return Cx(r, im < 0 ? -i : i)
    }
    static func expi(_ theta: Double) -> Cx { Cx(cos(theta), sin(theta)) }
}

enum MotorFFT {
    /// In-place iterative radix-2 FFT. `n` must be a power of two.
    static func fft(_ re: inout [Double], _ im: inout [Double]) {
        let n = re.count
        guard n > 1 else { return }
        var j = 0
        for i in 1..<n {
            var bit = n >> 1
            while j & bit != 0 { j ^= bit; bit >>= 1 }
            j |= bit
            if i < j { re.swapAt(i, j); im.swapAt(i, j) }
        }
        var len = 2
        while len <= n {
            let ang = -2 * Double.pi / Double(len)
            let wr = cos(ang), wi = sin(ang)
            var i = 0
            while i < n {
                var cr = 1.0, ci = 0.0
                for k in 0..<(len / 2) {
                    let a = i + k, b = i + k + len / 2
                    let tr = re[b] * cr - im[b] * ci
                    let ti = re[b] * ci + im[b] * cr
                    re[b] = re[a] - tr; im[b] = im[a] - ti
                    re[a] += tr; im[a] += ti
                    let ncr = cr * wr - ci * wi
                    ci = cr * wi + ci * wr
                    cr = ncr
                }
                i += len
            }
            len <<= 1
        }
    }

    /// |rfft(x, n: nfft)|² for k = 0...nfft/2.
    static func rfftPower(_ x: [Double], nfft: Int) -> [Double] {
        var re = [Double](repeating: 0, count: nfft), im = [Double](repeating: 0, count: nfft)
        for (i, v) in x.prefix(nfft).enumerated() { re[i] = v }
        fft(&re, &im)
        return (0...(nfft / 2)).map { re[$0] * re[$0] + im[$0] * im[$0] }
    }
}

/// Second-order sections, rows [b0, b1, b2, 1, a1, a2].
struct SOS {
    var sections: [[Double]]

    /// SciPy `butter(4, Wn, btype)` designed in the digital domain (Wn normalized to Nyquist).
    static func butter(order n: Int, low: Double?, high: Double?) -> SOS {
        // analog prototype poles: p = -exp(i*pi*m/(2N)), m = -N+1, -N+3, ..., N-1
        var proto: [Cx] = []
        var m = -n + 1
        while m < n {
            proto.append(-Cx.expi(Double.pi * Double(m) / Double(2 * n)))
            m += 2
        }
        let fs = 2.0
        func warp(_ w: Double) -> Double { 2 * fs * tan(Double.pi * w / fs) }
        var poles: [Cx]
        var zeros: [Cx]
        var k: Double
        if let lo = low, let hi = high { // band-pass
            let w1 = warp(lo), w2 = warp(hi)
            let bw = w2 - w1, wo = (w1 * w2).squareRoot()
            let plp = proto.map { $0 * (bw / 2) }
            let wo2 = Cx(wo * wo)
            poles = plp.map { $0 + ($0 * $0 - wo2).sqrt } + plp.map { $0 - ($0 * $0 - wo2).sqrt }
            zeros = [Cx](repeating: Cx(0), count: n)
            k = pow(bw, Double(n))
        } else { // high-pass at `low`
            let wo = warp(low!)
            poles = proto.map { Cx(wo) / $0 }
            zeros = [Cx](repeating: Cx(0), count: n)
            var prodNegP = Cx(1)
            for p in proto { prodNegP = prodNegP * (-p) }
            k = (Cx(1) / prodNegP).re
        }
        // bilinear transform, fs = 2
        let fs2 = Cx(2 * fs)
        let degree = poles.count - zeros.count
        var num = Cx(1), den = Cx(1)
        for z in zeros { num = num * (fs2 - z) }
        for p in poles { den = den * (fs2 - p) }
        let kz = k * (num / den).re
        let pz = poles.map { (fs2 + $0) / (fs2 - $0) }
        var zz = zeros.map { (fs2 + $0) / (fs2 - $0) }
        zz += [Cx](repeating: Cx(-1), count: degree)
        // pair conjugate poles (upper half plane), farthest from the unit circle first
        let upper = pz.filter { $0.im > 0 }.sorted { (1 - $0.magnitude) > (1 - $1.magnitude) }
        let ones = zz.filter { $0.re > 0 }.count, minus = zz.count - ones
        var sections: [[Double]] = []
        var remainingPlus = ones, remainingMinus = minus
        for (i, p) in upper.enumerated() {
            let a = [1.0, -2 * p.re, p.abs2]
            var b: [Double]
            if remainingPlus >= 1, remainingMinus >= 1 { b = [1, 0, -1]; remainingPlus -= 1; remainingMinus -= 1 }
            else if remainingPlus >= 2 { b = [1, -2, 1]; remainingPlus -= 2 }
            else { b = [1, 2, 1]; remainingMinus -= 2 }
            if i == 0 { b = b.map { $0 * kz } }
            sections.append(b + a)
        }
        return SOS(sections: sections)
    }

    var padlen: Int {
        let ns = sections.count
        let zb = sections.filter { $0[2] == 0 }.count, za = sections.filter { $0[5] == 0 }.count
        return 3 * (2 * ns + 1 - min(zb, za))
    }

    /// `sosfilt_zi`: steady-state initial conditions for a unit step.
    var zi: [[Double]] {
        var out: [[Double]] = []
        var scale = 1.0
        for s in sections {
            let b0 = s[0], b1 = s[1], b2 = s[2], a1 = s[4], a2 = s[5]
            let B0 = b1 - a1 * b0, B1 = b2 - a2 * b0
            let det = 1 + a1 + a2
            let z0 = (B0 + B1) / det
            let z1 = ((1 + a1) * B1 - a2 * B0) / det
            out.append([scale * z0, scale * z1])
            scale *= (b0 + b1 + b2) / (1 + a1 + a2)
        }
        return out
    }

    func filter(_ x: [Double], zi initial: [[Double]]) -> [Double] {
        var z = initial
        var y = [Double](repeating: 0, count: x.count)
        for n in 0..<x.count {
            var cur = x[n]
            for s in 0..<sections.count {
                let c = sections[s]
                let nx = c[0] * cur + z[s][0]
                z[s][0] = c[1] * cur - c[4] * nx + z[s][1]
                z[s][1] = c[2] * cur - c[5] * nx
                cur = nx
            }
            y[n] = cur
        }
        return y
    }

    /// SciPy `sosfiltfilt(sos, x)` with odd padding.
    func filtfilt(_ x: [Double]) -> [Double] {
        let edge = padlen
        guard x.count > edge else { return [Double](repeating: .nan, count: x.count) }
        let n = x.count
        var ext = [Double]()
        ext.reserveCapacity(n + 2 * edge)
        for i in stride(from: edge, through: 1, by: -1) { ext.append(2 * x[0] - x[i]) }
        ext += x
        for i in 1...edge { ext.append(2 * x[n - 1] - x[n - 1 - i]) }
        let z = zi
        var y = filter(ext, zi: z.map { $0.map { $0 * ext[0] } })
        y.reverse()
        let y0 = y[0]
        y = filter(y, zi: z.map { $0.map { $0 * y0 } })
        y.reverse()
        return Array(y[edge..<(edge + n)])
    }
}
