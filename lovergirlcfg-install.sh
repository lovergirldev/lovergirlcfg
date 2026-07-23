#!/usr/bin/env bash
# justc-nixos reinstall helper — v9 (reviewed)
#
# Intended target:
#   * the existing ~1 TB NixOS SSD
#   * GPT labels disk-main-esp and disk-main-luks
#   * LUKS mapping cryptroot
#   * Btrfs subvolumes @, @home, @nix, and @snapshots
#   * Windows on a separate SSD
#
# This is deliberately NOT a blank-disk installer. It will refuse to continue
# if the existing layout does not match that contract. It builds the complete
# NixOS closure before replacing @, keeps the old @ as a rollback subvolume,
# and backs up the NixOS ESP into @nix.
#
# Run from a NixOS 26.05 graphical installer USB:
#   bash install.sh
#
# install.sh may be inside the reviewed config, next to its reviewed
# justc-nixos/ directory, or next to lovergirlcfg.zip. The legacy reviewed ZIP
# names are also accepted only when they contain the v9 review marker. The
# script never repartitions or reformats a disk.

set -Eeuo pipefail
umask 077

NIXFLAGS=(--extra-experimental-features "nix-command flakes")
EXTRA_SUBS="https://cache.garnix.io https://nix-community.cachix.org"
EXTRA_KEYS="cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g= nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="

EXPECTED_HOST="justc"
EXPECTED_USER="lovergirlonline"
EXPECTED_UID=1000
EXPECTED_GROUP=100
SWAPSIZE="${SWAPSIZE:-24G}"

RUN_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
WORKDIR="$(mktemp -d /tmp/justc-install-v9.XXXXXX)"
BUILD="$WORKDIR/config"
TOP_MOUNT="$WORKDIR/btrfs-top"
STORE_ROOT="$WORKDIR/target-store"
ESP_PROBE="$WORKDIR/esp"
ESP_RESTORE="$WORKDIR/esp-restore"
LOG="/tmp/justc-install-v9-$RUN_STAMP.log"
PERSISTENT_LOG="$TOP_MOUNT/@nix/.justc-installer/install-$RUN_STAMP.log"

LUKS_DEV=""
ESP_DEV=""
DISK_DEV=""
TARGET=""
MAPPER_OPENED=0
SWAPFILE=""
ROOT_SWITCHED=0
ROLLBACK_NAME="@rollback-$RUN_STAMP"
ESP_BACKUP=""
ESP_BACKUP_REL=".justc-installer/esp-$RUN_STAMP"
PROFILE_BACKUP=""
GC_ROOT=""
ESP_CHANGED=0
INSTALL_SUCCEEDED=0

mkdir -p \
  "$BUILD" "$TOP_MOUNT" "$STORE_ROOT/nix" "$ESP_PROBE" "$ESP_RESTORE"
# Nix's chroot-store builders run as dedicated build users after entering this
# root and therefore need to traverse its top-level directory.
chmod 0755 "$STORE_ROOT"
touch "$LOG"
exec > >(tee -a "$LOG") 2>&1

msg() {
  printf '\n==> %s\n' "$*"
}

warn() {
  printf '    !!! %s\n' "$*"
}

die() {
  printf '\n!!! %s\n' "$*"
  printf '!!! Install log: %s\n' "$LOG"
  exit 1
}

is_mounted() {
  mountpoint -q "$1"
}

delete_partial_root() {
  local sub

  if ! sudo btrfs subvolume show "$TOP_MOUNT/@" >/dev/null 2>&1; then
    return 0
  fi

  while IFS= read -r sub; do
    [ -n "$sub" ] || continue
    sudo btrfs subvolume delete "$TOP_MOUNT/$sub" >/dev/null 2>&1 || return 1
  done < <(
    sudo btrfs subvolume list -o "$TOP_MOUNT/@" 2>/dev/null |
      awk '{print $NF}' |
      tac
  )

  sudo btrfs subvolume delete "$TOP_MOUNT/@" >/dev/null
}

restore_esp_backup() {
  [ "$ESP_CHANGED" -eq 1 ] || return 0
  [ -n "$ESP_BACKUP" ] && [ -d "$ESP_BACKUP" ] || return 1
  [ -n "$ESP_DEV" ] || return 1

  if is_mounted "$ESP_RESTORE"; then
    sudo umount "$ESP_RESTORE" || return 1
  fi
  sudo mount -o umask=0077 "$ESP_DEV" "$ESP_RESTORE" || return 1

  # Remove every NixOS bootloader path that this installer can create before
  # copying the old files back. Without this, a failed first Limine install
  # could leave new files beside an otherwise restored systemd-boot ESP.
  sudo rm -rf -- \
    "$ESP_RESTORE/loader" \
    "$ESP_RESTORE/EFI/nixos" \
    "$ESP_RESTORE/EFI/systemd" \
    "$ESP_RESTORE/EFI/Linux" \
    "$ESP_RESTORE/EFI/limine" \
    "$ESP_RESTORE/EFI/BOOT/BOOTX64.EFI" \
    "$ESP_RESTORE/limine" \
    "$ESP_RESTORE/limine.conf" || {
    sudo umount "$ESP_RESTORE" >/dev/null 2>&1 || true
    return 1
  }
  # FAT has no Unix ownership or mode metadata, so do not ask cp to preserve
  # attributes that the destination cannot represent.
  sudo cp -r -- "$ESP_BACKUP/." "$ESP_RESTORE/" || {
    sudo umount "$ESP_RESTORE" >/dev/null 2>&1 || true
    return 1
  }
  sync
  sudo umount "$ESP_RESTORE"
}

