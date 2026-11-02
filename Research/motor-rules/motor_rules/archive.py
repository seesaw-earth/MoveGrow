# MoveGrow motor-rules prototype — Copyright (C) 2026 Ziqing Shi
# SPDX-License-Identifier: AGPL-3.0-only
"""Load MoveGrow PoseArchive JSON (schemaVersion 2, optional v3 fields) into arrays.

Archive layout (see MoveGrow/Models/PoseArchive.swift):
    {"schemaVersion": 2, "durationSeconds": .., "nominalSampleIntervalSeconds": ..,
     "coordinateSystem": "normalized-top-left", "jointNames": [...],
     "frames": [{"time": t, "points": {name: {"x","y","confidence"}}, "lightOK": bool,
                 "subjectBox": {"x","y","width","height","confidence"} | null}]}

Optional fields proposed for schema v3 (used when present):
    "aspectRatio" (display width / height), "captureFrameRate",
    per-frame "personCount", per-frame "gyroRMS" (rad/s, from CoreMotion).
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field

import numpy as np

JOINTS = [
    "nose", "leftEye", "rightEye", "leftEar", "rightEar", "neck", "root",
    "leftShoulder", "rightShoulder", "leftElbow", "rightElbow", "leftWrist", "rightWrist",
    "leftHip", "rightHip", "leftKnee", "rightKnee", "leftAnkle", "rightAnkle",
]
J = {name: i for i, name in enumerate(JOINTS)}

DEFAULT_PORTRAIT_ASPECT = 9.0 / 16.0  # RecordView records 9:16 portrait


@dataclass
class PoseSeries:
    t: np.ndarray            # (T,) seconds, uniform grid after resampling
    xy: np.ndarray           # (T, J, 2) normalized image coords; NaN where invalid
    conf: np.ndarray         # (T, J) confidence (0 where invalid)
    light_ok: np.ndarray     # (T,) bool
    fs: float                # sampling rate of the uniform grid (Hz)
    aspect: float            # display width / height
    meta: dict = field(default_factory=dict)

    @property
    def T(self) -> int:
        return len(self.t)

    @property
    def duration(self) -> float:
        return float(self.t[-1] - self.t[0]) if self.T > 1 else 0.0


def _interp_with_gaps(t_src, y_src, t_dst, max_gap):
    """Linear interpolation that leaves NaN across source gaps longer than max_gap."""
    ok = np.isfinite(y_src)
    out = np.full(t_dst.shape, np.nan)
    if ok.sum() < 2:
        return out
    ts, ys = t_src[ok], y_src[ok]
    out = np.interp(t_dst, ts, ys, left=np.nan, right=np.nan)
    i = np.clip(np.searchsorted(ts, t_dst, side="left"), 1, len(ts) - 1)
    exact = np.abs(ts[i] - t_dst) < 1e-6
    gap = ts[i] - ts[i - 1]
    out[(gap > max_gap) & ~exact] = np.nan
    return out


def load_archive(path_or_dict, aspect: float | None = None, conf_floor: float = 0.30,
                 max_gap_s: float = 0.12) -> PoseSeries:
    data = path_or_dict
    if not isinstance(data, dict):
        if str(path_or_dict).endswith(".mgpose"):
            from .mgpose import read_mgpose
            data = read_mgpose(path_or_dict)
        else:
            with open(path_or_dict, "r", encoding="utf-8") as fh:
                data = json.load(fh)
    frames = data.get("frames", [])
    if len(frames) < 3:
        raise ValueError("archive has fewer than 3 frames")
    t_src = np.array([float(f["time"]) for f in frames])
    order = np.argsort(t_src)
    t_src = t_src[order]
    frames = [frames[i] for i in order]

    T0, NJ = len(frames), len(JOINTS)
    xy_src = np.full((T0, NJ, 2), np.nan)
    cf_src = np.zeros((T0, NJ))
    light = np.ones(T0, dtype=bool)
    for k, fr in enumerate(frames):
        light[k] = bool(fr.get("lightOK", True))
        for name, p in (fr.get("points") or {}).items():
            j = J.get(name)
            if j is None:
                continue
            c = float(p.get("confidence", 0.0))
            cf_src[k, j] = c
            if c >= conf_floor and 0.0 <= p["x"] <= 1.0 and 0.0 <= p["y"] <= 1.0:
                xy_src[k, j] = (float(p["x"]), float(p["y"]))

    dt = np.diff(t_src)
    dt = dt[(dt > 0) & np.isfinite(dt)]
    fs = 1.0 / float(np.median(dt))
    dt_cv = float(np.std(dt) / np.mean(dt)) if len(dt) else 0.0
    t = np.arange(t_src[0], t_src[-1] + 1e-9, 1.0 / fs)

    xy = np.full((len(t), NJ, 2), np.nan)
    conf = np.zeros((len(t), NJ))
    for j in range(NJ):
        for d in range(2):
            xy[:, j, d] = _interp_with_gaps(t_src, xy_src[:, j, d], t, max_gap_s)
        conf[:, j] = np.interp(t, t_src, cf_src[:, j])
    conf[~np.isfinite(xy[..., 0])] = 0.0
    light_u = np.interp(t, t_src, light.astype(float)) > 0.5

    if aspect is None:
        aspect = data.get("aspectRatio")
    aspect_assumed = aspect is None
    if aspect is None:
        aspect = DEFAULT_PORTRAIT_ASPECT

    meta = {
        "schemaVersion": data.get("schemaVersion"),
        "poseEstimator": data.get("poseEstimator"),
        "processing": data.get("processing"),
        "source_fps": fs,
        "dt_cv": dt_cv,
        "aspect_assumed": aspect_assumed,
        "captureFrameRate": data.get("captureFrameRate"),
    }
    return PoseSeries(t=t, xy=xy, conf=conf, light_ok=light_u, fs=fs, aspect=float(aspect), meta=meta)
