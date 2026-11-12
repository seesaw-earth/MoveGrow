// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
'use strict';
// A JavaScript port of MoveGrow/Features/Pose/BabyFigure.swift (the app's baby figure), emitting SVG.
// Same geometry, same order of painting, same palette. Used to preview the onboarding art exactly as the
// app's Canvas would draw it, and to check the poses and views chosen in OnboardingArt.swift.

// ---------- vectors ----------
const add = (a, b) => [a[0] + b[0], a[1] + b[1], a[2] + b[2]];
const sub = (a, b) => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
const mul = (a, k) => [a[0] * k, a[1] * k, a[2] * k];
const dot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
const cross = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
const len = a => Math.hypot(a[0], a[1], a[2]);
const unit = a => { const n = len(a); return n > 1e-6 ? mul(a, 1 / n) : [0, 0, 0]; };
const orthogonal = (v, axis) => unit(sub(v, mul(axis, dot(v, axis))));
const finite = a => !!a && isFinite(a[0]) && isFinite(a[1]) && isFinite(a[2]);
const NANV = [NaN, NaN, NaN];

const MHR = {
  nose: 0, leftEar: 3, rightEar: 4, leftShoulder: 5, rightShoulder: 6, leftElbow: 7, rightElbow: 8,
  leftHip: 9, rightHip: 10, leftKnee: 11, rightKnee: 12, leftAnkle: 13, rightAnkle: 14,
  leftBigToe: 15, leftSmallToe: 16, leftHeel: 17, rightBigToe: 18, rightSmallToe: 19, rightHeel: 20,
  rightMiddleKnuckle: 32, rightWrist: 41, leftMiddleKnuckle: 53, leftWrist: 62,
  leftAcromion: 67, rightAcromion: 68, neck: 69, J: 70,
};

// ---------- palette (BabyPalette) ----------
const hex = v => '#' + v.toString(16).padStart(6, '0').toUpperCase();
const mat = (base, light, shade, line) => ({ base: hex(base), light: hex(light), shade: hex(shade), line: hex(line) });
const Palette = {
  romper: mat(0xBFE3AE, 0xE6F6DC, 0x92C47E, 0x77A866),
  skin: mat(0xFFDAC6, 0xFFF1E8, 0xF1B497, 0xD9977B),
  left: mat(0xA9D3F6, 0xE0F1FF, 0x7DB4E5, 0x6697C9),
  right: mat(0xFBB89C, 0xFFE3D6, 0xEE9172, 0xD27858),
  ink: '#3B332D', blush: '#F39A98', mouth: '#C7655D', hair: '#C39A6E', hairLine: '#A67C52', sprout: '#6FA663',
  scene: {
    light: { backgroundTop: '#EEF5E8', backgroundBottom: '#FBF6EE', mat: '#FFFDF9', matEdge: '#EBDDCF', stitch: '#E9C7BF', dotA: '#DDEFD3', dotB: '#FBE2DC', shadow: '#55654F' },
    dark: { backgroundTop: '#232B24', backgroundBottom: '#161513', mat: '#2C342D', matEdge: '#1E241F', stitch: '#4A5A49', dotA: '#37443A', dotB: '#463734', shadow: '#000000' },
  },
};

// ---------- body frame ----------
function bodyAxes(P) {
  const ls = P(MHR.leftShoulder), rs = P(MHR.rightShoulder), lh = P(MHR.leftHip), rh = P(MHR.rightHip);
  if (![ls, rs, lh, rh].every(finite)) return null;
  const hips = mul(add(lh, rh), 0.5), shoulders = mul(add(ls, rs), 0.5);
  if (!(len(sub(shoulders, hips)) > 1e-4)) return null;
  const v = unit(sub(shoulders, hips));
  const us = orthogonal(sub(ls, rs), v), uh = orthogonal(sub(lh, rh), v);
  const ws = cross(us, v), wh = cross(uh, v);
  return { hips, shoulders, v, us, uh, ws, wh, w: unit(add(ws, wh)) };
}

function measure(P) {
  const b = bodyAxes(P);
  if (!b) return { torso: 0.18, shoulders: null, hips: null };
  return { torso: len(sub(b.shoulders, b.hips)), shoulders: len(sub(P(MHR.leftShoulder), P(MHR.rightShoulder))), hips: len(sub(P(MHR.leftHip), P(MHR.rightHip))) };
}

