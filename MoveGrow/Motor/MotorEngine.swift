// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
//
// Rule engine: pose track + rule book → descriptive findings with explicit abstentions
// (reference: Research/motor-rules/motor_rules/engine.py). Deterministic, no network, no ML.

import Foundation

struct MotorEngineInput {
    var track: PoseTrack
    var ageWeeks: Double?
    var context: String = "supine"
    var torsoCm: Double = 20.0
    var aspect: Double?
    var includeResearch = true
}

final class MotorEngine {
    static let version = "motor-rules-swift-0.2"  // 0.2: Spanish texts (stored results are re-rendered)
    let book: MotorRuleBook

    init(book: MotorRuleBook) { self.book = book }

    private static let limbZh: [MotorChannel: String] = [.L_arm: "左臂", .R_arm: "右臂", .L_leg: "左腿", .R_leg: "右腿"]
    private static let limbEn: [MotorChannel: String] = [.L_arm: "left arm", .R_arm: "right arm", .L_leg: "left leg", .R_leg: "right leg"]
    private static let sideZh = ["L": "左侧", "R": "右侧"], sideEn = ["L": "left", "R": "right"]
    /// Spanish limbs with their article, and sides agreeing with "lado" / "brazo" / "hombro".
    private static let limbEs: [MotorChannel: String] = [.L_arm: "el brazo izquierdo", .R_arm: "el brazo derecho",
                                                         .L_leg: "la pierna izquierda", .R_leg: "la pierna derecha"]
    private static let sideEs = ["L": "izquierdo", "R": "derecho"]

    /// "el brazo izquierdo y la pierna derecha"
    private static func listEs(_ items: [String]) -> String {
        items.count <= 1 ? (items.first ?? "") : items.dropLast().joined(separator: ", ") + " y " + items.last!
    }

    /// Lazily computed shared analyses for one session.
    private final class Env {
        let s: MotorSeries, bfRaw: MotorBodyFrame, sS: MotorSeries, bfS: MotorBodyFrame
        let input: MotorEngineInput
        var spectral: [String: SpectralResult] = [:]
        lazy var posture: [String: [Double]] = MotorPosture.features(bfS)
        lazy var speeds = MotorEvents.limbSpeeds(sS, bfS)
        lazy var activity: ActivitySummary = MotorEvents.activity(sS, speeds: speeds.limbs, noise: speeds.noise,
                                                                kneeL: posture["knee_angle_L"]!, kneeR: posture["knee_angle_R"]!)
        lazy var validCtx: [Bool] = (0..<s.count).map { bfS.valid[$0] && s.lightOK[$0] }
        var bursts: [String: BurstSummary] = [:]

        init(_ s: MotorSeries, _ input: MotorEngineInput) {
            self.s = s; self.input = input
            bfRaw = MotorBodyFrame(s)
            var smooth = s
            let win = max(1, MM.pyRound(0.2 * s.fs))
            smooth.x = s.x.map { MM.movingAverage($0, win) }
            smooth.y = s.y.map { MM.movingAverage($0, win) }
            sS = smooth
            bfS = MotorBodyFrame(smooth)
        }

        func spectralResult(_ band: String) -> SpectralResult {
            if let r = spectral[band] { return r }
            let r = MotorSpectral.windows(s, bfRaw, band: band, torsoCm: input.torsoCm)
            spectral[band] = r
            return r
        }
    }

    func analyze(_ input: MotorEngineInput) -> MotorReport? {
        guard let s = MotorSeries(track: input.track, aspect: input.aspect) else { return nil }
        let env = Env(s, input)
        let ctx = context(env)
        var findings: [MotorFinding] = []
        for rule in book.rules {
            if rule.status == "research" && !input.includeResearch { continue }
            if rule.status == "disabled" { continue }
            findings.append(run(rule, env))
        }
        return MotorReport(engine: Self.version, rulesSchema: book.schema, generatedAt: Date(), ageWeeks: input.ageWeeks,
                           context: ctx, findings: findings, highFrequencyComplete: s.fs >= 24,
                           rulesFingerprint: book.fingerprint)
    }

    // MARK: context

