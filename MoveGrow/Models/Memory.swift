// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

struct Baby: Codable, Equatable {
    var name: String
    var birthday: Date
    /// Optional due date for babies born early; enables corrected age.
    var dueDate: Date?

    /// "14 days old", "1 month, 14 days" (with the corrected age for babies born early, unless
    /// `corrected` is false).
    func age(on date: Date, corrected: Bool = true) -> String {
        let c = Calendar.current.dateComponents([.month, .day], from: Calendar.current.startOfDay(for: birthday), to: Calendar.current.startOfDay(for: date))
        let m = max(0, c.month ?? 0), d = max(0, c.day ?? 0)
        let base: String
        if m == 0 {
            base = d == 1 ? tr("1 day old") : tr("%lld days old", d)
        } else {
            base = tr("%1$@, %2$@", m == 1 ? tr("1 month") : tr("%lld months", m), d == 1 ? tr("1 day") : tr("%lld days", d))
        }
        guard corrected, usesCorrectedAge(on: date), let weeks = correctedWeeks(on: date) else { return base }
        return tr("%1$@ · corrected %2$@", base, Self.weeksLabel(weeks))
    }

    /// Chronological age in weeks.
    func chronologicalWeeks(on date: Date) -> Double {
        date.timeIntervalSince(Calendar.current.startOfDay(for: birthday)) / (7 * 86_400)
    }

    /// Born at least two weeks before the due date and still under 24 months chronological age.
    func usesCorrectedAge(on date: Date) -> Bool {
        guard let dueDate else { return false }
        return dueDate.timeIntervalSince(birthday) >= 14 * 86_400 && chronologicalWeeks(on: date) < 104
    }

    func correctedWeeks(on date: Date) -> Double? {
        guard let dueDate else { return nil }
        return date.timeIntervalSince(Calendar.current.startOfDay(for: dueDate)) / (7 * 86_400)
    }

    /// The age the movement checks use: corrected age for preterm babies, otherwise chronological.
    func analysisWeeks(on date: Date) -> Double {
        if usesCorrectedAge(on: date), let w = correctedWeeks(on: date) { return max(0, w) }
        return max(0, chronologicalWeeks(on: date))
    }

    /// "6 wk", "3 mo".
    static func weeksLabel(_ weeks: Double) -> String {
        let w = max(0, weeks)
        if w < 13 { return tr("%lld wk", Int(w)) }
        let m = Int(w / 4.345)
        return m == 1 ? tr("1 mo") : tr("%lld mo", m)
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

/// How the baby was positioned in the recording. Posture checks need `supine` (on the back, filmed from above).
enum RecordingContext: String, Codable, CaseIterable, Identifiable {
    case supine, prone, held, sitting, standing, walking, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .supine: return tr("On back")
        case .prone: return tr("Tummy time")
        case .held: return tr("Being held")
        case .sitting: return tr("Sitting")
        case .standing: return tr("Standing")
        case .walking: return tr("Walking")
        case .other: return tr("Other position")
        }
    }
}

/// Analysis progress persisted with the memory.
enum AnalysisStage: String, Codable, Hashable {
    /// 15 fps pass done: summary, suggestions and posture checks are available.
    case quick
    /// Full-rate pass done (or not needed): rhythm checks are available too.
    case complete
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
    // v1.1 additions — all optional so v1.0 albums decode unchanged.
    var contextTag: RecordingContext?
    var analysisStage: AnalysisStage?
    var motor: MotorSummary?
    var videoFPS: Double?
    var aspectRatio: Double?
    /// "mgpose1" once binary pose tracks exist; nil means legacy JSON (or none yet).
    var poseStorage: String?
    /// Older recordings get the detailed (full-rate) pass only when the parent asks for it.
    var detailDeferred: Bool?
    /// Kinematics summary for the Growth tab's across-video trends.
    var kinematics: SessionKinematics?
    // v1.2 dates (see VideoDate.swift). `date` stays the resolved date everything else uses.
    /// The date found automatically (recording time, the video's metadata, or the import time).
    var capturedDate: Date?
    /// How `capturedDate` was found; nil for older memories (treated as the filming date).
    var dateOrigin: DateOrigin?
    /// The parent's own date, when they set one.
    var dateSetting: DateSetting?

    var durationLabel: String { clock(duration) }
    /// Videos have no title of their own until the parent gives one ("A little moment" in older albums).
    var hasOwnTitle: Bool { !title.isEmpty && title != "A little moment" }
    var displayTitle: String { hasOwnTitle ? title : tr("A little moment") }
    var context: RecordingContext { contextTag ?? .supine }
    var hasPoseData: Bool { poseStorage != nil || report != nil }
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