// ---------- projection ----------
class Projector {
  constructor(root, yaw, pitch, scale, center) {
    this.root = root; this.c1 = Math.cos(yaw); this.s1 = Math.sin(yaw); this.c2 = Math.cos(pitch); this.s2 = Math.sin(pitch);
    this.scale = scale; this.center = center;
  }
  vec(d) {
    const x1 = this.c1 * d[0] + this.s1 * d[2], z1 = -this.s1 * d[0] + this.c1 * d[2];
    return [x1, this.c2 * d[1] - this.s2 * z1, this.s2 * d[1] + this.c2 * z1];
  }
  view(p) { return this.vec(sub(p, this.root)); }
  screen(v) { return { x: this.center.x + this.scale * v[0], y: this.center.y + this.scale * v[1] }; }
  point(p) { return this.screen(this.view(p)); }
  onScreen(d) { const v = this.vec(d); return { dx: this.scale * v[0], dy: this.scale * v[1] }; }
  patch(p, east, north) {
    const o = this.point(p), e = this.onScreen(east), n = this.onScreen(north);
    return [e.dx, e.dy, n.dx, n.dy, o.x, o.y];
  }
}
const viewLight = unit([-0.5, -0.75, -0.45]);
const screenLight = (() => { const n = Math.hypot(viewLight[0], viewLight[1]); return { dx: viewLight[0] / n, dy: viewLight[1] / n }; })();

// ---------- screen shapes ----------
const f2 = x => (Math.round(x * 100) / 100).toString();
const applyM = (m, p) => ({ x: m[0] * p.x + m[2] * p.y + m[4], y: m[1] * p.x + m[3] * p.y + m[5] });
const matrixAttr = m => `matrix(${m.map(v => (Math.round(v * 1e4) / 1e4)).join(' ')})`;
const polyD = pts => 'M' + pts.map(p => f2(p.x) + ' ' + f2(p.y)).join('L') + 'Z';

class Oval {
  constructor(center, angle, a, b) { this.center = center; this.angle = angle; this.a = a; this.b = b; }
  static fromAxes(center, axes) {
    let m11 = 0, m12 = 0, m22 = 0;
    for (const v of axes) { m11 += v.dx * v.dx; m12 += v.dx * v.dy; m22 += v.dy * v.dy; }
    const half = (m11 + m22) / 2;
    const disc = Math.sqrt(Math.max(0, half * half - (m11 * m22 - m12 * m12)));
    const l1 = half + disc, l2 = Math.max(half - disc, 1e-6);
    const angle = Math.abs(m12) > 1e-9 ? Math.atan2(m12, l1 - m22) : (m11 >= m22 ? 0 : Math.PI / 2);
    return new Oval(center, angle, Math.sqrt(Math.max(l1, 1e-6)), Math.sqrt(l2));
  }
  get transform() {
    const c = Math.cos(this.angle), s = Math.sin(this.angle), sx = Math.max(this.a, 0.5), sy = Math.max(this.b, 0.5);
    return [c * sx, s * sx, -s * sy, c * sy, this.center.x, this.center.y];
  }
  points(n = 48) {
    const c = Math.cos(this.angle), s = Math.sin(this.angle), out = [];
    for (let k = 0; k < n; k++) {
      const t = 2 * Math.PI * k / n, x = this.a * Math.cos(t), y = this.b * Math.sin(t);
      out.push({ x: this.center.x + x * c - y * s, y: this.center.y + x * s + y * c });
    }
    return out;
  }
  get d() { return polyD(this.points(64)); }
}

function hullPoints(points) {
  const pts = points.slice().sort((p, q) => p.x !== q.x ? p.x - q.x : p.y - q.y);
  if (pts.length < 3) return [];
  const cr = (o, a, b) => (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);
  const lower = [], upper = [];
  for (const q of pts) { while (lower.length >= 2 && cr(lower[lower.length - 2], lower[lower.length - 1], q) <= 0) lower.pop(); lower.push(q); }
  for (const q of pts.slice().reverse()) { while (upper.length >= 2 && cr(upper[upper.length - 2], upper[upper.length - 1], q) <= 0) upper.pop(); upper.push(q); }
  return lower.slice(0, -1).concat(upper.slice(0, -1));
}

function capsulePoints(a, ra, b, rb) {
  const dx = b.x - a.x, dy = b.y - a.y, length = Math.hypot(dx, dy);
  if (length <= Math.abs(ra - rb) + 1e-6) {
    const [c, r] = ra >= rb ? [a, ra] : [b, rb];
    return new Oval(c, 0, r, r).points(48);
  }
  const beta = Math.atan2(dy, dx), theta = Math.acos(Math.max(-1, Math.min(1, (ra - rb) / length))), steps = 14, out = [];
  for (let k = 0; k <= steps; k++) { const t = beta + theta - 2 * theta * k / steps; out.push({ x: b.x + rb * Math.cos(t), y: b.y + rb * Math.sin(t) }); }
  for (let k = 0; k <= steps; k++) { const t = beta - theta - (2 * Math.PI - 2 * theta) * k / steps; out.push({ x: a.x + ra * Math.cos(t), y: a.y + ra * Math.sin(t) }); }
  return out;
}