restore_system_profile() {
  [ -n "$PROFILE_BACKUP" ] && sudo test -L "$PROFILE_BACKUP" || return 0

  sudo rm -f -- "$TOP_MOUNT/@nix/var/nix/profiles/system" || return 1
  sudo cp -a "$PROFILE_BACKUP" \
    "$TOP_MOUNT/@nix/var/nix/profiles/system"
}

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  set +e

  if [ -n "$SWAPFILE" ]; then
    if swapon --noheadings --show=NAME 2>/dev/null | grep -Fxq "$SWAPFILE"; then
      sudo swapoff "$SWAPFILE"
    fi
    if [ -f "$SWAPFILE" ] && [ ! -L "$SWAPFILE" ]; then
      sudo rm -f -- "$SWAPFILE"
    fi
  fi

  if is_mounted /mnt; then
    sudo umount -R /mnt
  fi

  if [ "$status" -ne 0 ] && [ "$ROOT_SWITCHED" -eq 1 ] && [ "$INSTALL_SUCCEEDED" -eq 0 ]; then
    warn "The install did not finish; restoring the previous root subvolume."
    if delete_partial_root &&
       sudo test -d "$TOP_MOUNT/$ROLLBACK_NAME" &&
       sudo mv "$TOP_MOUNT/$ROLLBACK_NAME" "$TOP_MOUNT/@"; then
      ROOT_SWITCHED=0
      warn "Previous @ restored."
    else
      warn "Automatic root rollback failed. DO NOT REBOOT."
      warn "The preserved root is: $ROLLBACK_NAME"
    fi

    if ! restore_system_profile; then
      warn "Automatic NixOS system-profile restore failed."
    fi

    if [ "$ESP_CHANGED" -eq 1 ]; then
      if ! restore_esp_backup; then
        warn "Automatic ESP restore failed. The backup remains at: $ESP_BACKUP"
      else
        warn "Previous ESP files restored."
      fi
    fi
  fi

  # Once the new OS, bootloader, niri config, and password have passed, a
  # later dotfile/theme failure deliberately does not roll the bootable system
  # back. Preserve the diagnostic log in @nix even though /mnt was unmounted.
  if [ "$status" -ne 0 ] && [ "$INSTALL_SUCCEEDED" -eq 1 ] &&
     sudo test -d "$TOP_MOUNT/@nix/.justc-installer"; then
    sudo cp "$LOG" "$PERSISTENT_LOG" || true
  fi

  if is_mounted "$ESP_RESTORE"; then
    sudo umount "$ESP_RESTORE"
  fi
  if is_mounted "$ESP_PROBE"; then
    sudo umount "$ESP_PROBE"
  fi
  if is_mounted "$STORE_ROOT/nix"; then
    sudo umount "$STORE_ROOT/nix"
  fi
  if is_mounted "$TOP_MOUNT"; then
    sudo umount "$TOP_MOUNT"
  fi

  if [ "$MAPPER_OPENED" -eq 1 ] && [ -e /dev/mapper/cryptroot ]; then
    sudo cryptsetup close cryptroot
  fi

  if [ "$status" -eq 0 ]; then
    sudo rm -rf -- "$WORKDIR"
  else
    if [ "$INSTALL_SUCCEEDED" -eq 1 ]; then
      printf '\n!!! The core OS and bootloader were installed and were NOT rolled back.\n'
      printf '!!! A post-install user-configuration step failed; review: %s\n' "$LOG"
    else
      printf '\n!!! The installer stopped safely. Review: %s\n' "$LOG"
    fi
    printf '!!! Temporary working copy retained at: %s\n' "$WORKDIR"
  fi

  exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT TERM

setterm -blank 0 -powerdown 0 2>/dev/null || true

case "$SWAPSIZE" in
  [8-9]G | [1-5][0-9]G | 6[0-4]G) ;;
  *) die "SWAPSIZE must be 8G through 64G (received: $SWAPSIZE)." ;;
esac

for command_name in \
  awk blkid btrfs chattr chmod chown cp cryptsetup df diff fallocate find findmnt grep \
  flock head ln lsblk mkswap mount mountpoint nix nixos-enter nixos-generate-config \
  nixos-install mkdir mv readlink rm sed stat sudo swapon swapoff sync tac tail \
  tee tr truncate umount uname
do
  command -v "$command_name" >/dev/null 2>&1 ||
    die "Required command is missing from this live environment: $command_name"
done

exec 9>/tmp/justc-install-v9.lock
flock -n 9 || die "Another justc installer process is already running."

sudo -v || die "sudo authentication failed."

[ "$(uname -m)" = "x86_64" ] ||
  die "This flake targets x86_64-linux, not $(uname -m)."
[ -d /sys/firmware/efi/efivars ] ||
  die "The installer USB was not booted in UEFI mode. Reboot it through the UEFI/F12 entry."
if command -v bootctl >/dev/null 2>&1 &&
   bootctl status 2>/dev/null | grep -qi 'Secure Boot:[[:space:]]*enabled'; then
  die "Secure Boot is enabled, but this Limine configuration is not signed. Disable it before installing."
fi

if is_mounted /mnt; then
  die "/mnt is already mounted. Unmount it explicitly, verify what it was, and rerun."
fi

# ------------------------------------------------------------------ sources
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_ROOT=""
ZIP_FILE=""

msg "Preparing the configuration"
if [ -f "$SRC/flake.nix" ] && [ -f "$SRC/REVIEWED-VERSION" ]; then
  CONFIG_ROOT="$SRC"
elif [ -f "$SRC/lovergirlcfg.zip" ]; then
  ZIP_FILE="$SRC/lovergirlcfg.zip"
elif [ -f "$SRC/justc-nixos-v9-reviewed.zip" ]; then
  ZIP_FILE="$SRC/justc-nixos-v9-reviewed.zip"
elif [ -f "$SRC/justc-nixos/flake.nix" ] &&
     [ -f "$SRC/justc-nixos/REVIEWED-VERSION" ]; then
  CONFIG_ROOT="$SRC/justc-nixos"
elif [ -f "$SRC/justc-nixos.zip" ]; then
  ZIP_FILE="$SRC/justc-nixos.zip"
fi

