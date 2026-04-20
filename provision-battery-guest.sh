#!/bin/bash
# provision-battery-guest.sh — run INSIDE the Fedora guest.
#
# Host-to-guest battery mirror. Fedora aarch64 builds its kernel with
# CONFIG_TEST_POWER=n, so we fetch upstream test_power.c, build it against
# the running kernel headers, and install it out-of-tree. A boot-time
# oneshot rebuilds for new kernels.
#
# Host pushes JSON lines on power-source events (plug/unplug, percentage,
# state). Guest daemon relays into /sys/module/test_power/parameters/*;
# upower/GNOME pick up the resulting /sys/class/power_supply/test_battery
# automatically.
#
# Safe to run repeatedly.

set -Eeuo pipefail

PORT=/dev/virtio-ports/com.cmuav.battery

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
msg "[1/5] Build toolchain + headers"
dnf install -y --setopt=install_weak_deps=False \
    gcc make \
    "kernel-devel-${KVER}" \
    python3

#---------------------------------------------------------------------------
msg "[2/5] Install patched test_power.c into /usr/src/maix-test-power"
# Source is maintained in guest-assets/test_power.c alongside this script;
# copy it in via scp before running, or place it at /tmp/test_power.c.
SRC=/usr/src/maix-test-power
mkdir -p "$SRC"
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
for candidate in "$SCRIPT_DIR/test_power.c" "/tmp/test_power.c"; do
    if [[ -f "$candidate" ]]; then
        install -m 0644 "$candidate" "$SRC/test_power.c"
        break
    fi
done
[[ -f "$SRC/test_power.c" ]] || die \
    "test_power.c not found. scp guest-assets/test_power.c to /tmp/ first."

cat >"$SRC/Makefile" <<'MK'
obj-m := test_power.o
KDIR ?= /lib/modules/$(shell uname -r)/build
PWD  := $(shell pwd)
default:
	$(MAKE) -C $(KDIR) M=$(PWD) modules
clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
install: default
	install -D -m 0644 test_power.ko /lib/modules/$(shell uname -r)/extra/test_power.ko
	depmod -a
MK

#---------------------------------------------------------------------------
msg "[3/5] Build + install test_power for $KVER"
(
    cd "$SRC"
    make clean >/dev/null 2>&1 || true
    make -j"$(nproc)"
    make install
)
modprobe -r test_power 2>/dev/null || true
modprobe test_power
[[ -e /sys/class/power_supply/test_battery ]] || die \
    "modprobe succeeded but /sys/class/power_supply/test_battery missing."

cat >/etc/modules-load.d/maix-battery.conf <<'EOF'
test_power
EOF

#---------------------------------------------------------------------------
msg "[4/5] Boot-time rebuild hook for future kernel upgrades"
cat >/usr/local/sbin/maix-battery-ensure <<'SH'
#!/bin/bash
# If test_power.ko is missing for the running kernel, rebuild from the
# cached source tree. Mirrors the self-heal pattern used by akmods.
set -u
K="$(uname -r)"
if [[ -f "/lib/modules/${K}/extra/test_power.ko" ]] && modinfo -k "$K" test_power >/dev/null 2>&1; then
    exit 0
fi
SRC=/usr/src/maix-test-power
[[ -d "$SRC" ]] || { logger -t maix-battery-ensure "no source at $SRC"; exit 1; }
logger -t maix-battery-ensure "rebuilding test_power for $K"
( cd "$SRC" && make clean >/dev/null 2>&1 || true; make -j"$(nproc)" && make install )
SH
chmod +x /usr/local/sbin/maix-battery-ensure

cat >/etc/systemd/system/maix-battery-ensure.service <<'EOF'
[Unit]
Description=Rebuild test_power for the running kernel if missing
DefaultDependencies=no
After=local-fs.target
Before=systemd-modules-load.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/maix-battery-ensure
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
EOF

#---------------------------------------------------------------------------
msg "[5/5] Relay daemon"
cat >/usr/local/sbin/maix-battery-daemon <<'PY'
#!/usr/bin/env python3
# Reads one JSON object per line from the host's battery virtio-serial
# port and writes /sys/module/test_power/parameters/* accordingly. Idles
# at zero CPU between host events.
import json, os, sys

