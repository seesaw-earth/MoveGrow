# Model provenance

MoveGrow 1.0 uses the official Ultralytics **YOLO26l-pose** Core ML model.

- Upstream project: https://github.com/ultralytics/yolo-ios-app
- Swift package: `UltralyticsYOLO` 8.9.15
- Model release asset: `yolo26l-pose.mlpackage.zip`
- Release tag containing the pinned asset: `v8.3.0`
- Build-time URL: `https://github.com/ultralytics/yolo-ios-app/releases/download/v8.3.0/yolo26l-pose.mlpackage.zip`
- Archive SHA-256: `4e576806e5ce6cfba83ae456c7814336c0161e92b9cff59e873bf0c8b1efe777`
- License path selected for MoveGrow: GNU Affero General Public License v3.0

`Scripts/bundle-yolo-pose.sh` downloads the pinned archive on the developer's Mac during a build, verifies the SHA-256 digest, compiles the Core ML package, and places the compiled model in the application bundle. The installed application does not download this model at runtime.

## InstantHMR (default pose engine since the unreleased version after 1.2)

- Upstream: https://github.com/Naturalpad-studio/InstantHMR (commit 6b187ea), checkpoints on Hugging Face
  (`momolesang/InstantHMR`, `pytorch/<size>/`), MHR rig from https://github.com/facebookresearch/MHR (v1.0.1).
- Converted to Core ML with `instanthmr_coreml.ipynb` (coremltools 9.0): `InstantHMRMediumNet` (fp16, Neural
  Engine), `InstantHMRFit1/2` and `MHRBodyKeypoints` (fp32, CPU). Only Medium is shipped; Small, Tiny and Nano
  are not bundled.
- Medium checkpoint used for the App Store build: **`medium_commercial`** (the plain `medium`, like nano / tiny /
  small, is non-commercial only). Record here which one was converted and the `weight.bin` SHA-256 the build
  log prints (`MoveGrow: InstantHMRMediumNet weight.bin SHA-256 …`):
  - checkpoint: _to fill in_
  - `InstantHMRMediumNet.mlmodelc/weights/weight.bin` SHA-256: _to fill in_
- Licences: weights under Meta's SAM License (copy in `MoveGrow/Licenses/SAM-License.txt`); InstantHMR code and
  MHR under Apache-2.0 (`MoveGrow/Licenses/Apache-2.0.txt`).
- `Scripts/bundle-instanthmr.sh` compiles them from `INSTANTHMR_MODELS_DIR` (default `~/Downloads/coreml`) into the
  application bundle during the build. Not downloaded at runtime; not in the repository.

