# InstantHMR — the default pose engine

MoveGrow analyses videos with **InstantHMR** (3D, MHR body model) by default. **YOLO26l-pose** (2D) is the
alternative in **Settings → Pose engine**, and the automatic fallback when the InstantHMR models are not in
the build.

## Models: nothing to copy

The build phase *Bundle InstantHMR Models* (`Scripts/bundle-instanthmr.sh`) compiles the models straight
from the folder the Colab conversion was unzipped to, **`~/Downloads/coreml`** (build setting
`INSTANTHMR_MODELS_DIR`), into the app bundle, and recompiles only what changed. If the folder is missing, a
development build goes on and the app analyses with YOLO; **an archive stops** with an error, so a release
cannot ship without InstantHMR by accident (set `INSTANTHMR_OPTIONAL=YES` to archive a YOLO-only build).

**Only the Medium model is shipped.** Small, Tiny and Nano are never compiled; copies left in the build
folder by earlier builds are deleted, and the build fails if one is placed inside the project. Their
checkpoints are non-commercial only (see Licences).

Files unzipped from a browser download carry the `com.apple.quarantine` attribute, which the Core ML
compiler copies onto `weight.bin`; App Store Connect rejects such uploads (TMS-91109). The script removes it
from every compiled model, and the last build phase, *Strip Quarantine Attributes*
(`Scripts/strip-quarantine.sh`), removes it from the whole app and fails the build if any is left.

| File in that folder | Needed | What it is |
|---|---|---|
| `InstantHMRMediumNet.mlpackage` | yes | the network: crop → body parameters + 2D keypoints. Convert it from the **`medium_commercial`** checkpoint |
| `InstantHMRFit2.mlpackage` | yes (archive) | kinematic fit with 2 crops (default) |
| `InstantHMRFit1.mlpackage` | optional | kinematic fit with 1 crop (faster) |
| `MHRBodyKeypoints.mlpackage` | yes | MHR body model: parameters → 70 keypoints in 3D |

Ignored: `InstantHMRSmallNet`, `InstantHMRTinyNet`, `InstantHMRNanoNet` (not shipped), `yolo26n` (the person
box comes from the bundled YOLO26l-pose), the `FP16` fits, `MHRBodyMesh`, `mhr_faces.npy`, `reference_*`,
`verify_mac.py`.

## Settings (defaults)

- Engine: InstantHMR. Model: Medium (the only size; no setting). Kinematic fit: 2 crops. Frames per second: 30
  (15 / 30 / 60).
- A video's analysis passes always use the settings its first pass used (they are part of the estimator ID,
  e.g. `instanthmr-medium-fit2-r30`).
- Videos analysed with YOLO (or v1.0) are treated as new videos: while InstantHMR is the engine they are analysed
  again automatically, from a clean slate (their earlier pose files, summary and observations are deleted first;
  notes, dates and milestones stay).
- Videos made with other InstantHMR settings keep their results until analysed again: **Memories → Select →
  Analyse again**, **Settings → Pose engine → Analyse them again**, or **⋯ → Analyse again** on one video.
  Videos analysed in development builds with Small, Tiny or Nano are treated like YOLO videos: analysed again
  with Medium automatically.

## What runs, per analysed frame

YOLO26l-pose finds the largest person → InstantHMR crops it (1 or 2 crops, InstantHMR's crop and CLIFF vector)
→ network on the Neural Engine → one-step kinematic fit → 70 MHR keypoints in the camera frame (focal length
1.05 × frame diagonal). The first pass runs at 15 frames per second for quick results; the second fills in up
to the chosen rate, with checkpoints so it can resume.

Stored per video, next to the 2D track:
- `<id>.raw.mgpose` / `<id>.mgpose`: MoveGrow's 19 joints from InstantHMR's 2D projection (InstantHMR tracks are
  not One-Euro smoothed; the model is already steady). Everything that reads 2D tracks (video
  exports, observation rules, movement summary) keeps working.
- `<id>.hmr3d`: the 3D track (70 keypoints, 2D projection, uncertainty, box; from format version 2 also
  YOLO26l-pose's own 19 keypoints of the same person, for ⋯ → YOLO pose — not used in the analysis).
  Export: 3D tab → **Export 3D data (JSON)**, or ⋯ → Files → **3D pose data (JSON)**.
- `<id>.review.json`: the kinematics (below), computed from the 3D track.

## 3D tab: baby figure (`MoveGrow/Features/Pose/BabyFigure.swift`)

The review screen's 3D tab (after Kinematics) shows the 3D track as a soft, toy-like baby that follows the
video. The figure is drawn from the keypoints: every joint is where the analysis put it, and only the body's
thickness is the app's (all sizes are fractions of the video's median shoulder-to-hip distance). The
Summary tab's Activity card draws the same baby in a resting pose, each limb glowing by its share of time
moving. No 2D skeleton is shown by default anywhere; ⋯ → YOLO pose draws YOLO26l-pose's own keypoints over
the video on request.

- Proportions follow a baby's skeleton, measured per video (medians): torso length (shoulders to hips),
  shoulder width and hip width.
- Head: a big sphere (radius 0.45 torso lengths) with the ear canals low and towards the back (centre 0.22 R
  above and 0.08 R in front of them), facing where the nose points; eyes, cheeks, nose, smile and ear curls
  are drawn on its surface and turn with it. One curl of hair on top.
- Neck: short and chubby, from MHR's neck point (base of the neck) to the base of the skull (below and behind
  the ears). Painted trunk → neck → head.
