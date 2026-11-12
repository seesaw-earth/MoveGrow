// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
@_exported import Foundation
open class BGTask: @unchecked Sendable {
    public let identifier: String
    public var expirationHandler: (@Sendable () -> Void)?
    public private(set) var completed: Bool?
    public init(identifier: String) { self.identifier = identifier }
    public func setTaskCompleted(success: Bool) { completed = success }
}
public final class BGProcessingTask: BGTask, @unchecked Sendable {}
public final class BGContinuedProcessingTask: BGTask, @unchecked Sendable {
    public let progress = Progress(totalUnitCount: 0)
    public private(set) var title = "", subtitle = ""
    public func updateTitle(_ title: String, subtitle: String) { self.title = title; self.subtitle = subtitle }
}
open class BGTaskRequest: @unchecked Sendable {
    public let identifier: String
    public init(identifier: String) { self.identifier = identifier }
}
public final class BGProcessingTaskRequest: BGTaskRequest, @unchecked Sendable {
    public var requiresExternalPower = false
    public var requiresNetworkConnectivity = false
}
public final class BGContinuedProcessingTaskRequest: BGTaskRequest, @unchecked Sendable {
    public enum Strategy: Sendable { case fail, queue }
    public var strategy: Strategy = .queue
    public init(identifier: String, title: String, subtitle: String) { super.init(identifier: identifier) }
}
public final class BGTaskScheduler: @unchecked Sendable {
    public static let shared = BGTaskScheduler()
    public var handlers: [String: @Sendable (BGTask) -> Void] = [:]
    public var submitted: [BGTaskRequest] = []
    public var rejectContinued = false
    public var lastContinued: BGContinuedProcessingTask?
    public func register(forTaskWithIdentifier identifier: String, using queue: DispatchQueue?, launchHandler: @escaping @Sendable (BGTask) -> Void) -> Bool {
        handlers[identifier] = launchHandler; return true
    }
    public func submit(_ taskRequest: BGTaskRequest) throws {
        if taskRequest is BGContinuedProcessingTaskRequest && rejectContinued { throw CocoaError(.featureUnsupported) }
        submitted.append(taskRequest)
        // A continued task starts at once (strategy .fail): run its handler on the main queue.
        if taskRequest is BGContinuedProcessingTaskRequest, let h = handlers[taskRequest.identifier] {
            let task = BGContinuedProcessingTask(identifier: taskRequest.identifier)
            lastContinued = task
            DispatchQueue.main.async { h(task) }
        }
    }
}
