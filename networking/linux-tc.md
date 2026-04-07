# linux-tc.md — tc (Traffic Control): 대역폭 제한, QoS, 네트워크 지연 시뮬레이션

## 1. 개요

`tc`(Traffic Control)는 Linux 커널의 패킷 스케줄러를 제어하는 도구다. 단순한 대역폭 제한을 넘어, 특정 IP/포트 트래픽에 우선순위를 부여하거나, 테스트 환경에서 지연(delay)/패킷 손실(loss)/지터(jitter)를 인위적으로 재현하는 카오스 엔지니어링에도 활용된다. 클라우드 환경에서는 멀티테넌트 서비스 간 대역폭 격리, 그리고 CI/CD 파이프라인에서 네트워크 불안정 재현에 필수 도구다.

---

## 2. 설명

### 2.1 tc 아키텍처

```
NIC (eth0)
   │
   ▼
┌─────────────────────────────────────────────────────┐
│  qdisc (Queuing Discipline, 큐잉 규칙)               │
│  ├── root qdisc (egress, 송신 방향)                  │
│  │    ├── class (HTB/CBQ 계층)                       │
│  │    │    ├── filter (분류기: IP/포트 기준 분류)     │
│  │    │    └── leaf qdisc (실제 큐, sfq/netem 등)    │
│  │    └── class ...                                  │
│  └── ingress qdisc (수신 방향, 제한적 기능)           │
└─────────────────────────────────────────────────────┘
   │
   ▼
 Application
```

**3가지 핵심 개념:**

| 개념 | 역할 | 비유 |
|---|---|---|
| **qdisc** (Queuing Discipline) | 패킷 스케줄링 알고리즘 | 창구(줄 서는 방식) |
| **class** | qdisc 내 트래픽 분류 계층 | 창구별 우선순위 그룹 |
| **filter** | 패킷을 어떤 class에 할당할지 결정 | 안내 직원(분류 기준) |

```bash
# 현재 설정된 qdisc 확인
tc qdisc show dev eth0

# 클래스 구조 확인
tc class show dev eth0

# 필터 확인
tc filter show dev eth0
```

### 2.2 qdisc 종류

```
classless qdisc (계층 없음, 단순):
  pfifo_fast   기본값, 3개 우선순위 밴드
  fq_codel     공정 큐잉 + CoDel AQM (현대 배포판 기본)
  netem        네트워크 에뮬레이터 (지연/손실/지터)
  tbf          Token Bucket Filter (단순 대역폭 제한)

classful qdisc (계층 있음, class + filter 조합):
  htb          Hierarchical Token Bucket (실무 표준)
  hfsc         계층적 공정 서비스 커브 (복잡하지만 정밀)
  cbq          Class-Based Queuing (구식)
```

### 2.3 HTB: 대역폭 보장 + 버스팅

HTB(Hierarchical Token Bucket)는 클래스별로 **보장 대역폭(rate)**과 **최대 대역폭(ceil)**을 정의하고, 여유 대역폭은 하위 클래스가 버스팅으로 활용한다.

```
           root 1:0
              │
           1:1 (100Mbps ceil)
          /         \
       1:10           1:20
  (rate:30M           (rate:60M
   ceil:100M)          ceil:100M)
  [HTTP 트래픽]       [DB 트래픽]
```

```bash
# ── HTB 기본 설정: eth0에서 HTTP(80)는 30Mbps 보장, DB(3306)는 60Mbps 보장
# 전체 인터페이스 한도: 100Mbps

# 1단계: root qdisc 설정 (handle 1:0)
tc qdisc add dev eth0 root handle 1: htb default 30
# default 30: 분류되지 않은 트래픽은 class 1:30으로

# 2단계: 루트 클래스 (전체 대역폭 정의)
tc class add dev eth0 parent 1: classid 1:1 htb \
    rate 100mbit \           # 루트 클래스: 전체 100Mbps
    ceil 100mbit

# 3단계: 자식 클래스
tc class add dev eth0 parent 1:1 classid 1:10 htb \
    rate 30mbit \            # HTTP: 30Mbps 보장
    ceil 100mbit \           # 여유 대역폭 버스팅 허용
    burst 15k

tc class add dev eth0 parent 1:1 classid 1:20 htb \
    rate 60mbit \            # DB: 60Mbps 보장
    ceil 100mbit \
    burst 15k

tc class add dev eth0 parent 1:1 classid 1:30 htb \
    rate 10mbit \            # 기타: 10Mbps
    ceil 50mbit

# 4단계: 각 클래스의 leaf qdisc (공정 큐잉)
tc qdisc add dev eth0 parent 1:10 handle 10: sfq perturb 10
tc qdisc add dev eth0 parent 1:20 handle 20: sfq perturb 10
tc qdisc add dev eth0 parent 1:30 handle 30: sfq perturb 10

# 5단계: 필터 (트래픽 분류)
# HTTP 트래픽 → 1:10
tc filter add dev eth0 protocol ip parent 1:0 prio 1 \
    u32 match ip dport 80 0xffff flowid 1:10

# HTTPS 트래픽 → 1:10
tc filter add dev eth0 protocol ip parent 1:0 prio 1 \
    u32 match ip dport 443 0xffff flowid 1:10

# MySQL 트래픽 → 1:20
tc filter add dev eth0 protocol ip parent 1:0 prio 1 \
    u32 match ip dport 3306 0xffff flowid 1:20
```

