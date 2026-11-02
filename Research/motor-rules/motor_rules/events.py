# MoveGrow motor-rules prototype — Copyright (C) 2026 Ziqing Shi
# SPDX-License-Identifier: AGPL-3.0-only
"""Speed-based descriptors: activity bouts, L/R use, and brief synchronous bursts (catalog: event.*, activity.*)."""
from __future__ import annotations

import numpy as np

from .archive import J, PoseSeries
from .bodyframe import BodyFrame, moving_average
from .spectral import CHANNELS


def limb_speeds(ps: PoseSeries, bf: BodyFrame, smooth_s: float = 0.10) -> dict[str, np.ndarray]:
    """Distal-joint speed in torso lengths / s, body frame, lightly smoothed."""
    win = max(1, int(round(smooth_s * ps.fs)))
    out = {}
    for ch, jn in CHANNELS.items():
        X = moving_average(bf.B[:, J[jn], :], win)
        v = np.gradient(X, 1.0 / ps.fs, axis=0)
        out[ch] = np.linalg.norm(v, axis=1)
    X = moving_average(bf.B[:, J["nose"], :], win)
    out["head"] = np.linalg.norm(np.gradient(X, 1.0 / ps.fs, axis=0), axis=1)
    # noise floor: torso joints are (nearly) static in the body frame, so their apparent speed
    # is keypoint jitter + frame-estimation noise
    ref = []
    for jn in ("leftShoulder", "rightShoulder", "leftHip", "rightHip"):
        X = moving_average(bf.B[:, J[jn], :], win)
        ref.append(np.linalg.norm(np.gradient(X, 1.0 / ps.fs, axis=0), axis=1))
    out["_noise"] = float(np.nanmedian(np.concatenate(ref)))
    return out


def runs(mask: np.ndarray) -> list[tuple[int, int]]:
    """Contiguous True runs as [start, end) index pairs."""
    m = np.concatenate([[False], mask.astype(bool), [False]])
    d = np.diff(m.astype(int))
    return list(zip(np.where(d == 1)[0], np.where(d == -1)[0]))


def merge_runs(rr: list[tuple[int, int]], gap: int) -> list[tuple[int, int]]:
    out: list[list[int]] = []
    for a, b in rr:
        if out and a - out[-1][1] <= gap:
            out[-1][1] = b
        else:
            out.append([a, b])
    return [(a, b) for a, b in out]


def hysteresis(x: np.ndarray, on: float, off: float) -> np.ndarray:
    state, out = False, np.zeros(len(x), dtype=bool)
    for i, v in enumerate(x):
        if not np.isfinite(v):
            state = False
        elif state and v < off:
            state = False
        elif not state and v > on:
            state = True
        out[i] = state
    return out


