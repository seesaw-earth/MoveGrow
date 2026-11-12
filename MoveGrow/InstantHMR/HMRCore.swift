// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
//
// InstantHMR (3D pose): Core ML helpers and the person crop exactly as InstantHMR makes it.
// The models are compiled into the app by the "Bundle InstantHMR Models" build phase (INSTANTHMR.md).

import CoreGraphics
import CoreImage
import CoreML
import CoreVideo
import Foundation

// MARK: - Core ML helpers

enum HMRML {
    /// All values of a multi-array as Float, honouring its strides (Neural Engine outputs can be padded).
    static func floats(_ a: MLMultiArray) -> [Float] {
        let shape = a.shape.map { $0.intValue }
        let strides = a.strides.map { $0.intValue }
        let n = shape.reduce(1, *)
        var out = [Float](repeating: 0, count: n)
        guard n > 0 else { return out }
        var index = [Int](repeating: 0, count: shape.count)
        let base = a.dataPointer
        for i in 0..<n {
            var offset = 0
            for d in 0..<shape.count { offset += index[d] * strides[d] }
            switch a.dataType {
            case .float32:
                out[i] = base.assumingMemoryBound(to: Float.self)[offset]
            case .double:
                out[i] = Float(base.assumingMemoryBound(to: Double.self)[offset])
            default:                                       // float16 / int32: slower keyed access
                out[i] = a[index.map { NSNumber(value: $0) }].floatValue
            }
            var d = shape.count - 1                       // advance the multi-index, last axis fastest
            while d >= 0 {
                index[d] += 1
                if index[d] < shape[d] { break }
                index[d] = 0
                d -= 1
            }
        }
        return out
    }

    /// A new contiguous float32 multi-array filled with `values`.
    static func array(_ values: [Float], shape: [Int]) throws -> MLMultiArray {
        let a = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float32)
        let p = a.dataPointer.assumingMemoryBound(to: Float.self)
        for (i, v) in values.enumerated() { p[i] = v }
        return a
    }

    static func output(_ result: MLFeatureProvider, _ name: String) throws -> [Float] {
        guard let a = result.featureValue(for: name)?.multiArrayValue else { throw HMRError.missingOutput(name) }
        return floats(a)
    }

    /// A compiled model from the app bundle (Xcode compiles each .mlpackage to .mlmodelc).
    static func load(_ name: String, units: MLComputeUnits) throws -> MLModel {
        guard let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") else {
            throw HMRError.modelNotFound(name)
        }
        let config = MLModelConfiguration()
        config.computeUnits = units
        return try MLModel(contentsOf: url, configuration: config)
    }

    static func metadata(_ model: MLModel) -> [String: String] {
        model.modelDescription.metadata[MLModelMetadataKey.creatorDefinedKey] as? [String: String] ?? [:]
    }
}

enum HMRError: Error, LocalizedError {
    case modelNotFound(String), missingOutput(String), pixelBuffer, noVideo, yoloUnavailable

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let n): return tr("The InstantHMR model %@ is not in this build.", n)
        case .missingOutput(let n): return tr("The InstantHMR model gave no “%@” output.", n)
        case .pixelBuffer: return tr("There was not enough memory to analyse this frame.")
        case .noVideo: return tr("The video couldn’t be read.")
        case .yoloUnavailable: return tr("The YOLO model that finds the baby could not be loaded.")
        }
    }
}

// MARK: - Crops

/// One square person crop, computed exactly like InstantHMR's `InstantHMR._crop` (instanthmr/inference.py):
/// the box scaled by `scale` about its centre, a 1.2× square around it snapped outwards to whole pixels,
/// and the CLIFF vector (atan of the centre's offset over the focal length, and size / focal).
struct HMRCropSpec {
    let x1: Float, y1: Float, width: Float, height: Float    // the pixel square in the frame (top-left origin)
    let cliff: [Float]                                         // 3 values

    init(box: CGRect, scale: Float, focal: Float, frameWidth: Float, frameHeight: Float,
         cliffFocal: Bool = true, expand: Float = 1.2) {
        let cx = Float(box.midX), cy = Float(box.midY)
        let size = Float(max(box.width, box.height)) * scale
        if cliffFocal {
            cliff = [atan((cx - frameWidth / 2) / focal), atan((cy - frameHeight / 2) / focal), size / focal]
        } else {
            cliff = [2 * cx / frameWidth - 1, 2 * cy / frameHeight - 1, size / max(frameWidth, frameHeight)]
        }
        let side = size * expand
        let ix1 = (cx - side / 2).rounded(.down), iy1 = (cy - side / 2).rounded(.down)
        let ix2 = (cx - side / 2 + side).rounded(.up), iy2 = (cy - side / 2 + side).rounded(.up)
        x1 = ix1; y1 = iy1; width = ix2 - ix1; height = iy2 - iy1
    }

    var box: [Float] { [x1, y1, width, height] }
}

/// Renders crops with Core Image into IOSurface-backed BGRA buffers (what Core ML hands to the Neural
/// Engine without a copy). Areas outside the frame are black, as InstantHMR's cv2.warpAffine border.
/// Not thread-safe: one renderer per analysis thread.
final class HMRCropRenderer {
    private let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(),
                                              .cacheIntermediates: false])
    private var pools: [Int: CVPixelBufferPool] = [:]

    private func buffer(side: Int) throws -> CVPixelBuffer {
        if pools[side] == nil {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: side,
                kCVPixelBufferHeightKey as String: side,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
            pools[side] = pool
        }
        guard let pool = pools[side] else { throw HMRError.pixelBuffer }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let out else { throw HMRError.pixelBuffer }
        return out
    }

    /// The frame region [x1, x1 + width] × [y1, y1 + height] (pixels, top-left origin) resized to side × side.
    /// `frame` must have its extent at the origin.
    func crop(_ frame: CIImage, spec: HMRCropSpec, side: Int) throws -> CVPixelBuffer {
        let s = CGFloat(side)
        // Core Image's origin is bottom-left: the region's bottom edge is at height − (y1 + h).
        let bottom = frame.extent.height - CGFloat(spec.y1 + spec.height)
        let t = CGAffineTransform(translationX: -CGFloat(spec.x1), y: -bottom)
            .concatenating(CGAffineTransform(scaleX: s / CGFloat(spec.width), y: s / CGFloat(spec.height)))
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        let image = frame.transformed(by: t).cropped(to: rect)
            .composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: rect))
        let out = try buffer(side: side)
        context.render(image, to: out, bounds: rect, colorSpace: nil)
        return out
    }
}
