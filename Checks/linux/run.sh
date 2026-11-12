#!/bin/bash
# Linux (or macOS without Xcode) checks of everything that does not need Apple frameworks:
#  1. unit checks (frame plan, YOLO decoding, luminance, binary tracks, corrected age, legacy JSON,
#     video dates, MP4 export layout and values)
#  2. the two-pass pipeline on a fixture (quick → checkpoint → detail → merge)
#  3. the analysis queue end to end, against small stand-ins for UIKit/AVFoundation/BackgroundTasks
#     (pre-emption, resume, suspension, deletion, migration, retry, background tasks).
# The stand-ins in shim/ only mirror the API surface the app uses; an Xcode build is still required.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$ROOT/MoveGrow"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
mkdir shim
for m in CoreGraphics Combine BackgroundTasks; do
  swiftc -emit-library -emit-module -parse-as-library -module-name $m "$ROOT/Checks/linux/shim/$m.swift" -I shim -L shim -o shim/lib$m.so
done
for m in UIKit AVFoundation ImageIO; do
  swiftc -emit-library -emit-module -parse-as-library -module-name $m "$ROOT/Checks/linux/shim/$m.swift" -I shim -L shim -lCoreGraphics -o shim/lib$m.so
done
CORE="$APP/Motor/*.swift $APP/Models/Memory.swift $APP/Models/VideoDate.swift $APP/Models/L10n.swift $APP/Models/MilestoneSuggestion.swift $APP/Models/PoseArchive.swift $APP/Models/PoseFrame.swift \
 $APP/Services/MovementEngine.swift $APP/Services/PoseTemporalRefiner.swift $APP/Services/MilestoneClassifier.swift \
 $APP/Services/LocalFiles.swift $APP/Services/PoseStore.swift $APP/Services/AnalysisPlan.swift $APP/Services/PoseDecoding.swift \
 $APP/Services/AnalysisPipeline.swift $APP/Services/ReviewExport.swift \
 $APP/InstantHMR/MHR70.swift $APP/InstantHMR/PoseEngine.swift $APP/InstantHMR/HMRTrack.swift $APP/InstantHMR/HMRKinematics.swift"
FLAGS="-O -DDEBUG -parse-as-library -I shim -L shim"
export LD_LIBRARY_PATH="$WORK/shim:${LD_LIBRARY_PATH:-}" MOVEGROW_ROOT="$ROOT" HOME="$WORK/home"
mkdir -p "$HOME"
swiftc $FLAGS -lCoreGraphics $CORE "$ROOT/Checks/linux/date_export_checks.swift" "$ROOT/Checks/linux/unit_main.swift" -o unit
./unit > unit.log 2>&1 || { cat unit.log; exit 1; }
echo "unit: $(grep -c '✓' unit.log) date/export checks · $(tail -1 unit.log)"
swiftc $FLAGS -lCoreGraphics $CORE "$ROOT/Checks/linux/pipeline_main.swift" -o pipeline && ./pipeline | tail -1
# The iOS 26 continued-task code is gated on the Swift 6.2 compiler; type-check it here too.
sed 's/#if compiler(>=6.2)/#if true/' "$APP/Services/BackgroundWork.swift" > BackgroundWork+check.swift
swiftc $FLAGS -lCoreGraphics -lCombine -lUIKit -lAVFoundation -lImageIO -lBackgroundTasks $CORE \
  "$APP/Services/LocalStore.swift" "$APP/Services/LocalStore+Analysis.swift" BackgroundWork+check.swift \
  "$ROOT/Checks/linux/fakes.swift" "$ROOT/Checks/linux/store_main.swift" -o store
cp "$APP/Motor/Resources/rules.json" "$APP/Motor/Resources/sources.json" .
./store > store.log 2>&1 || { cat store.log; exit 1; }
echo "store: $(grep -c '✓' store.log) checks · $(tail -1 store.log)"
