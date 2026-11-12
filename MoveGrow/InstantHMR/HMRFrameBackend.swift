// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
//
// InstantHMR as an analysis backend for VideoAnalyzer: the person box from the bundled YOLO26l-pose
// (largest person), then InstantHMR (crop → network → kinematic fit → MHR keypoints). Returns
// MoveGrow's 19 joints from InstantHMR's 2D projection, so everything that reads 2D tracks keeps
// working, plus the 3D payload that is stored as the memory's `.hmr3d` — with YOLO's own keypoints of
// the same person, which the box detector computes anyway (for the YOLO pose page; not analysed).

import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

final class HMRFrameBackend {
    let config: HMRConfig
    private let net: PoseNet
    private let estimator: InstantHMREstimator
    /// Confidence given to InstantHMR joints inside the frame (it predicts every joint).
    static let jointConfidence: Float = 0.9

    private init(config: HMRConfig, net: PoseNet, estimator: InstantHMREstimator) {
        self.config = config
        self.net = net
        self.estimator = estimator
    }

    // One instance, like PoseNet: model loading is the slow part and analysis runs one video at a time
    // on one thread.
    private static let lock = NSLock()
    private static var cached: HMRFrameBackend?

    static func shared(_ config: HMRConfig) -> HMRFrameBackend? {
        lock.lock(); defer { lock.unlock() }
        if let cached, cached.config == config { return cached }
        guard let net = PoseNet.shared(),
              let estimator = try? InstantHMREstimator(netName: config.network, fitCrops: config.fitCrops) else { return nil }
        let backend = HMRFrameBackend(config: config, net: net, estimator: estimator)
        cached = backend
        return backend
    }

    /// Loads the current configuration in the background (launch), so the first analysis does not wait.
    static func prewarm() {
        guard PoseEngine.current == .instantHMR else { return }
        let config = HMRConfig.current
        DispatchQueue.global(qos: .utility).async { _ = shared(config) }
    }

    /// One frame: MoveGrow joints (normalized display coordinates and confidence, NaN when absent),
    /// the person box, and InstantHMR's payload (nil when no person was found).
    func analyze(_ pixels: CVPixelBuffer, orientation: CGImagePropertyOrientation) throws
        -> (joints: [Float], box: [Float]?, payload: HMRFramePayload?) {
        var joints = [Float](repeating: .nan, count: MJ.count * 3)
        for k in 0..<MJ.count { joints[k * 3 + 2] = 0 }
        guard let det = try net.detect(pixels, orientation: orientation), det.box.w > 0.01, det.box.h > 0.01 else {
            return (joints, nil, nil)
        }
        var frame = CIImage(cvPixelBuffer: pixels).oriented(orientation)
        frame = frame.transformed(by: CGAffineTransform(translationX: -frame.extent.minX, y: -frame.extent.minY))
        let w = frame.extent.width, h = frame.extent.height
        let focal = estimator.fallbackFocal(width: w, height: h)
        let box = CGRect(x: det.box.x * Double(w), y: det.box.y * Double(h),
                         width: det.box.w * Double(w), height: det.box.h * Double(h))
        var times = HMRStageTimes()
        let person = try estimator.estimate(frame: frame, box: box, focal: focal, times: &times)
        let fw = Float(w), fh = Float(h)
        let j2 = person.joints2D.flatMap { [$0.x / fw, $0.y / fh] }
        let boxValues = [Float(det.box.x), Float(det.box.y), Float(det.box.w), Float(det.box.h), Float(det.confidence)]
        let payload = HMRFramePayload(box: boxValues, joints2D: j2,
                                      joints3D: person.joints3D.flatMap { [$0.x, $0.y, $0.z] },
                                      sigma: person.sigma.map { $0 / Float(max(w, h)) },
                                      yolo: YOLOPoseDecoder.joints(from: det).joints,
                                      frameWidth: fw, frameHeight: fh, focal: focal)

        for (mj, k) in MHR70.toMJ {
            let x = j2[2 * k], y = j2[2 * k + 1]
            guard x.isFinite, y.isFinite, x >= 0, x <= 1, y >= 0, y <= 1 else { continue }
            joints[mj * 3] = x
            joints[mj * 3 + 1] = y
            joints[mj * 3 + 2] = Self.jointConfidence
        }
        // Neck and root as midpoints, as for YOLO (YOLOPoseDecoder.joints).
        for (m, a, b) in [(MJ.index["neck"], MJ.leftShoulder, MJ.rightShoulder), (MJ.index["root"], MJ.leftHip, MJ.rightHip)] {
            guard let m, joints[a * 3 + 2] > 0, joints[b * 3 + 2] > 0 else { continue }
            joints[m * 3] = (joints[a * 3] + joints[b * 3]) / 2
            joints[m * 3 + 1] = (joints[a * 3 + 1] + joints[b * 3 + 1]) / 2
            joints[m * 3 + 2] = Self.jointConfidence * 0.98
        }
        return (joints, boxValues, payload)
    }
}
