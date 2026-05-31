#!/usr/bin/env bash
set -euo pipefail

section() {
  printf '\n== %s ==\n' "$1"
}

target="${1:-/}"

section "filesystems"
df -hT

section "inodes"
df -hi

section "mounts"
findmnt

section "block devices"
lsblk -f

section "largest entries under ${target}"
du -xh --max-depth=1 "$target" 2>/dev/null | sort -h | tail -20 || true
