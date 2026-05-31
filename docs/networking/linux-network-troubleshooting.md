# Linux 네트워크 트러블슈팅

## 1. 개요

네트워크 장애는 "왜 안 되지?"부터 시작해 원인이 L1(물리) ~ L7(애플리케이션)까지 걸쳐 있다. 무작정 재시작하기 전에 **계층별 가설 → 명령어로 검증 → 범위 좁히기** 순서를 따르면 대부분 30분 안에 원인을 특정할 수 있다. 이 문서는 실무에서 가장 많이 쓰는 명령어와 장애 유형별 진단 흐름을 정리한다.

---

## 2. 트러블슈팅 기본 원칙

```
증상 파악 → 계층 분리 → 명령어 검증 → 원인 특정 → 수정 → 재검증
```

- **OSI 계층을 아래에서 위로** 확인한다 (물리 → IP → TCP → 애플리케이션)
- 여러 곳을 동시에 바꾸지 않는다 — 한 번에 하나씩 변경해야 원인을 알 수 있다
- 수정 전 현재 상태를 반드시 기록한다 (`ip route show`, `iptables -L -n -v` 등)

---

## 3. 계층별 핵심 명령어

### 3-0. L2 — 링크/ARP 확인

```bash
# 인터페이스 UP/DOWN 상태 확인
ip link show
# → "state UP" 이면 정상, "state DOWN" 이면 물리 또는 설정 문제

# 같은 서브넷 내 통신 불가 시 ARP 테이블 확인
ip neigh show
# REACHABLE: 정상 / STALE: 오래됨 / FAILED: ARP 해석 실패(L2 문제)

# VLAN 설정 확인 (태깅 문제 의심 시)
ip -d link show eth0
cat /proc/net/vlan/config 2>/dev/null

# NIC 물리 상태 확인 (속도, 듀플렉스, 링크 감지)
ethtool eth0 | grep -E "Speed|Duplex|Link detected"
```

### 3-1. L3 — IP 연결성 확인

```bash
# 기본 연결 확인 (패킷 손실, RTT 측정)
ping -c 4 8.8.8.8

# MTU 문제 탐지: 큰 패킷(1472 byte) + DF 비트 설정
ping -M do -s 1472 8.8.8.8
# → "Frag needed" 응답이 오면 경로 중간에 MTU 불일치

# 라우팅 테이블 조회
ip route show
ip route get 10.0.0.1          # 특정 목적지로 가는 경로
ip route get 10.0.0.1 from 192.168.1.5  # 소스 IP까지 지정

# 인터페이스 상태 확인
ip link show
ip -s link show eth0           # 수신/송신 패킷·에러·드롭 카운터 포함

# ARP 테이블 (같은 서브넷 내 통신 불가 시)
ip neigh show
ip neigh show dev eth0
```

### 3-2. L4 — TCP/UDP 포트 및 소켓 확인

```bash
# 리스닝 포트 전체 목록 (포트 번호 숫자로, 프로세스 포함)
ss -tlnp

# 특정 포트에 연결된 소켓 상태
ss -tnp state established '( dport = :443 or sport = :443 )'

# TCP 연결 상태별 카운트 (CLOSE_WAIT, TIME_WAIT 모니터링)
ss -tan | awk '{print $1}' | sort | uniq -c | sort -rn

# 특정 포트 열려있는지 원격에서 확인 (패킷 송수신 없이)
nc -zv 10.0.0.1 6379           # Redis 포트 오픈 확인
nc -zv -w 3 10.0.0.1 5432      # 3초 타임아웃으로 PostgreSQL 확인

# UDP 포트 확인
nc -zuv 10.0.0.1 53            # DNS UDP 포트
```

### 3-3. 경로 추적 — 어디서 막히는지

```bash
# 기본 traceroute (UDP 사용)
traceroute 8.8.8.8

# ICMP 사용 (UDP 차단 환경에서)
traceroute -I 8.8.8.8

# TCP SYN으로 추적 (방화벽이 ICMP/UDP를 막는 경우)
traceroute -T -p 443 8.8.8.8

# 더 빠른 버전 (mtr: traceroute + ping 통합)
mtr --report --report-cycles 10 8.8.8.8
# → Loss%, Last RTT, Avg RTT 컬럼으로 손실 구간 파악
```

