#!/usr/bin/env bash
# Clean removal + workspace tidy-up.
# Removes the installed DKMS package. Leaves ./src and ./archive intact.
set -Eeuo pipefail
SUDO=""; [[ $EUID -ne 0 ]] && SUDO="sudo"
echo "[*] Removing mediatek-mt7927-dkms…"
$SUDO dpkg -r mediatek-mt7927-dkms 2>/dev/null || echo "[!] Package was not installed."
echo "[*] Remaining DKMS state:"
dkms status | grep -i mediatek-mt7927 || echo "    (none)"
echo "[✓] Done. Reboot for a clean module state."
