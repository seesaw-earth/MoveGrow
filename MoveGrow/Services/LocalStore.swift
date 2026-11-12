// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
//
// The album index and every user action that changes it. The index lives in memory and is
// published immediately; album.json is written by `AlbumWriter` on a background queue (atomic,
// coalesced), so taps never wait for the disk. Heavy work (video analysis, pose files, the rule
// engine, file deletion) never runs on the main actor — see LocalStore+Analysis.swift.

import Foundation
import Combine
import AVFoundation
import UIKit
import ImageIO

/// Analysis progress lives in its own observable object so that 5 Hz progress updates only
/// re-render the views showing progress, not the whole album.
@MainActor final class AnalysisMonitor: ObservableObject {
    @Published private(set) var progress: [UUID: AnalysisProgress] = [:]
    /// Bumped when results become available (drives the "ready" haptic and banner).
    @Published private(set) var finished: Finished?
    /// The current batch (videos recorded or imported together); nil when there is none.
    @Published private(set) var batch: BatchProgress?

    struct Finished: Equatable {
        var id: UUID
        var stage: AnalysisStage
        var serial: Int
    }
    private var serial = 0

    func set(_ id: UUID, _ value: AnalysisProgress?) {
        if progress[id] != value { progress[id] = value }
    }

    func setPaused(_ paused: Bool) {
        for (id, var p) in progress where p.paused != paused {
            p.paused = paused
            progress[id] = p
        }
    }

    func setBatch(_ value: BatchProgress?) {
        if batch != value { batch = value }
    }

    func didFinish(_ id: UUID, stage: AnalysisStage) {
        serial += 1
        finished = Finished(id: id, stage: stage, serial: serial)
    }
}

@MainActor final class LocalStore: ObservableObject {
    static let shared = LocalStore()

    @Published private(set) var album = Album()
    @Published var error: String?
    @Published var analyzing: Set<UUID> = []          // set by the analysis queue (LocalStore+Analysis.swift)
    @Published private(set) var recoveryRequired = false
    /// The camera is open or a video export is running; analysis is paused meanwhile.
    @Published private(set) var captureActive = false
    private var cameraActive = false
    private var exportActive = false

    let monitor = AnalysisMonitor()
    let analysisControl = AnalysisControl()
    let ruleBook: MotorRuleBook? = MotorRuleBook.bundled

    lazy var rulesFingerprint: String? = ruleBook?.fingerprint

    // Analysis queue state (used by LocalStore+Analysis.swift).
    var tasks: [UUID: Task<Void, Never>] = [:]
    var pendingIDs: [UUID] = []
    var currentJob: (id: UUID, step: AnalysisStep)?
    var attemptedSteps: Set<String> = []
    var detailRequested: Set<UUID> = []
    var userInitiated: Set<UUID> = []
    var motorCache: [UUID: MotorReport] = [:]
    var refreshing: Set<UUID> = []
    var backfilling = false
    /// The current batch: user-started videos since the queue was last idle (one progress, one Live Activity).
    var batch: [UUID] = []
    var batchFinished: Set<UUID> = []
    var batchRate: Double?
    var activeRelay: ProgressRelay?
    /// Set when background time ran out; analysis resumes when the app is active again.
    var analysisSuspended = false
    let background = BackgroundWork()
    var powerObserver: NSObjectProtocol?

    private var indexByID: [UUID: Int] = [:]
    private lazy var writer = AlbumWriter { error in
        Task { @MainActor in
            LocalStore.shared.error = tr("Changes could not be saved to storage. %@", error.localizedDescription)
        }
    }

    init() {
        do {
            try LocalFiles.prepare()
            let file = LocalFiles.url("album.json")
            if FileManager.default.fileExists(atPath: file.path) {
                album = try LocalFiles.jsonDecoder().decode(Album.self, from: Data(contentsOf: file, options: .mappedIfSafe))
                guard album.schemaVersion == 1 else { throw StoreError.unsupportedVersion }
            }
        } catch {
            recoveryRequired = true
            self.error = tr("Your album could not be opened. Existing files have been kept. %@", error.localizedDescription)
        }
        reindex()
        observePowerState()
    }

    enum StoreError: LocalizedError {
        case unsupportedVersion, recovery, invalidMoment, needsBirthday
        var errorDescription: String? {
            switch self {
            case .needsBirthday: return tr("Add the baby’s birthday in Profile to date videos by age.")
            case .unsupportedVersion: return tr("This album needs a newer version of the app.")
            case .recovery: return tr("The album needs to be recovered before saving.")
            case .invalidMoment: return tr("Choose a title and a clip within this video.")
            }
        }
    }

