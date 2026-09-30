#!/bin/sh
set -eu

MODEL_NAME="yolo26l-pose"
MODEL_URL="https://github.com/ultralytics/yolo-ios-app/releases/download/v8.3.0/${MODEL_NAME}.mlpackage.zip"
EXPECTED_SHA256="4e576806e5ce6cfba83ae456c7814336c0161e92b9cff59e873bf0c8b1efe777"
CACHE_DIR="${HOME}/Library/Caches/MoveGrow/Models"
ARCHIVE="${CACHE_DIR}/${MODEL_NAME}.mlpackage.zip"
UNPACK_DIR="${DERIVED_FILE_DIR}/MoveGrowModel-${MODEL_NAME}"
RESOURCE_DIR="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
COMPILED_MODEL="${RESOURCE_DIR}/${MODEL_NAME}.mlmodelc"

if [ -d "$COMPILED_MODEL" ]; then
  echo "MoveGrow: bundled YOLO model already compiled for this build."
  exit 0
fi

mkdir -p "$CACHE_DIR" "$UNPACK_DIR" "$RESOURCE_DIR"

verify_archive() {
  [ -f "$ARCHIVE" ] || return 1
  ACTUAL="$(/usr/bin/shasum -a 256 "$ARCHIVE" | /usr/bin/awk '{print $1}')"
  [ "$ACTUAL" = "$EXPECTED_SHA256" ]
}

if ! verify_archive; then
  rm -f "$ARCHIVE"
  echo "MoveGrow: downloading official Ultralytics ${MODEL_NAME} Core ML asset for build-time bundling…"
  /usr/bin/curl --fail --location --retry 3 --retry-delay 2 "$MODEL_URL" --output "$ARCHIVE"
  if ! verify_archive; then
    echo "error: MoveGrow YOLO model SHA-256 verification failed." >&2
    rm -f "$ARCHIVE"
    exit 1
  fi
fi

rm -rf "$UNPACK_DIR"
mkdir -p "$UNPACK_DIR"
/usr/bin/ditto -x -k "$ARCHIVE" "$UNPACK_DIR"
MODEL_PACKAGE="$(/usr/bin/find "$UNPACK_DIR" -type d -name "${MODEL_NAME}.mlpackage" -print -quit)"
if [ -z "$MODEL_PACKAGE" ]; then
  echo "error: ${MODEL_NAME}.mlpackage was not found in the verified archive." >&2
  exit 1
fi

echo "MoveGrow: compiling ${MODEL_NAME} into the app bundle…"
/usr/bin/xcrun coremlcompiler compile "$MODEL_PACKAGE" "$RESOURCE_DIR"
if [ ! -d "$COMPILED_MODEL" ]; then
  echo "error: Core ML compiler did not create $COMPILED_MODEL" >&2
  exit 1
fi

echo "MoveGrow: ${MODEL_NAME} is bundled; installed app requires no model download."
