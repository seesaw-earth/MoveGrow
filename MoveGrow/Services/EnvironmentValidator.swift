// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only

//
//  EnvironmentValidator.swift
//  MoveGrow
//
//  Real-time filming guidance for capture quality. The goal is deliberately
//  narrow: make sure the body is detected, all four limbs are visible, the
//  important joints stay inside a central safe area, framing is useful for
//  movement analysis, and the body itself is adequately illuminated.
//

import Foundation
import CoreGraphics

enum FramingDirection: Equatable {
    case none
    case moveLeft
    case moveRight
    case moveUp
    case moveDown
    case moveCloser
    case moveFarther

    var message: String {
        switch self {
        case .none: return "Body is centered with safe margins"
        case .moveLeft: return "Move camera left"
        case .moveRight: return "Move camera right"
        case .moveUp: return "Move camera up"
        case .moveDown: return "Move camera down"
        case .moveCloser: return "Move camera closer"
        case .moveFarther: return "Move camera farther away"
        }
    }

    var systemImage: String {
        switch self {
        case .none: return "checkmark.circle.fill"
        case .moveLeft: return "arrow.left.circle.fill"
        case .moveRight: return "arrow.right.circle.fill"
        case .moveUp: return "arrow.up.circle.fill"
        case .moveDown: return "arrow.down.circle.fill"
        case .moveCloser: return "plus.magnifyingglass"
        case .moveFarther: return "minus.magnifyingglass"
        }
    }
}

struct EnvironmentChecks: Equatable {
    /// Whole-scene luminance is retained for debugging/fallback.
    var sceneBrightness: Double

    /// Preferred lighting metric: mean luminance measured inside the detected
    /// body region. Falls back to sceneBrightness until a stable pose exists.
    var bodyBrightness: Double

    var bodyConfidence: Double
    var limbVisibility: Double
    var framing: Double

    /// Normalized body bounding-box properties used for directional guidance.
    var bodyCenterX: Double
    var bodyCenterY: Double
    var bodyFill: Double

    var missingCriticalJoints: [BodyJoint]
    var outOfSafeAreaJoints: [BodyJoint]

    static let empty = EnvironmentChecks(
        sceneBrightness: 0,
        bodyBrightness: 0,
        bodyConfidence: 0,
        limbVisibility: 0,
        framing: 0,
        bodyCenterX: 0.5,
        bodyCenterY: 0.5,
        bodyFill: 0,
        missingCriticalJoints: EnvironmentValidator.criticalJoints,
        outOfSafeAreaJoints: []
    )

    /// Compatibility accessor used by existing score / UI code.
    var brightness: Double { bodyBrightness }

    var lightingOK: Bool { bodyBrightness >= 0.30 && bodyBrightness <= 0.90 }
    var bodyOK: Bool { bodyConfidence >= 0.45 }
    var limbsOK: Bool { limbVisibility >= 0.99 && missingLimbEndpoints.isEmpty }
    var framingOK: Bool {
        framing >= 0.82 &&
        outOfSafeAreaJoints.isEmpty &&
        framingDirection == .none
    }

    var allClear: Bool { lightingOK && bodyOK && limbsOK && framingOK }

    var quality: Double {
        let l = lightingOK ? 1.0 : min(1, max(0, bodyBrightness / 0.5))
        return (l + bodyConfidence + limbVisibility + framing) / 4
    }

    var lightingMessage: String {
        if bodyBrightness < 0.30 { return "Body is too dark — add soft, even light" }
        if bodyBrightness > 0.90 { return "Body is too bright — reduce glare or backlight" }
        return "Lighting on the body looks good"
    }

    var bodyMessage: String {
        bodyOK ? "Body pose detected" : "Position the full body in the guide"
    }

    var limbsMessage: String {
        let missing = missingLimbEndpoints
        guard !missing.isEmpty else {
            return limbVisibility >= 0.99
                ? "Both hands and feet are visible"
                : "Hold position while all four limbs are confirmed"
        }

        if missing.contains(.leftWrist) && missing.contains(.rightWrist) {
            return "Keep both hands visible"
        }
        if missing.contains(.leftAnkle) && missing.contains(.rightAnkle) {
            return "Keep both feet visible"
        }
        if missing.contains(.leftWrist) { return "Keep the left hand visible" }
        if missing.contains(.rightWrist) { return "Keep the right hand visible" }
        if missing.contains(.leftAnkle) { return "Keep the left foot visible" }
        if missing.contains(.rightAnkle) { return "Keep the right foot visible" }
        return "Keep all four limbs visible"
    }

