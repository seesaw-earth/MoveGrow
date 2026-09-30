// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Combine
import AVFoundation
import UIKit

// Media, pose samples and metadata remain in Application Support, excluded from
// system backup. Export is always a deliberate user action. No network client.
enum LocalFiles {
    private static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
    static var root: URL { applicationSupport.appendingPathComponent("MoveGrow", isDirectory: true) }
    private static var legacyRoot: URL { applicationSupport.appendingPathComponent("LittleMoves", isDirectory: true) }

    static func prepare() throws {
        let fm = FileManager.default
        // Preserve memories created by pre-1.0 Little Moves development builds.
        // This migration is local-only and runs before the new MoveGrow directory is created.
        if !fm.fileExists(atPath: root.path), fm.fileExists(atPath: legacyRoot.path) {
            try fm.moveItem(at: legacyRoot, to: root)
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try protect(root)
    }
    static func protect(_ source: URL) throws {
        var url = source
        var flags = URLResourceValues(); flags.isExcludedFromBackup = true
        try url.setResourceValues(flags)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
    }
    static func url(_ filename: String) -> URL { root.appendingPathComponent(filename) }
    static func write<T: Encodable>(_ value: T, to filename: String) throws {
        try prepare()
        let data = try JSONEncoder().encode(value)
        try data.write(to: url(filename), options: .atomic)
        try protect(url(filename))
    }
    static func writePoseArchive(_ value: PoseArchive, to filename: String) throws {
        try prepare()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        try data.write(to: url(filename), options: .atomic)
        try protect(url(filename))
    }
}

@MainActor final class LocalStore: ObservableObject {
    @Published private(set) var album = Album()
    @Published var error: String?
    @Published private(set) var analyzing: Set<UUID> = []
    @Published private(set) var recoveryRequired = false
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var pendingIDs: [UUID] = []
    init() {
        do {
            try LocalFiles.prepare()
            let file = LocalFiles.url("album.json")
            if FileManager.default.fileExists(atPath: file.path) {
                album = try JSONDecoder().decode(Album.self, from: Data(contentsOf: file))
                guard album.schemaVersion == 1 else { throw StoreError.unsupportedVersion }
            }
        } catch {
            recoveryRequired = true
            self.error = "Your album could not be opened. Existing files have been kept. \(error.localizedDescription)"
        }
    }
    enum StoreError: LocalizedError {
        case unsupportedVersion, recovery, invalidMoment
        var errorDescription: String? {
            switch self {
            case .unsupportedVersion: return "This album needs a newer app version."
            case .recovery: return "Album recovery is required before saving."
            case .invalidMoment: return "Choose a title and a valid clip within this video."
            }
        }
    }
    // Commit the complete index atomically before publishing UI changes.
    private func commit(_ next: Album) throws {
        guard !recoveryRequired else { throw StoreError.recovery }
        try LocalFiles.write(next, to: "album.json")
        album = next
    }
    func setBaby(_ baby: Baby) throws {
        var next = album; next.baby = baby; try commit(next)
    }
    func memory(_ id: UUID) -> Memory? { album.memories.first { $0.id == id } }
    func poseURL(for id: UUID) -> URL? {
        let file = LocalFiles.url("\(id).poses.json")
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }
    func rawPoseURL(for id: UUID) -> URL? {
        let file = LocalFiles.url("\(id).poses.raw.json")
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }
    func update(_ memory: Memory) throws {
        var next = album
        guard let index = next.memories.firstIndex(where: { $0.id == memory.id }) else { return }
        next.memories[index] = memory; try commit(next)
    }
    func saveRecording(url: URL, recordedDate: Date? = nil) async throws -> UUID {
        // Register the original immediately; thumbnail and analysis can be retried.
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw CocoaError(.fileReadCorruptFile) }
        try LocalFiles.protect(url)
        let id = UUID()
        let date = recordedDate ?? (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        let memory = Memory(id: id, date: date, title: "A little moment", duration: duration, filename: url.lastPathComponent)
        var next = album; next.memories.append(memory); try commit(next)
        analyze(id)
        return id
    }
    func importStagedVideo(from sourceURL: URL, recordedDate: Date? = nil) async throws -> UUID {
        // The Photos Transferable has already copied the user-selected asset into
        // this app's temporary directory. Move that staging file into protected
        // album storage without touching the original item in Photos.
        try LocalFiles.prepare()
        let ext = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension.lowercased()
        let destination = LocalFiles.url("imported-\(UUID().uuidString).\(ext)")
        do {
            try await Task.detached(priority: .utility) {
                try FileManager.default.moveItem(at: sourceURL, to: destination)
                try LocalFiles.protect(destination)
            }.value
            return try await saveRecording(url: destination, recordedDate: recordedDate)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
    func addMoment(_ moment: Moment) async throws {
        guard let m = memory(moment.memoryID), !moment.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              moment.start.isFinite, moment.end.isFinite, moment.start >= 0,
              moment.end > moment.start, moment.end <= m.duration + 0.01 else { throw StoreError.invalidMoment }
        var saved = moment
        let imageTask = Task.detached(priority: .utility) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: LocalFiles.url(m.filename)))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 240, height: 240)
            guard let image = try? generator.copyCGImage(at: CMTime(seconds: moment.start, preferredTimescale: 600), actualTime: nil) else { return Optional<Data>.none }
            return UIImage(cgImage: image).jpegData(compressionQuality: 0.8)
        }
        let thumbnailData = await imageTask.value
        if let data = thumbnailData {
            let filename = "moment-\(moment.id).jpg"
            try data.write(to: LocalFiles.url(filename), options: .atomic)
            try LocalFiles.protect(LocalFiles.url(filename)); saved.thumbnail = filename
        }
        guard memory(moment.memoryID) != nil else { throw StoreError.invalidMoment }
        var next = album; next.moments.append(saved); try commit(next)
    }
    func confirmSuggestion(memoryID: UUID, suggestionID: UUID) async throws {
        guard let current = memory(memoryID),
              let suggestion = current.milestoneSuggestions?.first(where: { $0.id == suggestionID }),
              suggestion.status == .suggested else { return }
        let moment = Moment(memoryID: memoryID, title: suggestion.title, date: current.date,
                            start: suggestion.start, end: suggestion.end,
                            note: "Suggested by on-device pose analysis and saved after review.")
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

    func deleteMoment(_ id: UUID) throws {
        let thumbnail = album.moments.first { $0.id == id }?.thumbnail
        var next = album; next.moments.removeAll { $0.id == id }; try commit(next)
        if let thumbnail { try? FileManager.default.removeItem(at: LocalFiles.url(thumbnail)) }
    }
    func deleteMemory(_ id: UUID) throws {
        guard let m = memory(id) else { return }
        tasks[id]?.cancel(); pendingIDs.removeAll { $0 == id }; analyzing.remove(id)
        let momentImages = album.moments.filter { $0.memoryID == id }.compactMap(\.thumbnail)
        var next = album; next.memories.removeAll { $0.id == id }; next.moments.removeAll { $0.memoryID == id }
        next.deletedFiles = (next.deletedFiles ?? []) + [m.filename]
        try commit(next)
        for name in [m.filename, m.thumbnail, "\(id).poses.json", "\(id).poses.raw.json"].compactMap({ $0 }) + momentImages {
            let file = LocalFiles.url(name)
            if FileManager.default.fileExists(atPath: file.path) {
                do { try FileManager.default.removeItem(at: file) }
                catch { self.error = "The memory was removed from the album, but a local file could not be erased. Cleanup will retry when the app reopens." }
            }
        }
    }
    func resumePending() {
        for m in album.memories where m.report == nil && m.analysisError == nil { analyze(m.id) }
    }
    func analyze(_ id: UUID) {
        guard memory(id) != nil, !analyzing.contains(id) else { return }
        analyzing.insert(id); pendingIDs.append(id); startNextAnalysis()
    }
    private func startNextAnalysis() {
        guard tasks.isEmpty, !pendingIDs.isEmpty else { return }
        let id = pendingIDs.removeFirst()
        guard let memory = memory(id) else { analyzing.remove(id); startNextAnalysis(); return }
        tasks[id] = Task {
            do {
                let result = try await VideoAnalyzer.process(url: LocalFiles.url(memory.filename))
                try Task.checkCancellation()
                guard var current = self.memory(id) else { throw CancellationError() }
                let rawArchive = PoseArchive(
                    durationSeconds: current.duration, frames: result.rawSamples,
                    poseEstimator: result.poseEstimator, processing: "raw"
                )
                let processedArchive = PoseArchive(
                    durationSeconds: current.duration, frames: result.samples,
                    poseEstimator: result.poseEstimator, processing: result.poseProcessing
                )
                try LocalFiles.writePoseArchive(rawArchive, to: "\(id).poses.raw.json")
                try LocalFiles.writePoseArchive(processedArchive, to: "\(id).poses.json")
                let detected = MilestoneClassifier.classify(samples: result.samples, duration: current.duration, aspect: result.aspectRatio)
                let prior = current.milestoneSuggestions ?? []
                let resolvedKinds = Set(prior.filter { $0.status != .suggested }.map(\.kind))
                current.milestoneSuggestions = prior.filter { $0.status != .suggested } + detected.filter { !resolvedKinds.contains($0.kind) }
                current.report = result.report; current.analysisError = nil
                current.poseEstimator = result.poseEstimator
                current.poseProcessing = result.poseProcessing
                // A thumbnail failure must not discard a successful movement report.
                if let jpeg = result.thumbnail {
                    let name = "\(id).jpg"
                    if (try? jpeg.write(to: LocalFiles.url(name), options: .atomic)) != nil {
                        try? LocalFiles.protect(LocalFiles.url(name)); current.thumbnail = name
                    }
                }
                try update(current)
            } catch is CancellationError {
                // On relaunch, a pending original can be analyzed again.
            } catch {
                if var current = self.memory(id) {
                    current.analysisError = "Summary unavailable. Your video is safe. Tap Retry."
                    do { try update(current) } catch { self.error = error.localizedDescription }
                }
            }
            analyzing.remove(id); tasks.removeValue(forKey: id); startNextAnalysis()
        }
    }
    // Recover originals saved just before an app interruption, without duplicating
    // known recordings. This never overwrites a corrupt index.
    func recoverRecordings() async {
        guard !recoveryRequired else { return }
        let known = Set(album.memories.map(\.filename))
        let files = (try? FileManager.default.contentsOfDirectory(at: LocalFiles.root, includingPropertiesForKeys: nil)) ?? []
        let deleted = Set(album.deletedFiles ?? [])
        for file in files where deleted.contains(file.lastPathComponent) { try? FileManager.default.removeItem(at: file) }
        let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]
        for file in files where videoExtensions.contains(file.pathExtension.lowercased()) && !known.contains(file.lastPathComponent) && !deleted.contains(file.lastPathComponent) {
            do { _ = try await saveRecording(url: file) }
            catch { self.error = "An interrupted recording could not be recovered; its file has been kept." }
        }
    }
}
