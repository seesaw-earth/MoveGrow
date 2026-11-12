// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
//
// Experimental 3D pose (InstantHMR, research preview): one person box → 1 or 2 crops → network →
// kinematic fit → MHR body keypoints. Same order of operations and constants as InstantHMR's
// `InstantHMR.predict` (instanthmr/inference.py). The person box comes from MoveGrow's own YOLO26l-pose
// (largest person), so no extra detector is needed.

import CoreGraphics
import CoreImage
import CoreML
import Foundation
import simd

/// One person in one frame (frame pixels of the displayed, upright video).
struct HMRPerson {
    var joints2D: [SIMD2<Float>]          // 70, pixels
    var joints3D: [SIMD3<Float>]          // 70, metres, camera frame (x right, y down, z forward)
    var sigma: [Float]                    // 70, the network's 2D uncertainty in pixels (first crop)
    var camTrans: SIMD3<Float>
}

/// Milliseconds spent in each stage of one frame.
struct HMRStageTimes {
    var crop = 0.0, net = 0.0, fit = 0.0, body = 0.0
    var total: Double { crop + net + fit + body }
}

/// Not thread-safe: use from one analysis thread.
final class InstantHMREstimator {
    let netName: String
    /// 0 = network alone, 1 or 2 = with the kinematic fit (InstantHMR's default: 2).
    let fitCrops: Int
    private let net: MLModel
    private let fit: MLModel?
    private let body: MLModel
    private let renderer = HMRCropRenderer()
    private let side: Int
    private let cliffFocal: Bool
    private let cropScales: [Float]
    private let detectorToGTBox: Float
    let focalFallbackDiag: Float

    /// The network runs on the Neural Engine (`.all`); the small fp32 geometry graphs on the CPU.
    init(netName: String, fitCrops: Int) throws {
        self.netName = netName
        let netModel = try HMRML.load(netName, units: .all)
        net = netModel
        if fitCrops > 0 {
            fit = try HMRML.load(HMRModels.fitName(fitCrops), units: .cpuOnly)
            self.fitCrops = fitCrops
        } else {
            fit = nil
            self.fitCrops = 0
        }
        body = try HMRML.load(HMRModels.bodyName, units: .cpuOnly)
        let meta = HMRML.metadata(netModel)
        side = Int(meta["image_size"] ?? "") ?? 288
        cliffFocal = (meta["cliff_focal"] ?? "true") == "true"
        let scales = (meta["crop_scales"] ?? "0.9,0.7").split(separator: ",").compactMap { Float(String($0)) }
        cropScales = scales.count >= 2 ? scales : [0.9, 0.7]
        detectorToGTBox = Float(meta["detector_to_gt_box"] ?? "") ?? (1 / 0.866)
        focalFallbackDiag = Float(meta["focal_fallback_diag"] ?? "") ?? 1.05
    }

    /// InstantHMR's focal length when the camera's is unknown: 1.05 × the frame diagonal.
    func fallbackFocal(width: CGFloat, height: CGFloat) -> Float {
        focalFallbackDiag * Float((width * width + height * height).squareRoot())
    }

