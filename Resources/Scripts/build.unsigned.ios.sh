#!/bin/bash
set -euo pipefail
app_root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$app_root"
cat > Configuration/Developer.xcconfig <<'EOF'
DEVELOPMENT_TEAM =
CODE_SIGN_STYLE = Manual
CODE_SIGN_IDENTITY =
CODE_SIGNING_REQUIRED = NO
CODE_SIGNING_ALLOWED = NO
EOF
build_args=(-workspace Asspp.xcworkspace -scheme Asspp -configuration Release
  -derivedDataPath "$RUNNER_TEMP/AssppBuild" -destination 'generic/platform=iOS'
  -disableAutomaticPackageResolution CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO
  CODE_SIGN_ENTITLEMENTS="" CODE_SIGNING_ALLOWED=NO ASSPP_SAP_PREPARED=YES)
xcodebuild "${build_args[@]}" -showBuildSettings -json > "$RUNNER_TEMP/AssppBuildSettings.json"
python3 - <<'PY'
import json, os, subprocess
from pathlib import Path
settings = json.loads((Path(os.environ['RUNNER_TEMP']) / 'AssppBuildSettings.json').read_text())
target = next(item['buildSettings'] for item in settings if item['target'] == 'Asspp')
env = dict(os.environ)
keys = ('SRCROOT', 'DERIVED_FILE_DIR', 'TARGET_BUILD_DIR', 'UNLOCALIZED_RESOURCES_FOLDER_PATH',
        'PLATFORM_NAME', 'ARCHS', 'SDKROOT', 'IPHONEOS_DEPLOYMENT_TARGET')
env.update({key: target[key] for key in keys})
subprocess.run(['/usr/bin/python3', 'Resources/Scripts/prepare.sap.py'], env=env, check=True)
PY
xcodebuild -workspace Asspp.xcworkspace -scheme Asspp -configuration Release \
  -derivedDataPath "$RUNNER_TEMP/AssppBuild" -destination 'generic/platform=iOS' \
  -disableAutomaticPackageResolution \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS="" CODE_SIGNING_ALLOWED=NO ASSPP_SAP_PREPARED=YES \
  build | xcbeautify
app_path="$RUNNER_TEMP/AssppBuild/Build/Products/Release-iphoneos/Asspp.app"
test -d "$app_path"
test ! -e "$app_path/embedded.mobileprovision"
if codesign -dv "$app_path" 2>/dev/null; then
  echo 'Unexpected signature on unsigned app' >&2
  exit 1
fi
APP_PATH="$app_path" python3 - <<'PY'
import hashlib, importlib.util, os, plistlib, zlib
from pathlib import Path
spec = importlib.util.spec_from_file_location('sap_build', 'Resources/Scripts/prepare.sap.py')
sap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sap)
app = Path(os.environ['APP_PATH'])
with (app / 'Info.plist').open('rb') as stream:
    info = plistlib.load(stream)
assert info['CFBundleIdentifier'] == 'wiki.qaq.Asspp'
assert 'iPhoneOS' in info['CFBundleSupportedPlatforms']
for name, expected in sap.ASSETS.items():
    assert not (app / 'SAPAssets' / name).exists(), name
    data = zlib.decompress((app / 'SAPAssets' / (name + '.sapz')).read_bytes())
    assert len(data) == expected[0] and hashlib.sha256(data).hexdigest() == expected[1], name
print('Verified iOS package identity and all bundled SAP asset hashes.')
PY
mkdir -p "$RUNNER_TEMP/AssppPackage/Payload"
ditto "$app_path" "$RUNNER_TEMP/AssppPackage/Payload/Asspp.app"
cd "$RUNNER_TEMP/AssppPackage"
/usr/bin/zip -q -r "$RUNNER_TEMP/Asspp-unsigned.ipa" Payload
cd "$RUNNER_TEMP"
shasum -a 256 Asspp-unsigned.ipa > Asspp-unsigned.ipa.sha256
cat Asspp-unsigned.ipa.sha256
