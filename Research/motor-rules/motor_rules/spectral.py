# MoveGrow motor-rules prototype — Copyright (C) 2026 Ziqing Shi
# SPDX-License-Identifier: AGPL-3.0-only
"""Windowed spectral features per limb channel (feature catalog: window.*).

Input must be the RAW pose series (before One-Euro / low-pass smoothing), sampled fast enough
for the band of interest. Signals are distal joints in the body frame (torso units), so rigid
camera translation cancels; a separate rigid-motion test catches camera rotation/zoom shake.
"""
from __future__ import annotations

import numpy as np
from scipy.signal import butter, sosfiltfilt

from .archive import J, PoseSeries
from .bodyframe import BodyFrame

CHANNELS = {"L_arm": "leftWrist", "R_arm": "rightWrist", "L_leg": "leftAnkle", "R_leg": "rightAnkle"}
CONTRA = {"L_arm": "R_arm", "R_arm": "L_arm", "L_leg": "R_leg", "R_leg": "L_leg"}
SIDE = {"L_arm": "L", "R_arm": "R", "L_leg": "L", "R_leg": "R"}

BANDS = {
    # name: (filter low, filter high or None, search low, search high, ref low, window s, hop s)
    "fast": dict(hp=4.0, lp=14.0, search=(4.5, 13.5), ref=(4.5, 14.0), win=2.0, hop=0.5, excl=1.0, bw=0.75),
    "slow": dict(hp=0.4, lp=6.0, search=(0.75, 4.5), ref=(0.5, 6.0), win=4.0, hop=1.0, excl=0.5, bw=0.35),
}


