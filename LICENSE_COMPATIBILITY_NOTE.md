# AGPL and Apple App Store distribution note

MoveGrow's application source is licensed under **AGPL-3.0-only**, and the project uses UltralyticsYOLO / YOLO26l-pose under Ultralytics' AGPL path.

This solves the *source-availability* side of the Ultralytics licensing choice, but it should **not** be treated as a legal clearance for Apple App Store distribution by itself.

Apple allows developers to provide a **custom EULA** in App Store Connect instead of relying solely on Apple's standard EULA. However, AGPLv3/GPLv3-family licenses can raise compatibility questions with app-store usage rules, code-signing/DRM, and downstream redistribution rights. MoveGrow can grant additional permissions for code owned by Ziqing Shi, but cannot grant additional permissions on behalf of Ultralytics.

Before the first public App Store release, obtain one of the following:

1. written confirmation from Ultralytics that downstream distribution of its AGPL-licensed iOS SDK/model through Apple's App Store is permitted under the planned terms; or
2. an applicable Ultralytics Enterprise/commercial license; or
3. replace the Ultralytics dependency/model with a pose stack whose license is clearly compatible with the intended App Store distribution.

If remaining on the AGPL path, also configure an appropriate **custom EULA** in App Store Connect rather than assuming Apple's default Standard EULA alone is sufficient. Legal review is appropriate before public distribution.

This file is a release-engineering warning, not legal advice.
