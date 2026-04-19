#!/bin/bash
# provision-camera-guest.sh — run INSIDE the Fedora guest.
#
# Sets up a lazy host-camera bridge using RPM Fusion's akmod-v4l2loopback.
# akmods rebuilds v4l2loopback automatically when # a new kernel is installed, as long as kernel-devel is present
#
# Safe to run repeatedly.

set -Eeuo pipefail

DATA_PORT=/dev/virtio-ports/com.cmuav.camera
CTRL_PORT=/dev/virtio-ports/com.cmuav.camera.control
DEV=/dev/video0

msg()  { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

if [[ $EUID -ne 0 ]]; then
    exec sudo -E bash "$0" "$@"
fi

trap 'warn "Failed at line $LINENO: $BASH_COMMAND"' ERR

KVER="$(uname -r)"
msg "Running kernel: $KVER"

#---------------------------------------------------------------------------
msg "[1/6] RPM Fusion free"
if ! rpm -q rpmfusion-free-release >/dev/null 2>&1; then
    dnf install -y \
        "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm"
fi

#---------------------------------------------------------------------------
msg "[2/6] Kernel companion packages (keeps kernel modules in sync on upgrades)"
# Unversioned names so future kernel-core updates pull matching versions via
# dnf's kernel-install hook. akmods rebuilds v4l2loopback when these change.
dnf install -y \
    kernel-devel \
    kernel-modules \
    kernel-modules-extra

#---------------------------------------------------------------------------
msg "[3/6] v4l2loopback (akmod) + tools"
dnf install -y \
    v4l2loopback akmod-v4l2loopback \
    ffmpeg-free inotify-tools psmisc v4l-utils lsof

#---------------------------------------------------------------------------
msg "[4/6] Force an akmods build for the running kernel (idempotent)"
# akmods.service builds on boot if needed, but running synchronously here
# gives a clear failure if something is wrong.
/usr/sbin/akmods --force --kernels "$KVER" || warn "akmods --force returned non-zero"
depmod -a "$KVER"

# Load video core + v4l2loopback. Core may be a module or built-in.
cat >/etc/modules-load.d/maix-camera.conf <<'EOF'
videodev
v4l2loopback
EOF

# Install-line override is more reliable than options-line in Fedora 43 —
# modules-load.d sometimes bypasses /etc/modprobe.d/<x>.conf. Use `install`
# form so the params are always applied no matter who triggers the load.
cat >/etc/modprobe.d/maix-camera.conf <<'EOF'
install v4l2loopback /sbin/modprobe --ignore-install v4l2loopback exclusive_caps=0 card_label=MaixCamera video_nr=0
EOF

modprobe -r v4l2loopback 2>/dev/null || true
modprobe videodev 2>/dev/null || true
modprobe v4l2loopback || die \
    "Could not insert v4l2loopback. akmods build may have failed. Check:
     systemctl status akmods
     journalctl -u akmods -b
     ls /lib/modules/$KVER/extra/v4l2loopback/"

[[ -e "$DEV" ]] || die "$DEV missing after modprobe — v4l2loopback loaded without creating a device."

#---------------------------------------------------------------------------
msg "[5/6] Camera supervisor + systemd service"

cat >/usr/local/sbin/maix-camera-supervisor <<'SH'
#!/usr/bin/env bash
# Architecture:
#   - ffmpeg is ALWAYS running, pulling MJPEG from /dev/virtio-ports/com.cmuav.camera
#     and writing to /dev/video0. It blocks harmlessly when the host isn't sending.
#   - We tell the host to start/stop AVCapture on /dev/video0 consumer transitions
#     via the control port. Camera LED is off whenever no consumer is active.
set -u

DATA_PORT=/dev/virtio-ports/com.cmuav.camera
CTRL_PORT=/dev/virtio-ports/com.cmuav.camera.control
DEV=/dev/video0

wait_for() { for _ in {1..60}; do [[ -e "$1" ]] && return 0; sleep 1; done; return 1; }
wait_for "$DATA_PORT" || exit 0
wait_for "$CTRL_PORT" || exit 0
wait_for "$DEV"       || exit 0

exec 9<>"$CTRL_PORT"
say() { printf '%s\n' "$1" >&9; }

# Expose a FIFO so unprivileged helpers (maix-next-camera, future tools) can
# inject control lines without racing the supervisor on /dev/virtio-ports/*.
# The FIFO is the only multi-writer surface; supervisor is the sole reader
# and the sole writer to the virtio port.
FIFO=/run/maix-camera.fifo
# World-writable is fine — the supervisor is the sole reader and only
# recognizes a fixed set of commands (GO/STOP/NEXT); there's no sensitive
# state here. Alternative would be to gate on the 'video' group, but that
# requires users to log out/in before the CLI works.
rm -f "$FIFO"
mkfifo "$FIFO"
chmod 0666 "$FIFO"
# Hold the FIFO open so writers don't see EOF between messages.
exec 8<>"$FIFO"

# Background line forwarder: FIFO -> control port.
while read -r line <&8; do
    say "$line"
done &
FWD_PID=$!

# Always-on producer. Raw UYVY (2vuy) straight from host — no decode, no
# format conversion. AVFoundation outputs this in video-range BT.601, which
# is what v4l2 consumers on Linux expect. Must match CameraBridge
# captureWidth/captureHeight/targetFPS in Maix.
WIDTH=1280
HEIGHT=720
FPS=30
ffmpeg -hide_banner -loglevel error \
    -fflags +nobuffer -flags low_delay -probesize 32 -analyzeduration 0 \
    -thread_queue_size 512 \
    -f rawvideo -pix_fmt uyvy422 -video_size ${WIDTH}x${HEIGHT} -framerate ${FPS} \
    -i "$DATA_PORT" \
    -f v4l2 -pix_fmt uyvy422 "$DEV" &
FFPID=$!

cleanup() {
    kill "$FFPID" 2>/dev/null || true
    wait "$FFPID" 2>/dev/null || true
    kill "$FWD_PID" 2>/dev/null || true
    say "STOP"
    exit 0
}
trap cleanup TERM INT HUP

# Host starts in idle mode (sends a standby JPEG to keep the producer fed),
# so STOP is safe to emit at startup. We toggle GO/STOP on consumer
# open/close. lsof -t filters out our own producer FFPID so we count only
# external consumers.
WAS_ON=0
say "STOP"
consumers_open() {
    lsof -t "$DEV" 2>/dev/null | grep -vx "$FFPID" | head -1
}
while :; do
    if [[ -n "$(consumers_open)" ]]; then
        (( WAS_ON )) || { say "GO";   WAS_ON=1; }
    else
        (( WAS_ON )) && { say "STOP"; WAS_ON=0; }
    fi
    sleep 0.25
done
SH
chmod +x /usr/local/sbin/maix-camera-supervisor

# CLI: write NEXT through the supervisor's FIFO so there's no virtio-port
# contention. Runs unprivileged as long as the user is in the 'video' group.
cat >/usr/local/bin/maix-next-camera <<'SH'
#!/usr/bin/env bash
printf 'NEXT\n' > /run/maix-camera.fifo
SH
chmod +x /usr/local/bin/maix-next-camera

# Desktop entry so it appears in the app grid / search as "Swap Camera".
cat >/usr/share/applications/maix-swap-camera.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Swap Camera
Comment=Cycle to the next host camera (built-in, external, Continuity)
Exec=/usr/local/bin/maix-next-camera
Icon=camera-web-symbolic
Terminal=false
Categories=Utility;Video;
EOF

# Remove any old udev rule from a previous install — the virtio port is now
# supervisor-exclusive; unprivileged access goes through the FIFO instead.
rm -f /etc/udev/rules.d/99-maix-camera.rules
udevadm control --reload 2>/dev/null || true

cat >/etc/systemd/system/maix-camera.service <<'EOF'
[Unit]
Description=Maix camera supervisor (lazy MJPEG from host → /dev/video0)
After=systemd-modules-load.service akmods.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/maix-camera-supervisor
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now maix-camera.service

#---------------------------------------------------------------------------
msg "[6/6] Smoke test"

sleep 1
if v4l2-ctl --list-devices 2>/dev/null | grep -q MaixCamera; then
    msg "MaixCamera visible at $DEV."
else
    warn "MaixCamera not listed yet. Check: systemctl status maix-camera"
fi

cat <<EOF

Done.

After future \`dnf upgrade; reboot\`, akmods rebuilds v4l2loopback for the new
kernel on first boot (as long as kernel-devel is kept installed, which this
script does). No manual steps.

Troubleshoot:
  systemctl status akmods maix-camera
  journalctl -u akmods -b
  journalctl -u maix-camera -b
  v4l2-ctl --list-devices
  ls /lib/modules/\$(uname -r)/extra/v4l2loopback/
EOF
