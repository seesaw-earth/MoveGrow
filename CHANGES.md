# Unreleased

- **Getting started** (`MoveGrow/Features/Onboarding`). Three layers, little of it up front:
  - **Welcome pages** before the baby profile on first launch, skippable, with the language menu on top:
    *Two ways to add a video* (record here, or choose from Photos), *The whole baby, in the middle* (two camera
    pictures, "not yet" and "all set", with the recorder's own words) and, with InstantHMR, *Analysed in 3D — no
    perfect angle needed* (the phone straight above or a little to either side). With the YOLO engine the third
    page is left out and the tips ask for a picture from straight above. Kept in **Settings → Getting started →
    How MoveGrow works**.
  - **In place**: the empty album shows the two ways as two buttons (Record, Choose from Photos). The first
    time the recorder opens, **Recording tips** fill the sheet before the camera starts, so the camera prompt
    comes with its reason; the first import shows them once before Photos opens. Along the bottom of the camera
    picture, three words — **Whole body · Hands & feet · Centred** — turn sage with a tick as each
    falls into place (the line of guidance under the picture still says what to do next).
  - **Always there**: **Tips** in the recorder's toolbar, **Recording tips** on the empty album and in Settings.
  - The pictures are drawn with the app's own baby figure (`BabyFigure`) kicking gently on its mat: no image
    files, light and dark, still when Reduce Motion is on.
  - The 3D page says what the analysis does (angles are measured on the baby's own body, not on the flat
    picture) and what it needs (all four limbs in view), and that the figure is an estimate from one camera.
    It does not say results are independent of the camera angle: that has not been measured.
  - 40 new texts in English, 简体中文 and Español; "Tap + to record a new video or choose one from Photos." is
    no longer used.
  - `Research/onboarding-preview`: a JavaScript port of `BabyFigure` (SVG output) with the same poses and
    views, used to look at the pictures before building. `Checks/linux/ui-typecheck.sh` type-checks the new
    screens and `BabyFigure` against a SwiftUI stand-in (`Checks/linux/ui`). Not yet built in Xcode: check
    the first launch, the recorder's first opening (tips, then the camera prompt), the first import, large
    text sizes, dark mode and Reduce Motion on a phone.
- **InstantHMR is the default pose engine** (3D, MHR body model; Medium model, 2-crop kinematic fit, up to 30 frames
  per second). YOLO26l-pose (2D) is the alternative in Settings → Pose engine and the fallback when the models are
  not in the build. Models are compiled at build time from `~/Downloads/coreml`. See `INSTANTHMR.md`.
- **Medium only**: the Small, Tiny and Nano models are no longer bundled or offered (no "Model size" setting).
  The build deletes copies left by earlier builds and fails if one is inside the project; videos analysed with
  them in development builds are analysed again with Medium automatically.
- **No quarantine attribute in the app**: compiled models and, in a new last build phase (*Strip Quarantine
  Attributes*), the whole app are cleared of `com.apple.quarantine`, which App Store Connect rejects (TMS-91109).
  An archive now stops if the InstantHMR models are missing (`INSTANTHMR_OPTIONAL=YES` to override).
- **Licences**: Settings → Open source & licences lists InstantHMR and MHR, with the full SAM License (required
  with the model weights) and Apache License 2.0 texts.
- **Privacy manifest** declares the system-boot-time API (reason 35F9.1) used for the analysis time estimate.
- Fixed: the 3D tab showed the kinematic fit as a model file name ("fit: InstantHMRFit2") instead of "2 crops".
- **Kinematics from 3D**: speeds, activity, elbow and knee angles, head direction and balance are computed from the
  3D track (no finger points). New: hip angle, lift of hands and feet, distance between the hands, leg pattern
  (together / alternating) and limb synchrony, in the review and the Growth tab.
- **3D tab** (after Kinematics) shows the analysis' 3D track as a baby figure following the video;
  **Export 3D data (JSON)** there or in ⋯ → Files. **Analyse again** per video or for all videos made with
  another engine.
- **Older videos are treated as new**: videos analysed with YOLO (or v1.0) are analysed again with InstantHMR
  automatically, from a clean slate; their earlier pose data and results are not used. Notes, dates and milestones
  are kept.
- **Choose videos to analyse again**: Memories → Select, tap the videos (or Select all), then **Analyse again**.
- **Baby figure**: the 3D pose is drawn as a soft, toy-like baby (big round head with a face, mint romper,
  chubby limbs; blue mittens and socks on the baby's left, coral on the right) on a mat or rug with soft
  shadows. Joints come from the analysis; only the body's thickness is drawn. The **Activity** card shows the
  same baby, each limb glowing by how much of the time it moved. Its build follows a baby's skeleton: a big
  skull with the ears low and back, a short neck, a trunk as wide as the baby's own shoulders and hips, and
  legs that leave the romper at the hip joints. A hand (or foot) next to the head no longer
  flickers in front of and behind it: it changes sides only when it clearly moves behind or back in front.
- **No skeleton by default**: none over the review video, none in the camera while recording (framing guidance
  stays), off in video exports unless chosen. **⋯ → YOLO pose** shows YOLO26l-pose's own 2D skeleton on
  request: it finds the baby for InstantHMR in every frame, and its keypoints are now kept with the 3D track
  (and in the 3D JSON) for comparison; the analysis does not use them.
- **Timeline under the video**: drag (or tap) to move through the video; observations and milestones are small
  coloured dots on it. The scrubber snaps to a dot when the finger is close (with a light tick), and the event's
  name shows on the video for a moment, then fades.
- **Smaller 3D view** in the 3D tab, with pinch to zoom (0.6–3×; tap the zoom badge or double-tap to reset).
- **Chinese and Spanish reviewed** for every new text (3D, InstantHMR, YOLO pose, timeline, selection), with the
  app's own terms (观察结果 / Observaciones, 姿态 / postura, Configuración, "video"); model sizes, the kinematic fit,
  InstantHMR error messages and the camera permission text are now translated too. Settings → Language switches
  between English, 简体中文 and Español at once.
- **Review screen in tabs**: Kinematics (the parameter timeline), 3D (the baby figure), Summary (activity, activity
  map, left and right, movement, joint range incl. hips in 3D) and Noticed (event navigation, observations,
  possible milestones).
  Time, frame stepping and speed stay above the tabs.
- **Simpler kinematic panel**: chips choose the track groups (speed and angles by default; lift and coordination in
  3D). The panel no longer reacts to touches while scrolling; **Hold to move** lets you drag through the video (on
  the panel with another finger, or by sliding along the button).
- **Progress while analysing**, also when a video is analysed again.
- **Standing** and **Walking** positions. Rhythm checks are skipped for them (upright movement is rhythmic by itself);
  posture checks still need "On back".

# MoveGrow 1.2 (build 3)

## Languages

- **English, 简体中文 and Español, switchable inside the app** (Settings → Language, also on the welcome screen), or "Same as iPhone".
  - The switch takes effect at once: screens, dates, numbers (decimal comma in Spanish), charts, the exported MP4 and PNG all follow.
  - The phone's own per-app language follows too, so the camera and Photos permission prompts match from the next launch.
- **Every visible text is translated**, about 420 interface texts in all, including errors, accessibility labels and the Live Activity.
- **The observation texts are translated too.** The rule book (names, messages, explanations, what to do) now has Spanish next to Chinese and English. So do the engine's own sentences (reasons a check couldn't run, notes, patterns across recordings).
  - Spanish messages use agreeing limb and side words and a decimal comma.
  - Stored results are re-rendered once after updating (engine 0.2), so older videos get Spanish too. The Python reference still renders Chinese and English only.
- Texts live in `MoveGrow/Localizable.xcstrings` and `MoveGrow/InfoPlist.xcstrings` (permission prompts). `Checks/l10n-check.py` runs inside the static check and fails when:
  - a text is missing a translation;
  - a placeholder doesn't match its key;
  - a SwiftUI text was left untranslated;
  - a rule lacks a language.

## Simpler screens

- **Decorative icons are gone.** Card titles, tiles, chips, menus, status lines, limb labels and observation tiles now use short words. Icons remain only on controls: playback, toolbar buttons, tabs and empty states.
- **Words where icons stood alone**:
  - limb pills read "L arm" / "左臂" / "Brazo izq.";
  - check counts read "5 checks clear" and "1 couldn’t run";
  - the position is a labelled chip;
  - the tracked ring shows its percentage;
  - import results are short sentences;
  - the processing pill says "3 videos ready" when done.
- Trend chips show signed changes ("+12 pts", "−0.05", "no change") instead of arrows. Rough dates read "about"/"约"/"unas" instead of "≈".
- Each Growth chart has a one-line explanation of what its numbers mean (units in words).
- **Videos without a title of their own** show "A little moment" in the app's language. Notes can now be saved without inventing a title.

## Growth charts as an image (PNG)

- A share button on the Growth tab opens **Export charts**. The picture on top is the image itself and follows every choice:
  - all six charts, or the one on screen;
  - the period (all, 3 months, 1 month);
  - points per video or per day;
  - the x axis by date or by (corrected) age;
  - whether to include milestones and patterns across recordings.
- The image is 1170 px wide, made for a check-up or for family. It contains:
  - a header with the baby's name and age, the dates covered and the number of videos;
  - each chart with its legend and first-to-last changes;
  - optionally the patterns across recordings and the milestones (with date and age);
  - a footer with the date and "not a diagnosis".
- **Share** sends the PNG; **Save to Photos** adds it (add-only access).
- Videos without a filming date are left out of trends, so they can't be placed wrongly. Rough dates are drawn as open circles.

## Import and processing

- **Batch import**: pick up to 10 videos in Photos, at most 20 minutes in total.
  - Videos are copied one after another, and each starts analysing as soon as it is in the album.
  - A video that would take the batch past 20 minutes is skipped. Originals in Photos are never changed.
- **Processing is a ring with time left**:
  - a floating pill above the album with a small ring and "3/10 · 4 min" (Liquid Glass on iOS 26);
  - tap it for a large ring with the percentage and time left;
  - each video shows the same ring until its review is ready;
  - on iOS 26, one system Live Activity for the whole batch (a continued-processing task the parent can stop).
- No video frames are drawn or converted while processing, so all the work goes to the analysis.
- **Every video is analysed at its own frame rate**, automatically: 24, 30, 60, 120 or 240 fps.
  - A ~15 fps first pass still makes the review appear within seconds; the remaining frames follow.
  - Older (v1.0) videos get the full-rate pass too. There is no longer a "Run detailed check" step or a Low Power Mode postponement.
  - Progress is per video across both passes, so each bar runs once from 0 to 100%.

## Review (modelled on RodentFlow's review player)

- The video stays on top; the skeleton is drawn from the player's own clock, so it moves smoothly with the video. Tap the video to play or pause.
- **Parameter timeline**: time on the x axis (m:ss ticks), one track per parameter, all sharing the playback cursor. The cursor marks each value at the current time with a dot. The tracks are:
  - arm speed and leg speed (left solid, right dashed);
  - elbow and knee angles;
  - left–right balance for arms and legs;
  - head direction;
  - overall movement;
  - tracking;
  - events (observations as bars, milestones as diamonds).
  - Curves are smoothed over about 1 s for display. Tap to jump; drag sideways to scrub, while vertical drags still scroll.
- **Navigation**: previous / next event with legend chips as the filter, frame stepping, ±5 s, and 0.25–2× speed.
- **Pictures instead of paragraphs**:
  - an activity body map (how much each limb moved);
  - left–right balance gauges for arms and legs;
  - elbow and knee range bars;
  - observation tiles.
- The earlier figures are kept below the timeline: the activity map (colour strips: tracking, four limbs, head, events, with the same cursor) and the movement curve card.
- Explanations, sources and the "share clip with your doctor" button open only when a tile is tapped.
- Removed: the summary paragraph, the "Movement clips" list (now on the Events track), "Recording details" and the pose-model label.
- The colours, cards and type follow the MoveGrow Research "baby in bloom" palette. Limb colours use its colour-blind-safe series.

## Growth: movement over days

- **"Movement over days"** charts the kinematic parameters across videos, or as the mean of each day, by date or by the baby's (corrected) age. The parameters are:
  - activity (% of time each limb moved);
  - median speed per limb;
  - left–right balance for arms and legs, with a ±0.2 "balanced" band;
  - elbow and knee range;
  - head-turn share left and right;
  - overall movement.
- Tap or drag on the chart to pick a point: its date, age and values appear, and a button opens that video's review.
- With nothing picked, chips show how each line changed from the first to the last point.
- Each video's summary is a few hundred bytes in the album index, so the chart needs no file reads. Videos analysed earlier are filled in automatically in the background.

## Dates

- **The filming date is read from the video**: the camera's own QuickTime creation date first, then the movie's. Placeholder dates (1904, 1970, the future) are ignored.
  - A video recorded in the app gets the recording time.
  - When an imported video carries no date (common after messaging apps), it is marked "Date unknown". The thumbnail shows a calendar badge, the review header shows **Add filming date**, and the import sheet says how many need a date.
- **Parents can set the date themselves** — tap the date in the review header, or use "Change date" / Edit. The choices are:
  - **Date**: a calendar day (the filmed time of day is kept);
  - **Age**: days after birth ("45 days old"), shown with the resulting date;
  - **Roughly**: "about N weeks old", "about N months old" or "sometime in a month".
- A card at the top of the sheet shows the date and age exactly as the album will. "Use the date from the video" goes back to the original.
- **Rough dates stay rough**: "Around Mar 2026" / "About 6 weeks old", "≈" on the thumbnail's age chip, and open circles (with a "≈ date" legend) in Growth.
- Age-based dates follow the birthday if it is corrected later. Exact days don't move.
- Changing a date moves that video's moments, and re-checks age-dependent observations (corrected age included).
- Thumbnails show the baby's age on the day ("12 d", "6 wk", "3 mo").

## Export as MP4

- A share button on the review screen opens **Export video**. Tap what to include:
  - the **skeleton**;
  - the **parameter charts** — arms, legs, elbows, knees, L·R balance, head, motion (pick any);
  - the **date & age** header;
  - **sound**.
- Then pick the whole video or a part (drag handles over a strip of how much the baby moved), and the quality:
  - Standard: 720 px wide, ≤ 30 fps;
  - High: 1080 px wide, the video's own frame rate up to 60 fps.
- The picture on top is a real frame of the export and updates with every choice. The line under it gives length, size in pixels and an estimated file size.
- **What the video looks like**:
  - a header with the baby's name, age, date and position;
  - the video with the skeleton;
  - the charts on the review screen's time axis, with a cursor that moves with the video;
  - the part still to come is faded, and the current values are printed beside each chart (L/R, degrees, speed, head direction);
  - lit L/R arm/leg pills show which limbs are moving;
  - a legend, units and "describes movement, not a diagnosis".
  - Portrait reports are 9 : 19.5, so they fill a phone screen; landscape videos get the charts underneath.
  - With only the skeleton and/or sound it is the plain video.
- **Export runs with a progress ring and time left.** Analysis pauses meanwhile, and the screen stays awake. Cancel any time.
- When it's done, the result plays in place. **Share** sends it, or **Save to Photos** adds it with its filming date, so it sorts correctly. Save to Photos uses add-only access and asks once.
- The choices are remembered for the next export. The file is H.264 + AAC MP4, which plays everywhere.
- The file name says who, how old and when: "MoveGrow Mia 45 days old 2026-02-24.mp4".
- The old "Skeleton clip" sheet (10-second clips) is replaced by this export. The original video and the pose JSON are still under the ••• menu.

## Under the hood

- **Review digest** (`MoveGrow/Motor/MotorDigest.swift`, stored as `<id>.review.json`, ~30 KB).
  - It is built from the same smoothed series, body frame, limb speeds and activity thresholds as the rule engine, so pictures and observations agree.
  - Opening a memory reads it instead of re-processing the track.

## Verification

- Linux: rule-engine parity, pipeline and digest tests (including the per-video summary), 52 date, language and export-layout checks, and 83 end-to-end store checks, including the summary backfill and video dates (`bash Checks/linux/run.sh`).
  - The date checks cover days old, about N weeks/months, sometime in a month (never before birth or after today), exact days, labels, corrected age, migration of older albums, and QuickTime date parsing.
  - The store checks cover dates following a birthday edit, moments moving with their video, observations re-checked for the new age, and imports with and without a date in the file.
  - The export checks cover canvas sizes (1080×2340 portrait, 1920 wide landscape, plain video), chart placement, the time→x mapping, frame rates, size estimates, file names and the values printed beside the charts.
  - The export's look was drawn from the layout code and a fixture's real data (`Previews/export-preview.png`).
  - The digest tests use synthetic fixtures with a known answer: a fixture whose left arm moves less gives balance −0.49, and a fixture whose head is mostly turned right gives 96% right.
- An independent reviewer checked the new screens against the iOS SDK. They found no compile errors, and these runtime findings were fixed:
  - Seeks now wait until the video is ready.
  - The playback clock is observed only by the cursor, read-out, navigator and skeleton, so the review screen no longer redraws 12 times a second.
  - The parameter tracks are drawn only when their data changes; only the cursor layer follows playback.
  - Scrubbing is tap or sideways drag, so vertical scrolling still works.
  - Segment playback starts after its seek lands.
  - The 20-minute budget counts only videos actually added.
- A second independent review covered the date sheet and the MP4 export against the iOS SDK. It found no compile errors. These runtime findings were fixed:
  - A read that fails mid-export is now an error, never a shortened file reported as "Ready". Statuses are re-checked before the file is finished.
  - The background time requested for an export is always handed back.
  - When that time runs out, the export says so, instead of quietly going back to the start.
  - Whole-video exports end at the last video frame, so there is no black tail where the sound runs longer.
  - Sound is used only when both the reader and the writer accept it.
  - The first sound buffer of a part is kept.
  - Frame colours pass through unchanged.
  - The range handles no longer jump when touched.
  - The date pickers start inside their ranges.
  - File names leave out an unknown date.
- Languages:
  - `Checks/l10n-check.py` (run by `static-check.py`) confirms all 423 texts exist in all three languages, that every placeholder matches, and that no bare UI text is left.
  - A native-level review of the Chinese and Spanish texts led to fixes:
    - shorter Spanish chips;
    - "App" in Chinese;
    - "这项检查" instead of rule-book jargon;
    - softer Chinese rule names that no longer say "always";
    - Spanish agreement and idiom in several rule explanations;
    - one term per idea ("fragmento", "médico").
  - A code review of the language switch and the PNG export found no compile errors. These runtime findings were fixed:
    - String Catalog symbol generation is off (it could clash on keys that differ only in case);
    - the welcome form keeps what was typed when the language changes;
    - dates use the app's language with the phone's own region settings;
    - Spanish numbers always use a decimal comma, like the observation texts;
    - the PNG is encoded off the main thread, saved from its file, and capped at 24 milestones;
    - a language chosen in iOS Settings → MoveGrow is adopted at launch;
    - export file names leave out the corrected age in every language;
    - chart choices survive a language change.
  - The Growth export's look in Chinese, drawn from the real catalog and fixture data, is in `Previews/growth-export-zh.png`.
- The SwiftUI screens and the AVFoundation export have not been compiled. Build in Xcode first (`bash Checks/check-on-mac.sh`), then export a portrait iPhone video (HDR if possible) and a landscape one, once whole and once in part, with sound.
  - Check that the colours, the skeleton's alignment and the A/V sync match the review screen.

# MoveGrow 1.1 (build 2)

## What parents notice

- **First results in seconds.** Analysis now runs in two passes. The quick pass (~15 fps) produces the summary, milestone suggestions and posture checks. The detailed pass (30 fps) then adds the fast-rhythm checks. A new recording's quick pass jumps ahead of any older video's detailed pass, so a fresh video never waits behind an old one.
- **Live progress with time left**, both in the memory and as a small ring on album thumbnails. A haptic plays when results arrive.
- **Keeps going after you leave the app.**
  - On iOS 26, a recording's analysis continues as a system background task, shown with progress.
  - On earlier iOS versions, it uses the usual short background extension.
  - Remaining work is checkpointed. It resumes the next time the app opens, or while the phone charges.
- **Analysis pauses while the camera is open**, so recording and the live skeleton stay smooth.
- **"What the camera noticed"**: observation cards from the bundled rule book (`MoveGrow/Motor/Resources/rules.json`). Each card offers:
  - tap-to-replay segments;
  - "why this is mentioned · what you can do", with published sources;
  - sharing a passthrough clip with a doctor, for findings worth discussing;
  - honest "checked" and "couldn't check" lists.
- **Baby's position** (on back, tummy time, held, sitting, other) is chosen before recording and can be changed later. Changing it re-runs only the rules, which takes well under a second; the video is not re-analysed.
- **Corrected age** for babies born two or more weeks early. Add the due date in Baby profile; checks then use corrected age until 24 months.
- **Across recordings** on the Growth tab: observations that recur over several videos.
- **Settings** now shows storage used and can run detailed checks for older videos.

## Speed

Speed comes from four changes:

- **Direct Core ML runner (`PoseNet`).** It uses the same YOLO26l-pose model and the same post-processing, without rendering an annotated image for every frame.
- **Smaller decode.** Frames are decoded at ≤960 px on the long side (the model sees 640 px).
- **Overlapped decode and inference.** They run on two threads with a 4-frame bounded queue between them.
- **Cheaper brightness check.** Lighting is sampled on the CPU from about 4,000 pixels in the body region, instead of a Core Image render per frame.

Other speed details:

- Frames are analysed at most at 30 fps. That places the Nyquist limit at 15 Hz, above the 4–14 Hz rhythm band. Analysing 60/120/240 fps imports at full rate would only multiply the work.
- The camera records 30 fps HEVC with exposure capped at 1/60 s, which keeps quick limb movements sharp. HEVC is about half the size of H.264.
- The model is pre-loaded in the background at launch.

## Storage

- **Binary pose tracks** (`<id>.raw.mgpose`, `<id>.mgpose`) replace pretty-printed JSON.
  - About 240 bytes per frame; decoded in milliseconds.
  - Format: `Research/motor-rules/motor_rules/mgpose.py`.
  - Research JSON is generated only when exported, from the share sheet.
- **Album index** (`album.json`) is published in memory immediately. A background queue writes it atomically and coalesces bursts of writes, so a tap never waits for the disk. It is flushed when the app goes to the background.
- **Thumbnails** are made right after saving and decoded off the main thread at display size (ImageIO, memory cache).
- **v1.0 memories** are migrated in place: the JSON tracks are verified, then removed. Their observations are computed from the stored 15 fps data. The detailed pass for old videos runs on request.
- **Robustness**: NaN/∞ metrics are stored safely, and the decode → infer pipeline stops cleanly on cancellation.
  - If the model is unavailable (for example in the background), the pass stops and retries later. The frame is never stored as "no body".

## Rule engine

- `MoveGrow/Motor/*` is a Swift port of the Python reference in `Research/motor-rules`.
- `swift test -c release` checks parity on 16 synthetic fixtures (status, severity, metrics, events).
- Research-status rules run only in the Python reference, not in the app.
- Results store a rule-book fingerprint. After an app update ships new rules, observations are recomputed from the stored tracks, without re-reading the videos.

## Verification status

Done on Linux:

- Rule-engine parity tests (`swift test -c release`).
- `bash Checks/linux/run.sh`, which builds the app's analysis, storage and queue code against small stand-ins for UIKit/AVFoundation/BackgroundTasks and runs:
  - unit checks;
  - a two-pass pipeline test;
  - an end-to-end test of the analysis queue (69 checks). It covers pre-emption, checkpoint/resume, background suspension and the watchdog, deletion during analysis, orphan cleanup, legacy migration, retry, rule-book updates, position changes and background tasks.
- An independent review of the Apple-framework code. Its findings are fixed.

Not yet done: an Xcode build, a simulator run and on-device testing. Run `bash Checks/check-on-mac.sh` on a Mac, then test on an iPhone. Before release, confirm App Store positioning: the observation cards suggest talking to a doctor, but the app stays descriptive.
