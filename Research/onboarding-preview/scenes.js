// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
'use strict';
// The onboarding's illustrations as SVG, composed exactly as OnboardingArt.swift composes them
// (same poses, views, sizes and offsets), from the port of the app's baby figure.
const B = require('./babyfigure.js'), S = require('./poses.js');
const rad = d => d * Math.PI / 180;
const C = { sage: '#4F6B4C', sageSoft: '#DCE6D3', blush: '#E59C98', blushSoft: '#F8E1DE', gold: '#A8843E', paper: '#FBF8F4', card: '#F3ECE2', ink: '#3B332D', green: '#34C759', second: '#8A8580' };
let seq = 0;
const nid = p => `${p}${seq++}_`;

/// A scene: background gradient + mat + baby, clipped to a rounded rectangle. Returns {defs, body}.
function scene({ w, h, t = null, turn = 0, yaw = 0, pitch = 0, fill = 0.36, dx = 0, dy = 0, mat = true, corner = 0, background = true, camera = false }) {
  const id = nid('s');
  const p = S.turned(S.pose(t), turn);
  const r = B.render({ size: { width: w, height: h }, P: j => p[j], radius: S.radius, shape: S.shape, floor: mat ? S.mat(turn) : null,
    yaw, pitch, fill, center: { x: w * (0.5 + dx), y: h * (0.5 + dy) }, id });
  let defs = r.defs + `<linearGradient id="${id}bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${camera ? C.sageSoft : '#EEF5E8'}"></stop><stop offset="1" stop-color="${camera ? C.card : '#FBF6EE'}"></stop></linearGradient>`
    + `<clipPath id="${id}cl"><rect x="0" y="0" width="${w}" height="${h}" rx="${corner}" ry="${corner}"></rect></clipPath>`;
  const body = `<g clip-path="url(#${id}cl)">${background ? `<rect x="0" y="0" width="${w}" height="${h}" fill="url(#${id}bg)"></rect>` : ''}${r.body}</g>`;
  return { defs, body, view: r.view };
}
const place = (x, y, s) => `<g transform="translate(${x} ${y})">${s.body}</g>`;
const svgWrap = (w, h, defs, body, label) => `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" viewBox="0 0 ${w} ${h}" role="img" aria-label="${label}"><defs>${defs}</defs>${body}</svg>`;

/// Viewfinder as in RecordView: a 9:16 preview with the dashed guide (green when ready).
function viewfinder({ w, good, t = 0.9, recorder = false }) {
  const h = w * 16 / 9, corner = recorder ? 24 : w * 0.1;
  const s = good ? scene({ w, h, t, fill: 0.50, dy: 0.0, corner, camera: true }) : scene({ w, h, t, fill: 0.74, dx: 0.20, dy: 0.22, corner, camera: true });
  const ix = w * 30 / 310, iy = w * 42 / 310, gr = recorder ? 24 : corner * 0.8, dash = recorder ? '8 7' : '6 5';
  const rect = (stroke, width, opacity) => `<rect x="${ix}" y="${iy}" width="${w - 2 * ix}" height="${h - 2 * iy}" rx="${gr}" ry="${gr}" fill="none" stroke="${stroke}" stroke-opacity="${opacity}" stroke-width="${width}" stroke-dasharray="${dash}"></rect>`;
  const guide = good ? rect(C.green, 2, 1) : rect('#000000', 3.4, 0.16) + rect('#FFFFFF', 2, recorder ? 0.85 : 1);
  const rim = `<rect x="0.5" y="0.5" width="${w - 1}" height="${h - 1}" rx="${corner}" ry="${corner}" fill="none" stroke="${C.ink}" stroke-opacity="0.10"></rect>`;
  return { defs: s.defs, body: s.body + guide + (recorder ? '' : rim), w, h };
}