### 3-4. DNS 해석 확인

```bash
# 기본 이름 해석 (시스템 설정 그대로)
getent hosts example.com       # /etc/nsswitch.conf 순서 따름
nslookup example.com           # 기본 DNS 서버 사용

# 특정 DNS 서버로 직접 쿼리
dig @8.8.8.8 example.com A
dig @10.0.0.2 internal-service.local A   # 사내 DNS 서버 직접 쿼리

# CNAME/MX/NS 레코드 확인
dig example.com ANY
dig example.com MX

# 역방향 조회 (IP → 도메인)
dig -x 8.8.8.8

# 응답시간 확인 (Query time 항목)
dig @1.1.1.1 example.com | grep "Query time"

# TTL 확인 (캐시가 언제 갱신되는지)
dig example.com | grep -A1 "ANSWER SECTION"
```

### 3-5. 패킷 캡처 — 실제 패킷 확인

```bash
# eth0에서 특정 호스트와의 패킷 캡처
tcpdump -i eth0 host 10.0.0.1

# 특정 포트만 캡처 (HTTP)
tcpdump -i eth0 port 80

# TCP SYN 패킷만 (연결 시도 모니터링)
tcpdump -i eth0 'tcp[tcpflags] & tcp-syn != 0'

# 파일로 저장 후 Wireshark로 분석
tcpdump -i eth0 -w /tmp/capture.pcap port 443

# ICMP (ping 패킷) 확인
tcpdump -i eth0 icmp

# DNS 쿼리/응답 캡처
tcpdump -i eth0 port 53 -n
```

### 3-6. 방화벽 규칙 확인

```bash
# iptables 규칙 전체 조회 (패킷 카운터 포함)
iptables -L -n -v --line-numbers

# NAT 테이블 확인 (MASQUERADE, DNAT 규칙)
iptables -t nat -L -n -v

# nftables 사용 시스템
nft list ruleset

# 특정 포트에 걸린 DROP 규칙 찾기
iptables -L -n -v | grep "dpt:8080"

# conntrack 테이블 (현재 추적 중인 연결)
conntrack -L
conntrack -L | wc -l            # 추적 중인 연결 수
conntrack -L | grep ESTABLISHED | wc -l
```

---

## 4. 장애 시나리오별 진단 흐름

### 시나리오 1: 서비스가 갑자기 응답 없음

```bash
# Step 1: 프로세스가 살아있는지 확인
systemctl status nginx
ps aux | grep nginx

# Step 2: 포트가 열려 있는지 확인
ss -tlnp | grep :80

# Step 3: 로컬에서 직접 접근 가능한지 확인
curl -v http://localhost:80/health

# Step 4: 방화벽이 차단하고 있는지 확인
iptables -L -n -v | grep "dpt:80"

# Step 5: 원격에서 접근 가능한지 확인
nc -zv <서버_IP> 80

# Step 6: 패킷이 실제로 도달하는지 확인 (서버에서 실행)
tcpdump -i eth0 port 80 -nn
# 동시에 클라이언트에서 curl 실행 → 패킷이 보이면 소프트웨어 문제,
#                                   안 보이면 네트워크/방화벽 문제
```

### 시나리오 2: DNS 해석 실패 / 간헐적 타임아웃

**증상 유형:**
- `Name or service not known` — 완전 해석 실패
- 특정 도메인만 실패, 나머지는 정상
- 간헐적 DNS 타임아웃 (5초 지연 후 재시도)

