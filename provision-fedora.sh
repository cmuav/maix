#!/bin/bash
# Provision a Fedora aarch64 image into ~/MaixVM/ for Maix.
#
# Default: Fedora Workstation (preinstalled desktop disk image).
# First boot drops into gnome-initial-setup to create a user, timezone, etc.
# No cloud-init, no seed ISO.
#
# Alt mode: FEDORA_MODE=cloud uses the Cloud Base qcow2 + cloud-init seed
# (headless unless you add a desktop group via cloud-init user-data).
#
# Requires: qemu-img, xz, hdiutil (macOS built-in).
#
# Env:
#   FEDORA_MODE      workstation (default) | cloud
#   FEDORA_RELEASE   release number (default 43)
#   FEDORA_IMAGE_URL override, full URL to .raw.xz or .qcow2[.xz]
#   DISK_SIZE        final raw disk size (default 64G)
#   VM_USER          cloud-mode username (default maix)
#   VM_PASSWORD      cloud-mode password (default maix)
#   VM_HOSTNAME      cloud-mode hostname (default maix)

set -euo pipefail

FEDORA_MODE="${FEDORA_MODE:-workstation}"
FEDORA_RELEASE="${FEDORA_RELEASE:-43}"
FEDORA_MIRROR="${FEDORA_MIRROR:-https://dl.fedoraproject.org/pub/fedora/linux}"
DISK_SIZE="${DISK_SIZE:-64G}"
VM_USER="${VM_USER:-maix}"
VM_PASSWORD="${VM_PASSWORD:-maix}"
VM_HOSTNAME="${VM_HOSTNAME:-maix}"

BUNDLE="${HOME}/MaixVM"
CACHE="${BUNDLE}/cache"
RAW="${BUNDLE}/disk.img"
SEED_ISO="${BUNDLE}/seed.iso"

mkdir -p "${BUNDLE}" "${CACHE}"

if [[ -f "${RAW}" ]]; then
    echo "Existing ${RAW} found. Delete it first if you want a clean reprovision." >&2
    exit 1
fi

discover() {
    local pattern="$1" subpath="$2"
    local base="${FEDORA_MIRROR}/releases/${FEDORA_RELEASE}/${subpath}"
    echo "[1/4] Discovering image under ${base}" >&2
    local index candidate
    index="$(curl -fsSL "${base}/" || true)"
    candidate="$(printf '%s\n' "${index}" | grep -oE "${pattern}" | sort -u | tail -n1 || true)"
    if [[ -z "${candidate}" ]]; then
        echo "Could not auto-discover image. Set FEDORA_IMAGE_URL explicitly." >&2
        exit 1
    fi
    echo "${base}/${candidate}"
}

if [[ -n "${FEDORA_IMAGE_URL:-}" ]]; then
    URL="${FEDORA_IMAGE_URL}"
else
    case "${FEDORA_MODE}" in
        workstation)
            URL="$(discover 'Fedora-Workstation-Disk-[^"]*\.aarch64\.raw\.xz' 'Workstation/aarch64/images')"
            ;;
        cloud)
            URL="$(discover 'Fedora-Cloud-Base-[^"]*\.aarch64\.qcow2(\.xz)?' 'Cloud/aarch64/images')"
            ;;
        *) echo "Unknown FEDORA_MODE: ${FEDORA_MODE}" >&2; exit 1 ;;
    esac
fi

FILE="${CACHE}/$(basename "${URL}")"
if [[ ! -f "${FILE}" ]]; then
    echo "[2/4] Downloading ${URL}"
    curl -fL --retry 3 -o "${FILE}.part" "${URL}"
    mv "${FILE}.part" "${FILE}"
else
    echo "[2/4] Using cached ${FILE}"
fi

echo "[3/4] Producing ${RAW}"
case "${FILE}" in
    *.raw.xz)
        xz -dc "${FILE}" > "${RAW}.part"
        mv "${RAW}.part" "${RAW}"
        ;;
    *.qcow2.xz)
        local_qcow="${FILE%.xz}"
        [[ -f "${local_qcow}" ]] || xz -dk "${FILE}"
        qemu-img convert -p -O raw "${local_qcow}" "${RAW}"
        ;;
    *.qcow2)
        qemu-img convert -p -O raw "${FILE}" "${RAW}"
        ;;
    *.raw)
        cp "${FILE}" "${RAW}"
        ;;
    *) echo "Unknown image type: ${FILE}" >&2; exit 1 ;;
esac

qemu-img resize -f raw "${RAW}" "${DISK_SIZE}"

if [[ "${FEDORA_MODE}" == "cloud" ]]; then
    echo "[4/4] Building cloud-init seed at ${SEED_ISO}"
    SEED_SRC="$(mktemp -d)"
    trap 'rm -rf "${SEED_SRC}"' EXIT
    cat > "${SEED_SRC}/meta-data" <<EOF
instance-id: maix-$(date +%s)
local-hostname: ${VM_HOSTNAME}
EOF
    cat > "${SEED_SRC}/user-data" <<EOF
#cloud-config
hostname: ${VM_HOSTNAME}
ssh_pwauth: true
users:
  - name: ${VM_USER}
    groups: [wheel]
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: ${VM_PASSWORD}
chpasswd:
  expire: false
growpart:
  mode: auto
  devices: ['/']
package_update: true
packages:
  - qemu-guest-agent
runcmd:
  - [ systemctl, enable, --now, qemu-guest-agent.service ]
EOF
    rm -f "${SEED_ISO}"
    hdiutil makehybrid -quiet -o "${SEED_ISO}" -hfs -joliet -iso \
        -default-volume-name CIDATA -hfs-volume-name CIDATA -joliet-volume-name CIDATA \
        "${SEED_SRC}"
else
    echo "[4/4] Workstation mode — no seed.iso needed."
    rm -f "${SEED_ISO}"
fi

echo
echo "Done."
echo "  Mode:    ${FEDORA_MODE}"
echo "  Disk:    ${RAW}  (${DISK_SIZE})"
if [[ "${FEDORA_MODE}" == "cloud" ]]; then
    echo "  Seed:    ${SEED_ISO}"
fi
if [[ "${FEDORA_MODE}" == "workstation" ]]; then
    echo
    echo "First boot runs gnome-initial-setup: create account, timezone, keyboard."
fi
