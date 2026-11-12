// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
//
// InstantHMR 3D track of one video, written by the analysis passes next to the 2D track as
// `<id>.hmr3d` (deleted with the memory) and exportable as JSON. Foundation only.
//
// Binary layout (little-endian): "MGH3", UInt32 header length, header JSON, UInt32 frame count T, then
// times Float64[T], valid UInt8[T], boxes Float32[T×5], joints2D Float32[T×70×2],
// joints3D Float32[T×70×3], sigma Float32[T×70]; from version 2 also yolo Float32[T×19×3]: YOLO26l-pose's
// own 2D keypoints of the same person (MoveGrow's 19 joints: x, y, confidence), for the YOLO pose page
// and comparison only — the analysis does not use them.

import Foundation

struct HMRTrackHeader: Codable, Equatable, Sendable {
    var format = "movegrow.hmr3d"
    var version = HMRTrack.currentVersion
    var estimator = "instanthmr-coreml"
    var network: String
    var fitCrops: Int
    var requestedFPS: Double
    var durationSeconds: Double
    /// Size of the analysed (upright, possibly downscaled) frames, pixels.
    var frameWidth: Double
    var frameHeight: Double
    /// Focal length in those pixels (InstantHMR's 1.05 × diagonal when the camera's is unknown).
    var focal: Double
    var complete: Bool
    var createdAt: Date = Date()
    var personSelection = "largest person box per frame (YOLO26l-pose), then InstantHMR"
    var joints2D = "normalized-top-left 0...1 of the displayed video"
    var joints3D = "metres, camera frame: x right, y down, z forward (InstantHMR keypoints_3d + cam_trans)"
    var sigma = "network 2D uncertainty, normalized by the frame's longer side"
    var yolo: String? = "YOLO26l-pose 2D keypoints of the same person (the box detector), MoveGrow's 19 joints, normalized display coordinates and confidence; for comparison, not used in the analysis"
    var yoloJointNames: [String]? = MJ.names
    var jointNames: [String] = MHR70.names
    var coco17FromMHR70: [Int] = MHR70.coco17
}

/// InstantHMR's result for one analysed frame, carried by AnalyzedFrame from the analysis thread
/// to the store. Nil on frames without a person.
struct HMRFramePayload: Sendable {
    var box: [Float]             // x, y, w, h (normalized, display), score
    var joints2D: [Float]        // 70 × 2, normalized display coordinates
    var joints3D: [Float]        // 70 × 3, metres, camera frame
    var sigma: [Float]           // 70, normalized by the frame's longer side
    /// YOLO26l-pose's own keypoints of the same person: 19 × 3 (MoveGrow joints; x, y, confidence).
    var yolo: [Float] = []
    var frameWidth: Float
    var frameHeight: Float
    var focal: Float
}

struct HMRTrack: Sendable {
    var header: HMRTrackHeader
    var times: [Double] = []
    var valid: [Bool] = []
    var boxes: [Float] = []        // T × 5: x, y, w, h (normalized), score
    var j2d: [Float] = []          // T × 70 × 2
    var j3d: [Float] = []          // T × 70 × 3
    var sigma: [Float] = []        // T × 70
    /// T × 19 × 3, YOLO's own 2D keypoints (version 2 files; empty in older ones).
    var yolo: [Float] = []

    static let J = 70
    static let currentVersion = 2
    /// Floats per frame in `yolo`.
    static let yoloWidth = MJ.count * 3
    var hasYOLO: Bool { yolo.count == count * Self.yoloWidth && count > 0 }
    var count: Int { times.count }
    var detectedCount: Int { valid.filter { $0 }.count }

    mutating func appendMissing(time: Double) {
        times.append(time)
        valid.append(false)
        boxes += [Float](repeating: .nan, count: 5)
        j2d += [Float](repeating: .nan, count: Self.J * 2)
        j3d += [Float](repeating: .nan, count: Self.J * 3)
        sigma += [Float](repeating: .nan, count: Self.J)
        yolo += Self.noYOLO
    }

