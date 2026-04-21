# MT7927 WiFi 7 + MT6639 Bluetooth — One-Click Ubuntu Installer

A thin, reproducible wrapper around
[`jetm/mediatek-mt7927-dkms`](https://github.com/jetm/mediatek-mt7927-dkms) that
turns driver installation into a single command, and always rebuilds from the
latest upstream source so it keeps working across kernel upgrades and Ubuntu
reinstalls.

> **All credit for the actual driver work goes to upstream author
> [@jetm](https://github.com/jetm) and contributors.** This repo only provides
> a packaging/automation layer.

---

## 🎯 Target hardware

MediaTek **MT7927** (WiFi 7, Filogic 380) + **MT6639** (Bluetooth 5.4) combo
module. This is the WiFi/BT chipset soldered onto many modern
AM5 / LGA1851 motherboards, including:

- **ASUS ProArt X870E-Creator WiFi**
- **ASUS ROG Crosshair X870E Hero**
- **ASUS ROG Strix X870-I Gaming WiFi**
- **ASUS ROG Strix X870E-E / X870E-F Gaming WiFi**
- Other boards shipping the same MediaTek combo module

### How to check your machine

```bash
lspci -nn | grep -i mediatek        # should show  [14c3:7927]
lsusb   | grep -iE '0489:e13a|0e8d' # MT6639 BT (VID:PID varies per vendor)
```

If the PCI ID `14c3:7927` shows up, you're in the right place. Full upstream
support list: see [upstream README](https://github.com/jetm/mediatek-mt7927-dkms).

---

## 💻 Target operating system

- **Ubuntu 24.04 LTS** (primary — tested)
- **Ubuntu 25.04 / 25.10** (should work — the installer auto-detects and uses
  the right kernel meta-package)
- Kernel **≥ 6.17** is required by the upstream driver. The installer will
  upgrade the kernel for you if needed (`linux-generic-hwe-<VERSION>` on LTS,
  `linux-generic` on interim releases).

Other Debian-based distros *might* work but are unsupported here — use
upstream directly.

---

## ⚙️ What the installer does

Everything happens inside `~/Workspace/drivers/mt7927/` (or wherever you
clone this repo). No stray files elsewhere, except the unavoidable system
paths required by the kernel (`/usr/src`, `/lib/modules`, `/usr/lib/firmware`).

Step by step, `install.sh`:

1. **Updates apt** and **installs/upgrades the kernel + headers** to the
   latest available meta-package for your release.
2. **Installs build dependencies**: `dkms`, `make`, `gcc`, `python3`, `curl`,
   `git`, `dpkg-dev`, `debhelper`, `build-essential`,
   `linux-headers-$(uname -r)`.
3. **Fresh-clones upstream source** into `./src/` on every run
   (`git clean -fdx` + re-clone — never trusts stale build artifacts).
4. Runs `make download && make deb`, which:
   - Downloads the mainline kernel source tarball (patches apply against it).
   - Downloads ASUS's official Windows driver zip to extract firmware blobs.
   - Applies the MT7927 WiFi and MT6639 Bluetooth patches.
   - Builds a versioned `.deb` package.
5. **Archives every built `.deb`** to `./archive/` with a timestamp for
   rollback.
6. `sudo dpkg -i` the freshly built `.deb`. DKMS builds the modules for every
   installed kernel and registers `dkms autoinstall` so **future kernel
   upgrades rebuild automatically**.
7. Verifies: `dkms status`, PCI/USB detection, installed modules, firmware
   files on disk.
8. Prints reboot instructions (see *Known issues* below for why live module
   reload is avoided).

All output is also saved to `install-YYYYMMDD-HHMMSS.log`.

### What the installer does **not** do

- Reboot your machine (it tells you to).
- Touch `/etc/network/*` or NetworkManager config.
- Push anything anywhere.

---

## 🚀 Usage

### First-time install

```bash
git clone https://github.com/camopel/mt7927-ubuntu-installer.git ~/Workspace/drivers/mt7927
cd ~/Workspace/drivers/mt7927
./install.sh
sudo reboot
```

The script uses `sudo` internally — it'll prompt once if passwordless sudo
isn't configured.

### Verify after reboot

```bash
dkms status                          # mediatek-mt7927/<ver>: installed
lspci -nnk | grep -A3 14c3           # 'Kernel driver in use: mt7925e'
ip link                              # new wlpXsY interface present
rfkill list                          # WiFi + Bluetooth both unblocked
dmesg | grep -iE 'mt79|mediatek|bluetooth'
```

### Re-run (upgrade to latest upstream patches)

Just run it again:

```bash
cd ~/Workspace/drivers/mt7927 && ./install.sh
```

Every run re-clones upstream, so you always get the newest fixes.

### After a kernel upgrade

Nothing to do — DKMS rebuilds automatically via `dkms autoinstall`. If you
want to force it:

```bash
sudo dkms autoinstall
```

### After a fresh Ubuntu reinstall

1. Clone (or restore) this repo to `~/Workspace/drivers/mt7927`.
2. `./install.sh`
3. `sudo reboot`

### Uninstall

```bash
sudo ./uninstall.sh
# equivalent to: sudo dpkg -r mediatek-mt7927-dkms
```

This removes the DKMS source, compiled modules, and firmware blobs cleanly.

---

## 📁 Layout

```
~/Workspace/drivers/mt7927/
├── install.sh                   # one-click entry point (always rebuilds from source)
├── uninstall.sh                 # sudo dpkg -r mediatek-mt7927-dkms
├── README.md                    # this file
├── LICENSE                      # MIT
├── src/                         # upstream source (re-cloned each run, gitignored)
└── archive/                     # every built .deb, timestamped (gitignored)
```

System paths touched by the `.deb` (managed by dpkg + DKMS, not this repo):

- `/usr/src/mediatek-mt7927-<ver>/` — DKMS source tree
- `/lib/modules/$(uname -r)/updates/dkms/*.ko` — compiled modules
  (`mt7925e`, `mt7921e`, `mt76*`, `btusb`, `btmtk`, …)
- `/usr/lib/firmware/mediatek/mt7927/` — firmware blobs

---

## ⚠️ Known issues (inherited from upstream)

- **Bluetooth vanishes after module reload / DKMS upgrade.** A normal reboot
  is **not** enough to recover it — the MT6639 BT firmware locks up and needs
  a **full power drain**: shut down, flip the PSU switch off (or unplug the
  cord), wait ~10 seconds, power back on. See
  [upstream #23](https://github.com/jetm/mediatek-mt7927-dkms/issues/23).
- **WiFi TX retransmissions** are higher than on Windows — firmware-side,
  not driver-fixable
  ([upstream #26](https://github.com/jetm/mediatek-mt7927-dkms/issues/26)).
- **AP mode @ 80 MHz** is ~295–570 Mbps (vs ~700 Mbps on Windows).
  NetworkManager hotspots default to 20 MHz — use `hostapd` for wider channels
  ([upstream #36](https://github.com/jetm/mediatek-mt7927-dkms/issues/36)).

---

## 🙏 Credits

This installer is a pure convenience layer. **All driver development,
patches, and firmware integration work is done by upstream:**

- 📦 **Upstream driver**: <https://github.com/jetm/mediatek-mt7927-dkms> — by [@jetm](https://github.com/jetm)
- 📝 **Background blog post**: <https://jetm.github.io/blog/posts/mt7927-wifi-the-missing-piece/>
- 🧵 **Community gist**: <https://gist.github.com/vitaliemiron/c23d7b2e47ab67a7a0851f6ef0cada39>
- 💬 **Reddit writeup**: <https://www.reddit.com/r/Ubuntu/comments/1rjepzd/fix_asus_proart_x870e_mt7927_14c36639_wifi_not/>

Please star/sponsor the upstream repo if this helps you.

---

## 📄 License

Installer scripts in this repo: **MIT** (see `LICENSE`).
Upstream DKMS driver: carries its own license — see the `src/` tree after
running the installer.
