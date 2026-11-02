# MoveGrow motor-rules prototype — Copyright (C) 2026 Ziqing Shi
# SPDX-License-Identifier: AGPL-3.0-only
"""Write deterministic parity fixtures for the Swift engine (Tests/MotorKitTests/Fixtures).

Each scenario -> <name>.mgpose (the app's binary pose format) + <name>.expected.json. The expected
values come from analysing the data AS READ BACK from the .mgpose file (float32), so the Swift and
Python engines see byte-identical input.

  python3 tools/make_fixtures.py [out_dir]
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
from motor_rules.mgpose import read_mgpose, write_mgpose  # noqa: E402
from motor_rules.synth import simulate  # noqa: E402
from test_scenarios import ENGINE, SCENARIOS  # noqa: E402

PICK = ["baseline_30fps", "baseline_60fps_20w", "tremor_bilateral_8hz_30fps", "tremor_8hz_at_15fps",
        "camera_shake_8hz", "coarse_5hz_left_arm", "clonic_left_arm_2hz", "rhythmic_kicking_bilateral",
        "spasm_like_cluster", "head_pref_right", "atnr_30w", "frog_leg", "asym_left_arm_20w",
        "scissoring_16w", "no_hands_midline_30w", "held_context"]
METRIC_KEYS = ("observed_s", "true_s", "n_episodes", "fraction", "pref_index", "median",
               "arm_asym_index", "largest_cluster", "surrogate_p", "denominator_s")


def expected_for(rep, sc):
    exp = {"age_weeks": sc.get("age"), "context": sc.get("context", "supine"),
           "fs": rep["context"]["fs"], "rules": {}}
    for f in rep["findings"]:
        m = f.get("metrics") or {}
        row = {"status": f["status"], "severity": f["severity"]}
        for k in METRIC_KEYS:
            if k in m and m[k] is not None:
                row[k] = m[k]
        ev = f.get("events") or []
        if f.get("family") == "rhythm" and f["status"] in ("detected", "not_detected"):
            row["n_events"] = len(ev)
            if ev:
                row["first_hz"] = ev[0]["hz"]
                row["first_limbs"] = ev[0]["limbs"]
        if f.get("direction"):
            row["direction"] = f["direction"]
        exp["rules"][f["rule_id"]] = row
    return exp


def main(out_dir):
    os.makedirs(out_dir, exist_ok=True)
    for sc in SCENARIOS:
        if sc["name"] not in PICK:
            continue
        path = os.path.join(out_dir, f"{sc['name']}.mgpose")
        write_mgpose(path, simulate(**sc["sim"]))
        rep = ENGINE.analyze(read_mgpose(path), age_weeks=sc.get("age"), context=sc.get("context", "supine"))
        with open(os.path.join(out_dir, f"{sc['name']}.expected.json"), "w") as fh:
            json.dump(expected_for(rep, sc), fh, indent=1, sort_keys=True)
        print("wrote", sc["name"], os.path.getsize(path) // 1024, "KB")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "..", "..", "Tests", "MotorKitTests", "Fixtures"))