// ---------- floor ----------
/// The mat under a lying baby, as BabyFloor.make would find it for a still pose `P` (camera frame).
function makeMat(P, L) {
  const b = bodyAxes(P);
  let n = [0, 0, -1];
  const trunk = [MHR.leftShoulder, MHR.rightShoulder, MHR.leftHip, MHR.rightHip].map(P);
  const low = Math.min(...trunk.map(p => dot(p, n)));
  const d = low - 0.34 * L;
  let origin = sub(b.hips, mul(n, dot(b.hips, n) - d));
  const ey = unit(sub([0, 1, 0], mul(n, dot([0, 1, 0], n))));
  const ex = cross(n, ey);
  origin = sub(origin, mul(ey, 0.25 * L));
  const bias = [0.35, 0.55, 0.45];
  const light = unit(add(mul(n, -1), sub(bias, mul(n, dot(bias, n)))));
  return { origin, normal: n, ex, ey, light, size: [3.6 * L, 4.8 * L], round: false };
}
function floorShadowPoint(floor, p) {
  const q = add(p, mul(floor.light, dot(sub(floor.origin, p), floor.normal) / dot(floor.light, floor.normal)));
  return { point: { x: dot(sub(q, floor.origin), floor.ex), y: dot(sub(q, floor.origin), floor.ey) }, height: dot(sub(p, floor.origin), floor.normal) };
}
function floorShadowVector(floor, a) {
  const a2 = sub(a, mul(floor.light, dot(a, floor.normal) / dot(floor.light, floor.normal)));
  return { dx: dot(a2, floor.ex), dy: dot(a2, floor.ey) };
}

// ---------- anchors ----------
function anchors(P, body, L) {
  const earL = P(MHR.leftEar), earR = P(MHR.rightEar), nose = P(MHR.nose);
  const earMid = mul(add(earL, earR), 0.5);
  const headOK = [earL, earR, nose].every(finite);
  const l = headOK ? unit(sub(earL, earR)) : body.us;
  let f = headOK ? orthogonal(sub(nose, earMid), l) : body.ws;
  if (len(f) < 0.5) f = orthogonal(body.ws, l);
  const up = cross(f, l), R = 0.45 * L;
  const cranium = add(add(earMid, mul(up, 0.22 * R)), mul(f, 0.08 * R));
  const head = headOK ? cranium : add(body.shoulders, mul(body.v, 0.55 * L));
  const skull = sub(sub(earMid, mul(up, 0.15 * R)), mul(f, 0.20 * R));
  const skullBase = headOK ? skull : sub(head, mul(up, 0.6 * R));
  const pieces = {};
  for (const [limb, sh, el, wr, kn] of [['leftArm', MHR.leftShoulder, MHR.leftElbow, MHR.leftWrist, MHR.leftMiddleKnuckle], ['rightArm', MHR.rightShoulder, MHR.rightElbow, MHR.rightWrist, MHR.rightMiddleKnuckle]]) {
    const s = P(sh), e = P(el), w = P(wr);
    let hand = sub(P(kn), w);
    if (!(len(hand) >= 0.05 * L)) hand = mul(unit(sub(w, e)), 0.3 * L);
    pieces[limb] = { upper: [s, e], lower: [e, w], end: [add(w, mul(hand, 0.25)), add(w, hand)] };
  }
  for (const [limb, hp, kn, an, heel, big, small] of [['leftLeg', MHR.leftHip, MHR.leftKnee, MHR.leftAnkle, MHR.leftHeel, MHR.leftBigToe, MHR.leftSmallToe], ['rightLeg', MHR.rightHip, MHR.rightKnee, MHR.rightAnkle, MHR.rightHeel, MHR.rightBigToe, MHR.rightSmallToe]]) {
    const h = P(hp), k = P(kn), a = P(an);
    const heelEnd = add(mul(P(heel), 0.6), mul(a, 0.4)), toes = mul(add(P(big), P(small)), 0.5);
    pieces[limb] = { upper: [h, k], lower: [k, a], end: [heelEnd, toes] };
  }
  return { head, skullBase, R, f, l, up, pieces };
}

