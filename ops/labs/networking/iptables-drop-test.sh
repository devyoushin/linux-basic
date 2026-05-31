#!/usr/bin/env bash
set -euo pipefail

cat <<'MSG'
This lab intentionally changes iptables rules.
Run commands manually after reviewing them:

sudo iptables -I INPUT -p tcp --dport 8080 -j DROP
curl -m 3 http://127.0.0.1:8080/
sudo iptables -D INPUT -p tcp --dport 8080 -j DROP
MSG
