// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

struct MotionPoint: Codable, Hashable {
    var x: Double
    var y: Double
    var confidence: Double
}
struct MotionBox: Codable, Hashable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var confidence: Double
}
struct MotionSample: Codable {
    var time: Double
    var points: [String: MotionPoint]
    var lightOK: Bool
    var subjectBox: MotionBox? = nil
}
// Independent of Vision/SwiftUI; values are descriptive engineering defaults,
// not developmental or diagnostic thresholds. Units: torso lengths / second.
enum MovementEngine {
    static let minimumConfidence = 0.28
    static let maximumGap = 0.25
    static let activityOn = 0.18
    static let activityOff = 0.10
    static let minimumBout = 0.4
    static let limbs: [(String, String, String, String)] = [
        ("Left arm", "leftShoulder", "leftElbow", "leftWrist"),
        ("Right arm", "rightShoulder", "rightElbow", "rightWrist"),
        ("Left leg", "leftHip", "leftKnee", "leftAnkle"),
        ("Right leg", "rightHip", "rightKnee", "rightAnkle")
    ]
    private struct Vector {
        var x: Double; var y: Double
        func distance(_ v: Vector) -> Double { hypot(x-v.x, y-v.y) }
    }
    private static func point(_ sample: MotionSample, _ key: String, aspect: Double) -> Vector? {
        guard sample.lightOK, let p = sample.points[key], p.confidence >= minimumConfidence,
              p.x.isFinite, p.y.isFinite, p.x >= 0.08, p.x <= 0.92, p.y >= 0.08, p.y <= 0.92 else { return nil }
        return Vector(x: p.x * aspect, y: p.y)
    }
    private static func torso(_ sample: MotionSample, aspect: Double) -> (Vector, Double)? {
        guard let ls = point(sample,"leftShoulder",aspect:aspect), let rs = point(sample,"rightShoulder",aspect:aspect),
              let lh = point(sample,"leftHip",aspect:aspect), let rh = point(sample,"rightHip",aspect:aspect) else { return nil }
        let shoulder = Vector(x:(ls.x+rs.x)/2,y:(ls.y+rs.y)/2)
        let hip = Vector(x:(lh.x+rh.x)/2,y:(lh.y+rh.y)/2)
        let scale = shoulder.distance(hip)
        guard scale >= 0.06 else { return nil }
        return (hip,scale)
    }
    private static func position(_ s: MotionSample, key: String, aspect: Double) -> Vector? {
        guard let p = point(s,key,aspect:aspect), let (origin,scale) = torso(s,aspect:aspect) else { return nil }
        return Vector(x:(p.x-origin.x)/scale,y:(p.y-origin.y)/scale)
    }
    private static func angle(_ s: MotionSample, limb: (String,String,String,String), aspect: Double) -> Double? {
        guard let a = point(s,limb.1,aspect:aspect), let b = point(s,limb.2,aspect:aspect), let c = point(s,limb.3,aspect:aspect) else { return nil }
        let u = Vector(x:a.x-b.x,y:a.y-b.y), v = Vector(x:c.x-b.x,y:c.y-b.y)
        let denom = hypot(u.x,u.y)*hypot(v.x,v.y)
        guard denom > 0.00001 else { return nil }
        return acos(max(-1,min(1,(u.x*v.x+u.y*v.y)/denom))) * 180 / .pi
    }
    private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[Int(Double(sorted.count-1)*fraction)]
    }
    static func report(samples: [MotionSample], duration: Double, aspect: Double) -> MovementReport {
        let frames = samples.filter { $0.time.isFinite && $0.time >= 0 && $0.time <= duration }.sorted { $0.time < $1.time }
        var results: [LimbSummary] = [], events: [MovementEvent] = []
        var head = 0.0, full = 0.0
        if frames.count > 1 {
            for i in 1..<frames.count {
                let a = frames[i-1], b = frames[i], dt = b.time-a.time
                guard dt > 0, dt <= maximumGap else { continue }
                if point(a,"nose",aspect:aspect) != nil && point(b,"nose",aspect:aspect) != nil { head += dt }
                let keys = ["nose","leftShoulder","rightShoulder","leftHip","rightHip","leftWrist","rightWrist","leftAnkle","rightAnkle"]
                if keys.allSatisfy({ point(a,$0,aspect:aspect) != nil && point(b,$0,aspect:aspect) != nil }) { full += dt }
            }
        }
        for limb in limbs {
            var observed = 0.0, active = 0.0
            var speeds: [Double] = [], angles: [Double] = []
            var smooth: Vector?, previousRaw: Vector?, previousTime: Double?
            var boutStart: Double?, lastActive = 0.0, moving = false
            func finish() {
                if let start = boutStart, lastActive-start >= minimumBout {
                    events.append(MovementEvent(limb:limb.0,start:start,end:lastActive))
                }
                boutStart = nil; moving = false
            }
            for s in frames {
                guard let current = position(s,key:limb.3,aspect:aspect), angle(s,limb:limb,aspect:aspect) != nil else {
                    finish(); smooth = nil; previousRaw = nil; previousTime = nil; continue
                }
                guard let t = previousTime, let old = smooth, let raw = previousRaw else {
                    smooth = current; previousRaw = current; previousTime = s.time; continue
                }
                let dt = s.time-t
                guard dt > 0, dt <= maximumGap, current.distance(raw)/dt < 8 else {
                    finish(); smooth = current; previousRaw = current; previousTime = s.time; continue
                }
                // Time-dependent low-pass filter, reset across missing intervals.
                let alpha = 1-exp(-dt/0.12)
                let filtered = Vector(x:old.x+alpha*(current.x-old.x),y:old.y+alpha*(current.y-old.y))
                let speed = filtered.distance(old)/dt
                observed += dt; speeds.append(speed)
                if let a = angle(s,limb:limb,aspect:aspect) { angles.append(a) }
                let isActive = speed >= (moving ? activityOff : activityOn)
                if isActive {
                    active += dt
                    if boutStart == nil { boutStart = t }
                    lastActive = s.time; moving = true
                } else if s.time-lastActive >= 0.2 { finish() }
                smooth = filtered; previousRaw = current; previousTime = s.time
            }
            finish()
            results.append(LimbSummary(name:limb.0,observedSeconds:observed,activeSeconds:active,
                medianSpeed:percentile(speeds,0.5), angleRange: observed >= 3 ? percentile(angles,0.95)-percentile(angles,0.05) : nil))
        }
        let usable = results.filter { $0.observedSeconds >= 3 }
        let activeNames = usable.filter { $0.activeSeconds >= 0.5 }.map { $0.name.lowercased() }
        let summary: String
        if usable.isEmpty { summary = "We couldn’t see enough continuous movement data to create a summary. Your video is saved." }
        else if activeNames.isEmpty { summary = "Little movement was detected during the parts we could observe. This describes this recording only." }
        else { summary = "Movement was observed in the \(activeNames.joined(separator: ", ")). Tap a movement clip to see it in your video." }
        let note = full >= duration*0.9 && duration >= 3
            ? "Head and limb landmarks were visible for most of this recording."
            : "Some parts were not clear enough to analyze. Unseen time is excluded, not counted as stillness."
        return MovementReport(duration:duration,limbs:results,headVisibleSeconds:head,fullBodySeconds:full,
            events:events.sorted { $0.start < $1.start },summary:summary,qualityNote:note)
    }
}
