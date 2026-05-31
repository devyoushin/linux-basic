#!/usr/bin/env bash
set -euo pipefail

section() {
  printf '\n== %s ==\n' "$1"
}

section "free"
free -h

section "vmstat"
vmstat 1 5

section "swap"
swapon --show || true

section "memory pressure"
grep -E 'MemTotal|MemAvailable|SwapTotal|SwapFree|Dirty|Writeback|Slab|SReclaimable' /proc/meminfo

section "oom killer logs"
if command -v journalctl >/dev/null 2>&1; then
  journalctl -k --since "24 hours ago" | grep -Ei 'oom|out of memory|killed process' || true
else
  dmesg | grep -Ei 'oom|out of memory|killed process' || true
fi
