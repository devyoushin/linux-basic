# linux-conntrack.md — 커넥션 트래킹 (conntrack)

## 1. 개요

`conntrack`은 Linux 커널의 넷필터(Netfilter) 서브시스템이 상태 기반 패킷 필터링을 위해 관리하는 연결 추적 테이블이다. iptables의 `-m state`, NAT, 그리고 Kubernetes kube-proxy(iptables/IPVS 모드)가 모두 conntrack에 의존한다. 고트래픽 환경에서 `nf_conntrack: table full, dropping packet` 에러는 서비스 단절을 초래하는 대표적 장애 패턴이며, SRE가 반드시 알아야 하는 커널 리소스다.

---

## 2. 설명

### 2.1 conntrack 기본 조회

```bash
# conntrack 패키지 설치
yum install conntrack-tools    # RHEL/CentOS
apt install conntrack          # Ubuntu/Debian

# 현재 테이블의 연결 수
conntrack -C

# 전체 conntrack 테이블 출력
conntrack -L

# 특정 프로토콜 필터
conntrack -L -p tcp
conntrack -L -p udp

# 특정 IP의 연결만 조회
conntrack -L --src 10.0.1.5
conntrack -L --dst 10.0.2.10

# 특정 상태 필터 (ESTABLISHED, TIME_WAIT 등)
conntrack -L -p tcp --state ESTABLISHED
```

### 2.2 conntrack 엔트리 읽는 법

```
tcp  6  86400  ESTABLISHED  src=10.0.1.5  dst=10.0.2.10  sport=52341  dport=443  \
              src=10.0.2.10 dst=10.0.1.5  sport=443    dport=52341  [ASSURED]  mark=0
│    │  │     │             │── 원본 방향(forward)                                   │
│    │  └─ TTL(초)          └── 응답 방향(reply)                               확인됨(양방향)
│    └─ L4 프로토콜 번호
└─ 프로토콜
```

**TCP conntrack 상태:**
| 상태 | 의미 |
|------|------|
| `SYN_SENT` | SYN 전송, 응답 대기 |
| `SYN_RECV` | SYN-ACK 수신 |
| `ESTABLISHED` | 3-way 핸드셰이크 완료 |
| `FIN_WAIT` | FIN 전송, 종료 대기 |
| `TIME_WAIT` | 연결 종료 후 소켓 재사용 대기 |
| `CLOSE` | 연결 종료 |
| `CLOSE_WAIT` | 상대방 FIN 수신 |

### 2.3 conntrack 테이블 용량 관련 파라미터

```bash
# 현재 conntrack 최대 엔트리 수
cat /proc/sys/net/netfilter/nf_conntrack_max
sysctl net.netfilter.nf_conntrack_max

# 현재 사용 중인 엔트리 수
cat /proc/sys/net/netfilter/nf_conntrack_count

# 해시 테이블 버킷 수 (최대 수의 1/4 ~ 1/8 권장)
cat /proc/sys/net/netfilter/nf_conntrack_buckets

# 사용률 계산 (80% 초과 시 위험)
echo "$(cat /proc/sys/net/netfilter/nf_conntrack_count) / $(cat /proc/sys/net/netfilter/nf_conntrack_max)" | bc -l
```

### 2.4 conntrack 테이블 풀 장애 대응

#### 장애 발생 메커니즘

`nf_conntrack_count`가 `nf_conntrack_max`에 도달하면 커널은 **새 연결의 패킷을 무조건 드롭**한다. 기존 ESTABLISHED 연결은 유지되지만 새 TCP 핸드셰이크, 새 UDP 플로우, 새 ICMP 요청이 모두 실패한다.

```
  새 패킷 도착
       │
       ▼
  ┌────────────────────────────┐
  │ Netfilter: nf_conntrack    │
  │ 새 엔트리 할당 시도        │
  └────────────┬───────────────┘
               │
       ┌───────┴───────┐
       │  count < max? │
       └───────┬───────┘
          YES  │  NO
          ▼    │  ▼
  ┌──────────┐ │ ┌───────────────────────────────────┐
  │ 엔트리   │ │ │ dmesg: "nf_conntrack: table full, │
  │ 생성     │ │ │        dropping packet"            │
  │ → 통과   │ │ │ /proc/net/stat/nf_conntrack       │
  └──────────┘ │ │  drop 카운터 증가                  │
               │ │ → 패킷 DROP                        │
               │ └───────────────────────────────────┘
               │
```

