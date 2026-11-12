// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
//
// Share-sheet items that produce their file only when the parent picks a destination, so the
// menus open instantly and nothing large is written unless it is actually shared.

import Foundation
import AVFoundation
import CoreTransferable
import UniformTypeIdentifiers

/// Research pose JSON (PoseArchive), converted from the binary track on demand.
struct PoseJSONExport: Transferable {
    let memoryID: UUID
    let raw: Bool

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { item in
            let id = item.memoryID, raw = item.raw
            let url = try await Task.detached(priority: .userInitiated) { try PoseStore.exportJSON(id: id, raw: raw) }.value
            return SentTransferredFile(url)
        }
    }
}

/// A section of a recording, cut without re-encoding (passthrough), e.g. to show a clinician.
struct VideoClipExport: Transferable {
    let source: URL
    let start: Double
    let end: Double

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .quickTimeMovie) { clip in
            SentTransferredFile(try await clip.export())
        }
    }

    func export() async throws -> URL {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(tr("MoveGrow clip %1$@–%2$@", clock(start).replacingOccurrences(of: ":", with: "."), clock(end).replacingOccurrences(of: ":", with: ".")) + ".mov")
        session.timeRange = CMTimeRange(start: CMTime(seconds: max(0, start), preferredTimescale: 600),
                                        end: CMTime(seconds: end, preferredTimescale: 600))
        if #available(iOS 18.0, *) {
            try await session.export(to: url, as: .mov)
        } else {
            session.outputURL = url
            session.outputFileType = .mov
            await session.export()
            guard session.status == .completed else { throw session.error ?? CocoaError(.fileWriteUnknown) }
        }
        return url
    }
}