if [ -n "$ZIP_FILE" ]; then
  ZIP_STAGE="$WORKDIR/archive"
  mkdir -p "$ZIP_STAGE"
  if command -v unzip >/dev/null 2>&1; then
    ZIP_ENTRIES="$(unzip -Z1 "$ZIP_FILE")"
    while IFS= read -r zip_entry; do
      case "/$zip_entry/" in
        //* | */../* | *\\*)
          die "The ZIP contains an unsafe path: $zip_entry"
          ;;
      esac
    done <<< "$ZIP_ENTRIES"
    unzip -q "$ZIP_FILE" -d "$ZIP_STAGE"
  else
    ZIP_ENTRIES="$(
      nix "${NIXFLAGS[@]}" shell nixpkgs#unzip -c unzip -Z1 "$ZIP_FILE"
    )"
    while IFS= read -r zip_entry; do
      case "/$zip_entry/" in
        //* | */../* | *\\*)
          die "The ZIP contains an unsafe path: $zip_entry"
          ;;
      esac
    done <<< "$ZIP_ENTRIES"
    nix "${NIXFLAGS[@]}" shell nixpkgs#unzip -c \
      unzip -q "$ZIP_FILE" -d "$ZIP_STAGE"
  fi

  if [ -f "$ZIP_STAGE/flake.nix" ]; then
    CONFIG_ROOT="$ZIP_STAGE"
  elif [ -f "$ZIP_STAGE/justc-nixos/flake.nix" ]; then
    CONFIG_ROOT="$ZIP_STAGE/justc-nixos"
  fi
fi

[ -n "$CONFIG_ROOT" ] ||
  die "Could not find the reviewed v9 config or ZIP next to install.sh."

UNSAFE_SOURCE_ENTRY="$(
  find "$CONFIG_ROOT" -mindepth 1 ! -type f ! -type d -print -quit
)"
[ -z "$UNSAFE_SOURCE_ENTRY" ] ||
  die "The configuration contains a symlink or special file, which is not accepted: $UNSAFE_SOURCE_ENTRY"

cp -a "$CONFIG_ROOT/." "$BUILD/"
if [ -e "$BUILD/.git" ] || [ -L "$BUILD/.git" ]; then
  rm -rf -- "$BUILD/.git"
fi

required_files=(
  REVIEWED-VERSION
  flake.nix
  preflight-options.nix
  hosts/justc/default.nix
  hosts/justc/disko.nix
  hosts/justc/boot.nix
  dotfiles/link.sh
  dotfiles/niri/config.kdl
)
for required_file in "${required_files[@]}"; do
  [ -f "$BUILD/$required_file" ] ||
    die "The configuration is incomplete; missing: $required_file"
done
grep -Fxq 'justc-nixos-v9-reviewed-2026-07-23' "$BUILD/REVIEWED-VERSION" ||
  die "The config is not the reviewed v9 source. Do not combine this installer with the original archive."
printf '    Working copy: %s\n' "$BUILD"

# ---------------------------------------------------------- identify target
msg "Identifying the existing NixOS SSD by exact GPT labels"
mapfile -t luks_candidates < <(
  lsblk -rpno PATH,PARTLABEL |
    awk '$2 == "disk-main-luks" { print $1 }'
)

[ "${#luks_candidates[@]}" -eq 1 ] ||
  die "Expected exactly one partition labeled disk-main-luks; found ${#luks_candidates[@]}.
This package only reinstalls the existing, known layout and will not guess."

LUKS_DEV="${luks_candidates[0]}"
sudo cryptsetup isLuks "$LUKS_DEV" ||
  die "$LUKS_DEV has the expected label but is not a valid LUKS container."

DISK_NAME="$(lsblk -rno PKNAME "$LUKS_DEV" | head -n 1)"
[ -n "$DISK_NAME" ] || die "Could not determine the parent disk for $LUKS_DEV."
DISK_DEV="/dev/$DISK_NAME"

mapfile -t esp_candidates < <(
  lsblk -rpno PATH,PARTLABEL "$DISK_DEV" |
    awk '$2 == "disk-main-esp" { print $1 }'
)
[ "${#esp_candidates[@]}" -eq 1 ] ||
  die "Expected exactly one sibling partition labeled disk-main-esp; found ${#esp_candidates[@]}."
ESP_DEV="${esp_candidates[0]}"

ESP_TYPE="$(sudo blkid -s TYPE -o value "$ESP_DEV" 2>/dev/null || true)"
case "$ESP_TYPE" in
  vfat | fat | fat32) ;;
  *) die "$ESP_DEV is labeled disk-main-esp but its filesystem is '$ESP_TYPE', not FAT." ;;
esac

DISK_SIZE="$(lsblk -bdno SIZE "$DISK_DEV")"
[ "$DISK_SIZE" -ge 800000000000 ] && [ "$DISK_SIZE" -le 1200000000000 ] ||
  die "$DISK_DEV is $((DISK_SIZE / 1000000000)) GB; expected the existing ~1 TB NixOS SSD."
ESP_SIZE="$(lsblk -bdno SIZE "$ESP_DEV")"
[ "$ESP_SIZE" -ge 500000000 ] && [ "$ESP_SIZE" -le 2000000000 ] ||
  die "$ESP_DEV is $((ESP_SIZE / 1000000)) MB; expected the existing approximately 1 GB ESP."
LUKS_SIZE="$(lsblk -bdno SIZE "$LUKS_DEV")"
[ "$LUKS_SIZE" -ge 700000000000 ] ||
  die "$LUKS_DEV is only $((LUKS_SIZE / 1000000000)) GB; expected the large NixOS data partition."

if lsblk -rno FSTYPE "$DISK_DEV" | grep -Eq '^ntfs'; then
  die "$DISK_DEV contains NTFS. That looks like the Windows disk, so the installer is stopping."
fi

TARGET=""
shopt -s nullglob
for by_id in \
  /dev/disk/by-id/nvme-eui.* \
  /dev/disk/by-id/nvme-uuid.* \
  /dev/disk/by-id/wwn-* \
  /dev/disk/by-id/nvme-*
do
  case "$by_id" in
    *-part*) continue ;;
  esac
  [[ "$by_id" =~ ^/dev/disk/by-id/[A-Za-z0-9._:+@=-]+$ ]] || continue
  if [ "$(readlink -f "$by_id" 2>/dev/null || true)" = "$DISK_DEV" ]; then
    TARGET="$by_id"
    break
  fi
