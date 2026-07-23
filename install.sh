#!/usr/bin/env bash
# justc-nixos one-shot installer — v7
#
# Run it from the live USB, from any state, as many times as you like:
#   rm -rf ~/i && git clone https://github.com/lovergirldev/mynixconfig ~/i && bash ~/i/install.sh
#
# v7 changes on top of v6:
#   * Limine is the bootloader now. Old systemd-boot leftovers on THIS disk's
#     ESP are cleared first so the two can't both claim \EFI\BOOT.
#   * Finds the Windows ESP by NTFS-neighbour + verifies bootmgfw.efi is
#     really there, then writes its filesystem UUID into boot.nix. That closes
#     the "Windows boot entry" item for good — no more EDK2 shell + map -c.
#     Addressing by UUID is immune to the nvme name swap.
#   * Everything else (disk safety, fresh @ subvolume, dotfiles-before-install,
#     niri self-check) is unchanged from v6.
set -euo pipefail

FRESH="${FRESH:-1}"

msg(){ echo; echo "==> $*"; }
die(){ echo; echo "!!! $*"; echo "!!! Photo this screen and send it to Claude."; exit 1; }

setterm -blank 0 -powerdown 0 2>/dev/null || true

# ---------------------------------------------------------------- 1. sources
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
msg "Preparing config from: $SRC"

if [ ! -f "$SRC/flake.nix" ] && [ ! -e "$SRC/justc-nixos/flake.nix" ] && [ -f "$SRC/justc-nixos.zip" ]; then
  ( cd "$SRC"
    if   command -v unzip   >/dev/null 2>&1; then unzip -oq justc-nixos.zip
    elif command -v python3 >/dev/null 2>&1; then python3 -m zipfile -e justc-nixos.zip .
    else nix --extra-experimental-features "nix-command flakes" shell nixpkgs#unzip -c unzip -oq justc-nixos.zip
    fi )
fi

FLAKE_FILE="$(find "$SRC" -maxdepth 3 -name flake.nix -not -path '*/.git/*' | head -1)"
[ -n "$FLAKE_FILE" ] || die "flake.nix not found next to install.sh"

BUILD="$HOME/justc-build"
rm -rf "$BUILD"
cp -r "$(dirname "$FLAKE_FILE")" "$BUILD"
rm -rf "$BUILD/.git"
cd "$BUILD"
echo "    Building from: $BUILD"

# ------------------------------------------------------------ 2. find drives
msg "Finding the encrypted NixOS drive (by type, never by nvme name)"
LUKS_PART="$(lsblk -rno NAME,FSTYPE | awk '$2=="crypto_LUKS"{print $1; exit}')"
[ -n "$LUKS_PART" ] || die "no LUKS partition found — is the right disk plugged in?"
LUKS_DEV="/dev/$LUKS_PART"
DISK="$(lsblk -rno PKNAME "$LUKS_DEV" | head -1)"
ESP_DEV="/dev/${DISK}p1"

SIZE="$(lsblk -bdno SIZE "/dev/$DISK")"
[ "$SIZE" -gt 700000000000 ] || die "the LUKS disk is only $((SIZE/1000000000)) GB — expected the 953 GB one. Stopping before touching anything."

echo "    Encrypted: $LUKS_DEV    ESP: $ESP_DEV    ($((SIZE/1000000000)) GB — Windows disk untouched)"

