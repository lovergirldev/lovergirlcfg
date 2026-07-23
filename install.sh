#!/usr/bin/env bash
# GitHub checkout entry point for the reviewed v9 installer.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$ROOT/install-v9-reviewed.sh"
ARCHIVE="$ROOT/justc-nixos-v9-reviewed.zip"

[ -f "$INSTALLER" ] || {
  printf 'Missing reviewed installer: %s\n' "$INSTALLER" >&2
  exit 1
}
[ -f "$ARCHIVE" ] || {
  printf 'Missing reviewed archive: %s\n' "$ARCHIVE" >&2
  exit 1
}

exec bash "$INSTALLER" "$@"
