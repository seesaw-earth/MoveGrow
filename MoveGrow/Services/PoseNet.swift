// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import CoreML
import CoreVideo
import ImageIO
import Vision

/// Runs the bundled YOLO26l-pose Core ML model directly through Vision on decoded pixel buffers.
///
/// Same model and the same letterbox/post-processing as UltralyticsYOLO, without the per-frame
/// costs that path carries for offline video: no CIImage re-orientation, no annotated preview
/// image rendered for every frame, no NMS bookkeeping for the end-to-end head. UltralyticsYOLO
/// and Apple Vision remain as fallbacks if this runner cannot be created.
final class PoseNet {
    enum PoseNetError: Error { case modelMissing, unexpectedOutput }

    static let confidenceThreshold = 0.16
    private let request: VNCoreMLRequest
    private let modelSize: (w: Double, h: Double)

    init() throws {
        guard let url = Bundle.main.url(forResource: YOLOPoseModelProvider.modelName, withExtension: "mlmodelc") else {
            throw PoseNetError.modelMissing
        }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        let model = try MLModel(contentsOf: url, configuration: config)
        if let c = model.modelDescription.inputDescriptionsByName.values.compactMap({ $0.imageConstraint }).first {
            modelSize = (Double(c.pixelsWide), Double(c.pixelsHigh))
        } else {
            modelSize = (640, 640)
        }
        let vision = try VNCoreMLModel(for: model)
        request = VNCoreMLRequest(model: vision)
        request.imageCropAndScaleOption = .scaleFit
    }

    /// Largest detected person, or nil. Not thread-safe: use from one analysis thread at a time.
    func detect(_ pixels: CVPixelBuffer, orientation: CGImagePropertyOrientation) throws -> PersonDetection? {
        let w = Double(CVPixelBufferGetWidth(pixels)), h = Double(CVPixelBufferGetHeight(pixels))
        let swaps = DisplayOrientation(rawValue: Int(orientation.rawValue))?.swapsAxes ?? false
        let input = swaps ? (w: h, h: w) : (w: w, h: h)
        let handler = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: orientation, options: [:])
        try handler.perform([request])
        // The model always returns its output tensor; no tensor means inference itself failed
        // (for example the Neural Engine is unavailable), which must not look like "no baby".
        guard let observation = (request.results as? [VNCoreMLFeatureValueObservation])?.first,
              let array = observation.featureValue.multiArrayValue else { throw PoseNetError.unexpectedOutput }
        let shape = array.shape.map { $0.intValue }
        let strides = array.strides.map { $0.intValue }
        // YOLO26 end-to-end pose head: [1, maxDet, 6 + 3K]
        guard shape.count == 3, shape[2] < shape[1], shape[2] >= 6 + 3 * 17 else { throw PoseNetError.unexpectedOutput }
        let value: (Int, Int) -> Double
        if array.dataType == .float32 {
            let ptr = array.dataPointer.assumingMemoryBound(to: Float.self)
            value = { i, f in Double(ptr[i * strides[1] + f * strides[2]]) }
        } else {
            value = { i, f in array[[0, NSNumber(value: i), NSNumber(value: f)]].doubleValue }
        }
        let detections = YOLOPoseDecoder.decodeEnd2End(detections: shape[1], fields: shape[2], value: value,
                                                       confidenceThreshold: Self.confidenceThreshold,
                                                       input: input, model: modelSize)
        return YOLOPoseDecoder.largest(detections)
    }

    /// Runs one inference on a blank frame so a broken model fails here, not mid-video.
    func selfTest() throws {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, attrs, &pb) == kCVReturnSuccess,
              let pb else { return }
        _ = try detect(pb, orientation: .up)
    }

    /// Loads (and on first launch compiles) the model in the background, so the first recording
    /// starts analysing at once.
    /// Called on the main thread: never waits for a load in progress.
    static func prewarm() {
        guard lock.try() else { return }                 // a load is already running
        let needed = cached == nil && !recentlyFailed
        lock.unlock()
        guard needed else { return }
        Task.detached(priority: .utility) { _ = shared() }
    }

    // One shared instance: model loading is the slow part and analysis runs one video at a time.
    private static let lock = NSLock()
    private static var cached: PoseNet?
    private static var failedAt: Date?
    /// A failed load (e.g. under memory pressure) is retried after a minute rather than never.
    private static var recentlyFailed: Bool { failedAt.map { Date().timeIntervalSince($0) < 60 } ?? false }

    static func shared() -> PoseNet? {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        if recentlyFailed { return nil }
        do {
            let net = try PoseNet()
            try net.selfTest()
            cached = net
            failedAt = nil
            return net
        } catch {
            failedAt = Date()
            return nil
        }
    }
}
