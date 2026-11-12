# Third-Party Notices

## UltralyticsYOLO

MoveGrow uses the `UltralyticsYOLO` Swift package, pinned to version **8.9.15**, and the official **YOLO26l-pose** Core ML model.

- Upstream source: https://github.com/ultralytics/yolo-ios-app
- License: GNU Affero General Public License v3.0 (AGPL-3.0)
- License information: https://www.ultralytics.com/license
- Model release asset: `yolo26l-pose.mlpackage.zip`, release `v8.3.0`
- Expected SHA-256: `4e576806e5ce6cfba83ae456c7814336c0161e92b9cff59e873bf0c8b1efe777`

The model is downloaded **at build time**, verified by SHA-256, compiled by Xcode's Core ML compiler, and placed in the application bundle. The installed MoveGrow app does not download the model at runtime.

MoveGrow itself is released under AGPL-3.0 so that the complete application source is available under terms compatible with this dependency path. See `LICENSE`.

## InstantHMR

`MoveGrow/InstantHMR/` re-implements in Swift the inference steps of InstantHMR (crop, CLIFF vector, kinematic-fit
inputs; https://github.com/Naturalpad-studio/InstantHMR, Apache-2.0). The InstantHMR and MHR Core ML models are
**not** part of this repository (`*.mlpackage` is ignored); they are compiled into the app at build time from a
local folder (see `INSTANTHMR.md`). Only the Medium network is shipped.

- InstantHMR model weights: Meta **SAM License** (Nov 19, 2025). The full text is bundled in the app
  (`MoveGrow/Licenses/SAM-License.txt`, Settings → Open source & licences), as the licence requires. The App
  Store build is to use the `medium_commercial` checkpoint (recorded in `MODEL_PROVENANCE.md`); the other
  checkpoints are non-commercial only.
- MHR (Momentum Human Rig), https://github.com/facebookresearch/MHR: Copyright (c) Meta Platforms, Inc. and
  affiliates, **Apache License 2.0** (`MoveGrow/Licenses/Apache-2.0.txt`).
