// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

@main struct MovementEngineChecks {
    static func check(_ passed: @autoclosure () -> Bool, _ label: String) {
        guard passed() else { fatalError("FAILED: \(label)") }
        print("PASS: \(label)")
    }
    static func sample(time:Double, moving:Bool = false, offset:Double = 0, confidence:Double = 1) -> MotionSample {
        let xy:[String:(Double,Double)] = [
            "nose":(0.5,0.20),"leftShoulder":(0.38,0.35),"rightShoulder":(0.62,0.35),
            "leftElbow":(0.28,0.44),"rightElbow":(0.72,0.44),
            "leftWrist":(0.23 + (moving ? 0.08*sin(time*4) : 0),0.55),"rightWrist":(0.77,0.55),
            "leftHip":(0.42,0.60),"rightHip":(0.58,0.60),
            "leftKnee":(0.4,0.73),"rightKnee":(0.6,0.73),"leftAnkle":(0.38,0.87),"rightAnkle":(0.62,0.87)
        ]
        return MotionSample(time:time,points:xy.mapValues {MotionPoint(x:$0.0+offset,y:$0.1,confidence:confidence)},lightOK:true)
    }
    static func series(fps:Double,moving:Bool = false) -> [MotionSample] {
        (0...Int(6*fps)).map {sample(time:Double($0)/fps,moving:moving)}
    }
    static func run(_ frames:[MotionSample]) -> MovementReport {MovementEngine.report(samples:frames,duration:6,aspect:9.0/16)}
    static func main() throws {
        let empty = run([])
        check(empty.events.isEmpty && empty.limbs.allSatisfy {$0.observedSeconds == 0},"No poses never become normal activity")
        let still = run(series(fps:10))
        check(still.limbs.allSatisfy {abs($0.observedSeconds-6)<0.01 && $0.activeSeconds == 0},"Static visible limbs have observed time but no activity")
        let moving = run(series(fps:10,moving:true))
        check(moving.limbs[0].activeSeconds > 2 && !moving.events.isEmpty,"Moving wrist creates movement bouts")
        check(moving.limbs[1].activeSeconds == 0,"One moving limb does not activate the other")
        let low = run((0...60).map {sample(time:Double($0)/10,confidence:0.1)})
        check(low.limbs.allSatisfy {$0.observedSeconds == 0},"Low confidence excluded rather than counted as stillness")
        let occluded = run(series(fps:10,moving:true).map {frame in
            var f=frame
            if f.time >= 2 && f.time <= 4 {f.points.removeValue(forKey:"leftWrist")}
            return f
        })
        check(occluded.limbs[0].observedSeconds < 4,"Missing wrist reduces only valid coverage")
        check(abs(occluded.limbs[1].observedSeconds-6)<0.01,"Other limbs remain observable during unilateral occlusion")
        check(!occluded.events.contains {$0.limb == "Left arm" && $0.start < 2 && $0.end > 4},"Events never bridge occlusion")
        let gap = run(series(fps:10,moving:true).filter {$0.time < 2 || $0.time > 4})
        check(gap.limbs.allSatisfy {$0.observedSeconds < 4},"Dropped frames do not count as observed time")
        let translated = run((0...60).map {i in sample(time:Double(i)/10,offset:0.025*sin(Double(i)/10))})
        check(translated.limbs.allSatisfy {$0.activeSeconds == 0},"Common image translation is removed")
        let slowRate = run(series(fps:20,moving:true))
        check(abs(moving.limbs[0].activeSeconds-slowRate.limbs[0].activeSeconds)<0.8,"Time-based activity is similar at 10 and 20 Hz")
        let dark = run(series(fps:10,moving:true).map { f in var q=f;q.lightOK=false;return q })
        check(dark.events.isEmpty && dark.limbs.allSatisfy {$0.observedSeconds == 0},"Poor lighting excludes measurements")
        check(moving.events.allSatisfy {$0.start >= 0 && $0.end <= 6 && $0.end > $0.start},"Clip boundaries stay inside source video")
        let json = try JSONEncoder().encode(moving)
        let restored = try JSONDecoder().decode(MovementReport.self,from:json)
        check(restored == moving,"Report persists without losing clip references")

        let stillSuggestions = MilestoneClassifier.classify(samples:series(fps:10),duration:6,aspect:9.0/16)
        check(stillSuggestions.isEmpty,"Static pose does not create milestone suggestions")

        let handToMouth = series(fps:10).map { frame -> MotionSample in
            var f = frame
            if f.time >= 1 && f.time <= 4 {
                f.points["leftWrist"] = MotionPoint(x:0.49,y:0.26,confidence:0.95)
            }
            return f
        }
        let handSuggestions = MilestoneClassifier.classify(samples:handToMouth,duration:6,aspect:9.0/16)
        check(handSuggestions.contains {$0.kind == .handsToMouth},"Sustained wrist-to-face geometry suggests hands to mouth")

        let allLimbs = series(fps:10).map { frame -> MotionSample in
            var f = frame
            let t = frame.time
            f.points["leftWrist"] = MotionPoint(x:0.27 + 0.08*sin(t*4.2),y:0.55 + 0.04*cos(t*3.7),confidence:0.95)
            f.points["rightWrist"] = MotionPoint(x:0.73 + 0.08*cos(t*4.0),y:0.55 + 0.04*sin(t*3.9),confidence:0.95)
            f.points["leftAnkle"] = MotionPoint(x:0.40 + 0.06*sin(t*3.5),y:0.84 + 0.05*cos(t*4.1),confidence:0.95)
            f.points["rightAnkle"] = MotionPoint(x:0.60 + 0.06*cos(t*3.6),y:0.84 + 0.05*sin(t*4.0),confidence:0.95)
            return f
        }
        let limbSuggestions = MilestoneClassifier.classify(samples:allLimbs,duration:6,aspect:9.0/16)
        check(limbSuggestions.contains {$0.kind == .movesArmsAndLegs},"Movement across all four limbs suggests bilateral movement")
        check(limbSuggestions.allSatisfy {$0.start >= 0 && $0.end <= 6 && $0.end > $0.start},"Milestone evidence clips stay inside source video")

        var shortGap = series(fps:15,moving:true)
        let shortGapIndex = shortGap.firstIndex { abs($0.time - 2.0) < 0.02 }!
        shortGap[shortGapIndex].points.removeValue(forKey:"leftWrist")
        let shortGapRefined = PoseTemporalRefiner.refine(shortGap)
        check(shortGap[shortGapIndex].points["leftWrist"] == nil,"Raw pose sequence stays unchanged during refinement")
        check(shortGapRefined[shortGapIndex].points["leftWrist"] != nil,"Short pose gaps are interpolated for display/classification")

        var longGap = series(fps:15,moving:true)
        for i in longGap.indices where longGap[i].time >= 2.0 && longGap[i].time <= 2.5 {
            longGap[i].points.removeValue(forKey:"leftWrist")
        }
        let longGapRefined = PoseTemporalRefiner.refine(longGap)
        let longGapMiddle = longGapRefined.firstIndex { abs($0.time - 2.25) < 0.04 }!
        check(longGapRefined[longGapMiddle].points["leftWrist"] == nil,"Long occlusions are not fabricated by temporal refinement")
    }
}
