// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
//
// The analysis queue. One job runs at a time; each job is one step for one memory:
//
//   migrate       v1.0 JSON pose files → binary tracks, plus observations from the stored 15 fps data
//   quick         ~15 fps pass → review, suggestions, posture checks (seconds after recording)
//   detail        every remaining frame at the video's own frame rate (resumable from checkpoints)
//   observations  re-run the rule engine on the stored track (context, age or rules changed)
//
// Progress is reported per video across both passes (0…1 of all its frames) and per batch
// (the videos the parent recorded or imported together), with time estimates for both.
//
// A new recording's quick pass pre-empts a running detail pass (which checkpoints and resumes
// later), so a fresh video never waits behind an older one. Steps never run on the main actor.

import Foundation
import UIKit
import ImageIO

enum AnalysisStep: String {
    case migrate, quick, detail, observations
    var showsProgress: Bool { self != .observations }
}

/// Converts frame counts reported on the analysis thread into whole-video progress (both passes)
/// with a time estimate.
final class ProgressRelay: @unchecked Sendable {
    let id: UUID
    let phase: AnalysisProgress.Phase
    /// Frames of this video already analysed before this pass.
    private let offset: Int
    /// All frames of this video (both passes).
    private let total: Int
    private let lock = NSLock()
    private var estimator = ThroughputEstimator()
    private var open = true

    init(id: UUID, phase: AnalysisProgress.Phase, offset: Int = 0, total: Int) {
        self.id = id
        self.phase = phase
        self.offset = offset
        self.total = total
    }

    var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return open }
    func close() { lock.lock(); open = false; lock.unlock() }

    func report(done: Int, expected: Int) {
        lock.lock()
        guard open else { lock.unlock(); return }
        estimator.update(done: done, now: ProcessInfo.processInfo.systemUptime)
        let all = max(total, offset + max(expected, done))
        let remaining = estimator.remainingSeconds(remainingFrames: max(0, all - offset - done))
        let rate = estimator.framesPerSecond
        lock.unlock()
        let progress = AnalysisProgress(phase: phase, fraction: all > 0 ? min(1, Double(offset + done) / Double(all)) : 0,
                                        remainingSeconds: remaining, framesPerSecond: rate)
        Task { @MainActor [self] in
            guard self.isOpen else { return }
            LocalStore.shared.progressDidChange(self.id, progress)
        }
    }
}

extension LocalStore {
    // MARK: public entry points

    /// Queues whatever each memory still needs (launch, foreground, power or rule changes).
    func resumePending() {
        guard !recoveryRequired else { return }
        analysisSuspended = false
        for m in album.memories.sorted(by: { $0.date > $1.date }) where nextStep(for: m) != nil { enqueue(m.id) }
        startNextAnalysis()
    }

    /// Explicit request (new recording, import, Retry).
    func analyze(_ id: UUID, detail: Bool = false, userInitiated initiated: Bool = true) {
        guard var m = memory(id) else { return }
        if detail { detailRequested.insert(id) }
        if initiated {
            userInitiated.insert(id)
            joinBatch(id)
        }
        attemptedSteps = attemptedSteps.filter { !$0.hasPrefix(id.uuidString) }
        if m.analysisError != nil {
            m.analysisError = nil
            try? update(m)
        }
        analysisSuspended = false
        enqueue(id)
    }

    /// Kept for older call sites: every video now gets the full-rate pass automatically.
    func requestDetailedCheck(_ id: UUID) { analyze(id, detail: true) }

    /// Whether a memory can be analysed again now (anything but the job that is running for it).
    func canReanalyze(_ id: UUID) -> Bool { currentJob?.id != id }

    /// Videos analysed before InstantHMR became the engine are treated as new: their earlier (YOLO,
    /// Vision or v1.0) pose data is ignored and they are analysed again from scratch, automatically.
    /// So are videos analysed with an InstantHMR model this build does not contain (Small, Tiny or Nano
    /// in development builds): their later passes could not continue with the same model.
    func needsEngineUpgrade(_ m: Memory) -> Bool {
        guard PoseEngine.current == .instantHMR, m.hasPoseData else { return false }
        guard let estimator = m.poseEstimator, PoseEngine.isInstantHMR(estimator) else { return true }
        return HMRConfig(estimatorID: estimator)?.isRunnable != true
    }

