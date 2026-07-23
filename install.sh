#!/usr/bin/env bash
# justc-nixos one-shot installer — v8
#
# Run it from the live USB, from any state, as many times as you like:
#   rm -rf ~/i && git clone https://github.com/lovergirldev/mynixconfig ~/i && bash ~/i/install.sh
#
# v8 changes on top of v7 — all four are things that can cost you a working
# laptop or several hours, and none of them changed the one-liner above:
#
#   * NOTHING TOUCHES THE DISK until the config has been proven to evaluate.
#     v7 deleted the old root subvolume at step 5 and did not evaluate a single
#     line of Nix until step 9. A typo or a renamed option anywhere in the tree
#     meant: old root gone, new system never built, laptop won't boot. This
#     session added Limine, an unstable kdePackages overlay, NUR and
#     nix-software-center — none of which have ever been evaluated on this
#     machine — so that was a live risk, not a theoretical one. Hardware
#     detection and a full dry-run evaluation now BOTH happen first.
#
#   * The garnix substituter is now passed to the INSTALL, not just written
#     into the installed system. hosts/justc/default.nix configures the nix
#     daemon of the system being built; the build itself is done by the live
#     USB's daemon, which never saw those settings. That is why Affinity's
#     patched Wine would still have compiled from source on the first run.
#
#   * niri validation no longer strips your blur block on a false positive.
#     v7 treated ANY non-zero exit — including "niri: command not found" or a
#     wrong CLI flag order — as "the config was rejected", and silently deleted
#     the blur region from both copies. It now tells those cases apart.
#
#   * The ESP is found by filesystem type and verified before anything is
#     deleted from it, instead of being assumed to be partition 1.
#
# Escape hatches:
#   FRESH=0      install in place over the existing root (keeps it)
#   PREFLIGHT=0  skip the dry-run evaluation (don't, unless it's misbehaving)

set -euo pipefail

FRESH="${FRESH:-1}"
PREFLIGHT="${PREFLIGHT:-1}"

# Substituters needed AT INSTALL TIME. Keep in sync with the list in
# hosts/justc/default.nix — that one is for the installed system, this one is
# for the live USB doing the building.
EXTRA_SUBS="https://cache.garnix.io https://nix-community.cachix.org"
EXTRA_KEYS="cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g= nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="

NIXFLAGS=(--extra-experimental-features "nix-command flakes")

msg(){ echo; echo "==> $*"; }
warn(){ echo "    !!! $*"; }
die(){ echo; echo "!!! $*"; echo "!!! Photo this screen and send it to Claude."; exit 1; }

setterm -blank 0 -powerdown 0 2>/dev/null || true

# ---------------------------------------------------------------- 1. sources
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
msg "Preparing config from: $SRC"

if [ ! -f "$SRC/flake.nix" ] && [ ! -e "$SRC/justc-nixos/flake.nix" ] && [ -f "$SRC/justc-nixos.zip" ]; then
  ( cd "$SRC"
    if   command -v unzip   >/dev/null 2>&1; then unzip -oq justc-nixos.zip
    elif command -v python3 >/dev/null 2>&1; then python3 -m zipfile -e justc-nixos.zip .
    else nix "${NIXFLAGS[@]}" shell nixpkgs#unzip -c unzip -oq justc-nixos.zip
    fi )
fi

FLAKE_FILE="$(find "$SRC" -maxdepth 3 -name flake.nix -not -path '*/.git/*' -print -quit)"
[ -n "$FLAKE_FILE" ] || die "flake.nix not found next to install.sh"

BUILD="$HOME/justc-build"
rm -rf "$BUILD"
cp -r "$(dirname "$FLAKE_FILE")" "$BUILD"
rm -rf "$BUILD/.git"
cd "$BUILD"
echo "    Building from: $BUILD"

for f in flake.nix hosts/justc/disko.nix hosts/justc/boot.nix dotfiles/link.sh; do
  [ -e "$BUILD/$f" ] || die "the config tree is missing $f — is the zip complete?"
done
echo "    config tree looks complete"