// ---- Art 1: record here, or bring videos from Photos ----
function artWays({ w = 326, h = 268, time = '0:12', duration = '0:42' } = {}) {
  let defs = '', body = '';
  // phone
  const pw = 138, ph = 262, px = 8, py = 3, sw = 122, sh = 246;
  body += `<rect x="${px}" y="${py}" width="${pw}" height="${ph}" rx="26" ry="26" fill="#FFFDF9" stroke="${C.sage}" stroke-opacity="0.35" stroke-width="1.5"></rect>`;
  const s = scene({ w: sw, h: sh, t: 1.3, fill: 0.50, dy: 0.03, corner: 19, camera: true });
  defs += s.defs; body += place(px + 8, py + 8, s);
  // recording pill
  body += `<g transform="translate(${px + pw / 2 - 26} ${py + 18})"><rect x="0" y="0" width="52" height="20" rx="10" ry="10" fill="#000000" fill-opacity="0.45"></rect><circle cx="12" cy="10" r="4" fill="#FF453A"></circle><text x="21" y="14" font-family="-apple-system, 'SF Pro Text', 'Helvetica Neue', Arial, sans-serif" font-size="11" font-weight="600" fill="#FFFFFF">${time}</text></g>`;
  // album stack
  const tx = 184, ty = 74, ts = 118;
  const thumbs = [{ rot: -9, ox: -18, oy: 14, t: 0.2 }, { rot: 8, ox: 18, oy: -22, t: 2.0 }, { rot: 0, ox: 0, oy: 0, t: 0.9 }];
  thumbs.forEach((th, i) => {
    const sc = scene({ w: ts, h: ts, t: th.t, fill: 0.40, dy: 0.03, corner: 14, camera: true });
    defs += sc.defs;
    const front = i === thumbs.length - 1;
    body += `<g transform="translate(${tx + th.ox} ${ty + th.oy}) rotate(${th.rot} ${ts / 2} ${ts / 2})"><rect x="-4" y="-4" width="${ts + 8}" height="${ts + 8}" rx="17" ry="17" fill="#FFFFFF" stroke="${C.ink}" stroke-opacity="0.08"></rect>${sc.body}`
      + (front ? `<g transform="translate(${ts - 44} ${ts - 24})"><rect x="0" y="0" width="38" height="18" rx="9" ry="9" fill="#000000" fill-opacity="0.55"></rect><text x="19" y="13" text-anchor="middle" font-family="-apple-system, 'SF Pro Text', 'Helvetica Neue', Arial, sans-serif" font-size="10.5" font-weight="600" fill="#FFFFFF">${duration}</text></g>`
        + `<g transform="translate(8 8)"><circle cx="10" cy="10" r="10" fill="${C.sage}" stroke="#FFFFFF" stroke-width="1.5"></circle><path d="M5.6 10.3 L8.8 13.3 L14.6 7.2" fill="none" stroke="#FFFFFF" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"></path></g>` : '')
      + `</g>`;
  });
  return { svg: svgWrap(w, h, defs, body, 'A phone recording a baby on a mat, next to videos chosen from Photos'), w, h };
}

// ---- Art 2: not yet / all set ----
function artFraming({ vw = 148 } = {}) {
  const a = viewfinder({ w: vw, good: false }), b = viewfinder({ w: vw, good: true });
  return { bad: svgWrap(a.w, a.h, a.defs, a.body, 'Too close: a hand and a foot are outside the picture'), good: svgWrap(b.w, b.h, b.defs, b.body, 'The whole baby is in the middle of the picture'), w: vw, h: a.h };
}

// ---- Art 3: the phone can be anywhere on the arc ----
function artAngles({ w = 326, h = 286 } = {}) {
  const turn = rad(-70), pitch = rad(-58);
  const s = scene({ w, h, t: 0.9, turn, pitch, fill: 0.27, dx: 0, dy: 0.20, corner: 22 });
  const c = { x: w * 0.5, y: h * 0.70 };                         // the tummy
  const R = h * 0.56;
  let o = '', defs = s.defs;
  const arcPt = deg => ({ x: c.x + R * Math.cos(rad(deg - 90)), y: c.y + R * Math.sin(rad(deg - 90)) });
  const a0 = arcPt(-54), a1 = arcPt(54);
  o += `<path d="M${a0.x.toFixed(1)} ${a0.y.toFixed(1)} A${R} ${R} 0 0 1 ${a1.x.toFixed(1)} ${a1.y.toFixed(1)}" fill="none" stroke="${C.sage}" stroke-opacity="0.5" stroke-width="2" stroke-linecap="round" stroke-dasharray="1 7"></path>`;
  [-40, 0, 40].forEach((deg, i) => {
    const p = arcPt(deg), main = deg === 0, gid = nid('cone');
    defs += `<linearGradient id="${gid}" gradientUnits="userSpaceOnUse" x1="${p.x.toFixed(1)}" y1="${p.y.toFixed(1)}" x2="${c.x}" y2="${c.y}"><stop offset="0" stop-color="${C.sage}" stop-opacity="${main ? 0.22 : 0.14}"></stop><stop offset="0.85" stop-color="${C.sage}" stop-opacity="0"></stop></linearGradient>`;
    const e0 = { x: c.x - 70, y: c.y + 6 }, e1 = { x: c.x + 70, y: c.y + 6 };
    o += `<path d="M${p.x.toFixed(1)} ${p.y.toFixed(1)} L${e0.x} ${e0.y} L${e1.x} ${e1.y} Z" fill="url(#${gid})"></path>`;
  });
  for (const deg of [-40, 0, 40]) {
    const p = arcPt(deg);
    o += `<g transform="translate(${p.x.toFixed(1)} ${p.y.toFixed(1)}) rotate(${deg})"><rect x="-21" y="-6" width="42" height="12" rx="4.5" ry="4.5" fill="#FFFDF9" stroke="${C.ink}" stroke-opacity="0.75" stroke-width="1.5"></rect><rect x="-15" y="5" width="9" height="4" rx="2" ry="2" fill="${C.ink}" fill-opacity="0.75"></rect></g>`;
  }
  return { svg: svgWrap(w, h, defs, s.body + o, 'A baby on a mat with the phone held straight above or a little to either side'), w, h };
}

module.exports = { scene, viewfinder, artWays, artFraming, artAngles, svgWrap, place, C };
