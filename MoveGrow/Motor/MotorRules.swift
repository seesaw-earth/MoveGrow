// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
//
// rules.json / sources.json model and the predicate language (reference: dsl.py).

import Foundation

/// A short text in the two languages the rule book carries.
struct LocalizedText: Codable, Hashable {
    var zh: String?
    var en: String?

    /// Chinese for Chinese-language devices, otherwise English (falling back to whichever exists).
    func resolved(preferChinese: Bool = LocalizedText.prefersChinese) -> String {
        (preferChinese ? (zh ?? en) : (en ?? zh)) ?? ""
    }

    static var prefersChinese: Bool {
        (Locale.preferredLanguages.first ?? "en").lowercased().hasPrefix("zh")
    }
}

struct RuleParam: Decodable {
    let value: Double
    let unit: String
    let origin: String
    let source: String?
    let note: String?

    private enum K: String, CodingKey { case value, unit, origin, source, note }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        if let b = try? c.decode(Bool.self, forKey: .value) { value = b ? 1 : 0 }
        else { value = try c.decode(Double.self, forKey: .value) }
        unit = try c.decode(String.self, forKey: .unit)
        origin = try c.decode(String.self, forKey: .origin)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }
}

indirect enum RuleOperand: Decodable {
    case number(Double)
    case param(String)
    case pair(RuleOperand, RuleOperand)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) { self = .number(d); return }
        if let s = try? c.decode(String.self) {
            guard s.hasPrefix("$") else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "string operand must be $param") }
            self = .param(String(s.dropFirst())); return
        }
        let arr = try c.decode([RuleOperand].self)
        guard arr.count == 2 else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "range needs [lo, hi]") }
        self = .pair(arr[0], arr[1])
    }

    func scalar(_ p: [String: RuleParam]) -> Double {
        switch self {
        case .number(let d): return d
        case .param(let n): return p[n]?.value ?? .nan
        case .pair: return .nan
        }
    }

    func range(_ p: [String: RuleParam]) -> (Double, Double) {
        if case .pair(let a, let b) = self { return (a.scalar(p), b.scalar(p)) }
        return (.nan, .nan)
    }
}

indirect enum RulePredicate: Decodable {
    case all([RulePredicate])
    case any([RulePredicate])
    case not(RulePredicate)
    case leaf(feature: String, op: String, value: RuleOperand)

    private enum K: String, CodingKey { case all, any, not, f, op, v }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        if let a = try c.decodeIfPresent([RulePredicate].self, forKey: .all) { self = .all(a); return }
        if let a = try c.decodeIfPresent([RulePredicate].self, forKey: .any) { self = .any(a); return }
        if let n = try c.decodeIfPresent(RulePredicate.self, forKey: .not) { self = .not(n); return }
        self = .leaf(feature: try c.decode(String.self, forKey: .f), op: try c.decode(String.self, forKey: .op),
                     value: try c.decode(RuleOperand.self, forKey: .v))
    }

    var features: Set<String> {
        switch self {
        case .all(let ps), .any(let ps): return ps.reduce(into: Set<String>()) { $0.formUnion($1.features) }
        case .not(let p): return p.features
        case .leaf(let f, _, _): return [f]
        }
    }

    /// True only on known (finite) values: unknown is never evidence.
    func evaluate(_ feats: [String: Double], _ p: [String: RuleParam]) -> Bool {
        switch self {
        case .all(let ps): return ps.allSatisfy { $0.evaluate(feats, p) }
        case .any(let ps): return ps.contains { $0.evaluate(feats, p) }
        case .not(let q):
            let known = q.features.allSatisfy { (feats[$0] ?? .nan).isFinite }
            return known && !q.evaluate(feats, p)
        case .leaf(let f, let op, let v):
            let x = feats[f] ?? .nan
            guard x.isFinite else { return false }
            switch op {
            case ">": return x > v.scalar(p)
            case ">=": return x >= v.scalar(p)
            case "<": return x < v.scalar(p)
            case "<=": return x <= v.scalar(p)
            case "==": return x == v.scalar(p)
            case "abs>=": return abs(x) >= v.scalar(p)
            case "abs<=": return abs(x) <= v.scalar(p)
            case "between": let (lo, hi) = v.range(p); return x >= lo && x <= hi
            case "outside": let (lo, hi) = v.range(p); return x < lo || x > hi
            default: return false
            }
        }
    }

    /// Vectorized evaluation over per-frame feature arrays.
    func evaluateFrames(_ feats: [String: [Double]], _ p: [String: RuleParam], count: Int) -> [Bool] {
        let names = Array(features)
        var row: [String: Double] = [:]
        return (0..<count).map { i in
            for n in names { row[n] = feats[n]?[i] ?? .nan }
            return evaluate(row, p)
        }
    }

    func validFrames(_ feats: [String: [Double]], count: Int) -> [Bool] {
        let names = Array(features)
        return (0..<count).map { i in names.allSatisfy { (feats[$0]?[i] ?? .nan).isFinite } }
    }
}