    var framingDirection: FramingDirection {
        guard bodyOK else { return .none }

        // Distance first: a body that is too large is at immediate risk of
        // clipping moving limbs; a very small body loses useful pose detail.
        if bodyFill > EnvironmentValidator.maximumBodyFill { return .moveFarther }
        if bodyFill > 0, bodyFill < EnvironmentValidator.minimumBodyFill { return .moveCloser }

        let dx = bodyCenterX - 0.5
        let dy = bodyCenterY - 0.5

        // Tell the operator how to move the camera, not the subject. If the
        // body appears right in frame, moving the camera right re-centers it.
        if abs(dx) >= abs(dy), abs(dx) > EnvironmentValidator.centerToleranceX {
            return dx > 0 ? .moveRight : .moveLeft
        }
        if abs(dy) > EnvironmentValidator.centerToleranceY {
            return dy > 0 ? .moveDown : .moveUp
        }
        return .none
    }

    var framingMessage: String {
        guard bodyOK else { return "Center the body in view" }

        if framingDirection != .none {
            return framingDirection.message
        }

        guard !outOfSafeAreaJoints.isEmpty else {
            return framingOK
                ? "Body is centered with safe margins"
                : "Keep the full body centered inside the guide"
        }

        let joints = Set(outOfSafeAreaJoints)
        if joints.contains(.leftWrist) || joints.contains(.rightWrist) {
            return "Bring both hands farther inside the guide"
        }
        if joints.contains(.leftAnkle) || joints.contains(.rightAnkle) {
            return "Bring both feet farther inside the guide"
        }
        return "Re-center the body inside the guide"
    }

    var primaryGuidance: String {
        if !lightingOK { return lightingMessage }
        if !bodyOK { return bodyMessage }
        if !limbsOK { return limbsMessage }
        if !framingOK { return framingMessage }
        return "Ready — full body is visible, centered, and well lit"
    }

    var primaryGuidanceIcon: String {
        if !lightingOK { return "sun.max.trianglebadge.exclamationmark" }
        if !bodyOK || !limbsOK { return "figure.stand.line.dotted.figure.stand" }
        if !framingOK { return framingDirection.systemImage }
        return "checkmark.circle.fill"
    }

    private var missingLimbEndpoints: [BodyJoint] {
        missingCriticalJoints.filter { EnvironmentValidator.limbEndpoints.contains($0) }
    }
}

struct EnvironmentValidator {
    static let limbEndpoints: [BodyJoint] = [
        .leftWrist, .rightWrist, .leftAnkle, .rightAnkle
    ]

    static let criticalJoints: [BodyJoint] = [
        .nose,
        .leftShoulder, .rightShoulder,
        .leftWrist, .rightWrist,
        .leftHip, .rightHip,
        .leftAnkle, .rightAnkle
    ]

    static let safeArea = CGRect(x: 0.12, y: 0.10, width: 0.76, height: 0.80)
    static let minimumJointConfidence = 0.28

    // These are product calibration defaults, not clinical thresholds. They
    // should be tuned against representative recordings before deployment.
    static let minimumBodyFill = 0.16
    static let maximumBodyFill = 0.58
    static let centerToleranceX = 0.09
    static let centerToleranceY = 0.10

