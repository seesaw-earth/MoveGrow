# MoveGrow motor-rules prototype — Copyright (C) 2026 Ziqing Shi
# SPDX-License-Identifier: AGPL-3.0-only
"""MoveGrow binary pose track (.mgpose), the app's on-device storage format.

Little-endian layout (version 1):
    0   4s   magic b"MGPS"
    4   u16  version (1)
    6   u16  joint count J (19, BodyJoint order)
    8   u32  frame count T
    12  u32  flags (bit 0: subject boxes present)
    16  u32  header length H
    20  H    header JSON (UTF-8): estimator, processing, aspectRatio, captureFrameRate, jointNames, ...
    then T frames:
        f64  time (s)
        i32  source frame index (-1 = unknown)
        u8   lightOK, 3 bytes padding
        J x (f32 x, f32 y, f32 confidence)   missing joint: x = y = NaN, confidence = 0
        [5 x f32 box x, y, w, h, confidence]  only when flags bit 0; missing: NaN
Coordinates are normalized to the displayed video, origin top-left (same as PoseArchive JSON).
"""
from __future__ import annotations

import json
import struct

import numpy as np

from .archive import JOINTS

MAGIC = b"MGPS"


def write_mgpose(path: str, archive: dict) -> None:
    frames = archive["frames"]
    has_box = any(f.get("subjectBox") for f in frames)
    header = {k: v for k, v in archive.items() if k not in ("frames", "connections", "_synthetic")}
    header["format"] = "movegrow.pose.binary"
    header["jointNames"] = JOINTS
    hb = json.dumps(header, separators=(",", ":")).encode("utf-8")
    J = len(JOINTS)
    out = bytearray()
    out += MAGIC + struct.pack("<HHIII", 1, J, len(frames), 1 if has_box else 0, len(hb)) + hb
    for k, f in enumerate(frames):
        out += struct.pack("<diB3x", float(f["time"]), int(f.get("frameIndex", k)), 1 if f.get("lightOK", True) else 0)
        arr = np.full((J, 3), np.nan, dtype="<f4")
        arr[:, 2] = 0.0
        for name, p in (f.get("points") or {}).items():
            if name in JOINTS:
                arr[JOINTS.index(name)] = (p["x"], p["y"], p["confidence"])
        out += arr.tobytes()
        if has_box:
            b = f.get("subjectBox")
            vals = (b["x"], b["y"], b["width"], b["height"], b["confidence"]) if b else (np.nan,) * 5
            out += np.array(vals, dtype="<f4").tobytes()
    with open(path, "wb") as fh:
        fh.write(out)


def read_mgpose(path: str) -> dict:
    """Return a PoseArchive-shaped dict (so load_archive can consume it)."""
    with open(path, "rb") as fh:
        data = fh.read()
    if data[:4] != MAGIC:
        raise ValueError("not an .mgpose file")
    version, J, T, flags, H = struct.unpack_from("<HHIII", data, 4)
    if version != 1:
        raise ValueError(f"unsupported .mgpose version {version}")
    header = json.loads(data[20:20 + H].decode("utf-8"))
    names = header.get("jointNames", JOINTS)
    off = 20 + H
    has_box = bool(flags & 1)
    frames = []
    for _ in range(T):
        t, idx, light = struct.unpack_from("<diB3x", data, off)
        off += 16
        arr = np.frombuffer(data, dtype="<f4", count=J * 3, offset=off).reshape(J, 3)
        off += J * 12
        pts = {names[j]: {"x": float(arr[j, 0]), "y": float(arr[j, 1]), "confidence": float(arr[j, 2])}
               for j in range(J) if np.isfinite(arr[j, 0]) and arr[j, 2] > 0}
        box = None
        if has_box:
            b = np.frombuffer(data, dtype="<f4", count=5, offset=off)
            off += 20
            if np.isfinite(b[0]):
                box = dict(x=float(b[0]), y=float(b[1]), width=float(b[2]), height=float(b[3]), confidence=float(b[4]))
        frames.append({"time": t, "frameIndex": idx, "points": pts, "lightOK": bool(light), "subjectBox": box})
    header["frames"] = frames
    return header