#### 주요 원인

| 원인 | 설명 |
|------|------|
| TCP established timeout 기본값 (5일) | `nf_conntrack_tcp_timeout_established` 기본 432000초 — idle 연결이 5일간 테이블에 잔류 |
| SYN Flood 공격 | 대량의 반개방(half-open) 연결이 `SYN_RECV` 상태로 테이블을 점유 |
| UDP 트래픽 급증 (DNS/QUIC) | DNS 쿼리·응답, QUIC 연결이 각각 별도 conntrack 엔트리를 소비 |
| Kubernetes Pod 급증 | 노드당 수백 Pod이 동시 배포되면 Service→Pod NAT로 엔트리 폭증 |
| `nf_conntrack_max` 미조정 | 기본값(보통 65536~262144)이 워크로드에 비해 작음 |
| 짧은 수명의 대량 연결 | 마이크로서비스 간 HTTP 요청 폭주 시 TIME_WAIT 엔트리 누적 |

#### 단계별 장애 탐지

```bash
# 1) 커널 로그에서 table full 메시지 확인
dmesg | grep -i "conntrack: table full"
journalctl -k --since "10 min ago" | grep "nf_conntrack"

# 2) /proc/net/stat/nf_conntrack에서 overflow(drop) 카운터 확인
#    첫 줄은 헤더, 이후 CPU별 통계. 16번째 필드(0-indexed)가 drop 카운터
cat /proc/net/stat/nf_conntrack
#    entries  searched  found  new  invalid  ignore  delete  ...  drop
#    drop 값이 증가하면 테이블 풀로 인한 패킷 드롭이 발생 중

# 3) 상태별 분포 집계 — 어떤 상태가 테이블을 점유하는지 파악
conntrack -L 2>/dev/null | awk '{print $4}' | sort | uniq -c | sort -rn
#  예시 출력:
#   128450 ESTABLISHED
#    23100 TIME_WAIT
#     5200 SYN_SENT
#      890 CLOSE_WAIT

# 4) 실시간 사용률 모니터링
watch -n 1 'echo "count: $(cat /proc/sys/net/netfilter/nf_conntrack_count) / max: $(cat /proc/sys/net/netfilter/nf_conntrack_max)"'
```

#### 즉각 대응 단계

장애 발생 시 아래 순서를 따른다.

```bash
# ── Step 1: 현황 파악 ──
COUNT=$(cat /proc/sys/net/netfilter/nf_conntrack_count)
MAX=$(cat /proc/sys/net/netfilter/nf_conntrack_max)
echo "현재: ${COUNT} / ${MAX}  ($(( COUNT * 100 / MAX ))%)"

# ── Step 2: nf_conntrack_max 임시 증가 ──
# conntrack 엔트리 1개 ≈ 320바이트 (커널 5.x 기준)
# 524288 × 320B ≈ 160MB, 1048576 × 320B ≈ 320MB
sysctl -w net.netfilter.nf_conntrack_max=1048576

# 해시 버킷도 함께 증가 (max의 1/4 권장)
echo 262144 > /sys/module/nf_conntrack/parameters/hashsize

# ── Step 3: 불필요한 TIME_WAIT / CLOSE 엔트리 정리 ──
conntrack -D --state TIME_WAIT
conntrack -D --state CLOSE

# ── Step 4: 최후 수단 — 전체 테이블 플러시 ──
conntrack -F
```

> **주의**: `conntrack -F`는 conntrack 테이블의 **모든 엔트리를 삭제**한다. NAT 매핑, ESTABLISHED 연결 정보가 즉시 소멸하므로 기존 활성 연결이 모두 끊어진다. 장애 중 다른 수단이 없을 때에만 최후 수단으로 사용한다.

