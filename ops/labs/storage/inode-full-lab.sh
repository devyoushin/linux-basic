#!/usr/bin/env bash
set -euo pipefail

workdir="${1:-/tmp/inode-lab}"
mkdir -p "$workdir"

echo "creating small files under $workdir"
for i in $(seq 1 1000); do
  : > "$workdir/file-$i"
done

df -hi "$workdir"
echo "cleanup: rm -rf $workdir"