done
shopt -u nullglob
[ -n "$TARGET" ] ||
  die "No safe, stable by-id link points to $DISK_DEV; refusing to save a volatile nvme name."

DISK_MODEL="$(lsblk -dn -o MODEL "$DISK_DEV" | sed 's/[[:space:]]*$//')"
DISK_SERIAL="$(lsblk -dn -o SERIAL "$DISK_DEV" | sed 's/[[:space:]]*$//')"
ESP_UUID="$(sudo blkid -s UUID -o value "$ESP_DEV" 2>/dev/null || true)"
LUKS_UUID="$(sudo blkid -s UUID -o value "$LUKS_DEV" 2>/dev/null || true)"
[ -n "$ESP_UUID" ] && [ -n "$LUKS_UUID" ] ||
  die "Could not read the target ESP/LUKS UUIDs."

printf '    Disk:       %s\n' "$DISK_DEV"
printf '    Stable ID:  %s\n' "$TARGET"
printf '    Model:      %s\n' "${DISK_MODEL:-unknown}"
printf '    Serial:     %s\n' "${DISK_SERIAL:-unknown}"
printf '    Size:       %s GB\n' "$((DISK_SIZE / 1000000000))"
printf '    ESP:        %s (UUID %s)\n' "$ESP_DEV" "$ESP_UUID"
printf '    Encrypted:  %s (LUKS UUID %s)\n' "$LUKS_DEV" "$LUKS_UUID"

if findmnt -rn -S "$ESP_DEV" >/dev/null 2>&1; then
  die "$ESP_DEV is already mounted. Unmount it explicitly and rerun."
fi

device_lines="$(
  grep -Ec '^[[:space:]]*device = "[^"]+";' \
    "$BUILD/hosts/justc/disko.nix" || true
)"
[ "$device_lines" -eq 1 ] ||
  die "disko.nix no longer has exactly one device line; refusing an ambiguous rewrite."
sed -i -E \
  "s#^[[:space:]]*device = \"[^\"]+\";#    device = \"$TARGET\";#" \
  "$BUILD/hosts/justc/disko.nix"
grep -Fq "device = \"$TARGET\";" "$BUILD/hosts/justc/disko.nix" ||
  die "Could not write the stable disk ID into disko.nix."

# ----------------------------------------------------------- Windows entry
msg "Looking for a unique Windows ESP on a different disk"
windows_uuid_lines="$(
  grep -Ec '^[[:space:]]*windowsEspUuid = "[^"]*";' \
    "$BUILD/hosts/justc/boot.nix" || true
)"
[ "$windows_uuid_lines" -eq 1 ] ||
  die "boot.nix no longer has exactly one windowsEspUuid line."
sed -i -E \
  's#windowsEspUuid = "[^"]*";#windowsEspUuid = "CHANGEME";#' \
  "$BUILD/hosts/justc/boot.nix"

windows_candidates=()
mapfile -t vfat_candidates < <(
  lsblk -rpno PATH,FSTYPE |
    awk '$2 == "vfat" { print $1 }'
)

probe_index=0
for candidate in "${vfat_candidates[@]}"; do
  candidate_parent="$(lsblk -rno PKNAME "$candidate" | head -n 1)"
  [ -n "$candidate_parent" ] || continue
  [ "/dev/$candidate_parent" != "$DISK_DEV" ] || continue
  [ "$(lsblk -dn -o RM "/dev/$candidate_parent" | tr -d ' ')" = "0" ] ||
    continue
  lsblk -rno FSTYPE "/dev/$candidate_parent" | grep -Eq '^ntfs' || continue

  mounted_at="$(findmnt -rn -S "$candidate" -o TARGET | head -n 1 || true)"
  mounted_here=0
  if [ -n "$mounted_at" ]; then
    probe_path="$mounted_at"
  else
    probe_path="$WORKDIR/windows-$probe_index"
    probe_index=$((probe_index + 1))
    mkdir -p "$probe_path"
    if ! sudo mount -o ro "$candidate" "$probe_path" 2>/dev/null; then
      continue
    fi
    mounted_here=1
  fi

  if sudo test -f "$probe_path/EFI/Microsoft/Boot/bootmgfw.efi"; then
    windows_candidates+=("$candidate")
  fi

  if [ "$mounted_here" -eq 1 ]; then
    sudo umount "$probe_path"
  fi
done

if [ "${#windows_candidates[@]}" -eq 1 ]; then
  WIN_UUID="$(
    sudo blkid -s UUID -o value "${windows_candidates[0]}" 2>/dev/null || true
  )"
  if [ -n "$WIN_UUID" ]; then
    sed -i -E \
      "s#windowsEspUuid = \"[^\"]*\";#windowsEspUuid = \"$WIN_UUID\";#" \
      "$BUILD/hosts/justc/boot.nix"
    printf '    Windows ESP: %s (UUID %s)\n' "${windows_candidates[0]}" "$WIN_UUID"
  else
    warn "The verified Windows ESP has no readable filesystem UUID."
    warn "No Limine Windows entry will be generated. F12 remains available."
  fi
elif [ "${#windows_candidates[@]}" -eq 0 ]; then
  warn "No verified Windows ESP found. F12 firmware boot remains available."
else
  warn "More than one verified Windows ESP found; refusing to guess."
  warn "No Limine Windows entry will be generated. F12 remains available."
fi

# --------------------------------------------------------- unlock and verify
msg "Unlocking and verifying the preserved Btrfs layout"
mapfile -t existing_crypt_mappings < <(
  lsblk -rno NAME,TYPE "$LUKS_DEV" |
    awk '$2 == "crypt" { print $1 }'
)
for mapping_name in "${existing_crypt_mappings[@]}"; do
  [ "$mapping_name" = "cryptroot" ] ||
    die "$LUKS_DEV is already open as '$mapping_name'. Close that mapping explicitly and rerun."
done

