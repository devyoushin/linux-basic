# RSS/RPS/RFS/XPS — 멀티큐 NIC 튜닝, 네트워크 수신 부하 분산

## 1. 개요

고트래픽 서버에서 NIC의 패킷 수신 처리가 단일 CPU 코어에 집중되면 병목이 발생한다. RSS/RPS/RFS/XPS는 이 수신(및 송신) 부하를 여러 CPU 코어에 분산시키는 메커니즘이다.

- **RSS**: 하드웨어 NIC의 멀티큐로 패킷을 여러 CPU에 분산
- **RPS**: 소프트웨어로 RSS를 구현 (단일 큐 NIC 지원)
- **RFS**: 패킷을 처리하는 애플리케이션의 CPU로 패킷을 보내 캐시 효율 향상
- **XPS**: 송신 큐도 CPU별로 분리해 TX 경합 제거

AWS ENA, Intel i40e, Mellanox mlx5 같은 현대 NIC는 RSS를 기본 지원하며, EC2 인스턴스에서도 vCPU 수만큼 큐가 자동 생성된다.

---

## 2. 설명

### 2.1 RSS (Receive Side Scaling)

RSS는 NIC 하드웨어가 5-tuple(소스 IP, 목적 IP, 소스 포트, 목적 포트, 프로토콜) 해시로 패킷을 여러 RX 큐에 분산하는 기능이다. 각 RX 큐는 특정 CPU의 IRQ에 연결된다.

```
패킷 흐름 A (해시: 0x1a3f) → 큐 0 → CPU 0
패킷 흐름 B (해시: 0x8b72) → 큐 1 → CPU 1
패킷 흐름 C (해시: 0x3c19) → 큐 2 → CPU 2
패킷 흐름 D (해시: 0xf402) → 큐 3 → CPU 3
```

동일 플로우의 패킷은 항상 같은 큐로 전달되므로 순서가 보장된다.

```bash
# NIC 큐 수 확인
ethtool -l eth0
# Pre-set maximums:
#   RX: 32      — 최대 지원 RX 큐 수
#   TX: 32      — 최대 지원 TX 큐 수
#   Combined: 32 — 합쳐진 큐 (RX+TX 공유)
# Current hardware settings:
#   Combined: 4  — 현재 설정된 큐 수

# 큐 수를 CPU 수에 맞게 조정
nproc                                  # vCPU 수 확인
ethtool -L eth0 combined $(nproc)      # 큐 수를 vCPU 수로 설정

# RSS 해시 설정 확인
ethtool -x eth0                        # Indirection Table (큐→CPU 매핑)
ethtool -X eth0 equal $(nproc)         # 균등 분산으로 리셋

# RSS 해시 키 확인
ethtool -x eth0 | grep "RSS hash key"  # 해시 함수 키 (Toeplitz 해시)

# 해시 대상 필드 설정
ethtool -N eth0 rx-flow-hash tcp4 sdfn  # TCP/IPv4: 소스+목적 IP+포트 해시
ethtool -N eth0 rx-flow-hash udp4 sdfn  # UDP도 동일하게
```

### 2.2 RSS 큐와 IRQ affinity 연결

RSS의 효과를 극대화하려면 각 RX 큐의 IRQ를 해당 CPU에 고정해야 한다.

```bash
# 큐별 IRQ 번호 확인
cat /proc/interrupts | grep eth0
# 출력 예시:
# 120:  12345678  PCI-MSI  eth0-TxRx-0  → CPU 0에 배정 필요
# 121:  87654321  PCI-MSI  eth0-TxRx-1  → CPU 1에 배정 필요
# 122:  11223344  PCI-MSI  eth0-TxRx-2  → CPU 2에 배정 필요

# 큐 N → CPU N 1:1 핀닝 스크립트
#!/bin/bash
NIC="eth0"
IRQ_LIST=$(cat /proc/interrupts | grep "${NIC}-TxRx" | awk '{print $1}' | tr -d ':')
CPU=0
for IRQ in $IRQ_LIST; do
    echo $CPU > /proc/irq/$IRQ/smp_affinity_list   # IRQ를 CPU에 핀닝
    echo "IRQ $IRQ → CPU $CPU"
    CPU=$((CPU + 1))
done

# irqbalance 비활성화 (수동 핀닝 시 필수)
systemctl stop irqbalance
systemctl disable irqbalance
```

### 2.3 RPS (Receive Packet Steering)

RPS는 소프트웨어로 RSS를 구현한다. 단일 RX 큐 NIC에서도 패킷을 여러 CPU의 소프트 IRQ로 분산할 수 있다.

