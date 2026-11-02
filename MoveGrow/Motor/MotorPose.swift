// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
//
// Pose storage for the motor engine: a compact struct-of-arrays track, the binary `.mgpose`
// file format used on device, and the uniformly resampled series the rules run on.

import Foundation

/// Joint order shared by `BodyJoint.allCases`, the `.mgpose` format and the Python reference.
enum MJ {
    static let names = [
        "nose", "leftEye", "rightEye", "leftEar", "rightEar", "neck", "root",
        "leftShoulder", "rightShoulder", "leftElbow", "rightElbow", "leftWrist", "rightWrist",
        "leftHip", "rightHip", "leftKnee", "rightKnee", "leftAnkle", "rightAnkle",
    ]
    static let count = names.count
    static let index: [String: Int] = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($1, $0) })
    static let nose = 0, leftEye = 1, rightEye = 2, leftEar = 3, rightEar = 4
    static let leftShoulder = 7, rightShoulder = 8, leftElbow = 9, rightElbow = 10
    static let leftWrist = 11, rightWrist = 12, leftHip = 13, rightHip = 14
    static let leftKnee = 15, rightKnee = 16, leftAnkle = 17, rightAnkle = 18
}

/// Metadata stored in the `.mgpose` header (JSON).
struct PoseTrackHeader: Codable, Equatable {
    var format = "movegrow.pose.binary"
    var schemaVersion = 3
    var poseEstimator: String
    var processing: String
    var durationSeconds: Double
    var aspectRatio: Double?
    var captureFrameRate: Double?
    var analysisFrameRate: Double?
    var coordinateSystem = "normalized-top-left"
    var jointSchema = "coco17-plus-derived-neck-root"
    var subjectSelection = "largest-person-box-per-frame"
    var jointNames: [String] = MJ.names
}

/// Struct-of-arrays pose track. `xyc` holds T × J × (x, y, confidence) as Float32; a missing
/// joint is (NaN, NaN, 0). `boxes` is empty or T × 5 (x, y, w, h, confidence; NaN if none).
struct PoseTrack: Equatable {
    var header: PoseTrackHeader
    var times: [Double] = []
    var frameIndices: [Int32] = []
    var lightOK: [Bool] = []
    var xyc: [Float] = []
    var boxes: [Float] = []

    var count: Int { times.count }
    var hasBoxes: Bool { !boxes.isEmpty }

    init(header: PoseTrackHeader) { self.header = header }

    mutating func reserve(_ n: Int) {
        times.reserveCapacity(n); frameIndices.reserveCapacity(n); lightOK.reserveCapacity(n)
        xyc.reserveCapacity(n * MJ.count * 3)
    }

    /// Append one frame. `joints` must hold J × 3 floats in `MJ` order.
    mutating func append(time: Double, frameIndex: Int32, lightOK ok: Bool, joints: [Float], box: [Float]? = nil) {
        precondition(joints.count == MJ.count * 3)
        times.append(time); frameIndices.append(frameIndex); lightOK.append(ok)
        xyc.append(contentsOf: joints)
        if let box {
            if boxes.isEmpty && count > 1 { boxes = [Float](repeating: .nan, count: (count - 1) * 5) }
            boxes.append(contentsOf: box.count == 5 ? box : [Float](repeating: .nan, count: 5))
        } else if !boxes.isEmpty {
            boxes.append(contentsOf: [Float](repeating: .nan, count: 5))
        }
    }

    @inline(__always) func x(_ t: Int, _ j: Int) -> Float { xyc[(t * MJ.count + j) * 3] }
    @inline(__always) func y(_ t: Int, _ j: Int) -> Float { xyc[(t * MJ.count + j) * 3 + 1] }
    @inline(__always) func conf(_ t: Int, _ j: Int) -> Float { xyc[(t * MJ.count + j) * 3 + 2] }

    /// Frames sorted by time (stable), returning a new track.
    func sortedByTime() -> PoseTrack {
        let order = times.indices.sorted { times[$0] < times[$1] || (times[$0] == times[$1] && $0 < $1) }
        if order == Array(times.indices) { return self }
        var out = PoseTrack(header: header)
        out.reserve(count)
        for i in order {
            let s = i * MJ.count * 3
            out.append(time: times[i], frameIndex: frameIndices[i], lightOK: lightOK[i],
                       joints: Array(xyc[s..<(s + MJ.count * 3)]),
                       box: hasBoxes ? Array(boxes[(i * 5)..<(i * 5 + 5)]) : nil)
        }
        return out
    }
}

