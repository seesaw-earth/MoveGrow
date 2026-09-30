// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import AVFoundation
import QuartzCore
import UIKit

/// Builds a short, shareable MP4 with pose landmarks baked over the displayed video.
/// Rendering stays local on the device and uses the already-computed pose samples.
enum SkeletonClipRenderer {
    enum RenderError: LocalizedError {
        case noVideoTrack, noPoseData, cannotCreateComposition, cannotExport
        var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "The video track could not be opened."
            case .noPoseData: return "No keypoints are available in this part of the video."
            case .cannotCreateComposition: return "The skeleton preview could not be prepared."
            case .cannotExport: return "The skeleton preview could not be saved."
            }
        }
    }

    static func render(videoURL: URL, samples: [MotionSample], start: Double, duration: Double = 10) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)
        guard let sourceTrack = try await asset.loadTracks(withMediaType: .video).first else { throw RenderError.noVideoTrack }
        let assetDuration = try await asset.load(.duration).seconds
        let safeStart = max(0, min(start, max(0, assetDuration - 0.05)))
        let clipDuration = max(0.05, min(duration, assetDuration - safeStart))
        let end = safeStart + clipDuration
        let clipSamples = samples.filter { $0.time >= safeStart && $0.time <= end }
        guard clipSamples.contains(where: { !$0.points.isEmpty }) else { throw RenderError.noPoseData }

        // Build the output in the source video's *display* coordinate system.
        // naturalSize alone is not enough for iPhone/Photos movies because portrait
        // clips are commonly stored as landscape pixels plus preferredTransform.
        // Normalizing that transform here means the rendered pixels, pose points,
        // and final MP4 all share one upright/mirrored display geometry.
        let naturalSize = try await sourceTrack.load(.naturalSize)
        let preferredTransform = try await sourceTrack.load(.preferredTransform)
        let transformedBounds = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let renderSize = CGSize(width: abs(transformedBounds.width), height: abs(transformedBounds.height))
        guard renderSize.width > 1, renderSize.height > 1 else { throw RenderError.cannotCreateComposition }

        var displayTransform = preferredTransform
        // Shift the transformed image into a zero-origin render canvas. Adjusting
        // tx/ty directly avoids ambiguity about affine concatenation order.
        displayTransform.tx -= transformedBounds.minX
        displayTransform.ty -= transformedBounds.minY

        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw RenderError.cannotCreateComposition
        }
        let sourceRange = CMTimeRange(
            start: CMTime(seconds: safeStart, preferredTimescale: 600),
            duration: CMTime(seconds: clipDuration, preferredTimescale: 600)
        )
        try compositionTrack.insertTimeRange(sourceRange, of: sourceTrack, at: .zero)
        // Rotation/mirroring is baked by the video-composition instruction below;
        // do not also carry it as track metadata or it can be applied twice.
        compositionTrack.preferredTransform = .identity

        // Keep the source audio when present.
        if let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first,
           let compositionAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try? compositionAudio.insertTimeRange(sourceRange, of: sourceAudio, at: .zero)
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        let nominalFPS = try await sourceTrack.load(.nominalFrameRate)
        let outputFPS: Float = nominalFPS.isFinite && nominalFPS >= 1 ? min(120, nominalFPS) : 30
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(outputFPS.rounded()))

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionTrack)
        layerInstruction.setTransform(displayTransform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]

        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: renderSize)
        let videoLayer = CALayer()
        videoLayer.frame = parentLayer.bounds
        parentLayer.addSublayer(videoLayer)

        let overlayLayer = CALayer()
        overlayLayer.frame = parentLayer.bounds
        // Pose coordinates use a UIKit-style top-left origin.
        overlayLayer.isGeometryFlipped = true
        parentLayer.addSublayer(overlayLayer)
        addSkeletonLayers(to: overlayLayer, renderSize: renderSize, samples: clipSamples, clipStart: safeStart, clipDuration: clipDuration)
        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parentLayer)

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoveGrow-Skeleton-\(UUID().uuidString)")
            .appendingPathExtension("mp4")
        try? FileManager.default.removeItem(at: output)
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw RenderError.cannotExport
        }
        exporter.outputURL = output
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = false
        exporter.videoComposition = videoComposition
        try await export(exporter)
        return output
    }

    private static func export(_ exporter: AVAssetExportSession) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exporter.exportAsynchronously {
                switch exporter.status {
                case .completed:
                    continuation.resume(returning: ())
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                default:
                    continuation.resume(throwing: exporter.error ?? RenderError.cannotExport)
                }
            }
        }
    }

    private static func addSkeletonLayers(to container: CALayer, renderSize: CGSize, samples: [MotionSample], clipStart: Double, clipDuration: Double) {
        let ordered = normalizedSamples(samples, clipStart: clipStart, clipDuration: clipDuration)
        let keyTimes = ordered.map { NSNumber(value: max(0, min(1, ($0.time - clipStart) / clipDuration))) }
        guard !keyTimes.isEmpty else { return }

        let scale = max(1, min(renderSize.width, renderSize.height) / 390)
        let haloWidth = 7.0 * scale
        let coreWidth = 3.5 * scale
        let jointRadius = 4.8 * scale
        let hidden = CGPoint(x: -1000, y: -1000)

        for connection in BodyJoint.connections {
            let values = ordered.map { sample -> CGPath in
                let path = CGMutablePath()
                guard let a = visiblePoint(sample, joint: connection.0, renderSize: renderSize),
                      let b = visiblePoint(sample, joint: connection.1, renderSize: renderSize) else {
                    path.move(to: hidden); path.addLine(to: hidden); return path
                }
                path.move(to: a); path.addLine(to: b); return path
            }
            let opacities = ordered.map { sample -> NSNumber in
                let visible = visiblePoint(sample, joint: connection.0, renderSize: renderSize) != nil && visiblePoint(sample, joint: connection.1, renderSize: renderSize) != nil
                return NSNumber(value: visible ? 1 : 0)
            }
            addBoneLayer(to: container, width: haloWidth, color: UIColor.black.withAlphaComponent(0.55), values: values.map { $0 as Any }, opacities: opacities.map { $0 as Any }, keyTimes: keyTimes, duration: clipDuration)
            addBoneLayer(to: container, width: coreWidth, color: UIColor.systemTeal.withAlphaComponent(0.96), values: values.map { $0 as Any }, opacities: opacities.map { $0 as Any }, keyTimes: keyTimes, duration: clipDuration)
        }

        for joint in BodyJoint.allCases {
            let positions = ordered.map { sample -> NSValue in
                NSValue(cgPoint: visiblePoint(sample, joint: joint, renderSize: renderSize) ?? hidden)
            }
            let opacities = ordered.map { sample -> NSNumber in
                NSNumber(value: visiblePoint(sample, joint: joint, renderSize: renderSize) == nil ? 0 : 1)
            }
            let layer = CAShapeLayer()
            layer.bounds = CGRect(x: 0, y: 0, width: jointRadius * 2, height: jointRadius * 2)
            layer.path = UIBezierPath(ovalIn: layer.bounds).cgPath
            layer.fillColor = UIColor.white.cgColor
            layer.strokeColor = UIColor.systemTeal.cgColor
            layer.lineWidth = 2 * scale
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOpacity = 0.45
            layer.shadowRadius = 2 * scale
            layer.shadowOffset = .zero
            layer.opacity = 0
            addKeyframeAnimation(layer: layer, keyPath: "position", values: positions.map { $0 as Any }, keyTimes: keyTimes, duration: clipDuration)
            addKeyframeAnimation(layer: layer, keyPath: "opacity", values: opacities.map { $0 as Any }, keyTimes: keyTimes, duration: clipDuration)
            container.addSublayer(layer)
        }
    }

    private static func addBoneLayer(to container: CALayer, width: CGFloat, color: UIColor, values: [Any], opacities: [Any], keyTimes: [NSNumber], duration: Double) {
        let layer = CAShapeLayer()
        layer.fillColor = UIColor.clear.cgColor
        layer.strokeColor = color.cgColor
        layer.lineWidth = width
        layer.lineCap = .round
        layer.lineJoin = .round
        layer.opacity = 0
        addKeyframeAnimation(layer: layer, keyPath: "path", values: values, keyTimes: keyTimes, duration: duration)
        addKeyframeAnimation(layer: layer, keyPath: "opacity", values: opacities, keyTimes: keyTimes, duration: duration)
        container.addSublayer(layer)
    }

    private static func addKeyframeAnimation(layer: CALayer, keyPath: String, values: [Any], keyTimes: [NSNumber], duration: Double) {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = keyTimes
        animation.duration = duration
        animation.beginTime = AVCoreAnimationBeginTimeAtZero
        animation.calculationMode = .linear
        animation.isRemovedOnCompletion = false
        animation.fillMode = .forwards
        layer.add(animation, forKey: keyPath)
    }

    private static func normalizedSamples(_ input: [MotionSample], clipStart: Double, clipDuration: Double) -> [MotionSample] {
        let sorted = input.sorted { $0.time < $1.time }
        guard let first = sorted.first, let last = sorted.last else { return [] }
        var result = sorted
        if first.time > clipStart {
            result.insert(MotionSample(time: clipStart, points: first.points, lightOK: first.lightOK), at: 0)
        }
        let clipEnd = clipStart + clipDuration
        if last.time < clipEnd {
            result.append(MotionSample(time: clipEnd, points: last.points, lightOK: last.lightOK))
        }
        return result
    }

    private static func visiblePoint(_ sample: MotionSample, joint: BodyJoint, renderSize: CGSize) -> CGPoint? {
        guard sample.lightOK, let point = sample.points[joint.rawValue], point.confidence >= MovementEngine.minimumConfidence,
              point.x.isFinite, point.y.isFinite, point.x >= 0, point.x <= 1, point.y >= 0, point.y <= 1 else { return nil }
        return CGPoint(x: point.x * renderSize.width, y: point.y * renderSize.height)
    }
}
