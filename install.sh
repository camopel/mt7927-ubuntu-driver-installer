#!/usr/bin/env bash
# ============================================================================
#  ASUS X870E (and friends) — MediaTek MT7927 WiFi 7 + MT6639 BT 5.4
#  One-click installer for Ubuntu / Debian-based distros (kernel 6.17+)
#
#  Workflow:
#    1. apt update + upgrade kernel + headers to latest available
#    2. Install build deps (dkms, make, gcc, etc.)
#    3. (Re)clone latest upstream jetm/mediatek-mt7927-dkms to ./src
#    4. Build fresh .deb (never reuses stale artifacts)
#    5. Archive .deb to ./archive/ with timestamp
#    6. dpkg -i → DKMS auto-builds modules for running + installed kernels
#    7. Verify, print status + reboot hint
#
#  All source/build/archive stays under this directory.
#  Installed files go to standard system paths (required for the kernel
#  to load modules/firmware):
#      /usr/src/mediatek-mt7927-<ver>/
#      /lib/modules/$(uname -r)/updates/dkms/*.ko
#      /usr/lib/firmware/mediatek/
#  Clean removal:  sudo dpkg -r mediatek-mt7927-dkms
# ============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/src"
ARCHIVE_DIR="$SCRIPT_DIR/archive"
UPSTREAM_REPO="https://github.com/jetm/mediatek-mt7927-dkms.git"
TS="$(date +%Y%m%d-%H%M%S)"
LOG="$SCRIPT_DIR/install-$TS.log"

# ── colors ─────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YLW=$'\e[33m'; C_BLU=$'\e[34m'
    C_BLD=$'\e[1m'; C_RST=$'\e[0m'
else
    C_RED=""; C_GRN=""; C_YLW=""; C_BLU=""; C_BLD=""; C_RST=""
fi
log()  { echo -e "${C_BLU}[*]${C_RST} $*" | tee -a "$LOG"; }
ok()   { echo -e "${C_GRN}[✓]${C_RST} $*" | tee -a "$LOG"; }
warn() { echo -e "${C_YLW}[!]${C_RST} $*" | tee -a "$LOG"; }
err()  { echo -e "${C_RED}[✗]${C_RST} $*" | tee -a "$LOG" >&2; }

trap 'err "Install failed at line $LINENO (see $LOG)"' ERR

banner() {
    cat <<EOF
${C_BLD}================================================================
  MT7927 WiFi 7 + MT6639 BT one-click installer
  Target: running kernel $(uname -r) on $(. /etc/os-release; echo "$PRETTY_NAME")
  Log:    $LOG
================================================================${C_RST}
EOF
}

# ── sanity ─────────────────────────────────────────────────────────────────
require_root_cached() {
    if [[ $EUID -eq 0 ]]; then SUDO=""; return; fi
    if sudo -n true 2>/dev/null; then SUDO="sudo -n"; return; fi
    log "Sudo password required (cached for this run)…"
    sudo -v
    SUDO="sudo"
}

check_os() {
    if [[ ! -r /etc/os-release ]]; then
        err "Not a systemd-based Linux (no /etc/os-release)"; exit 1
    fi
    . /etc/os-release
    case "${ID_LIKE:-$ID}" in
        *debian*|*ubuntu*) ok "Distro: $PRETTY_NAME (apt-based)";;
        *) err "This installer supports Debian/Ubuntu-based distros only. Detected: $PRETTY_NAME"; exit 1;;
    esac
}

check_hw() {
    local wifi bt
    wifi=$(lspci -nn 2>/dev/null | grep -iE '14c3:(7927|6639|0738)' || true)
    bt=$(lsusb 2>/dev/null | grep -iE '0489:e13a|0489:e10f|0489:e110|0489:e0fa|0489:e116|13d3:3588' || true)
    if [[ -n "$wifi" ]]; then ok "MT7927/6639/0738 WiFi PCIe detected:"; echo "    $wifi"
    else warn "No MediaTek MT7927/6639/0738 WiFi PCIe device detected — continuing anyway."; fi
    if [[ -n "$bt" ]]; then ok "MediaTek BT USB detected:"; echo "    $bt"
    else warn "No MediaTek BT USB device detected — continuing anyway."; fi
}

check_kernel() {
    local kver major minor
    kver=$(uname -r)
    major=$(echo "$kver" | cut -d. -f1)
    minor=$(echo "$kver" | cut -d. -f2)
    if (( major < 6 || (major == 6 && minor < 17) )); then
        warn "Current kernel $kver is below 6.17 — installer will try to upgrade."
    else
        ok "Kernel $kver meets 6.17+ requirement."
    fi
}

# ── steps ──────────────────────────────────────────────────────────────────
apt_refresh() {
    log "apt-get update…"
    $SUDO apt-get update -qq
}

