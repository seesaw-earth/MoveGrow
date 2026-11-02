# MoveGrow motor-rules prototype — Copyright (C) 2026 Ziqing Shi
# SPDX-License-Identifier: AGPL-3.0-only
"""Tiny predicate language shared by rules.json, the Python engine and (later) Swift.

Grammar (JSON):
    pred  := {"all": [pred, ...]} | {"any": [pred, ...]} | {"not": pred} | leaf
    leaf  := {"f": <feature name>, "op": <op>, "v": <value | "$param" | [lo, hi]>}
    op    := ">" | ">=" | "<" | "<=" | "==" | "between" | "outside" | "abs>=" | "abs<="
Values of the form "$name" are looked up in the rule's params (params[name]["value"]).
A leaf on a NaN feature is False (unknown is never evidence). Works on scalars or numpy arrays.
"""
from __future__ import annotations

import numpy as np

OPS = {">", ">=", "<", "<=", "==", "between", "outside", "abs>=", "abs<="}


def resolve(v, params: dict):
    if isinstance(v, str) and v.startswith("$"):
        return params[v[1:]]["value"]
    if isinstance(v, list):
        return [resolve(x, params) for x in v]
    return v


def features_used(pred: dict) -> set[str]:
    if "all" in pred or "any" in pred:
        return set().union(*(features_used(p) for p in pred.get("all", pred.get("any", []))))
    if "not" in pred:
        return features_used(pred["not"])
    return {pred["f"]}


def params_used(pred: dict) -> set[str]:
    if "all" in pred or "any" in pred:
        return set().union(*(params_used(p) for p in pred.get("all", pred.get("any", []))))
    if "not" in pred:
        return params_used(pred["not"])
    vals = pred["v"] if isinstance(pred["v"], list) else [pred["v"]]
    return {v[1:] for v in vals if isinstance(v, str) and v.startswith("$")}


def evaluate(pred: dict, feats: dict, params: dict):
    if "all" in pred:
        parts = [evaluate(p, feats, params) for p in pred["all"]]
        return np.logical_and.reduce(parts) if parts else True
    if "any" in pred:
        parts = [evaluate(p, feats, params) for p in pred["any"]]
        return np.logical_or.reduce(parts) if parts else False
    if "not" in pred:
        inner = pred["not"]
        val = evaluate(inner, feats, params)
        known = valid_mask(inner, feats)
        return np.logical_and(np.logical_not(val), known)
    x = feats[pred["f"]]
    x = np.asarray(x, dtype=float)
    v = resolve(pred["v"], params)
    op = pred["op"]
    with np.errstate(invalid="ignore"):
        if op == ">":
            r = x > v
        elif op == ">=":
            r = x >= v
        elif op == "<":
            r = x < v
        elif op == "<=":
            r = x <= v
        elif op == "==":
            r = x == v
        elif op == "between":
            r = (x >= v[0]) & (x <= v[1])
        elif op == "outside":
            r = (x < v[0]) | (x > v[1])
        elif op == "abs>=":
            r = np.abs(x) >= v
        elif op == "abs<=":
            r = np.abs(x) <= v
        else:
            raise ValueError(f"unknown op {op}")
    return r & np.isfinite(x)


def valid_mask(pred: dict, feats: dict):
    """True where every feature referenced by pred is finite."""
    names = features_used(pred)
    m = None
    for n in names:
        fin = np.isfinite(np.asarray(feats[n], dtype=float))
        m = fin if m is None else (m & fin)
    return m if m is not None else True
