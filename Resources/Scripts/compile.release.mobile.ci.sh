#!/bin/zsh

set -euo pipefail

SRCROOT=$(realpath "$1")
TARGET_IPA=$2

WORKSPACE="$SRCROOT/Asspp.xcworkspace"
SCHEME="Asspp"
BUILD_PRODUCT="Asspp.app"

cd $SRCROOT

git clean -fdx -f
git reset --hard

# Generate Developer.xcconfig for CI (codesign completely disabled)
cat >"$SRCROOT/Configuration/Developer.xcconfig" <<'EOF'
// CI-generated Developer.xcconfig
// Code signing is completely disabled for CI builds
DEVELOPMENT_TEAM =
CODE_SIGN_STYLE = Manual
CODE_SIGN_IDENTITY =
CODE_SIGN_IDENTITY[sdk=macosx*] =
CODE_SIGNING_REQUIRED = NO
CODE_SIGNING_ALLOWED = NO
EOF

# Store AMD proofs and kbsync downloads come from the ipatool bridge. Set
# ASSPP_IPATOOL=0 to build the ApplePackage-only app instead.
if [ "${ASSPP_IPATOOL:-1}" != "0" ]; then
    bash "$SRCROOT/Resources/Scripts/build.ipatool.sh" "$SRCROOT"
fi

xcodebuild -workspace "$WORKSPACE" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$SRCROOT/build/DerivedDataApp" \
    -destination 'generic/platform=iOS' \
    build \
    DEVELOPMENT_TEAM="" CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS="" CODE_SIGNING_ALLOWED="NO" \
    GCC_GENERATE_DEBUGGING_SYMBOLS=YES STRIP_INSTALLED_PRODUCT=NO \
    COPY_PHASE_STRIP=NO UNSTRIPPED_PRODUCT=NO \
    | xcbeautify

BUILD_PRODUCT_PATH=""
for i in $(find "$SRCROOT/build/DerivedDataApp" -name "$BUILD_PRODUCT"); do
    BUILD_PRODUCT_PATH=$i
    break
done
BUILD_PRODUCT_PATH=$(realpath "$BUILD_PRODUCT_PATH")

if [ -z "$BUILD_PRODUCT_PATH" ]; then
    echo "[-] build product not found"
    exit 1
fi

echo "[+] build product path: $BUILD_PRODUCT_PATH"

echo "[+] packaging..."
pushd "$SRCROOT/build"
mkdir -p Payload
cp -r "$BUILD_PRODUCT_PATH" Payload
zip -r "$TARGET_IPA" Payload
rm -rf Payload
popd

echo "[+] done"