    // MARK: index

    /// Publishes the new index at once and hands it to the background writer.
    func commit(_ next: Album) throws {
        guard !recoveryRequired else { throw StoreError.recovery }
        album = next
        reindex()
        writer.submit(next)
    }

    /// Blocks until album.json is on disk. Called when the app moves to the background.
    func flushToDisk() { writer.flushNow() }

    private func reindex() {
        indexByID = Dictionary(album.memories.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func memory(_ id: UUID) -> Memory? {
        guard let i = indexByID[id], i < album.memories.count, album.memories[i].id == id else {
            return album.memories.first { $0.id == id }
        }
        return album.memories[i]
    }

    func update(_ memory: Memory) throws {
        guard let index = indexByID[memory.id] ?? album.memories.firstIndex(where: { $0.id == memory.id }) else { return }
        guard album.memories[index] != memory else { return }
        var next = album
        next.memories[index] = memory
        try commit(next)
    }

    func setBaby(_ baby: Baby) throws {
        let previous = album.baby
        var next = album
        next.baby = baby
        // Dates given as an age ("45 days old", "about 3 months") follow the birthday.
        if previous?.birthday != baby.birthday {
            for i in next.memories.indices {
                guard let setting = next.memories[i].dateSetting, !(setting.isExact),
                      let d = setting.resolved(birthday: baby.birthday) else { continue }
                Self.moveDate(of: next.memories[i].id, to: d, in: &next)
            }
        }
        try commit(next)
        // Age gates depend on (corrected) age: refresh observations from the stored tracks.
        if previous?.birthday != baby.birthday || previous?.dueDate != baby.dueDate { refreshAllObservations() }
    }

    // MARK: dates

    /// Sets the parent's own date for a video, or with nil goes back to the date found in the video.
    /// Moments from the video that carried its old date move with it; age-dependent observations
    /// are re-checked.
    func setDate(_ setting: DateSetting?, for id: UUID) throws {
        guard let m = memory(id) else { return }
        var next = album
        guard let i = next.memories.firstIndex(where: { $0.id == id }) else { return }
        // Keep the original date to go back to (older memories never stored it separately).
        if next.memories[i].capturedDate == nil { next.memories[i].capturedDate = m.date }
        let target: Date
        if let setting {
            guard let d = setting.resolved(birthday: album.baby?.birthday) else { throw StoreError.needsBirthday }
            target = d
        } else {
            target = next.memories[i].capturedDate ?? m.date
        }
        next.memories[i].dateSetting = setting
        Self.moveDate(of: id, to: target, in: &next)
        guard next.memories[i] != m else { return }
        try commit(next)
        refreshAllObservations()
    }

    /// Moves a memory to `date`, with its moments that were on the memory's old day.
    private static func moveDate(of id: UUID, to date: Date, in album: inout Album) {
        guard let i = album.memories.firstIndex(where: { $0.id == id }) else { return }
        let old = album.memories[i].date
        album.memories[i].date = date
        guard old != date else { return }
        for k in album.moments.indices where album.moments[k].memoryID == id
            && Calendar.current.isDate(album.moments[k].date, inSameDayAs: old) {
            album.moments[k].date = date
        }
    }

    // MARK: pose data

    /// Whether smoothed pose data exists (from the album index — no disk access during rendering).
    func hasPoseTrack(_ id: UUID) -> Bool { memory(id)?.hasPoseData ?? false }

    /// The smoothed track for drawing (binary search by time); loaded off the main actor.
    func poseTrack(for id: UUID) async -> PoseTrack? {
        await Task.detached(priority: .userInitiated) { () -> PoseTrack? in
            guard let url = PoseStore.processedURL(for: id) else { return nil }
            return try? PoseStore.load(url)
        }.value
    }

    /// The review digest (made from the raw track the first time for older memories).
    func reviewDigest(for id: UUID) async -> ReviewDigest? {
        let aspect = memory(id)?.aspectRatio
        return await Task.detached(priority: .userInitiated) { AnalysisPipeline.digest(id: id, aspect: aspect) }.value
    }

    // MARK: recording & import

    /// `recordedDate` is the date found in the video (origin `.metadata` unless given); without one
    /// the file's creation date (the recording time) is used — or for imports with `origin: .unknown`,
    /// a placeholder until the parent sets the date.
    func saveRecording(url: URL, recordedDate: Date? = nil, origin: DateOrigin? = nil, context: RecordingContext? = nil,
                       userInitiated: Bool = true) async throws -> UUID {
        // Register the original immediately; thumbnail and analysis can be retried.
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let created: Date? = await Task.detached(priority: .utility) {
            try? LocalFiles.protect(url)
            return try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
        }.value
        let id = UUID()
        let origin = origin ?? (recordedDate != nil ? .metadata : .recorded)
        let date = recordedDate ?? (origin == .unknown ? Date() : created ?? Date())
        var memory = Memory(id: id, date: date, title: "",
                            duration: duration, filename: url.lastPathComponent)
        memory.capturedDate = date
        memory.dateOrigin = origin
        memory.contextTag = context
        var next = album
        next.memories.append(memory)
        try commit(next)
        makeThumbnail(id: id, url: url, duration: duration)
        analyze(id, userInitiated: userInitiated)
        return id
    }

    /// Poster frame right away, so the album shows the new video before analysis finishes.
    func makeThumbnail(id: UUID, url: URL, duration: Double) {
        Task(priority: .userInitiated) {
            guard let jpeg = await VideoAnalyzer.thumbnail(url: url, duration: duration) else { return }
            let name = "\(id).jpg"
            let ok: Bool = await Task.detached(priority: .utility) {
                (try? LocalFiles.write(jpeg, to: name)) != nil
            }.value
            guard ok, var current = memory(id) else { return }
            ThumbnailCache.shared.invalidate(name)
            current.thumbnail = name
            try? update(current)
        }
    }

    /// `recordedDate` is the capture date read from the video; nil marks the date as unknown.
    func importStagedVideo(from sourceURL: URL, recordedDate: Date? = nil, context: RecordingContext? = nil) async throws -> UUID {
        // The Photos Transferable has already copied the user-selected asset into
        // this app's temporary directory. Move that staging file into protected
        // album storage without touching the original item in Photos.
        let ext = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension.lowercased()
        let destination = LocalFiles.url("imported-\(UUID().uuidString).\(ext)")
        do {
            try await Task.detached(priority: .userInitiated) {
                try LocalFiles.prepare()
                try FileManager.default.moveItem(at: sourceURL, to: destination)
                try LocalFiles.protect(destination)
            }.value
            return try await saveRecording(url: destination, recordedDate: recordedDate,
                                           origin: recordedDate == nil ? .unknown : .metadata, context: context)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    // MARK: moments & suggestions

    func addMoment(_ moment: Moment) async throws {
        guard let m = memory(moment.memoryID), !moment.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              moment.start.isFinite, moment.end.isFinite, moment.start >= 0,
              moment.end > moment.start, moment.end <= m.duration + 0.01 else { throw StoreError.invalidMoment }
        var saved = moment
        let filename = "moment-\(moment.id).jpg"
        let videoURL = LocalFiles.url(m.filename)
        let wrote: Bool = await Task.detached(priority: .userInitiated) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 240, height: 240)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)
            guard let result = try? await generator.image(at: CMTime(seconds: moment.start, preferredTimescale: 600)),
                  let data = UIImage(cgImage: result.image).jpegData(compressionQuality: 0.8) else { return false }
            return (try? LocalFiles.write(data, to: filename)) != nil
        }.value
        if wrote { saved.thumbnail = filename }
        guard memory(moment.memoryID) != nil else { throw StoreError.invalidMoment }
        var next = album
        next.moments.append(saved)
        try commit(next)
    }

    func confirmSuggestion(memoryID: UUID, suggestionID: UUID) async throws {
        guard let current = memory(memoryID),
              let suggestion = current.milestoneSuggestions?.first(where: { $0.id == suggestionID }),
              suggestion.status == .suggested else { return }
        let moment = Moment(memoryID: memoryID, title: suggestion.title, date: current.date,
                            start: suggestion.start, end: suggestion.end,
                            note: tr("Suggested by on-device pose analysis and saved after review."))
        try await addMoment(moment)
        guard var refreshed = memory(memoryID), var suggestions = refreshed.milestoneSuggestions,
              let index = suggestions.firstIndex(where: { $0.id == suggestionID }) else { return }
        suggestions[index].status = .confirmed
        suggestions[index].momentID = moment.id
        refreshed.milestoneSuggestions = suggestions
        try update(refreshed)
    }

    func dismissSuggestion(memoryID: UUID, suggestionID: UUID) throws {
        guard var current = memory(memoryID), var suggestions = current.milestoneSuggestions,
              let index = suggestions.firstIndex(where: { $0.id == suggestionID }) else { return }
        suggestions[index].status = .dismissed
        current.milestoneSuggestions = suggestions
        try update(current)
    }

    // MARK: deletion

    func deleteMoment(_ id: UUID) throws {
        let thumbnail = album.moments.first { $0.id == id }?.thumbnail
        var next = album
        next.moments.removeAll { $0.id == id }
        try commit(next)
        if let thumbnail {
            ThumbnailCache.shared.invalidate(thumbnail)
            Task.detached(priority: .utility) { LocalFiles.remove(thumbnail) }
        }
    }

    func deleteMemory(_ id: UUID) throws {
        guard let m = memory(id) else { return }
        tasks[id]?.cancel()
        pendingIDs.removeAll { $0 == id }
        analyzing.remove(id)
        detailRequested.remove(id)
        motorCache[id] = nil
        monitor.set(id, nil)
        let momentImages = album.moments.filter { $0.memoryID == id }.compactMap(\.thumbnail)
        var next = album
        next.memories.removeAll { $0.id == id }
        next.moments.removeAll { $0.memoryID == id }
        next.deletedFiles = (next.deletedFiles ?? []) + [m.filename]
        try commit(next)
        let names = [m.filename, m.thumbnail].compactMap { $0 } + PoseFiles.all(id) + momentImages
        names.forEach { ThumbnailCache.shared.invalidate($0) }
        Task.detached(priority: .utility) {
            var failed = false
            for name in names {
                let file = LocalFiles.url(name)
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                do { try FileManager.default.removeItem(at: file) } catch { failed = true }
            }
            if failed {
                await MainActor.run {
                    LocalStore.shared.error = tr("The memory was removed from the album, but a local file could not be erased. Cleanup will retry when the app reopens.")
                }
            }
        }
    }

    // MARK: recovery

    // Recover originals saved just before an app interruption, without duplicating
    // known recordings. This never overwrites a corrupt index.
    func recoverRecordings() async {
        guard !recoveryRequired else { return }
        let known = Set(album.memories.map(\.filename))
        let knownIDs = Set(album.memories.map(\.id.uuidString))
        let deleted = Set(album.deletedFiles ?? [])
        let orphans: [URL] = await Task.detached(priority: .utility) {
            let files = (try? FileManager.default.contentsOfDirectory(at: LocalFiles.root, includingPropertiesForKeys: nil)) ?? []
            for file in files where deleted.contains(file.lastPathComponent) { try? FileManager.default.removeItem(at: file) }
            // Derived data (pose tracks, observations, poster frames) of memories no longer in the album.
            let derived: Set<String> = [".raw.mgpose", ".mgpose", ".partial.mgpose", ".motor.json", ".review.json", ".poses.json", ".poses.raw.json", ".hmr3d", ".hmr3d.partial", ".jpg"]
            for file in files {
                let name = file.lastPathComponent
                guard name.count > 36 else { continue }
                let prefix = String(name.prefix(36))
                guard UUID(uuidString: prefix) != nil, !knownIDs.contains(prefix), derived.contains(String(name.dropFirst(36))) else { continue }
                try? FileManager.default.removeItem(at: file)
            }
            let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]
            return files.filter {
                videoExtensions.contains($0.pathExtension.lowercased()) && !known.contains($0.lastPathComponent) && !deleted.contains($0.lastPathComponent)
            }
        }.value
        for file in orphans {
            do { _ = try await saveRecording(url: file, userInitiated: false) }
            catch { self.error = tr("An interrupted recording could not be recovered; its file has been kept.") }
        }
    }

    /// Bytes used on this device by videos, pose tracks and images.
    func storageUsed() async -> Int64 {
        await Task.detached(priority: .utility) { LocalFiles.storageBytes() }.value
    }

    // MARK: camera

    /// While the camera is open, analysis pauses so recording stays smooth and cool.
    /// The camera is open: analysis waits so recording stays smooth.
    func setCaptureActive(_ active: Bool) {
        cameraActive = active
        applyForegroundPause()
    }

    /// A video export is running: analysis waits so the export (and the encoder) get the device.
    func setExportActive(_ active: Bool) {
        exportActive = active
        applyForegroundPause()
    }

    private func applyForegroundPause() {
        let active = cameraActive || exportActive
        guard captureActive != active else { return }
        captureActive = active
        analysisControl.setPaused(active)
        monitor.setPaused(active)
        updateBatch()
    }
}
