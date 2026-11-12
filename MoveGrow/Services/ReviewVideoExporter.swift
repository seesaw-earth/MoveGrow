// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
//
// Renders the MP4 export, on the device. Frames are decoded already upright and at the size of
// the video area (a video composition does the rotation and scaling, and maps HDR to SDR), then
// drawn with Core Graphics over a background made once — header, chart tracks, labels, footer.
// On top go the skeleton, the cursor moving through the charts (the part still to come is
// faded) and the current values. AVAssetWriter encodes H.264 + AAC. The layout itself is in
// ReviewExport.swift.

import AVFoundation
import CoreGraphics
import UIKit
import VideoToolbox

/// Header text of the export.
struct ExportCaption: Hashable {
    /// "Mia · 45 days old"
    var title: String
    /// "Mar 3, 2026 · On back"
    var subtitle: String
}

enum ExportError: LocalizedError {
    case noVideo, cannotRead, cannotWrite, stalled, interrupted
    var errorDescription: String? {
        switch self {
        case .noVideo: return tr("This file has no video to export.")
        case .cannotRead: return tr("The video couldn’t be read.")
        case .cannotWrite: return tr("The MP4 couldn’t be written. Check that there is free space on this iPhone.")
        case .stalled: return tr("The export stopped responding. Please try again.")
        case .interrupted: return tr("The export stopped when MoveGrow left the screen. Please try again and keep the app open.")
        }
    }
}

/// The opened source video (loaded once per export sheet).
struct ExportSource: @unchecked Sendable {
    let asset: AVURLAsset
    let video: AVAssetTrack
    let audio: AVAssetTrack?
    /// Natural (stored) frame → upright frame with its origin at zero.
    let display: CGAffineTransform
    let upright: CGSize
    let fps: Double
    /// Where the video track has frames (often ends a little before the sound does).
    let videoRange: CMTimeRange

    var aspect: Double { upright.height > 0 ? Double(upright.width / upright.height) : 9.0 / 16.0 }
    var hasSound: Bool { audio != nil }

    static func load(_ url: URL) async throws -> ExportSource {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw ExportError.noVideo }
        let (natural, transform, fps, range) = try await video.load(.naturalSize, .preferredTransform, .nominalFrameRate, .timeRange)
        let audio = try? await asset.loadTracks(withMediaType: .audio).first
        let r = CGRect(origin: .zero, size: natural).applying(transform)
        let display = transform.concatenating(CGAffineTransform(translationX: -r.minX, y: -r.minY))
        return ExportSource(asset: asset, video: video, audio: audio, display: display,
                            upright: CGSize(width: abs(r.width), height: abs(r.height)), fps: Double(fps), videoRange: range)
    }
}

final class ReviewVideoExporter: @unchecked Sendable {
    struct Input: @unchecked Sendable {
        var source: ExportSource
        var track: PoseTrack?
        var digest: ReviewDigest?
        var caption: ExportCaption
        var options: ReviewExportOptions
        var outputURL: URL
    }

    private let input: Input
    private let lock = NSLock()
    private var cancelled = false

    init(_ input: Input) { self.input = input }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    // MARK: still preview