    private func context(_ env: Env) -> MotorContext {
        let s = env.s
        let nyq = 0.5 * s.fs
        let torso = [MJ.leftShoulder, MJ.rightShoulder, MJ.leftHip, MJ.rightHip]
        let cov = Double((0..<s.count).filter { t in torso.allSatisfy { s.x[$0][t].isFinite } }.count) / Double(s.count)
        var notes: [LocalizedText] = []
        if s.fs < 24 {
            notes.append(LocalizedText(
                zh: String(format: "采样约 %.0f fps，奈奎斯特频率 %.1f Hz：无法分析 6 Hz 以上的抖动；若是从更高帧率视频直接抽帧，高频抖动还会混叠成低频假象。", s.fs, nyq),
                en: String(format: "About %.0f fps (Nyquist %.1f Hz): shaking faster than 6 Hz can't be analysed, and skipping frames from a faster video would fold it into slower, false rhythms.", s.fs, nyq),
                es: "Unos \(String(format: "%.0f", s.fs)) fps (Nyquist \(String(format: "%.1f", nyq).replacingOccurrences(of: ".", with: ",")) Hz): "
                    + "no se pueden analizar temblores de más de 6 Hz, y saltar fotogramas de un video más rápido los convertiría en ritmos más lentos y falsos."))
        }
        if s.aspectAssumed {
            notes.append(LocalizedText(zh: "存档中没有画面宽高比，按 9:16 竖屏处理；角度类特征可能有偏差。",
                                       en: "The video's aspect ratio was missing, so 9:16 portrait was assumed; angles may be off.",
                                       es: "Faltaba la relación de aspecto del video, así que se supuso un formato vertical 9:16; los ángulos pueden no ser exactos."))
        }
        let light = Double(s.lightOK.filter { $0 }.count) / Double(s.count)
        if light < 0.7 {
            notes.append(LocalizedText(zh: String(format: "只有 %.0f%% 的帧光线合格。", light * 100),
                                       en: String(format: "Only %.0f%% of frames were well lit.", light * 100),
                                       es: String(format: "Solo el %.0f %% de los fotogramas tenía buena luz.", light * 100)))
        }
        var camRms: Double?, r2: Double?
        if s.fs >= 24 {
            let rows = env.spectralResult("fast").rows.filter { $0.channel == .L_arm }
            let cams = rows.compactMap { $0.features["camera_rms"] }
            let r2s = rows.compactMap { $0.features["rigid_r2"] }.filter { $0.isFinite }
            if !cams.isEmpty { camRms = MM.median(cams) }
            if !r2s.isEmpty { r2 = MM.median(r2s) }
        }
        return MotorContext(fs: s.fs, nyquistHz: nyq, durationS: s.duration, frames: s.count, torsoCoverage: cov,
                            lightOKFraction: light, aspect: s.aspect, aspectAssumed: s.aspectAssumed,
                            contextTag: env.input.context, torsoCmPrior: env.input.torsoCm,
                            cameraHFRms: camRms, rigidR2Median: r2, notes: notes)
    }

    // MARK: dispatcher

    private func base(_ rule: MotorRule) -> MotorFinding {
        MotorFinding(ruleID: rule.id, ruleVersion: rule.version, ruleStatus: rule.status, family: rule.family,
                     status: .notDetected, severity: FindingSeverity(rawValue: rule.severity ?? "info") ?? .info,
                     name: rule.name)
    }

