#!/bin/bash
set -euo pipefail
curl_check_dir=$(mktemp -d)
trap 'rm -rf "$curl_check_dir"' EXIT
curl_arch=$(uname -m)
env DERIVED_FILE_DIR="$curl_check_dir" TARGET_BUILD_DIR="$curl_check_dir" \
  UNLOCALIZED_RESOURCES_FOLDER_PATH=Resources PLATFORM_NAME=macosx ARCHS="$curl_arch" \
  MACOSX_DEPLOYMENT_TARGET=15.0 SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" \
  /usr/bin/python3 Resources/Scripts/prepare.curl.py
curl_root="$curl_check_dir/AuthenticationCurl"
xcrun clang -fobjc-arc -c Asspp/Backend/AppStore/CurlAuthenticationClient.m \
  -I "$curl_root/include" -o "$curl_check_dir/transport.o"
swiftc Asspp/Backend/AppStore/StoreProtocol.swift \
  Asspp/Backend/AppStore/StoreAuthenticationProtocol.swift \
  Asspp/Backend/AppStore/StoreAuthenticationTransport.swift \
  Resources/Tests/AuthenticationTransportChecks.swift \
  -import-objc-header Asspp/Backend/AppStore/CurlAuthenticationClient.h \
  "$curl_check_dir/transport.o" -L "$curl_root/lib" \
  -lcurl -lmbedtls -lmbedx509 -lmbedcrypto -framework Foundation \
  -o "$curl_check_dir/transport-checks"
/usr/bin/python3 Resources/Tests/AuthenticationTransportFixture.py \
  "$curl_check_dir/transport-checks" "$curl_root/cacert.pem"
