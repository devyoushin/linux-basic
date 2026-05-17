# SYN Flood 방어

## 1. 개요

SYN Flood는 TCP 3-way 핸드셰이크의 첫 단계(SYN)를 대량으로 발생시켜 서버의 연결 대기 큐(backlog)를 고갈시키는 DoS/DDoS 공격이다. 서버는 SYN을 받으면 SYN-ACK를 보내고 반완성(half-open) 연결을 메모리에 유지하는데, 공격자는 ACK를 보내지 않아 해당 자원을 고갈시킨다. 적절한 커널 파라미터 튜닝, iptables/nftables 규칙, 클라우드 레벨 방어를 함께 적용해야 실효성 있는 방어가 가능하다.

---

## 2. 설명

### 2.1 핵심 개념

#### TCP 3-way 핸드셰이크와 공격 원리

```
정상 흐름:
  Client → SYN      → Server  (SYN_RECV 상태 진입, backlog 큐에 저장)
  Client ← SYN-ACK  ← Server
  Client → ACK      → Server  (ESTABLISHED, 큐에서 제거)

SYN Flood:
  Client → SYN (위조 IP) → Server  (SYN_RECV, 큐 점유)
  Client ← SYN-ACK       ← Server  (ACK 없음, 큐 계속 점유)
  ... 반복 → backlog 큐 고갈 → 정상 연결 거부
```

#### SYN Cookie (핵심 방어 메커니즘)

SYN Cookie는 backlog 큐를 사용하지 않고 SYN-ACK의 시퀀스 번호 자체에 연결 정보를 암호화 인코딩하는 기법이다. ACK가 돌아왔을 때 시퀀스 번호를 검증하여 정상 연결만 수립한다.

```
SYN Cookie 흐름:
  Client → SYN               → Server
  Client ← SYN-ACK (seq=쿠키) ← Server  (backlog 큐 사용 안 함)
  Client → ACK (ack=쿠키+1)   → Server  (쿠키 검증 → ESTABLISHED)
```

> **참고**: SYN Cookie 활성화 시 TCP 옵션(window scale, timestamps, SACK)이 일부 제한될 수 있다.

#### 핵심 커널 파라미터 정리

| 파라미터 | 기본값 | 권장값 | 설명 |
|----------|--------|--------|------|
| `net.ipv4.tcp_syncookies` | 1 | 1 | SYN Cookie 활성화 (필수) |
| `net.ipv4.tcp_max_syn_backlog` | 512 | 4096~65536 | SYN_RECV 상태 최대 큐 크기 |
| `net.ipv4.tcp_synack_retries` | 5 | 2 | SYN-ACK 재전송 횟수 (대기 시간 단축) |
| `net.ipv4.tcp_syn_retries` | 6 | 3 | SYN 재전송 횟수 |
| `net.core.somaxconn` | 128 | 4096~65535 | listen() 백로그 상한 |
| `net.ipv4.tcp_abort_on_overflow` | 0 | 0 | 큐 초과 시 RST 대신 무시 |

---

### 2.2 실무 명령어

#### SYN Flood 공격 탐지

```bash
# SYN_RECV 상태 연결 수 확인 (정상: 수십 개, 공격 중: 수천~수만 개)
ss -ant | awk '{print $1}' | sort | uniq -c | sort -rn

# SYN_RECV 상태만 필터링하여 상위 소스 IP 확인
ss -ant state syn-recv | awk '{print $5}' | cut -d: -f1 | sort | uniq -c | sort -rn | head -20

# netstat로 동일 확인 (ss가 없을 경우)
netstat -ant | grep SYN_RECV | awk '{print $5}' | cut -d: -f1 | sort | uniq -c | sort -rn | head -20

# 초당 SYN 패킷 수 실시간 모니터링
watch -n 1 "ss -ant | grep -c SYN_RECV"

# tcpdump로 SYN 패킷 급증 확인 (샘플링)
tcpdump -i eth0 -n 'tcp[13] & 2 != 0' -c 1000 | awk '{print $3}' | cut -d. -f1-4 | sort | uniq -c | sort -rn | head -10
```