PORT = "/dev/virtio-ports/com.cmuav.battery"
SYS  = "/sys/module/test_power/parameters"

# test_power's battery_status setter accepts named strings (Charging,
# Discharging, Full) — not integers, and "Not charging" is silently
# coerced to Discharging. Send strings, map not_charging -> Charging
# when on AC so GNOME shows the plug icon.
STATUS_STR = {
    "charging":    "Charging",
    "discharging": "Discharging",
    "not_charging":"Charging",   # on AC but not filling = treat as charging for UI
    "full":        "Full",
}

# upower derives `state` from battery_current's sign, not from status.
# Feed a matching sign so GNOME shows charging/discharging correctly.
CURRENT_UA = {
    "charging":    1_500_000,
    "discharging":-1_500_000,
    "not_charging":       0,
    "full":               0,
}

def write_param(name, value):
    try:
        with open(os.path.join(SYS, name), "w") as f:
            f.write(str(value))
    except OSError as e:
        print(f"write {name}={value!r}: {e}", file=sys.stderr)

def kick_uevent(dev):
    # Force upower/udev to re-read properties. Only battery_capacity has a
    # setter in test_power that calls power_supply_changed(); the other
    # module_params don't notify, so GNOME keeps stale AC/status/time until
    # we poke the uevent interface ourselves.
    try:
        with open(f"/sys/class/power_supply/{dev}/uevent", "w") as f:
            f.write("change")
    except OSError as e:
        print(f"uevent kick {dev}: {e}", file=sys.stderr)

def apply(obj):
    pct = obj.get("pct")
    if isinstance(pct, int) and 0 <= pct <= 100:
        write_param("battery_capacity", pct)

    state = obj.get("state", "")
    if state in STATUS_STR:
        write_param("battery_status", STATUS_STR[state])
        write_param("battery_current", CURRENT_UA[state])

    ac = obj.get("on_ac")
    if isinstance(ac, bool):
        write_param("ac_online", 1 if ac else 0)

    # ttl_min is minutes; test_power expects seconds. Push to both the
    # "to empty" and "to full" slots — the POWER_SUPPLY layer exposes
    # whichever is relevant for the current state.
    ttl = obj.get("ttl_min")
    if isinstance(ttl, int) and ttl > 0:
        secs = ttl * 60
        write_param("battery_time_to_empty", secs)
        write_param("battery_time_to_full",  secs)

    kick_uevent("test_battery")
    kick_uevent("test_ac")

def main():
    with open(PORT, "rb", buffering=0) as f:
        for raw in f:
            line = raw.decode("utf-8", errors="replace").strip()
            if not line: continue
            try:
                apply(json.loads(line))
            except Exception as e:
                print(f"bad line {line!r}: {e}", file=sys.stderr)

if __name__ == "__main__":
    main()
PY
chmod +x /usr/local/sbin/maix-battery-daemon

cat >/etc/systemd/system/maix-battery.service <<'EOF'
[Unit]
Description=Maix battery relay (host power source -> test_battery)
After=systemd-modules-load.service maix-battery-ensure.service
Wants=maix-battery-ensure.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/maix-battery-daemon
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable maix-battery-ensure.service
systemctl enable --now maix-battery.service

sleep 1
if [[ -e /sys/class/power_supply/test_battery/capacity ]]; then
    msg "test_battery visible. Initial values:"
    for f in capacity status; do
        printf '  %-10s %s\n' "$f:" "$(cat /sys/class/power_supply/test_battery/$f 2>/dev/null || echo '(missing)')"
    done
    if [[ -e /sys/class/power_supply/test_ac/online ]]; then
        printf '  %-10s %s\n' "ac_online:" "$(cat /sys/class/power_supply/test_ac/online)"
    fi
else
    warn "test_battery not present. Check: systemctl status maix-battery"
fi

cat <<'EOF'

Done. GNOME should show a battery indicator within a few seconds (it
polls upower). Unplug/replug the Mac charger and the guest values
update live.

Troubleshoot:
  systemctl status maix-battery maix-battery-ensure
  journalctl -u maix-battery -b
  cat /proc/modules | grep test_power
EOF
