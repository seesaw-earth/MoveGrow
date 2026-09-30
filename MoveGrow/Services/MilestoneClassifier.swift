// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Lightweight temporal classifier over normalized 2D pose tracks.
/// It intentionally recognizes only movement patterns that can be inferred from
/// skeleton geometry alone. Scores are ranking signals, not probabilities.
enum MilestoneClassifier {
    static let version = "pose-events-v1"
    private static let confidenceFloor = 0.40
    private static let maxGap = 0.30
    private static let windowLength = 4.0
    private static let windowStep = 0.5

    private struct Vector {
        var x: Double
        var y: Double
        func distance(_ other: Vector) -> Double { hypot(x - other.x, y - other.y) }
    }

    private struct WindowScore {
        var start: Double
        var end: Double
        var score: Double
    }

    static func classify(samples: [MotionSample], duration: Double, aspect: Double) -> [MilestoneSuggestion] {
        guard duration > 0, !samples.isEmpty else { return [] }
        let frames = samples
            .filter { $0.time.isFinite && $0.time >= 0 && $0.time <= duration }
            .sorted { $0.time < $1.time }
        guard frames.count >= 8 else { return [] }

        var suggestions: [MilestoneSuggestion] = []
        if let best = bestWindow(duration: duration, scorer: { start, end in
            handsToMouthScore(frames: frames, start: start, end: end, aspect: aspect)
        }), best.score >= 0.72 {
            let clip = evidenceClip(around: (best.start + best.end) / 2, duration: duration)
            suggestions.append(MilestoneSuggestion(kind: .handsToMouth, start: clip.0, end: clip.1,
                                                   score: best.score, classifierVersion: version))
        }

        if let best = bestWindow(duration: duration, scorer: { start, end in
            bilateralMovementScore(frames: frames, start: start, end: end, aspect: aspect)
        }), best.score >= 0.64 {
            let clip = evidenceClip(around: (best.start + best.end) / 2, duration: duration)
            suggestions.append(MilestoneSuggestion(kind: .movesArmsAndLegs, start: clip.0, end: clip.1,
                                                   score: best.score, classifierVersion: version))
        }
        return suggestions.sorted { $0.score > $1.score }
    }

    private static func bestWindow(duration: Double, scorer: (Double, Double) -> Double) -> WindowScore? {
        let actualWindow = min(windowLength, duration)
        guard actualWindow >= 1.5 else { return nil }
        if duration <= actualWindow + 0.01 {
            return WindowScore(start: 0, end: duration, score: scorer(0, duration))
        }
        var best: WindowScore?
        var start = 0.0
        while start + actualWindow <= duration + 0.001 {
            let end = min(duration, start + actualWindow)
            let candidate = WindowScore(start: start, end: end, score: scorer(start, end))
            if best == nil || candidate.score > best!.score { best = candidate }
            start += windowStep
        }
        return best
    }

    private static func evidenceClip(around center: Double, duration: Double) -> (Double, Double) {
        let length = min(10.0, duration)
        var start = center - length / 2
        start = max(0, min(start, duration - length))
        return (start, min(duration, start + length))
    }

    private static func point(_ sample: MotionSample, _ key: String, aspect: Double) -> Vector? {
        guard sample.lightOK, let p = sample.points[key], p.confidence >= confidenceFloor,
              p.x.isFinite, p.y.isFinite, p.x >= 0, p.x <= 1, p.y >= 0, p.y <= 1 else { return nil }
        return Vector(x: p.x * aspect, y: p.y)
    }

    private static func torso(_ sample: MotionSample, aspect: Double) -> (origin: Vector, scale: Double)? {
        guard let ls = point(sample, "leftShoulder", aspect: aspect),
              let rs = point(sample, "rightShoulder", aspect: aspect),
              let lh = point(sample, "leftHip", aspect: aspect),
              let rh = point(sample, "rightHip", aspect: aspect) else { return nil }
        let shoulder = Vector(x: (ls.x + rs.x) / 2, y: (ls.y + rs.y) / 2)
        let hip = Vector(x: (lh.x + rh.x) / 2, y: (lh.y + rh.y) / 2)
        let scale = shoulder.distance(hip)
        guard scale >= 0.05 else { return nil }
        return (hip, scale)
    }