#### 근본 해결 — timeout 단축

TCP idle 연결이 5일(432000초)간 테이블에 남는 것이 풀 장애의 가장 흔한 근본 원인이다. 워크로드에 맞게 timeout을 단축한다.

```bash
# /etc/sysctl.d/99-conntrack.conf

# ── 테이블 용량 ──
net.netfilter.nf_conntrack_max = 524288               # 기본 65536~262144 → 증가
net.netfilter.nf_conntrack_buckets = 131072            # max의 1/4

# ── TCP timeout ──
net.netfilter.nf_conntrack_tcp_timeout_syn_sent = 30   # 기본 120초 → 30초 (SYN 보내고 응답 없는 연결 빨리 정리)
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 30   # 기본 60초 → 30초 (SYN_RECV 상태 단축)
net.netfilter.nf_conntrack_tcp_timeout_established = 300  # 기본 432000초(5일) → 300초 (idle 연결 5분)
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30   # 기본 120초 → 30초
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30  # 기본 120초 → 30초
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 10 # 기본 60초 → 10초
net.netfilter.nf_conntrack_tcp_timeout_close = 10      # 기본 10초 → 유지

# ── UDP timeout ──
net.netfilter.nf_conntrack_udp_timeout = 30            # 기본 30초 → 유지 (단발성 UDP)
net.netfilter.nf_conntrack_udp_timeout_stream = 60     # 기본 180초 → 60초 (스트림성 UDP)
```

```bash
# 적용
sysctl -p /etc/sysctl.d/99-conntrack.conf
```

> **주의**: `tcp_timeout_established`를 지나치게 짧게(예: 60초 이하) 설정하면 정상적인 장기 유휴 연결(DB 커넥션 풀, SSH 터널 등)이 끊어질 수 있다. 애플리케이션의 keepalive 주기보다 길게 설정해야 한다.

#### 사전 감지를 위한 모니터링

Prometheus `node-exporter`는 conntrack 관련 메트릭을 기본 수집한다.

| 메트릭 | 설명 |
|--------|------|
| `node_nf_conntrack_entries` | 현재 conntrack 테이블 사용 엔트리 수 |
| `node_nf_conntrack_entries_limit` | `nf_conntrack_max` 값 |

```yaml
# Prometheus alerting rule — conntrack 사용률 80% 초과 시 경보
groups:
- name: conntrack
  rules:
  - alert: ConntrackTableNearFull
    # 현재 엔트리 수 / 최대 허용 수 × 100 > 80
    expr: >
      (node_nf_conntrack_entries / node_nf_conntrack_entries_limit) * 100 > 80
    for: 5m
    labels:
      severity: warning
    annotations:
      summary: "conntrack 테이블 사용률 80% 초과 ({{ $labels.instance }})"
      description: >
        현재 {{ $value | printf "%.1f" }}% 사용 중.
        nf_conntrack_max 증가 또는 timeout 단축 필요.

  - alert: ConntrackTableCritical
    # 95% 초과 시 즉시 대응 필요
    expr: >
      (node_nf_conntrack_entries / node_nf_conntrack_entries_limit) * 100 > 95
    for: 1m
    labels:
      severity: critical
    annotations:
      summary: "conntrack 테이블 임계치 초과 ({{ $labels.instance }})"
      description: >
        현재 {{ $value | printf "%.1f" }}% 사용 중. 즉시 대응 필요.
```

```bash
# Grafana에서 사용할 PromQL 예시
# 사용률 게이지
node_nf_conntrack_entries / node_nf_conntrack_entries_limit * 100

# 엔트리 증가 속도 (5분간 초당 증가량)
rate(node_nf_conntrack_entries[5m])
```

### 2.5 Kubernetes에서의 conntrack 이슈

Kubernetes kube-proxy (iptables/IPVS 모드)는 모든 Service-Pod 간 NAT에 conntrack을 사용한다. 노드당 수천 개의 Pod이 연결되는 환경에서 conntrack 테이블 풀은 클러스터 전체 네트워크 단절로 이어진다.

