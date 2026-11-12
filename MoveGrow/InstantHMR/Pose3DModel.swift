// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
//
// State of the review screen's 3D tab for one memory: the 3D track written by the analysis (InstantHMR
// engine), its smoothed copy for display, and what the baby figure needs (body scale, the mat or rug
// under it). Also the 3D data export.

import Foundation
import CoreTransferable
import UniformTypeIdentifiers

@MainActor final class Pose3DModel: ObservableObject {
    @Published private(set) var track: HMRTrack?
    @Published private(set) var smoothedTrack: HMRTrack?
    @Published private(set) var loaded = false
    @Published var smooth = true
    /// Typical body extent (m) of the track, so the 3D view keeps one scale.
    @Published private(set) var radius: Float = 1
    /// The baby's proportions over the video (the figure's thickness and trunk widths).
    @Published private(set) var shape = BodyShape.unknown
    /// The mat or rug under the baby figure (none for held babies).
    @Published private(set) var floor: BabyFloor?

    /// What the 3D view draws.
    var shown: HMRTrack? { smooth ? (smoothedTrack ?? track) : track }

    /// (Re)reads the memory's 3D track, e.g. after its analysis finished.
    func load(memoryID: UUID, context: RecordingContext) async {
        let stored = await Task.detached(priority: .userInitiated) { () -> (HMRTrack, HMRTrack, Float, BodyShape, BabyFloor?)? in
            guard let t = HMRTrack.load(memoryID: memoryID), t.detectedCount > 0 else { return nil }
            let shape = BabyFigure.measure(t)
            return (t, t.smoothed(), t.typicalRadius, shape, BabyFloor.make(track: t, context: context, torso: shape.torso))
        }.value
        if let stored {
            track = stored.0
            smoothedTrack = stored.1
            radius = stored.2
            shape = stored.3
            floor = stored.4
        } else {
            track = nil
            smoothedTrack = nil
            floor = nil
        }
        loaded = true
    }
}

/// The 3D track as research JSON, written only when a share destination is chosen.
struct HMRJSONExport: Transferable {
    let memoryID: UUID

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { item in
            let id = item.memoryID
            let url = try await Task.detached(priority: .userInitiated) { () throws -> URL in
                guard let track = HMRTrack.load(memoryID: id) else { throw CocoaError(.fileReadNoSuchFile) }
                return try track.exportJSON(memoryID: id)
            }.value
            return SentTransferredFile(url)
        }
    }
}
