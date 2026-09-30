// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only

//
//  PoseFrame.swift
//  MoveGrow
//
//  Lightweight representation of a single estimated pose at one timestamp.
//  The primary backend is YOLO26l-pose/CoreML (COCO-17 joints) with derived
//  neck/root midpoints. Apple Vision is retained only as an explicit fallback.
//

import Foundation
import CoreGraphics

enum BodyJoint: String, Codable, CaseIterable {
    case nose, leftEye, rightEye, leftEar, rightEar
    case neck, root
    case leftShoulder, rightShoulder
    case leftElbow, rightElbow
    case leftWrist, rightWrist
    case leftHip, rightHip
    case leftKnee, rightKnee
    case leftAnkle, rightAnkle

    /// Bone connections for skeleton rendering.
    static let connections: [(BodyJoint, BodyJoint)] = [
        (.leftEar, .leftEye), (.leftEye, .nose), (.nose, .rightEye), (.rightEye, .rightEar),
        (.nose, .neck), (.neck, .root),
        (.neck, .leftShoulder), (.neck, .rightShoulder),
        (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
        (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
        (.root, .leftHip), (.root, .rightHip),
        (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
        (.rightHip, .rightKnee), (.rightKnee, .rightAnkle)
    ]
}

struct JointPoint: Codable, Hashable {
    var x: Double          // normalized 0...1, origin top-left (already converted)
    var y: Double
    var confidence: Double

    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

struct PoseFrame: Codable, Hashable {
    var timestamp: TimeInterval
    var joints: [String: JointPoint]   // keyed by BodyJoint.rawValue

    func point(_ joint: BodyJoint) -> JointPoint? {
        joints[joint.rawValue]
    }

    /// Mean confidence across detected joints (generic human-body pose confidence).
    var meanConfidence: Double {
        guard !joints.isEmpty else { return 0 }
        return joints.values.map(\.confidence).reduce(0, +) / Double(joints.count)
    }
}