    private func run(_ rule: MotorRule, _ env: Env) -> MotorFinding {
        var out = base(rule)
        if rule.status == "abstain_always" {
            out.status = .abstained; out.abstainReason = rule.abstain_reason
            return out
        }
        let s = env.s
        let req = rule.requires
        if let minFps = req?.min_fps, s.fs < minFps {
            out.status = .abstained
            out.abstainReason = LocalizedText(
                zh: String(format: "需要 ≥%.0f fps，本次约 %.0f fps（奈奎斯特 %.1f Hz）。", minFps, s.fs, s.fs / 2),
                en: String(format: "Needs at least %.0f fps; this video was analysed at about %.0f fps.", minFps, s.fs),
                es: String(format: "Necesita al menos %.0f fps; este video se analizó a unos %.0f fps.", minFps, s.fs))
            return out
        }
        let ctxt = env.input.context
        if let allowed = req?.context, !allowed.contains(ctxt) {
            out.status = .abstained
            out.abstainReason = LocalizedText(zh: "这项检查只在宝宝仰卧、镜头从上往下拍时进行（本次：\(Self.contextZh(ctxt))）。",
                                              en: "This check only runs when the baby is lying on their back, filmed from above (this video: \(Self.contextEn(ctxt))).",
                                              es: "Esta comprobación solo se hace con el bebé boca arriba, grabado desde arriba (este video: \(Self.contextEs(ctxt))).")
            return out
        }
        if let excluded = req?.context_exclude, excluded.contains(ctxt) {
            out.status = .abstained
            if ctxt == "standing" || ctxt == "walking" {
                out.abstainReason = LocalizedText(zh: "站立和走路本身就有节律性的动作，因此不做这项检查。",
                                                  en: "Skipped while standing or walking: upright movement is rhythmic by itself.",
                                                  es: "No se hace de pie ni caminando: el movimiento erguido ya es rítmico de por sí.")
            } else {
                out.abstainReason = LocalizedText(zh: "被抱着时大人的手会带来晃动和约束，因此不做这项检查。",
                                                  en: "Skipped while the baby is being held: an adult's hands move and restrain the limbs.",
                                                  es: "No se hace con el bebé en brazos: las manos del adulto mueven y sujetan las extremidades.")
            }
            return out
        }
        if let joints = req?.joints, !joints.isEmpty {
            let idx = joints.compactMap { MJ.index[$0] }
            let cov = Double((0..<s.count).filter { t in idx.allSatisfy { s.x[$0][t].isFinite } }.count) / Double(s.count)
            out.coverage = cov
            let need = req?.min_coverage ?? 0
            if cov < need {
                out.status = .abstained
                out.abstainReason = LocalizedText(
                    zh: String(format: "所需的身体部位只在 %.0f%% 的画面中清楚可见（需要 ≥%.0f%%）。", cov * 100, need * 100),
                    en: String(format: "The body parts this needs were clearly visible in %.0f%% of frames (needs %.0f%%).", cov * 100, need * 100),
                    es: String(format: "Las partes del cuerpo necesarias se vieron con claridad en el %.0f %% de los fotogramas (se necesita el %.0f %%).", cov * 100, need * 100))
                return out
            }
        }
        var below = false
        if let ag = rule.age_weeks {
            guard let age = env.input.ageWeeks else {
                out.status = .abstained
                out.abstainReason = LocalizedText(zh: "需要宝宝的（矫正）月龄。", en: "Needs your baby's (corrected) age.",
                                                  es: "Necesita la edad (corregida) de tu bebé.")
                return out
            }
            if let mx = ag.max, age > mx {
                out.status = .notApplicable
                out.abstainReason = LocalizedText(zh: "超出这项检查适用的月龄范围。", en: "Outside the age range for this check.",
                                                  es: "Fuera del rango de edad de esta comprobación.")
                return out
            }
            if let mn = ag.min, age < mn {
                if ag.below_min_status == "expected_for_age" { below = true } else {
                    out.status = .notApplicable
                    out.abstainReason = LocalizedText(zh: "还没到这项检查适用的月龄。", en: "Your baby is younger than the age this check applies to.",
                                                      es: "Tu bebé aún no tiene la edad a la que se aplica esta comprobación.")
                    return out
                }
            }
        }
        if let sba = rule.severity_by_age, let age = env.input.ageWeeks {
            for e in sba where age >= e.min_weeks { out.severity = FindingSeverity(rawValue: e.severity) ?? out.severity }
        }
        switch rule.analysis {
        case "spectral": spectral(rule, env, &out)
        case "posture": posture(rule, env, &out)
        case "posture_side": postureSide(rule, env, &out)
        case "posture_stat": postureStat(rule, env, &out)
        case "activity": activity(rule, env, &out)
        case "burst": burst(rule, env, &out)
        default: out.status = .abstained
        }
        if below && out.status == .detected {
            out.status = .expectedForAge
            out.severity = .info
            out.message = rule.message_expected ?? out.message
        }
        return out
    }

