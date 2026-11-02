# MoveGrow motor-rules prototype — Copyright (C) 2026 Ziqing Shi
# SPDX-License-Identifier: AGPL-3.0-only
"""Static checks for rules.json (run in CI and on every LLM-compiled rule before human review).

Checks: unique ids; required fields per analysis type; every predicate feature exists in the
feature catalog for that level; every $param exists and declares value/unit/origin; literature
params cite a known source; rule sources exist; message placeholders are known; 'safety' rules
carry follow-up guidance; no finger/fisting features (not observable with COCO-17).
"""
from __future__ import annotations

import json
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
sys.path.insert(0, ROOT)
from motor_rules import dsl  # noqa: E402

ANALYSES = {"spectral", "posture", "posture_side", "posture_stat", "activity", "burst", "none"}
STATUSES = {"enabled", "research", "abstain_always", "disabled"}
SEVERITIES = {"info", "note", "discuss", "safety"}
ORIGINS = {"literature", "engineering_prior"}


def validate(rules_path, sources_path, catalog_path) -> list[str]:
    spec = json.load(open(rules_path, encoding="utf-8"))
    sources = json.load(open(sources_path, encoding="utf-8"))["sources"]
    cat = json.load(open(catalog_path, encoding="utf-8"))
    win = set(cat["levels"]["window"]["features"])
    frame = set(cat["levels"]["frame"]["features"])
    sess = {k: set(v) for k, v in cat["levels"]["session"].items()}
    ph = cat["message_placeholders"]
    errs: list[str] = []
    seen = set()
    for r in spec["rules"]:
        rid = r.get("id", "?")
        E = lambda m: errs.append(f"{rid}: {m}")  # noqa: E731
        if rid in seen:
            E("duplicate id")
        seen.add(rid)
        for k in ("id", "version", "status", "analysis", "name", "sources"):
            if k not in r:
                E(f"missing '{k}'")
        if r.get("status") not in STATUSES:
            E(f"bad status {r.get('status')}")
        a = r.get("analysis")
        if a not in ANALYSES:
            E(f"bad analysis {a}")
            continue
        for s in r.get("sources", []):
            if s not in sources:
                E(f"unknown source {s}")
        if r.get("status") == "abstain_always" or a == "none":
            if "abstain_reason" not in r:
                E("abstain_always needs abstain_reason")
            continue
        if r.get("severity") not in SEVERITIES:
            E(f"bad severity {r.get('severity')}")
        if r.get("severity") == "safety" and not r.get("followup"):
            E("safety rule needs followup guidance")
        P = r.get("params", {})
        for name, p in P.items():
            for k in ("value", "unit", "origin"):
                if k not in p:
                    E(f"param {name} missing {k}")
            if p.get("origin") not in ORIGINS:
                E(f"param {name} bad origin {p.get('origin')}")
            if p.get("origin") == "literature" and p.get("source") not in sources:
                E(f"param {name} is 'literature' but cites no known source")
        preds = []
        if a == "spectral":
            preds.append(("window_predicate", win))
            if r.get("band") not in ("fast", "slow"):
                E("spectral rule needs band fast|slow")
        elif a == "posture":
            preds.append(("frame_predicate", frame))
            if "denominator_predicate" in r:
                preds.append(("denominator_predicate", frame))
            preds.append(("session_predicate", sess["posture"]))
        elif a == "posture_side":
            if r.get("side_signal", {}).get("f") not in frame:
                E("side_signal feature not in catalog")
            preds.append(("session_predicate", sess["posture_side"]))
        elif a == "posture_stat":
            if r.get("stat_signal", {}).get("f") not in frame:
                E("stat_signal feature not in catalog")
            preds.append(("session_predicate", sess["posture_stat"]))
        elif a == "activity":
            preds.append(("session_predicate", sess["activity"]))
        elif a == "burst":
            preds.append(("session_predicate", sess["burst"]))
            for k in ("abs_speed", "rel_speed", "sync_tol_s", "min_limbs", "min_dur_s", "max_dur_s",
                      "pre_quiet_ratio", "min_interval_s", "max_interval_s"):
                if k not in P:
                    E(f"burst rule missing param {k}")
        for key, allowed in preds:
            pr = r.get(key)
            if pr is None:
                E(f"missing {key}")
                continue
            for f in dsl.features_used(pr):
                if f not in allowed:
                    E(f"{key}: feature '{f}' not in catalog for this level")
                if re.search(r"finger|fist|thumb", f):
                    E(f"{key}: '{f}' is not observable with COCO-17")
            for pname in dsl.params_used(pr):
                if pname not in P:
                    E(f"{key}: references undefined param ${pname}")
        allowed_ph = set(ph.get(a, []))
        for lang, tpl in (r.get("message") or {}).items():
            for name in re.findall(r"{(\w+)(?::[^}]*)?}", tpl or ""):
                if name not in allowed_ph:
                    E(f"message[{lang}] uses unknown placeholder '{name}'")
        ag = r.get("age_weeks")
        if ag and ag.get("source") and ag["source"] not in sources:
            E("age_weeks cites unknown source")
    return errs


if __name__ == "__main__":
    app = os.path.join(ROOT, "..", "..", "MoveGrow", "Motor", "Resources")
    rp = sys.argv[1] if len(sys.argv) > 1 else os.path.join(app, "rules.json")
    errs = validate(rp, os.path.join(app, "sources.json"), os.path.join(ROOT, "rules", "feature_catalog.json"))
    if errs:
        print("\n".join(errs))
        sys.exit(1)
    print(f"OK: {rp}")
