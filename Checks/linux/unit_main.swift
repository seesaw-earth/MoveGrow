// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
@main struct UnitHarness {
    static func main() throws {
        // plan
        for fps in [15.0, 24, 25, 29.97, 30, 59.94, 60, 120, 240] {
            let p = AnalysisPlan(nominalFPS: fps, duration: 60)
            print("plan", fps, p.fullStride, p.quickStride, String(format: "%.1f", p.quickFPS), String(format: "%.1f", p.fullFPS), p.needsDetailPass, p.frameCount(.quick), p.frameCount(.detail))
            let total = p.estimatedFrames
            let q = (0..<total).filter { p.includes(frame: $0, in: .quick) }.count
            let d = (0..<total).filter { p.includes(frame: $0, in: .detail) && !p.includes(frame: $0, in: .quick) }.count
            precondition(q == p.frameCount(.quick) && d == p.frameCount(.detail), "count mismatch")
        }
        // decoder: synthetic 640x640 model, portrait 720x1280 input
        let fields = 57, dets = 3
        var arr = [Double](repeating: 0, count: dets * fields)
        // person 0: box in model px; letterbox gain = min(640/1280, 640/720)=0.5 -> resized 360x640, padX = round((640-360)/2 - 0.1)=140
        arr[0] = 140 + 90; arr[1] = 100; arr[2] = 140 + 270; arr[3] = 500; arr[4] = 0.9; arr[5] = 0
        for k in 0..<17 { arr[6 + 3*k] = 140 + 180; arr[6 + 3*k + 1] = 300; arr[6 + 3*k + 2] = 0.8 }
        arr[fields + 4] = 0.05 // below threshold
        let out = YOLOPoseDecoder.decodeEnd2End(detections: dets, fields: fields, value: { arr[$0 * fields + $1] },
                                                confidenceThreshold: 0.16, input: (720, 1280), model: (640, 640))
        precondition(out.count == 1)
        let b = out[0].box
        print("box", b, "kp0", out[0].keypoints[0])
        precondition(abs(b.x - 0.25) < 1e-9 && abs(b.w - 0.5) < 1e-9 && abs(out[0].keypoints[0].x - 0.5) < 1e-9)
        let (j, box) = YOLOPoseDecoder.joints(from: YOLOPoseDecoder.largest(out))
        precondition(j[MJ.index["neck"]! * 3 + 2] > 0 && box != nil)
        // luminance on a synthetic BGRA buffer (left half black, right half white), orientation up
        let w = 64, h = 32
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in (w/2)..<w { for c in 0..<3 { px[(y*w + x)*4 + c] = 255 } } }
        let lum = px.withUnsafeBytes { FrameLuminance.bgra(base: $0.baseAddress!, width: w, height: h, bytesPerRow: w*4, orientation: .up, joints: [Float](repeating: .nan, count: 57)) }
        print("luma", lum)
        precondition(abs(lum - 0.5) < 0.05)
        // sample bridge + binary roundtrip + legacy JSON
        var samples: [MotionSample] = []
        for i in 0..<50 {
            samples.append(MotionSample(time: Double(i) / 15, points: ["nose": MotionPoint(x: 0.5, y: 0.2, confidence: 0.9), "leftWrist": MotionPoint(x: 0.3, y: 0.5, confidence: 0.6)], lightOK: i % 7 != 0, subjectBox: i % 2 == 0 ? MotionBox(x: 0.1, y: 0.1, width: 0.5, height: 0.6, confidence: 0.9) : nil))
        }
        let header = PoseTrackHeader(poseEstimator: "test", processing: "raw", durationSeconds: 50.0/15, aspectRatio: 9.0/16, captureFrameRate: 30)
        let track = PoseBridge.track(from: samples, header: header)
        let data = try PoseStore.encode(track)
        let back = try PoseBinary.decode(data)
        precondition(back.times == track.times && back.xyc.map(\.bitPattern) == track.xyc.map(\.bitPattern) && back.boxes.map(\.bitPattern) == track.boxes.map(\.bitPattern) && back.header == track.header && back.lightOK == track.lightOK)
        let s2 = PoseBridge.samples(from: back)
        precondition(s2.count == 50 && s2[0].points.count == 2 && s2[1].subjectBox == nil && s2[0].subjectBox != nil && s2[7].lightOK == false)
        let archive = PoseBridge.archive(from: back)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let json = try enc.encode(archive)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("h.poses.json")
        try json.write(to: tmp)
        let fromJSON = try PoseStore.load(tmp)
        precondition(fromJSON.count == 50 && fromJSON.header.aspectRatio == 9.0/16)
        print("binary bytes", data.count, "json bytes", json.count)
        // refiner + report + classifier on bridged samples still work
        let refined = PoseTemporalRefiner.refine(s2)
        _ = MovementEngine.report(samples: refined, duration: 3.3, aspect: 9.0/16)
        _ = MilestoneClassifier.classify(samples: refined, duration: 3.3, aspect: 9.0/16)
        // album round trip with v1.0 JSON (no new keys)
        let v10 = #"{"schemaVersion":1,"memories":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","date":700000000,"title":"t","duration":5,"filename":"a.mov","favorite":false,"note":""}],"moments":[],"deletedFiles":[]}"#
        let album = try JSONDecoder().decode(Album.self, from: Data(v10.utf8))
        precondition(album.memories[0].context == .supine && album.memories[0].motor == nil)
        // corrected age
        let cal = Calendar.current
        let birth = cal.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let due = cal.date(from: DateComponents(year: 2026, month: 2, day: 26))!
        let baby = Baby(name: "x", birthday: birth, dueDate: due)
        let on = cal.date(from: DateComponents(year: 2026, month: 5, day: 1))!
        print("age", baby.age(on: on), baby.analysisWeeks(on: on), baby.chronologicalWeeks(on: on))
        precondition(baby.analysisWeeks(on: on) < baby.chronologicalWeeks(on: on))
        try DateExportChecks.run()
        print("HARNESS OK")
    }
}
