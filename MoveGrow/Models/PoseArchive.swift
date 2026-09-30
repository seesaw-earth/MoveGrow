// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Portable, research-friendly representation of all 2D pose samples from one video.
/// Coordinates are normalized to 0...1 with the origin at the displayed video's top-left.
struct PoseConnection: Codable, Hashable {
    var from: String
    var to: String
}

struct PoseArchive: Codable {
    var schemaVersion: Int = 2
    var generatedAt: Date = Date()
    var poseEstimator: String
    var processing: String?
    var durationSeconds: Double
    var nominalSampleIntervalSeconds: Double
    var coordinateSystem: String = "normalized-top-left"
    var coordinateRange: String = "0...1"
    var jointSchema: String? = "coco17-plus-derived-neck-root"
    var subjectSelection: String? = "largest-person-box-per-frame"
    var jointNames: [String]
    var connections: [PoseConnection]
    var frames: [MotionSample]

    init(durationSeconds: Double, frames: [MotionSample], poseEstimator: String, processing: String) {
        self.durationSeconds = durationSeconds
        self.frames = frames
        self.poseEstimator = poseEstimator
        self.processing = processing
        self.jointNames = BodyJoint.allCases.map(\.rawValue)
        self.connections = BodyJoint.connections.map { PoseConnection(from: $0.0.rawValue, to: $0.1.rawValue) }
        let deltas = zip(frames, frames.dropFirst()).map { $1.time - $0.time }.filter { $0.isFinite && $0 > 0 }
        if deltas.isEmpty {
            self.nominalSampleIntervalSeconds = 1.0 / 15.0
        } else {
            let sorted = deltas.sorted()
            self.nominalSampleIntervalSeconds = sorted[sorted.count / 2]
        }
    }
}
