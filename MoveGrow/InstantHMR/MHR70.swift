// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
//
// The 70 InstantHMR / SAM 3D Body keypoints (MHR70 order, instanthmr/skeleton.py) and how they map
// onto MoveGrow's 19 joints. Foundation only.

import Foundation

enum MHR70 {
    static let count = 70
    static let names = [
        "nose", "left_eye", "right_eye", "left_ear", "right_ear", "left_shoulder", "right_shoulder",
        "left_elbow", "right_elbow", "left_hip", "right_hip", "left_knee", "right_knee", "left_ankle", "right_ankle",
        "left_big_toe", "left_small_toe", "left_heel", "right_big_toe", "right_small_toe", "right_heel",
        "right_thumb4", "right_thumb3", "right_thumb2", "right_thumb_third_joint",
        "right_forefinger4", "right_forefinger3", "right_forefinger2", "right_forefinger_third_joint",
        "right_middle_finger4", "right_middle_finger3", "right_middle_finger2", "right_middle_finger_third_joint",
        "right_ring_finger4", "right_ring_finger3", "right_ring_finger2", "right_ring_finger_third_joint",
        "right_pinky_finger4", "right_pinky_finger3", "right_pinky_finger2", "right_pinky_finger_third_joint",
        "right_wrist",
        "left_thumb4", "left_thumb3", "left_thumb2", "left_thumb_third_joint",
        "left_forefinger4", "left_forefinger3", "left_forefinger2", "left_forefinger_third_joint",
        "left_middle_finger4", "left_middle_finger3", "left_middle_finger2", "left_middle_finger_third_joint",
        "left_ring_finger4", "left_ring_finger3", "left_ring_finger2", "left_ring_finger_third_joint",
        "left_pinky_finger4", "left_pinky_finger3", "left_pinky_finger2", "left_pinky_finger_third_joint",
        "left_wrist",
        "left_olecranon", "right_olecranon", "left_cubital_fossa", "right_cubital_fossa", "left_acromion",
        "right_acromion", "neck",
    ]

    static let nose = 0, leftEar = 3, rightEar = 4, leftShoulder = 5, rightShoulder = 6
    static let leftElbow = 7, rightElbow = 8, leftHip = 9, rightHip = 10, leftKnee = 11, rightKnee = 12
    static let leftAnkle = 13, rightAnkle = 14, rightWrist = 41, leftWrist = 62, neck = 69
    static let leftBigToe = 15, leftSmallToe = 16, leftHeel = 17, rightBigToe = 18, rightSmallToe = 19, rightHeel = 20
    /// Base of the middle finger: only for pointing the baby figure's mittens (drawing, not analysis).
    static let rightMiddleKnuckle = 32, leftMiddleKnuckle = 53
    /// Tips of the shoulders (surface points): the top corners of the baby figure's trunk.
    static let leftAcromion = 67, rightAcromion = 68

    /// Finger points (21–40 right hand, 42–61 left hand): drawn, exported, never used in the analysis.
    static func isFinger(_ j: Int) -> Bool { (21...40).contains(j) || (42...61).contains(j) }

    /// MHR70 index of each COCO-17 keypoint (nose … right ankle), for comparing with YOLO.
    static let coco17 = [0, 1, 2, 3, 4, 5, 6, 7, 8, 62, 41, 9, 10, 11, 12, 13, 14]

    /// (MoveGrow joint, MHR70 index) for the 17 joints both share; MJ.neck and MJ.root are midpoints.
    static let toMJ: [(mj: Int, mhr: Int)] = [
        (MJ.nose, 0), (MJ.leftEye, 1), (MJ.rightEye, 2), (MJ.leftEar, 3), (MJ.rightEar, 4),
        (MJ.leftShoulder, 5), (MJ.rightShoulder, 6), (MJ.leftElbow, 7), (MJ.rightElbow, 8),
        (MJ.leftWrist, 62), (MJ.rightWrist, 41), (MJ.leftHip, 9), (MJ.rightHip, 10),
        (MJ.leftKnee, 11), (MJ.rightKnee, 12), (MJ.leftAnkle, 13), (MJ.rightAnkle, 14),
    ]

    /// Body, feet and face lines.
    static let body: [(Int, Int)] = [
        (0, 1), (0, 2), (1, 3), (2, 4), (5, 6), (5, 7), (7, 62), (6, 8), (8, 41), (5, 9), (6, 10), (9, 10),
        (9, 11), (11, 13), (10, 12), (12, 14), (13, 15), (13, 16), (13, 17), (14, 18), (14, 19), (14, 20),
    ]

    /// Finger chains: wrist → third joint → 2 → 3 → 4 (tip), both hands. Drawing only.
    static let hands: [(Int, Int)] = {
        var e: [(Int, Int)] = []
        for (wrist, first) in [(41, 21), (62, 42)] {
            for finger in 0..<5 {
                let tip = first + 4 * finger                 // …4, …3, …2, …_third_joint
                e += [(wrist, tip + 3), (tip + 3, tip + 2), (tip + 2, tip + 1), (tip + 1, tip)]
            }
        }
        return e
    }()

    static let lines: [(Int, Int)] = body + hands

    /// Whether a line belongs to the person's left side (drawn in another colour).
    static func isLeft(_ a: Int, _ b: Int) -> Bool {
        names[a].hasPrefix("left") || names[b].hasPrefix("left")
    }
}
