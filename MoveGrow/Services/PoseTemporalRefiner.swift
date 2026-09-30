// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Light temporal cleanup for display/classification while preserving the raw
/// YOLO sequence separately. It interpolates only short gaps, then applies a
/// conservative One-Euro filter that relaxes smoothing during faster motion.
enum PoseTemporalRefiner {
    static let version = "short-gap+one-euro-v1"
    private static let confidenceFloor = 0.10
    private static let maximumInterpolationGap = 0.22
    private static let maximumFilterGap = 0.28
    private static let minCutoff = 2.2
    private static let beta = 0.045
    private static let derivativeCutoff = 1.0

    static func refine(_ input: [MotionSample]) -> [MotionSample] {
        guard input.count > 2 else { return input }
        var samples = input.sorted { $0.time < $1.time }
        interpolateShortGaps(&samples)
        smooth(&samples)
        return samples
    }

    private static func interpolateShortGaps(_ samples: inout [MotionSample]) {
        let keys = Set(samples.flatMap { $0.points.keys })
        for key in keys {
            var previousValid: Int?
            var index = 0
            while index < samples.count {
                if valid(samples[index].points[key]) {
                    if let left = previousValid, index > left + 1,
                       let a = samples[left].points[key], let b = samples[index].points[key] {
                        let gap = samples[index].time - samples[left].time
                        if gap > 0, gap <= maximumInterpolationGap {
                            for fill in (left + 1)..<index {
                                let t = (samples[fill].time - samples[left].time) / gap
                                guard t > 0, t < 1 else { continue }
                                samples[fill].points[key] = MotionPoint(
                                    x: a.x + (b.x - a.x) * t,
                                    y: a.y + (b.y - a.y) * t,
                                    confidence: min(a.confidence, b.confidence) * 0.82
                                )
                            }
                        }
                    }
                    previousValid = index
                }
                index += 1
            }
        }
    }

    private static func smooth(_ samples: inout [MotionSample]) {
        let keys = Set(samples.flatMap { $0.points.keys })
        for key in keys {
            var filter = OneEuro2D()
            for index in samples.indices {
                guard samples[index].lightOK, let point = samples[index].points[key], valid(point) else {
                    filter.reset()
                    continue
                }
                let filtered = filter.filter(x: point.x, y: point.y, time: samples[index].time)
                samples[index].points[key] = MotionPoint(
                    x: min(1, max(0, filtered.x)),
                    y: min(1, max(0, filtered.y)),
                    confidence: point.confidence
                )
            }
        }
    }

    private static func valid(_ point: MotionPoint?) -> Bool {
        guard let point else { return false }
        return point.confidence >= confidenceFloor && point.x.isFinite && point.y.isFinite &&
            point.x >= 0 && point.x <= 1 && point.y >= 0 && point.y <= 1
    }

    private struct OneEuro2D {
        var lastTime: Double?
        var rawX: Double?
        var rawY: Double?
        var filteredX: Double?
        var filteredY: Double?
        var derivativeX = 0.0
        var derivativeY = 0.0

        mutating func reset() {
            lastTime = nil; rawX = nil; rawY = nil; filteredX = nil; filteredY = nil
            derivativeX = 0; derivativeY = 0
        }

        mutating func filter(x: Double, y: Double, time: Double) -> (x: Double, y: Double) {
            guard let lastTime, let rawX, let rawY, let filteredX, let filteredY else {
                self.lastTime = time; self.rawX = x; self.rawY = y
                self.filteredX = x; self.filteredY = y
                return (x, y)
            }
            let dt = time - lastTime
            guard dt > 0, dt <= maximumFilterGap else {
                reset(); self.lastTime = time; self.rawX = x; self.rawY = y
                self.filteredX = x; self.filteredY = y
                return (x, y)
            }

            let derivativeAlpha = alpha(cutoff: derivativeCutoff, dt: dt)
            let dx = (x - rawX) / dt, dy = (y - rawY) / dt
            derivativeX += derivativeAlpha * (dx - derivativeX)
            derivativeY += derivativeAlpha * (dy - derivativeY)
            let speed = hypot(derivativeX, derivativeY)
            let cutoff = minCutoff + beta * speed
            let a = alpha(cutoff: cutoff, dt: dt)
            let fx = filteredX + a * (x - filteredX)
            let fy = filteredY + a * (y - filteredY)

            self.lastTime = time; self.rawX = x; self.rawY = y
            self.filteredX = fx; self.filteredY = fy
            return (fx, fy)
        }

        private func alpha(cutoff: Double, dt: Double) -> Double {
            let tau = 1 / (2 * Double.pi * max(0.0001, cutoff))
            return 1 / (1 + tau / dt)
        }
    }
}