    /// One composed frame at `time`, exactly as the export will show it.
    static func preview(_ input: Input, at time: Double) async throws -> CGImage {
        let layout = ExportLayout.make(aspect: input.source.aspect, options: input.options)
        let generator = AVAssetImageGenerator(asset: input.source.asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: layout.videoPixelWidth, height: layout.videoPixelHeight)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)
        let (frame, actual) = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
        return try await Task.detached(priority: .userInitiated) {
            let composer = ExportComposer(layout: layout, input: input)
            guard let ctx = ExportComposer.bitmap(width: layout.pixelWidth, height: layout.pixelHeight, data: nil, bytesPerRow: 0) else {
                throw ExportError.cannotWrite
            }
            composer.draw(ctx, frame: frame, time: actual.seconds.isFinite ? actual.seconds : time)
            guard let image = ctx.makeImage() else { throw ExportError.cannotWrite }
            return image
        }.value
    }

    // MARK: export

    /// Writes the MP4 and returns its URL. `progress` (0…1) is called from a background thread.
    func run(progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let o = input.options
        let s = input.source
        let layout = ExportLayout.make(aspect: s.aspect, options: o)
        let fps = ExportTiming.fps(source: s.fps, quality: o.quality)
        let url = input.outputURL
        try? FileManager.default.removeItem(at: url)

        // Writer: H.264 (plays everywhere) + AAC.
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: url, fileType: .mp4) } catch { throw ExportError.cannotWrite }
        writer.shouldOptimizeForNetworkUse = true
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: layout.pixelWidth,
            AVVideoHeightKey: layout.pixelHeight,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: ExportTiming.bitRate(width: layout.pixelWidth, height: layout.pixelHeight, fps: fps),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
            ],
        ])
        videoIn.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: layout.pixelWidth,
            kCVPixelBufferHeightKey as String: layout.pixelHeight,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ])
        guard writer.canAdd(videoIn) else { throw ExportError.cannotWrite }
        writer.add(videoIn)

        // Reader: frames upright, at the video area's pixel size, SDR, constant frame rate. The part
        // ends where the video's frames end (the sound often runs a little longer).
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: s.asset) } catch { throw ExportError.cannotRead }
        let start = CMTime(seconds: o.start, preferredTimescale: 600)
        let end = CMTimeMinimum(CMTime(seconds: o.end, preferredTimescale: 600), s.videoRange.end)
        guard end > start else { throw ExportError.cannotRead }
        reader.timeRange = CMTimeRange(start: start, end: end)

        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: layout.videoPixelWidth, height: layout.videoPixelHeight)
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, end: s.videoRange.end)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: s.video)
        let sx = composition.renderSize.width / max(1, s.upright.width), sy = composition.renderSize.height / max(1, s.upright.height)
        layer.setTransform(s.display.concatenating(CGAffineTransform(scaleX: sx, y: sy)), at: .zero)
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]

        let videoOut = AVAssetReaderVideoCompositionOutput(videoTracks: [s.video],
                                                           videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        videoOut.videoComposition = composition
        videoOut.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOut) else { throw ExportError.cannotRead }
        reader.add(videoOut)

        // Sound only when both ends accept it (an output nobody reads would stall the reader, and an
        // input nobody feeds would stall the writer).
        var audioOut: AVAssetReaderTrackOutput?
        var audioIn: AVAssetWriterInput?
        if o.sound, let track = s.audio {
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            out.alwaysCopiesSampleData = false
            let soundIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000,
            ])
            soundIn.expectsMediaDataInRealTime = false
            if reader.canAdd(out), writer.canAdd(soundIn) {
                reader.add(out)
                writer.add(soundIn)
                audioOut = out
                audioIn = soundIn
            }
        }

        let composer = ExportComposer(layout: layout, input: input)
        guard writer.startWriting() else { throw ExportError.cannotWrite }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else {
            writer.cancelWriting()
            throw Self.describe(reader.error, fallback: .cannotRead)
        }

        let pump = Pump(reader: reader, writer: writer, videoOut: videoOut, videoIn: videoIn, adaptor: adaptor,
                        audioOut: audioOut, audioIn: audioIn, composer: composer, offset: start,
                        span: max(0.1, end.seconds - start.seconds), progress: progress, isCancelled: { [weak self] in self?.isCancelled ?? true })
        do {
            try await withTaskCancellationHandler {
                try await pump.run()
            } onCancel: {
                self.cancel()
            }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        // A reader or writer can fail after the last sample: never hand out a cut-short file.
        guard reader.status != .failed, writer.status == .writing else {
            let error = reader.status == .failed ? Self.describe(reader.error, fallback: .cannotRead) : Self.describe(writer.error)
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            throw Self.describe(writer.error)
        }
        progress(1)
        return url
    }

    /// A decoder or encoder that stopped because the app left the screen reads as "interrupted".
    static func describe(_ error: Error?, fallback: ExportError = .cannotWrite) -> Error {
        guard let ns = error as NSError? else { return fallback }
        let interrupted: [AVError.Code] = [.operationInterrupted, .sessionWasInterrupted,
                                           .decoderTemporarilyUnavailable, .encoderTemporarilyUnavailable]
        if ns.domain == AVFoundationErrorDomain, interrupted.map(\.rawValue).contains(ns.code) {
            return ExportError.interrupted
        }
        return ns
    }
}