if [ -e /dev/mapper/cryptroot ]; then
  MAPPED_DEVICE="$(
    sudo cryptsetup status cryptroot |
      awk -F: '$1 ~ /^[[:space:]]*device$/ {
        sub(/^[[:space:]]*/, "", $2)
        print $2
        exit
      }' || true
  )"
  [ -n "$MAPPED_DEVICE" ] ||
    die "/dev/mapper/cryptroot exists, but its underlying device could not be identified."
  [ "$(readlink -f "$MAPPED_DEVICE")" = "$(readlink -f "$LUKS_DEV")" ] ||
    die "/dev/mapper/cryptroot points at $MAPPED_DEVICE, not $LUKS_DEV."
  printf '    Existing cryptroot mapping verified.\n'
else
  printf '    Enter the LUKS passphrase (nothing is shown while typing).\n'
  sudo cryptsetup open "$LUKS_DEV" cryptroot ||
    die "LUKS unlock failed. No root subvolume was changed."
  MAPPER_OPENED=1
fi

if findmnt -rn -S /dev/mapper/cryptroot >/dev/null 2>&1; then
  die "/dev/mapper/cryptroot is already mounted elsewhere. Unmount it explicitly and rerun."
fi

sudo mount -o subvolid=5,compress=zstd,noatime \
  /dev/mapper/cryptroot "$TOP_MOUNT"

for subvolume in @ @home @nix @snapshots; do
  sudo btrfs subvolume show "$TOP_MOUNT/$subvolume" >/dev/null 2>&1 ||
    die "Required existing Btrfs subvolume is missing: $subvolume"
done

sudo test -d "$TOP_MOUNT/@home/$EXPECTED_USER" ||
  die "Preserved home $EXPECTED_USER was not found in @home."
sudo test ! -L "$TOP_MOUNT/@home/$EXPECTED_USER" ||
  die "The preserved home is a symlink; refusing root-level writes through it."
sudo test -L "$TOP_MOUNT/@nix/var/nix/profiles/system" ||
  die "The preserved @nix does not contain an existing NixOS system profile."

# /etc/NIXOS is absent on valid NixOS systems that use system.etc.overlay.
# Identify the old system from its protected Nix profile instead: resolve the
# exact generation, require a nixos-system closure, then follow that closure's
# exact /etc store link and verify its os-release. All reads stay inside the
# already-verified @nix subvolume rather than following absolute links into the
# live installer's /nix/store.
SYSTEM_PROFILE="$TOP_MOUNT/@nix/var/nix/profiles/system"
PROFILE_TARGET="$(sudo readlink "$SYSTEM_PROFILE")"
GENERATION_LINK=""
OLD_SYSTEM_LOGICAL=""
if [[ "$PROFILE_TARGET" =~ ^system-[0-9]+-link$ ]]; then
  GENERATION_LINK="$TOP_MOUNT/@nix/var/nix/profiles/$PROFILE_TARGET"
elif [[ "$PROFILE_TARGET" =~ ^/nix/var/nix/profiles/system-[0-9]+-link$ ]]; then
  GENERATION_LINK="$TOP_MOUNT/@nix${PROFILE_TARGET#/nix}"
elif [[ "$PROFILE_TARGET" =~ ^/nix/store/[a-z0-9]{32}-nixos-system-[^/]+$ ]]; then
  OLD_SYSTEM_LOGICAL="$PROFILE_TARGET"
else
  die "The previous system profile has an unexpected target: $PROFILE_TARGET"
fi
if [ -n "$GENERATION_LINK" ]; then
  sudo test -L "$GENERATION_LINK" ||
    die "The previous system generation link is missing: $GENERATION_LINK"
  OLD_SYSTEM_LOGICAL="$(sudo readlink "$GENERATION_LINK")"
fi
[[ "$OLD_SYSTEM_LOGICAL" =~ ^/nix/store/[a-z0-9]{32}-nixos-system-[^/]+$ ]] ||
  die "The previous generation is not an exact NixOS system closure."
OLD_SYSTEM_PHYSICAL="$TOP_MOUNT/@nix${OLD_SYSTEM_LOGICAL#/nix}"
sudo test -d "$OLD_SYSTEM_PHYSICAL" ||
  die "The previous NixOS system closure is missing: $OLD_SYSTEM_PHYSICAL"
sudo test -s "$OLD_SYSTEM_PHYSICAL/nixos-version" ||
  die "The previous system closure has no NixOS version marker."
sudo test -L "$OLD_SYSTEM_PHYSICAL/etc" ||
  die "The previous NixOS system closure has no exact /etc store link."
OLD_ETC_LOGICAL="$(sudo readlink "$OLD_SYSTEM_PHYSICAL/etc")"
[[ "$OLD_ETC_LOGICAL" =~ ^/nix/store/[a-z0-9]{32}-etc(/etc)?$ ]] ||
  die "The previous system closure has an unexpected /etc target: $OLD_ETC_LOGICAL"
OLD_ETC_PHYSICAL="$TOP_MOUNT/@nix${OLD_ETC_LOGICAL#/nix}"
sudo test -f "$OLD_ETC_PHYSICAL/os-release" ||
  die "The previous system closure is missing os-release."
sudo grep -Eq '^(ID=nixos|ID="nixos")$' "$OLD_ETC_PHYSICAL/os-release" ||
  die "The previous system closure does not identify as NixOS."

HOME_UID="$(sudo stat -c %u "$TOP_MOUNT/@home/$EXPECTED_USER")"
[ "$HOME_UID" -eq "$EXPECTED_UID" ] ||
  die "Preserved home is owned by UID $HOME_UID, but this config requires UID $EXPECTED_UID."

sudo test ! -e "$TOP_MOUNT/$ROLLBACK_NAME" ||
  die "Rollback name already exists unexpectedly: $ROLLBACK_NAME"

printf '    Verified: @, @home, @nix, @snapshots\n'
printf '    Existing NixOS: %s\n' "$(sudo cat "$OLD_SYSTEM_PHYSICAL/nixos-version")"
printf '    Preserving: @home/%s (UID %s)\n' "$EXPECTED_USER" "$HOME_UID"

# Build into the preserved target Nix store, not the live ISO's RAM-backed
# store. This is the same chroot-store layout that nixos-install will use
# after /mnt is mounted, so a successful preflight is the actual closure that
# will be installed rather than a second, unrelated copy.
sudo mount -o compress=zstd,noatime,subvol=@nix \
  /dev/mapper/cryptroot "$STORE_ROOT/nix"