    private static func normalizedPoint(_ sample: MotionSample, _ key: String, aspect: Double) -> Vector? {
        guard let p = point(sample, key, aspect: aspect), let t = torso(sample, aspect: aspect) else { return nil }
        return Vector(x: (p.x - t.origin.x) / t.scale, y: (p.y - t.origin.y) / t.scale)
    }

    private static func frames(_ all: [MotionSample], start: Double, end: Double) -> [MotionSample] {
        all.filter { $0.time >= start && $0.time <= end }
    }

    private static func handsToMouthScore(frames all: [MotionSample], start: Double, end: Double, aspect: Double) -> Double {
        let window = frames(all, start: start, end: end)
        guard window.count >= 6 else { return 0 }
        var valid = 0
        var close = 0
        var weightedCloseness = 0.0
        var longestRun = 0.0
        var runStart: Double?
        var previousTime: Double?

        for sample in window {
            guard let nose = point(sample, "nose", aspect: aspect), let t = torso(sample, aspect: aspect) else {
                runStart = nil; previousTime = nil; continue
            }
            let distances = ["leftWrist", "rightWrist"].compactMap { key -> Double? in
                guard let wrist = point(sample, key, aspect: aspect) else { return nil }
                return wrist.distance(nose) / t.scale
            }
            guard let distance = distances.min() else { runStart = nil; previousTime = nil; continue }
            valid += 1
            // <=0.45 torso lengths is a strong hand-to-face geometry; 0.9 fades to zero.
            let proximity = max(0, min(1, (0.90 - distance) / 0.45))
            weightedCloseness += proximity
            let isClose = distance <= 0.68
            if isClose {
                close += 1
                if runStart == nil { runStart = sample.time }
                if let start = runStart { longestRun = max(longestRun, sample.time - start) }
            } else {
                runStart = nil
            }
            if let previousTime, sample.time - previousTime > maxGap { runStart = isClose ? sample.time : nil }
            previousTime = sample.time
        }
        let coverage = Double(valid) / Double(window.count)
        guard coverage >= 0.45, valid > 0 else { return 0 }
        let closeFraction = Double(close) / Double(valid)
        let proximity = weightedCloseness / Double(valid)
        let sustain = min(1, longestRun / 0.7)
        return clamp(0.30 * coverage + 0.30 * closeFraction + 0.25 * proximity + 0.15 * sustain)
    }

    private static func bilateralMovementScore(frames all: [MotionSample], start: Double, end: Double, aspect: Double) -> Double {
        let window = frames(all, start: start, end: end)
        guard window.count >= 8 else { return 0 }
        let keys = ["leftWrist", "rightWrist", "leftAnkle", "rightAnkle"]
        let limbScores = keys.map { movementScore(window: window, key: $0, aspect: aspect) }
        let coverage = limbScores.map(\.coverage).min() ?? 0
        guard coverage >= 0.45 else { return 0 }
        // Require all four distal limbs to contribute; the weakest limb limits the score.
        let weakest = limbScores.map(\.movement).min() ?? 0
        let mean = limbScores.map(\.movement).reduce(0, +) / Double(limbScores.count)
        return clamp(0.25 * coverage + 0.50 * weakest + 0.25 * mean)
    }

    private static func movementScore(window: [MotionSample], key: String, aspect: Double) -> (movement: Double, coverage: Double) {
        var positions: [(Double, Vector)] = []
        for sample in window {
            if let p = normalizedPoint(sample, key, aspect: aspect) { positions.append((sample.time, p)) }
        }
        let coverage = Double(positions.count) / Double(window.count)
        guard positions.count >= 4 else { return (0, coverage) }
        var speeds: [Double] = []
        var travel = 0.0
        for pair in zip(positions, positions.dropFirst()) {
            let dt = pair.1.0 - pair.0.0
            guard dt > 0, dt <= maxGap else { continue }
            let d = pair.0.1.distance(pair.1.1)
            guard d / dt < 8 else { continue }
            travel += d
            speeds.append(d / dt)
        }
        guard !speeds.isEmpty else { return (0, coverage) }
        let sorted = speeds.sorted()
        let p75 = sorted[Int(Double(sorted.count - 1) * 0.75)]
        // Both sustained travel and non-trivial speed help reject single-frame jitter.
        let speedScore = min(1, p75 / 0.38)
        let travelScore = min(1, travel / 0.70)
        return (clamp(0.60 * speedScore + 0.40 * travelScore), coverage)
    }

    private static func clamp(_ x: Double) -> Double { max(0, min(1, x)) }
}