    /// Discards a memory's pose data and observations and analyses the video again with the pose
    /// engine chosen in Settings. The video, its notes, date and milestones are untouched.
    func reanalyze(_ id: UUID) {
        guard var m = memory(id), canReanalyze(id) else { return }
        for name in PoseFiles.all(id) { LocalFiles.remove(name) }
        m.report = nil
        m.poseStorage = nil
        m.poseEstimator = nil
        m.poseProcessing = nil
        m.analysisStage = nil
        m.motor = nil
        m.kinematics = nil
        m.detailDeferred = nil
        m.analysisError = nil
        motorCache[id] = nil
        detailRequested.remove(id)
        try? update(m)
        analyze(id)
    }

    /// Videos whose pose data came from another engine (or settings) than the current choice.
    func memoriesNeedingReanalysis() -> [UUID] {
        let target = PoseEngine.preferredEstimatorID ?? YOLOPoseModelProvider.estimatorID
        return album.memories.filter { $0.poseEstimator != nil && $0.poseEstimator != target && canReanalyze($0.id) }.map(\.id)
    }

    /// Analyses all of them again with the current engine; returns how many were queued.
    @discardableResult
    func reanalyzeAll() -> Int { reanalyze(ids: memoriesNeedingReanalysis()) }

    /// Analyses the chosen videos again (the album's selection); returns how many were queued.
    @discardableResult
    func reanalyze(ids: [UUID]) -> Int {
        let ok = ids.filter { memory($0) != nil && canReanalyze($0) }
        for id in ok { reanalyze(id) }
        return ok.count
    }

    // MARK: batch progress

    /// Videos recorded or imported together share one progress (and one system Live Activity).
    func joinBatch(_ id: UUID) {
        if !batch.isEmpty, batch.allSatisfy({ batchFinished.contains($0) || memory($0) == nil }) {
            batch = []; batchFinished = []                       // the previous batch is done: start a new one
        }
        if !batch.contains(id) { batch.append(id) }
        batchFinished.remove(id)
        updateBatch()
    }

    /// Estimated frames of a memory (weight in the batch fraction and time estimate).
    private func frameWeight(_ id: UUID) -> Double {
        guard let m = memory(id) else { return 0 }
        return max(1, m.duration * (m.videoFPS ?? 30))
    }

    func updateBatch() {
        guard !batch.isEmpty else { monitor.setBatch(nil); return }
        var total = 0.0, done = 0.0
        for id in batch {
            let w = frameWeight(id)
            total += w
            if batchFinished.contains(id) || memory(id) == nil { done += w }
            else if let p = monitor.progress[id] { done += w * p.fraction }
        }
        if let rate = monitor.progress.values.compactMap(\.framesPerSecond).first, rate > 0 { batchRate = rate }
        let remaining = batchRate.map { max(0, total - done) / $0 }
        let finished = batch.filter { batchFinished.contains($0) || memory($0) == nil }.count
        let batchProgress = BatchProgress(ids: batch, finished: finished,
                                          fraction: total > 0 ? min(1, done / total) : 0,
                                          remainingSeconds: finished == batch.count ? 0 : remaining,
                                          currentID: currentJob?.id, paused: captureActive)
        monitor.setBatch(batchProgress)
        background.update(batchProgress)
    }


    func setContext(_ context: RecordingContext, for id: UUID) {
        guard var m = memory(id), m.contextTag != context else { return }
        m.contextTag = context
        do { try update(m) } catch { self.error = error.localizedDescription; return }
        refreshObservations([id])
    }

    /// Re-runs the rule engine for every memory whose observations are out of date (age changed).
    func refreshAllObservations() {
        refreshObservations(album.memories.filter(observationsStale).map(\.id))
    }

    /// Full observations for one memory (cached; loaded off the main actor).
    func motorReport(for id: UUID) async -> MotorReport? {
        if let cached = motorCache[id], cached.generatedAt == memory(id)?.motor?.generatedAt { return cached }
        let report = await Task.detached(priority: .userInitiated) { AnalysisPipeline.loadMotor(id: id) }.value
        if let report { motorCache[id] = report }
        return report
    }

    /// Fills in the kinematics summary of memories analysed before it existed (or with an older
    /// version), one at a time off the main actor. Safe to call often.
    func backfillKinematics() {
        guard !backfilling else { return }
        let todo = album.memories
            .filter { $0.poseStorage != nil && ($0.kinematics?.version ?? 0) != SessionKinematics.currentVersion && !analyzing.contains($0.id) }
            .map { (id: $0.id, aspect: $0.aspectRatio) }
        guard !todo.isEmpty else { return }
        backfilling = true
        Task { [weak self] in
            for item in todo {
                let summary = await Task.detached(priority: .utility) { AnalysisPipeline.digest(id: item.id, aspect: item.aspect)?.session }.value
                guard let self else { return }
                if let summary, var m = self.memory(item.id), !self.analyzing.contains(item.id) {
                    m.kinematics = summary
                    try? self.update(m)
                }
            }
            self?.backfilling = false
        }
    }

