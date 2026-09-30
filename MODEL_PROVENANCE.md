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
