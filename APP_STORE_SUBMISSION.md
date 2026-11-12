# MoveGrow 1.2 (build 4) — before you archive and upload

The 1.0 checklist below still applies; these are the additions for the InstantHMR release.

## Identity

- Version **1.2**, build **4** (`CURRENT_PROJECT_VERSION` was 3; App Store Connect refuses a build number it
  has seen before). If 1.2 is already live on the App Store, raise `MARKETING_VERSION` to 1.3 as well (in both
  build configurations, and in `Checks/static-check.py`).

## InstantHMR models (Medium only)

1. In `~/Downloads/coreml`, keep `InstantHMRMediumNet`, `InstantHMRFit2`, `InstantHMRFit1` (optional) and
   `MHRBodyKeypoints`. Small / Tiny / Nano are not shipped; you can delete them.
2. Make sure `InstantHMRMediumNet` was converted from the **`medium_commercial`** checkpoint. Plain `medium`,
   like nano / tiny / small, is licensed for non-commercial use only.
3. Clear the download quarantine once at the source (the build does it again for the app):
   `xattr -dr com.apple.quarantine ~/Downloads/coreml`
4. Product → Clean Build Folder, then Product → Archive. The archive stops if the Medium network, Fit2 or
   MHRBodyKeypoints is missing, or if a Small / Tiny / Nano package is inside the project.
5. Copy the `weight.bin SHA-256` line from the build log into `MODEL_PROVENANCE.md`.

## Check the archive before uploading

```sh
APP="$(ls -td ~/Library/Developer/Xcode/Archives/*/MoveGrow*.xcarchive | head -1)/Products/Applications/MoveGrow.app"
find "$APP" -xattrname com.apple.quarantine          # must print nothing (TMS-91109)
ls "$APP" | grep mlmodelc                            # InstantHMRMediumNet, InstantHMRFit2, (InstantHMRFit1),
                                                     # MHRBodyKeypoints, yolo26l-pose — and nothing else
```

Then on a device: Settings → Pose engine shows InstantHMR (3D) with no model-size choice; a new video gets a 3D
tab; Settings → Open source & licences opens the SAM License and Apache License 2.0 texts.

## Metadata to update in App Store Connect

- Description and review notes still describe a **pose skeleton over the video**. Since this release no
  skeleton is shown by default; the 3D tab shows a baby figure instead (⋯ → YOLO pose shows the 2D skeleton on
  request). Update both, or App Review will look for a skeleton that isn't there.
- Review notes say the app gives no screening results, but observations include "Talk to a doctor soon" flags
  (e.g. clusters of brief synchronous movements, one-sided rhythmic jerking). Describe them openly: they are
  descriptive, cite published descriptions (Sources in the app), say the app cannot tell what the movement
  was, and point to a clinician. A suggested text is in `APP_STORE_METADATA.md` → *1.2 review notes*.
- Licences: the AGPL / App Store question in `LICENSE_COMPATIBILITY_NOTE.md` now also covers the InstantHMR
  weights (SAM License: field-of-use limits and no reverse engineering) inside an AGPL app.

---

# MoveGrow 1.0 — App Store Submission Checklist

## Identity

- App Store name: **MoveGrow: Baby Milestones**
- Home Screen display name: **MoveGrow**
- Version: **1.0**
- Build: **1**
- Bundle ID in this project: **com.ziqingshi.movegrow**
- Seller/developer for an individual Apple Developer account: **Ziqing Shi**
- Copyright field: **2026 Ziqing Shi**
- Primary language: English (U.S.)
- Suggested primary category: Lifestyle
- Suggested secondary category: Photo & Video
- Do not opt into the Kids Category; the intended user is a parent/caregiver.

## Suggested metadata

- Subtitle: **Private Baby Movement Journal**
- Positioning: private, on-device baby movement video journal and milestone organizer.
- Avoid diagnostic/screening claims in screenshots, description, keywords, and review notes.

## Open-source / AGPL release requirement

