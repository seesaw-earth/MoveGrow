// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

struct Baby: Codable, Equatable {
    var name: String
    var birthday: Date
    func age(on date: Date) -> String {
        let c = Calendar.current.dateComponents([.month, .day], from: Calendar.current.startOfDay(for: birthday), to: Calendar.current.startOfDay(for: date))
        let m = max(0, c.month ?? 0), d = max(0, c.day ?? 0)
        return m == 0 ? "\(d) days old" : "\(m) mo · \(d) days"
    }
}
struct Moment: Identifiable, Codable, Hashable {
    var id = UUID()
    var memoryID: UUID
    var title: String
    var date: Date
    var start: Double
    var end: Double
    var note: String = ""
    var thumbnail: String?
}
struct Memory: Identifiable, Codable, Hashable {
    var id: UUID
    var date: Date
    var title: String
    var duration: Double
    var filename: String
    var thumbnail: String?
    var favorite = false
    var note = ""
    var report: MovementReport?
    var analysisError: String?
    var poseEstimator: String?
    var poseProcessing: String?
    var milestoneSuggestions: [MilestoneSuggestion]?
    var durationLabel: String { clock(duration) }
}
struct MovementEvent: Identifiable, Codable, Hashable {
    var id = UUID()
    var limb: String
    var start: Double
    var end: Double
    var title: String { "\(limb) movement" }
}
struct LimbSummary: Identifiable, Codable, Hashable {
    var name: String
    var observedSeconds: Double
    var activeSeconds: Double
    var medianSpeed: Double
    var angleRange: Double?
    var id: String { name }
    var activeFraction: Double? { observedSeconds >= 3 ? activeSeconds / observedSeconds : nil }
}
struct MovementReport: Codable, Hashable {
    var version: Int = 1
    var generatedAt = Date()
    var duration: Double
    var limbs: [LimbSummary]
    var headVisibleSeconds: Double
    var fullBodySeconds: Double
    var events: [MovementEvent]
    var summary: String
    var qualityNote: String
}
struct Album: Codable {
    var schemaVersion = 1
    var baby: Baby?
    var memories: [Memory] = []
    var moments: [Moment] = []
    var deletedFiles: [String]? = []
}
func clock(_ seconds: Double) -> String {
    let s = max(0, Int(seconds.isFinite ? seconds : 0))
    return String(format: "%d:%02d", s / 60, s % 60)
}
