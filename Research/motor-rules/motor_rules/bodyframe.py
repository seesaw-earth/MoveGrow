# MoveGrow motor-rules prototype — Copyright (C) 2026 Ziqing Shi
# SPDX-License-Identifier: AGPL-3.0-only
"""Anatomical body frame.

Coordinates are first made isotropic (x * aspect, y in image-height units), then expressed in a
per-frame torso frame:
    v = unit vector mid-hip -> mid-shoulder (cranial)
    u = unit vector perpendicular to v pointing to the baby's anatomical LEFT
        (chosen from the leftShoulder - rightShoulder direction, so prone/supine both work)
    unit length = torso length (mid-hip to mid-shoulder), session median.

Rotation and scale are smoothed (they are estimated from four noisy points and would otherwise
inject broadband noise into every channel). Translation uses the *unsmoothed* torso centroid so
that rigid camera translation cancels frame by frame.
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from .archive import J, PoseSeries


def rolling_nanmedian(x: np.ndarray, win: int) -> np.ndarray:
    if win <= 1:
        return x.copy()
    h = win // 2
    pad = np.pad(x, (h, h), mode="edge")
    from numpy.lib.stride_tricks import sliding_window_view
    w = sliding_window_view(pad, 2 * h + 1)
    with np.errstate(all="ignore"):
        import warnings
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", RuntimeWarning)
            return np.nanmedian(w, axis=-1)


def moving_average(x: np.ndarray, win: int) -> np.ndarray:
    """NaN-aware centered moving average along axis 0."""
    if win <= 1:
        return x.copy()
    k = np.ones(win)
    valid = np.isfinite(x)
    xf = np.where(valid, x, 0.0)
    if x.ndim == 1:
        num = np.convolve(xf, k, mode="same")
        den = np.convolve(valid.astype(float), k, mode="same")
    else:
        flat = xf.reshape(len(x), -1)
        vflat = valid.reshape(len(x), -1).astype(float)
        num = np.stack([np.convolve(flat[:, i], k, mode="same") for i in range(flat.shape[1])], 1)
        den = np.stack([np.convolve(vflat[:, i], k, mode="same") for i in range(vflat.shape[1])], 1)
        num, den = num.reshape(x.shape), den.reshape(x.shape)
    out = np.where(den > 0.5 * win, num / np.maximum(den, 1e-9), np.nan)
    return np.where(valid, out, np.nan)


@dataclass
class BodyFrame:
    P: np.ndarray        # (T, J, 2) isotropic image coords (height units)
    B: np.ndarray        # (T, J, 2) body coords [u, v] in torso units, centroid origin
    centroid: np.ndarray  # (T, 2) unsmoothed torso centroid, isotropic image coords
    u_hat: np.ndarray    # (T, 2)
    v_hat: np.ndarray    # (T, 2)
    L: np.ndarray        # (T,) smoothed torso length (height units)
    L_session: float
    L_raw: np.ndarray    # (T,) unsmoothed torso length (height units)
    valid: np.ndarray    # (T,) torso frame available
    shoulder_width: float  # session median, torso units
    hip_width: float


def build_body_frame(ps: PoseSeries, smooth_s: float = 0.5) -> BodyFrame:
    P = ps.xy.copy()
    P[..., 0] *= ps.aspect
    ls, rs = P[:, J["leftShoulder"]], P[:, J["rightShoulder"]]
    lh, rh = P[:, J["leftHip"]], P[:, J["rightHip"]]
    msh, mhp = 0.5 * (ls + rs), 0.5 * (lh + rh)
    centroid = 0.25 * (ls + rs + lh + rh)
    axis = msh - mhp
    L_raw = np.linalg.norm(axis, axis=1)
    valid = np.isfinite(L_raw) & (L_raw > 1e-4)

    win = max(1, int(round(smooth_s * ps.fs)) | 1)
    ang = np.arctan2(axis[:, 1], axis[:, 0])
    ang_f = ang.copy()
    if valid.any():
        ang_f[valid] = np.unwrap(ang[valid])
    ang_s = rolling_nanmedian(np.where(valid, ang_f, np.nan), win)
    L_s = rolling_nanmedian(np.where(valid, L_raw, np.nan), win)
    v_hat = np.stack([np.cos(ang_s), np.sin(ang_s)], 1)
    perp = np.stack([-v_hat[:, 1], v_hat[:, 0]], 1)  # +90 deg rotation
    sgn = np.sign(np.einsum("ij,ij->i", ls - rs, perp))
    sgn = rolling_nanmedian(np.where(valid, sgn, np.nan), max(win, int(ps.fs) | 1))
    sgn = np.where(np.isfinite(sgn) & (sgn != 0), np.sign(sgn), 1.0)
    u_hat = perp * sgn[:, None]
    L_session = float(np.nanmedian(L_s)) if np.isfinite(L_s).any() else np.nan

    rel = P - centroid[:, None, :]
    Bu = np.einsum("tjd,td->tj", rel, u_hat) / L_session
    Bv = np.einsum("tjd,td->tj", rel, v_hat) / L_session
    B = np.stack([Bu, Bv], -1)
    B[~valid] = np.nan

    with np.errstate(all="ignore"):
        sw = np.nanmedian(np.abs(B[:, J["leftShoulder"], 0] - B[:, J["rightShoulder"], 0]))
        hw = np.nanmedian(np.abs(B[:, J["leftHip"], 0] - B[:, J["rightHip"], 0]))
    return BodyFrame(P=P, B=B, centroid=centroid, u_hat=u_hat, v_hat=v_hat, L=L_s,
                     L_session=L_session, L_raw=L_raw, valid=valid, shoulder_width=float(sw), hip_width=float(hw))


def joint_angle(a: np.ndarray, b: np.ndarray, c: np.ndarray) -> np.ndarray:
    """Interior angle at b (degrees) for (T,2) arrays; 180 = straight."""
    v1, v2 = a - b, c - b
    n = np.linalg.norm(v1, axis=1) * np.linalg.norm(v2, axis=1)
    cosv = np.einsum("ij,ij->i", v1, v2) / np.where(n > 1e-9, n, np.nan)
    return np.degrees(np.arccos(np.clip(cosv, -1, 1)))