    /// Cross-session persistence of observations, oldest first.
    func motorTrends() -> [MotorTrend] {
        guard let book = ruleBook else { return [] }
        let sessions = album.memories.compactMap { m in m.motor.map { (date: m.date, summary: $0) } }.sorted { $0.date < $1.date }
        return MotorLongitudinal.trends(sessions: sessions, book: book)
    }

    func progressDidChange(_ id: UUID, _ progress: AnalysisProgress) {
        var p = progress
        p.paused = captureActive
        // A video's bar never moves backwards between its steps.
        if let old = monitor.progress[id], old.fraction > p.fraction { p.fraction = old.fraction }
        monitor.set(id, p)
        updateBatch()
    }

    // MARK: what a memory needs

    /// Every video is analysed at its own frame rate, automatically.
    func wantsDetail(_ m: Memory) -> Bool { true }

    func observationsStale(_ m: Memory) -> Bool {
        guard ruleBook != nil, m.poseStorage != nil else { return false }
        guard let s = m.motor else { return true }
        if s.engine != MotorEngine.version || s.rulesFingerprint != rulesFingerprint || s.contextTag != m.context.rawValue { return true }
        switch (album.baby?.analysisWeeks(on: m.date), s.ageWeeks) {
        case (nil, nil): return false
        case let (a?, b?): return abs(a - b) > 0.05
        default: return true
        }
    }

    func nextStep(for m: Memory) -> AnalysisStep? {
        guard m.analysisError == nil else { return nil }
        let step: AnalysisStep?
        let upgrade = needsEngineUpgrade(m)
        if m.poseStorage == nil {
            step = (!upgrade && m.report != nil && PoseStore.rawURL(for: m.id) != nil) ? .migrate : .quick
        } else if upgrade {
            step = .quick                                    // analysed with another engine: start again
        } else if m.analysisStage != .complete && wantsDetail(m) {
            step = .detail
        } else if observationsStale(m) && !refreshing.contains(m.id) {
            step = .observations
        } else {
            step = nil
        }
        guard let step, !attemptedSteps.contains(stepKey(m.id, step)) else { return nil }
        return step
    }

    private func stepKey(_ id: UUID, _ step: AnalysisStep) -> String { "\(id.uuidString).\(step.rawValue)" }

    // MARK: queue

    func enqueue(_ id: UUID) {
        guard let m = memory(id), let step = nextStep(for: m) else { return }
        if step.showsProgress {
            analyzing.insert(id)
            if monitor.progress[id] == nil { monitor.set(id, AnalysisProgress(phase: .preparing, fraction: 0, paused: captureActive)) }
        }
        if currentJob?.id != id, !pendingIDs.contains(id) { pendingIDs.append(id) }
        // A new video's first results should never wait behind an older video's detail pass.
        if step == .quick || step == .migrate, let job = currentJob, job.step == .detail, job.id != id {
            analysisControl.cancel()                       // the detail pass checkpoints and is re-queued
        }
        startNextAnalysis()
    }

