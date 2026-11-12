// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

// Media, pose samples and metadata remain in Application Support, excluded from
// system backup. Export is always a deliberate user action. No network client.
enum LocalFiles {
    private static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
    static var root: URL { applicationSupport.appendingPathComponent("MoveGrow", isDirectory: true) }
    private static var legacyRoot: URL { applicationSupport.appendingPathComponent("LittleMoves", isDirectory: true) }

    private static let prepareLock = NSLock()
    private static var prepared = false

    /// Creates and protects the album directory once per launch (cheap after the first call).
    static func prepare() throws {
        prepareLock.lock(); defer { prepareLock.unlock() }
        if prepared, FileManager.default.fileExists(atPath: root.path) { return }
        let fm = FileManager.default
        // Preserve memories created by pre-1.0 Little Moves development builds.
        // This migration is local-only and runs before the new MoveGrow directory is created.
        if !fm.fileExists(atPath: root.path), fm.fileExists(atPath: legacyRoot.path) {
            try fm.moveItem(at: legacyRoot, to: root)
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try protect(root)
        prepared = true
    }

    static func protect(_ source: URL) throws {
        #if os(iOS)
        var url = source
        var flags = URLResourceValues(); flags.isExcludedFromBackup = true
        try url.setResourceValues(flags)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }

    static func url(_ filename: String) -> URL { root.appendingPathComponent(filename) }
    static func exists(_ filename: String) -> Bool { FileManager.default.fileExists(atPath: url(filename).path) }

    /// Atomic write followed by backup exclusion and data protection.
    static func write(_ data: Data, to filename: String) throws {
        try prepare()
        let target = url(filename)
        try data.write(to: target, options: .atomic)
        try protect(target)
    }

    static func write<T: Encodable>(_ value: T, to filename: String) throws {
        try write(jsonEncoder().encode(value), to: filename)
    }

    /// Metrics can legitimately be NaN/∞ (e.g. "no interval" with fewer than two events). Plain JSON
    /// cannot hold them, so they are stored as strings — otherwise one NaN would make a whole save fail.
    static func jsonEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return e
    }

    static func jsonDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return d
    }

    static func remove(_ filename: String) {
        let target = url(filename)
        if FileManager.default.fileExists(atPath: target.path) { try? FileManager.default.removeItem(at: target) }
    }

    /// Bytes used by the album directory (videos, pose tracks, images).
    static func storageBytes() -> Int64 {
        let keys: [URLResourceKey] = [.fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: keys) else { return 0 }
        return files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: Set(keys)).fileSize) ?? 0) }
    }
}

/// File names for one memory's derived data.
enum PoseFiles {
    static func raw(_ id: UUID) -> String { "\(id).raw.mgpose" }
    static func processed(_ id: UUID) -> String { "\(id).mgpose" }
    static func partial(_ id: UUID) -> String { "\(id).partial.mgpose" }
    static func motor(_ id: UUID) -> String { "\(id).motor.json" }
    static func review(_ id: UUID) -> String { "\(id).review.json" }
    static func legacyProcessed(_ id: UUID) -> String { "\(id).poses.json" }
    static func legacyRaw(_ id: UUID) -> String { "\(id).poses.raw.json" }
    /// Names used when exporting JSON for research (generated on demand).
    static func exportRawJSON(_ id: UUID) -> String { "\(id).poses.raw.json" }
    static func exportProcessedJSON(_ id: UUID) -> String { "\(id).poses.json" }
    /// InstantHMR 3D track (InstantHMR/HMRTrack.swift) and its detail-pass checkpoint.
    static func hmr(_ id: UUID) -> String { "\(id).hmr3d" }
    static func hmrPartial(_ id: UUID) -> String { "\(id).hmr3d.partial" }
    static func all(_ id: UUID) -> [String] {
        [raw(id), processed(id), partial(id), motor(id), review(id), legacyProcessed(id), legacyRaw(id), hmr(id), hmrPartial(id)]
    }
}

/// Serializes album.json writes off the main thread and coalesces bursts of commits.
final class AlbumWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "movegrow.album.writer", qos: .utility)
    private let lock = NSLock()
    private var latest: Album?
    private var scheduled = false
    private let filename: String
    private let onError: @Sendable (Error) -> Void

    init(filename: String = "album.json", onError: @escaping @Sendable (Error) -> Void) {
        self.filename = filename
        self.onError = onError
    }

    func submit(_ album: Album) {
        lock.lock()
        latest = album
        let schedule = !scheduled
        scheduled = true
        lock.unlock()
        if schedule { queue.async { self.flush() } }
    }

    /// Blocks until every submitted album is on disk (call before suspension).
    func flushNow() { queue.sync { self.flush() } }

    private func flush() {
        lock.lock()
        let next = latest
        latest = nil
        scheduled = false
        lock.unlock()
        guard let next else { return }
        do { try LocalFiles.write(next, to: filename) } catch { onError(error) }
    }
}
