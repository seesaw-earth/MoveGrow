// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
//
// Keeps analysis going when the parent leaves the app.
//  • Recording / import / Retry (user-initiated): on iOS 26 one continued-processing task per batch
//    (all videos recorded or imported together), which the system shows as a Live Activity with
//    the batch's progress and time left, and which the parent can cancel; earlier systems get the
//    usual short background-time extension.
//  • Queued work (older videos, detailed checks): short extension, then a BGProcessingTask that
//    iOS runs later while the phone is charging.
// Analysis checkpoints whenever time runs out, so nothing is lost.

import Foundation
import UIKit
import BackgroundTasks

@MainActor final class BackgroundWork {
    static let processingIdentifier = "com.ziqingshi.movegrow.analysis"
    static let continuedPrefix = "com.ziqingshi.movegrow.continued"

    private(set) var shortTask: UIBackgroundTaskIdentifier = .invalid
    private var processingTask: BGProcessingTask?
    private(set) var continuedTask: AnyObject?
    /// A continued task was submitted for the current batch (it may not have started yet).
    private(set) var continuedActive = false
    private var lastSubtitle = ""
    private var watchdog: Task<Void, Never>?

    // MARK: lifecycle of one job

    func begin(for id: UUID, userInitiated: Bool, control: AnalysisControl) {
        if userInitiated, !continuedActive, submitContinued(control: control) { return }
        guard shortTask == .invalid, processingTask == nil, continuedTask == nil else { return }
        shortTask = UIApplication.shared.beginBackgroundTask(withName: "MoveGrow analysis") {
            // Backstop, on the main thread just before suspension (the watchdog below normally stops first).
            MainActor.assumeIsolated {
                let store = LocalStore.shared
                if store.background.continuedTask == nil {
                    control.cancel()
                    store.suspendAnalysis()
                    store.background.scheduleProcessing(store.hasQueuedWork)
                }
                store.background.endShortTask()
            }
        }
    }