    private static func contextZh(_ c: String) -> String {
        ["supine": "仰卧", "prone": "趴着", "held": "被抱着", "sitting": "坐着", "standing": "站着", "walking": "走路"][c] ?? "其他"
    }
    private static func contextEn(_ c: String) -> String {
        ["supine": "lying on back", "prone": "tummy time", "held": "being held", "sitting": "sitting",
         "standing": "standing", "walking": "walking"][c] ?? "other"
    }
    private static func contextEs(_ c: String) -> String {
        ["supine": "boca arriba", "prone": "boca abajo", "held": "en brazos", "sitting": "sentado",
         "standing": "de pie", "walking": "caminando"][c] ?? "otra postura"
    }

    private func render(_ rule: MotorRule, _ text: LocalizedText?, _ values: [String: Any]) -> LocalizedText? {
        guard let text else { return nil }
        return LocalizedText(zh: RuleTemplate.render(text.zh, values), en: RuleTemplate.render(text.en, values),
                             es: RuleTemplate.render(text.es, values, decimalComma: true))
    }

    // MARK: handlers

    private struct Episode {
        var channel: MotorChannel
        var t0: Double, t1: Double, lastT0: Double
        var rows: [SpectralRow]
        var dur: Double { t1 - t0 }
        func median(_ k: String) -> Double { MM.median(rows.map { $0.features[k] ?? .nan }) }
    }