#### SYN Cookie 및 커널 파라미터 설정

```bash
# 현재 SYN Cookie 상태 확인
sysctl net.ipv4.tcp_syncookies

# SYN Cookie 즉시 활성화 (재부팅 시 초기화)
sysctl -w net.ipv4.tcp_syncookies=1

# SYN_RECV 큐 크기 확장
sysctl -w net.ipv4.tcp_max_syn_backlog=4096

# SYN-ACK 재전송 횟수 줄이기 (기본 5 → 2, 반완성 연결 대기 시간 단축)
sysctl -w net.ipv4.tcp_synack_retries=2

# listen 백로그 상한 확장
sysctl -w net.core.somaxconn=4096
```

```bash
# /etc/sysctl.d/99-synflood-defense.conf 에 영구 적용
cat << 'EOF' | sudo tee /etc/sysctl.d/99-synflood-defense.conf
# SYN Flood 방어 설정

# SYN Cookie 활성화 (필수)
net.ipv4.tcp_syncookies = 1

# SYN_RECV 상태 큐 크기 확장
net.ipv4.tcp_max_syn_backlog = 4096

# SYN-ACK 재전송 횟수 축소 (반완성 연결 빠른 해제)
net.ipv4.tcp_synack_retries = 2

# listen() 백로그 상한
net.core.somaxconn = 4096

# IP 스푸핑 방지 (rp_filter: Reverse Path Filtering)
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# 소스 라우팅 비활성화 (위조 패킷 경로 조작 방지)
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# ICMP 리다이렉트 무시
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
EOF

# 설정 즉시 적용
sudo sysctl --system
```

#### iptables를 이용한 SYN Flood 방어

```bash
# SYN 패킷에 한해 연결 속도 제한 (초당 200개, 최대 순간 400개 허용)
iptables -A INPUT -p tcp --syn \
  -m limit --limit 200/s --limit-burst 400 \
  -j ACCEPT

# 위 임계치 초과 SYN 패킷 드롭
iptables -A INPUT -p tcp --syn -j DROP

# hashlimit 모듈: 소스 IP별 SYN 속도 제한 (단일 IP당 초당 10개 제한)
iptables -A INPUT -p tcp --syn \
  -m hashlimit \
  --hashlimit-name syn_limit \
  --hashlimit-above 10/sec \
  --hashlimit-mode srcip \
  --hashlimit-burst 20 \
  -j DROP

# 새 연결 상태(NEW)인데 SYN 플래그 없는 비정상 패킷 차단
iptables -A INPUT -p tcp ! --syn -m state --state NEW -j DROP

# 설정 확인
iptables -L INPUT -n -v --line-numbers
```

```bash
# iptables 규칙 영구 저장 (Rocky/CentOS)
service iptables save

# iptables 규칙 영구 저장 (Debian/Ubuntu)
netfilter-persistent save
```

#### nftables를 이용한 SYN Flood 방어

```bash
# /etc/nftables-synflood.conf — nftables SYN Flood 방어 규칙
cat << 'EOF' | sudo tee /etc/nftables-synflood.conf
#!/usr/sbin/nft -f

table inet filter {
    # SYN Flood 방어용 미터 (소스 IP별 속도 제한)
    meter syn_flood_meter {
        type ipv4_addr
        size 65536
        flags dynamic
    }

    chain input {
        type filter hook input priority 0; policy drop;

        # 기존 연결 허용
        ct state established,related accept

        # 루프백 허용
        iifname lo accept

        # SYN 패킷 속도 제한: 소스 IP당 초당 10개 초과 시 드롭
        tcp flags syn \
            meter syn_flood_meter { ip saddr limit rate over 10/second } \
            drop

        # 비정상 NEW 연결 (SYN 없음) 차단
        tcp flags != syn ct state new drop

        # SSH, HTTP, HTTPS 허용
        tcp dport { 22, 80, 443 } accept
    }
}
EOF

# 규칙 적용
sudo nft -f /etc/nftables-synflood.conf

# 미터 상태 확인 (공격 중인 IP 목록)
sudo nft list meter inet filter syn_flood_meter
```

