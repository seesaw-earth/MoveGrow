# MoveGrow 1.2 — App Store / AGPL submission candidate

**MoveGrow: Baby Milestones** is a private, parent-facing iPhone video journal for recording a baby's movement, visualizing a single-person skeleton, reviewing descriptive movement summaries, and organizing parent-confirmed milestone moments.

Copyright © 2026 Ziqing Shi.

## License

MoveGrow is distributed under the **GNU Affero General Public License v3.0 (AGPL-3.0)**. See `LICENSE` and `THIRD_PARTY_NOTICES.md`.

The project uses the official `UltralyticsYOLO` Swift package pinned to **8.9.15** and the official **YOLO26l-pose** Core ML model under the AGPL open-source path. Before public App Store release, read `LICENSE_COMPATIBILITY_NOTE.md`; source release and App Store license compatibility are related but separate questions.

## Open in Xcode

1. Open `MoveGrow.xcodeproj` in the Apple-required current Xcode version.
2. Let Xcode resolve `UltralyticsYOLO` 8.9.15.
3. Select your Apple Developer team under Signing & Capabilities.
4. Confirm Bundle ID `com.ziqingshi.movegrow` is available/registered for your team.
5. Build. The `Bundle YOLO Pose Model` build phase downloads the pinned model on the developer Mac, verifies SHA-256, compiles it, and puts it in the app bundle.

The installed app does **not** need to download the YOLO model at first use. Video frames, pose data, reports and milestone records stay on-device unless the user explicitly exports them.

Pose engine: InstantHMR (3D) by default when its models are present at build time, YOLO26l-pose (2D) as the alternative and fallback — see `INSTANTHMR.md`.

## App identity

- Display name: **MoveGrow**
- App Store name: **MoveGrow: Baby Milestones**
- Version/build: **1.2 (3)** — see `CHANGES.md`
- Bundle ID: `com.ziqingshi.movegrow`
- Developer/seller for the current individual account: **Ziqing Shi**

## Important positioning

MoveGrow produces descriptive movement visualization and organization. It is **not** a developmental screening test, diagnosis, treatment recommendation, or medical device.

## Public source and support

Planned public repository: `https://github.com/seesaw-earth/MoveGrow`

After GitHub Pages is enabled from `/docs` on the `main` branch:

- Privacy: `https://seesaw-earth.github.io/MoveGrow/privacy.html`
- Support: `https://seesaw-earth.github.io/MoveGrow/support.html`
- Marketing/home: `https://seesaw-earth.github.io/MoveGrow/`

Tag the exact App Store build (recommended tag: `v1.0.0`) before public release. See `APP_STORE_SUBMISSION.md`.

## How analysis works (1.2)

```
record / import (≤10 videos, ≤20 min) ─► quick pass (~15 fps) ─► review, suggestions, posture checks (seconds)
                                       └► full pass (native fps, resumable) ─► rhythm checks        (background)
pose tracks: <id>.raw.mgpose / <id>.mgpose   observations: <id>.motor.json   review digest: <id>.review.json
```

- `MoveGrow/Features/Onboarding/`: welcome pages, recording tips, the empty album's first-video card and the recorder's framing checklist; the pictures are drawn with the baby figure (see `Research/onboarding-preview`).
- `MoveGrow/Features/Review/`: the review player (skeleton, parameter timeline, activity map, navigator) and the visual cards.
- `MoveGrow/Features/Growth/KinematicTrendsView.swift`: kinematic parameters across videos and days.
- `MoveGrow/Features/Processing/`: the processing ring (pill and large ring); `Services/BatchImport.swift`.
- `MoveGrow/Models/L10n.swift`, `MoveGrow/Localizable.xcstrings`, `MoveGrow/InfoPlist.xcstrings`: English, 简体中文 and Español, switchable in the app (`Checks/l10n-check.py` keeps them complete).
- `MoveGrow/Features/Growth/GrowthExport.swift`: Growth charts as one PNG (share or save to Photos).
- `MoveGrow/Models/VideoDate.swift` + `Features/Results/VideoDateSheet.swift`: filming dates (from the file, a day, days after birth, or roughly).
- `MoveGrow/Services/ReviewExport.swift` (layout, tested on Linux) + `ReviewVideoExporter.swift` (AVFoundation / Core Graphics) + `Features/Results/ExportVideoSheet.swift`: MP4 export with skeleton, charts and date. See `Previews/export-preview.png`.

- `MoveGrow/Services/VideoAnalyzer.swift`: decode and inference on two threads (`PoseNet` = direct Core ML).
- `MoveGrow/Services/LocalStore+Analysis.swift`: the queue (pre-emption, checkpoints, retries).
- `MoveGrow/Services/BackgroundWork.swift`: background time (iOS 26 continued tasks, BGProcessingTask while charging).
- `MoveGrow/Motor/`: the rule engine, a Swift port of `Research/motor-rules` (Python reference, the rule book, synthetic fixtures).
  - Rules are data: `MoveGrow/Motor/Resources/rules.json` and `sources.json`.
  - `python3 Research/motor-rules/tools/validate_rules.py` checks them.

## Validation

Run portable checks:

```bash
python3 Checks/static-check.py   # includes Checks/l10n-check.py (translations complete, placeholders match)
swift test -c release        # rule engine == Python reference on 16 fixtures (macOS or Linux)
bash Checks/linux/run.sh     # pipeline + analysis queue end-to-end against framework stand-ins (no Xcode needed)
bash Checks/linux/ui-typecheck.sh   # onboarding screens + baby figure type-checked against a SwiftUI stand-in
```

On macOS with Xcode:

```bash
bash Checks/check-on-mac.sh
```

The macOS check resolves/builds the iOS project and will invoke the build-time model bundling phase.