### 2.4 netem: 네트워크 조건 시뮬레이션 (카오스 엔지니어링)

netem(Network Emulator)은 지연, 패킷 손실, 지터, 패킷 중복, 패킷 순서 뒤섞기를 소프트웨어로 재현한다.

```bash
# ── 기본 지연 추가: eth0 전체에 100ms 지연
tc qdisc add dev eth0 root netem delay 100ms

# ── 지터 추가: 100ms ± 20ms 랜덤 지연
tc qdisc add dev eth0 root netem delay 100ms 20ms

# ── 지터 + 상관관계: 이전 패킷의 25% 영향을 다음 패킷에 반영 (실제 네트워크 유사)
tc qdisc add dev eth0 root netem delay 100ms 20ms 25%

# ── 패킷 손실 시뮬레이션: 1% 확률로 드롭
tc qdisc add dev eth0 root netem loss 1%

# ── 패킷 손실 + 상관관계 (버스트 손실 패턴)
tc qdisc add dev eth0 root netem loss 0.3% 25%

# ── Gilbert-Elliott 모델로 버스트 손실 (상태머신 기반)
tc qdisc add dev eth0 root netem loss gemodel 1% 10% 70% 0.1%
# p: bad→bad 전이 확률, r: bad→good 전이 확률, 1-h: good 상태 손실, 1-k: bad 상태 손실

# ── 패킷 중복
tc qdisc add dev eth0 root netem duplicate 1%

# ── 패킷 순서 뒤섞기
tc qdisc add dev eth0 root netem delay 10ms reorder 25% 50%

# ── 복합 조건: 지연 + 손실 + 지터
tc qdisc add dev eth0 root netem delay 200ms 50ms loss 2% corrupt 0.1%

# ── 설정 변경
tc qdisc change dev eth0 root netem delay 50ms

# ── 설정 제거 (모든 netem 해제)
tc qdisc del dev eth0 root
```

### 2.5 특정 IP/포트 트래픽만 제한하기

전체 인터페이스가 아닌 특정 대상에만 제한을 적용하려면 HTB + filter 조합을 사용한다.

```bash
# ── 시나리오: 특정 IP(10.0.2.100)로 가는 트래픽만 netem 적용

# 1단계: root HTB qdisc
tc qdisc add dev eth0 root handle 1: htb

# 2단계: 기본 클래스 (제한 없음, 나머지 트래픽)
tc class add dev eth0 parent 1: classid 1:1 htb \
    rate 1000mbit ceil 1000mbit

# 3단계: 제한 대상 클래스
tc class add dev eth0 parent 1: classid 1:2 htb \
    rate 1mbit ceil 1mbit      # 1Mbps로 제한

# 4단계: 제한 대상 클래스에 netem 달기 (지연도 추가)
tc qdisc add dev eth0 parent 1:2 handle 20: netem \
    delay 200ms loss 5%

# 5단계: 나머지 트래픽은 1:1 (기본)
tc qdisc add dev eth0 parent 1:1 handle 10: sfq

# 6단계: 필터: 목적지 IP가 10.0.2.100이면 1:2로
tc filter add dev eth0 protocol ip parent 1: prio 1 \
    u32 match ip dst 10.0.2.100/32 flowid 1:2

# 기본 필터: 나머지는 1:1
tc filter add dev eth0 protocol ip parent 1: prio 2 \
    u32 match u32 0 0 flowid 1:1
```

```bash
# ── 특정 포트(예: Redis 6379)로의 트래픽만 지연
tc qdisc add dev eth0 root handle 1: prio priomap 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0

tc qdisc add dev eth0 parent 1:3 handle 30: netem delay 300ms

tc filter add dev eth0 protocol ip parent 1: prio 1 \
    u32 match ip dport 6379 0xffff flowid 1:3
```

### 2.6 AWS VPC에서 tc 사용 시 주의사항

```
AWS VPC 환경에서의 tc 적용 레이어:

  EC2 Instance
    └── eth0 (ENI)  ← tc가 작동하는 레이어
          │
          ▼
      AWS Hypervisor (ENA 드라이버)
          │
          ▼
      VPC 네트워크 (AWS 레벨 대역폭 제한은 EC2 타입별로 별도 적용)
```