    mutating func append(time: Double, box: [Float], joints2D: [Float], joints3D: [Float], sigma s: [Float],
                         yolo y: [Float] = []) {
        guard box.count == 5, joints2D.count == Self.J * 2, joints3D.count == Self.J * 3, s.count == Self.J else {
            appendMissing(time: time)
            return
        }
        times.append(time)
        valid.append(true)
        boxes += box
        j2d += joints2D
        j3d += joints3D
        sigma += s
        yolo += y.count == Self.yoloWidth ? y : Self.noYOLO
    }

    private static let noYOLO: [Float] = (0..<MJ.count).flatMap { _ in [Float.nan, .nan, 0] }

    /// YOLO's keypoint `j` (MoveGrow joint order) in frame `t`: normalized x, y and confidence.
    func yoloPoint(_ t: Int, _ j: Int) -> (x: Float, y: Float, c: Float) {
        guard hasYOLO else { return (.nan, .nan, 0) }
        let o = (t * MJ.count + j) * 3
        return (yolo[o], yolo[o + 1], yolo[o + 2])
    }

    /// YOLO's keypoints as a 2D track (for the skeleton overlay), or nil in files without them.
    func yoloTrack() -> PoseTrack? {
        guard hasYOLO, detectedCount > 0 else { return nil }
        var out = PoseTrack(header: PoseTrackHeader(poseEstimator: "yolo26l-pose (box detector of InstantHMR)",
                                                     processing: "raw", durationSeconds: header.durationSeconds,
                                                     analysisFrameRate: header.requestedFPS))
        out.reserve(count)
        for t in 0..<count {
            let o = t * Self.yoloWidth
            out.append(time: times[t], frameIndex: Int32(t), lightOK: true, joints: Array(yolo[o..<(o + Self.yoloWidth)]))
        }
        return out
    }

    func point2D(_ t: Int, _ j: Int) -> SIMD2<Float> { SIMD2(j2d[(t * Self.J + j) * 2], j2d[(t * Self.J + j) * 2 + 1]) }

    func point3D(_ t: Int, _ j: Int) -> SIMD3<Float> {
        let o = (t * Self.J + j) * 3
        return SIMD3(j3d[o], j3d[o + 1], j3d[o + 2])
    }

