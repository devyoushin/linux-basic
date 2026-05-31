# IRQ Affinity & CPU 격리 — 인터럽트 핀닝으로 레이턴시 최소화

## 1. 개요

IRQ(Interrupt Request) affinity는 하드웨어 인터럽트를 처리하는 CPU를 지정하는 기능이다. NIC의 패킷 수신, 디스크 I/O 완료 등 모든 하드웨어 이벤트는 인터럽트를 통해 CPU에 알려진다. 기본 설정에서는 `irqbalance` 데몬이 자동으로 분산하지만, 레이턴시 크리티컬 환경에서는 인터럽트를 전용 CPU에 고정하고, 애플리케이션 CPU는 `isolcpus`로 스케줄러에서 격리해야 안정적인 저레이턴시를 달성할 수 있다.

---

## 2. 설명

### 2.1 IRQ 현황 확인

```bash
# 현재 인터럽트 발생 현황 (CPU별 카운트)
cat /proc/interrupts

# 특정 NIC의 IRQ 번호 확인
cat /proc/interrupts | grep -i eth0
cat /proc/interrupts | grep -i ena    # AWS ENA NIC

# IRQ의 현재 CPU 친화성(비트마스크) 확인
cat /proc/irq/42/smp_affinity          # IRQ 42번의 CPU 친화성
cat /proc/irq/42/smp_affinity_list     # 읽기 쉬운 CPU 목록 형태

# 모든 IRQ의 친화성 한번에 확인
for irq in /proc/irq/*/smp_affinity_list; do
    echo "$irq: $(cat $irq)"
done

# NIC 큐별 IRQ 확인
ls /sys/class/net/eth0/queues/         # 큐 목록
cat /proc/interrupts | grep -i "eth0"  # 큐별 인터럽트 통계
```

### 2.2 smp_affinity 비트마스크 이해

```
CPU 번호:    7  6  5  4  3  2  1  0
비트마스크:  0  0  0  0  1  1  1  1  = 0x0f → CPU 0,1,2,3에서 처리
비트마스크:  1  1  1  1  0  0  0  0  = 0xf0 → CPU 4,5,6,7에서 처리
비트마스크:  0  0  0  0  0  0  0  1  = 0x01 → CPU 0에서만 처리
비트마스크:  1  1  1  1  1  1  1  1  = 0xff → 모든 CPU에서 처리
```

```bash
# IRQ 42를 CPU 0에만 고정 (비트마스크: 0x01)
echo 1 > /proc/irq/42/smp_affinity

# IRQ 42를 CPU 0,1에 고정 (비트마스크: 0x03)
echo 3 > /proc/irq/42/smp_affinity

# smp_affinity_list로 직접 CPU 번호 지정 (더 직관적)
echo 0 > /proc/irq/42/smp_affinity_list       # CPU 0만
echo 0-3 > /proc/irq/42/smp_affinity_list     # CPU 0~3
echo 0,4 > /proc/irq/42/smp_affinity_list     # CPU 0과 4

# 32코어 이상 시스템: 비트마스크를 그룹으로 표현
# CPU 32~63을 1그룹으로: "ffffffff,00000000"
echo "00000001,00000000" > /proc/irq/42/smp_affinity   # CPU 32만
```

### 2.3 irqbalance 관리

```bash
# irqbalance 상태 확인
systemctl status irqbalance

# irqbalance 비활성화 (수동 IRQ 핀닝 시 필수)
systemctl stop irqbalance
systemctl disable irqbalance

# irqbalance 힌트: 특정 IRQ는 건드리지 않도록 설정
# /etc/sysconfig/irqbalance (RHEL/CentOS)
IRQBALANCE_BANNED_CPUS=0x0f    # CPU 0~3은 irqbalance에서 제외
IRQBALANCE_ONESHOT=1           # 한번만 실행하고 데몬 종료 (부팅 초기 균형만 맞춤)
```

**irqbalance 사용/비활성화 비교:**

| 상황 | irqbalance 활성화 | irqbalance 비활성화 |
|------|-----------------|-------------------|
| 범용 서버 | 자동 분산, 편리 | 수동 관리 필요 |
| 고트래픽 NIC | 큐별 분산 자동화 | NIC 큐 수동 핀닝 |
| 레이턴시 민감 | 동적 이동으로 캐시 미스 유발 | 고정으로 캐시 지역성 보장 |

### 2.4 NIC 멀티큐 IRQ 핀닝 스크립트

