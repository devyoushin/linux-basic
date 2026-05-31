#!/usr/bin/env bash
set -euo pipefail

section() {
  printf '\n== %s ==\n' "$1"
}

section "host"
hostnamectl 2>/dev/null || hostname

section "kernel"
uname -a

section "uptime and load"
uptime

section "cpu"
nproc 2>/dev/null || true
lscpu 2>/dev/null | sed -n '1,20p' || true

section "memory"
free -h

section "disk"
df -hT

section "top processes"
ps -eo pid,ppid,user,stat,%cpu,%mem,comm --sort=-%cpu | head -15
