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
