# MoveGrow motor-rules prototype — Copyright (C) 2026 Ziqing Shi
# SPDX-License-Identifier: AGPL-3.0-only
"""Rule engine: PoseArchive JSON + rules.json -> descriptive findings with explicit abstentions."""
from __future__ import annotations

import copy
import datetime as dt
import json
import os
from collections import Counter

import numpy as np

from . import dsl
from .archive import J, PoseSeries, load_archive
from .bodyframe import build_body_frame, moving_average
from .events import activity_summary, axial_signal, burst_events, limb_speeds, merge_runs, runs
from .posture import posture_features
from .spectral import CHANNELS, CONTRA, spectral_windows

ENGINE_VERSION = "motor-rules-py-0.1"
HERE = os.path.dirname(os.path.abspath(__file__))
# Single source of truth: the rule book shipped inside the iOS app bundle.
APP_RESOURCES = os.path.join(HERE, "..", "..", "..", "MoveGrow", "Motor", "Resources")
DEFAULT_RULES = os.path.join(APP_RESOURCES, "rules.json")
DEFAULT_SOURCES = os.path.join(APP_RESOURCES, "sources.json")

LIMB_ZH = {"L_arm": "左臂", "R_arm": "右臂", "L_leg": "左腿", "R_leg": "右腿"}
LIMB_EN = {"L_arm": "left arm", "R_arm": "right arm", "L_leg": "left leg", "R_leg": "right leg"}
SIDE_ZH = {"L": "左侧", "R": "右侧"}
SIDE_EN = {"L": "left", "R": "right"}
SEVERITY = ["info", "note", "discuss", "safety"]


def _fmt(tpl: str | None, **kw) -> str | None:
    if not tpl:
        return None
    try:
        return tpl.format(**kw)
    except (KeyError, ValueError, TypeError):
        return tpl


def _num(x):
    if isinstance(x, (np.floating, np.integer)):
        x = x.item()
    if isinstance(x, float) and not np.isfinite(x):
        return None
    return x


def _clean(o):
    if isinstance(o, dict):
        return {k: _clean(v) for k, v in o.items()}
    if isinstance(o, (list, tuple)):
        return [_clean(v) for v in o]
    if isinstance(o, np.ndarray):
        return [_clean(v) for v in o.tolist()]
    if isinstance(o, (np.bool_,)):
        return bool(o)
    return _num(o)


def smoothed_copy(ps: PoseSeries, win_s: float = 0.2) -> PoseSeries:
    q = copy.copy(ps)
    q.xy = moving_average(ps.xy, max(1, int(round(win_s * ps.fs))))
    return q