/// Feeds frames and sound to the writer on its own thread, whichever input is ready (the writer
/// keeps them interleaved). Ends when both are done, on failure, or when cancelled.
private final class Pump: @unchecked Sendable {
    let reader: AVAssetReader
    let writer: AVAssetWriter
    let videoOut: AVAssetReaderVideoCompositionOutput
    let videoIn: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let audioOut: AVAssetReaderTrackOutput?
    let audioIn: AVAssetWriterInput?
    let composer: ExportComposer
    let offset: CMTime
    let span: Double
    let progress: @Sendable (Double) -> Void
    let isCancelled: () -> Bool

    init(reader: AVAssetReader, writer: AVAssetWriter, videoOut: AVAssetReaderVideoCompositionOutput, videoIn: AVAssetWriterInput,
         adaptor: AVAssetWriterInputPixelBufferAdaptor, audioOut: AVAssetReaderTrackOutput?, audioIn: AVAssetWriterInput?,
         composer: ExportComposer, offset: CMTime, span: Double, progress: @escaping @Sendable (Double) -> Void,
         isCancelled: @escaping () -> Bool) {
        self.reader = reader; self.writer = writer; self.videoOut = videoOut; self.videoIn = videoIn; self.adaptor = adaptor
        self.audioOut = audioOut; self.audioIn = audioIn; self.composer = composer; self.offset = offset; self.span = span
        self.progress = progress; self.isCancelled = isCancelled
    }

    func run() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let thread = Thread {
                do { try self.loop(); c.resume() } catch { c.resume(throwing: error) }
            }
            thread.name = "MoveGrow export"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    private func loop() throws {
        var videoDone = false
        var audioDone = audioOut == nil
        var firstFrame = true
        var lastReport = -1.0
        var idleSince: Date?
        while !(videoDone && audioDone) {
            if isCancelled() { throw CancellationError() }
            if writer.status == .failed { throw ReviewVideoExporter.describe(writer.error) }
            if reader.status == .failed { throw ReviewVideoExporter.describe(reader.error, fallback: .cannotRead) }
            var worked = false

            if !videoDone && videoIn.isReadyForMoreMediaData {
                worked = true
                try autoreleasepool {
                    guard let sample = videoOut.copyNextSampleBuffer() else {
                        // nil is also what a failed read returns: that is an error, not the end.
                        if reader.status == .failed { throw ReviewVideoExporter.describe(reader.error, fallback: .cannotRead) }
                        videoDone = true
                        videoIn.markAsFinished()
                        return
                    }
                    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                    guard let frame = CMSampleBufferGetImageBuffer(sample) else { return }
                    guard let pool = adaptor.pixelBufferPool else { throw ExportError.cannotWrite }
                    var buffer: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                    guard let buffer else { throw ExportError.cannotWrite }
                    composer.render(into: buffer, frame: frame, time: pts.seconds)
                    // The first frame starts the file, so it never opens on a blank frame.
                    let at = firstFrame ? CMTime.zero : CMTimeSubtract(pts, offset)
                    firstFrame = false
                    guard adaptor.append(buffer, withPresentationTime: CMTimeMaximum(at, .zero)) else {
                        throw ReviewVideoExporter.describe(writer.error)
                    }
                    let f = min(1, max(0, (pts.seconds - offset.seconds) / span))
                    if f - lastReport >= 0.005 { lastReport = f; progress(f * 0.99) }
                }
            }

            if !audioDone, let audioIn, let audioOut, audioIn.isReadyForMoreMediaData {
                worked = true
                try autoreleasepool {
                    guard let sample = audioOut.copyNextSampleBuffer() else {
                        if reader.status == .failed { throw ReviewVideoExporter.describe(reader.error, fallback: .cannotRead) }
                        audioDone = true
                        audioIn.markAsFinished()
                        return
                    }
                    guard let shifted = Self.shift(sample, by: offset) else { return }
                    guard audioIn.append(shifted) else { throw ReviewVideoExporter.describe(writer.error) }
                }
            }

            if worked {
                idleSince = nil
            } else {
                // Neither input is ready: the encoder is busy. Give up only if it never recovers.
                let now = Date()
                if let since = idleSince, now.timeIntervalSince(since) > 15 { throw ExportError.stalled }
                if idleSince == nil { idleSince = now }
                usleep(2_000)
            }
        }
    }

