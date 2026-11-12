// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
//
// Progressive frame selection. Every video is analysed at its own frame rate (every frame), or at
// InstantHMR's frame-rate setting (30 by default) when that engine analyses it.
// Pass 1 ("quick") takes about 15 frames per second first, so the review appears within seconds;
// pass 2 ("detail") then fills in all remaining frames — without redoing any frame from pass 1.

import Foundation

/// One analysed video frame (MJ joint order, J × (x, y, confidence); missing joint = NaN, NaN, 0).
struct AnalyzedFrame {
    var index: Int32
    var time: Double
    var joints: [Float]
    var box: [Float]?
    var lightOK: Bool
    /// InstantHMR's 3D result (InstantHMR engine only; nil without a person or with YOLO).
    var hmr: HMRFramePayload? = nil
}

struct AnalysisPlan: Equatable {
    var nominalFPS: Double
    /// Every `fullStride`-th decoded frame belongs to the full-rate set (1: native frame rate).
    var fullStride: Int
    /// Every `quickStride`-th decoded frame (a multiple of `fullStride`) is analysed in pass 1.
    var quickStride: Int
    var estimatedFrames: Int

    static let quickTargetFPS = 15.0
    /// No cap: the full pass uses the video's native frame rate.
    static let fullMaxFPS = Double.infinity
    /// Rhythm (spectral) checks need at least this analysed rate.
    static let rhythmMinFPS = 24.0

    /// `maxFPS` caps the full-rate pass (InstantHMR's frame-rate setting); the default is no cap.
    init(nominalFPS raw: Double, duration: Double, maxFPS: Double = AnalysisPlan.fullMaxFPS) {
        let fps = (raw.isFinite && raw > 1) ? raw : 30
        nominalFPS = fps
        fullStride = maxFPS.isFinite && maxFPS > 0 ? max(1, Int((fps / maxFPS - 0.02).rounded(.up))) : 1
        let fullRate = fps / Double(fullStride)
        quickStride = fullStride * max(1, Int((fullRate / Self.quickTargetFPS).rounded(.toNearestOrEven)))
        estimatedFrames = max(1, Int((duration * fps).rounded()))
    }

    var quickFPS: Double { nominalFPS / Double(quickStride) }
    var fullFPS: Double { nominalFPS / Double(fullStride) }
    /// A detail pass is useful only when it raises the rate to something the rhythm checks accept.
    var needsDetailPass: Bool { quickStride > fullStride && fullFPS >= Self.rhythmMinFPS }

    enum Pass: String { case quick, detail }

    /// Pass membership by decoded-frame ordinal. The detail pass covers every full-rate frame;
    /// frames already analysed (by time key) are skipped by the runner, so legacy v1.0 tracks
    /// sampled by timestamp are filled in correctly too.
    func includes(frame k: Int, in pass: Pass) -> Bool {
        switch pass {
        case .quick: return k % quickStride == 0
        case .detail: return k % fullStride == 0
        }
    }

    func frameCount(_ pass: Pass) -> Int {
        let total = estimatedFrames
        let quick = (total + quickStride - 1) / quickStride
        switch pass {
        case .quick: return quick
        case .detail: return max(0, (total + fullStride - 1) / fullStride - quick)
        }
    }

    /// Key used to recognise frames already analysed (also matches legacy v1.0 samples by time).
    static func timeKey(_ t: Double) -> Int64 { Int64((t * 1000).rounded()) }
}

/// Exponentially smoothed throughput → remaining-time estimate for the progress UI.
struct ThroughputEstimator {
    private var rate: Double?          // frames per second of wall time
    private var lastTime: Double?
    private var lastDone = 0

    mutating func update(done: Int, now: Double) {
        guard let lt = lastTime else { lastTime = now; lastDone = done; return }
        guard now - lt >= 0.5 else { return }                    // measure over ≥ 0.5 s windows
        if done > lastDone {
            let r = Double(done - lastDone) / (now - lt)
            rate = rate.map { 0.7 * $0 + 0.3 * r } ?? r
        }
        lastTime = now; lastDone = done
    }

    func remainingSeconds(remainingFrames: Int) -> Double? {
        guard let rate, rate > 0 else { return nil }
        return Double(remainingFrames) / rate
    }

    var framesPerSecond: Double? { rate }
}

struct AnalysisProgress: Equatable {
    enum Phase: Equatable { case preparing, quick, saving, detail, finishing }
    var phase: Phase
    var fraction: Double
    var remainingSeconds: Double?
    var paused = false
    /// Analysis throughput (frames per wall-clock second), for batch time estimates.
    var framesPerSecond: Double? = nil

    var title: String {
        switch phase {
        case .preparing: return tr("Preparing")
        case .quick: return tr("Tracking")
        case .saving: return tr("Saving")
        case .detail: return tr("Refining")
        case .finishing: return tr("Finishing")
        }
    }

    var etaText: String? {
        if paused { return tr("Paused") }
        return remainingSeconds.flatMap(Self.eta)
    }

    /// Time left: "< 10 s", "25 s", "4 min".
    static func eta(_ s: Double) -> String? {
        guard s.isFinite, s >= 0 else { return nil }
        if s < 10 { return tr("< 10 s") }
        if s < 60 { return tr("%lld s", Int((s / 5).rounded()) * 5) }
        return tr("%lld min", Int((s / 60).rounded(.up)))
    }
}

/// Progress of the videos recorded or imported together.
struct BatchProgress: Equatable {
    var ids: [UUID]
    var finished: Int
    var fraction: Double
    var remainingSeconds: Double?
    var currentID: UUID?
    var paused = false

    var total: Int { ids.count }
    var isComplete: Bool { finished >= total }
    /// "3/10 · 4 min"
    var shortText: String {
        if isComplete { return "\(total)/\(total)" }
        let eta = paused ? tr("Paused") : remainingSeconds.flatMap(AnalysisProgress.eta)
        return ["\(min(finished + 1, total))/\(total)", eta].compactMap { $0 }.joined(separator: " · ")
    }
}

/// The pose model stopped producing output mid-pass (for example, the Neural Engine was not
/// available while the app was in the background). Retryable: nothing is stored as "no body".
struct AnalysisInterrupted: Error {}

/// Thread-safe cancellation, pause (camera open) and thermal throttling shared by analysis threads.
final class AnalysisControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var paused = false

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    var isPaused: Bool { lock.lock(); defer { lock.unlock() }; return paused }

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func reset() { lock.lock(); cancelled = false; lock.unlock() }
    func setPaused(_ value: Bool) { lock.lock(); paused = value; lock.unlock() }

    /// Called between frames on an analysis thread (never on the main thread or the Swift
    /// concurrency pool): waits while paused, backs off when the device is hot.
    func waitIfNeeded() {
        while isPaused && !isCancelled { Thread.sleep(forTimeInterval: 0.15) }
        #if canImport(Darwin)
        switch ProcessInfo.processInfo.thermalState {
        case .critical:
            while ProcessInfo.processInfo.thermalState == .critical && !isCancelled { Thread.sleep(forTimeInterval: 0.5) }
        case .serious:
            Thread.sleep(forTimeInterval: 0.04)
        default:
            break
        }
        #endif
    }
}
