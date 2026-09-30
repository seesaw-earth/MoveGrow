// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import CoreTransferable
import UniformTypeIdentifiers

// PhotosPicker hands the app a temporary file. Copy it immediately so the URL
// remains valid after the transfer callback returns. This staging copy is still
// local-only and is removed after LocalStore moves the video into the album.
struct ImportedPhotoVideo: Transferable {
    let url: URL
    let recordedDate: Date?

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("movegrow-import-\(UUID().uuidString)")
                .appendingPathExtension(ext)
            let sourceDate = try? received.file.resourceValues(forKeys: [.creationDateKey]).creationDate
            try FileManager.default.copyItem(at: received.file, to: copy)
            return Self(url: copy, recordedDate: sourceDate)
        }
    }
}
