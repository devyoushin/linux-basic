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

#### 증상 확인

```bash
# 커널 로그에서 drop 확인
dmesg | grep -i "conntrack: table full"
journalctl -k | grep "nf_conntrack"

# 네트워크 통계에서 conntrack overflow 확인
netstat -s | grep -i conntrack
cat /proc/net/stat/nf_conntrack | awk '{print $1, $2}' | head -5
```

#### 즉시 조치 (임시)

```bash
# conntrack 최대값 증가 (즉시 적용)
sysctl -w net.netfilter.nf_conntrack_max=524288

# 오래된 TIME_WAIT 강제 정리
conntrack -D --state TIME_WAIT

# 특정 프로토콜의 모든 연결 삭제 (위험, 장애 중 최후 수단)
conntrack -F -p tcp
```

#### 영구 적용

```bash
# /etc/sysctl.d/99-conntrack.conf
net.netfilter.nf_conntrack_max = 524288
net.netfilter.nf_conntrack_buckets = 131072    # max의 1/4
net.netfilter.nf_conntrack_tcp_timeout_established = 300   # 기본 432000초(5일) → 단축
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30      # 기본 120초 → 단축
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 10
net.netfilter.nf_conntrack_udp_timeout = 30                # UDP 기본 30초
net.netfilter.nf_conntrack_udp_timeout_stream = 60

sysctl -p /etc/sysctl.d/99-conntrack.conf
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
