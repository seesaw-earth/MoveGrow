#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
check_dir="$(mktemp -d)"
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -parse-as-library \
  MoveGrow/Models/MilestoneSuggestion.swift \
  MoveGrow/Models/Memory.swift \
  MoveGrow/Services/MovementEngine.swift \
  MoveGrow/Services/PoseTemporalRefiner.swift \
  MoveGrow/Services/MilestoneClassifier.swift \
  Checks/MovementEngineChecks.swift -o "$check_dir/movement-checks"
"$check_dir/movement-checks"
xcodebuild -project MoveGrow.xcodeproj \
  -scheme MoveGrow -configuration Debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$check_dir/DerivedData" CODE_SIGNING_ALLOWED=NO build