    private func spectral(_ rule: MotorRule, _ env: Env, _ out: inout MotorFinding) {
        let S = env.spectralResult(rule.band ?? "slow")
        if S.abstain != nil {
            out.status = .abstained
            // The engine's own reason is technical ("sampling rate … too low for … band").
            out.abstainReason = LocalizedText(
                zh: String(format: "帧率（约 %.0f fps）太低，无法分析这类节律。", env.s.fs),
                en: String(format: "The frame rate (about %.0f fps) is too low to analyse this rhythm.", env.s.fs),
                es: String(format: "La frecuencia de imagen (unos %.0f fps) es demasiado baja para analizar este ritmo.", env.s.fs))
            return
        }
        guard let pred = rule.window_predicate else { out.status = .abstained; return }
        let P = rule.p
        let gap = rule.episode?.merge_gap_s ?? 0.5, minD = rule.episode?.min_duration_s ?? 0
        let ftol = rule.episode?.freq_tol_hz ?? 1e9
        let names = pred.features
        var eps: [Episode] = []
        var nValid = 0
        for ch in MotorChannel.allCases {
            var cur: Episode?
            for r in S.rows where r.channel == ch {
                var ok = false
                if r.valid {
                    nValid += 1
                    var feats: [String: Double] = [:]
                    for n in names { feats[n] = r.features[n] ?? .nan }
                    ok = pred.evaluate(feats, P)
                }
                guard ok else { continue }
                if var c = cur, r.t0 - c.lastT0 <= S.hop + gap + 1e-6,
                   abs((r.features["peak_hz"] ?? .nan) - MM.median(c.rows.map { $0.features["peak_hz"] ?? .nan })) <= ftol {
                    c.rows.append(r); c.lastT0 = r.t0; c.t1 = r.t1
                    cur = c
                } else {
                    if let c = cur { eps.append(c) }
                    cur = Episode(channel: ch, t0: r.t0, t1: r.t1, lastT0: r.t0, rows: [r])
                }
            }
            if let c = cur { eps.append(c) }
        }
        eps = eps.filter { $0.dur >= minD - 1e-6 }
        func overlap(_ a: Episode, _ b: Episode) -> Double { max(0, min(a.t1, b.t1) - max(a.t0, b.t0)) }
        if rule.laterality == "unilateral" {
            eps = eps.filter { e in
                let ov = eps.filter { $0.channel == e.channel.contra }.reduce(0.0) { $0 + overlap(e, $1) }
                return ov <= 0.3 * e.dur
            }
        }
        eps = eps.enumerated().sorted { ($0.element.t0, $0.offset) < ($1.element.t0, $1.offset) }.map(\.element)
        var groups: [[Episode]] = []
        for e in eps {
            if let gi = groups.firstIndex(where: { g in g.contains { overlap(e, $0) > 0 } }) { groups[gi].append(e) }
            else { groups.append([e]) }
        }
        var events: [MotorEvent] = []
        for g in groups {
            let chans = Set(g.map(\.channel)).sorted { $0.rawValue < $1.rawValue }
            let sides = Set(chans.map(\.side))
            let bil = sides.count == 2
            var ev = MotorEvent(t0: g.map(\.t0).min()!, t1: g.map(\.t1).max()!, limbs: chans.map(\.rawValue),
                                hz: MM.median(g.map { $0.median("peak_hz") }), p2pCm: MM.median(g.map { $0.median("amp_p2p_cm") }),
                                bilateral: bil)
            let side = sides.first ?? "L"
            let kw: [String: Any] = [
                "t0": ev.t0, "t1": ev.t1, "dur": ev.t1 - ev.t0, "hz": ev.hz ?? .nan, "p2p_cm": ev.p2pCm ?? .nan,
                "limbs_zh": chans.map { Self.limbZh[$0]! }.joined(separator: "、"),
                "limbs_en": chans.map { Self.limbEn[$0]! }.joined(separator: ", "),
                "laterality_zh": bil ? "双侧" : "仅\(Self.sideZh[side]!)",
                "laterality_en": bil ? "both sides" : "\(Self.sideEn[side]!) side only",
                "limbs_es": Self.listEs(chans.map { Self.limbEs[$0]! }),
                "laterality_es": bil ? "en ambos lados" : "solo en el lado \(Self.sideEs[side]!)",
            ]
            ev.message = render(rule, rule.message, kw)
            events.append(ev)
        }
        out.metrics["n_valid_windows"] = Double(nValid)
        out.metrics["search_lo_hz"] = S.searchLo
        out.metrics["search_hi_hz"] = S.searchHi
        out.events = events
        guard !events.isEmpty else { out.status = .notDetected; return }
        out.status = .detected
        if rule.aggregate == true {
            var counts: [String: Int] = [:]
            var order: [String] = []
            for ev in events { for l in ev.limbs { if counts[l] == nil { order.append(l) }; counts[l, default: 0] += 1 } }
            let top = order.enumerated().sorted { (counts[$0.element]!, -$0.offset) > (counts[$1.element]!, -$1.offset) }
                .prefix(2).map { MotorChannel(rawValue: $0.element)! }
            let total = events.reduce(0.0) { $0 + ($1.t1 - $1.t0) }
            let hz = MM.median(events.compactMap(\.hz))
            out.metrics["n_bouts"] = Double(events.count)
            out.metrics["total_s"] = total
            out.metrics["median_hz"] = hz
            out.message = render(rule, rule.message, [
                "n": events.count, "total_s": total, "hz": hz,
                "limbs_zh": top.map { Self.limbZh[$0]! }.joined(separator: "、"),
                "limbs_en": top.map { Self.limbEn[$0]! }.joined(separator: ", "),
                "limbs_es": Self.listEs(top.map { Self.limbEs[$0]! }),
            ])
        } else if events.count == 1 {
            out.message = events[0].message
        } else {
            let first = events[0].message
            out.message = LocalizedText(zh: "共 \(events.count) 段；第一段：" + (first?.zh ?? ""),
                                        en: "\(events.count) episodes; first: " + (first?.en ?? ""),
                                        es: "\(events.count) episodios; el primero: " + (first?.es ?? first?.en ?? ""))
        }
    }

    private func episodes(_ mask: [Bool], fs: Double, gapS: Double, minS: Double) -> [(Int, Int)] {
        MM.mergeRuns(MM.runs(mask), gap: MM.pyRound(gapS * fs)).filter { Double($0.1 - $0.0) / fs >= minS }
    }