    /// Moves a sound buffer to the export's own time line (the part starts at zero).
    static func shift(_ sample: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        guard var timing = try? sample.sampleTimingInfos(), !timing.isEmpty else { return nil }
        var shift = offset
        // The part's start is on a 1/600 s grid and the sound on 1/44100: a first buffer that
        // starts a hair early is moved to zero rather than dropped.
        let early = CMTimeSubtract(offset, timing[0].presentationTimeStamp)
        if early > .zero && early < CMTime(value: 1, timescale: 100) { shift = timing[0].presentationTimeStamp }
        for i in timing.indices {
            timing[i].presentationTimeStamp = CMTimeSubtract(timing[i].presentationTimeStamp, shift)
            if timing[i].decodeTimeStamp.isValid { timing[i].decodeTimeStamp = CMTimeSubtract(timing[i].decodeTimeStamp, shift) }
        }
        guard timing[0].presentationTimeStamp >= .zero else { return nil }
        return try? CMSampleBuffer(copying: sample, withNewTiming: timing)
    }
}

// MARK: - Drawing

/// Draws one export frame. The background (header, tracks, labels) is drawn once; per frame only
/// the video, skeleton, cursor, dots, values and the limb read-out.
final class ExportComposer: @unchecked Sendable {
    let layout: ExportLayout
    let options: ReviewExportOptions
    let track: PoseTrack?
    let digest: ReviewDigest?
    let caption: ExportCaption
    private var lines: [ExportRow: [ExportLine]] = [:]
    private var background: CGImage?

    static let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    static let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    init(layout: ExportLayout, input: ReviewVideoExporter.Input) {
        self.layout = layout
        options = input.options
        track = input.options.skeleton ? input.track : nil
        digest = input.digest
        caption = input.caption
        if let g = digest { for row in layout.rows { lines[row] = ExportData.lines(row, g) } }
        background = makeBackground()
    }

    static func bitmap(width: Int, height: Int, data: UnsafeMutableRawPointer?, bytesPerRow: Int) -> CGContext? {
        CGContext(data: data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                  space: space, bitmapInfo: bitmapInfo)
    }

