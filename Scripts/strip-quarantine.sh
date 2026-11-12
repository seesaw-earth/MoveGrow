#!/bin/sh
# MoveGrow — Copyright (C) 2026 Ziqing Shi
# SPDX-License-Identifier: AGPL-3.0-only
#
# Last build phase ("Strip Quarantine Attributes"): removes com.apple.quarantine from every file in the
# built app and fails the build if any is left. App Store Connect rejects uploads that contain it
# (TMS-91109 / ITMS-91109); it arrives with files unzipped from a browser download, such as the Core ML
# models in ~/Downloads/coreml, and survives compiling and copying. Runs before Xcode signs the app.
set -eu

APP="${TARGET_BUILD_DIR}/${WRAPPER_NAME}"
[ -d "$APP" ] || exit 0

/usr/bin/xattr -r -d com.apple.quarantine "$APP" 2>/dev/null || true

LEFT="$(/usr/bin/find "$APP" -xattrname com.apple.quarantine -print)"
if [ -n "$LEFT" ]; then
  echo "error: com.apple.quarantine is still set on:" >&2
  echo "$LEFT" >&2
  exit 1
fi
echo "MoveGrow: no com.apple.quarantine attributes in $WRAPPER_NAME"
