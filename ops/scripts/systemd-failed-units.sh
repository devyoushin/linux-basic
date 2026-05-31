#!/usr/bin/env bash
set -euo pipefail

section() {
  printf '\n== %s ==\n' "$1"
}

section "failed units"
systemctl --failed --no-pager

section "recent high priority journal"
journalctl -p warning..alert --since "1 hour ago" --no-pager || true
