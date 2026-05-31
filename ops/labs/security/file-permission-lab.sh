#!/usr/bin/env bash
set -euo pipefail

workdir="${1:-/tmp/permission-lab}"
mkdir -p "$workdir"

echo "secret" > "$workdir/secret.txt"
chmod 600 "$workdir/secret.txt"

echo "public" > "$workdir/public.txt"
chmod 644 "$workdir/public.txt"

ls -l "$workdir"
echo "cleanup: rm -rf $workdir"