```bash
# Step 1: 시스템 DNS 설정 확인
cat /etc/resolv.conf
# nameserver가 정상인지 확인 (127.0.0.53이면 systemd-resolved 사용 중)
# options에 timeout/attempts 설정 확인 (기본: timeout 5, attempts 2)

# Step 2: nsswitch 설정 확인
grep hosts /etc/nsswitch.conf
# "files dns" 순서: /etc/hosts → DNS 서버

# Step 3: DNS 서버 자체에 쿼리 가능한지 확인
dig @$(awk '/nameserver/{print $2; exit}' /etc/resolv.conf) google.com
# REFUSED: DNS 서버 접근 불가 / NXDOMAIN: 도메인 없음 / SERVFAIL: DNS 서버 문제

# Step 4: 직접 외부 DNS로 확인 (사내 DNS 우회)
dig @8.8.8.8 example.com
# 외부 DNS는 되고 내부 DNS만 안 되면 → 내부 DNS 서버 문제

# Step 5: dig +trace로 어느 계층에서 실패하는지 추적
dig +trace example.com
# 루트 → TLD → 권한 DNS 순서로 전체 해석 과정을 보여줌
# 특정 NS에서 응답이 없으면 해당 네임서버 장애

# Step 6: DNS 패킷을 직접 캡처하여 쿼리/응답 확인
tcpdump -i any port 53 -nn -c 20
# 쿼리만 나가고 응답이 안 오면 → DNS 서버 도달 불가 또는 방화벽 차단
# 응답에 SERVFAIL 포함 → 업스트림 DNS 서버 문제

# Step 7: 간헐적 타임아웃 — conntrack UDP timeout 확인
# DNS는 UDP 프로토콜 사용, conntrack이 UDP 엔트리를 너무 빨리 만료시키면
# 응답이 돌아와도 드롭됨
sysctl net.netfilter.nf_conntrack_udp_timeout
sysctl net.netfilter.nf_conntrack_udp_timeout_stream
# 기본값: 30초/120초 — 너무 낮으면 DNS 응답 드롭 가능

# Step 8: /etc/hosts 임시 등록 (긴급 조치)
echo "1.2.3.4 example.com" >> /etc/hosts
```

> **주의**: `/etc/hosts`에 임시 등록하면 DNS 변경이 반영되지 않으므로 장애 해소 후 반드시 제거한다.

**간헐적 DNS 실패 체크포인트:**

| 증상 | 원인 | 확인 방법 |
|------|------|----------|
| 5초 지연 후 성공 | 첫 번째 nameserver 불가, 두 번째로 fallback | `dig @<첫번째_NS>` 직접 시도 |
| 특정 도메인만 실패 | 해당 도메인의 권한 NS 장애 | `dig +trace <도메인>` |
| 대량 요청 시 실패 | conntrack table full로 UDP 응답 드롭 | `dmesg \| grep conntrack` |
| IPv6 쿼리 지연 | AAAA 쿼리 타임아웃 후 A로 fallback | `dig AAAA <도메인>`, resolv.conf에 `options single-request-reopen` 추가 |

### 시나리오 3: 연결은 되는데 패킷 손실/느림

```bash
# Step 1: 경로 상 손실 구간 파악
mtr --report --report-cycles 20 <목적지_IP>
# Loss% 컬럼에서 처음으로 손실이 발생하는 홉이 문제 구간

# Step 2: 인터페이스 에러 카운터 확인
ip -s link show eth0
# RX errors, TX errors, dropped 값이 증가하면 NIC/드라이버 문제

# Step 3: 네트워크 버퍼 오버플로우 확인
netstat -s | grep -E "retransmit|failed|error|overflow"
# receive buffer errors가 높으면 → 수신 버퍼 크기 증가 필요

# Step 4: CPU softirq 지연 확인 (패킷 처리 지연)
watch -n 1 'cat /proc/softirqs | grep NET_RX'
# 특정 CPU에만 몰리면 RPS/RFS 설정 필요

# Step 5: MTU mismatch 확인 (VPN/터널 환경에서 자주 발생)
ping -M do -s 1472 <목적지_IP>   # 1500 - 20(IP) - 8(ICMP) = 1472
ping -M do -s 1400 <목적지_IP>   # VPN 터널 고려시 더 작은 값
```

### 시나리오 4: TIME_WAIT / CLOSE_WAIT 폭증

