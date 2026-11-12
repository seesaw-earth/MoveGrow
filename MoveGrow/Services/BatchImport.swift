// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
//
// Import of up to 10 videos picked in Photos, at most 20 minutes in total. Videos are copied one
// after another; each starts analysing as soon as it is in the album, so the first results arrive
// while the rest are still being copied. A video that would take the batch over 20 minutes is
// skipped (the originals in Photos are never changed).

import Foundation
import SwiftUI
import PhotosUI
import AVFoundation

@MainActor final class BatchImporter: ObservableObject {
    static let maxVideos = 10
    static let maxTotalSeconds = 20.0 * 60

    struct State: Equatable {
        var total: Int
        var done = 0
        var added: [UUID] = []
        var acceptedSeconds = 0.0
        var skippedForLength = 0
        var failed = 0
        /// Imported without a filming date in the file.
        var undated = 0
        var finished = false
    }

    @Published private(set) var state: State?

    var isImporting: Bool { state.map { !$0.finished } ?? false }
    /// Copy progress of the current import (0…1).
    var fraction: Double { state.map { Double($0.done) / Double(max(1, $0.total)) } ?? 0 }

    func start(_ items: [PhotosPickerItem], store: LocalStore) {
        guard !isImporting, !items.isEmpty else { return }
        let picked = Array(items.prefix(Self.maxVideos))
        state = State(total: picked.count)
        Task {
            for item in picked {
                await importOne(item, store: store)
                state?.done += 1
            }
            state?.finished = true
        }
    }

    func clearIfFinished() {
        if state?.finished == true { state = nil }
    }

    private func importOne(_ item: PhotosPickerItem, store: LocalStore) async {
        do {
            guard let staged = try await item.loadTransferable(type: ImportedPhotoVideo.self) else {
                throw CocoaError(.fileReadUnknown)
            }
            defer { try? FileManager.default.removeItem(at: staged.url) }
            let asset = AVURLAsset(url: staged.url)
            let seconds = try await asset.load(.duration).seconds
            guard seconds.isFinite, seconds > 0 else { throw CocoaError(.fileReadCorruptFile) }
            if (state?.acceptedSeconds ?? 0) + seconds > Self.maxTotalSeconds + 0.5 {
                state?.skippedForLength += 1
                return
            }
            // No date in the video: the parent is asked for one in the album (the copy's file
            // date is only the time of the transfer).
            let recorded = await Self.recordingDate(asset)
            let id = try await store.importStagedVideo(from: staged.url, recordedDate: recorded)
            if recorded == nil { state?.undated += 1 }
            state?.acceptedSeconds += seconds
            state?.added.append(id)
        } catch {
            state?.failed += 1
        }
    }

    /// The capture date stored in the movie, when there is one: the camera's own QuickTime
    /// creation date first (it survives edits and re-exports), then the movie's creation date.
    private static func recordingDate(_ asset: AVURLAsset) async -> Date? {
        func date(of item: AVMetadataItem) async -> Date? {
            let value = try? await item.load(.dateValue)
            if let d = CaptureDate.plausible(value) { return d }
            let text = try? await item.load(.stringValue)
            return text.flatMap(CaptureDate.parse).flatMap { CaptureDate.plausible($0) }
        }
        if let items = try? await asset.load(.metadata) {
            for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .quickTimeMetadataCreationDate) {
                if let d = await date(of: item) { return d }
            }
        }
        if let item = try? await asset.load(.creationDate), let d = await date(of: item) { return d }
        return nil
    }
}