#### fail2ban을 이용한 자동 차단

```bash
# /etc/fail2ban/jail.d/syn-flood.conf
cat << 'EOF' | sudo tee /etc/fail2ban/jail.d/syn-flood.conf
[syn-flood]
enabled  = true
filter   = syn-flood
action   = iptables-allports[name=SYN]
logpath  = /var/log/kern.log
maxretry = 1
findtime = 60
bantime  = 3600
EOF

# /etc/fail2ban/filter.d/syn-flood.conf
cat << 'EOF' | sudo tee /etc/fail2ban/filter.d/syn-flood.conf
[Definition]
failregex = .*SYN flooding on port.* from <HOST>.*
ignoreregex =
EOF

# fail2ban 재시작
sudo systemctl restart fail2ban

# 차단 목록 확인
sudo fail2ban-client status syn-flood
```

---

### 2.3 클라우드/DevOps 연계

#### AWS Shield + NLB/ALB 구성

AWS에서는 SYN Flood를 여러 계층에서 방어한다.

| 계층 | 서비스 | 역할 |
|------|--------|------|
| 엣지 | AWS Shield Standard | 자동으로 L3/L4 DDoS 방어 (무료) |
| 엣지 | AWS Shield Advanced | 정교한 SYN Flood 방어 + DDoS 비용 보호 |
| L7 | AWS WAF | HTTP Flood, 요청 기반 필터 |
| L4 | NLB | SYN Proxy 기능 내장 (EC2 직접 노출 방지) |
| 인스턴스 | Security Group | 소스 IP/포트 화이트리스트 |

```hcl
# 버전: hashicorp/aws ~> 5.0 기준
# NLB를 EC2 앞에 배치하여 SYN Proxy 역할 수행
resource "aws_lb" "nlb" {
  name               = "<NAME>-nlb"
  load_balancer_type = "network"
  internal           = false
  subnets            = var.public_subnet_ids

  # 교차 가용 영역 부하 분산
  enable_cross_zone_load_balancing = true

  tags = {
    Name        = "<NAME>-nlb"
    Environment = "<ENVIRONMENT>"
    ManagedBy   = "terraform"
  }
}

# Shield Advanced 구독 (옵션: 고비용)
resource "aws_shield_protection" "nlb" {
  name         = "<NAME>-nlb-shield"
  resource_arn = aws_lb.nlb.arn
}
```

#### Kubernetes (노드 레벨 sysctl 적용)

```yaml
# DaemonSet으로 모든 노드에 SYN Flood 방어 파라미터 적용
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: sysctl-tuner
  namespace: kube-system
spec:
  selector:
    matchLabels:
      app: sysctl-tuner
  template:
    metadata:
      labels:
        app: sysctl-tuner
    spec:
      hostPID: true
      hostNetwork: true
      initContainers:
      - name: sysctl
        image: busybox:1.36
        securityContext:
          privileged: true
        command:
        - sh
        - -c
        - |
          # SYN Cookie 활성화
          sysctl -w net.ipv4.tcp_syncookies=1
          # SYN_RECV 큐 확장
          sysctl -w net.ipv4.tcp_max_syn_backlog=4096
          # SYN-ACK 재전송 축소
          sysctl -w net.ipv4.tcp_synack_retries=2
      containers:
      - name: pause
        image: gcr.io/google_containers/pause:3.9
```

#### Ansible로 전체 서버 일괄 적용

