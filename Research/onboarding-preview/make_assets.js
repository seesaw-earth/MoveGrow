// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
// Renders every picture the design preview needs as SVG (then PNG @3x by rsvg-convert).
const A = require('./scenes.js'), fs = require('fs');
const out = "assets"; fs.mkdirSync(out, { recursive: true });
const save = (name, w, h, s) => { fs.writeFileSync(`${out}/${name}.svg`, A.svgWrap(w, h, s.defs, s.body, name)); console.log(name, w, h); };
// page 1
save('phone', 122, 246, A.scene({ w: 122, h: 246, t: 1.3, fill: 0.50, dy: 0.03, corner: 19, camera: true }));
[['thumb_a', 0.2], ['thumb_b', 2.0], ['thumb_c', 0.9]].forEach(([n, t]) => save(n, 118, 118, A.scene({ w: 118, h: 118, t, fill: 0.40, dy: 0.03, corner: 14, camera: true })));
// page 2 and the tips
for (const good of [false, true]) { const v = A.viewfinder({ w: 148, good }); save(good ? 'vf_good' : 'vf_bad', v.w, v.h, v); }
// page 3
const a3 = A.artAngles(); fs.writeFileSync(`${out}/angles.svg`, a3.svg); console.log('angles', a3.w, a3.h);
// empty album
save('first', 326, 190, A.scene({ w: 326, h: 190, t: null, fill: 0.42, dy: -0.02, corner: 14, camera: true }));
// the recorder's camera picture (310 wide)
for (const good of [false, true]) { const v = A.viewfinder({ w: 310, good, recorder: true, t: 1.7 }); save(good ? 'cam_good' : 'cam_bad', v.w, v.h, v); }
