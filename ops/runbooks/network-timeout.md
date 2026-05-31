# Network Timeout Runbook

## 증상

서비스 접속이 timeout되거나 간헐적으로 연결이 끊깁니다.

## 1. 로컬 네트워크 상태

```bash
ip -brief addr
ip route
ss -s
ss -tan | awk 'NR > 1 { count[$1]++ } END { for (state in count) print state, count[state] }'
```

## 2. DNS 확인

```bash
cat /etc/resolv.conf
getent hosts example.com
```

## 3. 대상 연결 확인

```bash
target=example.com
port=443
timeout 5 bash -c "cat < /dev/null > /dev/tcp/$target/$port"
```

## 4. 패킷 확인

```bash
tcpdump -ni any host <target-ip>
```

## 판단

- SYN-SENT가 많으면 상대방, routing, security group, firewall을 확인합니다.
- TIME-WAIT가 많다고 바로 장애는 아닙니다. 포트 고갈 여부를 같이 봅니다.
- DNS 실패와 TCP 실패를 분리해서 봅니다.

## 관련 문서

- `docs/networking/linux-network-troubleshooting.md`
- `docs/networking/linux-tcpdump.md`
- `docs/networking/linux-ss-netstat.md`
