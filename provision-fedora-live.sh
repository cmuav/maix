#!/bin/bash
# Fedora Workstation Live ISO install path.
#
# Produces:
#   ~/MaixVM/disk.img        - blank raw target, DISK_SIZE
#   ~/MaixVM/installer.iso   - Fedora Workstation Live aarch64 ISO
#
# Maix attaches both on boot. EFI finds the ISO, boots Anaconda,
# you install to /dev/vda, reboot. After install completes, delete
# installer.iso and EFI will boot from disk.img.

set -euo pipefail

FEDORA_RELEASE="${FEDORA_RELEASE:-43}"
FEDORA_MIRROR="${FEDORA_MIRROR:-https://dl.fedoraproject.org/pub/fedora/linux}"
DISK_SIZE="${DISK_SIZE:-64G}"

BUNDLE="${HOME}/MaixVM"
CACHE="${BUNDLE}/cache"
RAW="${BUNDLE}/disk.img"
ISO="${BUNDLE}/installer.iso"
mkdir -p "${BUNDLE}" "${CACHE}"

if [[ -f "${RAW}" ]]; then
    echo "Existing ${RAW} found. Delete it first if you want a clean reinstall." >&2
    exit 1
fi

BASE="${FEDORA_MIRROR}/releases/${FEDORA_RELEASE}/Workstation/aarch64/iso"
echo "[1/3] Locating Live ISO under ${BASE}"
INDEX="$(curl -fsSL "${BASE}/" || true)"
NAME="$(printf '%s\n' "${INDEX}" | grep -oE 'Fedora-Workstation-Live-[^"]*\.aarch64\.iso' | sort -u | tail -n1)"
if [[ -z "${NAME}" ]]; then
    echo "Could not find Live ISO." >&2; exit 1
fi
URL="${BASE}/${NAME}"
CACHED="${CACHE}/${NAME}"

if [[ ! -f "${CACHED}" ]]; then
    echo "[2/3] Downloading ${URL}"
    curl -fL --retry 3 -o "${CACHED}.part" "${URL}"
    mv "${CACHED}.part" "${CACHED}"
else
    echo "[2/3] Using cached ${CACHED}"
fi

cp "${CACHED}" "${ISO}"

echo "[3/3] Creating blank ${DISK_SIZE} target at ${RAW}"
# Raw sparse file
dd if=/dev/zero of="${RAW}" bs=1 count=0 seek="${DISK_SIZE}" 2>/dev/null || {
    # macOS dd accepts seek=size with suffix via truncate-equivalent:
    mkfile -n "${DISK_SIZE}" "${RAW}"
}

echo
echo "Done."
echo "  Disk:      ${RAW}  (${DISK_SIZE}, blank)"
echo "  Installer: ${ISO}"
echo
echo "Boot Maix. EFI will boot the Live ISO -> GNOME desktop ->"
echo "'Install Fedora Linux' on the desktop. Target disk is /dev/vda."
echo "After install + reboot + user creation, quit the app and run:"
echo "  rm ~/MaixVM/installer.iso ~/MaixVM/nvram"
echo "Next launch will boot into your installed Fedora."