// ---------- the figure ----------
function buildFigure(view, shape, P, body) {
  const L = shape.torso, parts = [], shadows = [];
  const part = (pts, oval, material, depth, extra = {}) => Object.assign({ pts, oval, material, depth }, extra);
  const ellipsoid = (c, axes, m, shadow = true) => {
    const oval = Oval.fromAxes(view.point(c), axes.map(a => view.onScreen(a)));
    if (shadow) shadows.push({ kind: 'ellipsoid', c, axes });
    return part(oval.points(64), oval, m, view.view(c)[2]);
  };
  const capsule = (a, b, ra, rb, m, shadow = true) => {
    const va = view.view(a), vb = view.view(b), pa = view.screen(va), pb = view.screen(vb), s = view.scale;
    const dx = pb.x - pa.x, dy = pb.y - pa.y, length = Math.hypot(dx, dy), rmax = Math.max(ra, rb) * s;
    const oval = new Oval({ x: (pa.x + pb.x) / 2, y: (pa.y + pb.y) / 2 }, length > 1e-6 ? Math.atan2(dy, dx) : 0, Math.max(length / 2 + rmax, rmax), rmax);
    if (shadow) shadows.push({ kind: 'capsule', a, b, ra, rb });
    return part(capsulePoints(pa, ra * s, pb, rb * s), oval, m, (va[2] + vb[2]) / 2);
  };
  const ball = (c, r, m, shadow = true) => {
    const v = view.view(c), p = view.screen(v), rr = r * view.scale;
    if (shadow) shadows.push({ kind: 'ball', c, r });
    const oval = new Oval(p, 0, rr, rr);
    return part(oval.points(72), oval, m, v[2]);
  };

  const H = body.hips, T = sub(body.shoulders, body.hips), v = body.v;
  const romper = Palette.romper, skin = Palette.skin;
  const shoulderWidth = shape.shoulders ?? 0.8 * L, hipWidth = shape.hips ?? 0.45 * L;
  const acromL = P(MHR.leftAcromion), acromR = P(MHR.rightAcromion);
  const acromOK = [acromL, acromR].every(finite);
  const acromion = acromOK ? mul(add(acromL, acromR), 0.5) : add(body.shoulders, mul(v, 0.03 * L));
  const across = orthogonal(add(body.us, body.uh), v), out = cross(across, v);
  const girdleWidth = Math.max(0.46 * shoulderWidth, 0.28 * L), tummyWidth = Math.max(0.44 * L, 0.5 * hipWidth + 0.10 * L), pelvisWidth = 0.5 * hipWidth + 0.13 * L;
  const blobs = [
    { center: sub(acromion, mul(v, 0.16 * L)), axes: [mul(body.us, girdleWidth), mul(v, 0.18 * L), mul(body.ws, 0.27 * L)] },
    { center: add(add(H, mul(T, 0.45)), mul(add(body.ws, body.wh), 0.015 * L)), axes: [mul(across, tummyWidth), mul(v, 0.42 * L), mul(out, 0.36 * L)] },
    { center: sub(H, mul(v, 0.03 * L)), axes: [mul(body.uh, pelvisWidth), mul(v, 0.17 * L), mul(body.wh, 0.31 * L)] },
  ];
  const trunkParts = blobs.map(b => ellipsoid(b.center, b.axes, romper, false));
  shadows.push({ kind: 'hull', parts: blobs });
  const trunkOval = Oval.fromAxes(view.point(add(H, mul(T, 0.42))), [mul(across, 0.42 * L), mul(v, 0.62 * L), mul(out, 0.34 * L)].map(a => view.onScreen(a)));
  const trunkPts = hullPoints(trunkParts.flatMap(p => p.oval.points()));
  parts.push(part(trunkPts, trunkOval, romper, trunkParts.reduce((s, p) => s + p.depth, 0) / trunkParts.length,
    { decal: { kind: 'sprout', spot: add(H, mul(T, 0.50)), east: across, north: v, out, size: 0.37 * L } }));

  const a = anchors(P, body, L);
  const center = a.head, R = a.R, f = a.f, l = a.l, up = a.up;
  const neckPoint = P(MHR.neck);
  const neckBase = finite(neckPoint) ? neckPoint : add(body.shoulders, mul(v, 0.04 * L));
  const neck = capsule(neckBase, a.skullBase, 0.17 * L, 0.16 * L, skin, false);
  const head = ball(center, R, skin);
  const headCenter = head.oval.center, headRadius = head.oval.a;
  head.depth -= 0.08 * L;
  neck.depth = head.depth + 5e-4;
  parts.push(neck);
  head.decal = { kind: 'face', center, R, f, l, up };
  parts.push(head);
  for (const side of [1, -1]) {
    const ear = ball(sub(add(center, mul(l, side * 0.95 * R)), mul(up, 0.08 * R)), 0.22 * R, skin, false);
    ear.depth = head.depth + 1e-4;
    parts.push(ear);
  }
  const tuftBase = add(add(center, mul(up, 0.96 * R)), mul(f, 0.12 * R));
  parts.push(part(null, new Oval({ x: 0, y: 0 }, 0, 1, 1), null, view.view(tuftBase)[2] - 0.25 * R, { decal: { kind: 'tuft', base: tuftBase, R, f, up } }));

  for (const [limb, colour] of [['leftArm', Palette.left], ['rightArm', Palette.right]]) {
    const pc = a.pieces[limb];
    const [s, e] = pc.upper, [e2, w] = pc.lower, [m0, m1] = pc.end;
    const upper = capsule(s, e, 0.115 * L, 0.10 * L, skin);
    const sleeve = capsule(s, add(s, mul(sub(e, s), 0.42)), 0.14 * L, 0.13 * L, romper, false);
    sleeve.depth = upper.depth - 1e-4;
    const forearm = capsule(e2, w, 0.10 * L, 0.085 * L, skin);
    const mitten = capsule(m0, m1, 0.095 * L, 0.115 * L, colour);
    for (const item of [upper, sleeve, forearm, mitten]) { item.limb = limb; parts.push(item); }
  }
  for (const [limb, colour] of [['leftLeg', Palette.left], ['rightLeg', Palette.right]]) {
    const pc = a.pieces[limb];
    const [h, k] = pc.upper, [k2, ankle] = pc.lower, [heel, toes] = pc.end;
    const thigh = capsule(h, k, 0.165 * L, 0.13 * L, skin);
    const hip = view.point(h), r = 0.21 * L * view.scale;
    const opening = part(null, trunkOval, null, thigh.depth - 1e-4, { decal: { kind: 'legOpening', hip, r, thigh: thigh.pts, trunk: trunkPts } });
    const shin = capsule(k2, ankle, 0.13 * L, 0.10 * L, skin);
    const foot = capsule(heel, toes, 0.10 * L, 0.10 * L, colour);
    const cuff = ball(ankle, 0.11 * L, colour, false);
    cuff.depth = Math.min(cuff.depth, foot.depth + 1e-4);
    for (const item of [thigh, opening, shin, foot, cuff]) { item.limb = limb; parts.push(item); }
  }
  return { parts: parts.filter(p => isFinite(p.depth)), shadows, headCenter, headRadius };
}

