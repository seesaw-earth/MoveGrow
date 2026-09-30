# MoveGrow 1.0 — App Store metadata draft

## App information

- **Platform:** iOS
- **Name:** MoveGrow: Baby Milestones
- **Home-screen display name:** MoveGrow
- **Primary language:** English (U.S.)
- **Bundle ID:** `com.ziqingshi.movegrow`
- **SKU:** `MOVEGROW-IOS-001`
- **Version:** 1.0
- **Build:** 1
- **Primary category:** Lifestyle
- **Secondary category:** Photo & Video
- **Copyright:** © 2026 Ziqing Shi
- **Price:** Free for v1.0
- **Kids Category:** No — intended user is an adult parent/caregiver

## Public URLs after GitHub Pages is enabled

- **Privacy Policy URL:** `https://seesaw2025.github.io/MoveGrow/privacy.html`
- **Support URL:** `https://seesaw2025.github.io/MoveGrow/support.html`
- **Marketing URL:** `https://seesaw2025.github.io/MoveGrow/`
- **Source Code:** `https://github.com/Seesaw2025/MoveGrow`

## Subtitle

**Private Baby Movement Journal**

## Promotional text

Capture everyday movement, see an on-device pose skeleton, and organize the moments you choose into a private milestone timeline.

## Description

MoveGrow is a private video journal for the small movements and growing moments you want to remember.

Record a new video or choose one from your photo library. MoveGrow can visualize a single-person pose skeleton directly on the video, create descriptive movement summaries, and help you organize parent-confirmed milestone moments over time.

Designed for parents and caregivers:

• Record or import baby movement videos
• See a pose skeleton aligned with the original video
• Review descriptive movement summaries
• Save and revisit milestone moments by age
• Keep videos and analysis on your iPhone
• No MoveGrow account required
• No advertising or cross-app tracking in version 1.0

MoveGrow is designed as a personal movement and video journal. Its summaries are descriptive and may be affected by camera motion, occlusion, framing, lighting, and pose-estimation uncertainty.

MoveGrow is not a developmental screening test, diagnosis, treatment recommendation, or medical device. If you have concerns about a child's development or health, contact an appropriate healthcare professional.

## Keywords

baby,milestones,movement,journal,video,growth,parent,memory,motor,development

## Review notes

MoveGrow is a parent-facing local video journal. No account or login is required.

Core flow for review:
1. Create a local baby profile using any nickname and birthday.
2. Record a short video, or import a non-sensitive video using the system Photos picker.
3. The pose model runs locally on the device and displays a single-person skeleton.
4. Open the saved memory to review the video, skeleton overlay, descriptive movement summary, and optional parent-confirmed milestone suggestion.

Privacy and network behavior:
- Baby profile data, videos, pose keypoints, summaries, and milestone records are stored locally.
- MoveGrow does not upload these materials to a MoveGrow server.
- The YOLO pose model is compiled into the app bundle at build time; the installed app does not download the model at first use.
- No advertising, cross-app tracking, or MoveGrow analytics service is included in version 1.0.

Medical positioning:
MoveGrow provides descriptive movement visualization and organization only. It is not a screening test, diagnosis, treatment recommendation, or medical device.

Open source:
MoveGrow is distributed under AGPL-3.0. Corresponding source and third-party notices are published at https://github.com/Seesaw2025/MoveGrow .

## App Privacy answer planned for v1.0

If the final archived binary contains no additional telemetry or third-party data collection beyond the audited code, select:

**No, we do not collect data from this app.**

This must be re-verified against the final archived build and all third-party SDK behavior before publishing the privacy label.