```bash
# AWS EC2에서 ENI의 기본 qdisc 확인
tc qdisc show dev eth0
# 출력: qdisc mq 0: root ...  또는  qdisc fq 0: root (ENA 드라이버)

# ENA 드라이버는 멀티큐(mq)를 사용. root로 단순 교체 불가
# 올바른 방법: ingress 방향 제어
tc qdisc add dev eth0 handle ffff: ingress
tc filter add dev eth0 parent ffff: protocol ip \
    u32 match ip src 0.0.0.0/0 \
    police rate 100mbit burst 10m drop flowid :1

# 또는 IFB(Intermediate Functional Block) 가상 인터페이스로 ingress를 egress처럼 처리
modprobe ifb
ip link set dev ifb0 up
tc qdisc add dev eth0 handle ffff: ingress
tc filter add dev eth0 parent ffff: protocol ip u32 match u32 0 0 \
    action mirred egress redirect dev ifb0
tc qdisc add dev ifb0 root handle 1: htb default 10
```

> **주의**: AWS EC2의 실제 네트워크 대역폭은 인스턴스 타입(예: c5.xlarge = 최대 10Gbps)으로 결정된다. tc는 인스턴스 내부 ENI 레벨에서만 작동하며, AWS 하이퍼바이저 레벨의 대역폭 제한을 우회하거나 늘리지 못한다.

### 2.7 테스트 환경 장애 훈련 패턴

```bash
#!/bin/bash
# chaos-network.sh: 카오스 엔지니어링 - 네트워크 불안정 재현

TARGET_IF="${1:-eth0}"
MODE="${2:-delay}"   # delay / loss / partition / restore

case "$MODE" in
    delay)
        # 데이터센터 간 고지연 재현 (200ms ± 50ms)
        tc qdisc add dev "$TARGET_IF" root netem delay 200ms 50ms 25%
        echo "[chaos] ${TARGET_IF}에 200ms ± 50ms 지연 적용"
        ;;

    loss)
        # 불안정한 네트워크 재현 (2% 손실, 버스트)
        tc qdisc add dev "$TARGET_IF" root netem \
            delay 50ms 10ms \
            loss 2% 30% \
            duplicate 0.1%
        echo "[chaos] ${TARGET_IF}에 2% 패킷 손실 + 50ms 지연 적용"
        ;;

    partition)
        # 네트워크 파티션: 특정 IP와 완전 단절
        PARTITION_IP="${3:-10.0.1.1}"
        tc qdisc add dev "$TARGET_IF" root handle 1: prio
        tc qdisc add dev "$TARGET_IF" parent 1:3 handle 30: netem loss 100%
        tc filter add dev "$TARGET_IF" protocol ip parent 1: prio 1 \
            u32 match ip dst "${PARTITION_IP}/32" flowid 1:3
        echo "[chaos] ${PARTITION_IP}으로의 트래픽 100% 차단"
        ;;

    restore)
        # 장애 주입 해제
        tc qdisc del dev "$TARGET_IF" root 2>/dev/null || true
        echo "[chaos] ${TARGET_IF} tc 설정 초기화"
        ;;

    *)
        echo "Usage: $0 <interface> <delay|loss|partition|restore> [target_ip]"
        exit 1
        ;;
esac
```

```bash
# 장애 훈련 시나리오 예시
./chaos-network.sh eth0 delay       # 지연 주입
sleep 60                             # 1분간 서비스 동작 관찰
./chaos-network.sh eth0 restore     # 복구

# iperf3로 효과 검증
iperf3 -c <대상IP> -t 10            # 처리량 측정
ping -c 20 <대상IP>                  # 지연 측정
```

### 2.8 tc 상태 확인 및 통계

```bash
# 설치된 qdisc와 통계 (드롭 카운터 확인)
tc -s qdisc show dev eth0
# Sent: 전송된 패킷/바이트
# dropped: 드롭된 패킷 (대역폭 초과 시 증가)
# overlimits: 한도 초과 횟수

# 클래스별 통계
tc -s class show dev eth0

# 필터 통계
tc -s filter show dev eth0
```

---

## 3. 자주 하는 실수

| 실수 | 올바른 방법 |
|---|---|
| `tc qdisc add`를 두 번 실행 (이미 존재) | `tc qdisc change` 또는 `tc qdisc del dev eth0 root` 후 재추가 |
| ingress 방향 HTB 적용 시도 | ingress는 classful qdisc를 직접 지원 안함. IFB 인터페이스를 통해 우회 |
| netem 제거 없이 테스트 서버 운영 | `tc qdisc del dev eth0 root` 로 반드시 해제. 재부팅 전까지 설정 유지됨 |
| AWS ENI에 단순 root 교체 | ENA 멀티큐 환경에서는 mq qdisc 구조 유지 필요. ingress 방향 또는 IFB 활용 |
| 단위 오기 (mbit vs mbps) | tc에서 `mbit`은 메가비트/초. `kbit`, `gbit`도 동일 규칙. SI 단위 주의 |
| filter flowid를 잘못 지정 | `classid`와 `flowid`는 동일 값이어야 함 (예: classid 1:10 → flowid 1:10) |
| HTB `burst` 값 미설정 | `burst`는 최소 `rate/HZ` 이상으로 설정. 미설정 시 처리량 불안정 |
| 재부팅 후 설정 유지 기대 | tc 설정은 휘발성. `/etc/rc.local`이나 systemd unit으로 재적용 스크립트 등록 필요 |