    /// In the background with only the short extension: stop a few seconds before it runs out, so
    /// the running pass can write its checkpoint and the album is saved before iOS suspends the app.
    func startWatchdog() {
        stopWatchdog()
        guard shortTask != .invalid, continuedTask == nil, processingTask == nil else { return }
        watchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                let app = UIApplication.shared
                guard app.applicationState == .background, self.shortTask != .invalid, self.continuedTask == nil else { return }
                if app.backgroundTimeRemaining < 6 {
                    LocalStore.shared.suspendAnalysis()         // job ends → checkpoint → suspendAll()
                    return
                }
            }
        }
    }

    func stopWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    /// Mirrors the batch into the system Live Activity.
    func update(_ batch: BatchProgress) {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask {
            task.progress.totalUnitCount = 1000
            task.progress.completedUnitCount = Int64((max(0, min(1, batch.fraction)) * 1000).rounded())
            let title = Self.title(batch)
            let subtitle = batch.shortText
            if title + subtitle != lastSubtitle {
                lastSubtitle = title + subtitle
                task.updateTitle(title, subtitle: subtitle)
            }
        }
        #endif
    }

    private static func title(_ batch: BatchProgress) -> String {
        batch.total == 1 ? tr("Analysing movement") : tr("Analysing %lld videos", batch.total)
    }

    /// The batch the continued task was started for has nothing more to do.
    func endContinued(success: Bool) {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask {
            task.progress.completedUnitCount = task.progress.totalUnitCount
            task.setTaskCompleted(success: success)
        }
        #endif
        continuedTask = nil
        continuedActive = false
        lastSubtitle = ""
    }

    /// The queue is empty.
    func endAll() {
        endContinued(success: true)
        endShortTask()
        processingTask?.setTaskCompleted(success: true)
        processingTask = nil
    }

    /// Analysis stopped early (time ran out, or the model is unavailable in the background).
    func suspendAll() {
        endContinued(success: false)
        endShortTask()
        processingTask?.setTaskCompleted(success: false)
        processingTask = nil
    }

    func endShortTask() {
        stopWatchdog()
        guard shortTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(shortTask)
        shortTask = .invalid
    }

    // MARK: iOS 26 continued processing

    private func submitContinued(control: AnalysisControl) -> Bool {
        #if compiler(>=6.2)
        guard #available(iOS 26.0, *), UIApplication.shared.applicationState == .active else { return false }
        // Each request needs its own identifier under the permitted wildcard, registered just before submitting.
        let identifier = "\(Self.continuedPrefix).\(UUID().uuidString)"
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            MainActor.assumeIsolated {
                guard let task = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
                LocalStore.shared.background.attachContinued(task, control: control)
            }
        }
        guard registered else { return false }
        let batch = LocalStore.shared.monitor.batch
        let request = BGContinuedProcessingTaskRequest(identifier: identifier,
                                                       title: batch.map(Self.title) ?? tr("Analysing movement"),
                                                       subtitle: batch?.shortText ?? tr("Tracking"))
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            continuedActive = true
            return true
        } catch {
            return false
        }
        #else
        return false
        #endif
    }

    #if compiler(>=6.2)
    @available(iOS 26.0, *)
    private func attachContinued(_ task: BGContinuedProcessingTask, control: AnalysisControl) {
        guard continuedActive else { task.setTaskCompleted(success: true); return }   // already finished
        continuedTask = task
        endShortTask()                                           // the continued task keeps the app running now
        task.progress.totalUnitCount = 1000
        if let batch = LocalStore.shared.monitor.batch { update(batch) }
        task.expirationHandler = {
            Task { @MainActor in
                let store = LocalStore.shared
                // In the foreground the work simply carries on; in the background (the system or the
                // parent stopped it) it checkpoints and continues when the app is opened.
                if UIApplication.shared.applicationState != .active {
                    control.cancel()
                    store.suspendAnalysis()
                    store.background.scheduleProcessing(store.hasQueuedWork)
                }
                store.background.endContinued(success: false)
            }
        }
    }
    #endif

    // MARK: BGProcessingTask (charging, later)

    static func register() {
        _ = BGTaskScheduler.shared.register(forTaskWithIdentifier: processingIdentifier, using: .main) { task in
            MainActor.assumeIsolated {
                guard let task = task as? BGProcessingTask else { task.setTaskCompleted(success: false); return }
                LocalStore.shared.background.runProcessing(task)
            }
        }
    }

    private func runProcessing(_ task: BGProcessingTask) {
        let store = LocalStore.shared
        processingTask = task
        let control = store.analysisControl
        task.expirationHandler = {
            control.cancel()
            Task { @MainActor in
                let store = LocalStore.shared
                store.suspendAnalysis()
                store.background.processingTask?.setTaskCompleted(success: false)
                store.background.processingTask = nil
                store.background.scheduleProcessing(store.hasQueuedWork)
            }
        }
        store.resumePending()
        if !store.hasQueuedWork { endAll() }
    }

    func scheduleProcessing(_ needed: Bool) {
        guard needed else { return }
        let request = BGProcessingTaskRequest(identifier: Self.processingIdentifier)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = false
        try? BGTaskScheduler.shared.submit(request)
    }
}

extension LocalStore {
    /// Any memory still waiting for a pass (used to decide whether to ask iOS for time later).
    var hasQueuedWork: Bool {
        currentJob != nil || album.memories.contains { m in
            m.analysisError == nil && (m.poseStorage == nil || (m.analysisStage != .complete && wantsDetail(m)))
        }
    }

    /// App moved to the background: make sure the index is on disk and plan the remaining work.
    func appDidEnterBackground() {
        setCaptureActive(false)                                  // the camera does not run in the background
        flushToDisk()
        background.scheduleProcessing(hasQueuedWork)
        background.startWatchdog()
    }

    /// App became active again.
    func appDidBecomeActive() {
        PoseNet.prewarm()
        HMRFrameBackend.prewarm()
        resumePending()
        backfillKinematics()
    }
}