```yaml
# roles/syn-flood-defense/tasks/main.yml
---
- name: SYN Flood 방어 커널 파라미터 적용
  ansible.posix.sysctl:
    name: "{{ item.key }}"
    value: "{{ item.value }}"
    sysctl_file: /etc/sysctl.d/99-synflood-defense.conf
    reload: true
    state: present
  loop:
    - { key: net.ipv4.tcp_syncookies,        value: "1" }
    - { key: net.ipv4.tcp_max_syn_backlog,   value: "4096" }
    - { key: net.ipv4.tcp_synack_retries,    value: "2" }
    - { key: net.core.somaxconn,             value: "4096" }
    - { key: net.ipv4.conf.all.rp_filter,    value: "1" }

- name: iptables SYN Flood 속도 제한 규칙 적용
  ansible.builtin.iptables:
    chain: INPUT
    protocol: tcp
    tcp_flags:
      flags: ALL
      flags_set: SYN
    limit: "200/second"
    limit_burst: 400
    jump: ACCEPT
    comment: "SYN Flood: allow up to 200/s"

- name: iptables 초과 SYN 드롭 규칙
  ansible.builtin.iptables:
    chain: INPUT
    protocol: tcp
    tcp_flags:
      flags: ALL
      flags_set: SYN
    jump: DROP
    comment: "SYN Flood: drop excess SYN"
```

---

## 3. 자주 하는 실수

| 잘못된 방법 | 올바른 방법 | 이유 |
|-------------|-------------|------|
| `tcp_syncookies=1` 만 설정 | `tcp_max_syn_backlog`, `somaxconn`, `tcp_synack_retries` 함께 조정 | SYN Cookie만으로는 정상 트래픽 폭증 시 backlog 큐 고갈 방지 불충분 |
| iptables `limit` 없이 `-j ACCEPT` 전체 허용 | `--limit`/`--hashlimit` 으로 소스 IP별 속도 제한 적용 | 속도 제한 없이는 공격 패킷이 그대로 서버에 도달 |
| Security Group만으로 SYN Flood 방어 가능하다고 판단 | NLB/ALB + Shield Standard 조합 사용 | Security Group은 패킷 수 제한 기능이 없고 SYN Flood를 흡수하지 못함 |
| `tcp_synack_retries=0` 으로 설정 | `tcp_synack_retries=2` | 0으로 설정하면 정상 클라이언트 패킷 손실 시 연결 자체가 실패 |
| `rp_filter=0` (비활성) | `rp_filter=1` (strict) | IP 스푸핑된 SYN 패킷이 커널 레벨에서 걸러지지 않음 |
| SYN Flood 탐지를 애플리케이션 로그로만 확인 | `ss -ant | grep SYN_RECV` 수치와 커널 로그 함께 모니터링 | 애플리케이션 레벨에 도달 전 이미 backlog에서 차단되어 앱 로그에 안 남을 수 있음 |
| 방어 설정 후 검증 없이 완료 처리 | `sysctl -a | grep syncookies` 및 실제 트래픽으로 검증 | 설정 파일 오타나 우선순위 문제로 실제 적용 안 됐을 수 있음 |

---

## 4. 트러블슈팅

### 증상 1: SYN Cookie 활성화했는데 여전히 서버 응답 불가

**원인**: `net.core.somaxconn` 또는 애플리케이션의 listen backlog 값이 너무 작아 SYN Cookie 이전에 큐가 포화됨.

```bash
# listen backlog 상한 확인
sysctl net.core.somaxconn
# → 128이면 너무 작음, 4096 이상으로 증가

# 애플리케이션별 backlog 확인 (Nginx 예시)
grep backlog /etc/nginx/nginx.conf
# listen 80 backlog=4096; 으로 설정 필요

# Nginx reload
sudo nginx -t && sudo systemctl reload nginx
```

---

### 증상 2: SYN_RECV 상태 연결이 특정 IP에서 지속 급증

**원인**: 단일 소스 IP(또는 소수의 IP)에서 대량 SYN 전송 중.