def activity_summary(ps: PoseSeries, bf: BodyFrame, speeds: dict, on=0.18, off=0.10, min_bout_s=0.4,
                     knee_angles: dict | None = None) -> dict:
    fs = ps.fs
    noise = speeds.get("_noise", 0.0)
    on, off = max(on, 3.0 * noise), max(off, 2.0 * noise)
    res = {"_thresholds": {"on": on, "off": off, "noise_speed": noise}}
    for ch in CHANNELS:
        s = speeds[ch]
        valid = np.isfinite(s)
        act = hysteresis(s, on, off)
        bouts = [r for r in runs(act) if (r[1] - r[0]) / fs >= min_bout_s]
        obs_s = valid.sum() / fs
        path = float(np.nansum(s) / fs)
        res[ch] = dict(observed_s=obs_s, n_bouts=len(bouts),
                       bouts_per_min=len(bouts) / (obs_s / 60) if obs_s > 0 else np.nan,
                       active_frac=float(act[valid].mean()) if valid.any() else np.nan,
                       path_per_min=path / (obs_s / 60) if obs_s > 0 else np.nan,
                       median_speed=float(np.nanmedian(s)) if valid.any() else np.nan,
                       mean_conf=float(np.mean(ps.conf[:, J[CHANNELS[ch]]])))
        if knee_angles is not None and ch.endswith("leg"):
            ka = knee_angles["L" if ch.startswith("L") else "R"]
            kicks = 0
            for a, b in bouts:
                seg = ka[a:b]
                if np.isfinite(seg).sum() > 3 and np.nanmax(seg) - np.nanmin(seg) >= 25:
                    kicks += 1
            res[ch]["kicks_per_min"] = kicks / (obs_s / 60) if obs_s > 0 else np.nan

    def ai(a, b):
        return (a - b) / (a + b) if (a + b) > 0 else np.nan

    for limb in ("arm", "leg"):
        L, R = res[f"L_{limb}"], res[f"R_{limb}"]
        res[f"{limb}_asym_index"] = ai(L["path_per_min"], R["path_per_min"])
        res[f"{limb}_conf_diff"] = abs(L["mean_conf"] - R["mean_conf"])
        res[f"{limb}_min_observed_s"] = min(L["observed_s"], R["observed_s"])
        res[f"{limb}_active_s"] = (L["active_frac"] * L["observed_s"] + R["active_frac"] * R["observed_s"])
        res[f"{limb}_abs_asym_index"] = abs(res[f"{limb}_asym_index"]) if np.isfinite(res[f"{limb}_asym_index"]) else np.nan
        res[f"{limb}_less_side"] = "L" if res[f"{limb}_asym_index"] < 0 else "R"
    return res


def axial_signal(bf: BodyFrame) -> dict:
    """Head-to-shoulder distance and projected torso length (torso units): both shrink when the
    neck/trunk flex toward the camera in a supine top view."""
    nose_v = bf.B[:, J['nose'], 1]
    msh_v = 0.5 * (bf.B[:, J['leftShoulder'], 1] + bf.B[:, J['rightShoulder'], 1])
    return {'head': nose_v - msh_v, 'torso': bf.L_raw / bf.L_session}


class SplitMix64:
    """Tiny deterministic RNG shared bit-for-bit with the Swift engine (surrogate lags)."""
    MASK = (1 << 64) - 1

    def __init__(self, seed: int):
        self.state = seed & self.MASK

    def next(self) -> int:
        self.state = (self.state + 0x9E3779B97F4A7C15) & self.MASK
        z = self.state
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & self.MASK
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & self.MASK
        return z ^ (z >> 31)


