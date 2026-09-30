// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import AVFoundation
import Vision
import UIKit
import CoreImage
import ImageIO
import UltralyticsYOLO

struct AnalysisResult {
    var rawSamples: [MotionSample]
    var samples: [MotionSample]
    var report: MovementReport
    var thumbnail: Data?
    var aspectRatio: Double
    var poseEstimator: String
    var poseProcessing: String
}

// Offline processing uses movie presentation timestamps, not inference wall time.
// YOLO26l-pose/CoreML is the primary estimator. Apple Vision is an explicit
// fallback if the bundled official model cannot be loaded.
enum VideoAnalyzer {
    private static let sampleInterval = 1.0 / 15.0

    static func process(url: URL) async throws -> AnalysisResult {
        let worker = Task.detached(priority: .utility) { try await run(url: url) }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }

    private static func run(url: URL) async throws -> AnalysisResult {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw CocoaError(.fileReadCorruptFile) }
        let duration = try await asset.load(.duration).seconds
        let transform = try await track.load(.preferredTransform)
        let size = try await track.load(.naturalSize)
        let bounds = CGRect(origin: .zero, size: size).applying(transform)
        let aspect = abs(bounds.width) / max(1, abs(bounds.height))
        let orientation = displayOrientation(for: transform)

        let yolo: YOLO?
        let estimator: String
        do {
            yolo = try await YOLOPoseModelProvider.shared.model()
            estimator = YOLOPoseModelProvider.estimatorID
        } catch {
            yolo = nil
            estimator = "apple-vision-human-body-pose-fallback"
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw CocoaError(.fileReadUnknown) }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        defer { reader.cancelReading() }

        var rawSamples: [MotionSample] = []
        var last = -Double.infinity
        let context = CIContext(options: [.cacheIntermediates: false])
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let time = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            guard time.isFinite, time - last >= sampleInterval - 0.002,
                  let pixels = CMSampleBufferGetImageBuffer(buffer) else { continue }
            last = time

            let sample: MotionSample = autoreleasepool {
                if let yolo {
                    let image = CIImage(cvPixelBuffer: pixels).oriented(orientation)
                    let result = yolo(image)
                    return YOLOPoseAdapter.sample(
                        result: result,
                        time: time
                    ) { points in
                        let luminance = PoseDetection.luminance(pixels, orientation: orientation, context: context, points: points)
                        return luminance >= 0.25 && luminance <= 0.94
                    }
                }

                let request = VNDetectHumanBodyPoseRequest()
                let handler = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: orientation, options: [:])
                try? handler.perform([request])
                var points: [String: MotionPoint] = [:]
                // Keep the same one-subject rule in the Vision fallback: choose
                // the body occupying the largest recognized-joint footprint.
                if let all = request.results,
                   let observation = PoseDetection.largestObservation(all) {
                    points = PoseDetection.points(observation)
                }
                let luminance = PoseDetection.luminance(pixels, orientation: orientation, context: context, points: points)
                return MotionSample(time: time, points: points, lightOK: luminance >= 0.25 && luminance <= 0.94)
            }
            rawSamples.append(sample)
        }

        if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadUnknown) }
        let processed = yolo == nil ? rawSamples : PoseTemporalRefiner.refine(rawSamples)
        let processing = yolo == nil ? "none" : PoseTemporalRefiner.version
        let report = MovementEngine.report(samples: processed, duration: duration, aspect: aspect)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 400, height: 400)
        var thumb: Data?
        if let image = try? generator.copyCGImage(
            at: CMTime(seconds: min(0.5, duration / 2), preferredTimescale: 600),
            actualTime: nil
        ) {
            thumb = UIImage(cgImage: image).jpegData(compressionQuality: 0.8)
        }

        return AnalysisResult(
            rawSamples: rawSamples,
            samples: processed,
            report: report,
            thumbnail: thumb,
            aspectRatio: aspect,
            poseEstimator: estimator,
            poseProcessing: processing
        )
    }

    /// Convert AVAsset preferred-transform rotation/mirroring into the EXIF
    /// orientation used by Core Image and Vision. This keeps pose coordinates in
    /// the same displayed coordinate system as AVPlayer/AVAssetImageGenerator.
    private static func displayOrientation(for t: CGAffineTransform) -> CGImagePropertyOrientation {
        let a = t.a, b = t.b, c = t.c, d = t.d
        let eps: CGFloat = 0.5

        if abs(b) < eps, abs(c) < eps {
            if a >= 0, d >= 0 { return .up }
            if a < 0, d >= 0 { return .upMirrored }
            if a < 0, d < 0 { return .down }
            return .downMirrored
        }

        if b >= 0, c >= 0 { return .leftMirrored }
        if b >= 0, c < 0 { return .right }
        if b < 0, c < 0 { return .rightMirrored }
        return .left
    }
}

