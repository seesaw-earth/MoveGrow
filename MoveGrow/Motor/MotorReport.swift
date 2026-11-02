// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
//
// Codable results of the motor engine. The full report lives in `<memory id>.motor.json`;
// the album keeps only a `MotorSummary` (enough for badges and cross-session trends).

import Foundation

enum FindingStatus: String, Codable, Hashable {
    case detected, notDetected = "not_detected", abstained, notApplicable = "not_applicable"
    case expectedForAge = "expected_for_age"
}

enum FindingSeverity: String, Codable, Hashable, Comparable {
    case info, note, discuss, safety
    var rank: Int { switch self { case .info: return 0; case .note: return 1; case .discuss: return 2; case .safety: return 3 } }
    static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
}

struct MotorEvent: Codable, Hashable {
    var t0: Double
    var t1: Double
    var limbs: [String] = []
    var hz: Double?
    var p2pCm: Double?
    var bilateral: Bool?
    var message: LocalizedText?
}

struct MotorFinding: Codable, Hashable, Identifiable {
    var ruleID: String
    var ruleVersion: String
    var ruleStatus: String            // enabled | research | abstain_always
    var family: String?
    var status: FindingStatus
    var severity: FindingSeverity
    var name: LocalizedText
    var message: LocalizedText?
    var abstainReason: LocalizedText?
    var events: [MotorEvent] = []
    var metrics: [String: Double] = [:]
    var direction: String?
    var coverage: Double?
    var id: String { ruleID }

    var isShown: Bool { status == .detected || status == .expectedForAge }
}

struct MotorContext: Codable, Hashable {
    var fs: Double
    var nyquistHz: Double
    var durationS: Double
    var frames: Int
    var torsoCoverage: Double
    var lightOKFraction: Double
    var aspect: Double
    var aspectAssumed: Bool
    var contextTag: String
    var torsoCmPrior: Double
    var cameraHFRms: Double?
    var rigidR2Median: Double?
    var notes: [LocalizedText] = []
}

struct MotorReport: Codable, Hashable {
    var engine: String
    var rulesSchema: String
    var generatedAt: Date
    var ageWeeks: Double?
    var context: MotorContext
    var findings: [MotorFinding]
    var highFrequencyComplete: Bool

    var shown: [MotorFinding] {
        findings.filter(\.isShown).sorted { ($0.severity, $1.ruleID) > ($1.severity, $0.ruleID) }
    }
    var summary: MotorSummary {
        MotorSummary(engine: engine, generatedAt: generatedAt, highFrequencyComplete: highFrequencyComplete,
                     fs: context.fs, contextTag: context.contextTag,
                     statuses: Dictionary(uniqueKeysWithValues: findings.map { ($0.ruleID, MotorSummary.Entry(status: $0.status, severity: $0.severity, direction: $0.direction)) }))
    }
}

/// Small per-memory digest kept in album.json.
struct MotorSummary: Codable, Hashable {
    struct Entry: Codable, Hashable {
        var status: FindingStatus
        var severity: FindingSeverity
        var direction: String?
    }
    var engine: String
    var generatedAt: Date
    var highFrequencyComplete: Bool
    var fs: Double
    var contextTag: String
    var statuses: [String: Entry]

    var highestShownSeverity: FindingSeverity? {
        statuses.values.filter { $0.status == .detected }.map(\.severity).max()
    }
    var detectedCount: Int { statuses.values.filter { $0.status == .detected && $0.severity >= .note }.count }
}

/// Cross-session persistence (reference: engine.longitudinal).
struct MotorTrend: Codable, Hashable, Identifiable {
    var ruleID: String
    var name: LocalizedText
    var evaluatedSessions: Int
    var detectedSessions: Int
    var spanDays: Int?
    var direction: String?
    var persistent: Bool
    var severity: FindingSeverity
    var message: LocalizedText?
    var id: String { ruleID }
}

enum MotorLongitudinal {
    static func trends(sessions: [(date: Date, summary: MotorSummary)], book: MotorRuleBook,
                       calendar: Calendar = .current) -> [MotorTrend] {
        var out: [MotorTrend] = []
        for rule in book.rules {
            guard let lg = rule.longitudinal else { continue }
            let rows = sessions.compactMap { s -> (Date, MotorSummary.Entry)? in
                guard let e = s.summary.statuses[rule.id], e.status == .detected || e.status == .notDetected else { return nil }
                return (s.date, e)
            }
            let det = rows.filter { $0.1.status == .detected }
            var trend = MotorTrend(ruleID: rule.id, name: rule.name, evaluatedSessions: rows.count, detectedSessions: det.count,
                                   spanDays: nil, direction: nil, persistent: false,
                                   severity: FindingSeverity(rawValue: lg.severity ?? "note") ?? .note, message: nil)
            if det.count >= lg.min_sessions, let first = det.map(\.0).min(), let last = det.map(\.0).max() {
                let span = calendar.dateComponents([.day], from: calendar.startOfDay(for: first), to: calendar.startOfDay(for: last)).day ?? 0
                var counts: [String: Int] = [:]
                var order: [String] = []
                for (_, e) in det { let k = e.direction ?? "-"; if counts[k] == nil { order.append(k) }; counts[k, default: 0] += 1 }
                let top = order.max { counts[$0]! < counts[$1]! } ?? "-"
                let consistent = !(lg.same_direction ?? false) || counts[top]! >= lg.min_sessions
                let frac = Double(det.count) / Double(rows.count)
                trend.spanDays = span
                trend.direction = top == "-" ? nil : top
                if span >= lg.min_span_days, consistent, frac >= 0.6 {
                    trend.persistent = true
                    let sideZh = ["L": "左侧", "R": "右侧"][top]
                    let sideEn = ["L": "left", "R": "right"][top]
                    let same = lg.same_direction ?? false
                    let zh = "\(rule.name.zh ?? rule.id)：在 \(span) 天内的 \(det.count)/\(rows.count) 次录像中出现" +
                        ((same && sideZh != nil) ? "（均偏向宝宝的\(sideZh!)）" : "") + "。建议带上这些视频和医生或物理治疗师聊聊。"
                    let en = "\(rule.name.en ?? rule.id): seen in \(det.count) of \(rows.count) recordings over \(span) days" +
                        ((same && sideEn != nil) ? " (always toward the baby's \(sideEn!))" : "") + ". Consider showing these videos to your doctor or physiotherapist."
                    trend.message = LocalizedText(zh: zh, en: en)
                }
            }
            out.append(trend)
        }
        return out
    }
}
