// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
//
// Reading and writing pose tracks. On device they are stored as compact binary `.mgpose`
// files (≈240 bytes per frame, decoded in milliseconds). Research JSON (PoseArchive) is produced
// only when the user exports it. Legacy v1.0 JSON files are still readable and are migrated.

import Foundation

enum PoseBridge {
    /// `MotionSample`s (dictionary based, used by the summary, overlay and clip renderer) from a track.
    static func samples(from track: PoseTrack) -> [MotionSample] {
        var out: [MotionSample] = []
        out.reserveCapacity(track.count)
        for t in 0..<track.count {
            var points: [String: MotionPoint] = [:]
            for j in 0..<MJ.count {
                let c = track.conf(t, j), x = track.x(t, j), y = track.y(t, j)
                guard c > 0, x.isFinite, y.isFinite else { continue }
                points[MJ.names[j]] = MotionPoint(x: Double(x), y: Double(y), confidence: Double(c))
            }
            var box: MotionBox?
            if track.hasBoxes {
                let b = track.boxes[(t * 5)..<(t * 5 + 5)].map(Double.init)
                if b[0].isFinite { box = MotionBox(x: b[0], y: b[1], width: b[2], height: b[3], confidence: b[4]) }
            }
            out.append(MotionSample(time: track.times[t], points: points, lightOK: track.lightOK[t], subjectBox: box))
        }
        return out
    }

    /// Joints of one sample as J × 3 floats in `MJ` order (missing joint: NaN, NaN, 0).
    static func joints(_ sample: MotionSample) -> [Float] {
        var j = [Float](repeating: .nan, count: MJ.count * 3)
        for k in 0..<MJ.count { j[k * 3 + 2] = 0 }
        for (name, p) in sample.points {
            guard let k = MJ.index[name], p.x.isFinite, p.y.isFinite, p.confidence > 0 else { continue }
            j[k * 3] = Float(p.x); j[k * 3 + 1] = Float(p.y); j[k * 3 + 2] = Float(p.confidence)
        }
        return j
    }

    static func track(from samples: [MotionSample], header: PoseTrackHeader, frameIndices: [Int32]? = nil) -> PoseTrack {
        var track = PoseTrack(header: header)
        track.reserve(samples.count)
        let withBoxes = samples.contains { $0.subjectBox != nil }
        for (i, s) in samples.enumerated() {
            var box: [Float]?
            if withBoxes {
                if let b = s.subjectBox { box = [b.x, b.y, b.width, b.height, b.confidence].map(Float.init) }
                else { box = [Float](repeating: .nan, count: 5) }
            }
            track.append(time: s.time, frameIndex: frameIndices?[i] ?? -1, lightOK: s.lightOK, joints: joints(s), box: box)
        }
        return track
    }

    /// Research JSON (PoseArchive) for export.
    static func archive(from track: PoseTrack) -> PoseArchive {
        var a = PoseArchive(durationSeconds: track.header.durationSeconds, frames: samples(from: track),
                            poseEstimator: track.header.poseEstimator, processing: track.header.processing)
        a.aspectRatio = track.header.aspectRatio
        a.captureFrameRate = track.header.captureFrameRate
        return a
    }
}

enum PoseStore {
    enum StoreError: LocalizedError {
        case missing
        var errorDescription: String? { tr("No pose data is stored for this video yet.") }
    }

    /// Reads `.mgpose`, or legacy `PoseArchive` / `[MotionSample]` JSON.
    static func load(_ url: URL) throws -> PoseTrack {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        if data.count >= 4, data.prefix(4) == Data(PoseBinary.magic) { return try PoseBinary.decode(data) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let archive = try? decoder.decode(PoseArchive.self, from: data) {
            let header = PoseTrackHeader(poseEstimator: archive.poseEstimator, processing: archive.processing ?? "unknown",
                                         durationSeconds: archive.durationSeconds, aspectRatio: archive.aspectRatio,
                                         captureFrameRate: archive.captureFrameRate)
            return PoseBridge.track(from: archive.frames.sorted { $0.time < $1.time }, header: header)
        }
        let frames = try JSONDecoder().decode([MotionSample].self, from: data).sorted { $0.time < $1.time }
        let header = PoseTrackHeader(poseEstimator: "unknown", processing: "unknown",
                                     durationSeconds: frames.last?.time ?? 0)
        return PoseBridge.track(from: frames, header: header)
    }

    static func encode(_ track: PoseTrack) throws -> Data { try PoseBinary.encode(track) }

    /// Best available raw (unsmoothed) track for a memory: binary first, then legacy JSON.
    static func rawURL(for id: UUID) -> URL? {
        for name in [PoseFiles.raw(id), PoseFiles.legacyRaw(id)] where LocalFiles.exists(name) { return LocalFiles.url(name) }
        return nil
    }

    /// Best available processed (One-Euro smoothed) track for a memory.
    static func processedURL(for id: UUID) -> URL? {
        for name in [PoseFiles.processed(id), PoseFiles.legacyProcessed(id)] where LocalFiles.exists(name) { return LocalFiles.url(name) }
        return nil
    }

    /// Research JSON (PoseArchive) generated on demand into a fresh temporary folder.
    static func exportJSON(id: UUID, raw: Bool) throws -> URL {
        guard let source = raw ? rawURL(for: id) : processedURL(for: id) else { throw StoreError.missing }
        let archive = PoseBridge.archive(from: try load(source))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(raw ? PoseFiles.exportRawJSON(id) : PoseFiles.exportProcessedJSON(id))
        try encoder.encode(archive).write(to: url, options: .atomic)
        return url
    }

    /// Converts a memory's legacy JSON files to `.mgpose` (verifying the result) and removes the JSON.
    @discardableResult
    static func migrateLegacy(_ id: UUID) throws -> Bool {
        var migrated = false
        for (legacy, binary) in [(PoseFiles.legacyRaw(id), PoseFiles.raw(id)), (PoseFiles.legacyProcessed(id), PoseFiles.processed(id))] {
            guard LocalFiles.exists(legacy), !LocalFiles.exists(binary) else { continue }
            let track = try load(LocalFiles.url(legacy))
            let data = try encode(track)
            guard try PoseBinary.decode(data).count == track.count else { continue }
            try LocalFiles.write(data, to: binary)
            LocalFiles.remove(legacy)
            migrated = true
        }
        return migrated
    }
}