    func startNextAnalysis() {
        guard currentJob == nil, !analysisSuspended else { return }
        var chosen: (index: Int, step: AnalysisStep)?
        var i = 0
        while i < pendingIDs.count {
            guard let m = memory(pendingIDs[i]), let step = nextStep(for: m) else {
                settle(pendingIDs.remove(at: i))
                continue
            }
            if step != .detail { chosen = (i, step); break }
            if chosen == nil { chosen = (i, step) }
            i += 1
        }
        guard let chosen else { queueDidDrain(); return }
        let id = pendingIDs.remove(at: chosen.index)
        currentJob = (id, chosen.step)
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            await self.perform(chosen.step, id)
            self.jobDidFinish(id)
        }
    }

    private func jobDidFinish(_ id: UUID) {
        tasks[id] = nil
        currentJob = nil
        activeRelay?.close()
        activeRelay = nil
        if memory(id) == nil {
            // Deleted while its job ran: the job may have written a checkpoint or tracks after the
            // memory's files were removed. Pose data of a deleted video must not stay behind.
            Task.detached(priority: .utility) { PoseFiles.all(id).forEach(LocalFiles.remove) }
        }
        if let m = memory(id), nextStep(for: m) != nil {
            if !pendingIDs.contains(id) { pendingIDs.append(id) }
        } else {
            settle(id)
        }
        if analysisSuspended {
            // Release background time now instead of holding it until the system expires it.
            flushToDisk()
            background.suspendAll()
            background.scheduleProcessing(hasQueuedWork)
            return
        }
        startNextAnalysis()
    }

    /// The memory has nothing more to do right now.
    private func settle(_ id: UUID) {
        analyzing.remove(id)
        monitor.set(id, nil)
        userInitiated.remove(id)
        if batch.contains(id) { batchFinished.insert(id) }
        updateBatch()
        if !batch.isEmpty, batchFinished.count == batch.count { background.endContinued(success: true) }
    }

    private func queueDidDrain() {
        if UIApplication.shared.applicationState != .active { flushToDisk() }   // before iOS may suspend us
        background.endAll()
        backfillKinematics()
    }

    /// Background time ran out: stop now (the running pass checkpoints) and resume when active.
    func suspendAnalysis() {
        analysisSuspended = true
        analysisControl.cancel()
    }

    // MARK: running a step

    private func perform(_ step: AnalysisStep, _ id: UUID) async {
        attemptedSteps.insert(stepKey(id, step))           // failures are not retried until asked or relaunched
        analysisControl.reset()
        analysisControl.setPaused(captureActive)
        if step.showsProgress {
            background.begin(for: id, userInitiated: userInitiated.contains(id), control: analysisControl)
        }
        do {
            switch step {
            case .migrate: try await migrate(id)
            case .quick: try await quickPass(id)
            case .detail: try await detailPass(id)
            case .observations: try await recomputeObservations(id)
            }
            // Done: the step may run again later in this session (new context, age, request)…
            attemptedSteps.remove(stepKey(id, step))
            // …unless it made no progress (e.g. no usable track), which would otherwise loop.
            if let m = memory(id), nextStep(for: m) == step { attemptedSteps.insert(stepKey(id, step)) }
        } catch is CancellationError {
            attemptedSteps.remove(stepKey(id, step))   // pre-empted, suspended or deleted: runs again later
        } catch where UIApplication.shared.applicationState != .active {
            // In the background, failures are usually the environment (model or decoder unavailable,
            // AnalysisInterrupted): keep the checkpoint and retry once the app is active.
            attemptedSteps.remove(stepKey(id, step))
            analysisSuspended = true
        } catch {
            #if DEBUG
            print("MoveGrow analysis: \(step.rawValue) failed for \(id): \(error)")
            #endif
            // A failed quick pass is shown with Retry. Detail, migration and observation failures keep
            // the results the memory already has and are not retried until the next launch.
            if step == .quick, var m = memory(id) {
                m.analysisError = tr("Summary unavailable. Your video is safe. Tap Retry.")
                try? update(m)
            }
        }
    }

    private func analysisAge(_ m: Memory) -> Double? { album.baby?.analysisWeeks(on: m.date) }

    private func quickPass(_ id: UUID) async throws {
        guard var m = memory(id) else { throw CancellationError() }
        if m.hasPoseData || m.poseEstimator != nil {
            // Analysed before (another engine, or analysed again): treat it as a new video, so nothing of the
            // earlier pose data or its results is mixed in.
            for name in PoseFiles.all(id) { LocalFiles.remove(name) }
            m.report = nil
            m.poseStorage = nil
            m.poseEstimator = nil
            m.poseProcessing = nil
            m.analysisStage = nil
            m.motor = nil
            m.kinematics = nil
            m.detailDeferred = nil
            motorCache[id] = nil
            try? update(m)
        }
        let url = LocalFiles.url(m.filename)
        progressDidChange(id, AnalysisProgress(phase: .preparing, fraction: 0))
        let info = try await VideoAnalyzer.probe(url: url)
        let engine = PoseEngine.preferredEstimatorID                    // nil = YOLO chain
        let plan = AnalysisPlan(nominalFPS: info.nominalFPS, duration: info.duration,
                                maxFPS: engine.flatMap(HMRConfig.init(estimatorID:))?.planMaxFPS ?? AnalysisPlan.fullMaxFPS)
        if var known = memory(id), known.videoFPS == nil {             // better batch estimates from now on
            known.videoFPS = info.nominalFPS
            try? update(known)
        }
        let quickFrames = plan.frameCount(.quick)
        let allFrames = quickFrames + (plan.needsDetailPass ? plan.frameCount(.detail) : 0)
        let relay = ProgressRelay(id: id, phase: .quick, total: allFrames)
        activeRelay = relay
        let result = try await VideoAnalyzer.run(url: url, info: info, plan: plan, pass: .quick, skip: [],
                                                 control: analysisControl, estimatorID: engine,
                                                 progress: { relay.report(done: $0, expected: $1) })
        relay.close()
        let savedShare = Double(quickFrames) / Double(max(1, allFrames))
        progressDidChange(id, AnalysisProgress(phase: .saving, fraction: savedShare))

        guard let current = memory(id) else { throw CancellationError() }
        let book = ruleBook, age = analysisAge(current), context = current.context
        let duration = info.duration, aspect = info.aspect, frames = result.frames
        let header = AnalysisPipeline.header(estimator: result.estimator, processing: "raw", duration: duration, aspect: aspect,
                                             captureFPS: info.nominalFPS, analysisFPS: plan.quickFPS)
        let (out, kinematics) = try await Task.detached(priority: .userInitiated) { () throws -> (AnalysisPipeline.QuickOutput, SessionKinematics?) in
            let out = try AnalysisPipeline.finishQuick(id: id, frames: frames, header: header, duration: duration, aspect: aspect,
                                                       book: book, ageWeeks: age, context: context)
            return (out, AnalysisPipeline.digest(id: id, aspect: aspect)?.session)
        }.value

        guard var cur = memory(id) else { throw CancellationError() }
        let prior = cur.milestoneSuggestions ?? []
        let resolvedKinds = Set(prior.filter { $0.status != .suggested }.map(\.kind))
        cur.milestoneSuggestions = prior.filter { $0.status != .suggested } + out.suggestions.filter { !resolvedKinds.contains($0.kind) }
        cur.report = out.report
        cur.analysisError = nil
        cur.poseEstimator = result.estimator
        cur.poseProcessing = AnalysisPipeline.usesRefiner(result.estimator) ? PoseTemporalRefiner.version : "none"
        cur.poseStorage = "mgpose1"
        cur.videoFPS = info.nominalFPS
        cur.aspectRatio = aspect
        cur.motor = out.motor?.summary
        cur.kinematics = kinematics
        cur.analysisStage = plan.needsDetailPass ? .quick : .complete
        motorCache[id] = out.motor
        try update(cur)
        monitor.didFinish(id, stage: cur.analysisStage ?? .quick)
        if cur.thumbnail == nil { makeThumbnail(id: id, url: url, duration: duration) }
    }

    private func detailPass(_ id: UUID) async throws {
        guard let m = memory(id) else { throw CancellationError() }
        let url = LocalFiles.url(m.filename)
        progressDidChange(id, AnalysisProgress(phase: .detail, fraction: 0))
        let info = try await VideoAnalyzer.probe(url: url)
        let plan = AnalysisPlan(nominalFPS: info.nominalFPS, duration: info.duration,
                                maxFPS: m.poseEstimator.flatMap(HMRConfig.init(estimatorID:))?.planMaxFPS ?? AnalysisPlan.fullMaxFPS)
        guard plan.needsDetailPass else {                  // e.g. a 15–24 fps video: nothing to add
            var cur = m
            cur.analysisStage = .complete
            cur.detailDeferred = nil
            try update(cur)
            return
        }
        let (skip, previous) = await Task.detached(priority: .utility) {
            (AnalysisPipeline.analysedTimeKeys(id: id), AnalysisPipeline.loadPartial(id: id))
        }.value
        let header = AnalysisPipeline.header(estimator: m.poseEstimator ?? YOLOPoseModelProvider.estimatorID, processing: "raw",
                                             duration: info.duration, aspect: info.aspect,
                                             captureFPS: info.nominalFPS, analysisFPS: plan.fullFPS)
        let fullFrames = (plan.estimatedFrames + plan.fullStride - 1) / plan.fullStride
        let relay = ProgressRelay(id: id, phase: .detail, offset: min(skip.count, fullFrames), total: fullFrames)
        activeRelay = relay
        let result = try await VideoAnalyzer.run(
            url: url, info: info, plan: plan, pass: .detail, skip: skip, control: analysisControl, checkpointEvery: 300,
            estimatorID: m.poseEstimator,
            progress: { relay.report(done: $0, expected: $1) },
            checkpoint: { frames in AnalysisPipeline.writePartial(id: id, frames: previous + frames, header: header) })
        relay.close()
        // Never mix estimators within one track (e.g. if the model fell back to Vision this time).
        if let estimator = m.poseEstimator, estimator != result.estimator { throw CocoaError(.featureUnsupported) }
        progressDidChange(id, AnalysisProgress(phase: .finishing, fraction: 1))

        guard let current = memory(id) else { throw CancellationError() }
        let book = ruleBook, age = analysisAge(current), context = current.context
        let fullFPS = plan.fullFPS, newFrames = previous + result.frames
        let aspect = info.aspect
        let (motor, kinematics) = try await Task.detached(priority: .utility) { () throws -> (MotorReport?, SessionKinematics?) in
            let motor = try AnalysisPipeline.finishDetail(id: id, newFrames: newFrames, analysisFPS: fullFPS, book: book,
                                                          ageWeeks: age, context: context)
            return (motor, AnalysisPipeline.digest(id: id, aspect: aspect)?.session)
        }.value

        guard var cur = memory(id) else { throw CancellationError() }
        cur.analysisStage = .complete
        cur.detailDeferred = nil
        cur.videoFPS = info.nominalFPS
        if let kinematics { cur.kinematics = kinematics }
        if let motor {
            cur.motor = motor.summary
            motorCache[id] = motor
        }
        try update(cur)
        detailRequested.remove(id)
        monitor.didFinish(id, stage: .complete)
    }

    /// v1.0 memories: JSON → binary, and observations from the stored 15 fps track. The full-rate
    /// pass is offered in the memory ("Run detailed check") rather than started for every old video.
    private func migrate(_ id: UUID) async throws {
        guard let m = memory(id) else { throw CancellationError() }
        progressDidChange(id, AnalysisProgress(phase: .saving, fraction: 0.5))
        let info = try? await VideoAnalyzer.probe(url: LocalFiles.url(m.filename))
        let book = ruleBook, age = analysisAge(m), context = m.context, aspect = info?.aspect
        let motor = try await Task.detached(priority: .utility) { () throws -> MotorReport? in
            try PoseStore.migrateLegacy(id)
            return try AnalysisPipeline.recomputeMotor(id: id, book: book, ageWeeks: age, context: context, aspect: aspect)
        }.value
        guard var cur = memory(id) else { throw CancellationError() }
        let plan = info.map { AnalysisPlan(nominalFPS: $0.nominalFPS, duration: $0.duration) }
        cur.poseStorage = "mgpose1"
        cur.analysisStage = (plan?.needsDetailPass ?? true) ? .quick : .complete
        cur.detailDeferred = nil                               // the full-rate pass follows automatically
        cur.videoFPS = info?.nominalFPS
        cur.aspectRatio = aspect
        cur.motor = motor?.summary
        motorCache[id] = motor
        try update(cur)
    }

    private func recomputeObservations(_ id: UUID) async throws {
        guard let m = memory(id) else { return }
        let book = ruleBook, age = analysisAge(m), context = m.context, aspect = m.aspectRatio
        let motor = try await Task.detached(priority: .utility) {
            try AnalysisPipeline.recomputeMotor(id: id, book: book, ageWeeks: age, context: context, aspect: aspect)
        }.value
        guard var cur = memory(id) else { return }
        cur.motor = motor?.summary
        motorCache[id] = motor
        try update(cur)
    }

    /// Context or age edits: re-run the rule engine at once (≈0.2 s per video, CPU only), outside
    /// the queue. A memory with a running job is re-checked when that job ends.
    private func refreshObservations(_ ids: [UUID]) {
        let todo = ids.filter { $0 != currentJob?.id && !refreshing.contains($0) }
        guard !todo.isEmpty else { return }
        refreshing.formUnion(todo)
        Task { [weak self] in
            for id in todo {
                guard let self else { return }
                let before = self.memory(id).map { (context: $0.context, age: self.analysisAge($0)) }
                try? await self.recomputeObservations(id)
                self.refreshing.remove(id)
                // Changed again while this ran (e.g. a second position tap): run once more.
                if let m = self.memory(id), let before, m.context != before.context || self.analysisAge(m) != before.age {
                    self.refreshObservations([id])
                }
            }
        }
    }

    // MARK: power

    func observePowerState() {
        // Analysis runs at native frame rate regardless of Low Power Mode (it is work the parent
        // asked for); thermal state still throttles it (AnalysisControl). Leaving Low Power Mode
        // is a good moment to pick up anything that was interrupted.
        powerObserver = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                if !ProcessInfo.processInfo.isLowPowerModeEnabled { LocalStore.shared.resumePending() }
            }
        }
    }
}