TARGET="/dev/$DISK"
for link in /dev/disk/by-id/*; do
  case "$link" in *-part*) continue;; esac
  [ "$(readlink -f "$link" 2>/dev/null)" = "/dev/$DISK" ] && TARGET="$link" && break
done
echo "    Stable ID: $TARGET"
sed -i -E "s#device = \"/dev/nvme[^\"]*\";#device = \"$TARGET\";#" hosts/justc/disko.nix
sed -i -E "s#device = \"/dev/disk/by-id/[^\"]*\";#device = \"$TARGET\";#" hosts/justc/disko.nix

# --------------------------------------------- 2b. find the Windows ESP (NEW)
msg "Looking for the Windows ESP (for the Limine boot entry)"
WIN_UUID=""
NTFS_PART="$(lsblk -rno NAME,FSTYPE | awk '$2=="ntfs"{print $1; exit}')"
if [ -n "$NTFS_PART" ]; then
  WIN_DISK="$(lsblk -rno PKNAME "/dev/$NTFS_PART" | head -1)"
  if [ -n "$WIN_DISK" ] && [ "$WIN_DISK" != "$DISK" ]; then
    for p in $(lsblk -rno NAME,FSTYPE "/dev/$WIN_DISK" | awk '$2=="vfat"{print $1}'); do
      probe="$(mktemp -d)"
      if sudo mount -o ro "/dev/$p" "$probe" 2>/dev/null; then
        if [ -f "$probe/EFI/Microsoft/Boot/bootmgfw.efi" ]; then
          WIN_UUID="$(sudo blkid -s UUID -o value "/dev/$p" 2>/dev/null || true)"
          sudo umount "$probe"; rmdir "$probe"
          break
        fi
        sudo umount "$probe"
      fi
      rmdir "$probe" 2>/dev/null || true
    done
  fi
fi

if [ -n "$WIN_UUID" ]; then
  sed -i -E "s#windowsEspUuid = \"[^\"]*\";#windowsEspUuid = \"$WIN_UUID\";#" hosts/justc/boot.nix
  echo "    Windows ESP found, UUID $WIN_UUID — boot entry will be created"
else
  echo "    No Windows ESP found (or bootmgfw.efi missing). Skipping that entry;"
  echo "    F12 at power-on still reaches Windows. Nothing is broken by this."
fi

# ------------------------------------------------------------ 3. lock flake
msg "Pre-locking the flake (prevents the NAR-hash mismatch)"
nix --extra-experimental-features "nix-command flakes" flake lock

# ------------------------------------------------------------ 4. clean state
msg "Clearing leftovers from earlier runs"
sudo swapoff -a 2>/dev/null || true
sudo umount -R /mnt 2>/dev/null || true
sudo umount -R /btr 2>/dev/null || true

if [ ! -e /dev/mapper/cryptroot ]; then
  msg "Unlocking — TYPE YOUR PASSPHRASE (nothing shows as you type)"
  sudo cryptsetup open "$LUKS_DEV" cryptroot \
    || die "unlock failed (typo?) — just run the same one-line command again"
else
  msg "Drive already unlocked — continuing"
fi

# ------------------------------------------- 5. fresh root subvolume (or not)
if [ "$FRESH" = "1" ]; then
  msg "Making a FRESH root subvolume (keeping /home and /nix)"
  sudo mkdir -p /btr
  sudo mount -o subvolid=5 /dev/mapper/cryptroot /btr

  if sudo btrfs subvolume show /btr/@ >/dev/null 2>&1; then
    sudo btrfs subvolume list -o /btr/@ | awk '{print $NF}' | tac | while read -r sub; do
      sudo btrfs subvolume delete "/btr/${sub#@/}" 2>/dev/null \
        || sudo btrfs subvolume delete "/btr/$sub" 2>/dev/null || true
    done
    sudo btrfs subvolume delete /btr/@ || die "could not remove the old root subvolume"
    echo "    old root removed"
  fi
  sudo btrfs subvolume create /btr/@ >/dev/null
  for s in @home @nix @snapshots; do
    sudo btrfs subvolume show "/btr/$s" >/dev/null 2>&1 || sudo btrfs subvolume create "/btr/$s" >/dev/null
  done
  sudo umount /btr
  echo "    fresh @ created; @home / @nix / @snapshots kept"
else
  msg "FRESH=0 — installing in place over the existing root"
fi

# ---------------------------------------------------------------- 6. mount
msg "Mounting"
sudo mount -o compress=zstd,noatime,subvol=@ /dev/mapper/cryptroot /mnt
sudo mkdir -p /mnt/boot /mnt/home /mnt/nix /mnt/.snapshots
sudo mount -o compress=zstd,noatime,subvol=@home /dev/mapper/cryptroot /mnt/home
sudo mount -o compress=zstd,noatime,subvol=@nix /dev/mapper/cryptroot /mnt/nix
sudo mount -o compress=zstd,noatime,subvol=@snapshots /dev/mapper/cryptroot /mnt/.snapshots
sudo mount "$ESP_DEV" /mnt/boot
findmnt -n /mnt >/dev/null      || die "root mount failed"
findmnt -n /mnt/boot >/dev/null || die "boot mount failed"
echo "    mounts OK"

# -------------------------------------------- 6b. boot hygiene (Limine-aware)
# THIS disk's ESP only. Windows lives on the other disk and is never touched.
msg "Clearing old bootloader files from this disk's ESP"
sudo rm -rf /mnt/boot/loader/entries/nixos-generation-*.conf \
            /mnt/boot/loader/loader.conf \
            /mnt/boot/EFI/nixos \
            /mnt/boot/EFI/systemd \
            /mnt/boot/EFI/Linux \
            /mnt/boot/limine \
            /mnt/boot/limine.conf 2>/dev/null || true
sudo rm -f /mnt/boot/EFI/BOOT/BOOTX64.EFI 2>/dev/null || true
echo "    systemd-boot and any previous Limine files removed"

# ------------------------------------------------------------ 7. hardware
msg "Hardware detection"
sudo nixos-generate-config --no-filesystems --root /mnt
sudo cp /mnt/etc/nixos/hardware-configuration.nix hosts/justc/hardware-configuration.nix

# --------------------------------------- 8. config + dotfiles BEFORE install
msg "Placing your config and dotfiles (real copies, before the install)"
U=/mnt/home/lovergirlonline
sudo mkdir -p "$U"
sudo rm -rf "$U/nixos"
sudo cp -r "$BUILD" "$U/nixos"
sudo HOME="$U" bash "$U/nixos/dotfiles/link.sh" >/dev/null
sudo chown -R 1000:100 "$U"
echo "    ~/nixos + ~/.config populated"

# --------------------------------------------------------------- 9. install
msg "INSTALLING — the long part. Let it run; there are no prompts."
echo "    (first run pulls Affinity's Wine from cache.garnix.io instead of"
echo "     building it — that substituter is baked in now)"
sudo NIXPKGS_ALLOW_UNFREE=1 NIXPKGS_ALLOW_INSECURE=1 \
  nixos-install --flake "$BUILD#justc" --no-root-passwd --impure

# ------------------------------------------------ 10. validate the niri config
msg "Checking the niri config inside the new system"
NIRI_CFG="/home/lovergirlonline/.config/niri/config.kdl"
if sudo nixos-enter --root /mnt -- bash -lc "niri validate -c $NIRI_CFG" >/dev/null 2>&1; then
  echo "    niri config OK (blur enabled)"
else
  echo "    this niri build rejected something — removing the blur block and retrying"
  sudo sed -i '/>>>BLUR/,/<<<BLUR/d' "$U/.config/niri/config.kdl" "$U/nixos/dotfiles/niri/config.kdl"
  if sudo nixos-enter --root /mnt -- bash -lc "niri validate -c $NIRI_CFG" >/dev/null 2>&1; then
    echo "    niri config OK (blur removed — everything else intact)"
  else
    echo "    !!! niri validate still unhappy. The system will still boot;"
    echo "    !!! log into KDE at SDDM and send Claude the output of:"
    echo "    !!!   niri validate -c ~/.config/niri/config.kdl"
  fi
fi

# ------------------------------------------------------ 11. verify Limine landed
msg "Verifying the bootloader"
if sudo test -f /mnt/boot/limine.conf || sudo test -d /mnt/boot/limine; then
  echo "    Limine installed on the ESP"
  sudo grep -q 'Windows' /mnt/boot/limine.conf 2>/dev/null \
    && echo "    Windows 11 entry present" \
    || echo "    (no Windows entry — use F12 for now)"
else
  echo "    !!! Limine files not found on the ESP."
  echo "    !!! The system may still boot via the EFI variable, but if it does"
  echo "    !!! not: open hosts/justc/boot.nix, change the line"
  echo "    !!!     loader = \"limine\";"
  echo "    !!! to  loader = \"systemd-boot\";"
  echo "    !!! and re-run this same one-liner. That is the whole rollback."
fi

msg "Pre-applying theme names inside the new system"
sudo nixos-enter --root /mnt -- bash -lc \
  "su - lovergirlonline -c theme-apply" >/dev/null 2>&1 \
  && echo "    theme names written" \
  || echo "    (skipped — it runs itself at first login anyway)"
sudo chown -R 1000:100 "$U" 2>/dev/null || true

echo
echo "===================================================="
echo "  DONE."
echo "  1) sudo reboot         2) pull the USB stick"
echo "  3) Limine menu appears — NixOS is the default"
echo "  4) type your passphrase"
echo "  5) log in: lovergirlonline / changeme"
echo "  6) first commands:  passwd     then     nmtui"
echo
echo "  The theme applies itself at login. Nothing to run."
echo
echo "  Mod+T terminal · Mod+D launcher · Mod+E files"
echo "  Mod+X power menu · Ctrl+Alt+T works without Super"
echo "  fastfetch  ·  nvix (nixvim)  ·  bootcfg (Limine menu)"
echo "===================================================="
