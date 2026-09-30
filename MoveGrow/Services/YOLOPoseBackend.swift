// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import CoreGraphics
import CoreImage
import UltralyticsYOLO

/// Loads the official YOLO26l-pose Core ML model once and reuses it for all
/// offline video analysis. The verified Core ML model is compiled into the
/// app bundle at build time. The installed app performs no model download, and
/// video frames are never uploaded.
final class YOLOPoseModelProvider: @unchecked Sendable {
    static let shared = YOLOPoseModelProvider()

    static let estimatorID = "ultralytics-yolo26l-pose-coreml-bundled"
    static let modelName = "yolo26l-pose"

    private let lock = NSLock()
    private var loadedModel: YOLO?
    private var loadingModel: YOLO?
    private var isLoading = false
    private var waiters: [CheckedContinuation<YOLO, Error>] = []

    private init() {}

    func model() async throws -> YOLO {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let loadedModel {
                lock.unlock()
                continuation.resume(returning: loadedModel)
                return
            }
            waiters.append(continuation)
            let shouldStart = !isLoading
            if shouldStart { isLoading = true }
            lock.unlock()

            if shouldStart { startLoading() }
        }
    }

    private func startLoading() {
        // yolo26l-pose.mlmodelc is compiled into the app bundle by
        // Scripts/bundle-yolo-pose.sh during the Xcode build. The installed app
        // therefore performs no model download and can analyze fully offline.
        let instance = YOLO(
            Self.modelName,
            task: .pose,
            useGpu: true,
            numItemsThreshold: 4
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let model):
                model.setThresholds(numItems: 4, confidence: 0.16, iou: 0.70)
                self.finish(.success(model))
            case .failure(let error):
                self.finish(.failure(error))
            }
        }
        lock.lock()
        if loadedModel == nil { loadingModel = instance }
        lock.unlock()
    }

    private func finish(_ result: Result<YOLO, Error>) {
        lock.lock()
        if case .success(let model) = result { loadedModel = model }
        loadingModel = nil
        isLoading = false
        let continuations = waiters
        waiters.removeAll()
        lock.unlock()
        for continuation in continuations { continuation.resume(with: result) }
    }
}

/// MoveGrow is intentionally single-subject. Parents are filming their child,
/// so each frame keeps only the detected person occupying the largest fraction
/// of the image. No secondary person identity, history, IoU, centrality or motion
/// continuity is retained. Other detections are discarded immediately.
enum YOLOLargestPersonSelector {
    static func select(_ result: YOLOResult) -> (box: Box, keypoints: Keypoints)? {
        let count = min(result.boxes.count, result.keypointsList.count)
        guard count > 0 else { return nil }

        var bestIndex: Int?
        var bestArea = -Double.infinity
        var bestConfidence = -Double.infinity

        for index in 0..<count {
            let rect = result.boxes[index].xywhn.standardized
            guard rect.width.isFinite, rect.height.isFinite,
                  rect.width > 0, rect.height > 0 else { continue }

            let area = Double(rect.width * rect.height)
            let confidence = Double(result.boxes[index].conf)
            if area > bestArea || (abs(area - bestArea) < 1e-9 && confidence > bestConfidence) {
                bestArea = area
                bestConfidence = confidence
                bestIndex = index
            }
        }

        guard let bestIndex else { return nil }
        return (result.boxes[bestIndex], result.keypointsList[bestIndex])
    }
}

enum YOLOPoseAdapter {
    /// COCO keypoint order used by YOLO pose models.
    private static let cocoNames = [
        "nose", "leftEye", "rightEye", "leftEar", "rightEar",
        "leftShoulder", "rightShoulder", "leftElbow", "rightElbow",
        "leftWrist", "rightWrist", "leftHip", "rightHip",
        "leftKnee", "rightKnee", "leftAnkle", "rightAnkle"
    ]

    static func sample(result: YOLOResult, time: Double, light: ([String: MotionPoint]) -> Bool) -> MotionSample {
        guard let selected = YOLOLargestPersonSelector.select(result) else {
            return MotionSample(time: time, points: [:], lightOK: false)
        }
        let keypoints = selected.keypoints
        var points: [String: MotionPoint] = [:]
        let count = min(cocoNames.count, keypoints.xyn.count, keypoints.conf.count)
        for index in 0..<count {
            let p = keypoints.xyn[index]
            let confidence = Double(keypoints.conf[index])
            guard p.x.isFinite, p.y.isFinite, confidence.isFinite,
                  p.x >= 0, p.x <= 1, p.y >= 0, p.y <= 1, confidence > 0.03 else { continue }
            points[cocoNames[index]] = MotionPoint(x: Double(p.x), y: Double(p.y), confidence: confidence)
        }
        deriveMidpoint(name: "neck", a: "leftShoulder", b: "rightShoulder", points: &points)
        deriveMidpoint(name: "root", a: "leftHip", b: "rightHip", points: &points)
        let rect = selected.box.xywhn.standardized
        let subjectBox = MotionBox(
            x: Double(rect.minX), y: Double(rect.minY),
            width: Double(rect.width), height: Double(rect.height),
            confidence: Double(selected.box.conf)
        )
        return MotionSample(time: time, points: points, lightOK: light(points), subjectBox: subjectBox)
    }

    private static func deriveMidpoint(name: String, a: String, b: String, points: inout [String: MotionPoint]) {
        guard let pa = points[a], let pb = points[b] else { return }
        points[name] = MotionPoint(
            x: (pa.x + pb.x) / 2,
            y: (pa.y + pb.y) / 2,
            confidence: min(pa.confidence, pb.confidence) * 0.98
        )
    }
}
