#!/usr/bin/env python3
"""Portable structure checks; not a substitute for an Xcode/iOS build."""
from pathlib import Path
import json, plistlib, re, subprocess, shutil, xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
files = list((root / 'MoveGrow').rglob('*.swift'))

swiftc = shutil.which('swiftc')
if swiftc:
    for f in files:
        subprocess.run([swiftc, '-frontend', '-parse', str(f)], check=True, stdout=subprocess.DEVNULL)

for f in root.rglob('*.json'):
    json.loads(f.read_text())
for f in root.rglob('*.xcscheme'):
    ET.parse(f)

privacy = plistlib.loads((root/'MoveGrow/PrivacyInfo.xcprivacy').read_bytes())
assert privacy['NSPrivacyTracking'] is False
assert privacy['NSPrivacyCollectedDataTypes'] == []

source = '\n'.join(p.read_text() for p in files)
assert len(re.findall(r'@main\b', source)) == 1
for forbidden in ['UploadService', 'SageMaker', 'demoScore', 'AWS', 'S3Object']:
    assert forbidden not in source, forbidden

project = (root/'MoveGrow.xcodeproj/project.pbxproj').read_text()
assert 'PBXFileSystemSynchronizedRootGroup' in project
assert 'https://github.com/ultralytics/yolo-ios-app.git' in project
assert 'productName = UltralyticsYOLO;' in project
assert 'version = 8.9.15;' in project
assert project.count('MARKETING_VERSION = 1.0;') == 2
assert 'modelName = "yolo26l-pose"' in source
assert 'ultralytics-yolo26l-pose-coreml-bundled' in source
assert 'YOLOLargestPersonSelector' in source
assert 'YOLOSubjectTracker' not in source
assert 'largest-person-box-per-frame' in source
assert 'poses.raw.json' in source
assert 'path = MoveGrow;' in project
assert project.count('PRODUCT_BUNDLE_IDENTIFIER = com.ziqingshi.movegrow;') == 2
assert 'IPHONEOS_DEPLOYMENT_TARGET = 17.0;' in project
assert 'UIFileSharingEnabled = YES' not in project
assert 'isExcludedFromBackup = true' in source
assert 'CODE_SIGNING_ALLOWED=NO' in (root/'Checks/check-on-mac.sh').read_text()
assert (root/'LICENSE').exists()
assert 'GNU AFFERO GENERAL PUBLIC LICENSE' in (root/'LICENSE').read_text(errors='ignore')
assert (root/'THIRD_PARTY_NOTICES.md').exists()
assert (root/'PRIVACY_POLICY.md').exists()
script=(root/'Scripts/bundle-yolo-pose.sh').read_text()
assert '4e576806e5ce6cfba83ae456c7814336c0161e92b9cff59e873bf0c8b1efe777' in script
assert 'coremlcompiler compile' in script
assert 'PBXShellScriptBuildPhase' in project and 'Bundle YOLO Pose Model' in project
assert 'MoveGrow-AppIcon-1024.png' in (root/'MoveGrow/Assets.xcassets/AppIcon.appiconset/Contents.json').read_text()
assert all('SPDX-License-Identifier: AGPL-3.0-only' in f.read_text() for f in files)

print(f'PASS: {len(files)} Swift files checked; MoveGrow 1.0 identity, AGPL source notices, icon, privacy manifest, build-time bundled YOLO26l path and pose archives present.')
print('NOT RUN: Xcode build, simulator, Core ML runtime, camera/device acceptance.')
