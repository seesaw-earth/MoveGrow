#!/bin/bash
# Type-checks the onboarding screens (Features/Onboarding) and the baby figure they draw with, on Linux
# or on a Mac without Xcode, against stand-ins for SwiftUI and simd (Checks/linux/ui). It catches wrong
# argument labels, types, generics and builder mistakes; it is not the iOS SDK, so an Xcode build is
# still required.
#  - ui/SwiftUI.swift, ui/simd.swift: the API surface these files use, with the iOS 17 signatures.
#    Calibrated on BabyFigure.swift, which is known to build in Xcode.
#  - ui/app_standins.swift: the app code that is too heavy to check here (L10n, Theme, the 3D track …).
#  - ui/call_sites.swift: the lines added to RootView.swift and RecordView.swift, as written there.
#    Keep it in step with those two files.
# Needs Swift 5.9 or later.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$ROOT/MoveGrow"
UI="$ROOT/Checks/linux/ui"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
mkdir shim
swiftc -emit-module -parse-as-library -module-name CoreGraphics "$ROOT/Checks/linux/shim/CoreGraphics.swift" -emit-module-path shim/CoreGraphics.swiftmodule
swiftc -emit-module -parse-as-library -module-name simd "$UI/simd.swift" -emit-module-path shim/simd.swiftmodule
swiftc -emit-module -parse-as-library -module-name SwiftUI "$UI/SwiftUI.swift" -emit-module-path shim/SwiftUI.swiftmodule
swiftc -typecheck -parse-as-library -I shim -module-name MoveGrowUICheck \
  "$UI/app_standins.swift" "$UI/call_sites.swift" \
  "$APP/InstantHMR/MHR70.swift" "$APP/InstantHMR/PoseEngine.swift" "$APP/Models/PoseFrame.swift" \
  "$APP/Services/EnvironmentValidator.swift" "$APP/Features/Pose/BabyFigure.swift" \
  "$APP/Features/Onboarding/OnboardingArt.swift" "$APP/Features/Onboarding/OnboardingView.swift"
echo "ui: the onboarding screens and BabyFigure type-check against the SwiftUI stand-in (no errors)"