    /// Nearest frame to `time` that has a person, within `tolerance` seconds.
    func frame(near time: Double, tolerance: Double) -> Int? {
        guard !times.isEmpty, time.isFinite else { return nil }
        var lo = 0, hi = times.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if times[mid] < time { lo = mid + 1 } else { hi = mid }
        }
        var best: Int?
        for i in [lo - 1, lo] where i >= 0 && i < times.count && valid[i] {
            if best == nil || abs(times[i] - time) < abs(times[best!] - time) { best = i }
        }
        guard let best, abs(times[best] - time) <= tolerance else { return nil }
        return best
    }

    /// Half the typical 3D body extent (m) around the hips, for a steady scale in the 3D view.
    var typicalRadius: Float {
        var radii: [Float] = []
        let stride = max(1, count / 400)
        for t in Swift.stride(from: 0, to: count, by: stride) where valid[t] {
            let root = (point3D(t, MHR70.leftHip) + point3D(t, MHR70.rightHip)) / 2
            var r: Float = 0
            for j in 0..<Self.J {
                let d = point3D(t, j) - root
                let len = (d * d).sum().squareRoot()
                if len.isFinite { r = max(r, len) }
            }
            if r > 0 { radii.append(r) }
        }
        guard !radii.isEmpty else { return 1 }
        radii.sort()
        return max(0.1, radii[min(radii.count - 1, radii.count * 9 / 10)])
    }

    // MARK: smoothing (display only; the stored track is raw)

    /// One Euro filter (Casiez et al. 2012) forward over time, restarted after gaps longer than 0.5 s.
    func smoothed(minCutoff: Float = 1.0, beta: Float = 0.5, dCutoff: Float = 1.0) -> HMRTrack {
        var out = self
        func alpha(_ cutoff: Float, _ dt: Float) -> Float {
            let tau = 1 / (2 * Float.pi * cutoff)
            return 1 / (1 + tau / dt)
        }
        func run(_ values: inout [Float], width: Int, scale: Float) {
            var prev: [Float]? = nil
            var dprev = [Float](repeating: 0, count: width)
            var lastTime = 0.0
            for t in 0..<count {
                guard valid[t] else { continue }
                let o = t * width
                let x = Array(values[o..<(o + width)])
                if let p = prev, times[t] - lastTime <= 0.5, times[t] > lastTime {
                    let dt = Float(times[t] - lastTime)
                    let ad = alpha(dCutoff, dt)
                    var y = x
                    for i in 0..<width where x[i].isFinite && p[i].isFinite {
                        let d = (x[i] - p[i]) / dt
                        dprev[i] = ad * d + (1 - ad) * dprev[i]
                        let a = alpha(minCutoff + beta * abs(dprev[i]) / scale, dt)
                        y[i] = a * x[i] + (1 - a) * p[i]
                    }
                    values.replaceSubrange(o..<(o + width), with: y)
                    prev = y
                } else {
                    dprev = [Float](repeating: 0, count: width)
                    prev = x
                }
                lastTime = times[t]
            }
        }
        // 2D speeds in ~1/10 of the frame per second, 3D in metres per second.
        run(&out.j2d, width: Self.J * 2, scale: 0.1)
        run(&out.j3d, width: Self.J * 3, scale: 1)
        return out
    }

    // MARK: binary file

    private static let magic = Data("MGH3".utf8)

    func encoded() throws -> Data {
        var data = Self.magic
        let head = try LocalFiles.jsonEncoder().encode(header)
        Self.put(UInt32(head.count), &data)
        data.append(head)
        Self.put(UInt32(count), &data)
        times.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        data.append(contentsOf: valid.map { $0 ? UInt8(1) : UInt8(0) })
        // Version 2: the YOLO block always follows (NaN when it was not recorded).
        let y = hasYOLO ? yolo : (0..<count).flatMap { _ in Self.noYOLO }
        for a in [boxes, j2d, j3d, sigma, y] { a.withUnsafeBufferPointer { data.append(Data(buffer: $0)) } }
        return data
    }

    static func decode(_ data: Data) throws -> HMRTrack {
        var cursor = 0
        func take(_ n: Int) throws -> Data {
            guard n >= 0, cursor + n <= data.count else { throw CocoaError(.fileReadCorruptFile) }
            defer { cursor += n }
            return data.subdata(in: (data.startIndex + cursor)..<(data.startIndex + cursor + n))
        }
        func u32() throws -> Int {
            let d = try take(4)
            return Int(d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
        }
        func floats(_ n: Int) throws -> [Float] {
            let d = try take(n * 4)
            return d.withUnsafeBytes { raw in (0..<n).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) } }
        }
        guard try take(4) == magic else { throw CocoaError(.fileReadCorruptFile) }
        let header = try LocalFiles.jsonDecoder().decode(HMRTrackHeader.self, from: try take(try u32()))
        let n = try u32()
        var track = HMRTrack(header: header)
        let td = try take(n * 8)
        track.times = td.withUnsafeBytes { raw in (0..<n).map { raw.loadUnaligned(fromByteOffset: $0 * 8, as: Double.self) } }
        track.valid = try take(n).map { $0 != 0 }
        track.boxes = try floats(n * 5)
        track.j2d = try floats(n * J * 2)
        track.j3d = try floats(n * J * 3)
        track.sigma = try floats(n * J)
        if header.version >= 2 {
            track.yolo = try floats(n * yoloWidth)
            if !track.yolo.contains(where: { $0.isFinite }) { track.yolo = [] }
        }
        track.header.version = currentVersion
        return track
    }

    private static func put(_ v: UInt32, _ data: inout Data) {
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    // MARK: storage

    static func load(memoryID: UUID) -> HMRTrack? { load(file: PoseFiles.hmr(memoryID)) }

    static func load(file: String) -> HMRTrack? {
        guard let data = try? Data(contentsOf: LocalFiles.url(file)) else { return nil }
        return try? decode(data)
    }

    func save(memoryID: UUID) throws { try save(file: PoseFiles.hmr(memoryID)) }

    func save(file: String) throws {
        try LocalFiles.write(try encoded(), to: file)
    }

    // MARK: building from analysed frames

    /// The payload of frame `t` (nil when no person was found).
    func payload(_ t: Int) -> HMRFramePayload? {
        guard t >= 0, t < count, valid[t] else { return nil }
        let J = Self.J
        return HMRFramePayload(box: Array(boxes[(t * 5)..<(t * 5 + 5)]),
                               joints2D: Array(j2d[(t * J * 2)..<((t + 1) * J * 2)]),
                               joints3D: Array(j3d[(t * J * 3)..<((t + 1) * J * 3)]),
                               sigma: Array(sigma[(t * J)..<((t + 1) * J)]),
                               yolo: hasYOLO ? Array(yolo[(t * Self.yoloWidth)..<((t + 1) * Self.yoloWidth)]) : [],
                               frameWidth: Float(header.frameWidth), frameHeight: Float(header.frameHeight),
                               focal: Float(header.focal))
    }

    /// A track from (time, payload) entries, sorted by time and without duplicate times.
    /// `estimator` is the InstantHMR estimator ID of the pass (network, fit, frame-rate cap).
    static func make(entries: [(time: Double, payload: HMRFramePayload?)], estimator: String,
                     duration: Double, analysisFPS: Double, complete: Bool) -> HMRTrack? {
        guard entries.contains(where: { $0.payload != nil }) else { return nil }
        // Tracks from passes that did not record YOLO's keypoints (older versions) carry none.
        let anyYOLO = entries.contains { $0.payload?.yolo.count == yoloWidth }
        let config = HMRConfig(estimatorID: estimator)
        let first = entries.first(where: { $0.payload != nil })?.payload
        var header = HMRTrackHeader(network: config?.network ?? estimator, fitCrops: config?.fitCrops ?? 0,
                                    requestedFPS: analysisFPS, durationSeconds: duration,
                                    frameWidth: Double(first?.frameWidth ?? 0), frameHeight: Double(first?.frameHeight ?? 0),
                                    focal: Double(first?.focal ?? 0), complete: complete)
        header.estimator = estimator
        var track = HMRTrack(header: header)
        var seen = Set<Int64>()
        for e in entries.sorted(by: { $0.time < $1.time }) where seen.insert(AnalysisPlan.timeKey(e.time)).inserted {
            if let p = e.payload {
                track.append(time: e.time, box: p.box, joints2D: p.joints2D, joints3D: p.joints3D, sigma: p.sigma, yolo: p.yolo)
            } else {
                track.appendMissing(time: e.time)
            }
        }
        if !anyYOLO { track.yolo = [] }
        return track
    }

    /// All frames as (time, payload) entries, for merging passes.
    var entries: [(time: Double, payload: HMRFramePayload?)] {
        (0..<count).map { (time: times[$0], payload: payload($0)) }
    }

    // MARK: research export

    private struct ExportFrame: Encodable {
        var t: Double
        var person: Bool
        var box: [Float]?
        var joints2D: [[Float]]?
        var joints3D: [[Float]]?
        var sigma: [Float]?
        /// YOLO26l-pose's own 2D keypoints (MoveGrow's 19 joints: x, y, confidence), when recorded.
        var yolo2D: [[Float]]?
    }

    private struct ExportFile: Encodable {
        var header: HMRTrackHeader
        var frames: [ExportFrame]
    }

    /// Pretty JSON in a temporary folder (for the share sheet).
    func exportJSON(memoryID: UUID) throws -> URL {
        var frames: [ExportFrame] = []
        frames.reserveCapacity(count)
        func round4(_ v: Float) -> Float { (v * 10000).rounded() / 10000 }
        for t in 0..<count {
            guard valid[t] else {
                frames.append(ExportFrame(t: times[t], person: false))
                continue
            }
            frames.append(ExportFrame(
                t: times[t], person: true,
                box: Array(boxes[(t * 5)..<(t * 5 + 5)]).map(round4),
                joints2D: (0..<Self.J).map { let p = point2D(t, $0); return [round4(p.x), round4(p.y)] },
                joints3D: (0..<Self.J).map { let p = point3D(t, $0); return [round4(p.x), round4(p.y), round4(p.z)] },
                sigma: Array(sigma[(t * Self.J)..<((t + 1) * Self.J)]).map(round4),
                yolo2D: hasYOLO ? (0..<MJ.count).map { let p = yoloPoint(t, $0); return [round4(p.x), round4(p.y), round4(p.c)] } : nil))
        }
        let encoder = LocalFiles.jsonEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(memoryID).instanthmr3d.json")
        try encoder.encode(ExportFile(header: header, frames: frames)).write(to: url, options: .atomic)
        return url
    }
}
