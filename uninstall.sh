#!/usr/bin/env bash
# Clean removal + workspace tidy-up.
# Removes the installed DKMS package. Leaves ./src and ./archive intact.
set -Eeuo pipefail
SUDO=""; [[ $EUID -ne 0 ]] && SUDO="sudo"
echo "[*] Removing mediatek-mt7927-dkms…"
$SUDO dpkg -r mediatek-mt7927-dkms 2>/dev/null || echo "[!] Package was not installed."
# WiFi firmware extracted by install.sh (when linux-firmware lacked it) is not
# owned by any package, so dpkg -r leaves it behind. Never touch package-owned files.
for f in /usr/lib/firmware/mediatek/mt7927/WIFI_*.bin; do
    [[ -e "$f" ]] || continue
    dpkg -S "$f" >/dev/null 2>&1 && continue
    echo "[*] Removing $f"
    $SUDO rm -f "$f"
done
echo "[*] Remaining DKMS state:"
dkms status | grep -i mediatek-mt7927 || echo "    (none)"
echo "[✓] Done. Reboot for a clean module state."