```bash
# RPS CPU 마스크 설정 (비트마스크: 모든 CPU 사용)
# 예: 8코어 시스템 → 0xff (CPU 0~7 모두 사용)

# 단일 큐의 RPS를 모든 CPU에 분산
echo ff > /sys/class/net/eth0/queues/rx-0/rps_cpus   # RX 큐 0을 CPU 0~7에 분산

# 멀티 큐 NIC에서 각 큐별 RPS 설정
for QUEUE in /sys/class/net/eth0/queues/rx-*; do
    echo ff > $QUEUE/rps_cpus   # 각 RX 큐를 모든 CPU에 분산
done

# RPS 흐름 테이블 크기 설정 (전역)
echo 32768 > /proc/sys/net/core/rps_sock_flow_entries   # 전체 플로우 테이블 크기

# 큐별 흐름 테이블 크기 (rps_sock_flow_entries / 큐 수)
echo 4096 > /sys/class/net/eth0/queues/rx-0/rps_flow_cnt

# RPS 현황 확인
cat /sys/class/net/eth0/queues/rx-0/rps_cpus   # 현재 RPS CPU 마스크
```

**RPS vs RSS 선택:**

| 항목 | RSS | RPS |
|------|-----|-----|
| 방식 | 하드웨어 | 소프트웨어 |
| 지원 NIC | 멀티큐 NIC 필요 | 모든 NIC |
| CPU 부하 | NIC가 분산 | 소프트 IRQ 처리 CPU 부하 |
| 레이턴시 | 낮음 | RSS보다 약간 높음 |
| 권장 | 멀티큐 NIC | 단일 큐 NIC 또는 VM |

### 2.4 RFS (Receive Flow Steering)

RFS는 RPS의 확장으로, 패킷을 단순히 균등 분산하는 것이 아니라 **해당 플로우를 처리하는 소켓이 있는 CPU**로 패킷을 보낸다. 이로써 소켓 데이터가 L1/L2 캐시에 이미 있는 CPU에서 패킷을 수신해 캐시 미스를 줄인다.

```
RPS 없음:  패킷(플로우A) → CPU 0   / 소켓(플로우A) → CPU 3  (캐시 미스 발생)
RPS만:     패킷(플로우A) → CPU 0   / 소켓(플로우A) → CPU 3  (캐시 미스 발생)
RFS:       패킷(플로우A) → CPU 3   / 소켓(플로우A) → CPU 3  (캐시 히트!)
```

```bash
# RFS 활성화 (rps_sock_flow_entries 설정 필요)
echo 32768 > /proc/sys/net/core/rps_sock_flow_entries

# 큐별 흐름 수 설정 (rps_sock_flow_entries / 큐 수)
QUEUE_COUNT=$(ls /sys/class/net/eth0/queues/ | grep rx | wc -l)
FLOW_PER_QUEUE=$((32768 / QUEUE_COUNT))
for QUEUE in /sys/class/net/eth0/queues/rx-*; do
    echo $FLOW_PER_QUEUE > $QUEUE/rps_flow_cnt   # 큐별 플로우 카운트
done

# RFS는 RPS 설정 위에 자동으로 동작
# rps_cpus 설정이 있고 rps_sock_flow_entries > 0이면 RFS 활성화

# RFS 통계 확인
cat /proc/net/softnet_stat   # 소프트 IRQ 처리 통계 (열: 수신/드롭/조절)
```

### 2.5 XPS (Transmit Packet Steering)

XPS는 송신 시 어떤 TX 큐를 사용할지 CPU별로 매핑한다. CPU별로 전용 TX 큐를 배정하면 큐 잠금 경합이 없어진다.

```bash
# CPU를 TX 큐에 매핑 (CPU N → TX 큐 N)
# 예: CPU 0 → TX 큐 0, CPU 1 → TX 큐 1

# TX 큐 0을 CPU 0에만 배정 (비트마스크: 0x01 = CPU 0)
echo 01 > /sys/class/net/eth0/queues/tx-0/xps_cpus

# TX 큐 1을 CPU 1에만 배정 (비트마스크: 0x02 = CPU 1)
echo 02 > /sys/class/net/eth0/queues/tx-1/xps_cpus

# 자동화 스크립트: CPU N → TX 큐 N 1:1 매핑
TX_QUEUE_NUM=0
for QUEUE in /sys/class/net/eth0/queues/tx-*; do
    MASK=$((1 << TX_QUEUE_NUM))                      # CPU 번호를 비트마스크로 변환
    printf '%x\n' $MASK > $QUEUE/xps_cpus            # XPS 설정
    echo "TX 큐 $TX_QUEUE_NUM → CPU $TX_QUEUE_NUM"
    TX_QUEUE_NUM=$((TX_QUEUE_NUM + 1))
done
```

