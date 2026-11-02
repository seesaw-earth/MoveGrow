# MoveGrow motor-rules prototype — Copyright (C) 2026 Ziqing Shi
# SPDX-License-Identifier: AGPL-3.0-only
"""Scenario tests: each rule must (a) fire on the pattern its source text describes and
(b) stay quiet / abstain where it should. Synthetic data = observability check, not accuracy."""
from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

import numpy as np  # noqa: E402

from motor_rules.archive import load_archive  # noqa: E402
from motor_rules.bodyframe import build_body_frame  # noqa: E402
from motor_rules.engine import MotorEngine, longitudinal  # noqa: E402
from motor_rules.spectral import spectral_windows  # noqa: E402
from motor_rules.synth import simulate  # noqa: E402

FLAGGED = ["rhythm.fast_fine", "rhythm.coarse", "rhythm.slow_unilateral_sustained", "burst.spasm_like_cluster",
           "posture.head_preference", "posture.atnr_like_persistent", "posture.frog_leg",
           "posture.scissoring", "asym.arm_use"]

ENGINE = MotorEngine()

SCENARIOS = [
    dict(name="baseline_30fps", sim=dict(fs=30, seed=1), age=12, expect={r: "not_detected" for r in FLAGGED}
         | {"posture.atnr_like_persistent": "not_detected", "asym.arm_use": "not_applicable"}),
    dict(name="baseline_60fps_20w", sim=dict(fs=60, seed=2), age=20, expect={r: "not_detected" for r in FLAGGED}),
    dict(name="tremor_bilateral_8hz_30fps", sim=dict(fs=30, seed=3, inject=[
        dict(type="tremor", limbs=["L_arm", "R_arm", "L_leg", "R_leg"], f=8.0, amp_p2p=0.05, t0=20, t1=35)]),
         age=2, expect={"rhythm.fast_fine": "detected", "rhythm.coarse": "not_detected"},
         check=lambda rep: _event(rep, "rhythm.fast_fine")["bilateral"] and abs(_event(rep, "rhythm.fast_fine")["hz"] - 8) < 0.6),
    dict(name="tremor_8hz_at_15fps", sim=dict(fs=30, seed=3, decimate=2, inject=[
        dict(type="tremor", limbs=["L_arm", "R_arm"], f=8.0, amp_p2p=0.05, t0=20, t1=35)]),
         age=2, expect={"rhythm.fast_fine": "abstained", "rhythm.coarse": "abstained",
                        "rhythm.slow_unilateral_sustained": "abstained"}),
    dict(name="camera_shake_8hz", sim=dict(fs=30, seed=4, inject=[
        dict(type="camera_shake", f=8.0, amp=0.004, rot_deg=0.5, t0=10, t1=80)]),
         age=4, expect={"rhythm.fast_fine": "not_detected", "rhythm.coarse": "not_detected"}),
    dict(name="coarse_5hz_left_arm", sim=dict(fs=30, seed=5, inject=[
        dict(type="tremor", limbs=["L_arm"], f=5.0, amp_p2p=0.25, t0=30, t1=40)]),
         age=4, expect={"rhythm.coarse": "detected", "rhythm.fast_fine": "not_detected"}),
    dict(name="clonic_left_arm_2hz", sim=dict(fs=30, seed=6, inject=[
        dict(type="clonic", limb="L_arm", f=2.0, amp_deg=35, t0=30, t1=52)]),
         age=1, expect={"rhythm.slow_unilateral_sustained": "detected"},
         check=lambda rep: _event(rep, "rhythm.slow_unilateral_sustained")["limbs"] == ["L_arm"]),
    dict(name="rhythmic_kicking_bilateral", sim=dict(fs=30, seed=7, inject=[
        dict(type="kick_rhythm", f=1.2, amp_deg=30, t0=t0, t1=t0 + 8) for t0 in (10, 40, 70)]),
         age=20, expect={"rhythm.slow_bout": "detected", "rhythm.slow_unilateral_sustained": "not_detected"}),
    dict(name="spasm_like_cluster", sim=dict(fs=30, seed=8, inject=[
        dict(type="spasm_cluster", n=6, interval=8.0, t0=20, t1=72)]),
         age=24, expect={"burst.spasm_like_cluster": "detected"}),
    dict(name="isolated_startles", sim=dict(fs=30, seed=9, inject=[
        dict(type="spasm_cluster", n=1, interval=8.0, t0=t0, t1=t0 + 3) for t0 in (15, 55)]),
         age=24, expect={"burst.spasm_like_cluster": "not_detected"}),
    dict(name="head_pref_right", sim=dict(fs=30, seed=10, inject=[dict(type="head_pref", side="R", base_deg=45)]),
         age=8, expect={"posture.head_preference": "detected"},
         check=lambda rep: _f(rep, "posture.head_preference")["direction"] == "R"),
    dict(name="atnr_30w", sim=dict(fs=30, seed=11, inject=[dict(type="atnr", side="L", t0=10, t1=80)]),
         age=30, expect={"posture.atnr_like_persistent": "detected"}),
    dict(name="atnr_8w_expected", sim=dict(fs=30, seed=11, inject=[dict(type="atnr", side="L", t0=10, t1=80)]),
         age=8, expect={"posture.atnr_like_persistent": "expected_for_age"}),
    dict(name="frog_leg", sim=dict(fs=30, seed=12, inject=[dict(type="frog_leg")]),
         age=10, expect={"posture.frog_leg": "detected"}),
    dict(name="asym_left_arm_20w", sim=dict(fs=30, seed=13, inject=[dict(type="asym_arm", side="L", factor=0.25)]),
         age=20, expect={"asym.arm_use": "detected"},
         check=lambda rep: _f(rep, "asym.arm_use")["direction"] == "L"),
    dict(name="scissoring_16w", sim=dict(fs=30, seed=14, inject=[dict(type="scissor", starts=[10, 30, 50, 70], dur=4.0)]),
         age=16, expect={"posture.scissoring": "detected"}),
    dict(name="hands_midline_30w", sim=dict(fs=30, seed=15, duration=150, inject=[
        dict(type="hands_midline", starts=list(range(10, 140, 15)), dur=2.0)]),
         age=30, expect={"milestone.hands_together_absent": "not_detected", "burst.spasm_like_cluster": "not_detected"}),
    dict(name="no_hands_midline_30w", sim=dict(fs=30, seed=16, duration=150), age=30,
         expect={"milestone.hands_together_absent": "detected"}),
    dict(name="held_context", sim=dict(fs=30, seed=17), age=12, context="held",
         expect={"rhythm.fast_fine": "abstained", "posture.head_preference": "abstained"}),
]