function spot(c, R, f, l, up, lat, lon) {
  const la = lat * Math.PI / 180, lo = lon * Math.PI / 180;
  const around = add(mul(f, Math.cos(lo)), mul(l, Math.sin(lo)));
  const d = add(mul(around, Math.cos(la)), mul(up, Math.sin(la)));
  const east = unit(add(mul(f, -Math.sin(lo)), mul(l, Math.cos(lo))));
  const north = unit(sub(mul(up, Math.cos(la)), mul(around, Math.sin(la))));
  return { point: add(c, mul(d, R)), normal: d, east, north };
}
const visibility = (view, d) => Math.min(1, Math.max(0, (-view.vec(d)[2] - 0.05) / 0.25));
function towardLight(view, east, north) {
  const e = view.onScreen(east), n = view.onScreen(north), det = e.dx * n.dy - e.dy * n.dx, u = view.scale;
  if (!(Math.abs(det) > 0.05 * u * u)) return null;
  const hx = (screenLight.dx * n.dy - screenLight.dy * n.dx) / det, hy = (e.dx * screenLight.dy - e.dy * screenLight.dx) / det;
  const k = Math.hypot(hx, hy);
  return k > 0 ? { x: hx / k, y: hy / k } : null;
}

/// Draws the figure. Returns { defs, body } — SVG markup with ids prefixed by `id`.
function render({ size, P, radius, shape, floor = null, yaw = 0, pitch = 0, fill = 0.36, center = null, id = 'b', theme = 'light' }) {
  const body = bodyAxes(P);
  if (!body) return { defs: '', body: '' };
  const L = shape.torso;
  const root = add(body.hips, mul(sub(body.shoulders, body.hips), 0.6));
  const scale = Math.min(size.width, size.height) * fill / Math.max(radius, 0.05);
  const view = new Projector(root, yaw, pitch, scale, center ?? { x: size.width / 2, y: size.height / 2 });
  const figure = buildFigure(view, shape, P, body);
  const outline = Math.min(2.2, Math.max(0.8, 0.022 * L * scale));
  const scene = Palette.scene[theme];
  let defs = '', out = '', n = 0;
  const uid = () => `${id}${n++}`;
  const el = (tag, attrs, inner = '') => `<${tag}${Object.entries(attrs).filter(([, v]) => v !== undefined && v !== null).map(([k, v]) => ` ${k}="${v}"`).join('')}>${inner}</${tag}>`;
  const clip = d => { const c = uid(); defs += el('clipPath', { id: c }, el('path', { d })); return c; };
  const shadeFill = (oval, material) => {
    const a = Math.max(oval.a, 0.5), b = Math.max(oval.b, 0.5), big = Math.max(a, b), c = Math.cos(-oval.angle), s = Math.sin(-oval.angle);
    const lx = (screenLight.dx * c - screenLight.dy * s) * 0.42 * big / a, ly = (screenLight.dx * s + screenLight.dy * c) * 0.42 * big / b;
    const g = uid();
    defs += el('radialGradient', { id: g, gradientUnits: 'userSpaceOnUse', cx: f2(lx), cy: f2(ly), r: '1.5', gradientTransform: matrixAttr(oval.transform) },
      el('stop', { offset: '0', 'stop-color': material.light }) + el('stop', { offset: '0.45', 'stop-color': material.base }) + el('stop', { offset: '1', 'stop-color': material.shade }));
    return `url(#${g})`;
  };

  // floor
  if (floor) {
    const facing = -view.vec(floor.normal)[2], alpha = Math.min(1, Math.max(0, facing * 5));
    if (alpha > 0) {
      const transform = offset => { const o = view.point(add(floor.origin, mul(floor.normal, offset))), x = view.onScreen(floor.ex), y = view.onScreen(floor.ey); return [x.dx, x.dy, y.dx, y.dy, o.x, o.y]; };
      const w = floor.size[0], h = floor.size[1], l = L;
      const outlinePts = inset => {
        const x0 = -w / 2 + inset, y0 = -h / 2 + inset, ww = w - 2 * inset, hh = h - 2 * inset;
        if (floor.round) return new Oval({ x: 0, y: 0 }, 0, ww / 2, hh / 2).points(72);
        const r = Math.min(Math.max(0.05 * l, 0.5 * l - inset), ww / 2, hh / 2), pts = [], q = 10;
        const corner = (cx, cy, a0) => { for (let k = 0; k <= q; k++) { const t = a0 + (Math.PI / 2) * k / q; pts.push({ x: cx + r * Math.cos(t), y: cy + r * Math.sin(t) }); } };
        corner(x0 + ww - r, y0 + r, -Math.PI / 2); corner(x0 + ww - r, y0 + hh - r, 0); corner(x0 + r, y0 + hh - r, Math.PI / 2); corner(x0 + r, y0 + r, Math.PI);
        return pts;
      };
      const onTop = transform(0);
      const topD = polyD(outlinePts(0).map(p => applyM(onTop, p)));
      let g = el('path', { d: polyD(outlinePts(0).map(p => applyM(transform(-0.07 * L), p))), fill: scene.matEdge }) + el('path', { d: topD, fill: scene.mat });
      const topClip = clip(topD);
      const step = 0.8 * l, r = 0.07 * l, cnt = Math.ceil(Math.max(w, h) / 2 / step) + 1;
      let dotsA = '', dotsB = '';
      for (let iy = -cnt; iy <= cnt; iy++) for (let ix = -cnt; ix <= cnt; ix++) {
        const x = ix * step + ((iy & 1) === 1 ? step / 2 : 0), y = iy * step;
        if (!(Math.abs(x) <= w / 2 && Math.abs(y) <= h / 2)) continue;
        const d = polyD(new Oval({ x, y }, 0, r, r).points(20).map(p => applyM(onTop, p)));
        if (((ix + iy) & 1) === 0) dotsA += d; else dotsB += d;
      }
      let inside = el('path', { d: dotsA, fill: scene.dotA }) + el('path', { d: dotsB, fill: scene.dotB });
      // shadows
      const near = [], high = [];
      for (const s of figure.shadows) {
        let pts, height;
        if (s.kind === 'ball') { const q = floorShadowPoint(floor, s.c); pts = new Oval(q.point, 0, s.r, s.r).points(32); height = q.height; }
        else if (s.kind === 'capsule') { const qa = floorShadowPoint(floor, s.a), qb = floorShadowPoint(floor, s.b); pts = capsulePoints(qa.point, s.ra, qb.point, s.rb); height = (qa.height + qb.height) / 2; }
        else if (s.kind === 'ellipsoid') { const q = floorShadowPoint(floor, s.c); pts = Oval.fromAxes(q.point, s.axes.map(a => floorShadowVector(floor, a))).points(); height = q.height; }
        else { let all = []; height = 0; for (const p of s.parts) { const q = floorShadowPoint(floor, p.center); all = all.concat(Oval.fromAxes(q.point, p.axes.map(a => floorShadowVector(floor, a))).points()); height += q.height / Math.max(1, s.parts.length); } pts = hullPoints(all); }
        (height < 0.45 * L ? near : high).push(polyD(pts.map(p => applyM(onTop, p))));
      }
      for (const [paths, opacity, blur] of [[near, 0.24, 0.07], [high, 0.13, 0.17]]) {
        if (!paths.length) continue;
        const fid = uid();
        defs += el('filter', { id: fid, x: '-50%', y: '-50%', width: '200%', height: '200%' }, el('feGaussianBlur', { stdDeviation: f2(blur * L * view.scale * 0.6) }));
        inside += el('g', { opacity, filter: `url(#${fid})` }, el('path', { d: paths.join(''), fill: scene.shadow }));
      }
      g += el('g', { 'clip-path': `url(#${topClip})` }, inside);
      g += el('path', { d: polyD(outlinePts(0.15 * l).map(p => applyM(onTop, p))), fill: 'none', stroke: scene.stitch, 'stroke-width': 1.3, 'stroke-linecap': 'round', 'stroke-dasharray': '4 3.5' });
      out += el('g', { opacity: f2(alpha) }, g);
    }
  }

  // parts, far to near
  const order = figure.parts.map((p, i) => [p, i]).sort((x, y) => (y[0].depth - x[0].depth) || (x[1] - y[1])).map(x => x[0]);
  for (const part of order) {
    let d = null;
    if (part.pts && part.material) {
      d = polyD(part.pts);
      out += el('path', { d, fill: shadeFill(part.oval, part.material), stroke: part.material.line, 'stroke-opacity': 0.9, 'stroke-width': f2(outline), 'stroke-linejoin': 'round' });
    }
    const decal = part.decal;
    if (!decal) continue;
    if (decal.kind === 'face' && d) {
      const { center: c, R, f, l, up } = decal, r = R;
      let g = '';
      for (const lon of [48, -48]) {
        const s = spot(c, R, f, l, up, -30, lon), a = visibility(view, s.normal);
        if (!(a > 0)) continue;
        const gid = uid();
        defs += el('radialGradient', { id: gid, gradientUnits: 'userSpaceOnUse', cx: 0, cy: 0, r: f2(0.19 * r * 1000) / 1000 },
          el('stop', { offset: 0, 'stop-color': Palette.blush, 'stop-opacity': f2(0.55 * a) }) + el('stop', { offset: 1, 'stop-color': Palette.blush, 'stop-opacity': 0 }));
        const m = view.patch(s.point, s.east, s.north);
        g += el('g', { transform: matrixAttr([m[0], m[1], m[2] * 0.72, m[3] * 0.72, m[4], m[5]]) }, el('circle', { cx: 0, cy: 0, r: 0.19 * r, fill: `url(#${gid})` }));
      }
      for (const lon of [28, -28]) {
        const s = spot(c, R, f, l, up, -10, lon), a = visibility(view, s.normal);
        if (!(a > 0)) continue;
        const m = view.patch(s.point, s.east, s.north);
        let eye = el('ellipse', { cx: 0, cy: 0, rx: 0.085 * r, ry: 0.105 * r, fill: Palette.ink, 'fill-opacity': f2(a) });
        const h = towardLight(view, s.east, s.north);
        if (h) eye += el('circle', { cx: 0.03 * r * h.x, cy: 0.045 * r * h.y, r: 0.03 * r, fill: '#FFFFFF', 'fill-opacity': f2(0.95 * a) });
        g += el('g', { transform: matrixAttr(m) }, eye);
      }
      const lineWidth = Math.max(1.0, 0.03 * R * view.scale);
      const bez = (m, p0, c1, c2, p1) => { const q = [p0, c1, c2, p1].map(p => applyM(m, p)); return `M${f2(q[0].x)} ${f2(q[0].y)}C${f2(q[1].x)} ${f2(q[1].y)} ${f2(q[2].x)} ${f2(q[2].y)} ${f2(q[3].x)} ${f2(q[3].y)}`; };
      for (const lon of [86, -86]) {
        const s = spot(c, R, f, l, up, -8, lon), a = visibility(view, s.normal);
        if (!(a > 0)) continue;
        const k = lon > 0 ? 1 : -1, m = view.patch(s.point, s.east, s.north);
        g += el('path', { d: bez(m, { x: -0.05 * r * k, y: 0.11 * r }, { x: 0.10 * r * k, y: 0.13 * r }, { x: 0.10 * r * k, y: -0.11 * r }, { x: -0.04 * r * k, y: -0.09 * r }), fill: 'none', stroke: Palette.skin.line, 'stroke-opacity': f2(0.8 * a), 'stroke-width': f2(lineWidth), 'stroke-linecap': 'round' });
      }
      const nose = spot(c, R, f, l, up, -22, 0), na = visibility(view, nose.normal);
      if (na > 0) g += el('g', { transform: matrixAttr(view.patch(nose.point, nose.east, nose.north)) }, el('ellipse', { cx: 0, cy: 0, rx: 0.05 * r, ry: 0.035 * r, fill: Palette.skin.shade, 'fill-opacity': f2(0.9 * na) }));
      const mouth = spot(c, R, f, l, up, -38, 0), ma = visibility(view, mouth.normal);
      if (ma > 0) {
        const m = view.patch(mouth.point, mouth.east, mouth.north), q = [{ x: -0.10 * r, y: 0.035 * r }, { x: 0, y: -0.07 * r }, { x: 0.10 * r, y: 0.035 * r }].map(p => applyM(m, p));
        g += el('path', { d: `M${f2(q[0].x)} ${f2(q[0].y)}Q${f2(q[1].x)} ${f2(q[1].y)} ${f2(q[2].x)} ${f2(q[2].y)}`, fill: 'none', stroke: Palette.mouth, 'stroke-opacity': f2(ma), 'stroke-width': f2(Math.max(1.2, 0.035 * R * view.scale)), 'stroke-linecap': 'round' });
      }
      out += el('g', { 'clip-path': `url(#${clip(d)})` }, g);
    } else if (decal.kind === 'sprout' && d) {
      const a = visibility(view, decal.out);
      if (a > 0) {
        const m = view.patch(add(decal.spot, mul(decal.out, decal.size)), decal.east, decal.north), k = decal.size * 0.32;
        let g = el('path', { d: `M0 ${-0.55 * k}Q${0.05 * k} ${-0.1 * k} 0 ${0.25 * k}`, fill: 'none', stroke: Palette.sprout, 'stroke-width': 0.12 * k, 'stroke-linecap': 'round' });
        for (const side of [1, -1]) g += el('path', { d: `M0 ${0.2 * k}Q${side * 0.15 * k} ${0.75 * k} ${side * 0.65 * k} ${0.6 * k}Q${side * 0.5 * k} ${0.1 * k} 0 ${0.2 * k}Z`, fill: Palette.sprout });
        out += el('g', { 'clip-path': `url(#${clip(d)})` }, el('g', { transform: matrixAttr(m), opacity: f2(0.9 * a) }, g));
      }
    } else if (decal.kind === 'tuft') {
      const { base, R, f, up } = decal;
      const p1 = sub(add(base, mul(up, 0.32 * R)), mul(f, 0.10 * R)), p2 = add(add(base, mul(up, 0.42 * R)), mul(f, 0.30 * R)), p3 = add(add(base, mul(up, 0.16 * R)), mul(f, 0.26 * R));
      const q = [base, p1, p2, p3].map(p => view.point(p));
      const dd = `M${f2(q[0].x)} ${f2(q[0].y)}C${f2(q[1].x)} ${f2(q[1].y)} ${f2(q[2].x)} ${f2(q[2].y)} ${f2(q[3].x)} ${f2(q[3].y)}`;
      const width = Math.max(1.5, 0.075 * R * view.scale);
      out += el('path', { d: dd, fill: 'none', stroke: Palette.hairLine, 'stroke-width': f2(width + outline * 1.6), 'stroke-linecap': 'round' }) + el('path', { d: dd, fill: 'none', stroke: Palette.hair, 'stroke-width': f2(width), 'stroke-linecap': 'round' });
    } else if (decal.kind === 'legOpening') {
      const circle = polyD(new Oval(decal.hip, 0, decal.r, decal.r).points(48)), trunk = polyD(decal.trunk), thigh = polyD(decal.thigh);
      const cTrunk = clip(trunk), cCircle = clip(circle), cThigh = clip(thigh), fillR = shadeFill(part.oval, Palette.romper);
      out += el('g', { 'clip-path': `url(#${cTrunk})` }, el('g', { 'clip-path': `url(#${cCircle})` }, el('path', { d: thigh, fill: fillR, stroke: fillR, 'stroke-width': f2(outline * 1.8), 'stroke-linejoin': 'round' })));
      const line = { fill: 'none', stroke: Palette.romper.line, 'stroke-opacity': 0.9, 'stroke-width': f2(outline), 'stroke-linejoin': 'round' };
      out += el('g', { 'clip-path': `url(#${cThigh})` }, el('g', { 'clip-path': `url(#${cCircle})` }, el('path', Object.assign({ d: trunk }, line))) + el('g', { 'clip-path': `url(#${cTrunk})` }, el('path', Object.assign({ d: circle }, line))));
    }
  }
  return { defs, body: out, headCenter: figure.headCenter, headRadius: figure.headRadius, view };
}