enum PoseBinaryError: Error, Equatable {
    case badMagic, unsupportedVersion(Int), truncated, jointMismatch
}

/// `.mgpose` codec (little-endian). See Research/motor-rules/motor_rules/mgpose.py.
enum PoseBinary {
    static let magic: [UInt8] = Array("MGPS".utf8)

    static func encode(_ track: PoseTrack) throws -> Data {
        let headerData = try JSONEncoder().encode(track.header)
        let J = MJ.count
        var out = Data()
        out.reserveCapacity(20 + headerData.count + track.count * (16 + J * 12 + (track.hasBoxes ? 20 : 0)))
        out.append(contentsOf: magic)
        appendLE(&out, UInt16(1)); appendLE(&out, UInt16(J))
        appendLE(&out, UInt32(track.count)); appendLE(&out, UInt32(track.hasBoxes ? 1 : 0))
        appendLE(&out, UInt32(headerData.count))
        out.append(headerData)
        for t in 0..<track.count {
            appendLE(&out, track.times[t].bitPattern)
            appendLE(&out, UInt32(bitPattern: track.frameIndices[t]))
            out.append(track.lightOK[t] ? 1 : 0); out.append(contentsOf: [0, 0, 0])
            let base = t * J * 3
            for k in 0..<(J * 3) { appendLE(&out, track.xyc[base + k].bitPattern) }
            if track.hasBoxes { for k in 0..<5 { appendLE(&out, track.boxes[t * 5 + k].bitPattern) } }
        }
        return out
    }

    static func decode(_ data: Data) throws -> PoseTrack {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> PoseTrack in
            guard raw.count >= 20 else { throw PoseBinaryError.truncated }
            guard Array(raw[0..<4]) == magic else { throw PoseBinaryError.badMagic }
            let version = Int(readLE(raw, 4, UInt16.self))
            guard version == 1 else { throw PoseBinaryError.unsupportedVersion(version) }
            let J = Int(readLE(raw, 6, UInt16.self))
            let T = Int(readLE(raw, 8, UInt32.self))
            let flags = readLE(raw, 12, UInt32.self)
            let H = Int(readLE(raw, 16, UInt32.self))
            guard J == MJ.count else { throw PoseBinaryError.jointMismatch }
            let hasBox = flags & 1 == 1
            let frameSize = 16 + J * 12 + (hasBox ? 20 : 0)
            guard raw.count >= 20 + H + T * frameSize else { throw PoseBinaryError.truncated }
            let header = try JSONDecoder().decode(PoseTrackHeader.self, from: Data(raw[20..<(20 + H)]))
            var track = PoseTrack(header: header)
            track.times = [Double](repeating: 0, count: T)
            track.frameIndices = [Int32](repeating: -1, count: T)
            track.lightOK = [Bool](repeating: true, count: T)
            track.xyc = [Float](repeating: 0, count: T * J * 3)
            if hasBox { track.boxes = [Float](repeating: .nan, count: T * 5) }
            var off = 20 + H
            for t in 0..<T {
                track.times[t] = Double(bitPattern: readLE(raw, off, UInt64.self))
                track.frameIndices[t] = Int32(bitPattern: readLE(raw, off + 8, UInt32.self))
                track.lightOK[t] = raw[off + 12] != 0
                off += 16
                for k in 0..<(J * 3) { track.xyc[t * J * 3 + k] = Float(bitPattern: readLE(raw, off + 4 * k, UInt32.self)) }
                off += J * 12
                if hasBox {
                    for k in 0..<5 { track.boxes[t * 5 + k] = Float(bitPattern: readLE(raw, off + 4 * k, UInt32.self)) }
                    off += 20
                }
            }
            return track
        }
    }

    private static func appendLE<T: FixedWidthInteger>(_ data: inout Data, _ v: T) {
        withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func readLE<T: FixedWidthInteger>(_ raw: UnsafeRawBufferPointer, _ offset: Int, _: T.Type) -> T {
        var v: T = 0
        withUnsafeMutableBytes(of: &v) { dst in
            for i in 0..<MemoryLayout<T>.size { dst[i] = raw[offset + i] }
        }
        return T(littleEndian: v)
    }
}

