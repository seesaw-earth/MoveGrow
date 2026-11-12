// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
// Test doubles for the parts of the app that need Apple frameworks (video decoding, Core ML).
import Foundation
import CoreGraphics

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

enum YOLOPoseModelProvider { static let estimatorID = "ultralytics-yolo26l-pose-coreml-bundled" }
enum PoseNet { static func prewarm() {} }
enum HMRFrameBackend { static func prewarm() {} }
final class ThumbnailCache: @unchecked Sendable { static let shared = ThumbnailCache(); func invalidate(_ name: String) {} }

extension ProcessInfo { var isLowPowerModeEnabled: Bool { FakeEnv.lowPower } }
extension Notification.Name { static let NSProcessInfoPowerStateDidChange = Notification.Name("NSProcessInfoPowerStateDidChange") }

enum FakeEnv {
    nonisolated(unsafe) static var lowPower = false
    nonisolated(unsafe) static var perFrameDelay: useconds_t = 2000
    nonisolated(unsafe) static var estimator = YOLOPoseModelProvider.estimatorID
    nonisolated(unsafe) static var failInferenceAt: Int?
    nonisolated(unsafe) static var runs: [(id: String, pass: String, frames: Int, skipped: Int)] = []
    static let fixtures = URL(fileURLWithPath: (ProcessInfo.processInfo.environment["MOVEGROW_ROOT"] ?? FileManager.default.currentDirectoryPath) + "/Tests/MotorKitTests/Fixtures")
}

enum VideoAnalyzer {
    static func fixture(_ url: URL) throws -> PoseTrack {
        let parts = try String(contentsOf: url, encoding: .utf8).split(separator: ":")
        guard parts.count == 3 else { throw CocoaError(.fileReadCorruptFile) }
        return try PoseBinary.decode(Data(contentsOf: FakeEnv.fixtures.appendingPathComponent("\(parts[1]).mgpose")))
    }

    static func probe(url: URL) async throws -> VideoInfo {
        let t = try fixture(url)
        let fps = Double(t.count - 1) / max(1e-6, (t.times.last ?? 0) - (t.times.first ?? 0))
        return VideoInfo(duration: t.header.durationSeconds, aspect: t.header.aspectRatio ?? 9.0 / 16, nominalFPS: fps.rounded(),
                         orientation: .up, naturalSize: CGSize(width: 720, height: 1280))
    }

    static func thumbnail(url: URL, duration: Double, maxSide: CGFloat = 400) async -> Data? { Data("jpeg".utf8) }

    static func run(url: URL, info: VideoInfo, plan: AnalysisPlan, pass: AnalysisPlan.Pass, skip: Set<Int64>,
                    control: AnalysisControl, checkpointEvery: Int = 0, estimatorID: String? = nil,
                    progress: @escaping @Sendable (Int, Int) -> Void,
                    checkpoint: (@Sendable ([AnalyzedFrame]) -> Void)? = nil) async throws -> PassResult {
        let track = try fixture(url)
        let all = AnalysisPipeline.frames(from: track)
        let expected = pass == .quick ? plan.frameCount(.quick) : max(1, (plan.estimatedFrames + plan.fullStride - 1) / plan.fullStride - skip.count)
        let name = url.lastPathComponent
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<PassResult, Error>) in
                DispatchQueue.global(qos: .utility).async {
                    var frames: [AnalyzedFrame] = []
                    var failure = false
                    for (k, f0) in all.enumerated() {
                        if control.isCancelled { break }
                        guard plan.includes(frame: k, in: pass), !skip.contains(AnalysisPlan.timeKey(f0.time)) else { continue }
                        control.waitIfNeeded()
                        if let at = FakeEnv.failInferenceAt, frames.count == at { failure = true; control.cancel(); break }
                        usleep(FakeEnv.perFrameDelay)
                        var f = f0
                        f.index = Int32(k)
                        frames.append(f)
                        if frames.count % 25 == 0 { progress(frames.count, max(expected, frames.count)) }
                        if checkpointEvery > 0, frames.count % checkpointEvery == 0, let checkpoint { checkpoint(frames) }
                    }
                    FakeEnv.runs.append((name, pass.rawValue, frames.count, skip.count))
                    if control.isCancelled {
                        if let checkpoint, !frames.isEmpty { checkpoint(frames) }
                        cont.resume(throwing: failure ? AnalysisInterrupted() : CancellationError())
                    } else {
                        progress(frames.count, frames.count)
                        cont.resume(returning: PassResult(frames: frames, estimator: FakeEnv.estimator))
                    }
                }
            }
        } onCancel: { control.cancel() }
    }
}
