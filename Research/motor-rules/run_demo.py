# MoveGrow motor-rules prototype — Copyright (C) 2026 Ziqing Shi
# SPDX-License-Identifier: AGPL-3.0-only
"""CLI.

  python3 run_demo.py path/to/<id>.poses.raw.json --age-weeks 12 [--context supine] [--out report.json]
  python3 run_demo.py --synthetic clonic_left_arm_2hz        # any scenario name from tests/test_scenarios.py
  python3 run_demo.py --list

Use the RAW export (<id>.poses.raw.json) so the high-frequency rules see unsmoothed keypoints.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import warnings

warnings.filterwarnings("ignore")
ROOT = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, ROOT)
sys.path.insert(0, os.path.join(ROOT, "tests"))

from motor_rules.engine import MotorEngine, render_text  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("archive", nargs="?")
    ap.add_argument("--age-weeks", type=float, default=None, help="(corrected) age in weeks")
    ap.add_argument("--context", default="supine", choices=["supine", "prone", "held", "sitting", "other"])
    ap.add_argument("--torso-cm", type=float, default=20.0)
    ap.add_argument("--synthetic", default=None)
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--out", default=None)
    ap.add_argument("--lang", default="zh", choices=["zh", "en"])
    a = ap.parse_args()
    if a.list or a.synthetic:
        from test_scenarios import SCENARIOS
        from motor_rules.synth import simulate
        if a.list:
            print("\n".join(s["name"] for s in SCENARIOS))
            return
        sc = next(s for s in SCENARIOS if s["name"] == a.synthetic)
        archive, age, ctx, sid = simulate(**sc["sim"]), sc.get("age"), sc.get("context", "supine"), sc["name"]
    else:
        if not a.archive:
            ap.error("archive path or --synthetic required")
        archive, age, ctx, sid = a.archive, a.age_weeks, a.context, os.path.basename(a.archive)
    eng = MotorEngine()
    rep = eng.analyze(archive, age_weeks=age if a.age_weeks is None else a.age_weeks, context=ctx,
                      torso_cm=a.torso_cm, session_id=sid)
    print(render_text(rep, a.lang))
    if a.out:
        with open(a.out, "w", encoding="utf-8") as fh:
            json.dump(rep, fh, ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
