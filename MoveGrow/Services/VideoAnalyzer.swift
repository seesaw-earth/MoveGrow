// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import AVFoundation
import Vision
import UIKit
import CoreImage
import ImageIO
import UltralyticsYOLO

struct VideoInfo {
    var duration: Double
    var aspect: Double
    var nominalFPS: Double
    var orientation: CGImagePropertyOrientation
    var naturalSize: CGSize
}

struct PassResult {
    var frames: [AnalyzedFrame]
    var estimator: String
}

// Offline processing uses movie presentation timestamps, not inference wall time.
// InstantHMR (3D, InstantHMR/HMRFrameBackend.swift) is the default engine; the bundled YOLO26l-pose
// model runs through PoseNet (direct Core ML) when YOLO is chosen or InstantHMR is unavailable;
// UltralyticsYOLO and Apple Vision are explicit fallbacks. Decoding and inference run on two threads with a small
// bounded queue between them, so the decoder works ahead while the Neural Engine is busy.
enum VideoAnalyzer {
    private static let inferQueue = DispatchQueue(label: "movegrow.analysis.infer", qos: .utility)
    private static let decodeQueue = DispatchQueue(label: "movegrow.analysis.decode", qos: .utility)
    /// Long side of decoded frames. The model sees 640 px, so decoding larger only costs time.
    private static let decodeLongSide = 960.0