```bash
# 공격 소스 IP 상위 목록 추출
ss -ant state syn-recv | awk '{print $5}' | cut -d: -f1 | \
  sort | uniq -c | sort -rn | head -10

# 상위 공격 IP 즉시 차단
iptables -I INPUT -s <IP_ADDR> -j DROP

# 다수의 IP를 ipset으로 일괄 차단 (성능 효율적)
ipset create blocklist hash:ip timeout 3600    # 1시간 자동 해제
ipset add blocklist <IP_ADDR>
iptables -I INPUT -m set --match-set blocklist src -j DROP
```

---

### 증상 3: 커널 로그에 "possible SYN flooding" 메시지

```bash
# 커널 로그에서 SYN flooding 메시지 확인
dmesg | grep -i "syn flood"
journalctl -k | grep -i "syn flood"
# 예: "TCP: request_sock_TCP: Possible SYN flooding on port 443. Sending cookies."
# → SYN Cookie가 정상 동작 중이나 공격 강도가 임계치를 넘었다는 의미
```

**조치**: 이 메시지 자체는 SYN Cookie가 작동한다는 정상 신호이나, 지속된다면 upstream 레벨(클라우드 WAF, CDN)에서 차단이 필요하다.

```bash
# 로그 임계치 조정 (너무 자주 출력되면 로그 노이즈)
sysctl -w net.ipv4.tcp_max_syn_backlog=8192
```

---

### 증상 4: iptables hashlimit 규칙 적용 후 정상 트래픽도 차단됨

**원인**: `--hashlimit-above` 임계값이 너무 낮거나, `--hashlimit-burst` 미설정.

```bash
# 현재 hashlimit 상태 확인
iptables -L INPUT -n -v | grep hashlimit

# 임계값 완화 (초당 50개, 순간 100개로 조정)
iptables -D INPUT -p tcp --syn \
  -m hashlimit --hashlimit-name syn_limit \
  --hashlimit-above 10/sec --hashlimit-mode srcip \
  --hashlimit-burst 20 -j DROP

iptables -A INPUT -p tcp --syn \
  -m hashlimit --hashlimit-name syn_limit \
  --hashlimit-above 50/sec --hashlimit-mode srcip \
  --hashlimit-burst 100 -j DROP
```

---

## 5. TIP

**SYN Cookie 활성화 임계치 확인**
`tcp_syncookies=1`은 큐가 가득 찼을 때만 자동 활성화된다. `tcp_syncookies=2`로 설정하면 항상 SYN Cookie를 사용하므로 TCP 옵션 협상이 불가한 클라이언트 대응에 유의한다.

```bash
# 값 2: 항상 SYN Cookie 사용 (테스트/고보안 환경)
sysctl -w net.ipv4.tcp_syncookies=2
```

**`/proc/net/netstat`으로 SYN Cookie 통계 확인**

```bash
# SYNCookiesSent / SYNCookiesRecv / SYNCookiesFailed 수치 확인
grep -E "SyncookiesSent|SyncookiesRecv|SyncookiesFailed" /proc/net/netstat
# SyncookiesFailed 급증 시 → 공격이 SYN Cookie 검증을 우회하려는 시도
```

**분산 SYN Flood(botnet)는 커널 레벨로 한계 있음**

단일 서버 커널 튜닝만으로는 수십만 IP에서 오는 분산 SYN Flood를 막기 어렵다. 이 경우 클라우드 레벨(AWS Shield Advanced, CloudFront, Cloudflare) 방어가 필수다.

**`ss` 명령어의 빠른 SYN 상태 요약**

```bash
# 상태별 연결 수를 한눈에 요약
ss -s
# 출력 예:
# TCP:   4589 (estab 4200, closed 80, orphaned 2, synrecv 300, timewait 75/0)
# synrecv 수치가 수천을 초과하면 공격 의심
```

**Cloudflare / CDN 계층 방어가 최우선**

웹 서비스라면 서버 IP를 직접 노출하지 않고 Cloudflare, AWS CloudFront 등 CDN 뒤에 배치하는 것이 SYN Flood 방어의 가장 효과적인 1차 수단이다. CDN은 엣지에서 TCP 종단을 처리하므로 오리진 서버가 공격에 노출되지 않는다.