// ---------- poses ----------
/// BabyFigure.restingPose: a baby on its back seen from above, arms in a W, legs a little frog-like.
function restingPose() {
  const p = Array.from({ length: MHR.J }, () => NANV.slice()), z = 0.80;
  p[MHR.leftHip] = [0.040, 0.060, z]; p[MHR.rightHip] = [-0.040, 0.060, z];
  p[MHR.leftShoulder] = [0.068, -0.110, z]; p[MHR.rightShoulder] = [-0.068, -0.110, z];
  const head = [0, -0.185, z - 0.005], forward = unit([0, -0.12, -1]), left = [1, 0, 0];
  p[MHR.leftEar] = add(head, mul(left, 0.05)); p[MHR.rightEar] = sub(head, mul(left, 0.05)); p[MHR.nose] = add(head, mul(forward, 0.065));
  for (const [s, side] of [[1, true], [-1, false]]) {
    const [el, wr, kn, an] = side ? [MHR.leftElbow, MHR.leftWrist, MHR.leftKnee, MHR.leftAnkle] : [MHR.rightElbow, MHR.rightWrist, MHR.rightKnee, MHR.rightAnkle];
    const [knuckle, heel, big, small] = side ? [MHR.leftMiddleKnuckle, MHR.leftHeel, MHR.leftBigToe, MHR.leftSmallToe] : [MHR.rightMiddleKnuckle, MHR.rightHeel, MHR.rightBigToe, MHR.rightSmallToe];
    p[el] = [s * 0.132, -0.058, z - 0.01]; p[wr] = [s * 0.140, -0.138, z - 0.03]; p[knuckle] = [s * 0.138, -0.172, z - 0.035];
    p[kn] = [s * 0.092, 0.138, z - 0.05]; p[an] = [s * 0.068, 0.214, z - 0.03];
    const toe = unit([s * 0.15, 0.8, -0.6]);
    p[heel] = sub(p[an], mul(toe, 0.015));
    p[big] = sub(add(p[an], mul(toe, 0.06)), mul(left, 0.008));
    p[small] = add(add(p[an], mul(toe, 0.05)), mul(left, 0.018));
  }
  return p;
}

module.exports = { render, restingPose, measure, makeMat, bodyAxes, MHR, Palette, add, sub, mul, dot, cross, len, unit, finite, NANV, Projector };
