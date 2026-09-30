# MoveGrow 1.0 — App Store / AGPL submission candidate

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

## App identity

- Display name: **MoveGrow**
- App Store name: **MoveGrow: Baby Milestones**
- Version/build: **1.0 (1)**
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

## Validation

Run portable checks:

```bash
python3 Checks/static-check.py
```

On macOS with Xcode:

```bash
bash Checks/check-on-mac.sh
```

The macOS check resolves/builds the iOS project and will invoke the build-time model bundling phase.
