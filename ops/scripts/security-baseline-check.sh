#!/usr/bin/env bash
set -euo pipefail

section() {
  printf '\n== %s ==\n' "$1"
}

section "root login and password auth"
sshd_config="/etc/ssh/sshd_config"
if [[ -r "$sshd_config" ]]; then
  grep -Ei '^(PermitRootLogin|PasswordAuthentication|PubkeyAuthentication|AllowUsers|AllowGroups)' "$sshd_config" || true
else
  echo "cannot read $sshd_config"
fi

section "sudo group"
getent group sudo || getent group wheel || true

section "world writable directories"
find / -xdev -type d -perm -0002 -maxdepth 4 2>/dev/null | head -100 || true

section "suid files"
find / -xdev -perm -4000 -type f 2>/dev/null | sort | head -100 || true