sudo test -d "$STORE_ROOT/nix/store" ||
  die "The preserved @nix does not contain /nix/store."
sudo test -d "$STORE_ROOT/nix/var/nix/db" ||
  die "The preserved @nix does not contain a Nix store database."
printf '    Preflight store: %s/nix\n' "$STORE_ROOT"

# ------------------------------------------------------- hardware and lock
msg "Generating this machine's hardware configuration"
HW="$WORKDIR/hardware"
mkdir -p "$HW"
sudo nixos-generate-config --no-filesystems --dir "$HW" ||
  die "nixos-generate-config failed."
[ -s "$HW/hardware-configuration.nix" ] ||
  die "Generated hardware-configuration.nix is empty."
sudo cp "$HW/hardware-configuration.nix" \
  "$BUILD/hosts/justc/hardware-configuration.nix"
sudo chown "$(id -u):$(id -g)" \
  "$BUILD/hosts/justc/hardware-configuration.nix"
grep -q 'boot.initrd.availableKernelModules' \
  "$BUILD/hosts/justc/hardware-configuration.nix" ||
  warn "The generated hardware config has no initrd module list."

msg "Locking all flake inputs"
(
  cd "$BUILD"
  sudo env NIXPKGS_ALLOW_UNFREE=1 \
    nix "${NIXFLAGS[@]}" --store "$STORE_ROOT" flake lock
) || die "Flake locking failed. Check the network; the existing system is unchanged."

# -------------------------------------------------------------- swap first
SWAPFILE="$TOP_MOUNT/@nix/.justc-install-swap"
SWAP_GIB="${SWAPSIZE%G}"
AVAILABLE_BYTES="$(df -B1 --output=avail "$TOP_MOUNT/@nix" | tail -n 1 | tr -d ' ')"
REQUIRED_BYTES=$(((SWAP_GIB + 20) * 1024 * 1024 * 1024))
[ "$AVAILABLE_BYTES" -ge "$REQUIRED_BYTES" ] ||
  die "@nix has less than $((SWAP_GIB + 20)) GiB free; not enough for $SWAPSIZE swap plus install headroom."

if [ -L "$SWAPFILE" ] || { [ -e "$SWAPFILE" ] && [ ! -f "$SWAPFILE" ]; }; then
  die "Refusing to replace unexpected object at $SWAPFILE"
fi
if swapon --noheadings --show=NAME 2>/dev/null | grep -Fxq "$SWAPFILE"; then
  sudo swapoff "$SWAPFILE"
fi
sudo rm -f -- "$SWAPFILE"

msg "Creating $SWAPSIZE temporary swap before the full build"
if ! sudo btrfs filesystem mkswapfile --size "$SWAPSIZE" "$SWAPFILE"; then
  warn "btrfs mkswapfile was unavailable; using the compatible NOCOW method."
  sudo truncate -s 0 "$SWAPFILE"
  sudo chattr +C "$SWAPFILE"
  sudo btrfs property set "$SWAPFILE" compression none
  sudo fallocate -l "$SWAPSIZE" "$SWAPFILE"
  sudo chmod 600 "$SWAPFILE"
  sudo mkswap "$SWAPFILE" >/dev/null
fi
sudo swapon "$SWAPFILE" ||
  die "Temporary swap could not be activated."
printf '    Swap active at %s\n' "$SWAPFILE"

# ---------------------------------------------------------- real preflight
msg "Preflight 1/3: checking high-risk NixOS option paths"
if OPTOUT="$(
  sudo env NIXPKGS_ALLOW_UNFREE=1 \
    nix "${NIXFLAGS[@]}" --store "$STORE_ROOT" eval --impure --raw \
    --file "$BUILD/preflight-options.nix" \
    --argstr flake "$BUILD" 2>&1
)"; then
  printf '%s\n' "$OPTOUT" | sed 's/^/    /'
  if printf '%s\n' "$OPTOUT" | grep -q '^MISSING OPTIONS'; then
    die "One or more required NixOS options do not exist. The existing @ is unchanged."
  fi
else
  printf '%s\n' "$OPTOUT" | tail -n 12 | sed 's/^/    | /'
  die "The option preflight itself failed. The existing @ is unchanged."
fi

msg "Preflight 2/3: building the complete system closure"
printf '    This is a real build, not a dry run. It can take a long time.\n'
printf '    The existing @ remains in place throughout this build.\n'
sudo env NIXPKGS_ALLOW_UNFREE=1 \
  nix "${NIXFLAGS[@]}" --store "$STORE_ROOT" build \
    --no-link \
    --print-build-logs \
    --impure \
    --option extra-substituters "/ $EXTRA_SUBS" \
    --option extra-trusted-public-keys "$EXTRA_KEYS" \
    "$BUILD#nixosConfigurations.$EXPECTED_HOST.config.system.build.toplevel" ||
  die "The full system build failed. The existing @ is unchanged."

printf '\n    FULL BUILD PASSED.\n'
printf '    No partition was formatted and the existing @ is still present.\n'

