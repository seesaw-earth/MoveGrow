// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
//
// CPU-side steps that follow pose extraction: building and storing tracks, smoothing, the movement
// summary, milestone suggestions and the motor observations. Foundation only; always called off
// the main thread.

import Foundation

enum AnalysisPipeline {
    struct QuickOutput {
        var report: MovementReport
        var suggestions: [MilestoneSuggestion]
        var motor: MotorReport?
    }

    static func header(estimator: String, processing: String, duration: Double, aspect: Double,
                       captureFPS: Double, analysisFPS: Double) -> PoseTrackHeader {
        PoseTrackHeader(poseEstimator: estimator, processing: processing, durationSeconds: duration,
                        aspectRatio: aspect, captureFrameRate: captureFPS, analysisFrameRate: analysisFPS)
    }

    static func track(_ frames: [AnalyzedFrame], header: PoseTrackHeader) -> PoseTrack {
        var t = PoseTrack(header: header)
        t.reserve(frames.count)
        let withBoxes = frames.contains { $0.box != nil }
        for f in frames.sorted(by: { $0.time < $1.time }) {
            t.append(time: f.time, frameIndex: f.index, lightOK: f.lightOK, joints: f.joints,
                     box: withBoxes ? (f.box ?? [Float](repeating: .nan, count: 5)) : nil)
        }
        return t
    }

    static func frames(from track: PoseTrack) -> [AnalyzedFrame] {
        let stride = MJ.count * 3
        return (0..<track.count).map { t in
            AnalyzedFrame(index: track.frameIndices[t], time: track.times[t],
                          joints: Array(track.xyc[(t * stride)..<((t + 1) * stride)]),
                          box: track.hasBoxes ? Array(track.boxes[(t * 5)..<(t * 5 + 5)]) : nil,
                          lightOK: track.lightOK[t])
        }
    }

    /// Whether an estimator's 2D track gets the One-Euro refiner. It is tuned for YOLO; the Vision
    /// fallback (as in v1.0) and InstantHMR (a body model fitted every frame, already steady) are kept as is.
    static func usesRefiner(_ estimator: String) -> Bool {
        !estimator.hasPrefix("apple-vision") && !PoseEngine.isInstantHMR(estimator)
    }

    /// Smoothed (One-Euro) companion of a raw track, for display, summary and suggestions.
    static func processed(_ raw: PoseTrack) -> (track: PoseTrack, samples: [MotionSample]) {
        if !usesRefiner(raw.header.poseEstimator) {
            var header = raw.header
            header.processing = "none"
            var track = raw
            track.header = header
            return (track, PoseBridge.samples(from: raw))
        }
        let samples = PoseTemporalRefiner.refine(PoseBridge.samples(from: raw))
        var header = raw.header
        header.processing = PoseTemporalRefiner.version
        return (PoseBridge.track(from: samples, header: header, frameIndices: raw.frameIndices.count == samples.count ? raw.frameIndices : nil), samples)
    }

    static func motor(raw: PoseTrack, book: MotorRuleBook?, ageWeeks: Double?, context: RecordingContext,
                      aspect: Double?) -> MotorReport? {
        guard let book else { return nil }
        // Research-status rules (lower validation) run only in Research/motor-rules, not in the app.
        return MotorEngine(book: book).analyze(MotorEngineInput(track: raw, ageWeeks: ageWeeks, context: context.rawValue,
                                                                aspect: aspect, includeResearch: false))
    }

    static func saveMotor(_ report: MotorReport?, id: UUID) throws {
        guard let report else { return }
        try LocalFiles.write(LocalFiles.jsonEncoder().encode(report), to: PoseFiles.motor(id))
    }

    // MARK: review digest

    static func saveDigest(_ digest: ReviewDigest?, id: UUID) {
        guard let digest, let data = try? JSONEncoder().encode(digest) else { return }
        try? LocalFiles.write(data, to: PoseFiles.review(id))
    }