```bash
# Step 1: 현재 상태 확인
ss -tan | awk '{print $1}' | sort | uniq -c | sort -rn

# Step 2: CLOSE_WAIT 많은 경우 (애플리케이션 버그)
# → 상대방이 FIN을 보냈는데 앱이 소켓을 닫지 않고 있음
ss -tnp state close-wait       # 어떤 프로세스인지 확인
# 해결: 앱 코드에서 connection.close() 누락 여부 확인

# Step 3: TIME_WAIT 많은 경우 (정상이지만 포트 고갈 가능)
# → 클라이언트 측에서 짧은 연결을 대량 생성할 때 발생
cat /proc/sys/net/ipv4/tcp_tw_reuse  # 1이면 TIME_WAIT 소켓 재사용 허용
ss -tan state time-wait | wc -l

# Step 4: 로컬 포트 고갈 확인
cat /proc/sys/net/ipv4/ip_local_port_range   # 기본: 32768 60999
# 사용 가능한 포트 수 계산: 60999 - 32768 = 28231개
ss -tan | grep TIME_WAIT | wc -l  # 이 값이 28231에 근접하면 위험

# Step 5: 단기 조치 (포트 범위 확장)
sysctl -w net.ipv4.ip_local_port_range="10000 65535"
sysctl -w net.ipv4.tcp_tw_reuse=1
```

### 시나리오 5: 특정 서버만 접근 안 됨 (라우팅 문제)

```bash
# Step 1: 해당 IP로 가는 경로 확인
ip route get <목적지_IP>
# "via" 다음이 게이트웨이 주소, "dev" 다음이 나가는 인터페이스

# Step 2: 게이트웨이가 ARP 테이블에 있는지 확인
ip neigh show | grep <게이트웨이_IP>
# REACHABLE: 정상 / STALE: 오래된 항목 / FAILED: ARP 실패

# Step 3: 라우팅 테이블에 블랙홀 경로 없는지 확인
ip route show type blackhole
ip route show type unreachable

# Step 4: 멀티 NIC 환경에서 잘못된 인터페이스로 나가는지 확인
ip route get <목적지_IP>
# 예상한 인터페이스(eth0)가 아닌 다른 인터페이스(eth1)로 나간다면 정책 라우팅 문제

# Step 5: policy routing 확인
ip rule list
ip route show table all | grep -v "^default"
```

### 시나리오 6: "Connection refused" vs "Connection timed out" 구분

```bash
# Connection refused → 포트에 리스닝 프로세스가 없거나 방화벽 REJECT
# Connection timed out → 방화벽 DROP, 경로 없음, 서버 다운

# 빠른 구분: 응답 시간 측정
time curl -sv --connect-timeout 3 http://<IP>:<PORT>/ 2>&1 | head -5
# 즉시 실패: refused (포트 닫힘)
# 3초 후 실패: timed out (DROP 또는 경로 없음)

# 서버 측에서 패킷 수신 여부 확인
tcpdump -i any port <PORT> -nn -c 5
# SYN 패킷이 들어오는지 확인:
# - 들어온다 + RST 응답: 포트 닫힘 (refused 원인)
# - 들어온다 + 응답 없음: 앱이 accept() 안 함
# - 안 들어온다: 네트워크/방화벽 차단 (timed out 원인)
```

### 시나리오 7: conntrack table full — 간헐적 패킷 드롭

**증상:**
- 기존 연결(ESTABLISHED)은 정상이지만 **신규 연결만 실패**
- `curl`이 간헐적으로 타임아웃, 서비스 헬스체크 실패
- dmesg에 `nf_conntrack: table full, dropping packet` 메시지

