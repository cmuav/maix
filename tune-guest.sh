#!/bin/bash
# tune-guest.sh — run INSIDE the Fedora guest. One-shot kernel / userspace
# tuning to complement the QEMU argv performance changes.
#
# Safe to run repeatedly.

set -Eeuo pipefail

msg()  { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*" >&2; }

if [[ $EUID -ne 0 ]]; then
    exec sudo -E bash "$0" "$@"
fi

trap 'warn "Failed at line $LINENO: $BASH_COMMAND"' ERR

#---------------------------------------------------------------------------
msg "[1/3] Kernel cmdline"
# mitigations=off: kiosk is local-only, the 8-15% hit from Spectre/Meltdown
# mitigations on aarch64 is not worth it here.
# clocksource=arch_sys_counter: ARMv8 generic counter is direct, no PIT.
# transparent_hugepage=madvise: fewer THP faults than the default 'always'.
CMDLINE_ADD="mitigations=off clocksource=arch_sys_counter transparent_hugepage=madvise"
GRUB=/etc/default/grub
cp "$GRUB" "$GRUB.maix.bak.$(date +%s)" 2>/dev/null || true

python3 - "$GRUB" "$CMDLINE_ADD" <<'PY'
import sys, re
path, add = sys.argv[1], sys.argv[2]
want = add.split()
text = open(path).read()
m = re.search(r'^GRUB_CMDLINE_LINUX="([^"]*)"', text, re.M)
if not m:
    print("no GRUB_CMDLINE_LINUX in", path, file=sys.stderr); sys.exit(1)
current = m.group(1).split()
# Drop conflicting versions of the keys we set, then append ours.
keys = {w.split('=', 1)[0] for w in want}
current = [w for w in current if w.split('=', 1)[0] not in keys]
current += want
new_line = 'GRUB_CMDLINE_LINUX="' + ' '.join(current) + '"'
text = text[:m.start()] + new_line + text[m.end():]
open(path, 'w').write(text)
print("updated", path)
PY
grub2-mkconfig -o /boot/grub2/grub.cfg >/dev/null

#---------------------------------------------------------------------------
msg "[2/3] tuned (virtual-guest profile)"
dnf install -y --setopt=install_weak_deps=False tuned >/dev/null
systemctl enable --now tuned.service >/dev/null
tuned-adm profile virtual-guest
tuned-adm active

#---------------------------------------------------------------------------
msg "[3/3] zram swap"
dnf install -y --setopt=install_weak_deps=False zram-generator-defaults >/dev/null
systemctl daemon-reload
systemctl restart systemd-zram-setup@zram0.service 2>/dev/null || true

# Net multi-queue intentionally not configured: slirp (user-mode netdev)
# is single-queue; adding combined channels on the guest side doesn't help
# and qemu rejects queues=N on virtio-net-pci without a tap/vhost backend.
# Revisit if we ever get com.apple.vm.networking + vmnet-shared.

cat <<'EOF'

Done. Kernel cmdline changes take effect on next reboot.

Verify:
  cat /proc/cmdline                        # after reboot
  tuned-adm active                         # -> virtual-guest
  cat /sys/block/vda/queue/scheduler       # -> [mq-deadline] or [none]
  zramctl                                  # -> zram0 entry
EOF