enum PoseDetection {
    static let map: [VNHumanBodyPoseObservation.JointName: String] = [
        .nose: "nose", .leftEye: "leftEye", .rightEye: "rightEye", .leftEar: "leftEar", .rightEar: "rightEar",
        .neck: "neck", .root: "root", .leftShoulder: "leftShoulder", .rightShoulder: "rightShoulder",
        .leftElbow: "leftElbow", .rightElbow: "rightElbow", .leftWrist: "leftWrist", .rightWrist: "rightWrist",
        .leftHip: "leftHip", .rightHip: "rightHip", .leftKnee: "leftKnee", .rightKnee: "rightKnee",
        .leftAnkle: "leftAnkle", .rightAnkle: "rightAnkle"
    ]

    static func largestObservation(_ observations: [VNHumanBodyPoseObservation]) -> VNHumanBodyPoseObservation? {
        observations.max { recognizedBodyArea($0) < recognizedBodyArea($1) }
    }

    private static func recognizedBodyArea(_ observation: VNHumanBodyPoseObservation) -> Double {
        let recognized = (try? observation.recognizedPoints(.all)) ?? [:]
        let visible = recognized.values.filter { $0.confidence > 0.10 }
        guard visible.count >= 3 else { return 0 }
        let xs = visible.map { Double($0.location.x) }
        let ys = visible.map { Double($0.location.y) }
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return 0 }
        return max(0, maxX - minX) * max(0, maxY - minY)
    }

    static func points(_ observation: VNHumanBodyPoseObservation) -> [String: MotionPoint] {
        let found = (try? observation.recognizedPoints(.all)) ?? [:]
        var result: [String: MotionPoint] = [:]
        for (key, name) in map {
            if let point = found[key], point.confidence > 0.05 {
                result[name] = MotionPoint(
                    x: point.location.x,
                    y: 1 - point.location.y,
                    confidence: Double(point.confidence)
                )
            }
        }
        return result
    }

    static func luminance(
        _ pixels: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        context: CIContext,
        points: [String: MotionPoint]
    ) -> Double {
        let image = CIImage(cvPixelBuffer: pixels).oriented(orientation)
        var region = image.extent
        let visible = points.values.filter { $0.confidence >= 0.20 }
        if visible.count >= 5 {
            let xs = visible.map(\.x), ys = visible.map(\.y)
            let x0 = max(0, (xs.min() ?? 0) - 0.05), x1 = min(1, (xs.max() ?? 1) + 0.05)
            let y0 = max(0, (ys.min() ?? 0) - 0.05), y1 = min(1, (ys.max() ?? 1) + 0.05)
            region = CGRect(
                x: region.minX + x0 * region.width,
                y: region.minY + (1 - y1) * region.height,
                width: max(1, (x1 - x0) * region.width),
                height: max(1, (y1 - y0) * region.height)
            )
        }
        guard let filter = CIFilter(
            name: "CIAreaAverage",
            parameters: [kCIInputImageKey: image, kCIInputExtentKey: CIVector(cgRect: region)]
        ), let output = filter.outputImage else { return 0 }
        var rgba = [UInt8](repeating: 0, count: 4)
        context.render(
            output,
            toBitmap: &rgba,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return (0.299 * Double(rgba[0]) + 0.587 * Double(rgba[1]) + 0.114 * Double(rgba[2])) / 255
    }
}
