# MoveGrow motor-rules prototype — Copyright (C) 2026 Ziqing Shi
# SPDX-License-Identifier: AGPL-3.0-only
"""Multi-seed observability sweep on synthetic data (NOT clinical accuracy).

1. per-scenario hit rate across seeds and keypoint-jitter levels
2. baseline false-positive rate per rule
3. fine-tremor detection limit vs amplitude, frame rate and jitter
"""
from __future__ import annotations

import json
import os
import sys
import warnings

warnings.filterwarnings("ignore")
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
sys.path.insert(0, ROOT)
sys.path.insert(0, os.path.join(ROOT, "tests"))

from motor_rules.synth import simulate  # noqa: E402
from test_scenarios import ENGINE, FLAGGED, SCENARIOS, _f  # noqa: E402

POSITIVE = {  # scenario -> rule that should fire
    "tremor_bilateral_8hz_30fps": "rhythm.fast_fine", "coarse_5hz_left_arm": "rhythm.coarse",
    "clonic_left_arm_2hz": "rhythm.slow_unilateral_sustained", "rhythmic_kicking_bilateral": "rhythm.slow_bout",
    "spasm_like_cluster": "burst.spasm_like_cluster", "head_pref_right": "posture.head_preference",
    "atnr_30w": "posture.atnr_like_persistent", "frog_leg": "posture.frog_leg",
    "asym_left_arm_20w": "asym.arm_use", "scissoring_16w": "posture.scissoring",
}
JITTERS = [0.0025, 0.005]


def main(n_seeds=8, n_fp=24):
    out = {"hit_rate": {}, "fp_rate": {}, "tremor_limit": []}
    by_name = {s["name"]: s for s in SCENARIOS}
    for name, rid in POSITIVE.items():
        sc = by_name[name]
        for jit in JITTERS:
            hits = 0
            for k in range(n_seeds):
                sim = dict(sc["sim"], seed=1000 + 17 * k, jitter=jit)
                rep = ENGINE.analyze(simulate(**sim), age_weeks=sc["age"])
                hits += _f(rep, rid)["status"] == "detected"
            out["hit_rate"][f"{name}|jitter={jit}"] = hits / n_seeds
            print(f"{name:30} {rid:36} jitter={jit:<7} hit={hits}/{n_seeds}", flush=True)
    for fs in (30, 60):
        for jit in JITTERS:
            hits = {r: 0 for r in FLAGGED}
            for k in range(n_fp):
                rep = ENGINE.analyze(simulate(fs=fs, seed=5000 + k, jitter=jit), age_weeks=40)
                for r in FLAGGED:
                    hits[r] += _f(rep, r)["status"] == "detected"
            out["fp_rate"][f"fs={fs}|jitter={jit}"] = {r: h / n_fp for r, h in hits.items()}
            print(f"baseline fs={fs} jitter={jit}: {hits} / {n_fp}", flush=True)
    for fs in (30, 60):
        for jit in JITTERS:
            for amp in (0.008, 0.012, 0.02, 0.03, 0.05):
                hits = 0
                for k in range(6):
                    arc = simulate(fs=fs, seed=7000 + k, jitter=jit, inject=[
                        dict(type="tremor", limbs=["L_arm", "R_arm"], f=8.0, amp_p2p=amp, t0=20, t1=40)])
                    rep = ENGINE.analyze(arc, age_weeks=2)
                    hits += _f(rep, "rhythm.fast_fine")["status"] == "detected"
                row = dict(fs=fs, jitter=jit, amp_p2p_torso=amp, amp_p2p_cm_at_20cm_torso=amp * 20, hit_rate=hits / 6)
                out["tremor_limit"].append(row)
                print("tremor", row, flush=True)
    os.makedirs(os.path.join(ROOT, "out"), exist_ok=True)
    with open(os.path.join(ROOT, "out", "sweep.json"), "w") as fh:
        json.dump(out, fh, indent=1)


if __name__ == "__main__":
    main()
