// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
// End-to-end checks of the analysis queue, storage and background handling (Linux, fake video/model).
import Foundation
import UIKit
import BackgroundTasks

@MainActor func wait(_ label: String, timeout: Double = 120, _ cond: () -> Bool) async {
    let start = Date()
    while !cond() {
        if Date().timeIntervalSince(start) > timeout {
            let s = LocalStore.shared
            print("STATE job=\(String(describing: s.currentJob)) pending=\(s.pendingIDs) analyzing=\(s.analyzing) suspended=\(s.analysisSuspended)")
            print("  attempted=\(s.attemptedSteps) runs=\(FakeEnv.runs.map { "\($0.id) \($0.pass) \($0.frames)" })")
            for m in s.album.memories { print("  mem \(m.filename) stage=\(String(describing: m.analysisStage)) err=\(m.analysisError ?? "-") pose=\(m.poseStorage ?? "-") motor=\(m.motor != nil)") }
            print("  progress=\(s.monitor.progress) ruleBook=\(s.ruleBook != nil)")
            fatalError("TIMEOUT: \(label)")
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    print(String(format: "  ✓ %@ (%.2f s)", label, Date().timeIntervalSince(start)))
}

func check(_ ok: Bool, _ label: String) {
    guard ok else { fatalError("FAILED: \(label)") }
    print("  ✓ \(label)")
}

@MainActor func makeVideo(_ fixture: String, _ name: String) throws -> URL {
    try LocalFiles.prepare()
    let t = try PoseBinary.decode(Data(contentsOf: FakeEnv.fixtures.appendingPathComponent("\(fixture).mgpose")))
    let url = LocalFiles.url(name)
    try "fixture:\(fixture):\(t.header.durationSeconds)".write(to: url, atomically: true, encoding: .utf8)
    return url
}

@main struct StoreHarness {
    @MainActor static func main() async throws {
        setvbuf(stdout, nil, _IONBF, 0)
        BackgroundWork.register()
        let store = LocalStore.shared
        check(!store.recoveryRequired, "fresh album opens")
        try store.setBaby(Baby(name: "Test", birthday: Date().addingTimeInterval(-10 * 7 * 86_400)))
        store.appDidBecomeActive()

        print("A. record → quick → detail (continued task on iOS 26 path)")
        let id1 = try await store.saveRecording(url: try makeVideo("tremor_bilateral_8hz_30fps", "recording-1.mov"), context: .supine)
        check(store.analyzing.contains(id1), "queued at once")
        await wait("quick results for video 1") { store.memory(id1)?.analysisStage != nil }
        var m1 = store.memory(id1)!
        check(m1.analysisStage == .quick && m1.report != nil && m1.motor != nil && m1.poseStorage == "mgpose1", "quick stage stored")
        check(m1.thumbnail == "\(id1).jpg", "thumbnail written on save")
        check(m1.motor?.ageWeeks != nil && m1.motor?.rulesFingerprint == store.rulesFingerprint, "summary carries age and rules fingerprint")
        check(BGTaskScheduler.shared.submitted.contains { $0 is BGContinuedProcessingTaskRequest }, "continued-processing task submitted for a user recording")
        await wait("detail pass running on video 1") { (store.monitor.progress[id1]?.phase == .detail) && (store.monitor.progress[id1]?.fraction ?? 0) > 0.72 }
        check(store.monitor.progress[id1]?.remainingSeconds != nil, "ETA estimated")
        let continued = BGTaskScheduler.shared.lastContinued
        check((continued?.progress.completedUnitCount ?? 0) > 650, "continued task shows batch progress (\(continued?.progress.completedUnitCount ?? -1)/1000)")

        check(store.monitor.batch?.total == 1 && (store.monitor.batch?.fraction ?? 0) > 0.4, "batch progress tracks the video (\(store.monitor.batch?.shortText ?? "-"))")

        print("B. a new recording pre-empts the detail pass")
        let id2 = try await store.saveRecording(url: try makeVideo("baseline_30fps", "recording-2.mov"), context: .supine)
        await wait("quick results for video 2") { store.memory(id2)?.analysisStage != nil }
        check(store.memory(id1)?.analysisStage == .quick, "video 1 detail not finished yet (was pre-empted)")
        check(LocalFiles.exists(PoseFiles.partial(id1)) || FakeEnv.runs.contains { $0.id == "recording-1.mov" && $0.pass == "detail" }, "pre-empted pass checkpointed")
        await wait("both videos complete", timeout: 240) {
            store.memory(id1)?.analysisStage == .complete && store.memory(id2)?.analysisStage == .complete && store.analyzing.isEmpty
        }
        check(store.monitor.batch?.isComplete == true && store.monitor.batch?.total == 2, "batch of two complete")
        let detailRuns = FakeEnv.runs.filter { $0.id == "recording-1.mov" && $0.pass == "detail" }
        check(detailRuns.count >= 2 && detailRuns.last!.skipped > 1350, "video 1 detail resumed from checkpoint (runs: \(detailRuns.map { "\($0.frames)/skip \($0.skipped)" }))")
        let r1 = await store.motorReport(for: id1)!
        let ff = r1.findings.first { $0.ruleID == "rhythm.fast_fine" }!
        check(ff.status == .detected && abs(r1.context.fs - 30) < 0.1, "8 Hz tremor detected at 30 fps after merge")
        let raw1 = try PoseStore.load(PoseStore.rawURL(for: id1)!)
        check(raw1.count == 2700 && Set(raw1.times.map(AnalysisPlan.timeKey)).count == 2700, "merged track has every frame once")
        check(!LocalFiles.exists(PoseFiles.partial(id1)), "checkpoint removed after merge")
        check(store.monitor.progress.isEmpty, "no stale progress left")
        check(store.monitor.finished?.stage == .complete, "finish signal published")
        check(continued?.completed == true, "continued task completed")
        check(UIApplication.shared.open.isEmpty, "no background task left open")
        let k1 = store.memory(id1)?.kinematics
        check(k1?.activeFraction.count == 4 && abs((k1?.analysisFPS ?? 0) - 30) < 0.1 && (k1?.trackedFraction ?? 0) > 0.9,
              "kinematics summary stored from the full-rate pass")
        var cleared = store.memory(id2)!
        cleared.kinematics = nil
        try store.update(cleared)
        store.backfillKinematics()
        await wait("kinematics backfilled") { store.memory(id2)?.kinematics != nil && !store.backfilling }
        let r2 = await store.motorReport(for: id2)!
        check(r2.findings.filter { $0.status == .detected && $0.severity >= .note }.isEmpty, "baseline video: nothing of note")

        print("C. context change re-runs only the rules")
        let runsBefore = FakeEnv.runs.count
        store.setContext(.held, for: id1)
        await wait("observations for 'held'") { store.memory(id1)?.motor?.contextTag == "held" }
        let held = await store.motorReport(for: id1)!
        check(held.findings.first { $0.ruleID == "posture.head_preference" }?.status == .abstained, "posture check abstains when held")
        check(FakeEnv.runs.count == runsBefore, "no video pass re-run")

        print("D. due date → corrected age → refreshed observations")
        m1 = store.memory(id1)!
        let ageBefore = m1.motor?.ageWeeks ?? -1
        var baby = store.album.baby!
        baby.dueDate = baby.birthday.addingTimeInterval(6 * 7 * 86_400)
        try store.setBaby(baby)
        await wait("ages updated") {
            store.album.memories.allSatisfy { m in m.motor.map { abs(($0.ageWeeks ?? -1) - (ageBefore - 6)) < 0.1 } ?? true }
        }

        print("E. v1.0 memory: JSON migration, then detailed check on request")
        let legacyVideo = try makeVideo("coarse_5hz_left_arm", "legacy.mov")
        let legacyID = UUID()
        let full = try PoseBinary.decode(Data(contentsOf: FakeEnv.fixtures.appendingPathComponent("coarse_5hz_left_arm.mgpose")))
        let fifteen = AnalysisPipeline.frames(from: full).enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
        let legacyHeader = PoseTrackHeader(poseEstimator: YOLOPoseModelProvider.estimatorID, processing: "raw", durationSeconds: full.header.durationSeconds)
        let legacyTrack = AnalysisPipeline.track(fifteen, header: legacyHeader)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        var legacyArchive = PoseBridge.archive(from: legacyTrack)
        legacyArchive.aspectRatio = nil
        try enc.encode(legacyArchive).write(to: LocalFiles.url(PoseFiles.legacyRaw(legacyID)))
        try enc.encode(legacyArchive).write(to: LocalFiles.url(PoseFiles.legacyProcessed(legacyID)))
        let samples = PoseBridge.samples(from: legacyTrack)
        var legacy = Memory(id: legacyID, date: Date(), title: "Old", duration: full.header.durationSeconds, filename: legacyVideo.lastPathComponent)
        legacy.report = MovementEngine.report(samples: samples, duration: legacy.duration, aspect: 9.0 / 16)
        legacy.poseEstimator = YOLOPoseModelProvider.estimatorID
        var next = store.album; next.memories.append(legacy); try store.commit(next)
        store.resumePending()
        await wait("legacy migrated") { store.memory(legacyID)?.poseStorage == "mgpose1" }
        let lm = store.memory(legacyID)!
        check(!LocalFiles.exists(PoseFiles.legacyRaw(legacyID)) && LocalFiles.exists(PoseFiles.raw(legacyID)), "JSON replaced by binary track")
        check(lm.detailDeferred == nil && lm.motor != nil, "15 fps observations present; full-rate pass follows automatically")
        await wait("legacy full-rate pass complete") { store.memory(legacyID)?.analysisStage == .complete && store.analyzing.isEmpty }
        let lr = await store.motorReport(for: legacyID)!
        check(abs(lr.context.fs - 30) < 0.1, "legacy track filled to 30 fps")
        check(lr.findings.first { $0.ruleID == "rhythm.coarse" }?.status == .detected, "coarse 5 Hz shaking found after detail pass")

        print("F. delete during analysis")
        let id3 = try await store.saveRecording(url: try makeVideo("frog_leg", "recording-3.mov"))
        await wait("video 3 quick pass running") { (store.monitor.progress[id3]?.fraction ?? 0) > 0.2 && store.monitor.progress[id3]?.phase == .quick }
        try store.deleteMemory(id3)
        await wait("queue idle after delete") { store.analyzing.isEmpty && store.currentJob == nil }
        try? await Task.sleep(nanoseconds: 300_000_000)
        check(store.memory(id3) == nil && PoseFiles.all(id3).allSatisfy { !LocalFiles.exists($0) } && !LocalFiles.exists("recording-3.mov"), "memory and files gone")

        print("G. background time runs out mid-detail, resumes when active")
        let id4 = try await store.saveRecording(url: try makeVideo("rhythmic_kicking_bilateral", "recording-4.mov"))
        await wait("video 4 detail running") { store.monitor.progress[id4]?.phase == .detail && (store.monitor.progress[id4]?.fraction ?? 0) > 0.65 }
        UIApplication.shared.applicationState = .background
        BGTaskScheduler.shared.lastContinued?.expirationHandler?()
        await wait("suspended") { store.analysisSuspended && store.currentJob == nil }
        try? await Task.sleep(nanoseconds: 200_000_000)
        check(store.memory(id4)?.analysisStage == .quick && LocalFiles.exists(PoseFiles.partial(id4)), "work stopped with a checkpoint")
        check(BGTaskScheduler.shared.submitted.contains { $0.identifier == BackgroundWork.processingIdentifier }, "charging-time processing task requested")
        UIApplication.shared.applicationState = .active
        store.appDidBecomeActive()
        await wait("video 4 complete after resume") { store.memory(id4)?.analysisStage == .complete && store.analyzing.isEmpty }

        print("G2. continued task ended by the system while the app is open → work carries on")
        let id9 = try await store.saveRecording(url: try makeVideo("scissoring_16w", "recording-9.mov"))
        await wait("video 9 running") { (store.monitor.progress[id9]?.fraction ?? 0) > 0.2 }
        BGTaskScheduler.shared.lastContinued?.expirationHandler?()
        await wait("video 9 complete without suspension") { store.memory(id9)?.analysisStage == .complete && store.analyzing.isEmpty }
        check(!store.analysisSuspended, "not suspended in the foreground")

        print("G3. short background extension: watchdog stops before time runs out")
        let id10 = try await store.saveRecording(url: try makeVideo("no_hands_midline_30w", "recording-10.mov"), userInitiated: false)
        await wait("video 10 running") { (store.monitor.progress[id10]?.fraction ?? 0) > 0.2 }
        UIApplication.shared.applicationState = .background
        UIApplication.shared.backgroundTimeRemaining = 4
        store.appDidEnterBackground()
        await wait("watchdog suspended the queue", timeout: 10) { store.analysisSuspended && store.currentJob == nil }
        check(UIApplication.shared.open.isEmpty, "short task released after the checkpoint")
        UIApplication.shared.applicationState = .active
        UIApplication.shared.backgroundTimeRemaining = 30
        store.appDidBecomeActive()
        await wait("video 10 complete") { store.memory(id10)?.analysisStage == .complete && store.analyzing.isEmpty }

        print("H. model unavailable in background → no false 'no body', retried later")
        UIApplication.shared.applicationState = .background
        FakeEnv.failInferenceAt = 40
        let id5 = try await store.saveRecording(url: try makeVideo("asym_left_arm_20w", "recording-5.mov"), userInitiated: false)
        await wait("interrupted and suspended") { store.analysisSuspended && store.currentJob == nil }
        check(store.memory(id5)?.analysisError == nil && store.memory(id5)?.report == nil, "no error, nothing stored")
        UIApplication.shared.applicationState = .active
        FakeEnv.failInferenceAt = nil
        store.appDidBecomeActive()
        await wait("video 5 complete") { store.memory(id5)?.analysisStage == .complete && store.analyzing.isEmpty }

        print("I. broken video → Retry")
        let bad = LocalFiles.url("broken.mov")
        try "fixture:does_not_exist:30".write(to: bad, atomically: true, encoding: .utf8)
        let id6 = try await store.saveRecording(url: bad)
        await wait("error shown") { store.memory(id6)?.analysisError != nil && store.analyzing.isEmpty }
        store.analyze(id6)
        check(store.memory(id6)?.analysisError == nil, "retry clears the error at once")
        await wait("error shown again") { store.memory(id6)?.analysisError != nil && store.analyzing.isEmpty }

        print("J. new rules after an app update: observations recomputed once, no loop")
        store.rulesFingerprint = "previous-version"
        store.resumePending()
        await wait("queue drains", timeout: 60) { store.currentJob == nil && store.pendingIDs.isEmpty }
        store.rulesFingerprint = store.ruleBook?.fingerprint
        store.resumePending()
        await wait("queue drains again") { store.currentJob == nil && store.pendingIDs.isEmpty }

        print("K. BGProcessingTask runs queued work while charging")
        store.setContext(.supine, for: id1)                          // something cheap to do
        var deferred = store.memory(id2)!
        deferred.analysisStage = .quick; deferred.detailDeferred = nil
        try store.update(deferred)
        store.suspendAnalysis()
        let task = BGProcessingTask(identifier: BackgroundWork.processingIdentifier)
        BGTaskScheduler.shared.handlers[BackgroundWork.processingIdentifier]?(task)
        await wait("processing task completed") { task.completed == true }
        check(store.memory(id2)?.analysisStage == .complete, "queued detail finished in the processing task")

        print("M. model error in the foreground → shown once, no retry loop")
        FakeEnv.failInferenceAt = 40
        let id7 = try await store.saveRecording(url: try makeVideo("head_pref_right", "recording-7.mov"))
        await wait("foreground interruption shown as error") { store.memory(id7)?.analysisError != nil && store.analyzing.isEmpty && store.currentJob == nil }
        let quickRuns = FakeEnv.runs.filter { $0.id == "recording-7.mov" }.count
        try? await Task.sleep(nanoseconds: 300_000_000)
        check(FakeEnv.runs.filter { $0.id == "recording-7.mov" }.count == quickRuns && quickRuns == 1, "ran once")
        FakeEnv.failInferenceAt = nil

        print("N. two quick position changes → the last one wins")
        store.setContext(.prone, for: id2)
        store.setContext(.sitting, for: id2)
        await wait("observations for 'sitting'") { store.memory(id2)?.motor?.contextTag == "sitting" && !store.refreshing.contains(id2) }

        print("O. delete during the detail pass, and launch cleanup of orphaned pose data")
        let id8 = try await store.saveRecording(url: try makeVideo("atnr_30w", "recording-8.mov"))
        await wait("video 8 detail running") { store.monitor.progress[id8]?.phase == .detail && (store.monitor.progress[id8]?.fraction ?? 0) > 0.65 }
        try store.deleteMemory(id8)
        await wait("queue idle") { store.currentJob == nil && store.analyzing.isEmpty }
        try? await Task.sleep(nanoseconds: 400_000_000)
        check(PoseFiles.all(id8).allSatisfy { !LocalFiles.exists($0) }, "no checkpoint or track left after delete")
        let stray = UUID()
        try Data([1, 2, 3]).write(to: LocalFiles.url(PoseFiles.raw(stray)))
        try Data([1]).write(to: LocalFiles.url("\(stray).jpg"))
        await store.recoverRecordings()
        check(!LocalFiles.exists(PoseFiles.raw(stray)) && !LocalFiles.exists("\(stray).jpg"), "orphaned derived files removed at launch")
        check(store.album.memories.allSatisfy { m in m.poseStorage == nil || LocalFiles.exists(PoseFiles.raw(m.id)) }, "known memories' tracks kept")

        print("P. video dates: days old, birthday edits, back to the filmed date, imports without a date")
        var d1 = store.memory(id1)!
        check(d1.dateOrigin == .recorded && d1.capturedDate == d1.date && !d1.needsDate, "recorded in the app: the recording time")
        let filmed = d1.date
        var withMoment = store.album
        let momentID = UUID()
        withMoment.moments.append(Moment(id: momentID, memoryID: id1, title: "kick", date: filmed, start: 0, end: 1))
        try store.commit(withMoment)
        let born = Calendar.current.startOfDay(for: store.album.baby!.birthday)
        try store.setDate(.daysOld(days: 20), for: id1)
        d1 = store.memory(id1)!
        let expected = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Calendar.current.date(byAdding: .day, value: 20, to: born)!)!
        check(d1.date == expected && d1.dateSetting == .daysOld(days: 20) && d1.capturedDate == filmed, "20 days old → birthday + 20 days, filming date kept")
        check(store.album.moments.first { $0.id == momentID }?.date == expected, "its moment moved with it")
        await wait("observations re-checked for the new age") {
            guard let m = store.memory(id1), let a = m.motor?.ageWeeks else { return false }
            return abs(a - store.album.baby!.analysisWeeks(on: m.date)) < 0.05 && !store.refreshing.contains(id1)
        }
        var shifted = store.album.baby!
        shifted.birthday = shifted.birthday.addingTimeInterval(2 * 86_400)
        try store.setBaby(shifted)
        check(store.memory(id1)!.date == Calendar.current.date(byAdding: .day, value: 2, to: expected)!, "birthday edit moves age-based dates")
        try store.setDate(.exact(date: filmed.addingTimeInterval(-86_400)), for: id2)
        let exactDate = store.memory(id2)!.date
        var back = store.album.baby!
        back.birthday = back.birthday.addingTimeInterval(-2 * 86_400)
        try store.setBaby(back)
        check(store.memory(id2)!.date == exactDate, "exact days don't follow the birthday")
        try store.setDate(nil, for: id1)
        d1 = store.memory(id1)!
        check(d1.date == filmed && d1.dateSetting == nil, "back to the date from the video")
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("staged-\(UUID().uuidString).mov")
        let t9 = try PoseBinary.decode(Data(contentsOf: FakeEnv.fixtures.appendingPathComponent("baseline_30fps.mgpose")))
        try "fixture:baseline_30fps:\(t9.header.durationSeconds)".write(to: staged, atomically: true, encoding: .utf8)
        let undatedID = try await store.importStagedVideo(from: staged)
        check(store.memory(undatedID)!.needsDate && store.memory(undatedID)!.dateOrigin == .unknown, "import without a date asks for one")
        try store.setDate(.aboutWeeks(weeks: 3), for: undatedID)
        check(!store.memory(undatedID)!.needsDate && store.memory(undatedID)!.dateIsApproximate, "rough date set")
        let datedStaged = FileManager.default.temporaryDirectory.appendingPathComponent("staged-\(UUID().uuidString).mov")
        try "fixture:baseline_30fps:\(t9.header.durationSeconds)".write(to: datedStaged, atomically: true, encoding: .utf8)
        let when = Date().addingTimeInterval(-3 * 86_400)
        let datedID = try await store.importStagedVideo(from: datedStaged, recordedDate: when)
        check(store.memory(datedID)!.date == when && store.memory(datedID)!.dateOrigin == .metadata, "import with a date in the file keeps it")
        await wait("imports analysed") { store.currentJob == nil && store.analyzing.isEmpty }

        print("L. album on disk matches memory")
        store.flushToDisk()
        let disk = try JSONDecoder().decode(Album.self, from: Data(contentsOf: LocalFiles.url("album.json")))
        check(disk.memories.count == store.album.memories.count && disk.memories.map(\.analysisStage) == store.album.memories.map(\.analysisStage), "album.json up to date")
        check(disk.memories.allSatisfy { $0.motor == nil || $0.motor?.rulesFingerprint != nil }, "summaries stored")
        let bytes = LocalFiles.storageBytes()
        print("  storage:", bytes, "bytes;", store.album.memories.count, "memories")
        print("STORE HARNESS OK")
    }
}