    private func commonSession(_ env: Env) -> [String: Double] {
        let a = env.activity.limbs
        func nanmean2(_ x: Double, _ y: Double) -> Double {
            let v = [x, y].filter { !$0.isNaN }
            return v.isEmpty ? .nan : v.reduce(0, +) / Double(v.count)
        }
        return ["leg_active_frac": nanmean2(a[.L_leg]!.activeFrac, a[.R_leg]!.activeFrac),
                "arm_active_frac": nanmean2(a[.L_arm]!.activeFrac, a[.R_arm]!.activeFrac)]
    }

    private func posture(_ rule: MotorRule, _ env: Env, _ out: inout MotorFinding) {
        guard let pred = rule.frame_predicate, let sp = rule.session_predicate else { out.status = .abstained; return }
        let s = env.s, P = rule.p, feats = env.posture, T = s.count
        let vctx = env.validCtx
        let vm = zip(pred.validFrames(feats, count: T), vctx).map { $0 && $1 }
        let truth = zip(pred.evaluateFrames(feats, P, count: T), vm).map { $0 && $1 }
        let eps = episodes(truth, fs: s.fs, gapS: rule.episode?.merge_gap_s ?? 0.5, minS: rule.episode?.min_duration_s ?? 0)
        let trueS = Double(eps.reduce(0) { $0 + ($1.1 - $1.0) }) / s.fs
        let obs = Double(vm.filter { $0 }.count) / s.fs
        var sess: [String: Double] = ["observed_s": obs, "true_s": trueS, "fraction": obs > 0 ? trueS / obs : .nan,
                                      "n_episodes": Double(eps.count),
                                      "longest_s": eps.map { Double($0.1 - $0.0) / s.fs }.max() ?? 0]
        if let dp = rule.denominator_predicate {
            let dm = zip(zip(dp.evaluateFrames(feats, P, count: T), dp.validFrames(feats, count: T)), vctx).map { $0.0 && $0.1 && $1 }
            let ds = Double(dm.filter { $0 }.count) / s.fs
            sess["denominator_s"] = ds
            sess["frac_of_denominator"] = ds > 0 ? trueS / ds : .nan
        }
        sess.merge(commonSession(env)) { a, _ in a }
        let detected = sp.evaluate(sess, P)
        out.metrics = sess
        out.events = eps.map { MotorEvent(t0: s.t[$0.0], t1: s.t[$0.1 - 1]) }
        out.status = detected ? .detected : .notDetected
        if detected {
            let frac = rule.denominator_predicate != nil ? (sess["frac_of_denominator"] ?? .nan) : (sess["fraction"] ?? .nan)
            let pct = 100 * frac
            let leg = sess["leg_active_frac"] ?? .nan
            out.message = render(rule, rule.message, ["pct": pct.isFinite ? pct : 0, "n": eps.count, "obs": obs, "true_s": trueS,
                                                      "leg_act": leg.isFinite ? 100 * leg : 0])
        }
    }

    private func postureSide(_ rule: MotorRule, _ env: Env, _ out: inout MotorFinding) {
        guard let sig = rule.side_signal, let sp = rule.session_predicate, let x = env.posture[sig.f] else { out.status = .abstained; return }
        let s = env.s, P = rule.p
        let thr = sig.thr?.scalar(P) ?? 0.5
        var tl = 0, tr = 0, nobs = 0
        for t in 0..<s.count where x[t].isFinite && env.validCtx[t] {
            nobs += 1
            if x[t] >= thr { tl += 1 }
            if x[t] <= -thr { tr += 1 }
        }
        let TL = Double(tl) / s.fs, TR = Double(tr) / s.fs, obs = Double(nobs) / s.fs
        let turned = TL + TR
        let pi = turned > 0 ? (TL - TR) / turned : .nan
        let sess: [String: Double] = ["observed_s": obs, "left_s": TL, "right_s": TR,
                                      "turned_frac": obs > 0 ? turned / obs : .nan, "pref_index": pi]
        let detected = sp.evaluate(sess, P)
        let side = (pi.isFinite && pi > 0) ? "L" : "R"
        out.metrics = sess
        out.status = detected ? .detected : .notDetected
        out.direction = detected ? side : nil
        if detected {
            out.message = render(rule, rule.message, ["pct": turned > 0 ? 100 * max(TL, TR) / turned : 0,
                                                      "side_zh": Self.sideZh[side]!, "side_en": Self.sideEn[side]!, "side_es": Self.sideEs[side]!,
                                                      "pi": pi.isFinite ? pi : 0, "obs": obs])
        }
    }

