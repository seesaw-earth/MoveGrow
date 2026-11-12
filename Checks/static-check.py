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
    if '.build' in f.parts: continue
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
assert project.count('MARKETING_VERSION = 1.2;') == 2
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
assert project.count('INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription') == 2
assert '"zh-Hans",' in project and '\t\t\t\tes,' in project, 'knownRegions must list zh-Hans and es'
assert subprocess.run(['python3', '-I', str(root/'Checks/l10n-check.py')]).returncode == 0, 'localization check failed'
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
info = plistlib.loads((root/'MoveGrow/Info.plist').read_bytes())
assert 'com.ziqingshi.movegrow.analysis' in info['BGTaskSchedulerPermittedIdentifiers']
assert 'com.ziqingshi.movegrow.continued.*' in info['BGTaskSchedulerPermittedIdentifiers']
assert 'processing' in info['UIBackgroundModes']
assert 'BackgroundWork.processingIdentifier' in source or 'com.ziqingshi.movegrow.analysis' in source
# InstantHMR: Medium only, quarantine stripped, licences bundled.
hmr_script = (root/'Scripts/bundle-instanthmr.sh').read_text()
models_line = next(l for l in hmr_script.splitlines() if l.startswith('MODELS='))
assert all(n not in models_line for n in ['SmallNet', 'TinyNet', 'NanoNet']), 'only the Medium network is bundled'
assert 'NOT_SHIPPED=' in hmr_script and 'xattr -r -d com.apple.quarantine' in hmr_script
for size in ['Small', 'Tiny', 'Nano']:
    assert f'InstantHMR{size}Net' not in source, f'{size} model referenced in app code'
    assert not list((root/'MoveGrow').rglob(f'InstantHMR{size}Net.*')), f'{size} model inside the project'
assert 'netName = "InstantHMRMediumNet"' in source
assert 'Strip Quarantine Attributes' in project and 'strip-quarantine.sh' in project
assert 'xattr -r -d com.apple.quarantine' in (root/'Scripts/strip-quarantine.sh').read_text()
assert (root/'MoveGrow/Licenses/SAM-License.txt').read_text().startswith('SAM License')
assert 'Apache License' in (root/'MoveGrow/Licenses/Apache-2.0.txt').read_text()
assert '"SAM-License"' in source and '"Apache-2.0"' in source
# Required-reason APIs used by the app are declared.
declared = {d['NSPrivacyAccessedAPIType']: d['NSPrivacyAccessedAPITypeReasons'] for d in privacy['NSPrivacyAccessedAPITypes']}
for api, category in [('systemUptime', 'SystemBootTime'), ('UserDefaults', 'UserDefaults'),
                      ('volumeAvailableCapacity', 'DiskSpace'), ('creationDateKey', 'FileTimestamp')]:
    if api in source:
        assert f'NSPrivacyAccessedAPICategory{category}' in declared, f'{api} used but {category} not declared'
rules = json.loads((root/'MoveGrow/Motor/Resources/rules.json').read_text())
sources = json.loads((root/'MoveGrow/Motor/Resources/sources.json').read_text())['sources']
assert all(s in sources for r in rules['rules'] for s in r['sources']), 'rule cites an unknown source'
assert 'MGPS' in source and '.mgpose' in source
assert len(list((root/'Tests/MotorKitTests/Fixtures').glob('*.mgpose'))) >= 10

print(f'PASS: {len(files)} Swift files checked; MoveGrow 1.2 identity, AGPL source notices, icon, privacy manifest (incl. required-reason APIs), build-time bundled YOLO26l path, InstantHMR Medium only, quarantine stripping, SAM/Apache licence texts, pose archives, motor rule book and background-task keys present.')
print('NOT RUN: Xcode build, simulator, Core ML runtime, camera/device acceptance.')