NIC의 큐 N을 CPU N에 1:1로 매핑하는 패턴이다.

```bash
#!/bin/bash
# nic-irq-pin.sh — NIC 멀티큐 IRQ를 CPU에 1:1 핀닝

NIC="eth0"
CPU_START=0   # 시작 CPU 번호 (NUMA 고려해서 지정)

# irqbalance 중지
systemctl stop irqbalance

# NIC 큐 개수 확인
QUEUE_COUNT=$(ls /sys/class/net/$NIC/queues/ | grep rx | wc -l)
echo "큐 개수: $QUEUE_COUNT"

# 큐별 IRQ 번호 추출 및 CPU 핀닝
QUEUE_NUM=0
for IRQ in $(cat /proc/interrupts | grep "$NIC" | awk '{print $1}' | tr -d ':'); do
    CPU=$((CPU_START + QUEUE_NUM))
    echo $CPU > /proc/irq/$IRQ/smp_affinity_list   # 큐 $QUEUE_NUM → CPU $CPU 핀닝
    echo "IRQ $IRQ (큐 $QUEUE_NUM) → CPU $CPU"
    QUEUE_NUM=$((QUEUE_NUM + 1))
done
```

### 2.5 CPU 격리: isolcpus

`isolcpus`는 커널 부팅 파라미터로, 지정한 CPU를 스케줄러의 일반 태스크 할당에서 완전히 제외한다.

```bash
# 현재 격리된 CPU 확인
cat /sys/devices/system/cpu/isolated

# /etc/default/grub 편집
GRUB_CMDLINE_LINUX_DEFAULT="... isolcpus=4-7"
# CPU 4~7을 격리 — 일반 프로세스는 CPU 0~3에서만 실행됨

# grub 재생성
grub2-mkconfig -o /boot/grub2/grub.cfg   # RHEL/CentOS
update-grub                               # Ubuntu/Debian

# 재부팅 후 확인
cat /sys/devices/system/cpu/isolated     # 격리된 CPU 목록
taskset -c 4 stress --cpu 1 &            # 격리 CPU 4에 테스트 프로세스 배치
```

### 2.6 타이머 인터럽트 제거: nohz_full

`isolcpus`만으로는 주기적인 타이머 인터럽트(HZ)가 여전히 격리 CPU를 방해한다. `nohz_full`은 이 타이머 인터럽트도 제거한다.

```bash
# /etc/default/grub — 완전한 CPU 격리 설정
GRUB_CMDLINE_LINUX_DEFAULT="... isolcpus=4-7 nohz_full=4-7 rcu_nocbs=4-7"

# isolcpus=4-7  : CPU 4~7을 스케줄러에서 격리
# nohz_full=4-7 : 격리 CPU에서 타이머 인터럽트 제거 (단일 프로세스 실행 시)
# rcu_nocbs=4-7 : RCU(Read-Copy-Update) 콜백을 비격리 CPU로 오프로드

# 효과 확인 (재부팅 후)
cat /sys/devices/system/cpu/nohz_full
```

> **주의** `nohz_full`은 해당 CPU에 프로세스가 1개만 실행될 때만 타이머 틱을 완전히 제거한다. 여러 프로세스가 실행되면 일반 모드로 돌아간다.

### 2.7 격리 CPU에 프로세스 고정

```bash
# taskset으로 프로세스를 격리 CPU에 배치
taskset -c 4-7 ./latency-critical-app

# 실행 중인 프로세스를 특정 CPU로 이동
taskset -cp 4-7 <PID>

# numactl과 조합 (NUMA 노드 1의 CPU 4~7로 고정)
numactl --cpunodebind=1 --membind=1 taskset -c 4-7 ./app

# cgroup cpuset으로 컨테이너 단위 고정
mkdir /sys/fs/cgroup/cpuset/realtime
echo 4-7 > /sys/fs/cgroup/cpuset/realtime/cpuset.cpus
echo 0   > /sys/fs/cgroup/cpuset/realtime/cpuset.mems
echo <PID> > /sys/fs/cgroup/cpuset/realtime/tasks
```

### 2.8 완전한 레이턴시 최적화 구성 예시

```
CPU 구성 (16코어 서버):
- CPU 0~3  : 커널, 시스템 서비스, irqbalance 제외 IRQ 처리
- CPU 4~7  : NIC IRQ 전용 (NIC 큐 0~3 각각 핀닝)
- CPU 8~15 : 애플리케이션 전용 (isolcpus + nohz_full)
```