/// Uniformly resampled pose series in normalized image coordinates (reference `PoseSeries`).
struct MotorSeries {
    var t: [Double]
    var x: [[Double]]      // [joint][frame], NaN where invalid
    var y: [[Double]]
    var conf: [[Double]]   // [joint][frame]
    var lightOK: [Bool]
    var fs: Double
    var aspect: Double
    var aspectAssumed: Bool

    var count: Int { t.count }
    var duration: Double { count > 1 ? t[count - 1] - t[0] : 0 }

    static let defaultPortraitAspect = 9.0 / 16.0

    /// Port of `load_archive`: confidence floor, uniform grid at the median frame interval,
    /// linear interpolation that never bridges gaps longer than `maxGap`.
    init?(track input: PoseTrack, aspect: Double? = nil, confFloor: Double = 0.30, maxGap: Double = 0.12) {
        let track = input.sortedByTime()
        let T0 = track.count, J = MJ.count
        guard T0 >= 3 else { return nil }
        let ts = track.times
        var xs = [[Double]](repeating: [Double](repeating: .nan, count: T0), count: J)
        var ys = xs
        var cs = [[Double]](repeating: [Double](repeating: 0, count: T0), count: J)
        for f in 0..<T0 {
            for j in 0..<J {
                let c = Double(track.conf(f, j)), px = Double(track.x(f, j)), py = Double(track.y(f, j))
                guard c > 0, px.isFinite else { continue }
                cs[j][f] = c.isFinite ? c : 0
                if c >= confFloor, px >= 0, px <= 1, py >= 0, py <= 1 {
                    xs[j][f] = px; ys[j][f] = py
                }
            }
        }
        var dt: [Double] = []
        for i in 1..<T0 { let d = ts[i] - ts[i - 1]; if d > 0, d.isFinite { dt.append(d) } }
        guard !dt.isEmpty else { return nil }
        let fs = 1.0 / MM.median(dt)
        let step = 1.0 / fs
        let n = Int(((ts[T0 - 1] + 1e-9 - ts[0]) / step).rounded(.up))
        // NumPy arange fills start + i * ((start + step) - start)
        let delta = (ts[0] + step) - ts[0]
        let grid = (0..<n).map { $0 == 1 ? ts[0] + step : ts[0] + Double($0) * delta }

        func interpGaps(_ src: [Double]) -> [Double] {
            let okIdx = src.indices.filter { src[$0].isFinite }
            guard okIdx.count >= 2 else { return [Double](repeating: .nan, count: grid.count) }
            let tsOk = okIdx.map { ts[$0] }, ysOk = okIdx.map { src[$0] }
            var out = MM.interp(grid, tsOk, ysOk, left: .nan, right: .nan)
            for (k, tq) in grid.enumerated() {
                let i = min(max(MM.searchSortedLeft(tsOk, tq), 1), tsOk.count - 1)
                let exact = abs(tsOk[i] - tq) < 1e-6
                if tsOk[i] - tsOk[i - 1] > maxGap, !exact { out[k] = .nan }
            }
            return out
        }
        var gx = [[Double]](), gy = [[Double]](), gc = [[Double]]()
        for j in 0..<J {
            let ix = interpGaps(xs[j]), iy = interpGaps(ys[j])
            var c = MM.interp(grid, ts, cs[j])
            for k in 0..<grid.count where !ix[k].isFinite { c[k] = 0 }
            gx.append(ix); gy.append(iy); gc.append(c)
        }
        let light = MM.interp(grid, ts, track.lightOK.map { $0 ? 1.0 : 0.0 }).map { $0 > 0.5 }
        let asp = aspect ?? track.header.aspectRatio
        self.t = grid; self.x = gx; self.y = gy; self.conf = gc; self.lightOK = light; self.fs = fs
        self.aspect = asp ?? Self.defaultPortraitAspect
        self.aspectAssumed = asp == nil
    }
}
