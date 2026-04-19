#!/bin/bash
# Build Maix.app:
#   - compile MaixKiosk (Swift app) + maix-qemu-launcher (C launcher)
#   - vendor UTM's aarch64 qemu framework + supporting frameworks + edk2 firmware
#   - codesign the whole bundle
set -euo pipefail
cd "$(dirname "$0")"

SIGN_ID="${SIGN_ID:--}"
APP_NAME="MaixKiosk"
APP_DISPLAY="Maix"
BUILD_DIR=".build/release"
APP_DIR="build/${APP_NAME}.app"
UTM_APP="${UTM_APP:-/Applications/UTM.app}"

if [[ ! -d "${UTM_APP}" ]]; then
    echo "UTM.app not found at ${UTM_APP}. Install UTM first (we vendor its qemu)." >&2
    exit 1
fi

echo "[1/6] swift build"
swift build -c release --arch arm64 --product MaixKiosk
swift build -c release --arch arm64 --product maix-qemu-launcher

echo "[2/6] Assemble bundle"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Frameworks" "${APP_DIR}/Contents/Resources/qemu"
cp "${BUILD_DIR}/${APP_NAME}"         "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp "${BUILD_DIR}/maix-qemu-launcher"  "${APP_DIR}/Contents/MacOS/maix-qemu-launcher"
cp Info.plist                         "${APP_DIR}/Contents/Info.plist"

echo "[3/6] Vendor UTM frameworks (aarch64-softmmu + supporting libs)"
# Copy every framework except other-arch qemu-*-softmmu frameworks.
OTHER_ARCHES='^qemu-(alpha|arm|i386|riscv32|riscv64|ppc|ppc64|s390x|sparc|sparc64|mips|mipsel|mips64|mips64el|xtensa|xtensaeb|microblaze|microblazeel|tricore|loongarch64|m68k|avr|hppa|cris|nios2|or1k|rx|sh4|sh4eb|x86_64|nanomips)-softmmu\.framework$'
cd "${UTM_APP}/Contents/Frameworks"
for f in *; do
    if [[ -d "$f" ]] && ! [[ "$f" =~ $OTHER_ARCHES ]]; then
        rsync -a "$f" "${OLDPWD}/${APP_DIR}/Contents/Frameworks/"
    fi
done
cd "${OLDPWD}"

echo "[4/6] Vendor UTM qemu resources (firmware + keymaps)"
# aarch64 + common stuff only
SRC="${UTM_APP}/Contents/Resources/qemu"
DST="${APP_DIR}/Contents/Resources/qemu"
cp "${SRC}/edk2-aarch64-code.fd"     "${DST}/"
cp "${SRC}/edk2-aarch64-secure-code.fd" "${DST}/" 2>/dev/null || true
cp "${SRC}/edk2-arm-vars.fd"         "${DST}/"
cp "${SRC}/edk2-licenses.txt"        "${DST}/" 2>/dev/null || true
for rom in efi-virtio.rom efi-e1000.rom efi-e1000e.rom efi-pcnet.rom efi-rtl8139.rom efi-virtio-net.rom vgabios-virtio.bin; do
    cp "${SRC}/${rom}" "${DST}/" 2>/dev/null || true
done
for dir in keymaps firmware; do
    if [[ -d "${SRC}/${dir}" ]]; then rsync -a "${SRC}/${dir}" "${DST}/"; fi
done

echo "[4b/6] Compile CocoaSpice Metal shader into resource bundle"
METAL_SRC=".build/checkouts/CocoaSpice/Sources/CocoaSpiceRenderer/CSShaders.metal"
RENDERER_BUNDLE="${APP_DIR}/Contents/Resources/CocoaSpice_CocoaSpiceRenderer.bundle"
if [[ ! -f "${METAL_SRC}" ]]; then
    echo "Metal source not found at ${METAL_SRC}" >&2; exit 1
fi
mkdir -p "${RENDERER_BUNDLE}"
# Copy SPM's generated bundle resources (Info.plist, etc.) if any
if [[ -d ".build/release/CocoaSpice_CocoaSpiceRenderer.bundle" ]]; then
    rsync -a ".build/release/CocoaSpice_CocoaSpiceRenderer.bundle/" "${RENDERER_BUNDLE}/"
fi
xcrun -sdk macosx metal -c "${METAL_SRC}" -o /tmp/CSShaders.air
xcrun -sdk macosx metallib /tmp/CSShaders.air -o "${RENDERER_BUNDLE}/default.metallib"
rm -f /tmp/CSShaders.air
rm -f "${APP_DIR}/Contents/Resources/default.metallib" 2>/dev/null || true

echo "[5/6] codesign (id=${SIGN_ID})"
# Sign frameworks first (deepest first), then the main binary.
find "${APP_DIR}/Contents/Frameworks" -type d -name '*.framework' -maxdepth 1 | while read fw; do
    codesign --force --options runtime --sign "${SIGN_ID}" "$fw" >/dev/null 2>&1 || \
        codesign --force --sign "${SIGN_ID}" "$fw"
done
codesign --force --options runtime \
    --entitlements MaixKiosk.entitlements \
    --sign "${SIGN_ID}" \
    "${APP_DIR}/Contents/MacOS/maix-qemu-launcher"
codesign --force --options runtime \
    --entitlements MaixKiosk.entitlements \
    --sign "${SIGN_ID}" \
    "${APP_DIR}"

echo "[6/6] verify"
codesign --verify --verbose=2 "${APP_DIR}" 2>&1 | tail -5
echo "Built: ${APP_DIR}  ($(du -sh "${APP_DIR}" | cut -f1))"