    private func postureStat(_ rule: MotorRule, _ env: Env, _ out: inout MotorFinding) {
        guard let sig = rule.stat_signal, let sp = rule.session_predicate, let x = env.posture[sig.f] else { out.status = .abstained; return }
        let s = env.s, P = rule.p
        let vals = (0..<s.count).filter { x[$0].isFinite && env.validCtx[$0] }.map { x[$0] }
        let obs = Double(vals.count) / s.fs
        let med = vals.isEmpty ? Double.nan : MM.median(vals)
        let iqr = vals.isEmpty ? Double.nan : MM.nanPercentile(vals, 75) - MM.nanPercentile(vals, 25)
        let sess: [String: Double] = ["observed_s": obs, "median": med, "iqr": iqr]
        let detected = sp.evaluate(sess, P)
        let side = (med.isFinite && med > 0) ? "R" : "L"
        out.metrics = sess
        out.status = detected ? .detected : .notDetected
        out.direction = detected ? side : nil
        if detected {
            out.message = render(rule, rule.message, ["median": med.isFinite ? med : 0, "side_zh": Self.sideZh[side]!,
                                                      "side_en": Self.sideEn[side]!, "side_es": Self.sideEs[side]!, "obs": obs])
        }
    }

    private func activity(_ rule: MotorRule, _ env: Env, _ out: inout MotorFinding) {
        guard let sp = rule.session_predicate else { out.status = .abstained; return }
        let a = env.activity
        let detected = sp.evaluate(a.session, rule.p)
        let side = a.armLessSide
        out.metrics = a.session
        for (ch, l) in a.limbs {
            out.metrics["\(ch.rawValue)_active_frac"] = l.activeFrac
            out.metrics["\(ch.rawValue)_bouts_per_min"] = l.boutsPerMin
            if let k = l.kicksPerMin { out.metrics["\(ch.rawValue)_kicks_per_min"] = k }
        }
        out.status = detected ? .detected : .notDetected
        out.direction = detected ? side : nil
        if detected {
            out.message = render(rule, rule.message, ["side_zh": Self.sideZh[side]!, "side_en": Self.sideEn[side]!, "side_es": Self.sideEs[side]!,
                                                      "ai": a.session["arm_asym_index"] ?? 0])
        }
    }

    private func burst(_ rule: MotorRule, _ env: Env, _ out: inout MotorFinding) {
        guard let sp = rule.session_predicate else { out.status = .abstained; return }
        let P = rule.p
        let raw = P.mapValues(\.value)
        let key = raw.keys.sorted().map { "\($0)=\(raw[$0]!)" }.joined(separator: ",")
        let B: BurstSummary
        if let cached = env.bursts[key] { B = cached } else {
            B = MotorEvents.bursts(env.sS, speeds: env.speeds.limbs, params: .init(raw), axial: MotorEvents.axialSignals(env.bfS))
            env.bursts[key] = B
        }
        let sess: [String: Double] = ["largest_cluster": Double(B.largestCluster), "n_sudden": Double(B.nSudden),
                                      "n_events": Double(B.events.count),
                                      "cluster_median_interval_s": B.best?.medianIntervalS ?? .nan,
                                      "cluster_interval_cv": B.best?.intervalCV ?? .nan,
                                      "surrogate_p": B.surrogateP, "speed_threshold": B.threshold]
        let detected = sp.evaluate(sess, P)
        out.metrics = sess
        out.status = detected ? .detected : .notDetected
        if detected, let c = B.best {
            out.message = render(rule, rule.message, ["n": c.nEvents, "dur": c.medianDurS, "iv": c.medianIntervalS])
            out.events = B.events.filter { $0.sudden && $0.t0 >= c.t0 && $0.t0 <= c.t1 }
                .map { MotorEvent(t0: $0.t0, t1: $0.t1, limbs: $0.limbs.map(\.rawValue)) }
        }
    }
}
