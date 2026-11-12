// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
//
// Framework-free pieces of per-frame pose extraction: YOLO26 end-to-end pose decoding with
// letterbox correction, single-subject selection, and luminance of the body region read straight
// from the decoded BGRA pixels (no GPU round trip per frame).

import Foundation

/// EXIF-style display orientation of decoded video pixels (mirrors CGImagePropertyOrientation).
enum DisplayOrientation: Int {
    case up = 1, upMirrored, down, downMirrored, leftMirrored, right, rightMirrored, left

    var swapsAxes: Bool { [.leftMirrored, .right, .rightMirrored, .left].contains(self) }

    /// Maps a normalized display point (origin top-left) to normalized buffer coordinates.
    func bufferPoint(u: Double, v: Double) -> (Double, Double) {
        switch self {
        case .up: return (u, v)
        case .upMirrored: return (1 - u, v)
        case .down: return (1 - u, 1 - v)
        case .downMirrored: return (u, 1 - v)
        case .right: return (v, 1 - u)
        case .left: return (1 - v, u)
        case .rightMirrored: return (v, u)
        case .leftMirrored: return (1 - v, 1 - u)
        }
    }
}

struct PersonDetection {
    /// Normalized display coordinates (origin top-left).
    var box: (x: Double, y: Double, w: Double, h: Double)
    var confidence: Double
    /// 17 COCO keypoints: normalized x, y and confidence.
    var keypoints: [(x: Double, y: Double, c: Double)]
    var area: Double { box.w * box.h }
}

enum YOLOPoseDecoder {
    static let cocoNames = [
        "nose", "leftEye", "rightEye", "leftEar", "rightEar",
        "leftShoulder", "rightShoulder", "leftElbow", "rightElbow",
        "leftWrist", "rightWrist", "leftHip", "rightHip",
        "leftKnee", "rightKnee", "leftAnkle", "rightAnkle",
    ]

    /// Vision `.scaleFit` letterbox, as in Ultralytics BasePredictor.letterboxTransform.
    static func letterbox(input: (w: Double, h: Double), model: (w: Double, h: Double)) -> (gain: Double, padX: Double, padY: Double)? {
        guard model.w > 0, model.h > 0, input.w > 0, input.h > 0 else { return nil }
        let gain = min(model.h / input.h, model.w / input.w)
        let rw = (input.w * gain).rounded(), rh = (input.h * gain).rounded()
        return (gain, ((model.w - rw) / 2 - 0.1).rounded(), ((model.h - rh) / 2 - 0.1).rounded())
    }

    /// Decodes a YOLO26 end-to-end pose output [1, maxDet, 6 + 3K] (xyxy in model pixels, conf, class, keypoints).
    /// `value(det, field)` reads one element (lets the caller handle MLMultiArray strides and data types).
    static func decodeEnd2End(detections: Int, fields: Int, value: (Int, Int) -> Double,
                              confidenceThreshold: Double, input: (w: Double, h: Double),
                              model: (w: Double, h: Double)) -> [PersonDetection] {
        guard let lb = letterbox(input: input, model: model) else { return [] }
        let kpStart = (fields - 6) % 3 == 0 ? 6 : 5
        let nk = (fields - kpStart) / 3
        func toInput(_ x: Double, _ y: Double) -> (Double, Double) {
            (min(max((x - lb.padX) / lb.gain, 0), input.w), min(max((y - lb.padY) / lb.gain, 0), input.h))
        }
        var out: [PersonDetection] = []
        for i in 0..<detections {
            let conf = value(i, 4)
            guard conf > confidenceThreshold else { continue }
            let (x1, y1) = toInput(value(i, 0), value(i, 1))
            let (x2, y2) = toInput(value(i, 2), value(i, 3))
            let bx = min(x1, x2), by = min(y1, y2)
            let box = (x: bx / input.w, y: by / input.h, w: abs(x2 - x1) / input.w, h: abs(y2 - y1) / input.h)
            var kps: [(x: Double, y: Double, c: Double)] = []
            kps.reserveCapacity(nk)
            for k in 0..<nk {
                let (kx, ky) = toInput(value(i, kpStart + 3 * k), value(i, kpStart + 3 * k + 1))
                kps.append((kx / input.w, ky / input.h, value(i, kpStart + 3 * k + 2)))
            }
            out.append(PersonDetection(box: box, confidence: conf, keypoints: kps))
        }
        return out
    }