```bash
# 노드에서 확인 (DaemonSet 또는 kubectl debug node)
kubectl debug node/<node-name> -it --image=ubuntu -- bash
cat /proc/sys/net/netfilter/nf_conntrack_count
cat /proc/sys/net/netfilter/nf_conntrack_max

# conntrack 관련 kube-proxy 설정
kubectl -n kube-system get configmap kube-proxy -o yaml | grep conntrack
```

```yaml
# kube-proxy ConfigMap에서 conntrack 튜닝
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
conntrack:
  maxPerCore: 32768        # 코어당 최대 (0=자동)
  min: 131072              # 최소 보장값
  tcpEstablishedTimeout: 300s
  tcpCloseWaitTimeout: 10s
```

```yaml
# DaemonSet으로 노드 conntrack 파라미터 초기화 (init container 패턴)
initContainers:
- name: setup-conntrack
  image: busybox
  securityContext:
    privileged: true
  command:
  - sh
  - -c
  - |
    sysctl -w net.netfilter.nf_conntrack_max=524288
    sysctl -w net.netfilter.nf_conntrack_tcp_timeout_established=300
```

### 2.6 conntrack 모니터링

```bash
# 실시간 이벤트 모니터링 (연결 생성/소멸)
conntrack -E

# 연결 생성만 모니터
conntrack -E -e NEW

# 특정 IP 연결 생성/소멸 추적
conntrack -E --src 10.0.1.5

# conntrack 통계 (CPU별)
conntrack -S

# 상태별 카운트 집계
conntrack -L 2>/dev/null | awk '{print $4}' | sort | uniq -c | sort -rn
```

### 2.7 conntrack 우회: NOTRACK 규칙

고성능이 필요한 내부 트래픽(예: 클러스터 내 Pod-to-Pod)은 conntrack을 우회해 오버헤드를 줄일 수 있다.

```bash
# iptables로 특정 트래픽 conntrack 제외 (raw 테이블)
iptables -t raw -A PREROUTING -p tcp --dport 9999 -j NOTRACK
iptables -t raw -A OUTPUT -p tcp --sport 9999 -j NOTRACK

# 확인
iptables -t raw -L -nv
```

> **주의**: NOTRACK 규칙을 적용한 트래픽은 NAT와 상태 기반 필터링이 작동하지 않는다. iptables `-m state --state ESTABLISHED`도 매칭되지 않으므로 반드시 명시적 ACCEPT 규칙이 필요하다.

### 2.8 Terraform/Ansible로 노드 conntrack 설정

```yaml
# Ansible: conntrack 파라미터 영구 설정
- name: Configure conntrack limits
  sysctl:
    name: "{{ item.key }}"
    value: "{{ item.value }}"
    state: present
    reload: yes
    sysctl_file: /etc/sysctl.d/99-conntrack.conf
  loop:
    - { key: net.netfilter.nf_conntrack_max, value: 524288 }
    - { key: net.netfilter.nf_conntrack_tcp_timeout_established, value: 300 }
    - { key: net.netfilter.nf_conntrack_tcp_timeout_time_wait, value: 30 }
```

---

## 3. 자주 하는 실수

| 실수 | 올바른 방법 |
|------|------------|
| conntrack_max를 올리지 않고 iptables 규칙만 늘림 | 연결 수 증가 시 nf_conntrack_max 반드시 함께 조정 |
| TCP established timeout 기본값(5일) 방치 | 단기 서비스는 300~3600초로 단축 |
| Kubernetes 노드에서 conntrack 모니터링 누락 | 노드당 nf_conntrack_count 메트릭 수집 (Prometheus node-exporter) |
| `conntrack -F`로 전체 삭제 | 기존 연결 모두 단절됨 — 장애 중 최후 수단으로만 사용 |
| 버킷 수 자동 계산 맡김 | nf_conntrack_buckets = max / 4로 명시 설정 |
| conntrack 테이블 풀을 TCP 문제로만 인식 | UDP(DNS, QUIC)도 conntrack 테이블 소비 |
