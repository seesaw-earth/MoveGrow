#!/bin/sh
# MoveGrow — Copyright (C) 2026 Ziqing Shi
# SPDX-License-Identifier: AGPL-3.0-only
#
# Compiles the InstantHMR Core ML models (MoveGrow's default pose engine) straight from the folder the
# Colab conversion was unzipped to (INSTANTHMR_MODELS_DIR, default ~/Downloads/coreml) into the app
# bundle. Nothing is copied into the project. See INSTANTHMR.md.
#
# - Only the Medium network is bundled. Small / Tiny / Nano are never compiled, and copies left in the
#   build folder by earlier builds are deleted, so they cannot end up in an archive.
# - Files unzipped from a browser download carry com.apple.quarantine, and the Core ML compiler copies
#   it onto weight.bin. App Store Connect rejects that (ITMS/TMS-91109), so it is removed here, and
#   Scripts/strip-quarantine.sh checks the whole app again at the end of the build.
# - Development builds without the models go on and analyse with YOLO (2D). An archive (Product →
#   Archive) stops instead, so a release never ships without InstantHMR by accident; set
#   INSTANTHMR_OPTIONAL=YES to archive a YOLO-only build on purpose.
set -eu

MODELS_DIR="${INSTANTHMR_MODELS_DIR:-$HOME/Downloads/coreml}"
RESOURCE_DIR="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
IN_PROJECT="${SRCROOT}/MoveGrow"
NET="InstantHMRMediumNet"
REQUIRED="$NET InstantHMRFit2 MHRBodyKeypoints"          # what an archive must contain
MODELS="$NET InstantHMRFit2 InstantHMRFit1 MHRBodyKeypoints"
NOT_SHIPPED="InstantHMRSmallNet InstantHMRTinyNet InstantHMRNanoNet"

ARCHIVING=NO
[ "${ACTION:-build}" = "install" ] && [ "${INSTANTHMR_OPTIONAL:-NO}" != "YES" ] && ARCHIVING=YES

mkdir -p "$RESOURCE_DIR"

# 1. Sizes MoveGrow does not ship: never in the project, never in the bundle.
for NAME in $NOT_SHIPPED; do
  FOUND_IN_PROJECT="$(/usr/bin/find "$IN_PROJECT" -name "$NAME.mlpackage" -o -name "$NAME.mlmodel" | /usr/bin/head -n 1)"
  if [ -n "$FOUND_IN_PROJECT" ]; then
    echo "error: $FOUND_IN_PROJECT is in the project, so Xcode would compile it into the app. MoveGrow ships only the Medium model — remove it." >&2
    exit 1
  fi
  if [ -d "$RESOURCE_DIR/$NAME.mlmodelc" ]; then
    echo "MoveGrow: removing $NAME.mlmodelc left by an earlier build (only Medium is shipped)"
    rm -rf "$RESOURCE_DIR/$NAME.mlmodelc"
  fi
done

# 2. The models MoveGrow ships.
if [ ! -d "$MODELS_DIR" ]; then
  if [ "$ARCHIVING" = YES ]; then
    echo "error: InstantHMR models folder not found: $MODELS_DIR. An archive must contain InstantHMR (set INSTANTHMR_MODELS_DIR, or INSTANTHMR_OPTIONAL=YES for a YOLO-only release)." >&2
    exit 1
  fi
  echo "warning: InstantHMR models folder not found: $MODELS_DIR — videos will be analysed with YOLO (set INSTANTHMR_MODELS_DIR)."
  exit 0
fi

FOUND=0
for NAME in $MODELS; do
  SRC="$MODELS_DIR/$NAME.mlpackage"
  OUT="$RESOURCE_DIR/$NAME.mlmodelc"
  # A copy inside the project folder is compiled by Xcode itself; don't produce it twice.
  if [ -n "$(/usr/bin/find "$IN_PROJECT" -name "$NAME.mlpackage" -print -quit)" ]; then
    FOUND=$((FOUND + 1))
    continue
  fi
  [ -d "$SRC" ] || continue
  FOUND=$((FOUND + 1))
  if [ -d "$OUT" ] && [ -z "$(/usr/bin/find "$SRC" -newer "$OUT" -print -quit)" ]; then
    :                                           # already compiled and unchanged
  else
    echo "MoveGrow: compiling $NAME…"
    rm -rf "$OUT"
    /usr/bin/xcrun coremlcompiler compile "$SRC" "$RESOURCE_DIR" > /dev/null
    if [ ! -d "$OUT" ]; then
      echo "error: Core ML compiler did not create $OUT" >&2
      exit 1
    fi
  fi
  # Remove the download quarantine (weight.bin carries it when the folder came from a browser).
  /usr/bin/xattr -r -d com.apple.quarantine "$OUT" 2>/dev/null || true
  if [ -n "$(/usr/bin/find "$OUT" -xattrname com.apple.quarantine -print -quit)" ]; then
    echo "error: could not remove com.apple.quarantine from $OUT" >&2
    exit 1
  fi
done

# 3. An archive must have the full set.
MISSING=""
for NAME in $REQUIRED; do
  [ -d "$RESOURCE_DIR/$NAME.mlmodelc" ] || [ -n "$(/usr/bin/find "$IN_PROJECT" -name "$NAME.mlpackage" -print -quit)" ] || MISSING="$MISSING $NAME"
done
if [ -n "$MISSING" ]; then
  if [ "$ARCHIVING" = YES ]; then
    echo "error: InstantHMR model(s) missing from $MODELS_DIR:$MISSING. An archive must contain them (or set INSTANTHMR_OPTIONAL=YES)." >&2
    exit 1
  fi
  echo "warning: InstantHMR model(s) missing from $MODELS_DIR:$MISSING"
fi

# Record which Medium weights went into this build (compare with MODEL_PROVENANCE.md).
if [ -f "$RESOURCE_DIR/$NET.mlmodelc/weights/weight.bin" ]; then
  echo "MoveGrow: $NET weight.bin SHA-256 $(/usr/bin/shasum -a 256 "$RESOURCE_DIR/$NET.mlmodelc/weights/weight.bin" | /usr/bin/awk '{print $1}')"
fi
echo "MoveGrow: $FOUND InstantHMR model(s) bundled from $MODELS_DIR (Medium only)"
