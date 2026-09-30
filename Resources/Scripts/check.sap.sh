#!/bin/bash
set -euo pipefail
sap_repo_dir=$(cd "$(dirname "$0")/../.." && pwd)
sap_check_dir=$(mktemp -d)
trap 'rm -rf "$sap_check_dir"' EXIT
cd "$sap_repo_dir"

swiftc Asspp/Backend/AppStore/StoreProtocol.swift \
    Asspp/Backend/AppStore/StoreDiagnostics.swift \
    Asspp/Backend/AppStore/StoreAuthenticationProtocol.swift \
    Resources/Tests/AuthenticationProtocolChecks.swift -o "$sap_check_dir/auth-checks"
"$sap_check_dir/auth-checks"
/usr/bin/python3 Resources/Tests/SAPBuildChecks.py
/usr/bin/python3 Resources/Tests/LocalizationChecks.py \
    Asspp/Backend/AppStore/StoreAuthenticationProtocol.swift \
    Asspp/Backend/AppStore/AuthenticationService.swift \
    Asspp/Interface/Account/AddAccountView.swift

# Pass an already prepared macOS SAP directory to reuse its pinned interpreter.
sap_runtime_dir=${1:-"$sap_check_dir/SAP"}
if [ $# -eq 0 ]; then
    env DERIVED_FILE_DIR="$sap_check_dir" SRCROOT="$sap_repo_dir" \
        TARGET_BUILD_DIR="$sap_check_dir" UNLOCALIZED_RESOURCES_FOLDER_PATH=Resources \
        PLATFORM_NAME=macosx ARCHS="$(uname -m)" MACOSX_DEPLOYMENT_TARGET=15.0 \
        SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" \
        /usr/bin/python3 Resources/Scripts/prepare.sap.py
fi
xcrun clang++ -std=c++20 -O1 -g -fsanitize=address,undefined \
    -I Asspp/Backend/AppStore/SAP -I "$sap_runtime_dir/source/include" \
    Resources/Tests/SAPRuntimeChecks.cpp \
    Asspp/Backend/AppStore/SAP/SapMachine.cpp Asspp/Backend/AppStore/SAP/MachImage.cpp \
    "$sap_runtime_dir/lib/libunicorn.a" -o "$sap_check_dir/runtime-checks"
"$sap_check_dir/runtime-checks"

# Exercise the actual Objective-C bridge, verified Apple assets and full interpreter.
xcrun clang++ -std=c++20 -O2 -fobjc-arc -framework Foundation -lz \
    -I Asspp/Backend/AppStore/SAP -I "$sap_runtime_dir/source/include" \
    Resources/Tests/SAPHandshakeChecks.mm Asspp/Backend/AppStore/SAP/SAPContext.mm \
    Asspp/Backend/AppStore/SAP/SapMachine.cpp Asspp/Backend/AppStore/SAP/MachImage.cpp \
    "$sap_runtime_dir/lib/libunicorn.a" -o "$sap_check_dir/handshake-checks"
SAP_RUNTIME_DIR="$sap_runtime_dir" SAP_CHECK_DIR="$sap_check_dir" /usr/bin/python3 - <<'PY'
import importlib.util, os
from pathlib import Path
spec = importlib.util.spec_from_file_location('sap_build', 'Resources/Scripts/prepare.sap.py')
sap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sap)
sap.bundle_assets(Path(os.environ['SAP_RUNTIME_DIR']) / 'assets', Path(os.environ['SAP_CHECK_DIR']) / 'packed-assets')
PY
"$sap_check_dir/handshake-checks" "$sap_check_dir/packed-assets"