    /// MoveGrow is single-subject: keep the person with the largest box (ties → higher confidence).
    static func largest(_ dets: [PersonDetection]) -> PersonDetection? {
        var best: PersonDetection?
        for d in dets where d.box.w.isFinite && d.box.h.isFinite && d.box.w > 0 && d.box.h > 0 {
            if let b = best {
                if d.area > b.area || (abs(d.area - b.area) < 1e-9 && d.confidence > b.confidence) { best = d }
            } else { best = d }
        }
        return best
    }

    /// J × 3 floats in `MJ` order with derived neck/root midpoints, plus the subject box.
    static func joints(from det: PersonDetection?) -> (joints: [Float], box: [Float]?) {
        var j = [Float](repeating: .nan, count: MJ.count * 3)
        for k in 0..<MJ.count { j[k * 3 + 2] = 0 }
        guard let det else { return (j, nil) }
        for (i, kp) in det.keypoints.prefix(cocoNames.count).enumerated() {
            guard kp.x.isFinite, kp.y.isFinite, kp.c.isFinite, kp.x >= 0, kp.x <= 1, kp.y >= 0, kp.y <= 1, kp.c > 0.03,
                  let m = MJ.index[cocoNames[i]] else { continue }
            j[m * 3] = Float(kp.x); j[m * 3 + 1] = Float(kp.y); j[m * 3 + 2] = Float(kp.c)
        }
        func mid(_ name: String, _ a: Int, _ b: Int) {
            guard j[a * 3 + 2] > 0, j[b * 3 + 2] > 0, let m = MJ.index[name] else { return }
            j[m * 3] = (j[a * 3] + j[b * 3]) / 2
            j[m * 3 + 1] = (j[a * 3 + 1] + j[b * 3 + 1]) / 2
            j[m * 3 + 2] = min(j[a * 3 + 2], j[b * 3 + 2]) * 0.98
        }
        mid("neck", MJ.leftShoulder, MJ.rightShoulder)
        mid("root", MJ.leftHip, MJ.rightHip)
        let b = det.box
        return (j, [b.x, b.y, b.w, b.h, det.confidence].map(Float.init))
    }
}

enum FrameLuminance {
    /// Mean Rec.601 luma (0...1) of a BGRA buffer over the body region (or the whole frame when
    /// fewer than five confident joints), sampling a sparse grid of about 4,000 pixels.
    static func bgra(base: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int,
                     orientation: DisplayOrientation, joints: [Float]) -> Double {
        var xs: [Double] = [], ys: [Double] = []
        for k in 0..<MJ.count where joints[k * 3 + 2] >= 0.20 && joints[k * 3].isFinite {
            xs.append(Double(joints[k * 3])); ys.append(Double(joints[k * 3 + 1]))
        }
        var u0 = 0.0, u1 = 1.0, v0 = 0.0, v1 = 1.0
        if xs.count >= 5 {
            u0 = max(0, xs.min()! - 0.05); u1 = min(1, xs.max()! + 0.05)
            v0 = max(0, ys.min()! - 0.05); v1 = min(1, ys.max()! + 0.05)
        }
        let a = orientation.bufferPoint(u: u0, v: v0), b = orientation.bufferPoint(u: u1, v: v1)
        let bx0 = Int(min(a.0, b.0) * Double(width)), bx1 = Int(max(a.0, b.0) * Double(width))
        let by0 = Int(min(a.1, b.1) * Double(height)), by1 = Int(max(a.1, b.1) * Double(height))
        let x0 = max(0, min(width - 1, bx0)), x1 = max(x0 + 1, min(width, bx1))
        let y0 = max(0, min(height - 1, by0)), y1 = max(y0 + 1, min(height, by1))
        let area = Double((x1 - x0) * (y1 - y0))
        let step = max(1, Int((area / 4000).squareRoot()))
        var sum = 0.0, n = 0.0
        let px = base.assumingMemoryBound(to: UInt8.self)
        var y = y0
        while y < y1 {
            let row = px + y * bytesPerRow
            var x = x0
            while x < x1 {
                let p = row + x * 4
                sum += 0.114 * Double(p[0]) + 0.587 * Double(p[1]) + 0.299 * Double(p[2])
                n += 1
                x += step
            }
            y += step
        }
        return n > 0 ? sum / (n * 255) : 0
    }

    static func isLightOK(_ luma: Double) -> Bool { luma >= 0.25 && luma <= 0.94 }
}
