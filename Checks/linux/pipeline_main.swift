// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
@main struct PipelineHarness {
    static func main() throws {
        let root = ProcessInfo.processInfo.environment["MOVEGROW_ROOT"] ?? FileManager.default.currentDirectoryPath
        let res = URL(fileURLWithPath: root + "/MoveGrow/Motor/Resources")
        let book = try MotorRuleBook(rulesData: Data(contentsOf: res.appendingPathComponent("rules.json")),
                                     sourcesData: Data(contentsOf: res.appendingPathComponent("sources.json")))
        let fixture = try PoseBinary.decode(Data(contentsOf: URL(fileURLWithPath: root + "/Tests/MotorKitTests/Fixtures/tremor_bilateral_8hz_30fps.mgpose")))
        var all = AnalysisPipeline.frames(from: fixture)
        for i in all.indices { all[i].index = Int32(i) }
        let plan = AnalysisPlan(nominalFPS: 30, duration: 90)
        let quick = all.filter { plan.includes(frame: Int($0.index), in: .quick) }
        let id = UUID()
        let header = AnalysisPipeline.header(estimator: "test", processing: "raw", duration: 90, aspect: 9.0/16, captureFPS: 30, analysisFPS: plan.quickFPS)
        var t0 = Date()
        let q = try AnalysisPipeline.finishQuick(id: id, frames: quick, header: header, duration: 90, aspect: 9.0/16, book: book, ageWeeks: 2, context: .supine)
        print("quick: frames", quick.count, "ms", Int(Date().timeIntervalSince(t0) * 1000), "fs", q.motor!.context.fs,
              "fast_fine", q.motor!.findings.first { $0.ruleID == "rhythm.fast_fine" }!.status, "limbs", q.report.limbs.count, "sugg", q.suggestions.count)
        precondition(q.motor!.findings.first { $0.ruleID == "rhythm.fast_fine" }!.status == .abstained)
        // detail pass with a checkpoint in the middle
        let done = AnalysisPipeline.analysedTimeKeys(id: id)
        let detail = all.filter { plan.includes(frame: Int($0.index), in: .detail) && !done.contains(AnalysisPlan.timeKey($0.time)) }
        precondition(detail.count == all.count - quick.count, "detail \(detail.count)")
        AnalysisPipeline.writePartial(id: id, frames: Array(detail.prefix(500)), header: header)
        let resumedSkip = AnalysisPipeline.analysedTimeKeys(id: id)
        precondition(resumedSkip.count == quick.count + 500)
        let partial = AnalysisPipeline.loadPartial(id: id)
        let rest = detail.filter { !resumedSkip.contains(AnalysisPlan.timeKey($0.time)) }
        t0 = Date()
        let m = try AnalysisPipeline.finishDetail(id: id, newFrames: partial + rest, analysisFPS: 30, book: book, ageWeeks: 2, context: .supine)!
        let ff = m.findings.first { $0.ruleID == "rhythm.fast_fine" }!
        print("detail: ms", Int(Date().timeIntervalSince(t0) * 1000), "fs", m.context.fs, "fast_fine", ff.status, ff.events.first?.hz ?? -1)
        precondition(ff.status == .detected && abs(m.context.fs - 30) < 0.01)
        precondition(!LocalFiles.exists(PoseFiles.partial(id)))
        let raw = try PoseStore.load(LocalFiles.url(PoseFiles.raw(id)))
        precondition(raw.count == all.count)
        let rec = try AnalysisPipeline.recomputeMotor(id: id, book: book, ageWeeks: 2, context: .held, aspect: nil)!
        precondition(rec.findings.first { $0.ruleID == "rhythm.fast_fine" }!.status == .abstained)
        let loaded = AnalysisPipeline.loadMotor(id: id)!
        precondition(loaded.context.contextTag == "held")
        let sizes = [PoseFiles.raw(id), PoseFiles.processed(id), PoseFiles.motor(id)].map { (try? FileManager.default.attributesOfItem(atPath: LocalFiles.url($0).path)[.size] as? Int) ?? -1 }
        print("file sizes (raw, processed, motor):", sizes)
        // trends
        let s = loaded.summary
        let cal = Calendar.current
        let sessions = (0..<3).map { (date: cal.date(byAdding: .day, value: $0 * 4, to: Date())!, summary: s) }
        let trends = MotorLongitudinal.trends(sessions: sessions, book: book)
        print("trends:", trends.count, trends.filter(\.persistent).map(\.ruleID))
        // Review digest: stored with each pass, agrees with the fixtures' known patterns.
        let digest = AnalysisPipeline.digest(id: id, aspect: 9.0 / 16)!
        precondition(LocalFiles.exists(PoseFiles.review(id)) && digest.count > 0 && digest.bin >= 0.25 && abs(digest.analysisFPS - 30) < 0.1)
        precondition(digest.speed.count == 4 && digest.angleRange.count == 4 && digest.trackedFraction > 0.9)
        let reread = try JSONDecoder().decode(ReviewDigest.self, from: Data(contentsOf: LocalFiles.url(PoseFiles.review(id))))
        precondition(reread == digest, "digest round trip")
        print("digest: bins", digest.count, "bin", digest.bin, "active", digest.activeFraction.mapValues { Int($0 * 100) },
              "bytes", (try? Data(contentsOf: LocalFiles.url(PoseFiles.review(id))).count) ?? -1)
        func fixtureDigest(_ name: String) throws -> ReviewDigest {
            let t = try PoseBinary.decode(Data(contentsOf: URL(fileURLWithPath: root + "/Tests/MotorKitTests/Fixtures/\(name).mgpose")))
            return MotorDigestBuilder.make(track: t, aspect: 9.0 / 16)!
        }
        let asym = try fixtureDigest("asym_left_arm_20w")
        print("asym_left_arm: armBalance", asym.armBalance ?? .nan, "legBalance", asym.legBalance ?? .nan)
        let sk = asym.session
        precondition(sk.activeFraction.count == 4 && sk.medianSpeed.count == 4 && (sk.armBalance ?? 0) < -0.2 && sk.motionMedian != nil)
        let skData = try JSONEncoder().encode(sk)
        let skBack = try JSONDecoder().decode(SessionKinematics.self, from: skData)
        precondition(skBack == sk)
        print("session summary bytes:", skData.count)
        precondition((asym.armBalance ?? 0) < -0.2, "left arm moves less → negative arm balance")
        let head = try fixtureDigest("head_pref_right")
        print("head_pref_right: headTurn", head.headTurn.map { Int($0 * 100) })
        precondition(head.headTurn[2] > head.headTurn[0] + 0.3, "head mostly turned right")
        let still = try fixtureDigest("baseline_30fps")
        let kick = try fixtureDigest("rhythmic_kicking_bilateral")
        print("motion median baseline vs kicking:", MM.nanMedian(still.motion.values.map(Double.init)), MM.nanMedian(kick.motion.values.map(Double.init)))
        let tic = Date()
        let long = try fixtureDigest("baseline_60fps_20w")
        print("digest 60 fps:", long.count, "bins in", Int(Date().timeIntervalSince(tic) * 1000), "ms")
        for f in PoseFiles.all(id) { LocalFiles.remove(f) }
        print("PIPELINE OK")
    }
}