    /// - frame: the upright frame with its extent at the origin.
    /// - box: the person box in frame pixels (top-left origin).
    func estimate(frame: CIImage, box: CGRect, focal f: Float, times: inout HMRStageTimes) throws -> HMRPerson {
        let w = Float(frame.extent.width), h = Float(frame.extent.height)
        let n = fit == nil ? 0 : fitCrops
        let specs: [HMRCropSpec]
        if n == 0 {
            specs = [HMRCropSpec(box: box, scale: 1, focal: f, frameWidth: w, frameHeight: h, cliffFocal: cliffFocal)]
        } else {
            // The fit's crop scales were chosen on ground-truth boxes; detector boxes are tighter (InstantHMR).
            let k = CGFloat(detectorToGTBox)
            let gt = CGRect(x: box.midX - box.width * k / 2, y: box.midY - box.height * k / 2,
                            width: box.width * k, height: box.height * k)
            specs = cropScales.prefix(n).map {
                HMRCropSpec(box: gt, scale: $0, focal: f, frameWidth: w, frameHeight: h, cliffFocal: cliffFocal)
            }
        }

        var mu: [Float] = [], sd: [Float] = []
        var mp0: [Float] = [], shape0: [Float] = [], cam0: [Float] = []
        var sigma = [Float](repeating: 0, count: MHR70.count)
        for (i, spec) in specs.enumerated() {
            var t = CFAbsoluteTimeGetCurrent()
            let crop = try renderer.crop(frame, spec: spec, side: side)
            times.crop += ms(since: t)
            t = CFAbsoluteTimeGetCurrent()
            let input = try MLDictionaryFeatureProvider(dictionary: [
                "image": MLFeatureValue(pixelBuffer: crop),
                "cliff": MLFeatureValue(multiArray: try HMRML.array(spec.cliff, shape: [1, 3])),
            ])
            let out = try net.prediction(from: input)
            let m = try HMRML.output(out, "kp_mu")
            let s = try HMRML.output(out, "kp_sigma")
            mu += m
            sd += s
            if i == 0 {
                mp0 = try HMRML.output(out, "mhr_params")
                shape0 = try HMRML.output(out, "shape_params")
                cam0 = try HMRML.output(out, "cam_trans")
                // mu, sigma are in crop units of half a side ([-1, 1] spans the crop).
                let half = spec.width / 2
                for j in 0..<MHR70.count where 2 * j + 1 < s.count {
                    sigma[j] = (s[2 * j] + s[2 * j + 1]) / 2 * half
                }
            }
            times.net += ms(since: t)
        }
        guard mp0.count == 204, shape0.count == 45, cam0.count == 3, mu.count == 140 * specs.count else {
            throw HMRError.missingOutput("mhr_params / kp_mu")
        }

        var mp = mp0, cam = cam0
        var joints2D: [SIMD2<Float>]
        if n > 0, let fit {
            let t = CFAbsoluteTimeGetCurrent()
            let input = try MLDictionaryFeatureProvider(dictionary: [
                "mhr_params": MLFeatureValue(multiArray: try HMRML.array(mp0, shape: [1, 204])),
                "cam_trans": MLFeatureValue(multiArray: try HMRML.array(cam0, shape: [1, 3])),
                "kp_mu": MLFeatureValue(multiArray: try HMRML.array(mu, shape: [n, 70, 2])),
                "kp_sigma": MLFeatureValue(multiArray: try HMRML.array(sd, shape: [n, 70, 2])),
                "crop_box": MLFeatureValue(multiArray: try HMRML.array(specs.flatMap { $0.box }, shape: [n, 4])),
                "cam": MLFeatureValue(multiArray: try HMRML.array([f, w / 2, h / 2], shape: [1, 3])),
            ])
            let out = try fit.prediction(from: input)
            mp = try HMRML.output(out, "mhr_params_fit")
            cam = try HMRML.output(out, "cam_trans_fit")
            let j = try HMRML.output(out, "joints_2d")
            guard j.count >= 140 else { throw HMRError.missingOutput("joints_2d") }
            joints2D = (0..<70).map { SIMD2(j[2 * $0], j[2 * $0 + 1]) }
            times.fit += ms(since: t)
        } else {
            // network alone: pixel = crop corner + (mu + 1) / 2 × crop side (InstantHMR._estimate)
            let s = specs[0]
            joints2D = (0..<70).map {
                SIMD2(s.x1 + (mu[2 * $0] + 1) * 0.5 * s.width, s.y1 + (mu[2 * $0 + 1] + 1) * 0.5 * s.height)
            }
        }

        let t = CFAbsoluteTimeGetCurrent()
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "mhr_params": MLFeatureValue(multiArray: try HMRML.array(mp, shape: [1, 204])),
            "shape_params": MLFeatureValue(multiArray: try HMRML.array(shape0, shape: [1, 45])),
        ])
        let k3 = try HMRML.output(try body.prediction(from: input), "keypoints_3d")
        guard k3.count >= 210, cam.count >= 3 else { throw HMRError.missingOutput("keypoints_3d") }
        let camT = SIMD3(cam[0], cam[1], cam[2])
        let joints3D = (0..<70).map { SIMD3(k3[3 * $0], k3[3 * $0 + 1], k3[3 * $0 + 2]) + camT }
        times.body += ms(since: t)

        return HMRPerson(joints2D: joints2D, joints3D: joints3D, sigma: sigma, camTrans: camT)
    }

    private func ms(since t: CFAbsoluteTime) -> Double { (CFAbsoluteTimeGetCurrent() - t) * 1000 }
}
