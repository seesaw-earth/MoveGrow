# MoveGrow motor-rules prototype — Copyright (C) 2026 Ziqing Shi
# SPDX-License-Identifier: AGPL-3.0-only
"""Per-frame posture descriptors in the anatomical body frame (feature catalog: posture.*).

All lengths are in torso units; angles in degrees. Sign conventions:
    head_yaw_sin   > 0  face turned toward the baby's LEFT  (sin of yaw, ~ -1..1)
    head_tilt_deg  > 0  head tilted toward the baby's RIGHT shoulder (eye line vs shoulder line)
    thigh_abd_*    > 0  thigh points laterally (abduction) relative to the caudal torso axis
    ankle_cross    < 0  left ankle is to the right of the right ankle (legs crossed)
"""
from __future__ import annotations

import numpy as np

from .archive import J
from .bodyframe import BodyFrame, joint_angle


def _pt(bf: BodyFrame, name: str) -> np.ndarray:
    return bf.B[:, J[name]]


def posture_features(bf: BodyFrame, head_r_prior: float = 0.30) -> dict[str, np.ndarray]:
    f: dict[str, np.ndarray] = {}
    nose = _pt(bf, "nose")
    le, re = _pt(bf, "leftEye"), _pt(bf, "rightEye")
    lear, rear = _pt(bf, "leftEar"), _pt(bf, "rightEar")
    ls, rs = _pt(bf, "leftShoulder"), _pt(bf, "rightShoulder")
    msh = 0.5 * (ls + rs)

    both_ears = np.isfinite(lear[:, 0]) & np.isfinite(rear[:, 0])
    ear_mid = 0.5 * (lear + rear)
    center_u = np.where(both_ears, ear_mid[:, 0], msh[:, 0])
    spread = 0.5 * np.abs(lear[:, 0] - rear[:, 0])
    if both_ears.sum() >= 30:
        head_r = float(np.nanpercentile(spread[both_ears], 90))
        head_r = head_r if 0.12 < head_r < 0.6 else head_r_prior
    else:
        head_r = head_r_prior
    f["head_yaw_sin"] = np.clip((nose[:, 0] - center_u) / head_r, -1.2, 1.2)
    f["head_center_from_ears"] = both_ears.astype(float)

    eye_vec = le - re
    sh_vec = ls - rs
    a_eye = np.degrees(np.arctan2(eye_vec[:, 1], eye_vec[:, 0]))
    a_sh = np.degrees(np.arctan2(sh_vec[:, 1], sh_vec[:, 0]))
    tilt = (a_eye - a_sh + 180.0) % 360.0 - 180.0
    tilt[np.abs(f["head_yaw_sin"]) > 0.5] = np.nan  # eye line unreliable when face is turned
    f["head_tilt_deg"] = tilt

    for side, s in (("left", "L"), ("right", "R")):
        sh, el, wr = _pt(bf, f"{side}Shoulder"), _pt(bf, f"{side}Elbow"), _pt(bf, f"{side}Wrist")
        hp, kn, an = _pt(bf, f"{side}Hip"), _pt(bf, f"{side}Knee"), _pt(bf, f"{side}Ankle")
        f[f"elbow_angle_{s}"] = joint_angle(sh, el, wr)
        f[f"knee_angle_{s}"] = joint_angle(hp, kn, an)
        thigh = kn - hp
        lat = thigh[:, 0] if s == "L" else -thigh[:, 0]
        f[f"thigh_abd_{s}"] = np.degrees(np.arctan2(lat, -thigh[:, 1]))
        tl = np.linalg.norm(thigh, axis=1)
        ref = np.nanpercentile(tl, 90) if np.isfinite(tl).sum() > 10 else np.nan
        f[f"thigh_flat_{s}"] = tl / ref
    hipw = _pt(bf, "leftHip")[:, 0] - _pt(bf, "rightHip")[:, 0]
    hipw = np.where(np.abs(hipw) > 0.05, hipw, np.nan)
    f["knee_spread"] = (_pt(bf, "leftKnee")[:, 0] - _pt(bf, "rightKnee")[:, 0]) / hipw
    f["ankle_cross"] = _pt(bf, "leftAnkle")[:, 0] - _pt(bf, "rightAnkle")[:, 0]

    lw, rw = _pt(bf, "leftWrist"), _pt(bf, "rightWrist")
    f["hands_dist"] = np.linalg.norm(lw - rw, axis=1)
    f["hands_mid_u"] = np.maximum(np.abs(lw[:, 0]), np.abs(rw[:, 0]))

    # side-resolved helpers for the ATNR-like pattern (face side vs occiput side)
    yaw = f["head_yaw_sin"]
    face_left = yaw > 0
    f["face_side_elbow"] = np.where(face_left, f["elbow_angle_L"], f["elbow_angle_R"])
    f["occiput_side_elbow"] = np.where(face_left, f["elbow_angle_R"], f["elbow_angle_L"])
    f["abs_head_yaw_sin"] = np.abs(yaw)
    # np.minimum/np.maximum propagate NaN: "both sides" predicates need both sides observed
    f["min_thigh_abd"] = np.minimum(f["thigh_abd_L"], f["thigh_abd_R"])
    f["min_thigh_flat"] = np.minimum(f["thigh_flat_L"], f["thigh_flat_R"])
    f["min_knee_angle"] = np.minimum(f["knee_angle_L"], f["knee_angle_R"])
    f["max_knee_angle"] = np.maximum(f["knee_angle_L"], f["knee_angle_R"])
    f["_head_r"] = np.full(len(yaw), head_r)
    return f