### 2.6 NUMA를 고려한 큐 배치

멀티소켓 서버에서 NIC와 CPU가 다른 NUMA 노드에 있으면 메모리 접근 레이턴시가 증가한다.

```bash
# NIC가 연결된 NUMA 노드 확인
cat /sys/class/net/eth0/device/numa_node   # 출력: 0 또는 1

# NUMA 노드 0에 연결된 NIC라면, RX/TX 큐를 NUMA 노드 0 CPU에 핀닝
# NUMA 노드 0 CPU 목록 확인
cat /sys/devices/system/node/node0/cpulist   # 예: 0-7,16-23

# NUMA 친화적 IRQ 핀닝
NIC_NUMA=$(cat /sys/class/net/eth0/device/numa_node)
CPU_LIST=$(cat /sys/devices/system/node/node${NIC_NUMA}/cpulist)

for IRQ in $(cat /proc/interrupts | grep eth0 | awk '{print $1}' | tr -d ':'); do
    echo $CPU_LIST > /proc/irq/$IRQ/smp_affinity_list   # NUMA 로컬 CPU에 핀닝
done

# RPS도 NUMA 로컬 CPU로 제한
for QUEUE in /sys/class/net/eth0/queues/rx-*; do
    # NUMA 노드 0 CPU만 사용하는 비트마스크 계산
    echo 00ff > $QUEUE/rps_cpus   # CPU 0~7만 (NUMA 노드 0 예시)
done
```

### 2.7 AWS ENA에서 RSS/RPS 설정

```bash
# ENA NIC 확인
ethtool -i eth0 | grep driver   # ena 드라이버 확인

# ENA 큐 수 확인
ethtool -l eth0
# ENA는 인스턴스의 vCPU 수만큼 큐를 자동 생성

# 큐 수를 vCPU 수로 최대화
CPU_COUNT=$(nproc)
ethtool -L eth0 combined $CPU_COUNT   # 큐 수를 vCPU 수로 설정

# ENA IRQ 확인
cat /proc/interrupts | grep -i ena
# ena-rx-tx-0, ena-rx-tx-1, ... 형식으로 출력

# ENA IRQ를 CPU에 1:1 핀닝
#!/bin/bash
CPU=0
for IRQ in $(cat /proc/interrupts | grep "ena-rx-tx" | awk '{print $1}' | tr -d ':'); do
    echo $CPU > /proc/irq/$IRQ/smp_affinity_list   # IRQ를 해당 CPU에 고정
    echo "ENA IRQ $IRQ → CPU $CPU"
    CPU=$((CPU + 1))
done

# ENA Enhanced Networking 통계
ethtool -S eth0 | grep -E "queue_\d+_(tx|rx)_cnt"   # 큐별 패킷 카운트

# c5n.18xlarge (32 vCPU, 100Gbps ENA)
# 큐 32개 설정 → 각 CPU가 독립 큐로 처리 → 최대 처리량
```

### 2.8 종합 설정 스크립트

```bash
#!/bin/bash
# network-tuning.sh — RSS/RPS/RFS/XPS 종합 최적화 스크립트

NIC="${1:-eth0}"
CPU_COUNT=$(nproc)

echo "=== $NIC 네트워크 수신 최적화 시작 ==="

# 1. irqbalance 비활성화 (수동 핀닝)
systemctl stop irqbalance
systemctl disable irqbalance
echo "irqbalance 비활성화 완료"

# 2. 큐 수를 CPU 수로 최대화
ethtool -L $NIC combined $CPU_COUNT 2>/dev/null || echo "큐 수 조정 불가 (드라이버 제한)"
echo "큐 수: $(ethtool -l $NIC | grep -A1 'Current' | grep Combined | awk '{print $2}')"

# 3. IRQ를 CPU에 1:1 핀닝
CPU=0
for IRQ in $(cat /proc/interrupts | grep "$NIC" | awk '{print $1}' | tr -d ':'); do
    echo $CPU > /proc/irq/$IRQ/smp_affinity_list
    CPU=$(( (CPU + 1) % CPU_COUNT ))
done
echo "IRQ 핀닝 완료"

# 4. RPS 전체 CPU 마스크 계산 및 설정
RPS_MASK=$(python3 -c "print(hex((1 << $CPU_COUNT) - 1)[2:])")
for QUEUE in /sys/class/net/$NIC/queues/rx-*; do
    echo $RPS_MASK > $QUEUE/rps_cpus
done
echo "RPS 마스크 설정: $RPS_MASK"

# 5. RFS 활성화
echo 32768 > /proc/sys/net/core/rps_sock_flow_entries
QUEUE_COUNT=$(ls /sys/class/net/$NIC/queues/ | grep "^rx" | wc -l)
FLOW_PER_Q=$((32768 / QUEUE_COUNT))
for QUEUE in /sys/class/net/$NIC/queues/rx-*; do
    echo $FLOW_PER_Q > $QUEUE/rps_flow_cnt
done
echo "RFS 활성화: 큐당 $FLOW_PER_Q 플로우"

# 6. XPS 설정 (CPU N → TX 큐 N)
TX_NUM=0
for QUEUE in /sys/class/net/$NIC/queues/tx-*; do
    MASK=$((1 << (TX_NUM % CPU_COUNT)))
    printf '%x' $MASK > $QUEUE/xps_cpus
    TX_NUM=$((TX_NUM + 1))
done
echo "XPS 설정 완료"

echo "=== 최적화 완료 ==="
```