```bash
# /etc/default/grub
GRUB_CMDLINE_LINUX_DEFAULT="isolcpus=8-15 nohz_full=8-15 rcu_nocbs=8-15 intel_idle.max_cstate=1"

# 부팅 후 NIC IRQ 핀닝
for i in 0 1 2 3; do
    CPU=$((4 + i))
    IRQ=$(cat /proc/interrupts | grep "eth0-$i" | awk '{print $1}' | tr -d ':')
    echo $CPU > /proc/irq/$IRQ/smp_affinity_list   # NIC 큐 i → CPU 4+i
done

# 애플리케이션 실행
taskset -c 8-15 ./my-low-latency-app
```

### 2.9 레이턴시 검증

```bash
# cyclictest — 실시간 레이턴시 측정
# (rt-tests 패키지 필요)
cyclictest --mlockall --smp --priority=80 --interval=200 --distance=0

# 격리 CPU에서만 측정
cyclictest -a 8-15 --mlockall --priority=80 --interval=200 -l 100000

# oslat — OS 레이턴시 측정
oslat --cpu-list 8-15 --duration 60

# 결과 해석
# max < 50μs  : 우수 (소프트 실시간)
# max < 200μs : 양호 (일반 저레이턴시)
# max > 1ms   : 개선 필요 (인터럽트/타이머 확인)
```

### 2.10 Kubernetes CPU Manager

```bash
# kubelet 설정 — CPU Manager static 정책
# /var/lib/kubelet/config.yaml
cpuManagerPolicy: static
topologyManagerPolicy: single-numa-node   # NUMA 친화성 보장

# Guaranteed QoS Pod (CPU 전용 할당)
# requests == limits 이어야 함
apiVersion: v1
kind: Pod
spec:
  containers:
  - name: app
    resources:
      requests:
        cpu: "4"          # 정수값이어야 전용 CPU 할당
        memory: "8Gi"
      limits:
        cpu: "4"
        memory: "8Gi"
```

```bash
# 할당된 CPU 확인
cat /var/lib/kubelet/cpu_manager_state

# Pod의 실제 CPU 친화성 확인
PID=$(docker inspect --format '{{.State.Pid}}' <container_id>)
taskset -cp $PID
```

### 2.11 AWS EC2에서의 IRQ 최적화

```bash
# ENA NIC의 IRQ 번호 확인
cat /proc/interrupts | grep -i ena

# ENA 멀티큐 확인
ethtool -l eth0     # 현재/최대 큐 수 확인

# ENA 큐 수를 vCPU 수에 맞게 설정
ethtool -L eth0 combined $(nproc)   # vCPU 수만큼 큐 생성

# ENA IRQ를 CPU에 1:1 핀닝 (c5n, hpc 인스턴스 권장)
# irqbalance 비활성화 후 스크립트로 고정
systemctl stop irqbalance
systemctl disable irqbalance
```

---

## 3. 자주 하는 실수

| 실수 | 올바른 방법 |
|------|------------|
| `irqbalance` 켜놓고 수동 IRQ 핀닝 | `systemctl stop irqbalance` 후 수동 핀닝 — 두 설정 충돌 |
| `isolcpus`만 설정하고 `nohz_full` 누락 | `nohz_full=<cpus>`도 함께 설정해야 타이머 인터럽트 제거 |
| `rcu_nocbs` 없이 `nohz_full` 사용 | RCU 콜백이 격리 CPU에서 실행됨 — `rcu_nocbs`로 오프로드 |
| NIC 큐보다 많은 CPU에 IRQ 핀닝 시도 | 큐 수 = `ethtool -l eth0`로 확인, 큐 수만큼만 핀닝 |
| NUMA 고려 없이 IRQ affinity 설정 | NIC가 연결된 PCIe 슬롯의 NUMA 노드 CPU에 IRQ 핀닝 |
| `taskset`으로 격리 CPU에 배치 안 함 | `isolcpus`는 커널이 자동 배치 안 할 뿐 — `taskset`으로 명시적 배치 |
| Kubernetes에서 CPU Manager 없이 저레이턴시 기대 | `cpuManagerPolicy: static` + Guaranteed QoS Pod |
| 레이턴시 측정 없이 최적화 완료 판단 | `cyclictest`로 실측 — 설정 변경 전후 비교 |