def _f(rep, rid):
    return next(f for f in rep["findings"] if f["rule_id"] == rid)


def _event(rep, rid):
    return _f(rep, rid)["events"][0]


def run_scenario(sc):
    arc = simulate(**sc["sim"])
    rep = ENGINE.analyze(arc, age_weeks=sc.get("age"), context=sc.get("context", "supine"), session_id=sc["name"])
    fails = []
    for rid, want in sc["expect"].items():
        got = _f(rep, rid)["status"]
        if got != want:
            fails.append(f"{rid}: want {want}, got {got}")
    if not fails and "check" in sc:
        try:
            if not sc["check"](rep):
                fails.append("extra check failed")
        except Exception as e:  # noqa: BLE001
            fails.append(f"extra check error: {e}")
    return rep, fails


def test_all_scenarios():
    bad = {}
    for sc in SCENARIOS:
        _, fails = run_scenario(sc)
        if fails:
            bad[sc["name"]] = fails
    assert not bad, bad


def test_longitudinal_head_preference():
    reps = []
    for i, day in enumerate(["2026-10-01", "2026-10-05", "2026-10-11"]):
        arc = simulate(fs=30, seed=40 + i, inject=[dict(type="head_pref", side="R", base_deg=45)])
        reps.append(ENGINE.analyze(arc, age_weeks=8, session_date=day))
    lg = {r["rule_id"]: r for r in longitudinal(reps, ENGINE.rules)}
    assert lg["posture.head_preference"]["status"] == "persistent"
    assert lg["posture.head_preference"]["direction"] == "R"


def baseline_false_positive_sweep(n=12, fs=30):
    hits = {r: 0 for r in FLAGGED}
    for s in range(n):
        rep = ENGINE.analyze(simulate(fs=fs, seed=100 + s), age_weeks=20)
        for r in FLAGGED:
            if _f(rep, r)["status"] == "detected":
                hits[r] += 1
    return hits


def aliasing_demo():
    """11 Hz one-sided tremor filmed at 30 fps, analysed at 30 fps vs. every 2nd frame (15 fps, no anti-alias)."""
    from scipy.signal import butter, sosfiltfilt
    out = {}
    for dec in (1, 2):
        arc = simulate(fs=30, seed=21, decimate=dec, inject=[
            dict(type="tremor", limbs=["L_arm"], f=11.0, amp_p2p=0.06, t0=20, t1=60), dict(type="quiet", t0=20, t1=60)])
        ps = load_archive(arc)
        bf = build_body_frame(ps)
        m = (ps.t >= 25) & (ps.t < 55)
        x = bf.B[m, 7 + 4, :]  # leftWrist
        x = x - np.nanmean(x, 0)
        x = np.nan_to_num(x)
        sos = butter(4, 2.5 / (ps.fs / 2), btype="high", output="sos")
        x = sosfiltfilt(sos, x, axis=0)
        f = np.fft.rfftfreq(len(x), 1 / ps.fs)
        P = (np.abs(np.fft.rfft(x * np.hanning(len(x))[:, None], axis=0)) ** 2).sum(1)
        sel = f >= 2.5
        out[f"{ps.fs:.0f}fps"] = round(float(f[sel][np.argmax(P[sel])]), 2)
    return out


if __name__ == "__main__":
    total_fail = 0
    for sc in SCENARIOS:
        rep, fails = run_scenario(sc)
        flag = "PASS" if not fails else "FAIL"
        total_fail += bool(fails)
        det = [f"{f['rule_id']}({f['status']})" for f in rep["findings"] if f["status"] in ("detected", "expected_for_age")]
        print(f"{flag:4} {sc['name']:28} detected={det} {fails if fails else ''}")
    try:
        test_longitudinal_head_preference()
        print("PASS longitudinal_head_preference")
    except AssertionError as e:
        total_fail += 1
        print("FAIL longitudinal_head_preference", e)
    print("baseline FP sweep (12 seeds, 30 fps, 20 w):", baseline_false_positive_sweep())
    print("aliasing demo:", aliasing_demo())
    print("FAILED SCENARIOS:", total_fail)