### 2.9 성능 모니터링

```bash
# 큐별 수신 패킷 분포 확인 (RSS 균등 분산 여부)
ethtool -S eth0 | grep -E "rx_queue_[0-9]+_packets"
# 각 큐의 패킷 수가 균등한지 확인 — 편중 시 IRQ 핀닝 재확인

# 소프트 IRQ 처리 통계
cat /proc/net/softnet_stat
# 컬럼: total dropped squeezed 0 0 0 0 0 0 time_squeeze cpu_collision
# squeezed: 타임슬롯 부족으로 처리 못한 패킷 (net.core.netdev_budget 증가 필요)

# CPU별 소프트 IRQ 부하
sar -I ALL 1 5       # 1초 간격, 5회 IRQ 통계
mpstat -P ALL 1      # CPU별 소프트 IRQ (softirq %) 확인

# NIC 큐별 통계
watch -n1 'ethtool -S eth0 | grep -E "(rx|tx)_queue"'

# RFS 효과 측정 (캐시 미스율)
perf stat -e cache-misses,cache-references -p <app_pid> sleep 10
# RFS 전후 cache-misses 비율 비교

# 네트워크 처리량 실시간 모니터링
sar -n DEV 1         # 1초 간격 인터페이스 통계
nload eth0           # 실시간 대역폭 그래프
```

### 2.10 ring buffer 튜닝

```bash
# 현재 ring buffer 크기 확인
ethtool -g eth0
# Pre-set maximums:  RX: 4096  TX: 4096
# Current hardware settings: RX: 256  TX: 256

# ring buffer 크기 증가 (패킷 드롭 방지)
ethtool -G eth0 rx 4096 tx 4096   # 최대값으로 설정

# 패킷 드롭 확인
ethtool -S eth0 | grep -i "drop\|miss\|error"
ip -s link show eth0 | grep RX    # RX 에러/드롭 확인

# 커널 수신 버퍼 크기 증가
sysctl -w net.core.rmem_max=134217728       # 소켓 수신 버퍼 최대 128MB
sysctl -w net.core.rmem_default=67108864   # 기본값 64MB
sysctl -w net.core.netdev_budget=1200      # 소프트 IRQ 한 번에 처리할 패킷 수 증가
sysctl -w net.core.netdev_max_backlog=30000 # NIC 큐 백로그 크기 증가
```

---

## 3. 자주 하는 실수

| 실수 | 올바른 방법 |
|------|------------|
| irqbalance 켜놓고 수동 IRQ 핀닝 | `systemctl stop irqbalance` 후 수동 핀닝 — 두 설정 충돌 |
| 큐 수 증가 없이 IRQ 핀닝만 | `ethtool -L eth0 combined $(nproc)`으로 큐 수 먼저 최대화 |
| RFS 없이 RPS만 설정 | `rps_sock_flow_entries`와 `rps_flow_cnt` 모두 설정해야 RFS 활성화 |
| NUMA 무시하고 IRQ를 다른 노드 CPU에 핀닝 | NIC NUMA 노드(`/sys/class/net/eth0/device/numa_node`) 확인 후 로컬 CPU에 핀닝 |
| ethtool -S 통계 없이 RSS 균등 분산 가정 | 큐별 패킷 수 확인 — 특정 큐에 집중 시 해시 키 변경 또는 큐 수 재조정 |
| XPS 설정 안 해서 TX 큐 잠금 경합 | CPU별 전용 TX 큐 배정으로 mutex 경합 제거 |
| ring buffer 기본값 유지 | 고트래픽 시 `ethtool -G eth0 rx 4096`으로 드롭 방지 |
| VM/컨테이너 환경에서 RSS 기대 | 가상 NIC는 RSS 미지원 — RPS/RFS로 소프트웨어 분산 |