    /// The stored digest, or one made now from the tracks (older memories), then stored.
    static func digest(id: UUID, aspect: Double?) -> ReviewDigest? {
        if let data = try? Data(contentsOf: LocalFiles.url(PoseFiles.review(id))),
           let d = try? JSONDecoder().decode(ReviewDigest.self, from: data), d.version == ReviewDigest.currentVersion {
            return d
        }
        guard let url = PoseStore.rawURL(for: id), let raw = try? PoseStore.load(url) else { return nil }
        let d = makeDigest(id: id, raw: raw, aspect: aspect ?? raw.header.aspectRatio)
        saveDigest(d, id: id)
        return d
    }

    /// Kinematics of a memory: from InstantHMR's 3D track when the memory was analysed with it
    /// (HMRKinematics), otherwise from the 2D track (MotorDigestBuilder).
    static func makeDigest(id: UUID, raw: PoseTrack, aspect: Double?) -> ReviewDigest? {
        if PoseEngine.isInstantHMR(raw.header.poseEstimator), let hmr = HMRTrack.load(memoryID: id), hmr.detectedCount > 0 {
            var light: [Int64: Bool] = [:]
            for i in 0..<raw.count { light[AnalysisPlan.timeKey(raw.times[i])] = raw.lightOK[i] }
            if let d = HMRKinematics.digest(hmr, lightOK: light) { return d }
        }
        return MotorDigestBuilder.make(track: raw, aspect: aspect)
    }

    /// Writes (or extends) the memory's 3D track from analysed frames; no-op for 2D engines.
    static func saveHMR(id: UUID, frames: [AnalyzedFrame], existing: HMRTrack?, header: PoseTrackHeader) throws {
        guard PoseEngine.isInstantHMR(header.poseEstimator) else { return }
        let entries = (existing?.entries ?? []) + frames.map { (time: $0.time, payload: $0.hmr) }
        guard let track = HMRTrack.make(entries: entries, estimator: header.poseEstimator, duration: header.durationSeconds,
                                        analysisFPS: header.analysisFrameRate ?? 30, complete: true) else { return }
        try track.save(memoryID: id)
    }

    static func loadMotor(id: UUID) -> MotorReport? {
        guard let data = try? Data(contentsOf: LocalFiles.url(PoseFiles.motor(id))) else { return nil }
        return try? LocalFiles.jsonDecoder().decode(MotorReport.self, from: data)
    }

    /// After the quick pass: store tracks, compute the summary, suggestions and observations.
    static func finishQuick(id: UUID, frames: [AnalyzedFrame], header: PoseTrackHeader, duration: Double, aspect: Double,
                            book: MotorRuleBook?, ageWeeks: Double?, context: RecordingContext) throws -> QuickOutput {
        let raw = track(frames, header: header)
        try LocalFiles.write(PoseBinary.encode(raw), to: PoseFiles.raw(id))
        try saveHMR(id: id, frames: frames, existing: nil, header: header)
        let (proc, samples) = processed(raw)
        try LocalFiles.write(PoseBinary.encode(proc), to: PoseFiles.processed(id))
        let report = MovementEngine.report(samples: samples, duration: duration, aspect: aspect)
        let suggestions = MilestoneClassifier.classify(samples: samples, duration: duration, aspect: aspect)
        let motor = Self.motor(raw: raw, book: book, ageWeeks: ageWeeks, context: context, aspect: aspect)
        try saveMotor(motor, id: id)
        saveDigest(makeDigest(id: id, raw: raw, aspect: aspect), id: id)
        return QuickOutput(report: report, suggestions: suggestions, motor: motor)
    }