```bash
# Step 1: dmesg에서 conntrack 에러 확인
dmesg | grep conntrack
# "nf_conntrack: table full, dropping packet" → 확정 진단

# Step 2: 현재 conntrack 사용량 vs 최대값 확인
sysctl net.netfilter.nf_conntrack_max         # 최대 엔트리 수 (기본: 65536)
sysctl net.netfilter.nf_conntrack_count        # 현재 사용 중인 엔트리 수
# count가 max에 근접하면 위험

# Step 3: conntrack 통계 — 드롭 수 확인
cat /proc/net/stat/nf_conntrack
# 첫 줄이 헤더, 각 CPU별 통계 — "drop" 컬럼 값이 0이 아니면 패킷 드롭 발생

# Step 4: 상태별 분포 확인 — 어떤 상태가 테이블을 차지하는지
conntrack -L -o extended | awk '{print $4}' | sort | uniq -c | sort -rn
# TIME_WAIT가 대부분이면 → timeout 단축으로 해결 가능
# ESTABLISHED가 대부분이면 → max 값 증가 필요

# Step 5: 프로토콜별 분포 확인
conntrack -L | awk '{print $1}' | sort | uniq -c | sort -rn
# UDP 비율이 높으면 DNS/로그 수집 트래픽 확인

# ── 해결 ──

# 방법 1: conntrack 테이블 크기 증가 (즉시 적용)
sysctl -w net.netfilter.nf_conntrack_max=262144
# hashsize도 함께 조정 (max / 4 또는 max / 8)
echo 65536 > /sys/module/nf_conntrack/parameters/hashsize

# 방법 2: 타임아웃 단축 (불필요한 엔트리 빨리 정리)
sysctl -w net.netfilter.nf_conntrack_tcp_timeout_time_wait=30      # 기본 120초
sysctl -w net.netfilter.nf_conntrack_tcp_timeout_established=86400 # 기본 432000초(5일)
sysctl -w net.netfilter.nf_conntrack_udp_timeout=30                # 기본 30초
sysctl -w net.netfilter.nf_conntrack_udp_timeout_stream=60         # 기본 120초
```

> **주의**: `nf_conntrack_tcp_timeout_established`를 너무 짧게 설정하면 유휴 상태의 정상 연결이 끊어질 수 있다. DB 커넥션 풀 등 장시간 유지 연결이 있다면 최소 4시간(14400) 이상으로 설정한다.

```bash
# 방법 3: 특정 조건의 conntrack 엔트리 수동 삭제
conntrack -D -p tcp --state TIME_WAIT     # TIME_WAIT 상태 일괄 삭제
conntrack -D --src 10.0.1.100             # 특정 소스 IP 엔트리 삭제
conntrack -D -p udp                       # UDP 엔트리 전체 삭제

# 방법 4: 영구 적용 (/etc/sysctl.d/에 저장)
cat > /etc/sysctl.d/99-conntrack.conf << 'SYSCTL'
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_established = 86400
SYSCTL
sysctl --system
```

> 상세한 conntrack 테이블 구조와 NOTRACK 설정은 [`linux-conntrack.md`](linux-conntrack.md) 참고.

---

## 5. 성능 진단 명령어

```bash
# 실시간 네트워크 사용량 (인터페이스별)
watch -n 1 'cat /proc/net/dev | awk "NR>2{print \$1, \$2, \$10}"'

# sar로 네트워크 트래픽 히스토리 조회 (sysstat 패키지 필요)
sar -n DEV 1 5                 # 1초 간격 5번 측정
sar -n SOCK 1 5                # 소켓 통계 (TCP/UDP/raw 수)

# 소켓 메모리 사용량 확인
ss -m                          # 각 소켓의 send/recv 버퍼 사용량

# TCP 재전송 통계
netstat -s | grep retransmit
ss -s                          # 요약 통계 (estab, closed, orphan 수 등)

# NIC 드라이버 큐 드롭 확인 (ethtool 필요)
ethtool -S eth0 | grep -i "drop\|miss\|error"
```

---

## 6. 자주 쓰는 원라이너 모음

```bash
# 외부 통신 가능한지 빠르게 확인 (curl 없을 때)
echo > /dev/tcp/8.8.8.8/53 && echo "열림" || echo "차단됨"

# 포트 스캔 없이 단일 포트 확인
timeout 3 bash -c "echo >/dev/tcp/<IP>/<PORT>" 2>/dev/null && echo open || echo closed

# 현재 서버의 공인 IP 확인
curl -s ifconfig.me
curl -s checkip.amazonaws.com

# 네트워크 인터페이스별 IP 주소 깔끔하게 출력
ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}'

# ESTABLISHED 연결을 원격 IP별로 집계
ss -tn state established | awk '{print $5}' | cut -d: -f1 | sort | uniq -c | sort -rn | head -20

# 특정 프로세스가 어떤 포트를 사용하는지
ss -tlnp | grep <프로세스명>
lsof -i -n -P | grep <프로세스명>

# 최근 1분간 새로 생성된 TCP 연결 수 모니터링
watch -n 5 'ss -tan | grep ESTABLISHED | wc -l'
```

