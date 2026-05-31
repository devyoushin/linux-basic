#!/usr/bin/env bash
set -euo pipefail

since="${1:-1 hour ago}"

if ! command -v journalctl >/dev/null 2>&1; then
  echo "journalctl command not found"
  exit 0
fi

journalctl --since "$since" --no-pager |
  grep -Ei 'error|failed|timeout|denied|refused|oom|segfault' |
  sed -E 's/[[:space:]]+/ /g' |
  tail -200
