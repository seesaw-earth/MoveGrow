/* MoveGrow website — Copyright (C) 2026 Ziqing Shi — SPDX-License-Identifier: AGPL-3.0-only
   The hero: a simulated baby from MoveGrow's test data (window.MG_MOTION: 15 fps keypoints and the
   per-limb speed the app computes from them), drawn the way the app draws it, with the
   arm and leg speed traces underneath and a cursor that moves with it. With reduced motion it is
   a single still frame. */
(function () {
  "use strict";
  var data = window.MG_MOTION;
  var canvas = document.getElementById("hero-canvas");
  if (!data || !canvas || !canvas.getContext) return;
  var ctx = canvas.getContext("2d");
  var reduce = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var pills = Array.prototype.slice.call(document.querySelectorAll("[data-limb]"));
  var clockEl = document.getElementById("hero-time");
  var css = getComputedStyle(document.documentElement);
  function v(name, fallback) { return (css.getPropertyValue(name) || "").trim() || fallback; }
  var colors = { L_arm: v("--l-arm", "#5AA0F0"), R_arm: v("--r-arm", "#F28A5E"), L_leg: v("--l-leg", "#3CC992"), R_leg: v("--r-leg", "#F2B632") };
  var mint = "#BFE0AE";
  var labels = { arms: canvas.getAttribute("data-arms") || "Arms", legs: canvas.getAttribute("data-legs") || "Legs" };
  var fps = data.fps, frames = data.frames, span = frames.length / fps;
  var startAt = data.start || 0;

  // COCO-17 order: nose, eyes, ears, shoulders, elbows, wrists, hips, knees, ankles; 17 = neck, 18 = root.
  var bones = [[3, 1], [1, 0], [0, 2], [2, 4], [0, 17], [17, 18], [17, 5], [17, 6], [5, 7], [7, 9], [6, 8], [8, 10],
               [18, 11], [18, 12], [11, 13], [13, 15], [12, 14], [14, 16]];
  var ends = { 9: 1, 10: 1, 15: 1, 16: 1 };

  function point(f, j) {
    if (!f || !f.length) return null;
    if (j === 17 || j === 18) {
      var a = j === 17 ? 5 : 11, b = j === 17 ? 6 : 12;
      var p = point(f, a), q = point(f, b);
      return p && q ? [(p[0] + q[0]) / 2, (p[1] + q[1]) / 2] : null;
    }
    var x = f[2 * j], y = f[2 * j + 1];
    return x < 0 || y < 0 ? null : [x, y];
  }

  function pose(t) {
    var k = t * fps, i = Math.floor(k), w = k - i;
    var a = frames[i % frames.length], b = frames[(i + 1) % frames.length];
    if (!a || !a.length) return b;
    if (!b || !b.length || i + 1 >= frames.length) return a;
    var out = [];
    for (var n = 0; n < a.length; n++) out.push(a[n] < 0 || b[n] < 0 ? a[n] : a[n] + (b[n] - a[n]) * w);
    return out;
  }

  // The area the baby moves in over the whole clip, in a 9:16 frame's units, so the skeleton can
  // be shown large and steady rather than small in the middle of the recording's frame.
  var box = (function () {
    var x0 = 1e9, y0 = 1e9, x1 = -1e9, y1 = -1e9;
    frames.forEach(function (f) {
      for (var j = 0; j < 17; j++) {
        var p = point(f, j); if (!p) continue;
        x0 = Math.min(x0, p[0] * 9); x1 = Math.max(x1, p[0] * 9);
        y0 = Math.min(y0, p[1] * 16); y1 = Math.max(y1, p[1] * 16);
      }
    });
    return x1 > x0 ? { x: x0, y: y0, w: x1 - x0, h: y1 - y0 } : { x: 0, y: 0, w: 9, h: 16 };
  })();

  var W = 0, H = 0, dpr = 1;
  function resize() {
    var r = canvas.getBoundingClientRect();
    dpr = Math.min(window.devicePixelRatio || 1, 2.5);
    W = Math.max(1, r.width); H = Math.max(1, r.height);
    canvas.width = Math.round(W * dpr); canvas.height = Math.round(H * dpr);
  }

  function clock(s) { s = Math.max(0, Math.floor(s)); return Math.floor(s / 60) + ":" + ("0" + (s % 60)).slice(-2); }

  function draw(t) {
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, W, H);
    var chartH = Math.min(H * 0.34, 150), gap = 10;
    var bodyH = H - chartH - gap;

    // Fit the clip's movement area into the space above the charts; a soft "blanket" behind it.
    var pad = 22, k = Math.min((W - 2 * pad) / box.w, (bodyH - 2 * pad) / box.h);
    var ox = (W - box.w * k) / 2 - box.x * k, oy = (bodyH - box.h * k) / 2 - box.y * k;
    var g = ctx.createRadialGradient(W / 2, bodyH * 0.5, 10, W / 2, bodyH * 0.5, bodyH * 0.6);
    g.addColorStop(0, "rgba(191,224,174,0.10)"); g.addColorStop(1, "rgba(191,224,174,0)");
    ctx.fillStyle = g; ctx.fillRect(0, 0, W, bodyH);

    var f = pose(t);
    function P(j) { var p = point(f, j); return p ? [ox + p[0] * 9 * k, oy + p[1] * 16 * k] : null; }
    var s = Math.max(0.9, Math.min(1.7, box.h * k / 260));
    ctx.lineCap = "round"; ctx.lineJoin = "round";
    [[7 * s, "rgba(0,0,0,0.35)"], [4 * s, mint]].forEach(function (pass) {
      ctx.beginPath();
      bones.forEach(function (bn) { var p = P(bn[0]), q = P(bn[1]); if (p && q) { ctx.moveTo(p[0], p[1]); ctx.lineTo(q[0], q[1]); } });
      ctx.lineWidth = pass[0]; ctx.strokeStyle = pass[1]; ctx.stroke();
    });
    for (var j = 0; j < 17; j++) {
      var p = P(j); if (!p) continue;
      var r = (ends[j] ? 5.5 : 3.6) * s;
      ctx.beginPath(); ctx.arc(p[0], p[1], r, 0, Math.PI * 2);
      ctx.fillStyle = "#fff"; ctx.fill(); ctx.lineWidth = 1.8 * s; ctx.strokeStyle = "#4F6B4C"; ctx.stroke();
    }

    // Arm and leg speed over the clip (solid = left, dashed = right); the part to come is faded.
    ctx.font = "600 11px " + getComputedStyle(document.body).fontFamily;
    var labelW = Math.ceil(Math.max(ctx.measureText(labels.arms).width, ctx.measureText(labels.legs).width)) + 14;
    var top = H - chartH, cw = W - labelW, rowH = (chartH - 16) / 2;
    var bins = data.speed.L_arm.length, scale = data.scale * 1.1;
    var cx = labelW + (t / span) * cw;
    [["arms", ["L_arm", "R_arm"]], ["legs", ["L_leg", "R_leg"]]].forEach(function (row, ri) {
      var y0 = top + ri * (rowH + 8);
      ctx.fillStyle = "rgba(191,224,174,0.07)";
      roundRect(labelW, y0, cw, rowH, 6); ctx.fill();
      ctx.fillStyle = "rgba(230,239,225,0.62)";
      ctx.textAlign = "right"; ctx.textBaseline = "middle"; ctx.fillText(labels[row[0]], labelW - 8, y0 + rowH / 2);
      row[1].forEach(function (key, li) {
        var vals = data.speed[key];
        ctx.beginPath(); var on = false;
        for (var q = 0; q < bins; q++) {
          var val = vals[q]; if (val < 0) { on = false; continue; }
          var x = labelW + (q + 0.5) / bins * cw, y = y0 + rowH - Math.min(1, val / scale) * (rowH - 4) - 2;
          if (on) ctx.lineTo(x, y); else { ctx.moveTo(x, y); on = true; }
        }
        ctx.setLineDash(li ? [5, 4] : []); ctx.lineWidth = 2; ctx.strokeStyle = colors[key]; ctx.stroke(); ctx.setLineDash([]);
      });
      ctx.fillStyle = "rgba(28,42,26,0.62)";
      if (cx < labelW + cw) ctx.fillRect(cx, y0 - 1, labelW + cw - cx + 1, rowH + 2);
    });
    ctx.strokeStyle = "rgba(242,247,238,0.9)"; ctx.lineWidth = 1.5;
    ctx.beginPath(); ctx.moveTo(cx, top - 4); ctx.lineTo(cx, H - 2); ctx.stroke();

    // Read-out: the time and which limbs are moving now.
    var bin = Math.min(bins - 1, Math.floor(t / span * bins));
    pills.forEach(function (el) { el.classList.toggle("on", data.active[el.getAttribute("data-limb")][bin] === 1); });
    if (clockEl) clockEl.textContent = clock(startAt + t);
  }

  function roundRect(x, y, w, h, r) {
    ctx.beginPath(); ctx.moveTo(x + r, y); ctx.arcTo(x + w, y, x + w, y + h, r); ctx.arcTo(x + w, y + h, x, y + h, r);
    ctx.arcTo(x, y + h, x, y, r); ctx.arcTo(x, y, x + w, y, r); ctx.closePath();
  }

  resize();
  window.addEventListener("resize", function () { resize(); if (reduce) draw(span * 0.4); });
  if (reduce) { draw(span * 0.4); return; }

  // Runs only while the panel is on screen (and the tab is visible).
  var visible = true, running = false, t0 = null;
  function start() { if (!running) { running = true; requestAnimationFrame(tick); } }
  function tick(now) {
    if (!visible) { running = false; return; }
    if (t0 === null) t0 = now;
    draw(((now - t0) / 1000) % span);
    requestAnimationFrame(tick);
  }
  if ("IntersectionObserver" in window) {
    new IntersectionObserver(function (es) { visible = es[0].isIntersecting; if (visible) start(); }).observe(canvas);
  }
  start();
})();