def _fill_nan(x: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    ok = np.isfinite(x)
    if ok.sum() < 2:
        return np.zeros_like(x), ok
    idx = np.arange(len(x))
    return np.interp(idx, idx[ok], x[ok]), ok


def _filter(x: np.ndarray, fs: float, hp: float, lp: float | None) -> np.ndarray:
    nyq = 0.5 * fs
    if lp is not None and lp < nyq * 0.95:
        sos = butter(4, [hp / nyq, lp / nyq], btype="band", output="sos")
    else:
        sos = butter(4, hp / nyq, btype="high", output="sos")
    return sosfiltfilt(sos, x, axis=0)


def _psd(seg: np.ndarray, fs: float, nfft: int) -> tuple[np.ndarray, np.ndarray]:
    """One-sided Hann periodogram; sum(P)*df ~= variance of seg (per column, summed over columns)."""
    n = seg.shape[0]
    w = np.hanning(n)
    segc = seg - seg.mean(axis=0)
    X = np.fft.rfft(segc * w[:, None], n=nfft, axis=0)
    P = (np.abs(X) ** 2) / (fs * np.sum(w ** 2))
    P[1:-1] *= 2.0
    f = np.fft.rfftfreq(nfft, 1.0 / fs)
    return f, P.sum(axis=1)


def _rigid_r2(D: np.ndarray, Pbar: np.ndarray) -> float:
    """Fraction of multi-joint displacement explained by one similarity motion per frame.

    D: (T, n, 2) band-passed image-space displacements; Pbar: (n, 2) mean positions.
    """
    n = Pbar.shape[0]
    c = Pbar.mean(axis=0)
    r = Pbar - c
    A = np.zeros((2 * n, 4))
    A[0::2, 0] = 1.0
    A[1::2, 1] = 1.0
    A[0::2, 2], A[1::2, 2] = -r[:, 1], r[:, 0]   # small rotation
    A[0::2, 3], A[1::2, 3] = r[:, 0], r[:, 1]    # isotropic scale
    Y = D.reshape(D.shape[0], 2 * n).T          # (2n, T)
    coef, *_ = np.linalg.lstsq(A, Y, rcond=None)
    res = Y - A @ coef
    sst = float(np.sum(Y ** 2))
    return 1.0 - float(np.sum(res ** 2)) / sst if sst > 0 else 0.0


def spectral_windows(ps: PoseSeries, bf: BodyFrame, band: str = "fast",
                     min_valid: float = 0.9, torso_cm: float = 20.0) -> dict:
    cfg = BANDS[band]
    fs, nyq = ps.fs, 0.5 * ps.fs
    s_lo, s_hi = cfg["search"][0], min(cfg["search"][1], nyq - 0.5)
    r_lo, r_hi = cfg["ref"][0], (cfg["ref"][1] or nyq - 0.25)
    r_hi = min(r_hi, nyq - 0.25)
    if s_hi <= s_lo + 0.5 or cfg["hp"] >= nyq * 0.9:
        return {"band": band, "rows": [], "abstain": f"sampling rate {fs:.1f} Hz too low for {band} band"}

    win, hop = int(round(cfg["win"] * fs)), int(round(cfg["hop"] * fs))
    nfft = int(2 ** np.ceil(np.log2(max(256, 4 * win))))
    T = ps.T

    filt, okmask = {}, {}
    for ch, jn in CHANNELS.items():
        X = bf.B[:, J[jn], :]
        cols, oks = [], []
        for d in range(2):
            xf, ok = _fill_nan(X[:, d])
            cols.append(_filter(xf, fs, cfg["hp"], cfg["lp"]))
            oks.append(ok)
        filt[ch] = np.stack(cols, 1)
        okmask[ch] = oks[0] & oks[1]

    # image-space band-passed coordinates for the rigid-motion (camera) test
    rig_names = ["leftShoulder", "rightShoulder", "leftHip", "rightHip", "leftElbow", "rightElbow",
                 "leftWrist", "rightWrist", "leftKnee", "rightKnee", "leftAnkle", "rightAnkle", "nose"]
    rig_idx = [J[n] for n in rig_names]
    Pimg = bf.P[:, rig_idx, :]
    Pf = np.full_like(Pimg, np.nan)
    rig_ok = np.isfinite(Pimg[..., 0])
    for k in range(len(rig_idx)):
        for d in range(2):
            xf, _ = _fill_nan(Pimg[:, k, d])
            Pf[:, k, d] = _filter(xf, fs, cfg["hp"], cfg["lp"])
    cen_f = np.stack([_filter(_fill_nan(bf.centroid[:, d])[0], fs, cfg["hp"], cfg["lp"]) for d in range(2)], 1)

    rows = []
    for st in range(0, T - win + 1, hop):
        sl = slice(st, st + win)
        t0, t1 = float(ps.t[st]), float(ps.t[st + win - 1])
        # rigid test on joints valid through the whole window
        full = rig_ok[sl].all(axis=0)
        if full.sum() >= 6:
            r2 = _rigid_r2(Pf[sl][:, full, :], np.nanmean(bf.P[sl][:, [rig_idx[i] for i in np.where(full)[0]], :], axis=0))
        else:
            r2 = np.nan
        cam_rms = float(np.sqrt(np.mean(np.sum(cen_f[sl] ** 2, 1)))) / bf.L_session
        for ch in CHANNELS:
            vfrac = float(okmask[ch][sl].mean())
            row = dict(channel=ch, side=SIDE[ch], t0=t0, t1=t1, valid_frac=vfrac, rigid_r2=r2,
                       camera_rms=cam_rms, band=band)
            if vfrac < min_valid:
                row["valid"] = False
                rows.append(row)
                continue
            seg = filt[ch][sl]
            f, P = _psd(seg, fs, nfft)
            df = f[1] - f[0]
            sm = (f >= s_lo) & (f <= s_hi)
            k = int(np.argmax(np.where(sm, P, -np.inf)))
            # parabolic interpolation on log power
            if 0 < k < len(P) - 1 and P[k - 1] > 0 and P[k + 1] > 0:
                a, b, c = np.log(P[k - 1]), np.log(P[k]), np.log(P[k + 1])
                off = 0.5 * (a - c) / (a - 2 * b + c) if (a - 2 * b + c) != 0 else 0.0
            else:
                off = 0.0
            f0 = float(f[k] + off * df)
            ref = (f >= r_lo) & (f <= r_hi) & (np.abs(f - f0) > cfg["excl"])
            med = float(np.median(P[ref])) if ref.any() else np.nan
            prom = 10 * np.log10(P[k] / med) if med and med > 0 else np.nan
            pb = (np.abs(f - f0) <= cfg["bw"])
            var_band = float(P[pb].sum() * df)
            amp = 2.0 * np.sqrt(2.0 * var_band)  # peak-to-peak, torso units
            lag = int(round(fs / f0)) if f0 > 0 else 0
            if 0 < lag < win - 2:
                x = seg - seg.mean(0)
                num = float(np.sum(x[:-lag] * x[lag:]))
                den = float(np.sqrt(np.sum(x[:-lag] ** 2) * np.sum(x[lag:] ** 2)))
                rho = num / den if den > 0 else 0.0
            else:
                rho = np.nan
            tot = float(P[(f >= r_lo) & (f <= r_hi)].sum() * df)
            row.update(valid=True, peak_hz=f0, prominence_db=float(prom), amp_p2p=float(amp),
                       amp_p2p_cm=float(amp * torso_cm), rhythmicity=float(rho),
                       band_var=var_band, total_var=tot, peak_frac=var_band / tot if tot > 0 else np.nan)
            rows.append(row)

    # contralateral comparison: power of the homologous limb at this window's peak frequency
    index = {(r["channel"], r["t0"]): r for r in rows}
    for r in rows:
        if not r.get("valid"):
            continue
        o = index.get((CONTRA[r["channel"]], r["t0"]))
        if o is None or not o.get("valid"):
            r["contra_ratio"] = np.nan
            continue
        seg = filt[o["channel"]][int(round((r["t0"] - ps.t[0]) * fs)):][:win]
        f, P = _psd(seg, fs, nfft)
        pb = np.abs(f - r["peak_hz"]) <= cfg["bw"]
        r["contra_ratio"] = float(P[pb].sum() * (f[1] - f[0])) / r["band_var"] if r["band_var"] > 0 else np.nan
    return {"band": band, "rows": rows, "abstain": None, "nyquist": nyq,
            "search": (s_lo, s_hi), "win_s": cfg["win"], "hop_s": cfg["hop"]}
