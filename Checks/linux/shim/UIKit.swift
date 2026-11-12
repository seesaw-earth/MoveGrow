// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
@_exported import CoreGraphics
public struct UIBackgroundTaskIdentifier: Equatable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let invalid = UIBackgroundTaskIdentifier(rawValue: 0)
}
@MainActor public final class UIApplication {
    public static let shared = UIApplication()
    public enum State: Sendable { case active, inactive, background }
    public var applicationState: State = .active
    public var backgroundTimeRemaining: TimeInterval = 30
    public var expiration: (@MainActor @Sendable () -> Void)?
    public var open: Set<Int> = []
    private var next = 1
    public func beginBackgroundTask(withName taskName: String?, expirationHandler handler: (@MainActor @Sendable () -> Void)? = nil) -> UIBackgroundTaskIdentifier {
        next += 1; open.insert(next); expiration = handler
        return UIBackgroundTaskIdentifier(rawValue: next)
    }
    public func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) { open.remove(identifier.rawValue) }
}
public final class UIImage {
    public init(cgImage: CGImage) {}
    public func jpegData(compressionQuality: CGFloat) -> Data? { Data("jpeg".utf8) }
}