# ------------------------------------------------------------ 2. find drives
msg "Finding the encrypted NixOS drive (by type, never by nvme name)"
LUKS_PART="$(lsblk -rno NAME,FSTYPE | awk '$2=="crypto_LUKS"{print $1; exit}')"
[ -n "$LUKS_PART" ] || die "no LUKS partition found.
!!! This installer REINSTALLS onto an already-partitioned disk; it does not
!!! partition a blank one. If the disk really is blank you need the disko
!!! step from README first."
LUKS_DEV="/dev/$LUKS_PART"
DISK="$(lsblk -rno PKNAME "$LUKS_DEV" | head -n1)"
[ -n "$DISK" ] || die "could not work out which disk $LUKS_DEV lives on"

SIZE="$(lsblk -bdno SIZE "/dev/$DISK")"
[ "$SIZE" -gt 700000000000 ] || die "the LUKS disk is only $((SIZE/1000000000)) GB — expected the 953 GB one. Stopping before touching anything."

# Find the ESP by filesystem type on THIS disk rather than assuming p1.
ESP_PART="$(lsblk -rno NAME,FSTYPE "/dev/$DISK" | awk '$2=="vfat"{print $1; exit}')"
[ -n "$ESP_PART" ] || die "no vfat/EFI partition found on /dev/$DISK — refusing to guess"
ESP_DEV="/dev/$ESP_PART"

echo "    Encrypted: $LUKS_DEV    ESP: $ESP_DEV    ($((SIZE/1000000000)) GB — Windows disk untouched)"