- Trunk (mint romper, short sleeves): the convex hull of three ellipsoids — the shoulder girdle (as wide as
  the shoulders, its top from the acromions), a round tummy, and the pelvis around the hip joints — each
  turned with its own line. The arms leave it at the upper corners and the legs at the lower ones; no waist.
- Hips: the thigh starts at the hip joint. Where its root lies over the trunk it is covered again with
  romper, and the edge of the leg opening is drawn across the thigh, so legs leave the romper instead of
  ending in a ball.
- Chubby tapered capsules for arms and legs; mittens point along the hand (base of the middle finger,
  drawing only); socks run heel → toes.
- Sides: mittens and socks are blue on the baby's left and coral on the right (pastels of the app's
  left/right colours).
- Scene: a mat for "On back" and "Tummy time", a round rug for "Sitting", "Standing" and "Walking", nothing
  for "Being held" and "Other". Its plane is fixed for the whole video: normal = mean out-of-chest (lying)
  or mean head-ward axis (upright), through the lowest body point (10th percentile). Soft shadows from a
  fixed light: lifted hands and feet cast lighter, softer shadows further away. Viewed from behind the
  mat, it fades out.
- Rendering: SwiftUI Canvas, orthographic, parts painted far to near (outlines, radial shading). No 3D
  engine, no extra model or licence.
- Hands and feet by the head: painting by centres would flip a hand next to the head in front and behind
  with every small movement. Each limb piece that overlaps the head keeps its side instead: its depth
  relative to the head's centre is averaged over ±0.17 s; it goes behind only when more than 0.12 torso
  lengths deeper, and comes back in front once no longer deeper than the centre. Decided over the 2 s
  before the frame, so playing and scrubbing look the same (`BabyFigure.headOrder`).

## Research export (3D JSON)

`<id>.instanthmr3d.json`, written only when shared: `header` (estimator ID, network, fit crops, frame rate,
duration, analysed frame size, focal length, joint names, coordinate conventions) and one entry per analysed
frame: `t` (s), `person`, `box` (x, y, w, h normalized, score), `joints2D` (70 × [x, y], normalized display
coordinates), `joints3D` (70 × [x, y, z], metres, camera frame: x right, y down, z forward), `sigma` (70, 2D
uncertainty) and, when recorded, `yolo2D` (19 × [x, y, confidence], YOLO26l-pose).

## Kinematics from 3D (`MoveGrow/InstantHMR/HMRKinematics.swift`)

Body joints only; finger points are never used in the analysis. Body frame per frame: torso centroid, u to
the baby's left, v cranial, w out of the chest; lengths in torso lengths. Same fields as before, now in 3D —
limb speeds and activity, elbow and knee angles, head direction, balance, overall movement — plus:

- **Hips**: shoulder–hip–knee angle (180 = in line with the trunk).
- **Hands ↑ / Feet ↑**: height in front of the torso plane (towards the camera when lying on the back).
- **Hands ↔**: distance between the wrists; share of time closer than 0.3 torso lengths.
- **Legs ⇄**: correlation of left and right knee motion over ~2 s (+1 together, −1 alternating).
- **Sync**: mean correlation of the four limb speeds over ~2 s.

They appear in the review timeline and in the Growth tab (Lift, Hip range, Coordination).

## Licences

- InstantHMR code: Apache-2.0. Its checkpoints are under Meta's SAM License; **nano, tiny, small and medium are
  non-commercial only**. `medium_commercial` (same HGNetV2-B4 backbone, trained on commercially licensed
  images) is the one that permits commercial use, so the App Store build should be converted from it (it is
  less accurate: 3DPW PA-MPJPE 50.7 mm vs 40.0 mm). Using plain `medium` in a public App Store release needs
  its own legal clearance.
- The SAM License requires a copy of it to go with the weights: `MoveGrow/Licenses/SAM-License.txt`, shown in
  Settings → Open source & licences. It also forbids reverse engineering the weights and some end uses
  (military, weapons …); see the text.
- MHR body model: © Meta Platforms, Inc. and affiliates, Apache-2.0 (`MoveGrow/Licenses/Apache-2.0.txt`).
- `*.mlpackage` is in `.gitignore`, so the models are never published with the source.
