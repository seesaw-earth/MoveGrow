# MoveGrow motor-rules prototype — Copyright (C) 2026 Ziqing Shi
# SPDX-License-Identifier: AGPL-3.0-only
"""Synthetic supine-infant pose generator that writes MoveGrow PoseArchive JSON.

Purpose: unit tests and observability checks for rules ("if the described pattern were present,
would the rule see it, and does the baseline stay quiet?"). It is NOT evidence of clinical
accuracy: the patterns are injected from the same text the rules were compiled from.

Body model (torso units, origin mid-hip, u = baby's left, v = cranial), 2D kinematics with
foreshortening for out-of-plane hip/shoulder lift. Spontaneous movement = smoothed noise on joint
angles gated by an on/off activity envelope. Injections modify angles or positions.
"""
from __future__ import annotations

import numpy as np
from scipy.signal import butter, sosfiltfilt

from .archive import JOINTS

SH = {1: np.array([0.42, 1.0]), -1: np.array([-0.42, 1.0])}
HP = {1: np.array([0.28, 0.0]), -1: np.array([-0.28, 0.0])}
UPPER, FORE, THIGH, SHANK = 0.42, 0.40, 0.48, 0.44
HEAD_C, NECK_P, HEAD_R = np.array([0.0, 1.38]), np.array([0.0, 1.05]), 0.30

BASE = dict(alpha=75.0, beta=80.0, lift=20.0, gamma=25.0, kappa=80.0, phi=35.0)
AMP = dict(alpha=22.0, beta=28.0, lift=15.0, gamma=10.0, kappa=28.0, phi=18.0)
SIDES = {"L": 1, "R": -1}
LIMB_DOF = {"arm": ("alpha", "beta", "lift"), "leg": ("gamma", "kappa", "phi")}


def _rot(v: np.ndarray, deg: np.ndarray) -> np.ndarray:
    a = np.radians(deg)
    c, s = np.cos(a), np.sin(a)
    return np.stack([c * v[..., 0] - s * v[..., 1], s * v[..., 0] + c * v[..., 1]], -1)


def _smooth_noise(rng, T, fs, fc):
    sos = butter(2, min(fc / (0.5 * fs), 0.99), output="sos")
    x = sosfiltfilt(sos, rng.standard_normal(T + 200))[100:-100]
    return x / (np.std(x) + 1e-9)


def _envelope(rng, T, fs, on=3.0, off=2.0, floor=0.12):
    env = np.zeros(T)
    i, state = 0, rng.random() < 0.6
    while i < T:
        n = max(1, int(rng.exponential(on if state else off) * fs))
        env[i:i + n] = 1.0 if state else floor
        i += n
        state = not state
    k = np.hanning(max(3, int(0.6 * fs)))
    return np.convolve(env, k / k.sum(), mode="same")


def _bump(t, t0, rise=0.15, hold=0.4, fall=0.45):
    """Fast rise, short hold, slower decay (0..1)."""
    y = np.zeros_like(t)
    a = (t >= t0) & (t < t0 + rise)
    y[a] = 0.5 - 0.5 * np.cos(np.pi * (t[a] - t0) / rise)
    b = (t >= t0 + rise) & (t < t0 + rise + hold)
    y[b] = 1.0
    c = (t >= t0 + rise + hold) & (t < t0 + rise + hold + fall)
    y[c] = 0.5 + 0.5 * np.cos(np.pi * (t[c] - t0 - rise - hold) / fall)
    return y


