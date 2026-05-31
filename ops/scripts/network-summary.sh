#!/usr/bin/env bash
set -euo pipefail

section() {
  printf '\n== %s ==\n' "$1"
}

section "addresses"
ip -brief addr

section "routes"
ip route

section "dns"
cat /etc/resolv.conf

section "listening sockets"
ss -lntup 2>/dev/null || ss -lntu

section "tcp summary"
ss -s

section "interface counters"
ip -s link