def _scan_bursts(t, fs, S: np.ndarray, thr: float, p: dict, axial: dict | None = None) -> dict:
    """S: (4, T) limb speeds. Returns events, clusters and the best cluster."""
    limbs = list(CHANNELS)
    strong = np.nan_to_num(S, nan=0.0) > thr
    tol = max(1, int(round(p["sync_tol_s"] * fs)))
    k = np.ones(2 * tol + 1)
    dil = np.array([np.convolve(r.astype(float), k, mode="same") > 0 for r in strong])
    sync = dil.sum(0) >= p["min_limbs"]
    ev = merge_runs(runs(sync), int(round(0.2 * fs)))
    with np.errstate(all="ignore"):
        import warnings
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", RuntimeWarning)
            speed_mean = np.nanmean(S, axis=0)
    events = []
    for a, b in ev:
        dur = (b - a) / fs
        if not (p["min_dur_s"] <= dur <= p["max_dur_s"]):
            continue
        pre = speed_mean[max(0, a - int(2.0 * fs)):max(0, a - int(0.5 * fs))]
        peak = float(np.nanmax(speed_mean[a:b]))
        pre_level = float(np.nanmedian(pre)) if np.isfinite(pre).sum() > 3 else np.nan
        sudden = np.isfinite(pre_level) and pre_level <= p["pre_quiet_ratio"] * peak
        lb = [limbs[i] for i in range(4) if strong[i, a:b].any()]
        pair = ({"L_arm", "R_arm"} <= set(lb)) or ({"L_leg", "R_leg"} <= set(lb))
        ax = np.nan
        if axial is not None:
            pa, pb = max(0, a - int(1.5 * fs)), max(1, a - int(0.2 * fs))
            devs = []
            for sig in axial.values():
                base = np.nanmedian(sig[pa:pb]) if np.isfinite(sig[pa:pb]).any() else np.nan
                seg = sig[a:min(len(sig), b + int(0.3 * fs))]
                if np.isfinite(base) and np.isfinite(seg).any():
                    devs.append(float(np.nanmax(np.abs(seg - base))))
            ax = max(devs) if devs else np.nan
        axial_ok = (not p.get("require_axial", False)) or (np.isfinite(ax) and ax >= p.get("min_axial", 0.0))
        events.append(dict(t0=float(t[a]), t1=float(t[b - 1]), dur_s=dur, peak_speed=peak,
                           pre_level=pre_level, bilateral_pair=bool(pair), axial_dev=ax,
                           sudden=bool(sudden and axial_ok and (pair or not p.get("require_pair", True))), limbs=lb))
    sud = [e for e in events if e["sudden"]]
    clusters, cur = [], []
    for e in sud:
        if cur and p["min_interval_s"] <= e["t0"] - cur[-1]["t0"] <= p["max_interval_s"]:
            cur.append(e)
        else:
            if cur:
                clusters.append(cur)
            cur = [e]
    if cur:
        clusters.append(cur)
    cl_out = []
    for c in clusters:
        iv = np.diff([e["t0"] for e in c])
        cl_out.append(dict(n_events=len(c), t0=c[0]["t0"], t1=c[-1]["t1"],
                           median_interval_s=float(np.median(iv)) if len(iv) else np.nan,
                           interval_cv=float(np.std(iv) / np.mean(iv)) if len(iv) > 1 else np.nan,
                           median_dur_s=float(np.median([e["dur_s"] for e in c]))))
    ok = [c for c in cl_out if np.isfinite(c["median_interval_s"]) and c["median_interval_s"] <= p.get("max_median_interval_s", np.inf)]
    best = max(ok, key=lambda c: c["n_events"], default=None)
    return dict(events=events, n_sudden=len(sud), clusters=cl_out, best=best,
                stat=best["n_events"] if best else 0)


def burst_events(ps: PoseSeries, speeds: dict, p: dict, axial: dict | None = None,
                 n_surrogates: int = 60, seed: int = 0) -> dict:
    """Brief, sudden, near-synchronous multi-limb movements and their clustering.

    Surrogate test (no labels needed): circularly shift each limb's speed series by an independent
    random lag. This keeps every limb's own activity statistics but destroys cross-limb timing, so
    it estimates how large a 'cluster' chance coincidences of ordinary movements would produce.
    """
    fs = ps.fs
    limbs = list(CHANNELS)
    S = np.array([speeds[c] for c in limbs])
    pooled = float(np.nanmedian(S))
    thr = max(p["abs_speed"], p["rel_speed"] * pooled)  # pooled: a busier limb must not get a higher bar
    obs = _scan_bursts(ps.t, fs, S, thr, p, axial)
    T = S.shape[1]
    min_shift = int(5 * fs)
    ge = 0
    if obs["stat"] > 0 and T > 4 * min_shift:
        rng = SplitMix64(seed)
        span = T - 2 * min_shift
        for _ in range(n_surrogates):
            rows = [S[0]]
            for i in range(1, 4):
                rows.append(np.roll(S[i], min_shift + rng.next() % span))
            if _scan_bursts(ps.t, fs, np.array(rows), thr, p, axial)["stat"] >= obs["stat"]:
                ge += 1
        pval = (1 + ge) / (1 + n_surrogates)
    else:
        pval = 1.0
    best = obs["best"]
    return dict(events=obs["events"], n_sudden=obs["n_sudden"], clusters=obs["clusters"], threshold=thr,
                largest_cluster=best["n_events"] if best else 0,
                cluster_median_interval_s=best["median_interval_s"] if best else np.nan,
                cluster_interval_cv=best["interval_cv"] if best else np.nan, best=best,
                surrogate_p=pval, n_surrogates=n_surrogates)