class MotorEngine:
    def __init__(self, rules_path: str = DEFAULT_RULES, sources_path: str = DEFAULT_SOURCES):
        with open(rules_path, encoding="utf-8") as fh:
            self.spec = json.load(fh)
        with open(sources_path, encoding="utf-8") as fh:
            self.sources = json.load(fh)["sources"]
        self.rules = self.spec["rules"]

    # ------------------------------------------------------------------ public
    def analyze(self, archive, age_weeks: float | None = None, context: str = "supine",
                torso_cm: float = 20.0, session_id: str | None = None,
                session_date: str | None = None, include_research: bool = True) -> dict:
        ps = load_archive(archive)
        bf_raw = build_body_frame(ps)
        ps_s = smoothed_copy(ps)
        bf_s = build_body_frame(ps_s)
        cache: dict = {}
        env = dict(ps=ps, bf_raw=bf_raw, ps_s=ps_s, bf_s=bf_s, cache=cache, age=age_weeks,
                   context=context, torso_cm=torso_cm)
        ctx = self._context(env)
        findings = []
        for rule in self.rules:
            if rule["status"] == "research" and not include_research:
                continue
            findings.append(self._run(rule, env))
        counts = Counter(f["status"] for f in findings)
        detected = [f for f in findings if f["status"] in ("detected",)]
        top = max((SEVERITY.index(f["severity"]) for f in detected), default=-1)
        return _clean({
            "engine": ENGINE_VERSION, "rules_schema": self.spec.get("schema"),
            "session_id": session_id, "session_date": session_date,
            "age_weeks": age_weeks, "context": ctx, "findings": findings,
            "summary": {"status_counts": dict(counts),
                        "highest_severity": SEVERITY[top] if top >= 0 else None},
        })

    # ----------------------------------------------------------------- context
    def _context(self, env) -> dict:
        ps, bf = env["ps"], env["bf_raw"]
        nyq = 0.5 * ps.fs
        torso = [J[n] for n in ("leftShoulder", "rightShoulder", "leftHip", "rightHip")]
        cov = float(np.mean(np.all(np.isfinite(ps.xy[:, torso, 0]), axis=1)))
        notes = []
        if ps.fs < 24:
            notes.append({"zh": f"采样约 {ps.fs:.0f} fps，奈奎斯特频率 {nyq:.1f} Hz：无法分析 6 Hz 以上的抖动；若是从更高帧率视频直接抽帧，高频抖动还会混叠成低频假象。建议 ≥30 fps（最好 60 fps）并逐帧分析。",
                          "en": f"~{ps.fs:.0f} fps (Nyquist {nyq:.1f} Hz): >6 Hz tremor bands are unobservable, and decimating a faster video without anti-aliasing folds them into lower bands."})
        if ps.meta.get("aspect_assumed"):
            notes.append({"zh": "存档中没有画面宽高比，按 9:16 竖屏处理；角度类特征可能有偏差。",
                          "en": "aspectRatio missing; assumed 9:16 portrait."})
        light = float(np.mean(ps.light_ok))
        if light < 0.7:
            notes.append({"zh": f"只有 {light*100:.0f}% 的帧光线合格。", "en": f"only {light*100:.0f}% of frames well lit."})
        cam = None
        if ps.fs >= 24:
            S = self._spectral(env, "fast")
            vals = [r["camera_rms"] for r in S["rows"] if r.get("channel") == "L_arm"]
            r2 = [r["rigid_r2"] for r in S["rows"] if r.get("channel") == "L_arm" and np.isfinite(r["rigid_r2"])]
            if vals:
                cam = {"hf_centroid_rms_torso_median": float(np.median(vals)),
                       "rigid_r2_median": float(np.median(r2)) if r2 else None}
        return {"fs": ps.fs, "nyquist_hz": nyq, "duration_s": ps.duration, "frames": ps.T,
                "torso_coverage": cov, "light_ok_frac": light, "aspect": ps.aspect,
                "context_tag": env["context"], "torso_cm_prior": env["torso_cm"],
                "camera_hf": cam, "notes": notes}

    # ------------------------------------------------------------- dispatcher
    def _base(self, rule) -> dict:
        return {"rule_id": rule["id"], "version": rule.get("version"), "rule_status": rule["status"],
                "name": rule["name"], "family": rule.get("family"), "severity": rule.get("severity", "info"),
                "sources": [{"id": s, **self.sources.get(s, {})} for s in rule.get("sources", [])],
                "explain": rule.get("explain"), "followup": rule.get("followup")}

    def _run(self, rule, env) -> dict:
        out = self._base(rule)
        if rule["status"] == "abstain_always":
            out.update(status="abstained", abstain_reason=rule.get("abstain_reason"))
            return out
        ps = env["ps"]
        req = rule.get("requires", {})
        # sampling-rate gate
        if ps.fs < req.get("min_fps", 0):
            out.update(status="abstained", abstain_reason={
                "zh": f"需要 ≥{req['min_fps']} fps，本次约 {ps.fs:.0f} fps（奈奎斯特 {ps.fs/2:.1f} Hz）。",
                "en": f"needs >= {req['min_fps']} fps; got {ps.fs:.0f}."})
            return out
        # context gate
        ctxt = env["context"]
        if (req.get("context") and ctxt not in req["context"]) or ctxt in req.get("context_exclude", []):
            out.update(status="abstained", abstain_reason={
                "zh": f"这条规则只在 {req.get('context') or '非 ' + str(req.get('context_exclude'))} 场景下判断（本次：{ctxt}）。",
                "en": f"context '{ctxt}' not supported by this rule."})
            return out
        # coverage gate
        joints = [J[n] for n in req.get("joints", [])]
        if joints:
            cov = float(np.mean(np.all(np.isfinite(ps.xy[:, joints, 0]), axis=1)))
            out["coverage"] = cov
            if cov < req.get("min_coverage", 0.0):
                out.update(status="abstained", abstain_reason={
                    "zh": f"所需关键点只在 {cov*100:.0f}% 的帧中可见（需要 ≥{req['min_coverage']*100:.0f}%）。",
                    "en": f"required joints visible in {cov*100:.0f}% of frames."})
                return out
        # age gate
        ag = rule.get("age_weeks")
        below = False
        if ag:
            age = env["age"]
            if age is None:
                out.update(status="abstained", abstain_reason={"zh": "需要宝宝的（矫正）月龄。", "en": "needs (corrected) age."})
                return out
            if "max" in ag and age > ag["max"]:
                out.update(status="not_applicable", abstain_reason={"zh": "超出该规则适用的月龄范围。", "en": "outside age range."})
                return out
            if "min" in ag and age < ag["min"]:
                if ag.get("below_min_status") == "expected_for_age":
                    below = True
                else:
                    out.update(status="not_applicable", abstain_reason={"zh": "未到该规则适用的月龄。", "en": "below age range."})
                    return out
        if "severity_by_age" in rule and env["age"] is not None:
            for s in rule["severity_by_age"]:
                if env["age"] >= s["min_weeks"]:
                    out["severity"] = s["severity"]

        handler = {"spectral": self._rule_spectral, "posture": self._rule_posture,
                   "posture_side": self._rule_posture_side, "posture_stat": self._rule_posture_stat,
                   "activity": self._rule_activity, "burst": self._rule_burst}[rule["analysis"]]
        res = handler(rule, env)
        out.update(res)
        if below and out.get("status") == "detected":
            out["status"] = "expected_for_age"
            out["severity"] = "info"
            out["message"] = rule.get("message_expected", out.get("message"))
        return out

    # --------------------------------------------------------------- caches
    def _spectral(self, env, band):
        key = ("spec", band)
        if key not in env["cache"]:
            env["cache"][key] = spectral_windows(env["ps"], env["bf_raw"], band, torso_cm=env["torso_cm"])
        return env["cache"][key]

    def _posture(self, env):
        if "posture" not in env["cache"]:
            env["cache"]["posture"] = posture_features(env["bf_s"])
        return env["cache"]["posture"]

    def _speeds(self, env):
        if "speeds" not in env["cache"]:
            env["cache"]["speeds"] = limb_speeds(env["ps_s"], env["bf_s"])
        return env["cache"]["speeds"]

    def _activity(self, env):
        if "activity" not in env["cache"]:
            pf = self._posture(env)
            env["cache"]["activity"] = activity_summary(
                env["ps_s"], env["bf_s"], self._speeds(env),
                knee_angles={"L": pf["knee_angle_L"], "R": pf["knee_angle_R"]})
        return env["cache"]["activity"]

    def _valid_ctx(self, env):
        return env["bf_s"].valid & env["ps"].light_ok

    # ------------------------------------------------------------- handlers
    def _rule_spectral(self, rule, env) -> dict:
        S = self._spectral(env, rule["band"])
        if S["abstain"]:
            return {"status": "abstained", "abstain_reason": {"zh": S["abstain"], "en": S["abstain"]}}
        P, pred = rule["params"], rule["window_predicate"]
        names = dsl.features_used(pred)
        ep = rule.get("episode", {})
        hop, gap, min_d = S["hop_s"], ep.get("merge_gap_s", 0.5), ep.get("min_duration_s", 0.0)
        ftol = ep.get("freq_tol_hz", 1e9)  # a real rhythm keeps its frequency; noise peaks wander
        eps = []
        n_valid = 0
        for ch in CHANNELS:
            rows = [r for r in S["rows"] if r["channel"] == ch]
            cur = None
            for r in rows:
                ok = False
                if r.get("valid"):
                    n_valid += 1
                    feats = {k: r.get(k, np.nan) for k in names}
                    ok = bool(dsl.evaluate(pred, feats, P))
                if ok:
                    if (cur is not None and r["t0"] - cur["last_t0"] <= hop + gap + 1e-6
                            and abs(r["peak_hz"] - float(np.median([x["peak_hz"] for x in cur["rows"]]))) <= ftol):
                        cur["rows"].append(r)
                        cur["last_t0"], cur["t1"] = r["t0"], r["t1"]
                    else:
                        if cur is not None:
                            eps.append(cur)
                        cur = {"channel": ch, "t0": r["t0"], "t1": r["t1"], "last_t0": r["t0"], "rows": [r]}
            if cur is not None:
                eps.append(cur)
        for e in eps:
            e["dur"] = e["t1"] - e["t0"]
            e["hz"] = float(np.median([r["peak_hz"] for r in e["rows"]]))
            e["p2p_cm"] = float(np.median([r["amp_p2p_cm"] for r in e["rows"]]))
            e["p2p_torso"] = float(np.median([r["amp_p2p"] for r in e["rows"]]))
            e["prom_db"] = float(np.median([r["prominence_db"] for r in e["rows"]]))
            e["rhythmicity"] = float(np.median([r["rhythmicity"] for r in e["rows"]]))
        eps = [e for e in eps if e["dur"] >= min_d - 1e-6]

        def overlap(a, b):
            return max(0.0, min(a["t1"], b["t1"]) - max(a["t0"], b["t0"]))

        if rule.get("laterality") == "unilateral":
            keep = []
            for e in eps:
                contra = [o for o in eps if o["channel"] == CONTRA[e["channel"]]]
                ov = sum(overlap(e, o) for o in contra)
                if ov <= 0.3 * e["dur"]:
                    keep.append(e)
            eps = keep
        # group overlapping episodes across limbs
        eps.sort(key=lambda e: e["t0"])
        groups: list[list[dict]] = []
        for e in eps:
            for g in groups:
                if any(overlap(e, o) > 0 for o in g):
                    g.append(e)
                    break
            else:
                groups.append([e])
        events = []
        for g in groups:
            chans = sorted({e["channel"] for e in g})
            sides = {c[0] for c in chans}
            bil = len(sides) == 2
            ev = dict(t0=min(e["t0"] for e in g), t1=max(e["t1"] for e in g), limbs=chans,
                      hz=float(np.median([e["hz"] for e in g])), p2p_cm=float(np.median([e["p2p_cm"] for e in g])),
                      prom_db=float(np.median([e["prom_db"] for e in g])),
                      rhythmicity=float(np.median([e["rhythmicity"] for e in g])),
                      bilateral=bil)
            ev["dur"] = ev["t1"] - ev["t0"]
            kw = dict(t0=ev["t0"], t1=ev["t1"], dur=ev["dur"], hz=ev["hz"], p2p_cm=ev["p2p_cm"],
                      limbs_zh="、".join(LIMB_ZH[c] for c in chans), limbs_en=", ".join(LIMB_EN[c] for c in chans),
                      laterality_zh="双侧" if bil else f"仅{SIDE_ZH[next(iter(sides))]}",
                      laterality_en="both sides" if bil else f"{SIDE_EN[next(iter(sides))]} side only")
            ev["message"] = {"zh": _fmt(rule["message"]["zh"], **kw), "en": _fmt(rule["message"].get("en"), **kw)}
            events.append(ev)
        metrics = {"n_valid_windows": n_valid, "band": rule["band"], "search_hz": S["search"]}
        if not events:
            return {"status": "not_detected", "events": [], "metrics": metrics}
        if rule.get("aggregate"):
            limb_counts = Counter(c for ev in events for c in ev["limbs"])
            top = [c for c, _ in limb_counts.most_common(2)]
            kw = dict(n=len(events), total_s=sum(e["dur"] for e in events),
                      hz=float(np.median([e["hz"] for e in events])),
                      limbs_zh="、".join(LIMB_ZH[c] for c in top), limbs_en=", ".join(LIMB_EN[c] for c in top))
            metrics.update(n_bouts=kw["n"], total_s=kw["total_s"], median_hz=kw["hz"], limb_counts=dict(limb_counts))
            return {"status": "detected", "events": events, "metrics": metrics,
                    "message": {"zh": _fmt(rule["message"]["zh"], **kw), "en": _fmt(rule["message"].get("en"), **kw)}}
        return {"status": "detected", "events": events, "metrics": metrics,
                "message": events[0]["message"] if len(events) == 1 else {
                    "zh": f"共 {len(events)} 段；第一段：" + events[0]["message"]["zh"],
                    "en": f"{len(events)} episodes; first: " + (events[0]["message"]["en"] or "")}}

    def _session_feats_common(self, env) -> dict:
        a = self._activity(env)
        return {"leg_active_frac": float(np.nanmean([a["L_leg"]["active_frac"], a["R_leg"]["active_frac"]])),
                "arm_active_frac": float(np.nanmean([a["L_arm"]["active_frac"], a["R_arm"]["active_frac"]]))}

    def _rule_posture(self, rule, env) -> dict:
        ps, P = env["ps"], rule["params"]
        feats = self._posture(env)
        vctx = self._valid_ctx(env)
        pred = rule["frame_predicate"]
        vm = dsl.valid_mask(pred, feats) & vctx
        tr = dsl.evaluate(pred, feats, P) & vm
        ep = rule.get("episode", {})
        fs = ps.fs
        eps = [(a, b) for a, b in merge_runs(runs(tr), int(round(ep.get("merge_gap_s", 0.5) * fs)))
               if (b - a) / fs >= ep.get("min_duration_s", 0.0)]
        true_s = sum((b - a) for a, b in eps) / fs
        obs = float(vm.sum() / fs)
        sess = {"observed_s": obs, "true_s": true_s, "fraction": true_s / obs if obs > 0 else np.nan,
                "n_episodes": len(eps), "longest_s": max(((b - a) / fs for a, b in eps), default=0.0)}
        if "denominator_predicate" in rule:
            dp = rule["denominator_predicate"]
            dm = dsl.evaluate(dp, feats, P) & dsl.valid_mask(dp, feats) & vctx
            sess["denominator_s"] = float(dm.sum() / fs)
            sess["frac_of_denominator"] = true_s / sess["denominator_s"] if sess["denominator_s"] > 0 else np.nan
        sess.update(self._session_feats_common(env))
        detected = bool(dsl.evaluate(rule["session_predicate"], sess, P))
        pct = 100 * (sess.get("frac_of_denominator", sess["fraction"]) if "denominator_s" in sess else sess["fraction"])
        kw = dict(pct=pct if np.isfinite(pct) else 0.0, n=len(eps), obs=obs, true_s=true_s,
                  leg_act=100 * sess["leg_active_frac"] if np.isfinite(sess["leg_active_frac"]) else 0.0)
        events = [{"t0": float(ps.t[a]), "t1": float(ps.t[b - 1]), "dur": (b - a) / fs} for a, b in eps]
        return {"status": "detected" if detected else "not_detected", "metrics": sess, "events": events,
                "message": {"zh": _fmt(rule["message"]["zh"], **kw), "en": _fmt(rule["message"].get("en"), **kw)} if detected else None}

    def _rule_posture_side(self, rule, env) -> dict:
        ps, P = env["ps"], rule["params"]
        feats = self._posture(env)
        sig = feats[rule["side_signal"]["f"]]
        thr = dsl.resolve(rule["side_signal"]["thr"], P)
        valid = np.isfinite(sig) & self._valid_ctx(env)
        fs = ps.fs
        TL = float(np.sum(valid & (sig >= thr)) / fs)
        TR = float(np.sum(valid & (sig <= -thr)) / fs)
        obs = float(valid.sum() / fs)
        turned = TL + TR
        pi = (TL - TR) / turned if turned > 0 else np.nan
        sess = {"observed_s": obs, "left_s": TL, "right_s": TR, "turned_frac": turned / obs if obs > 0 else np.nan,
                "pref_index": pi}
        detected = bool(dsl.evaluate(rule["session_predicate"], sess, P))
        side = "L" if (np.isfinite(pi) and pi > 0) else "R"
        kw = dict(pct=100 * max(TL, TR) / turned if turned > 0 else 0.0, side_zh=SIDE_ZH[side],
                  side_en=SIDE_EN[side], pi=pi if np.isfinite(pi) else 0.0, obs=obs)
        return {"status": "detected" if detected else "not_detected", "metrics": sess,
                "direction": side if detected else None,
                "message": {"zh": _fmt(rule["message"]["zh"], **kw), "en": _fmt(rule["message"].get("en"), **kw)} if detected else None}

    def _rule_posture_stat(self, rule, env) -> dict:
        ps, P = env["ps"], rule["params"]
        sig = self._posture(env)[rule["stat_signal"]["f"]]
        valid = np.isfinite(sig) & self._valid_ctx(env)
        obs = float(valid.sum() / ps.fs)
        med = float(np.median(sig[valid])) if valid.any() else np.nan
        sess = {"observed_s": obs, "median": med,
                "iqr": float(np.subtract(*np.percentile(sig[valid], [75, 25]))) if valid.any() else np.nan}
        detected = bool(dsl.evaluate(rule["session_predicate"], sess, P))
        side = "R" if (np.isfinite(med) and med > 0) else "L"
        kw = dict(median=med if np.isfinite(med) else 0.0, side_zh=SIDE_ZH[side], side_en=SIDE_EN[side], obs=obs)
        return {"status": "detected" if detected else "not_detected", "metrics": sess,
                "direction": side if detected else None,
                "message": {"zh": _fmt(rule["message"]["zh"], **kw), "en": _fmt(rule["message"].get("en"), **kw)} if detected else None}

    def _rule_activity(self, rule, env) -> dict:
        a = self._activity(env)
        P = rule["params"]
        sess = {k: v for k, v in a.items() if not isinstance(v, dict)}
        detected = bool(dsl.evaluate(rule["session_predicate"], sess, P))
        side = a["arm_less_side"]
        kw = dict(side_zh=SIDE_ZH[side], side_en=SIDE_EN[side], ai=a["arm_asym_index"])
        per_limb = {ch: a[ch] for ch in CHANNELS}
        return {"status": "detected" if detected else "not_detected", "metrics": {**sess, "per_limb": per_limb},
                "direction": side if detected else None,
                "message": {"zh": _fmt(rule["message"]["zh"], **kw), "en": _fmt(rule["message"].get("en"), **kw)} if detected else None}

    def _rule_burst(self, rule, env) -> dict:
        P = rule["params"]
        p = {k: v["value"] for k, v in P.items()}
        key = ("burst", json.dumps(p, sort_keys=True))
        if key not in env["cache"]:
            env["cache"][key] = burst_events(env["ps_s"], self._speeds(env), p, axial=axial_signal(env["bf_s"]))
        B = env["cache"][key]
        sess = {"largest_cluster": B["largest_cluster"], "n_sudden": B["n_sudden"], "n_events": len(B["events"]),
                "cluster_median_interval_s": B["cluster_median_interval_s"], "cluster_interval_cv": B["cluster_interval_cv"],
                "surrogate_p": B["surrogate_p"],
                "speed_threshold": B["threshold"]}
        detected = bool(dsl.evaluate(rule["session_predicate"], sess, P))
        msg, events = None, []
        if detected:
            c = B["best"]
            kw = dict(n=c["n_events"], dur=c["median_dur_s"], iv=c["median_interval_s"])
            msg = {"zh": _fmt(rule["message"]["zh"], **kw), "en": _fmt(rule["message"].get("en"), **kw)}
            events = [e for e in B["events"] if e["sudden"] and c["t0"] <= e["t0"] <= c["t1"]]
            sess["cluster"] = c
        return {"status": "detected" if detected else "not_detected", "metrics": sess,
                "events": events, "message": msg}