---

## 7. AWS 환경 특화 체크리스트

```bash
# EC2 인스턴스 메타데이터 확인 (네트워크 인터페이스, IP 정보)
curl -s http://169.254.169.254/latest/meta-data/network/interfaces/macs/
MAC=$(curl -s http://169.254.169.254/latest/meta-data/network/interfaces/macs/)
curl -s "http://169.254.169.254/latest/meta-data/network/interfaces/macs/${MAC}local-ipv4s"

# 보안 그룹 규칙 조회 (AWS CLI)
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
aws ec2 describe-instance-attribute \
  --instance-id $INSTANCE_ID \
  --attribute groupSet \
  --query 'Groups[*].GroupId' --output text

# VPC 흐름 로그에서 차단된 트래픽 확인
# 흐름 로그 필드: version account-id interface-id srcaddr dstaddr srcport dstport protocol packets bytes start end action log-status
# action=REJECT 인 항목이 차단된 패킷
aws logs filter-log-events \
  --log-group-name /aws/vpc/flowlogs \
  --filter-pattern "REJECT" \
  --start-time $(date -d '10 minutes ago' +%s000)

# ENI 수신/송신 패킷 드롭 확인 (CloudWatch)
aws cloudwatch get-metric-statistics \
  --namespace AWS/EC2 \
  --metric-name NetworkPacketsIn \
  --dimensions Name=InstanceId,Value=$INSTANCE_ID \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 --statistics Sum
```

---

## 8. 모니터링 및 알람 기준

사후 대응이 아닌 사전 감지를 위해 핵심 네트워크 메트릭에 알람을 설정한다.

### 8-1. Prometheus + node_exporter 기반 주요 메트릭

| 메트릭 | PromQL 예시 | 알람 임계값 | 의미 |
|--------|-------------|------------|------|
| conntrack 사용률 | `node_nf_conntrack_entries / node_nf_conntrack_entries_limit * 100` | > 80% (warn), > 95% (crit) | conntrack table full 직전 감지 |
| 수신 패킷 드롭 | `rate(node_network_receive_drop_total[5m])` | > 0 (sustained) | NIC/커널 수신 버퍼 부족 |
| 송신 에러 | `rate(node_network_transmit_errs_total[5m])` | > 0 (sustained) | NIC/드라이버 문제 |
| TCP 재전송 | `rate(node_netstat_Tcp_RetransSegs[5m])` | > 100/s | 네트워크 품질 저하 또는 혼잡 |
| TCP 연결 실패 | `rate(node_netstat_Tcp_AttemptFails[5m])` | > 50/s | 원격 포트 닫힘 또는 방화벽 DROP |
| TIME_WAIT 수 | `node_sockstat_TCP_tw` | > 20000 | 포트 고갈 임박 |
| UDP 수신 에러 | `rate(node_netstat_Udp_RcvbufErrors[5m])` | > 0 | UDP 소켓 버퍼 부족 (DNS 영향) |
| softnet 드롭 | `rate(node_softnet_dropped_total[5m])` | > 0 | CPU의 패킷 처리 큐 오버플로우 |

### 8-2. Alertmanager 룰 예시

```yaml
# conntrack table 사용률 경고
groups:
  - name: network
    rules:
      - alert: ConntrackTableNearFull
        expr: node_nf_conntrack_entries / node_nf_conntrack_entries_limit > 0.8
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "conntrack 사용률 {{ $value | humanizePercentage }} ({{ $labels.instance }})"
          description: "80% 초과 시 신규 연결 드롭 위험. nf_conntrack_max 증가 또는 timeout 단축 필요."

      - alert: HighTcpRetransmits
        expr: rate(node_netstat_Tcp_RetransSegs[5m]) > 100
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "TCP 재전송 {{ $value }}/s ({{ $labels.instance }})"

      - alert: PacketDropDetected
        expr: rate(node_network_receive_drop_total[5m]) > 0
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "{{ $labels.device}} 수신 드롭 감지 ({{ $labels.instance }})"
```

### 8-3. 빠른 확인용 쉘 명령어