    func render(into buffer: CVPixelBuffer, frame: CVPixelBuffer?, time: Double) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = Self.bitmap(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
                                    data: CVPixelBufferGetBaseAddress(buffer), bytesPerRow: CVPixelBufferGetBytesPerRow(buffer)) else { return }
        var image: CGImage?
        if let frame { VTCreateCGImageFromCVPixelBuffer(frame, options: nil, imageOut: &image) }
        // The frame's values are already in the file's (BT.709) encoding: tag them as the canvas's
        // space so they pass through unchanged instead of being converted twice.
        draw(ctx, frame: image.map { $0.copy(colorSpace: Self.space) ?? $0 }, time: time)
    }

    /// `ctx` is a bitmap of the export's pixel size (origin bottom-left, as Core Graphics makes them).
    func draw(_ ctx: CGContext, frame: CGImage?, time t: Double) {
        let w = CGFloat(ctx.width), h = CGFloat(ctx.height)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.translateBy(x: 0, y: h)
        ctx.scaleBy(x: 1, y: -1)
        if let background {
            Self.drawUpright(background, in: CGRect(x: 0, y: 0, width: w, height: h), ctx)
        }
        let u = CGFloat(layout.unit)
        ctx.scaleBy(x: u, y: u)
        if let frame {
            ctx.saveGState()
            if layout.framed {
                ctx.addPath(CGPath(roundedRect: layout.video, cornerWidth: 12, cornerHeight: 12, transform: nil))
                ctx.clip()
            }
            ctx.interpolationQuality = .medium
            Self.drawUpright(frame, in: layout.video, ctx)
            ctx.restoreGState()
        }
        drawSkeleton(ctx, t)
        if layout.panel != nil { drawLive(ctx, t) }
    }

    // MARK: background

    private func makeBackground() -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: layout.pixelWidth, height: layout.pixelHeight), format: format)
        let image = renderer.image { r in
            let ctx = r.cgContext
            ctx.scaleBy(x: CGFloat(layout.unit), y: CGFloat(layout.unit))
            let all = CGRect(origin: .zero, size: layout.size)
            guard layout.framed else {
                ctx.setFillColor(UIColor.black.cgColor)
                ctx.fill(all.insetBy(dx: -2, dy: -2))
                return
            }
            ctx.setFillColor(Self.cg(ExportColor.paper))
            ctx.fill(all.insetBy(dx: -2, dy: -2))
            if let header = layout.header { drawHeader(header) }
            ctx.setFillColor(Self.cg(ExportColor.videoBack))
            ctx.addPath(CGPath(roundedRect: layout.video, cornerWidth: 12, cornerHeight: 12, transform: nil))
            ctx.fillPath()
            if let panel = layout.panel { drawPanel(ctx, panel) }
        }
        return image.cgImage
    }

    private func drawHeader(_ r: CGRect) {
        let serif = UIFont.systemFont(ofSize: 17, weight: .semibold).fontDescriptor.withDesign(.serif)
            .map { UIFont(descriptor: $0, size: 17) } ?? UIFont.systemFont(ofSize: 17, weight: .semibold)
        let mark = Self.text("MoveGrow", UIFont.systemFont(ofSize: 11, weight: .semibold), ExportColor.sage)
        let markSize = mark.size()
        let markX = r.maxX - markSize.width
        mark.draw(at: CGPoint(x: markX, y: r.minY + 7))
        let dot = CGRect(x: markX - 11, y: r.minY + 7 + markSize.height / 2 - 3.5, width: 7, height: 7)
        UIColor(hex: ExportColor.sage).setFill()
        UIBezierPath(ovalIn: dot).fill()
        let titleWidth = dot.minX - 8 - r.minX
        Self.text(caption.title, serif, ExportColor.ink)
            .draw(with: CGRect(x: r.minX, y: r.minY + 2, width: titleWidth, height: 22), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
        Self.text(caption.subtitle, UIFont.systemFont(ofSize: 12, weight: .regular), ExportColor.ink, alpha: 0.62)
            .draw(with: CGRect(x: r.minX, y: r.minY + 24, width: r.width, height: 16), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
    }

    private func drawPanel(_ ctx: CGContext, _ panel: CGRect) {
        ctx.setFillColor(Self.cg(ExportColor.card))
        ctx.addPath(CGPath(roundedRect: panel, cornerWidth: 14, cornerHeight: 14, transform: nil))
        ctx.fillPath()
        let o = options
        let label = UIFont.systemFont(ofSize: 10, weight: .semibold)

        // Grid at the axis ticks, across all tracks.
        let step = SeriesMath.tickStep(o.duration)
        var ticks: [Double] = []
        var tick = (o.start / step).rounded(.up) * step
        while tick <= o.end + 1e-6 { ticks.append(tick); tick += step }
        if let first = layout.rowRects.first, let last = layout.rowRects.last {
            ctx.setStrokeColor(Self.cg(ExportColor.ink, 0.08))
            ctx.setLineWidth(0.5)
            for t in ticks {
                let x = CGFloat(layout.x(t, start: o.start, end: o.end))
                ctx.move(to: CGPoint(x: x, y: first.minY)); ctx.addLine(to: CGPoint(x: x, y: last.maxY))
            }
            ctx.strokePath()
        }

        for (row, rect) in zip(layout.rows, layout.rowRects) {
            ctx.setFillColor(Self.cg(ExportColor.ink, 0.05))
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil))
            ctx.fillPath()
            let title = Self.text(row.title, label, ExportColor.ink, alpha: 0.6)
            let size = title.size()
            title.draw(at: CGPoint(x: rect.minX - 6 - size.width, y: rect.midY - size.height / 2))
            guard let g = digest else { continue }
            let range = row.range(g)
            func y(_ v: Double) -> CGFloat { CGFloat(ExportLayout.y(v, in: rect, range: range)) }
            func x(ofBin i: Int) -> CGFloat { CGFloat(layout.x(g.time(ofBin: i), start: o.start, end: o.end)) }
            // Bins inside the exported part (one either side so lines reach the edges).
            let lo = max(0, (g.bin(at: o.start) ?? 0) - 1)
            let hi = min(g.count - 1, (g.bin(at: o.end) ?? (g.count - 1)) + 1)
            guard lo <= hi else { continue }
            ctx.saveGState()
            ctx.clip(to: rect)
            if row == .balance || row == .head {
                ctx.setStrokeColor(Self.cg(ExportColor.ink, 0.22))
                ctx.setLineWidth(0.75)
                ctx.move(to: CGPoint(x: rect.minX, y: y(0))); ctx.addLine(to: CGPoint(x: rect.maxX, y: y(0)))
                ctx.strokePath()
            }
            switch row {
            case .head:
                // Bars from the centre line: up = turned to the baby's left, down = right.
                let y0 = y(0)
                for i in lo...hi {
                    let v = Double(g.headYaw[i])
                    guard v.isFinite, abs(v) > 0.05 else { continue }
                    let x0 = CGFloat(layout.x(g.start + Double(i) * g.bin, start: o.start, end: o.end))
                    let x1 = CGFloat(layout.x(g.start + Double(i + 1) * g.bin, start: o.start, end: o.end))
                    let y1 = y(v)
                    ctx.setFillColor(Self.cg(v > 0 ? ExportColor.leftArm : ExportColor.rightArm, 0.75))
                    ctx.fill(CGRect(x: x0, y: min(y0, y1), width: max(0.6, x1 - x0), height: abs(y1 - y0)))
                }
            case .motion:
                guard let line = lines[row]?.first else { break }
                let area = CGMutablePath()
                var open = false
                var lastX: CGFloat = 0
                for i in lo...hi {
                    let v = Double(line[i])
                    let px = x(ofBin: i)
                    if v.isFinite {
                        if !open { area.move(to: CGPoint(x: px, y: rect.maxY)); open = true }
                        area.addLine(to: CGPoint(x: px, y: y(v)))
                        lastX = px
                    } else if open {
                        area.addLine(to: CGPoint(x: lastX, y: rect.maxY)); area.closeSubpath(); open = false
                    }
                }
                if open { area.addLine(to: CGPoint(x: lastX, y: rect.maxY)); area.closeSubpath() }
                ctx.addPath(area)
                ctx.setFillColor(Self.cg(ExportColor.sage, 0.5))
                ctx.fillPath()
            default:
                for line in lines[row] ?? [] {
                    let path = CGMutablePath()
                    var drawing = false
                    for i in lo...hi {
                        let v = Double(line[i])
                        guard v.isFinite else { drawing = false; continue }
                        let p = CGPoint(x: x(ofBin: i), y: y(v))
                        if drawing { path.addLine(to: p) } else { path.move(to: p); drawing = true }
                    }
                    ctx.addPath(path)
                    ctx.setStrokeColor(Self.cg(line.color, CGFloat(line.alpha)))
                    ctx.setLineWidth(1.6)
                    ctx.setLineCap(.round); ctx.setLineJoin(.round)
                    ctx.setLineDash(phase: 0, lengths: line.dashed ? [4, 3] : [])
                    ctx.strokePath()
                }
                ctx.setLineDash(phase: 0, lengths: [])
            }
            ctx.restoreGState()
        }

        // Time axis (the video's own clock).
        if let axis = layout.axis {
            let font = UIFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
            for (k, t) in ticks.enumerated() {
                let s = Self.text(clock(t), font, ExportColor.ink, alpha: 0.55)
                let size = s.size()
                let x = CGFloat(layout.x(t, start: o.start, end: o.end))
                let left = k == 0 && x - size.width / 2 < axis.minX ? axis.minX : (x + size.width / 2 > axis.maxX ? axis.maxX - size.width : x - size.width / 2)
                s.draw(at: CGPoint(x: left, y: axis.midY - size.height / 2))
            }
        }

        // Legend, units and the note.
        if let f = layout.footer {
            let small = UIFont.systemFont(ofSize: 9, weight: .semibold)
            var x = f.minX
            let y0 = f.minY + 7
            for (side, dashed) in [(tr("Left"), false), (tr("Right"), true)] {
                ctx.setStrokeColor(Self.cg(ExportColor.ink, 0.7))
                ctx.setLineWidth(1.6)
                ctx.setLineDash(phase: 0, lengths: dashed ? [4, 3] : [])
                ctx.move(to: CGPoint(x: x, y: y0)); ctx.addLine(to: CGPoint(x: x + 16, y: y0))
                ctx.strokePath()
                let s = Self.text(side, small, ExportColor.ink, alpha: 0.7)
                s.draw(at: CGPoint(x: x + 20, y: y0 - s.size().height / 2))
                x += 26 + s.size().width
            }
            ctx.setLineDash(phase: 0, lengths: [])
            Self.text(tr("Speed: torso lengths/s · Angles: degrees"), UIFont.systemFont(ofSize: 9), ExportColor.ink, alpha: 0.55)
                .draw(with: CGRect(x: x + 4, y: y0 - 6, width: f.maxX - x - 4, height: 12), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
            Self.text(tr("MoveGrow · describes movement, not a diagnosis"), UIFont.systemFont(ofSize: 9), ExportColor.ink, alpha: 0.45)
                .draw(at: CGPoint(x: f.minX, y: f.minY + 15))
        }
    }

    // MARK: per frame

    private func drawSkeleton(_ ctx: CGContext, _ t: Double) {
        guard let track, let i = track.frame(near: t) else { return }
        let r = layout.video
        func point(_ j: Int) -> CGPoint? {
            let x = track.x(i, j), y = track.y(i, j), c = track.conf(i, j)
            guard c >= 0.3, x.isFinite, y.isFinite, x >= 0, x <= 1, y >= 0, y <= 1 else { return nil }
            return CGPoint(x: r.minX + CGFloat(x) * r.width, y: r.minY + CGFloat(y) * r.height)
        }
        let s = max(0.8, min(1.5, r.width / 300))
        let bones = CGMutablePath()
        for (a, b) in SkeletonDrawing.bones {
            guard let p = point(a), let q = point(b) else { continue }
            bones.move(to: p); bones.addLine(to: q)
        }
        ctx.saveGState()
        ctx.clip(to: r)
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        ctx.addPath(bones); ctx.setStrokeColor(UIColor.black.withAlphaComponent(0.35).cgColor); ctx.setLineWidth(5 * s); ctx.strokePath()
        ctx.addPath(bones); ctx.setStrokeColor(Self.cg(ExportColor.skeleton)); ctx.setLineWidth(3 * s); ctx.strokePath()
        let dots = CGMutablePath()
        for j in 0..<MJ.count {
            guard let p = point(j) else { continue }
            let d = ([MJ.leftWrist, MJ.rightWrist, MJ.leftAnkle, MJ.rightAnkle].contains(j) ? 4.5 : 3) * s
            dots.addEllipse(in: CGRect(x: p.x - d, y: p.y - d, width: 2 * d, height: 2 * d))
        }
        ctx.addPath(dots); ctx.setFillColor(UIColor.white.cgColor); ctx.fillPath()
        ctx.addPath(dots); ctx.setStrokeColor(Self.cg(ExportColor.sage)); ctx.setLineWidth(1.5 * s); ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawLive(_ ctx: CGContext, _ t: Double) {
        let o = options
        let cx = CGFloat(layout.x(t, start: o.start, end: o.end))
        let bin = digest?.bin(at: t)

        // The part still to come is faded.
        ctx.setFillColor(Self.cg(ExportColor.card, 0.62))
        for rect in layout.rowRects where cx < rect.maxX {
            ctx.fill(CGRect(x: cx, y: rect.minY - 0.5, width: rect.maxX - cx + 0.5, height: rect.height + 1))
        }
        if let first = layout.rowRects.first, let last = layout.rowRects.last {
            ctx.setStrokeColor(Self.cg(ExportColor.ink, 0.85))
            ctx.setLineWidth(1.5)
            ctx.move(to: CGPoint(x: cx, y: first.minY - 2)); ctx.addLine(to: CGPoint(x: cx, y: last.maxY + 2))
            ctx.strokePath()
        }

        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext() }
        let valueFont = UIFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)
        for (row, rect) in zip(layout.rows, layout.rowRects) {
            let rowLines = lines[row] ?? []
            if let g = digest, let i = bin {
                let range = row.range(g)
                for line in rowLines where row != .head {
                    let v = Double(line[i])
                    guard v.isFinite else { continue }
                    let y = CGFloat(ExportLayout.y(v, in: rect, range: range))
                    let dot = CGRect(x: cx - 3.2, y: y - 3.2, width: 6.4, height: 6.4)
                    ctx.setFillColor(UIColor.white.cgColor); ctx.fillEllipse(in: dot)
                    ctx.setStrokeColor(Self.cg(line.color, CGFloat(line.alpha))); ctx.setLineWidth(1.8); ctx.strokeEllipse(in: dot)
                }
            }
            let values = ExportData.values(row, rowLines, bin: bin)
            let lineHeight: CGFloat = 11
            var y = rect.midY - lineHeight * CGFloat(values.count) / 2
            for v in values {
                let s = Self.text(v.text, valueFont, v.color)
                s.draw(at: CGPoint(x: rect.maxX + 7, y: y + (lineHeight - s.size().height) / 2))
                y += lineHeight
            }
        }

        // Read-out: the time, and which limbs are moving now.
        if let r = layout.readout {
            let time = Self.text(clock(t), UIFont.monospacedDigitSystemFont(ofSize: 17, weight: .semibold), ExportColor.ink)
            time.draw(at: CGPoint(x: r.minX, y: r.midY - time.size().height / 2))
            let moving = digest.map { ExportData.moving($0, bin: bin) } ?? [:]
            let titles = [tr("L arm"), tr("R arm"), tr("L leg"), tr("R leg")]
            let font = UIFont.systemFont(ofSize: titles.contains { $0.count > 6 } ? 9.5 : 10, weight: .semibold)
            // Pills fit their (translated) names; the row is right-aligned.
            let widths = titles.map { max(46, ceil(Self.text($0, font, ExportColor.ink).size().width) + 10) }
            var x = r.maxX - (widths.reduce(0, +) + 5 * CGFloat(widths.count - 1))
            for (k, (key, title)) in zip(ExportData.limbs, titles).enumerated() {
                let pill = CGSize(width: widths[k], height: 20)
                let rect = CGRect(x: x, y: r.midY - pill.height / 2, width: pill.width, height: pill.height)
                let color = ExportColor.limb(key)
                let state = moving[key]
                ctx.setFillColor(Self.cg(state == nil ? ExportColor.ink : color, state == true ? 1 : (state == nil ? 0.05 : 0.13)))
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 10, cornerHeight: 10, transform: nil))
                ctx.fillPath()
                let s = Self.text(title, font, state == true ? 0xFFFFFF : (state == nil ? ExportColor.ink : color), alpha: state == nil ? 0.35 : 1)
                let size = s.size()
                s.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
                x += pill.width + 5
            }
        }
    }

    // MARK: helpers

    /// Draws an image the right way up in a context whose y axis points down.
    static func drawUpright(_ image: CGImage, in r: CGRect, _ ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
        ctx.restoreGState()
    }

    static func cg(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    static func text(_ s: String, _ font: UIFont, _ hex: UInt32, alpha: CGFloat = 1) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: UIColor(hex: hex).withAlphaComponent(alpha)])
    }
}