    static func probe(url: URL) async throws -> VideoInfo {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw CocoaError(.fileReadCorruptFile) }
        let duration = try await asset.load(.duration).seconds
        let transform = try await track.load(.preferredTransform)
        let size = try await track.load(.naturalSize)
        let fps = Double(try await track.load(.nominalFrameRate))
        let bounds = CGRect(origin: .zero, size: size).applying(transform)
        let aspect = abs(bounds.width) / max(1, abs(bounds.height))
        return VideoInfo(duration: duration, aspect: aspect, nominalFPS: fps,
                         orientation: displayOrientation(for: transform), naturalSize: size)
    }

    /// Small JPEG poster frame, generated before analysis so the album shows the video at once.
    static func thumbnail(url: URL, duration: Double, maxSide: CGFloat = 400) async -> Data? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxSide, height: maxSide)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let time = CMTime(seconds: min(0.5, max(0, duration / 2)), preferredTimescale: 600)
        guard let result = try? await generator.image(at: time) else { return nil }
        return UIImage(cgImage: result.image).jpegData(compressionQuality: 0.8)
    }

    private enum Backend {
        case hmr(HMRFrameBackend)
        case net(PoseNet)
        case yolo(YOLO)
        case vision
    }

    /// `estimatorID`: the engine a memory's earlier pass used (its later passes must match), or nil for
    /// the engine chosen in Settings.
    private static func makeBackend(estimatorID: String?) async -> (Backend, String) {
        let config: HMRConfig?
        if let estimatorID {
            config = HMRConfig(estimatorID: estimatorID)
        } else {
            config = PoseEngine.preferredEstimatorID.flatMap(HMRConfig.init(estimatorID:))
        }
        if let config, let hmr = HMRFrameBackend.shared(config) { return (.hmr(hmr), config.estimatorID) }
        if let net = PoseNet.shared() { return (.net(net), YOLOPoseModelProvider.estimatorID) }
        if let yolo = try? await YOLOPoseModelProvider.shared.model() { return (.yolo(yolo), YOLOPoseModelProvider.estimatorID) }
        return (.vision, "apple-vision-human-body-pose-fallback")
    }

    private static func makeReader(asset: AVAsset, track: AVAssetTrack, scaled: CGSize?) throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
        var settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        if let scaled {
            settings[kCVPixelBufferWidthKey as String] = Int(scaled.width)
            settings[kCVPixelBufferHeightKey as String] = Int(scaled.height)
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw CocoaError(.fileReadUnknown) }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        return (reader, output)
    }

    /// Runs one analysis pass over the video.
    /// - Parameters:
    ///   - skip: time keys (`AnalysisPlan.timeKey`) of frames already analysed.
    ///   - progress: (done, expected) on the analysis thread, at most ~5 times per second.
    ///   - checkpoint: all frames analysed so far, every `checkpointEvery` frames (analysis thread).
    ///   - estimatorID: the engine to use (see makeBackend); nil = the one chosen in Settings.
    static func run(url: URL, info: VideoInfo, plan: AnalysisPlan, pass: AnalysisPlan.Pass, skip: Set<Int64>,
                    control: AnalysisControl, checkpointEvery: Int = 0, estimatorID: String? = nil,
                    progress: @escaping @Sendable (Int, Int) -> Void,
                    checkpoint: (@Sendable ([AnalyzedFrame]) -> Void)? = nil) async throws -> PassResult {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw CocoaError(.fileReadCorruptFile) }
        let (backend, estimator) = await makeBackend(estimatorID: estimatorID)
        let long = max(info.naturalSize.width, info.naturalSize.height)
        var scaled: CGSize?
        if long > decodeLongSide * 1.2 {
            let s = decodeLongSide / long
            func even(_ v: CGFloat) -> CGFloat { max(2, (v * s / 2).rounded() * 2) }
            scaled = CGSize(width: even(info.naturalSize.width), height: even(info.naturalSize.height))
        }
        let (reader, output): (AVAssetReader, AVAssetReaderTrackOutput)
        do { (reader, output) = try makeReader(asset: asset, track: track, scaled: scaled) }
        catch { (reader, output) = try makeReader(asset: asset, track: track, scaled: nil) }

        let expected: Int = {
            switch pass {
            case .quick: return plan.frameCount(.quick)
            case .detail: return max(1, (plan.estimatedFrames + plan.fullStride - 1) / plan.fullStride - skip.count)
            }
        }()
        let orientation = info.orientation
        let display = DisplayOrientation(rawValue: Int(orientation.rawValue)) ?? .up

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PassResult, Error>) in
                inferQueue.async {
                    let queue = FrameQueue(capacity: 4)
                    let decodeDone = DispatchSemaphore(value: 0)
                    decodeQueue.async {
                        var k: Int32 = -1
                        while !control.isCancelled, let buffer = output.copyNextSampleBuffer() {
                            guard CMSampleBufferGetImageBuffer(buffer) != nil else { continue }
                            k += 1
                            let t = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
                            guard t.isFinite, plan.includes(frame: Int(k), in: pass),
                                  !skip.contains(AnalysisPlan.timeKey(t)) else { continue }
                            if !queue.put(FrameQueue.Item(index: k, time: t, buffer: buffer), control: control) { break }
                        }
                        if control.isCancelled || reader.status == .reading { reader.cancelReading() }
                        queue.finish()
                        decodeDone.signal()
                    }

                    var frames: [AnalyzedFrame] = []
                    frames.reserveCapacity(expected + 8)
                    var lastReport = 0.0
                    var failure: Error?
                    let vision = VNDetectHumanBodyPoseRequest()
                    while let item = queue.take(control: control) {
                        if control.isCancelled { break }
                        control.waitIfNeeded()
                        let frame: AnalyzedFrame? = autoreleasepool {
                            guard let pixels = CMSampleBufferGetImageBuffer(item.buffer) else { return nil }
                            var joints: [Float]
                            var box: [Float]? = nil
                            var hmr: HMRFramePayload? = nil
                            switch backend {
                            case .hmr(let hmrBackend):
                                do { (joints, box, hmr) = try hmrBackend.analyze(pixels, orientation: orientation) }
                                catch { failure = error; return nil }
                            case .net(let net):
                                let det: PersonDetection?
                                do { det = try net.detect(pixels, orientation: orientation) }
                                catch { failure = error; return nil }
                                (joints, box) = YOLOPoseDecoder.joints(from: det)
                            case .yolo(let yolo):
                                let result = yolo(CIImage(cvPixelBuffer: pixels).oriented(orientation))
                                let sample = YOLOPoseAdapter.sample(result: result, time: item.time) { _ in true }
                                joints = PoseBridge.joints(sample)
                                box = sample.subjectBox.map { [$0.x, $0.y, $0.width, $0.height, $0.confidence].map(Float.init) }
                            case .vision:
                                let handler = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: orientation, options: [:])
                                try? handler.perform([vision])
                                var points: [String: MotionPoint] = [:]
                                if let all = vision.results, let best = PoseDetection.largestObservation(all) {
                                    points = PoseDetection.points(best)
                                }
                                joints = PoseBridge.joints(MotionSample(time: item.time, points: points, lightOK: true))
                            }
                            var luma = 0.0
                            if CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA,
                               CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess {
                                if let base = CVPixelBufferGetBaseAddress(pixels) {
                                    luma = FrameLuminance.bgra(base: UnsafeRawPointer(base),
                                                               width: CVPixelBufferGetWidth(pixels),
                                                               height: CVPixelBufferGetHeight(pixels),
                                                               bytesPerRow: CVPixelBufferGetBytesPerRow(pixels),
                                                               orientation: display, joints: joints)
                                }
                                CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
                            }
                            let hasBody = (0..<MJ.count).contains { joints[$0 * 3 + 2] > 0 }
                            return AnalyzedFrame(index: item.index, time: item.time, joints: joints, box: box,
                                                 lightOK: hasBody && FrameLuminance.isLightOK(luma), hmr: hmr)
                        }
                        if failure != nil { control.cancel(); break }
                        if let frame { frames.append(frame) }
                        let now = CFAbsoluteTimeGetCurrent()
                        if now - lastReport > 0.2 {
                            lastReport = now
                            progress(frames.count, max(expected, frames.count))
                        }
                        if checkpointEvery > 0, frames.count % checkpointEvery == 0, let checkpoint { checkpoint(frames) }
                    }
                    queue.finish()
                    decodeDone.wait()
                    if control.isCancelled {
                        if let checkpoint, !frames.isEmpty { checkpoint(frames) }
                        continuation.resume(throwing: failure != nil ? AnalysisInterrupted() : CancellationError())
                    } else if reader.status == .failed {
                        // Keep what was analysed (the store retries later if this happened in the background).
                        if let checkpoint, !frames.isEmpty { checkpoint(frames) }
                        continuation.resume(throwing: reader.error ?? CocoaError(.fileReadUnknown))
                    } else {
                        progress(frames.count, frames.count)
                        continuation.resume(returning: PassResult(frames: frames, estimator: estimator))
                    }
                }
            }
        } onCancel: {
            control.cancel()
        }
    }

    /// Convert AVAsset preferred-transform rotation/mirroring into the EXIF
    /// orientation used by Core Image and Vision. This keeps pose coordinates in
    /// the same displayed coordinate system as AVPlayer/AVAssetImageGenerator.
    static func displayOrientation(for t: CGAffineTransform) -> CGImagePropertyOrientation {
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

/// Small blocking hand-off between the decode thread and the inference thread.
private final class FrameQueue: @unchecked Sendable {
    struct Item {
        let index: Int32
        let time: Double
        let buffer: CMSampleBuffer
    }

    private let condition = NSCondition()
    private var items: [Item] = []
    private var finished = false
    private let capacity: Int

    init(capacity: Int) { self.capacity = capacity }

    /// Returns false when the consumer is gone or the pass was cancelled.
    func put(_ item: Item, control: AnalysisControl) -> Bool {
        condition.lock(); defer { condition.unlock() }
        while items.count >= capacity && !finished && !control.isCancelled {
            _ = condition.wait(until: Date().addingTimeInterval(0.2))
        }
        if finished || control.isCancelled { return false }
        items.append(item)
        condition.broadcast()
        return true
    }

    func take(control: AnalysisControl) -> Item? {
        condition.lock(); defer { condition.unlock() }
        while items.isEmpty && !finished && !control.isCancelled {
            _ = condition.wait(until: Date().addingTimeInterval(0.2))
        }
        guard !items.isEmpty else { return nil }
        let item = items.removeFirst()
        condition.broadcast()
        return item
    }

    func finish() {
        condition.lock()
        finished = true
        condition.broadcast()
        condition.unlock()
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

    /// Live-preview luminance (camera, foreground only).
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