    /// After the detail pass: merge, store full-rate tracks and recompute the observations.
    static func finishDetail(id: UUID, newFrames: [AnalyzedFrame], analysisFPS: Double, book: MotorRuleBook?,
                             ageWeeks: Double?, context: RecordingContext) throws -> MotorReport? {
        let existing = try PoseStore.load(LocalFiles.url(PoseFiles.raw(id)))
        var seen = Set(existing.times.map(AnalysisPlan.timeKey))
        var all = frames(from: existing)
        for f in newFrames where seen.insert(AnalysisPlan.timeKey(f.time)).inserted { all.append(f) }
        var header = existing.header
        header.analysisFrameRate = analysisFPS
        let raw = track(all, header: header)
        try LocalFiles.write(PoseBinary.encode(raw), to: PoseFiles.raw(id))
        try saveHMR(id: id, frames: newFrames, existing: HMRTrack.load(memoryID: id), header: header)
        try LocalFiles.write(PoseBinary.encode(processed(raw).track), to: PoseFiles.processed(id))
        let motor = Self.motor(raw: raw, book: book, ageWeeks: ageWeeks, context: context, aspect: header.aspectRatio)
        try saveMotor(motor, id: id)
        saveDigest(makeDigest(id: id, raw: raw, aspect: header.aspectRatio), id: id)
        LocalFiles.remove(PoseFiles.partial(id))
        LocalFiles.remove(PoseFiles.hmrPartial(id))
        partialLock.lock(); lastHMRPartial[id] = nil; partialLock.unlock()
        return motor
    }

    /// Re-run only the rule engine (context or age changed, rules updated, legacy data).
    static func recomputeMotor(id: UUID, book: MotorRuleBook?, ageWeeks: Double?, context: RecordingContext,
                               aspect: Double?) throws -> MotorReport? {
        guard let url = PoseStore.rawURL(for: id) else { return nil }
        let raw = try PoseStore.load(url)
        let report = Self.motor(raw: raw, book: book, ageWeeks: ageWeeks, context: context, aspect: aspect ?? raw.header.aspectRatio)
        try saveMotor(report, id: id)
        return report
    }

    private static let partialLock = NSLock()
    private static var lastHMRPartial: [UUID: Date] = [:]

    /// Detail-pass checkpoint. The 3D frames (much larger) are written at most once a minute; frames
    /// whose 3D missed the last checkpoint are simply analysed again on resume (loadPartial).
    static func writePartial(id: UUID, frames: [AnalyzedFrame], header: PoseTrackHeader) {
        guard !frames.isEmpty, let data = try? PoseBinary.encode(track(frames, header: header)) else { return }
        try? LocalFiles.write(data, to: PoseFiles.partial(id))
        guard PoseEngine.isInstantHMR(header.poseEstimator) else { return }
        partialLock.lock()
        let due = Date().timeIntervalSince(lastHMRPartial[id] ?? .distantPast) >= 60
        if due { lastHMRPartial[id] = Date() }
        partialLock.unlock()
        guard due, let hmr = HMRTrack.make(entries: frames.map { (time: $0.time, payload: $0.hmr) }, estimator: header.poseEstimator,
                                           duration: header.durationSeconds, analysisFPS: header.analysisFrameRate ?? 30,
                                           complete: false) else { return }
        try? hmr.save(file: PoseFiles.hmrPartial(id))
    }

    static func loadPartial(id: UUID) -> [AnalyzedFrame] {
        guard let t = try? PoseStore.load(LocalFiles.url(PoseFiles.partial(id))) else { return [] }
        let all = frames(from: t)
        guard PoseEngine.isInstantHMR(t.header.poseEstimator) else { return all }
        // InstantHMR: keep only frames whose 3D was checkpointed too (outer nil = not checkpointed).
        var payloads: [Int64: HMRFramePayload?] = [:]
        if let hmr = HMRTrack.load(file: PoseFiles.hmrPartial(id)) {
            for i in 0..<hmr.count { payloads[AnalysisPlan.timeKey(hmr.times[i])] = .some(hmr.payload(i)) }
        }
        return all.compactMap { f -> AnalyzedFrame? in
            guard let payload = payloads[AnalysisPlan.timeKey(f.time)] else { return nil }
            var g = f
            g.hmr = payload
            return g
        }
    }

    /// Time keys of frames already analysed (raw track + detail checkpoint).
    static func analysedTimeKeys(id: UUID) -> Set<Int64> {
        var keys = Set<Int64>()
        if let url = PoseStore.rawURL(for: id), let t = try? PoseStore.load(url) { keys.formUnion(t.times.map(AnalysisPlan.timeKey)) }
        keys.formUnion(loadPartial(id: id).map { AnalysisPlan.timeKey($0.time) })
        return keys
    }
}