msg "Preflight 3/3: validating the packaged niri configuration"
NIRI_STORE_PATH="$(
  sudo env NIXPKGS_ALLOW_UNFREE=1 \
    nix "${NIXFLAGS[@]}" --store "$STORE_ROOT" eval --impure --raw \
      "$BUILD#nixosConfigurations.$EXPECTED_HOST.config.programs.niri.package.outPath"
)" || die "Could not resolve the built niri package. The existing @ is unchanged."
case "$NIRI_STORE_PATH" in
  /nix/store/*) ;;
  *) die "Nix returned an unexpected niri store path: $NIRI_STORE_PATH" ;;
esac
sudo test -x "$STORE_ROOT$NIRI_STORE_PATH/bin/niri" ||
  die "The built niri executable is missing from the target store."
sudo mkdir -p "$STORE_ROOT/tmp"
sudo chmod 1777 "$STORE_ROOT/tmp"
sudo cp "$BUILD/dotfiles/niri/config.kdl" \
  "$STORE_ROOT/tmp/justc-niri-config.kdl"
sudo env NIXPKGS_ALLOW_UNFREE=1 \
  nix "${NIXFLAGS[@]}" --store "$STORE_ROOT" run "$NIRI_STORE_PATH" -- \
    validate -c /tmp/justc-niri-config.kdl ||
  die "The built niri rejected the packaged config. The existing @ is unchanged."
sudo rm -f -- "$STORE_ROOT/tmp/justc-niri-config.kdl"
printf '    niri config accepted by %s.\n' "$NIRI_STORE_PATH"

# ---------------------------------------------------------- final consent
msg "Final target confirmation"
printf '    The next step will rename the old @ to %s.\n' "$ROLLBACK_NAME"
printf '    It will preserve @home, @nix, and @snapshots.\n'
printf '    Target disk: %s | %s | serial %s\n' \
  "$DISK_DEV" "${DISK_MODEL:-unknown}" "${DISK_SERIAL:-unknown}"
printf '    Windows disks are not modified.\n\n'
printf 'Type exactly  REINSTALL justc  to continue: '
read -r CONFIRMATION
[ "$CONFIRMATION" = "REINSTALL justc" ] ||
  die "Confirmation did not match. Cancelled with the existing @ unchanged."
sudo -v ||
  die "sudo authentication expired before the root switch. The existing @ is unchanged."

# --------------------------------------------------------- ESP safety copy
msg "Backing up the NixOS ESP into preserved @nix"
ESP_BACKUP="$TOP_MOUNT/@nix/$ESP_BACKUP_REL"
PROFILE_BACKUP="$TOP_MOUNT/@nix/.justc-installer/system-profile-$RUN_STAMP"
if sudo test -e "$ESP_BACKUP" || sudo test -L "$ESP_BACKUP"; then
  die "The per-run ESP backup path already exists: $ESP_BACKUP"
fi
if sudo test -e "$PROFILE_BACKUP" || sudo test -L "$PROFILE_BACKUP"; then
  die "The per-run profile backup path already exists: $PROFILE_BACKUP"
fi
sudo mkdir -p "$TOP_MOUNT/@nix/.justc-installer"
sudo mkdir "$ESP_BACKUP"
sudo cp -a "$TOP_MOUNT/@nix/var/nix/profiles/system" "$PROFILE_BACKUP"
sudo test -L "$PROFILE_BACKUP" ||
  die "The previous NixOS system profile was not backed up correctly."

# A Btrfs root snapshot does not itself keep referenced /nix/store paths alive.
# Register the old system closure as an explicit GC root so the automatic Nix
# garbage collector cannot invalidate the rollback while it is being tested.
GC_ROOT="$TOP_MOUNT/@nix/var/nix/gcroots/justc-installer/previous-system-$RUN_STAMP"
if sudo test -e "$GC_ROOT" || sudo test -L "$GC_ROOT"; then
  die "The per-run rollback GC root already exists: $GC_ROOT"
fi
sudo mkdir -p "$TOP_MOUNT/@nix/var/nix/gcroots/justc-installer"
sudo ln -s "$OLD_SYSTEM_LOGICAL" "$GC_ROOT"
sudo test -L "$GC_ROOT" ||
  die "Could not protect the previous system closure from garbage collection."

sudo mount -o umask=0077 "$ESP_DEV" "$ESP_PROBE"
if sudo test -d "$ESP_PROBE/EFI/Microsoft"; then
  die "The target ESP contains EFI/Microsoft. This contradicts the expected separate-disk layout."
fi
sudo cp -a "$ESP_PROBE/." "$ESP_BACKUP/"
sudo diff -qr "$ESP_PROBE" "$ESP_BACKUP" >/dev/null ||
  die "The ESP backup did not compare byte-for-byte with the mounted ESP."
sync
sudo umount "$ESP_PROBE"
printf '    ESP backup: %s\n' "$ESP_BACKUP"

# ----------------------------------------------------- reversible root swap
msg "Creating a fresh root while retaining the old root"
sudo mv "$TOP_MOUNT/@" "$TOP_MOUNT/$ROLLBACK_NAME"
ROOT_SWITCHED=1
sudo btrfs subvolume create "$TOP_MOUNT/@" >/dev/null
sync
printf '    Previous root retained as: %s\n' "$ROLLBACK_NAME"

# --------------------------------------------------------------- mount all
msg "Mounting the new system"
sudo mount -o compress=zstd,noatime,subvol=@ \
  /dev/mapper/cryptroot /mnt
sudo mkdir -p /mnt/boot /mnt/home /mnt/nix /mnt/.snapshots
sudo mount -o compress=zstd,noatime,subvol=@home \
  /dev/mapper/cryptroot /mnt/home
sudo mount -o compress=zstd,noatime,subvol=@nix \
  /dev/mapper/cryptroot /mnt/nix
sudo mount -o compress=zstd,noatime,subvol=@snapshots \
  /dev/mapper/cryptroot /mnt/.snapshots
sudo mount -o umask=0077 "$ESP_DEV" /mnt/boot

findmnt -n /mnt >/dev/null || die "Root mount failed."
findmnt -n /mnt/home >/dev/null || die "Home mount failed."
findmnt -n /mnt/nix >/dev/null || die "Nix mount failed."
findmnt -n /mnt/boot >/dev/null || die "ESP mount failed."

if sudo test -e /mnt/home/.snapshots; then
  sudo btrfs subvolume show /mnt/home/.snapshots >/dev/null 2>&1 ||
    die "/home/.snapshots exists but is not a Btrfs subvolume."
else
  sudo btrfs subvolume create /mnt/home/.snapshots >/dev/null
fi

# Remove only known NixOS bootloader paths, after taking the complete backup.
# Windows is on a different ESP and is never included in these targets.
msg "Removing obsolete NixOS bootloader files from the backed-up ESP"
ESP_CHANGED=1
sudo rm -rf -- \
  /mnt/boot/loader \
  /mnt/boot/EFI/nixos \
  /mnt/boot/EFI/systemd \
  /mnt/boot/EFI/Linux \
  /mnt/boot/EFI/limine \
  /mnt/boot/EFI/BOOT/BOOTX64.EFI \
  /mnt/boot/limine \
  /mnt/boot/limine.conf

# ---------------------------------------------------------------- install
msg "Installing the already-built NixOS closure"
sudo env NIXPKGS_ALLOW_UNFREE=1 \
  nixos-install \
    --root /mnt \
    --flake "$BUILD#$EXPECTED_HOST" \
    --no-channel-copy \
    --no-root-passwd \
    --impure \
    --option extra-substituters "$EXTRA_SUBS" \
    --option extra-trusted-public-keys "$EXTRA_KEYS" ||
  die "nixos-install failed. The previous root and ESP will be restored automatically."

# ------------------------------------------------------ critical validations
msg "Validating the installed system and bootloader"
if ! sudo test -e /mnt/etc/NIXOS && ! sudo test -L /mnt/etc/NIXOS; then
  die "The installed root is missing /etc/NIXOS."
fi
sudo test -L /mnt/nix/var/nix/profiles/system ||
  die "The installed system profile is missing."

LIMINE_CONFIG="$(
  sudo find /mnt/boot -maxdepth 5 -type f -iname limine.conf -print -quit
)"
[ -n "$LIMINE_CONFIG" ] ||
  die "Limine configuration was not installed on the ESP."
sudo test -f /mnt/boot/EFI/BOOT/BOOTX64.EFI ||
  die "Limine's removable-media fallback EFI file is missing."

printf '    Limine config: %s\n' "$LIMINE_CONFIG"
if sudo grep -q 'Windows 11' "$LIMINE_CONFIG"; then
  printf '    Windows menu entry present (F12 remains the fallback).\n'
else
  printf '    No Windows menu entry; use F12 firmware boot.\n'
fi

msg "Validating the packaged niri configuration with the built niri"
sudo mkdir -p /mnt/tmp
sudo cp "$BUILD/dotfiles/niri/config.kdl" /mnt/tmp/justc-niri-config.kdl
sudo nixos-enter --root /mnt -c \
  "niri validate -c /tmp/justc-niri-config.kdl" ||
  die "niri rejected the packaged config. Nothing was auto-edited."
sudo rm -f -- /mnt/tmp/justc-niri-config.kdl
printf '    niri config accepted.\n'

# --------------------------------------------------------- account + files
msg "Setting the login password for $EXPECTED_USER"
printf '    Choose the real account password now; it is not stored in this config.\n'
while ! sudo nixos-enter --root /mnt -c "passwd '$EXPECTED_USER'"; do
  warn "Password was not set."
  printf 'Type RETRY to try again, or anything else to roll back: '
  read -r PASSWORD_RETRY
  [ "$PASSWORD_RETRY" = "RETRY" ] ||
    die "No user password was set."
done

# From here onward, the new root, bootloader, compositor config, and login
# account have all passed. A dotfile/theme issue should not discard that
# bootable system or overwrite the newly chosen password.
INSTALL_SUCCEEDED=1

msg "Installing the reviewed config and dotfiles into the preserved home"
USER_HOME="/mnt/home/$EXPECTED_USER"
CONFIG_BACKUP="$USER_HOME/.justc-installer-backup-$RUN_STAMP"
if sudo test -e "$CONFIG_BACKUP" || sudo test -L "$CONFIG_BACKUP"; then
  die "The per-run home backup path already exists: $CONFIG_BACKUP"
fi
sudo mkdir -p "$CONFIG_BACKUP"
sudo chown "$EXPECTED_UID:$EXPECTED_GROUP" "$CONFIG_BACKUP"
if sudo test -e "$USER_HOME/nixos" || sudo test -L "$USER_HOME/nixos"; then
  sudo mv "$USER_HOME/nixos" "$CONFIG_BACKUP/nixos-before-install"
fi
sudo cp -a "$BUILD" "$USER_HOME/nixos"
sudo chown -R "$EXPECTED_UID:$EXPECTED_GROUP" "$USER_HOME/nixos"

sudo nixos-enter --root /mnt -c \
  "su - '$EXPECTED_USER' -c 'env JUSTC_DOTFILES_BACKUP=\$HOME/.justc-installer-backup-$RUN_STAMP/dotfiles-before-install bash \$HOME/nixos/dotfiles/link.sh'" ||
  die "The dotfile copy failed."

msg "Validating the installed niri configuration"
NIRI_CFG="/home/$EXPECTED_USER/.config/niri/config.kdl"
sudo nixos-enter --root /mnt -c "niri validate -c '$NIRI_CFG'" ||
  die "niri rejected the installed config. Nothing was auto-edited."
printf '    niri config accepted.\n'

msg "Pre-applying theme names"
sudo nixos-enter --root /mnt -c \
  "su - '$EXPECTED_USER' -c 'theme-apply'" ||
  warn "theme-apply did not run now; its user service retries at login."

msg "Packages skipped by the guarded package lists"
MISSING_FILE=/mnt/etc/justc/missing-packages
if sudo test -f "$MISSING_FILE"; then
  sudo sed 's/^/    /' "$MISSING_FILE"
else
  warn "The missing-package report was not generated."
fi

sudo cp "$LOG" "$PERSISTENT_LOG"

printf '\n'
printf '============================================================\n'
printf '  INSTALL COMPLETE\n'
printf '  Previous root: %s\n' "$ROLLBACK_NAME"
printf '  ESP backup:    /nix/%s\n' "$ESP_BACKUP_REL"
printf '  GC protection: /nix/var/nix/gcroots/justc-installer/previous-system-%s\n' "$RUN_STAMP"
printf '  Install log:   /nix/.justc-installer/install-%s.log\n' "$RUN_STAMP"
printf '\n'
printf '  Next: sudo reboot, then remove the installer USB.\n'
printf '  Limine should start NixOS; enter the LUKS passphrase,\n'
printf '  then log in as %s with the password you just set.\n' "$EXPECTED_USER"
printf '\n'
printf '  Keep the rollback root and ESP backup until the new system\n'
printf '  has booted and you have tested networking, both desktops,\n'
printf '  audio, and a second reboot.\n'
printf '============================================================\n'