TARGET="/dev/$DISK"
for link in /dev/disk/by-id/*; do
  case "$link" in *-part*) continue;; esac
  [ "$(readlink -f "$link" 2>/dev/null)" = "/dev/$DISK" ] && TARGET="$link" && break
done
echo "    Stable ID: $TARGET"

sed -i -E "s#device = \"/dev/nvme[^\"]*\";#device = \"$TARGET\";#" hosts/justc/disko.nix
sed -i -E "s#device = \"/dev/disk/by-id/[^\"]*\";#device = \"$TARGET\";#" hosts/justc/disko.nix
grep -q "device = \"$TARGET\";" hosts/justc/disko.nix \
  || die "could not rewrite the device line in disko.nix — the file format changed"
echo "    disko.nix now points at the stable ID"

# ---------------------------------------------- 2b. find the Windows ESP
msg "Looking for the Windows ESP (for the Limine boot entry)"
WIN_UUID=""
NTFS_PART="$(lsblk -rno NAME,FSTYPE | awk '$2=="ntfs"{print $1; exit}')"
if [ -n "$NTFS_PART" ]; then
  WIN_DISK="$(lsblk -rno PKNAME "/dev/$NTFS_PART" | head -n1)"
  if [ -n "$WIN_DISK" ] && [ "$WIN_DISK" != "$DISK" ]; then
    for p in $(lsblk -rno NAME,FSTYPE "/dev/$WIN_DISK" | awk '$2=="vfat"{print $1}'); do
      probe="$(mktemp -d)"
      if sudo mount -o ro "/dev/$p" "$probe" 2>/dev/null; then
        if [ -f "$probe/EFI/Microsoft/Boot/bootmgfw.efi" ]; then
          WIN_UUID="$(sudo blkid -s UUID -o value "/dev/$p" 2>/dev/null || true)"
          sudo umount "$probe"; rmdir "$probe" 2>/dev/null || true
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
  grep -q "windowsEspUuid = \"$WIN_UUID\";" hosts/justc/boot.nix \
    || die "found the Windows ESP but could not write it into boot.nix"
  echo "    Windows ESP found, UUID $WIN_UUID — boot entry will be created"
else
  echo "    No Windows ESP found (or bootmgfw.efi missing). Skipping that entry;"
  echo "    F12 at power-on still reaches Windows. Nothing is broken by this."
fi

# --------------------------------------- 3. hardware detection (BEFORE wipe)
# v7 did this at step 7, after the old root had already been deleted. Probing
# writes to a scratch directory and needs nothing mounted, so it belongs here.
msg "Hardware detection"
HW="$(mktemp -d)"
sudo nixos-generate-config --no-filesystems --dir "$HW" \
  || die "nixos-generate-config failed — nothing has been changed on disk yet"
[ -s "$HW/hardware-configuration.nix" ] || die "hardware-configuration.nix came out empty"
sudo cp "$HW/hardware-configuration.nix" hosts/justc/hardware-configuration.nix
sudo chown "$(id -u):$(id -g)" hosts/justc/hardware-configuration.nix
grep -q 'boot.initrd.availableKernelModules' hosts/justc/hardware-configuration.nix \
  || warn "generated hardware config has no initrd module list — unusual, but continuing"
echo "    real hardware-configuration.nix in place (stub replaced)"

# ------------------------------------------------------------ 4. lock flake
msg "Pre-locking the flake (prevents the NAR-hash mismatch)"
nix "${NIXFLAGS[@]}" flake lock \
  || die "could not lock the flake. Usually this is no network, or one of the
!!! flake inputs moved. Nothing on disk has been changed yet — check the
!!! connection with  nmtui  and run the same one-liner again."

# ------------------------------------------- 5. PREFLIGHT — evaluate the config
# The single most important change in v8. Everything below this block is
# destructive; everything above it is not. If the config cannot evaluate, we
# find out HERE, while the machine is still bootable.
if [ "$PREFLIGHT" = "1" ]; then
  # ---- 5a. option NAMES first -------------------------------------------
  # Package names are guarded (modules/guard-args.nix) and can no longer stop
  # an install. Option names cannot be guarded, and Nix stops at the FIRST bad
  # one — so check them all up front and report the whole list at once.
  msg "PREFLIGHT 1/2 — checking option names"
  if OPTOUT="$(nix "${NIXFLAGS[@]}" eval --impure --raw \
                 --file "$BUILD/preflight-options.nix" \
                 --argstr flake "$BUILD" 2>&1)"; then
    echo "$OPTOUT" | sed 's/^/    /'
    if echo "$OPTOUT" | grep -q "^MISSING OPTIONS"; then
      die "one or more option names do not exist in this nixpkgs.

!!! Nothing has been erased. Your current system still boots.
!!! Photo the list above — it is the COMPLETE set, not just the first one."
    fi
  else
    echo "    (option check could not run — continuing to the full evaluation,"
    echo "     which will find the same problems one at a time)"
    echo "$OPTOUT" | tail -3 | sed 's/^/    | /'
  fi

  msg "PREFLIGHT 2/2 — proving the config builds before anything is erased"
  echo "    (a few minutes of pure evaluation, no disk writes, no downloads)"
  if sudo NIXPKGS_ALLOW_UNFREE=1 NIXPKGS_ALLOW_INSECURE=1 \
       nix "${NIXFLAGS[@]}" build --dry-run --impure \
         --option extra-substituters "$EXTRA_SUBS" \
         --option extra-trusted-public-keys "$EXTRA_KEYS" \
         "$BUILD#nixosConfigurations.justc.config.system.build.toplevel"; then
    echo
    echo "    PREFLIGHT PASSED — the config evaluates. Safe to continue."
  else
    die "PREFLIGHT FAILED — the config does not evaluate.

!!! GOOD NEWS: nothing has been erased. Your current system is untouched and
!!! will still boot. Reboot and you are exactly where you started.
!!!
!!! Photo the LAST few lines above (the last error is the real one) and send
!!! them to Claude. The likeliest cause is an option name that does not exist
!!! in this nixpkgs — the new Limine, KDE-unstable, NUR and
!!! nix-software-center code has never been evaluated on this machine before."
  fi
else
  msg "PREFLIGHT=0 — skipping the safety evaluation (you asked for this)"
fi

# ============================================================================
#  EVERYTHING BELOW HERE CHANGES THE DISK
# ============================================================================

# ------------------------------------------------------------ 6. clean state
msg "Clearing leftovers from earlier runs"
sudo swapoff -a 2>/dev/null || true
sudo umount -R /mnt 2>/dev/null || true
sudo umount -R /btr 2>/dev/null || true
if findmnt -n /mnt >/dev/null 2>&1; then
  die "/mnt is still mounted and would not unmount.
!!! Something is holding it open. Reboot the live USB and run this again."
fi

if [ ! -e /dev/mapper/cryptroot ]; then
  msg "Unlocking — TYPE YOUR PASSPHRASE (nothing shows as you type)"
  sudo cryptsetup open "$LUKS_DEV" cryptroot \
    || die "unlock failed (typo?) — just run the same one-line command again"
else
  msg "Drive already unlocked — continuing"
fi

# ------------------------------------------- 7. fresh root subvolume (or not)
if [ "$FRESH" = "1" ]; then
  msg "Making a FRESH root subvolume (keeping /home and /nix)"
  sudo mkdir -p /btr
  sudo mount -o subvolid=5 /dev/mapper/cryptroot /btr

  if sudo btrfs subvolume show /btr/@ >/dev/null 2>&1; then
    # `btrfs subvolume list -o` prints paths relative to the filesystem root,
    # e.g. "@/var/lib/machines" — so /btr/<path> is already correct. v7 tried
    # /btr/var/lib/machines first, which never matched anything.
    sudo btrfs subvolume list -o /btr/@ | awk '{print $NF}' | tac | while read -r sub; do
      sudo btrfs subvolume delete "/btr/$sub" >/dev/null 2>&1 || true
    done
    sudo btrfs subvolume delete /btr/@ >/dev/null \
      || die "could not remove the old root subvolume"
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

# ---------------------------------------------------------------- 8. mount
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

# -------------------------------------------- 8b. swap for the big build
# The live USB's /nix/store is RAM-backed. This closure (Plasma 6.7, DaVinci
# Resolve Studio, Affinity's patched Wine) is many gigabytes, and 16 GB of RAM
# is not a comfortable margin. tmpfs pages are swappable, so a swapfile on the
# target disk is what keeps the build from dying with an out-of-memory error.
# It is removed again once the install finishes.
SWAPSIZE="${SWAPSIZE:-12G}"
SWAPFILE=/mnt/swapfile
msg "Adding $SWAPSIZE of temporary swap (removed at the end)"
sudo rm -f "$SWAPFILE" 2>/dev/null || true
if sudo btrfs filesystem mkswapfile --size "$SWAPSIZE" "$SWAPFILE" 2>/dev/null; then
  echo "    created with btrfs mkswapfile"
else
  # Older btrfs-progs: a swapfile must be nodatacow and uncompressed, and
  # chattr +C only takes effect on a still-empty file.
  sudo truncate -s 0 "$SWAPFILE"
  sudo chattr +C "$SWAPFILE" 2>/dev/null || true
  sudo fallocate -l "$SWAPSIZE" "$SWAPFILE" 2>/dev/null \
    || sudo dd if=/dev/zero of="$SWAPFILE" bs=1M count=$((${SWAPSIZE%G}*1024)) status=none
  sudo chmod 600 "$SWAPFILE"
  sudo mkswap "$SWAPFILE" >/dev/null
  echo "    created the manual way"
fi
if sudo swapon "$SWAPFILE" 2>/dev/null; then
  echo "    swap active — the build has room now"
else
  sudo rm -f "$SWAPFILE" 2>/dev/null || true
  warn "could not enable swap. Continuing without it; if the install dies"
  warn "with an out-of-memory error, that is the reason."
fi

# snapper is configured for /home, which needs /home/.snapshots to exist as a
# subvolume. Without this the snapper-home service fails on the installed
# system — harmless to boot, but it never takes a snapshot.
sudo btrfs subvolume create /mnt/home/.snapshots >/dev/null 2>&1 \
  && echo "    /home/.snapshots created for snapper" \
  || echo "    /home/.snapshots already present"

# Diagnostic only. disko addresses /boot and the LUKS device BY PARTLABEL, but
# this script never runs disko — it reinstalls onto a disk that disko
# partitioned previously. If these labels are not what disko expects, the
# system installs fine and then fails at first boot, so record them here.
echo "    partition labels on this disk (disko expects disk-main-esp / disk-main-luks):"
lsblk -no NAME,PARTLABEL "/dev/$DISK" 2>/dev/null | sed 's/^/      /' || true

# -------------------------------------------- 9. boot hygiene (Limine-aware)
# THIS disk's ESP only. Windows lives on the other disk and is never touched.
# Verified above that $ESP_DEV is vfat and lives on the LUKS disk.
msg "Clearing old bootloader files from this disk's ESP"
if [ -d /mnt/boot/EFI/Microsoft ]; then
  die "found EFI/Microsoft on the ESP we are about to clean.
!!! That means this is the WINDOWS ESP, not the NixOS one. Refusing to touch
!!! it. Nothing has been deleted. Send Claude the output of:
!!!   lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT"
fi
sudo rm -rf /mnt/boot/loader/entries/nixos-generation-*.conf \
            /mnt/boot/loader/loader.conf \
            /mnt/boot/EFI/nixos \
            /mnt/boot/EFI/systemd \
            /mnt/boot/EFI/Linux \
            /mnt/boot/limine \
            /mnt/boot/limine.conf 2>/dev/null || true
# Keep a copy of the removable-media fallback rather than deleting it outright.
# If Limine registers its own EFI variable this is redundant; if the Legion's
# firmware ever drops that variable, it is the difference between booting and
# needing the USB stick again.
if [ -f /mnt/boot/EFI/BOOT/BOOTX64.EFI ]; then
  sudo mv /mnt/boot/EFI/BOOT/BOOTX64.EFI /mnt/boot/EFI/BOOT/BOOTX64.EFI.pre-limine 2>/dev/null || true
  echo "    old fallback loader set aside as BOOTX64.EFI.pre-limine"
fi
echo "    systemd-boot and any previous Limine files removed"

# --------------------------------------- 10. config + dotfiles BEFORE install
msg "Placing your config and dotfiles (real copies, before the install)"
U=/mnt/home/lovergirlonline
sudo mkdir -p "$U"
sudo rm -rf "$U/nixos"
sudo cp -r "$BUILD" "$U/nixos"
sudo HOME="$U" bash "$U/nixos/dotfiles/link.sh" >/dev/null \
  || die "dotfiles link.sh failed — the system is not installed yet, so just fix and re-run"
sudo chown -R 1000:100 "$U"
echo "    ~/nixos + ~/.config populated"

# --------------------------------------------------------------- 11. install
msg "INSTALLING — the long part. Let it run; there are no prompts."
echo "    (garnix + nix-community are passed on the command line, so Affinity's"
echo "     patched Wine is FETCHED, not compiled — that only works because the"
echo "     live USB's nix daemon is told about them here, not in the config)"
sudo NIXPKGS_ALLOW_UNFREE=1 NIXPKGS_ALLOW_INSECURE=1 \
  nixos-install --flake "$BUILD#justc" --no-root-passwd --impure \
    --option extra-substituters "$EXTRA_SUBS" \
    --option extra-trusted-public-keys "$EXTRA_KEYS"

# ------------------------------------------------ 11b. drop the temporary swap
# It did its job during the build; leaving a 12 GB file in the new root would
# just waste space on the installed system.
if [ -f "$SWAPFILE" ]; then
  sudo swapoff "$SWAPFILE" 2>/dev/null || true
  sudo rm -f "$SWAPFILE" 2>/dev/null || true
  echo "    temporary swapfile removed"
fi

# ------------------------------------------------ 12. validate the niri config
msg "Checking the niri config inside the new system"
NIRI_CFG="/home/lovergirlonline/.config/niri/config.kdl"

niri_try() { sudo nixos-enter --root /mnt -- bash -lc "$1" 2>&1; }

if ! niri_try "command -v niri >/dev/null" >/dev/null 2>&1; then
  echo "    niri binary not found inside the new system — skipping this check."
  echo "    (nothing removed; validate by hand after first boot)"
else
  NIRI_OUT=""
  NIRI_OK=1
  for form in "niri validate -c '$NIRI_CFG'" \
              "niri validate --config '$NIRI_CFG'" \
              "niri -c '$NIRI_CFG' validate"; do
    if NIRI_OUT="$(niri_try "$form")"; then NIRI_OK=0; break; fi
  done

  if [ "$NIRI_OK" = "0" ]; then
    echo "    niri config OK (blur enabled)"
  elif echo "$NIRI_OUT" | grep -qiE "unexpected argument|unrecognized|command not found|No such file|USAGE:|Usage:"; then
    # v7 would have deleted the blur block here. This is a CLI mismatch, not a
    # bad config — leave the config alone and say so.
    warn "could not work out how to run 'niri validate' on this build."
    warn "Your config was NOT modified. After first boot, run by hand:"
    warn "  niri validate -c ~/.config/niri/config.kdl"
  else
    echo "    this niri build rejected something — removing the blur block and retrying"
    sudo sed -i '/>>>BLUR/,/<<<BLUR/d' \
      "$U/.config/niri/config.kdl" "$U/nixos/dotfiles/niri/config.kdl"
    if niri_try "niri validate -c '$NIRI_CFG'" >/dev/null 2>&1 \
    || niri_try "niri validate --config '$NIRI_CFG'" >/dev/null 2>&1 \
    || niri_try "niri -c '$NIRI_CFG' validate" >/dev/null 2>&1; then
      echo "    niri config OK (blur removed — everything else intact)"
    else
      warn "niri validate still unhappy. The system will still boot;"
      warn "log into KDE at SDDM and send Claude the output of:"
      warn "  niri validate -c ~/.config/niri/config.kdl"
      echo "$NIRI_OUT" | tail -5 | sed 's/^/    | /'
    fi
  fi
fi

# ------------------------------------------------------ 13. verify Limine landed
msg "Verifying the bootloader"
if sudo test -f /mnt/boot/limine.conf || sudo test -d /mnt/boot/limine; then
  echo "    Limine installed on the ESP"
  if sudo grep -q 'Windows' /mnt/boot/limine.conf 2>/dev/null; then
    echo "    Windows 11 entry present"
  else
    echo "    (no Windows entry — use F12 for now)"
  fi
else
  warn "Limine files not found on the ESP."
  warn "The system may still boot via the EFI variable, but if it does"
  warn "not: open hosts/justc/boot.nix, change the line"
  warn "    loader = \"limine\";"
  warn "to  loader = \"systemd-boot\";"
  warn "and re-run this same one-liner. That is the whole rollback."
fi

msg "Pre-applying theme names inside the new system"
sudo nixos-enter --root /mnt -- bash -lc \
  "su - lovergirlonline -c theme-apply" >/dev/null 2>&1 \
  && echo "    theme names written" \
  || echo "    (skipped — it runs itself at first login anyway)"
sudo chown -R 1000:100 "$U" 2>/dev/null || true

# ------------------------------------------- 14. report guarded-out packages
# modules/guard.nix looks plain nixpkgs names up BY STRING, so a name that was
# renamed upstream is skipped instead of aborting the install. This is where
# you find out which ones that happened to.
msg "Packages skipped because this nixpkgs does not have them"
MISSING_FILE=/mnt/etc/justc/missing-packages
if sudo test -f "$MISSING_FILE"; then
  if sudo grep -q '^none' "$MISSING_FILE"; then
    echo "    none — every package name in the config resolved."
  else
    echo "    THESE ARE NOT INSTALLED. Photo this list and send it to Claude:"
    echo
    sudo sed 's/^/      /' "$MISSING_FILE"
    echo
    echo "    Nothing is broken — the system boots and everything else is"
    echo "    present. Same list any time after boot:  missingpkgs"
  fi
else
  echo "    (no report file — guard module may not have been imported)"
fi

rm -rf "$HW" 2>/dev/null || true

echo
echo "===================================================="
echo "  DONE."
echo "  1) sudo reboot         2) pull the USB stick"
echo "  3) Limine menu appears — NixOS is the default"
echo "  4) type your passphrase"
echo "  5) log in: lovergirlonline / fern2424"
echo "  6) first commands:  passwd     then     nmtui"
echo
echo "  The theme applies itself at login. Nothing to run."
echo
echo "  Mod+T terminal · Mod+D launcher · Mod+E files"
echo "  Mod+X power menu · Ctrl+Alt+T works without Super"
echo "  fastfetch  ·  nvim  ·  bootcfg (Limine menu)"
echo "  missingpkgs — any package names this nixpkgs didn't have"
echo "===================================================="
