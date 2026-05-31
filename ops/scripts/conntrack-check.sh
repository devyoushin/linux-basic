#!/usr/bin/env bash
set -euo pipefail

section() {
  printf '\n== %s ==\n' "$1"
}

section "conntrack sysctl"
for key in \
  net.netfilter.nf_conntrack_count \
  net.netfilter.nf_conntrack_max \
  net.netfilter.nf_conntrack_buckets; do
  sysctl "$key" 2>/dev/null || true
done

section "conntrack command"
if command -v conntrack >/dev/null 2>&1; then
  conntrack -S || true
else
  echo "conntrack command not found"
fi
