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
4. Publish a stable Source Code URL and add it to project/support documentation. A natural location for the connected GitHub account would be `https://github.com/Seesaw2025/MoveGrow` if that repository is created publicly.
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
