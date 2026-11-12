// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
@_exported import CoreGraphics
public struct CMTime: Sendable {
    public var seconds: Double
    public init(seconds: Double, preferredTimescale: Int32) { self.seconds = seconds }
    public init(value: Int64, timescale: Int32) { self.seconds = Double(value) / Double(timescale) }
}
public struct CMTimeRange: Sendable { public init(start: CMTime, end: CMTime) {} }
public final class AVAsyncProperty<Root, Value>: @unchecked Sendable {
    let get: (Root) throws -> Value
    init(_ get: @escaping (Root) throws -> Value) { self.get = get }
}
open class AVAsset: @unchecked Sendable {
    public let url: URL
    init(url: URL) { self.url = url }
    public func load<T>(_ property: AVAsyncProperty<AVAsset, T>) async throws -> T { try property.get(self) }
}
public final class AVURLAsset: AVAsset, @unchecked Sendable { public override init(url: URL) { super.init(url: url) } }
extension AVAsyncProperty where Root == AVAsset, Value == CMTime {
    /// Fake: the "video" file holds "fixture:<name>:<seconds>".
    public static var duration: AVAsyncProperty<AVAsset, CMTime> {
        AVAsyncProperty { asset in
            let text = try String(contentsOf: asset.url, encoding: .utf8)
            let parts = text.split(separator: ":")
            guard parts.count == 3, parts[0] == "fixture", let d = Double(parts[2]) else { throw CocoaError(.fileReadCorruptFile) }
            return CMTime(seconds: d, preferredTimescale: 600)
        }
    }
}
public final class AVAssetImageGenerator {
    public var appliesPreferredTrackTransform = false
    public var maximumSize = CGSize.zero
    public var requestedTimeToleranceBefore = CMTime(seconds: 0, preferredTimescale: 600)
    public var requestedTimeToleranceAfter = CMTime(seconds: 0, preferredTimescale: 600)
    public init(asset: AVAsset) {}
    public func image(at time: CMTime) async throws -> (image: CGImage, actualTime: CMTime) { (CGImage(), time) }
}