struct SignalSpec: Decodable { let f: String; let thr: RuleOperand? }
struct EpisodeSpec: Decodable { let min_duration_s: Double?; let merge_gap_s: Double?; let freq_tol_hz: Double? }
struct AgeGate: Decodable { let min: Double?; let max: Double?; let below_min_status: String?; let source: String? }
struct SeverityByAge: Decodable { let min_weeks: Double; let severity: String }
struct Requirements: Decodable {
    let min_fps: Double?
    let series: String?
    let context: [String]?
    let context_exclude: [String]?
    let joints: [String]?
    let min_coverage: Double?
}
struct LongitudinalSpec: Decodable { let min_sessions: Int; let min_span_days: Int; let same_direction: Bool?; let severity: String? }

struct MotorRule: Decodable {
    let id: String
    let version: String
    let status: String
    let family: String?
    let analysis: String
    let band: String?
    let aggregate: Bool?
    let name: LocalizedText
    let requires: Requirements?
    let params: [String: RuleParam]?
    let window_predicate: RulePredicate?
    let frame_predicate: RulePredicate?
    let denominator_predicate: RulePredicate?
    let session_predicate: RulePredicate?
    let side_signal: SignalSpec?
    let stat_signal: SignalSpec?
    let episode: EpisodeSpec?
    let laterality: String?
    let age_weeks: AgeGate?
    let severity_by_age: [SeverityByAge]?
    let longitudinal: LongitudinalSpec?
    let severity: String?
    let message: LocalizedText?
    let message_expected: LocalizedText?
    let explain: LocalizedText?
    let followup: LocalizedText?
    let abstain_reason: LocalizedText?
    let sources: [String]

    var p: [String: RuleParam] { params ?? [:] }
}

struct MotorSource: Decodable, Hashable {
    let cite: String
    let url: String
    let basis: String
}

/// The bundled rule book (rules.json + sources.json).
struct MotorRuleBook: Decodable {
    let schema: String
    let rules: [MotorRule]
    var sources: [String: MotorSource] = [:]

    private enum K: String, CodingKey { case schema, rules }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        schema = try c.decode(String.self, forKey: .schema)
        rules = try c.decode([MotorRule].self, forKey: .rules)
    }

    init(rulesData: Data, sourcesData: Data?) throws {
        self = try JSONDecoder().decode(MotorRuleBook.self, from: rulesData)
        if let sourcesData {
            struct Wrap: Decodable { let sources: [String: MotorSource] }
            sources = try JSONDecoder().decode(Wrap.self, from: sourcesData).sources
        }
    }

    func rule(_ id: String) -> MotorRule? { rules.first { $0.id == id } }

    /// The copy shipped in the app bundle.
    static let bundled: MotorRuleBook? = {
        guard let r = Bundle.main.url(forResource: "rules", withExtension: "json"),
              let data = try? Data(contentsOf: r) else { return nil }
        let s = Bundle.main.url(forResource: "sources", withExtension: "json").flatMap { try? Data(contentsOf: $0) }
        return try? MotorRuleBook(rulesData: data, sourcesData: s)
    }()
}

/// Minimal Python `str.format` for rule templates: `{name}`, `{name:.1f}`, `{name:+.2f}`.
enum RuleTemplate {
    static func render(_ template: String?, _ values: [String: Any]) -> String? {
        guard let template else { return nil }
        var out = ""
        var i = template.startIndex
        while i < template.endIndex {
            let ch = template[i]
            if ch == "{", let close = template[i...].firstIndex(of: "}") {
                let body = template[template.index(after: i)..<close]
                let parts = body.split(separator: ":", maxSplits: 1).map(String.init)
                let name = parts.first ?? ""
                let spec = parts.count > 1 ? parts[1] : ""
                if let v = values[name] {
                    out += format(v, spec)
                } else {
                    out += "{" + body + "}"
                }
                i = template.index(after: close)
            } else {
                out.append(ch)
                i = template.index(after: i)
            }
        }
        return out
    }

    private static func format(_ v: Any, _ spec: String) -> String {
        if let d = (v as? Double) ?? (v as? Int).map(Double.init) {
            guard !spec.isEmpty else { return d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : String(d) }
            var s = spec
            let plus = s.hasPrefix("+")
            if plus { s.removeFirst() }
            var digits = 6
            if s.hasPrefix("."), s.hasSuffix("f") { digits = Int(s.dropFirst().dropLast()) ?? 6 }
            return String(format: "%\(plus ? "+" : "").\(digits)f", d)
        }
        return "\(v)"
    }
}