    static func evaluate(
        sceneLuma: Double,
        bodyLuma: Double?,
        pose: PoseFrame?
    ) -> EnvironmentChecks {
        guard let pose else {
            return EnvironmentChecks(
                sceneBrightness: sceneLuma,
                bodyBrightness: bodyLuma ?? sceneLuma,
                bodyConfidence: 0,
                limbVisibility: 0,
                framing: 0,
                bodyCenterX: 0.5,
                bodyCenterY: 0.5,
                bodyFill: 0,
                missingCriticalJoints: criticalJoints,
                outOfSafeAreaJoints: []
            )
        }

        let confidentPoints = pose.joints.values.filter { $0.confidence >= minimumJointConfidence }
        let bodyConfidence: Double
        if confidentPoints.isEmpty {
            bodyConfidence = 0
        } else {
            bodyConfidence = confidentPoints.map(\.confidence).reduce(0, +) / Double(confidentPoints.count)
        }

        let missing = criticalJoints.filter { joint in
            guard let p = pose.point(joint) else { return true }
            return p.confidence < minimumJointConfidence
        }

        let visibleLimbCount = limbEndpoints.reduce(into: 0) { count, joint in
            if let p = pose.point(joint), p.confidence >= minimumJointConfidence {
                count += 1
            }
        }
        let limbVisibility = Double(visibleLimbCount) / Double(limbEndpoints.count)

        let outOfSafeArea = criticalJoints.compactMap { joint -> BodyJoint? in
            guard let p = pose.point(joint), p.confidence >= minimumJointConfidence else { return nil }
            return safeArea.contains(CGPoint(x: p.x, y: p.y)) ? nil : joint
        }

        let bounds = bodyBounds(for: pose)
        let framing = framingScore(
            for: pose,
            missing: missing,
            outOfSafeArea: outOfSafeArea,
            bounds: bounds
        )

        return EnvironmentChecks(
            sceneBrightness: sceneLuma,
            bodyBrightness: bodyLuma ?? sceneLuma,
            bodyConfidence: bodyConfidence,
            limbVisibility: limbVisibility,
            framing: framing,
            bodyCenterX: bounds.map { Double($0.midX) } ?? 0.5,
            bodyCenterY: bounds.map { Double($0.midY) } ?? 0.5,
            bodyFill: bounds.map { Double($0.width * $0.height) } ?? 0,
            missingCriticalJoints: missing,
            outOfSafeAreaJoints: outOfSafeArea
        )
    }

    /// Normalized (top-left origin) body box derived from detected critical
    /// joints. The crop is padded because arms/legs can move beyond the torso.
    static func bodyRegion(for pose: PoseFrame, padding: Double = 0.10) -> CGRect? {
        guard let raw = bodyBounds(for: pose) else { return nil }
        let x0 = max(0, raw.minX - padding)
        let y0 = max(0, raw.minY - padding)
        let x1 = min(1, raw.maxX + padding)
        let y1 = min(1, raw.maxY + padding)
        return CGRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }

    private static func bodyBounds(for pose: PoseFrame) -> CGRect? {
        let pts = criticalJoints.compactMap { joint -> JointPoint? in
            guard let p = pose.point(joint), p.confidence >= minimumJointConfidence else { return nil }
            return p
        }
        guard pts.count >= 5 else { return nil }

        let xs = pts.map(\.x)
        let ys = pts.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return nil }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func framingScore(
        for pose: PoseFrame,
        missing: [BodyJoint],
        outOfSafeArea: [BodyJoint],
        bounds: CGRect?
    ) -> Double {
        let pts = criticalJoints.compactMap { joint -> JointPoint? in
            guard let p = pose.point(joint), p.confidence >= minimumJointConfidence else { return nil }
            return p
        }
        guard pts.count >= 5, let bounds else { return 0 }

        let safeFraction = Double(max(0, pts.count - outOfSafeArea.count)) / Double(criticalJoints.count)
        let completeness = Double(criticalJoints.count - missing.count) / Double(criticalJoints.count)
        let centerDistance = hypot(bounds.midX - 0.5, bounds.midY - 0.5)
        let centered = max(0, 1 - centerDistance / 0.30)

        let fill = bounds.width * bounds.height
        let fillScore: Double
        if fill < minimumBodyFill {
            fillScore = max(0, fill / minimumBodyFill)
        } else if fill > maximumBodyFill {
            fillScore = max(0, 1 - (fill - maximumBodyFill) / 0.25)
        } else {
            fillScore = 1
        }

        return min(1,
                   safeFraction * 0.42 +
                   completeness * 0.25 +
                   centered * 0.20 +
                   fillScore * 0.13)
    }
}