upgrade_kernel() {
    log "Upgrading kernel + headers to latest available…"
    . /etc/os-release
    local ubver="${VERSION_ID:-}"
    local meta_candidates=()

    # Prefer HWE meta-packages on Ubuntu LTS releases; fall back to generic.
    if [[ "$ID" == "ubuntu" && -n "$ubver" ]]; then
        meta_candidates+=(
            "linux-generic-hwe-${ubver}"
            "linux-image-generic-hwe-${ubver}"
            "linux-headers-generic-hwe-${ubver}"
        )
    fi
    meta_candidates+=( linux-generic linux-image-generic linux-headers-generic )

    local to_install=()
    for pkg in "${meta_candidates[@]}"; do
        if apt-cache show "$pkg" >/dev/null 2>&1; then to_install+=("$pkg"); fi
    done

    if (( ${#to_install[@]} == 0 )); then
        warn "No kernel meta-package candidates available — skipping upgrade."
        return
    fi

    log "Installing/upgrading: ${to_install[*]}"
    DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y "${to_install[@]}" \
        | tee -a "$LOG" | tail -20
    # Ensure headers for the currently running kernel are present (needed now for DKMS build)
    DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y "linux-headers-$(uname -r)" 2>&1 \
        | tee -a "$LOG" | tail -5 || warn "linux-headers-$(uname -r) not available — DKMS may fail."
    ok "Kernel upgrade step complete."
}

install_build_deps() {
    log "Installing build dependencies…"
    DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y \
        dkms make gcc python3 curl git dpkg-dev debhelper build-essential \
        | tee -a "$LOG" | tail -5
    ok "Build deps ready."
}

fetch_source() {
    mkdir -p "$SRC_DIR"
    if [[ -d "$SRC_DIR/.git" ]]; then
        log "Refreshing upstream source in $SRC_DIR…"
        git -C "$SRC_DIR" fetch --all --tags --prune
        git -C "$SRC_DIR" reset --hard origin/HEAD
        git -C "$SRC_DIR" clean -fdx
    else
        log "Cloning $UPSTREAM_REPO → $SRC_DIR…"
        rm -rf "$SRC_DIR"
        git clone --depth 1 "$UPSTREAM_REPO" "$SRC_DIR"
    fi
    ok "Source at commit: $(git -C "$SRC_DIR" log -1 --oneline)"
}

build_deb() {
    log "Building .deb (this downloads the kernel tarball + ASUS firmware zip)…"
    (cd "$SRC_DIR" && make download) 2>&1 | tee -a "$LOG" | tail -5
    (cd "$SRC_DIR" && make deb) 2>&1 | tee -a "$LOG" | tail -10

    local deb
    deb=$(ls -1t "$SRC_DIR"/mediatek-mt7927-dkms_*.deb 2>/dev/null | head -1)
    if [[ -z "$deb" || ! -f "$deb" ]]; then
        err "No .deb produced in $SRC_DIR"; exit 1
    fi

    mkdir -p "$ARCHIVE_DIR"
    local archived="$ARCHIVE_DIR/$(basename "$deb" .deb)_$TS.deb"
    cp -f "$deb" "$archived"
    ok "Built:    $deb"
    ok "Archived: $archived"
    echo "$deb" > "$SCRIPT_DIR/.last-deb"
}

install_deb() {
    local deb
    deb=$(cat "$SCRIPT_DIR/.last-deb")
    log "Installing $deb (DKMS will build for all installed kernels)…"
    DEBIAN_FRONTEND=noninteractive $SUDO dpkg -i "$deb" 2>&1 | tee -a "$LOG" | tail -30 || {
        warn "dpkg reported an issue — attempting apt-get -f install to fix deps…"
        $SUDO apt-get -y -f install 2>&1 | tee -a "$LOG" | tail -10
    }
    ok "Package installed."
}

verify() {
    log "Verifying…"
    echo "── dkms status ─────────────────────────────"
    dkms status mediatek-mt7927 || true
    echo "── WiFi PCIe ───────────────────────────────"
    lspci -nnk | grep -A3 -iE 'mediatek|14c3:' || true
    echo "── BT USB ──────────────────────────────────"
    lsusb | grep -iE '0489|13d3|0e8d' || true
    echo "── Installed modules (running kernel) ──────"
    find "/lib/modules/$(uname -r)/updates/dkms/" -maxdepth 1 -type f 2>/dev/null \
        | grep -E 'mt76|mt7921|mt7925|btusb|btmtk' || warn "No DKMS modules in /lib/modules/$(uname -r)/updates/dkms/"
    echo "── Firmware ────────────────────────────────"
    ls /usr/lib/firmware/mediatek/mt7927/ 2>/dev/null || warn "Firmware dir /usr/lib/firmware/mediatek/mt7927/ missing"
}

post_install_notes() {
    cat <<EOF

${C_GRN}${C_BLD}Install complete.${C_RST}

${C_BLD}Next step — reboot.${C_RST}
  The in-kernel mt76/mt7921 modules are currently loaded (probably serving a
  USB WiFi dongle). A simple modprobe swap cannot safely replace them without
  risking symbol-version mismatches on the live kernel. After reboot, the
  DKMS modules in /lib/modules/\$(uname -r)/updates/dkms/ take priority and
  mt7925e will bind to the MT7927 PCIe device automatically.

${C_YLW}${C_BLD}Known Bluetooth gotcha${C_RST} (from upstream README):
  After DKMS upgrades / module reloads the MT6639 BT may disappear and stay
  gone across normal reboots. Recovery: ${C_BLD}full power drain${C_RST} —
  shut down, switch PSU off at the back / unplug the power cable, wait
  ~10 seconds, then power on again. A plain reboot is not enough.

Clean removal:
  sudo dpkg -r mediatek-mt7927-dkms

Rebuild after a kernel upgrade (DKMS normally does this automatically):
  sudo dkms autoinstall

Log: $LOG
EOF
}

# ── main ───────────────────────────────────────────────────────────────────
main() {
    banner
    require_root_cached
    check_os
    check_kernel
    check_hw
    apt_refresh
    upgrade_kernel
    install_build_deps
    fetch_source
    build_deb
    install_deb
    verify
    post_install_notes
}

main "$@"