# ---------------------------------------------------------------- longitudinal
def longitudinal(reports: list[dict], rules: list[dict]) -> list[dict]:
    """Promote session-level findings that persist across sessions/days in the same direction."""
    out = []
    for rule in rules:
        lg = rule.get("longitudinal")
        if not lg:
            continue
        rows = []
        for rep in reports:
            f = next((x for x in rep["findings"] if x["rule_id"] == rule["id"]), None)
            if f and f["status"] in ("detected", "not_detected") and rep.get("session_date"):
                rows.append((dt.date.fromisoformat(rep["session_date"]), f))
        det = [(d, f) for d, f in rows if f["status"] == "detected"]
        res = {"rule_id": rule["id"], "name": rule["name"], "evaluated_sessions": len(rows),
               "detected_sessions": len(det), "status": "not_detected", "severity": lg.get("severity", "note")}
        if len(det) >= lg["min_sessions"]:
            span = (max(d for d, _ in det) - min(d for d, _ in det)).days
            dirs = Counter(f.get("direction") for _, f in det)
            direction, n_dir = dirs.most_common(1)[0]
            consistent = (not lg.get("same_direction")) or n_dir >= lg["min_sessions"]
            frac = len(det) / len(rows)
            res.update(span_days=span, direction=direction, detected_fraction=frac)
            if span >= lg["min_span_days"] and consistent and frac >= 0.6:
                res["status"] = "persistent"
                side = {"L": "左侧", "R": "右侧"}.get(direction, "")
                res["message"] = {"zh": f"{rule['name']['zh']}：在 {span} 天内的 {len(det)}/{len(rows)} 次录像中出现" +
                                        (f"（均偏向宝宝的{side}）" if side and lg.get("same_direction") else "") +
                                        "。建议带上这些视频和医生或物理治疗师聊聊。"}
        out.append(res)
    return out


def render_text(report: dict, lang: str = "zh") -> str:
    ctx = report["context"]
    lines = [f"会话 {report.get('session_id') or ''}  时长 {ctx['duration_s']:.0f}s  采样 {ctx['fs']:.0f}fps  "
             f"月龄(周) {report.get('age_weeks')}  场景 {ctx['context_tag']}"]
    for n in ctx["notes"]:
        lines.append("  · " + n[lang])
    order = {"safety": 0, "discuss": 1, "note": 2, "info": 3}
    det = [f for f in report["findings"] if f["status"] in ("detected", "expected_for_age")]
    det.sort(key=lambda f: order.get(f["severity"], 9))
    for f in det:
        lines.append(f"[{f['severity']}] {f['name'][lang]} — {(f.get('message') or {}).get(lang) or ''}")
    ab = [f for f in report["findings"] if f["status"] == "abstained"]
    if ab:
        lines.append("未判断：" + "；".join(f"{f['name'][lang]}（{(f.get('abstain_reason') or {}).get(lang, '')}）" for f in ab))
    nd = [f["name"][lang] for f in report["findings"] if f["status"] == "not_detected"]
    if nd:
        lines.append("未发现：" + "、".join(nd))
    return "\n".join(lines)
