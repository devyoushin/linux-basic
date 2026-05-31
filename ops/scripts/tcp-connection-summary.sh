#!/usr/bin/env bash
set -euo pipefail

section() {
  printf '\n== %s ==\n' "$1"
}

section "socket summary"
ss -s

section "tcp states"
ss -tan | awk 'NR > 1 { count[$1]++ } END { for (state in count) print state, count[state] }' | sort

section "top remote endpoints"
ss -tan | awk 'NR > 1 { print $5 }' | sed 's/^\[//; s/\]//' | sort | uniq -c | sort -nr | head -20
