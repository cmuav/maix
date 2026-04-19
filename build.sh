#!/bin/bash
# Build, bundle, and sign MaixKiosk.app
set -euo pipefail

cd "$(dirname "$0")"

SIGN_ID="${SIGN_ID:--}"     # override: SIGN_ID="Developer ID Application: ..." ./build.sh
APP_NAME="MaixKiosk"
BUILD_DIR=".build/release"
APP_DIR="build/${APP_NAME}.app"

echo "[1/4] swift build -c release"
swift build -c release --arch arm64

echo "[2/4] assemble bundle at ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"
cp "${BUILD_DIR}/${APP_NAME}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp Info.plist "${APP_DIR}/Contents/Info.plist"

echo "[3/4] codesign (id=${SIGN_ID})"
codesign --force --deep \
    --options runtime \
    --entitlements MaixKiosk.entitlements \
    --sign "${SIGN_ID}" \
    "${APP_DIR}"

echo "[4/4] verify"
codesign --verify --verbose=2 "${APP_DIR}"
echo "Built: ${APP_DIR}"