This source archive is licensed AGPL-3.0. **AGPL source release alone is not treated here as final App Store license clearance.** Read `LICENSE_COMPATIBILITY_NOTE.md` before submission; Apple supports a custom EULA, but downstream Ultralytics/App Store compatibility should be confirmed before public release.

Before public App Store distribution:

1. Publish the complete corresponding MoveGrow source in a public repository (suggested repository name: `MoveGrow`).
2. Include `LICENSE`, `THIRD_PARTY_NOTICES.md`, `Scripts/bundle-yolo-pose.sh`, project files, configuration, and all application source.
3. Tag the exact submitted build, for example `v1.0.0-appstore-1`.
4. Publish a stable Source Code URL and add it to project/support documentation. A natural location for the connected GitHub account would be `https://github.com/seesaw-earth/MoveGrow` if that repository is created publicly.
5. Keep the exact upstream/model provenance and SHA-256 in `THIRD_PARTY_NOTICES.md`.
6. In App Store Connect, review **App Information → License Agreement** and use an appropriate custom EULA if staying on the AGPL path.
7. Obtain written Ultralytics clarification or other legal clearance for downstream App Store distribution; open-sourcing the project does not itself answer every App Store/AGPL compatibility question.

## Model bundling

`Scripts/bundle-yolo-pose.sh` runs as an Xcode build phase. It downloads the official Ultralytics YOLO26l-pose Core ML archive at build time, verifies SHA-256, compiles it with `coremlcompiler`, and places `yolo26l-pose.mlmodelc` into the built app bundle.

The installed app therefore has no first-use model download. If the bundled model cannot load, the app's existing Apple Vision fallback remains available for offline video analysis.

The first Xcode build/archive on a clean Mac needs internet access so the build script can fetch the pinned model asset. Subsequent builds use the verified cache under `~/Library/Caches/MoveGrow/Models/`.

## Privacy

The included `PrivacyInfo.xcprivacy` declares no tracking and no collected data types. The current application code has no MoveGrow network client, account system, advertising SDK, or analytics SDK. The model network fetch occurs on the developer's Mac during build, not on the user's device.

Publish `PRIVACY_POLICY.md` at a stable public HTTPS URL and use that URL in App Store Connect. Recheck the App Privacy questionnaire if any SDK, telemetry, cloud sync, crash reporting, account system, or backend is added.

## Before creating the App Store record

- Confirm `com.ziqingshi.movegrow` is the Bundle ID you want permanently.
- Register that Bundle ID in Certificates, Identifiers & Profiles if needed.
- Select the correct Apple Development Team in Xcode.
- Confirm the individual account legal name in Apple Developer is exactly **Ziqing Shi**.

## Before TestFlight

- Build with the current Apple-required Xcode/iOS SDK version.
- `Product > Archive` using a physical-device/Any iOS Device destination.
- Confirm the Archive contains `yolo26l-pose.mlmodelc` in the app resources.
- Install the TestFlight build on a clean iPhone and test in Airplane Mode:
  - first launch
  - camera recording
  - live skeleton
  - Photos import
  - full-video analysis
  - skeleton playback alignment
  - 10-second skeleton export
  - milestone suggestion review
  - app relaunch and local data persistence
- Test portrait, landscape, and rotated/mirrored imported videos.

## App Review positioning

Suggested review note:

> MoveGrow is a parent/caregiver video journal for recording and organizing a baby's visible movements and milestones. Video pose estimation and movement summaries run on-device. The app does not provide developmental scores, screening results, diagnoses, or treatment recommendations. Milestone suggestions require parent review before being saved. No account is required and the app does not upload user videos to a MoveGrow server.

## Still external to this ZIP

These items cannot be completed only by editing the Xcode project:

- public GitHub repository / exact source-code release URL
- public privacy-policy URL
- public support URL
- App Store Connect app record
- screenshots and optional preview video
- age-rating questionnaire
- pricing/availability
- final signing/team selection
- TestFlight upload and App Review submission