```bash
# conntrack 사용률 확인 (Prometheus 없을 때)
echo "$(cat /proc/sys/net/netfilter/nf_conntrack_count) / $(cat /proc/sys/net/netfilter/nf_conntrack_max)" | bc -l

# TCP 재전송 비율 (10초 간격 비교)
T1=$(cat /proc/net/snmp | awk '/^Tcp:/{getline; print $13}')
sleep 10
T2=$(cat /proc/net/snmp | awk '/^Tcp:/{getline; print $13}')
echo "재전송/10초: $(( T2 - T1 ))"

# softnet 드롭 확인 (3번째 컬럼이 dropped)
cat /proc/net/softnet_stat | awk '{total += strtonum("0x"$2)} END {print "softnet dropped:", total}'
```

---

## 9. 자주 하는 실수

| 실수 | 올바른 방법 |
|------|------------|
| `netstat -tulnp` 결과 믿기 | `ss -tlnp`를 쓴다 — `netstat`은 대규모 연결에서 느리고 일부 배포판에서 기본 설치 안 됨 |
| `ping`만으로 "통신 된다"고 판단 | ICMP가 허용돼도 TCP 포트가 막힐 수 있음 — `nc -zv`로 포트별 확인 필요 |
| DNS 캐시 무시하고 바로 레코드 수정 | `dig`로 현재 TTL 확인 후 TTL 경과까지 대기 또는 강제 flush (`systemd-resolve --flush-caches`) |
| TIME_WAIT를 무조건 문제로 판단 | TIME_WAIT는 정상 TCP 동작 — CLOSE_WAIT 폭증이 진짜 문제 신호 |
| 방화벽 규칙 추가만 하고 저장 안 함 | `iptables-save > /etc/iptables/rules.v4`로 영구 저장 또는 `firewalld --permanent` 사용 |
| 패킷 캡처 없이 앱 로그만 보고 판단 | 앱 로그에 없는 문제는 `tcpdump`로 실제 패킷을 봐야 원인 파악 가능 |
| 원격지 포트 확인 시 `telnet` 사용 | `nc -zv` 또는 `curl -v`가 더 정확하고 현대적 — telnet은 없는 환경 많음 |
| MTU 문제를 성능 문제로 오해 | 대용량 파일 전송만 느리고 소량 통신은 정상이면 MTU mismatch 의심 (`ping -M do -s 1472`) |
| 간헐적 드롭을 애플리케이션 문제로만 판단 | `dmesg \| grep conntrack`으로 conntrack table full 여부부터 확인 — 신규 연결만 실패하는 패턴이면 conntrack 의심 |
| DNS 타임아웃을 DNS 서버 탓으로만 돌림 | conntrack UDP timeout, resolv.conf의 `options single-request-reopen`, IPv6 AAAA fallback도 원인이 될 수 있음 |

---

## 10. 트러블슈팅 체크리스트

장애 발생 시 순서대로 체크한다:

```
[ ] 1.  L2 인터페이스 상태: ip link show — UP/DOWN, 속도/듀플렉스 확인
[ ] 2.  L2 ARP 테이블: ip neigh show — 같은 서브넷 내 MAC 해석 정상 확인
[ ] 3.  L3 IP 주소 할당: ip addr show — 정상 IP 할당 확인
[ ] 4.  L3 기본 게이트웨이: ip route show default — 게이트웨이 설정 확인
[ ] 5.  L3 게이트웨이 도달: ping <GW_IP> — L3 연결 확인
[ ] 6.  L3 외부 IP 도달: ping 8.8.8.8 — 인터넷 연결 확인
[ ] 7.  L7 DNS 해석: dig @8.8.8.8 google.com — 외부 DNS 동작 확인
[ ] 8.  L3 목적지 도달: traceroute/mtr — 경로 상 어디서 막히는지
[ ] 9.  L4 포트 오픈: ss -tlnp / nc -zv — 서비스 포트 리스닝 확인
[ ] 10. L4 방화벽: iptables -L -n -v — DROP 규칙 확인
[ ] 11. L4 conntrack: conntrack -C vs nf_conntrack_max — 테이블 포화 확인
[ ] 12. 패킷 캡처: tcpdump — 패킷이 실제로 오가는지 확인
```
