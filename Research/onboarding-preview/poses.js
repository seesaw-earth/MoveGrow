// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
'use strict';
// The onboarding's poses and views (mirrors OnboardingBaby in OnboardingArt.swift).
const B = require('./babyfigure.js');
const { MHR, add, sub, mul, unit } = B;
const lerp = (a, b, k) => [a[0] + (b[0] - a[0]) * k, a[1] + (b[1] - a[1]) * k, a[2] + (b[2] - a[2]) * k];
const rest = B.restingPose();
const shape = B.measure(j => rest[j]);
const hipsRest = mul(add(rest[MHR.leftHip], rest[MHR.rightHip]), 0.5);
const radius = Math.max(...rest.filter(B.finite).map(q => B.len(sub(q, hipsRest))));
const wave = (t, period, phase = 0) => 0.5 - 0.5 * Math.cos(2 * Math.PI * (t / period + phase));

/// The resting baby, kicking and waving gently. `t` in seconds; t = nil gives the still resting pose.
function pose(t) {
  const p = rest.map(q => q.slice());
  if (t === null || t === undefined) return p;
  const left = [1, 0, 0];
  for (const [s, isLeft] of [[1, true], [-1, false]]) {
    const [hp, kn, an, heel, big, small] = isLeft ? [MHR.leftHip, MHR.leftKnee, MHR.leftAnkle, MHR.leftHeel, MHR.leftBigToe, MHR.leftSmallToe]
      : [MHR.rightHip, MHR.rightKnee, MHR.rightAnkle, MHR.rightHeel, MHR.rightBigToe, MHR.rightSmallToe];
    const k = wave(t, 2.4, isLeft ? 0 : 0.45);
    const thigh = unit(lerp([s * 0.060, 0.045, -0.085], [s * 0.034, 0.100, -0.020], k));
    const shin = unit(lerp([s * -0.030, 0.060, 0.045], [s * 0.004, 0.082, -0.006], k));
    p[kn] = add(p[hp], mul(thigh, 0.106));
    p[an] = add(p[kn], mul(shin, 0.082));
    const toe = unit(lerp([s * 0.10, 0.55, -0.80], [s * 0.15, 0.85, -0.50], k));
    p[heel] = sub(p[an], mul(toe, 0.015));
    p[big] = sub(add(p[an], mul(toe, 0.06)), mul(left, 0.008));
    p[small] = add(add(p[an], mul(toe, 0.05)), mul(left, 0.018));
    const [el, wr, knuckle] = isLeft ? [MHR.leftElbow, MHR.leftWrist, MHR.leftMiddleKnuckle] : [MHR.rightElbow, MHR.rightWrist, MHR.rightMiddleKnuckle];
    const a = wave(t, 3.1, isLeft ? 0.3 : 0.75);
    const fore = unit(lerp([s * 0.008, -0.080, -0.020], [s * 0.050, -0.058, -0.045], a));
    p[wr] = add(p[el], mul(fore, 0.083));
    p[knuckle] = add(p[wr], mul(fore, 0.034));
  }
  return p;
}
/// Turns a pose about the mat's normal (the camera's z axis) through the resting hips.
function turned(p, angle) {
  const c = Math.cos(angle), s = Math.sin(angle);
  return p.map(q => { if (!B.finite(q)) return q; const x = q[0] - hipsRest[0], y = q[1] - hipsRest[1]; return [hipsRest[0] + x * c - y * s, hipsRest[1] + x * s + y * c, q[2]]; });
}
/// The mat under the resting baby, turned with it.
function mat(angle = 0) {
  const f = B.makeMat(j => rest[j], shape.torso);
  const c = Math.cos(angle), s = Math.sin(angle);
  const rot = v => [v[0] * c - v[1] * s, v[0] * s + v[1] * c, v[2]];
  const o = sub(f.origin, hipsRest);
  return Object.assign({}, f, { origin: add(hipsRest, rot(o)), ex: rot(f.ex), ey: rot(f.ey) });
}
module.exports = { pose, turned, mat, shape, radius, rest, hipsRest, wave };