def simulate(duration=90.0, fs=30.0, seed=0, aspect=9 / 16, jitter=0.0025, dropout=0.01,
             activity=1.0, inject=(), body_rot_deg=8.0, scale=0.20, decimate=1) -> dict:
    rng = np.random.default_rng(seed)
    T = int(round(duration * fs))
    t = np.arange(T) / fs
    dof = {}
    for side in SIDES:
        for limb, names in LIMB_DOF.items():
            env = _envelope(rng, T, fs)
            for n in names:
                dof[(side, n)] = BASE[n] + activity * AMP[n] * _smooth_noise(rng, T, fs, 1.2) * env
    henv = _envelope(rng, T, fs, on=4, off=3, floor=0.3)
    psi = 30.0 * _smooth_noise(rng, T, fs, 0.4) * henv
    tau = 4.0 * _smooth_noise(rng, T, fs, 0.3)
    pos_overrides = []  # callables applied after FK: f(B, t) -> None
    img_ops = []

    def win(spec):
        t0, t1 = spec.get("t0", 0.0), spec.get("t1", duration)
        return (t >= t0) & (t < t1), t0, t1

    def scale_activity(mask, limbs, factor):
        for side in SIDES:
            for limb, names in LIMB_DOF.items():
                if f"{side}_{limb}" in limbs:
                    for n in names:
                        x = dof[(side, n)]
                        x[mask] = BASE[n] + (x[mask] - BASE[n]) * factor

    all_limbs = ["L_arm", "R_arm", "L_leg", "R_leg"]
    for spec in inject:
        typ = spec["type"]
        m, t0, t1 = win(spec)
        if typ == "quiet":
            scale_activity(m, spec.get("limbs", all_limbs), spec.get("factor", 0.2))
        elif typ == "asym_arm":
            scale_activity(m, [f"{spec['side']}_arm"], spec.get("factor", 0.3))
        elif typ == "head_pref":
            s = 1 if spec["side"] == "L" else -1
            psi[m] = s * spec.get("base_deg", 45.0) + 15.0 * _smooth_noise(rng, T, fs, 0.4)[m]
        elif typ == "atnr":
            s = 1 if spec["side"] == "L" else -1
            face, occ = ("L", "R") if s == 1 else ("R", "L")
            psi[m] = s * 55.0 + 6.0 * _smooth_noise(rng, T, fs, 0.4)[m]
            scale_activity(m, [f"{face}_arm", f"{occ}_arm"], 0.15)
            dof[(face, "alpha")][m] += 90.0 - BASE["alpha"]
            dof[(face, "beta")][m] += 10.0 - BASE["beta"]
            dof[(occ, "alpha")][m] += 130.0 - BASE["alpha"]
            dof[(occ, "beta")][m] += 120.0 - BASE["beta"]
        elif typ == "frog_leg":
            scale_activity(m, ["L_leg", "R_leg"], spec.get("factor", 0.15))
            for side in SIDES:
                dof[(side, "gamma")][m] += 62.0 - BASE["gamma"]
                dof[(side, "kappa")][m] += 95.0 - BASE["kappa"]
                dof[(side, "phi")][m] += 3.0 - BASE["phi"]
        elif typ == "scissor":
            for e0 in spec["starts"]:
                mm = (t >= e0) & (t < e0 + spec.get("dur", 4.0))
                scale_activity(mm, ["L_leg", "R_leg"], 0.1)
                for side in SIDES:
                    dof[(side, "gamma")][mm] += -24.0 - BASE["gamma"]
                    dof[(side, "kappa")][mm] += 8.0 - BASE["kappa"]
                    dof[(side, "phi")][mm] += 12.0 - BASE["phi"]
        elif typ == "kick_rhythm":
            f, a = spec.get("f", 1.2), spec.get("amp_deg", 30.0)
            for side, ph in (("L", 0.0), ("R", np.pi)):
                w = np.sin(2 * np.pi * f * t + ph)
                dof[(side, "kappa")][m] = BASE["kappa"] + a * w[m]
                dof[(side, "phi")][m] = BASE["phi"] + 0.6 * a * w[m]
        elif typ == "clonic":
            side, limb = spec["limb"].split("_")
            f, a = spec.get("f", 2.0), spec.get("amp_deg", 35.0)
            ph = (f * t) % 1.0
            w = np.where(ph < 0.2, ph / 0.2, 1.0 - (ph - 0.2) / 0.8)  # fast jerk, slow relax
            n = "beta" if limb == "arm" else "kappa"
            others = [x for x in all_limbs if x != spec["limb"]]
            scale_activity(m, others + [spec["limb"]], 0.2)
            dof[(side, n)][m] = dof[(side, n)][m] + a * (w[m] - 0.5)
        elif typ == "spasm_cluster":
            n_ev, iv = spec.get("n", 6), spec.get("interval", 8.0)
            scale_activity(m, all_limbs, 0.2)
            starts = [t0 + k * iv + rng.uniform(-1.0, 1.0) for k in range(n_ev)]
            for st in starts:
                b = _bump(t, st)
                pos_overrides.append(("axial", None, b))
                for side in SIDES:
                    dof[(side, "alpha")] += 55.0 * b
                    dof[(side, "beta")] -= 60.0 * b
                    dof[(side, "kappa")] += 35.0 * b
                    dof[(side, "phi")] += 25.0 * b
        elif typ == "tremor":
            f, a = spec.get("f", 8.0), spec.get("amp_p2p", 0.04)
            for limb in spec["limbs"]:
                ang = rng.uniform(0, np.pi)
                d = np.array([np.cos(ang), np.sin(ang)])
                ph0 = rng.uniform(0, 2 * np.pi)
                osc = 0.5 * a * np.sin(2 * np.pi * f * t + ph0) * m
                pos_overrides.append((limb, d, osc))
        elif typ == "hands_midline":
            w = np.zeros(T)
            for e0 in spec["starts"]:
                w = np.maximum(w, _bump(t, e0, rise=0.4, hold=spec.get("dur", 2.0), fall=0.4))
            pos_overrides.append(("hands_mid", None, w))
        elif typ == "camera_shake":
            img_ops.append(spec)
        else:
            raise ValueError(typ)

    # ---- forward kinematics (body coords) ----
    B = {}
    head_shift: list = []
    for side, s in SIDES.items():
        a, be, li = dof[(side, "alpha")], dof[(side, "beta")], dof[(side, "lift")]
        d1 = np.stack([s * np.sin(np.radians(a)), -np.cos(np.radians(a))], -1)
        el = SH[s] + (UPPER * np.cos(np.radians(np.clip(li, 0, 80))))[:, None] * d1
        wr = el + FORE * _rot(d1, s * be)
        g, k, ph = dof[(side, "gamma")], dof[(side, "kappa")], dof[(side, "phi")]
        dt_ = np.stack([s * np.sin(np.radians(g)), -np.cos(np.radians(g))], -1)
        kn = HP[s] + (THIGH * np.cos(np.radians(np.clip(ph, 0, 85))))[:, None] * dt_
        an = kn + SHANK * _rot(dt_, -s * k)
        nm = "left" if side == "L" else "right"
        B[f"{nm}Shoulder"] = np.repeat(SH[s][None], T, 0)
        B[f"{nm}Hip"] = np.repeat(HP[s][None], T, 0)
        B[f"{nm}Elbow"], B[f"{nm}Wrist"], B[f"{nm}Knee"], B[f"{nm}Ankle"] = el, wr, kn, an
    for limb, d, osc in pos_overrides:
        if limb == "axial":  # neck/trunk flexion toward the camera: upper body foreshortens
            for nm in ("leftShoulder", "rightShoulder", "leftElbow", "rightElbow", "leftWrist", "rightWrist"):
                B[nm] = B[nm] - np.stack([np.zeros(T), 0.10 * osc], -1)
            head_shift.append(osc)
            continue
        if limb == "hands_mid":
            for nm, tu in (("left", 0.05), ("right", -0.05)):
                tgt = np.array([tu, 0.72])
                B[f"{nm}Wrist"] = (1 - osc[:, None]) * B[f"{nm}Wrist"] + osc[:, None] * tgt
            continue
        side, part = limb.split("_")
        nm = "left" if side == "L" else "right"
        dist, mid = ("Wrist", "Elbow") if part == "arm" else ("Ankle", "Knee")
        B[nm + dist] = B[nm + dist] + osc[:, None] * d
        B[nm + mid] = B[nm + mid] + 0.4 * osc[:, None] * d

    conf = {n: np.full(T, 0.85) for n in B}
    hs = np.sum(head_shift, axis=0) if head_shift else np.zeros(T)
    ps_r = np.radians(psi)

    def face_pt(angle, dv, rr=HEAD_R):
        return np.stack([rr * np.sin(angle), np.full(T, dv)], -1) + HEAD_C, np.cos(angle)

    sig = lambda z: 0.85 / (1 + np.exp(-8 * (z + 0.15)))
    for n, ang, dv, rr in (("nose", ps_r, 0.02, HEAD_R), ("leftEye", ps_r + 0.5, 0.10, 0.95 * HEAD_R),
                           ("rightEye", ps_r - 0.5, 0.10, 0.95 * HEAD_R), ("leftEar", ps_r + np.pi / 2, 0.0, HEAD_R),
                           ("rightEar", ps_r - np.pi / 2, 0.0, HEAD_R)):
        p, z = face_pt(ang, dv, rr)
        B[n] = _rot(p - NECK_P, tau) + NECK_P - np.stack([np.zeros(T), 0.22 * hs], -1)
        conf[n] = sig(z)
    B["neck"] = 0.5 * (B["leftShoulder"] + B["rightShoulder"])
    B["root"] = 0.5 * (B["leftHip"] + B["rightHip"])
    conf["neck"], conf["root"] = np.full(T, 0.85), np.full(T, 0.85)

    # ---- body -> image (isotropic height units), then normalize x by aspect ----
    drift = np.stack([0.01 * _smooth_noise(rng, T, fs, 0.1), 0.01 * _smooth_noise(rng, T, fs, 0.1)], -1)
    cx, cy = 0.5 * aspect, 0.52
    frames_xy = {}
    for n, p in B.items():
        q = _rot(p - np.array([0.0, 0.5]), np.full(T, body_rot_deg)) * scale
        X = cx + q[:, 0] + drift[:, 0]
        Y = cy - q[:, 1] + drift[:, 1]
        frames_xy[n] = np.stack([X, Y], -1)
    for op in img_ops:
        m, _, _ = win(op)
        f, a, rot = op.get("f", 8.0), op.get("amp", 0.004), op.get("rot_deg", 0.4)
        tx = a * np.sin(2 * np.pi * f * t) * m
        ty = a * np.cos(2 * np.pi * f * 1.07 * t) * m
        rr = rot * np.sin(2 * np.pi * f * 0.93 * t) * m
        for n in frames_xy:
            P = frames_xy[n] - np.array([cx, cy])
            frames_xy[n] = _rot(P, rr) + np.array([cx, cy]) + np.stack([tx, ty], -1)
    for n in frames_xy:
        c = conf[n]
        sd = jitter * np.where(c < 0.5, 1.6, 1.0)
        frames_xy[n] = frames_xy[n] + rng.standard_normal((T, 2)) * sd[:, None]
        drop = rng.random(T) < dropout
        conf[n] = np.where(drop, 0.05, np.clip(c + 0.05 * rng.standard_normal(T), 0, 1))

    frames = []
    for k in range(0, T, decimate):
        pts = {}
        for n in JOINTS:
            X, Y = frames_xy[n][k]
            pts[n] = {"x": float(X / aspect), "y": float(Y), "confidence": float(conf[n][k])}
        frames.append({"time": float(t[k]), "points": pts, "lightOK": True, "subjectBox": None})
    return {"schemaVersion": 2, "poseEstimator": "synthetic", "processing": "raw",
            "durationSeconds": float(duration), "nominalSampleIntervalSeconds": decimate / fs,
            "coordinateSystem": "normalized-top-left", "coordinateRange": "0...1",
            "jointSchema": "coco17-plus-derived-neck-root", "subjectSelection": "synthetic",
            "jointNames": JOINTS, "connections": [], "frames": frames,
            "aspectRatio": aspect, "captureFrameRate": fs,
            "_synthetic": {"seed": seed, "inject": list(inject)}}
