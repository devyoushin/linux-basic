# Linux 프로세스 스케줄러

## 1. 개요

Linux 스케줄러는 CPU 시간을 어떤 프로세스/스레드에 얼마나 할당할지 결정한다. 기본 스케줄러인 CFS(Completely Fair Scheduler)는 실행 가능한 모든 태스크에 공정한 CPU 시간을 보장하며, RT(Real-Time) 스케줄러는 레이턴시가 중요한 작업에 CPU를 우선 제공한다. 데이터베이스, 스트리밍 서버, 레이턴시 민감 서비스 튜닝 시 반드시 이해해야 한다.

---

## 2. 설명

### 2.1 스케줄러 클래스 계층

Linux는 여러 스케줄러 클래스를 우선순위 순으로 적용한다.

```
우선순위 높음
  │  stop_sched_class    — 마이그레이션, 스케줄러 내부용
  │  dl_sched_class      — SCHED_DEADLINE (EDF 알고리즘)
  │  rt_sched_class      — SCHED_FIFO / SCHED_RR
  │  fair_sched_class    — SCHED_OTHER / SCHED_BATCH (CFS)
  ▼  idle_sched_class    — SCHED_IDLE
우선순위 낮음
```

상위 클래스에 실행 가능한 태스크가 있으면 하위 클래스는 CPU를 받지 못한다.

### 2.2 CFS (Completely Fair Scheduler)

대부분의 프로세스가 사용하는 기본 스케줄러. 각 태스크의 `vruntime`(가상 실행 시간)을 Red-Black 트리로 관리하며, 가장 작은 `vruntime`을 가진 태스크를 다음에 실행한다.

```
vruntime 증가 속도 = 실제 실행 시간 × (nice 0 weight / 태스크 weight)
→ nice가 낮을수록(우선순위 높을수록) vruntime이 느리게 증가
→ 같은 시간 안에 더 많이 실행됨
```

```bash
# 프로세스 스케줄링 정책 확인
chrt -p <PID>
# pid 1234's current scheduling policy: SCHED_OTHER
# pid 1234's current scheduling priority: 0

# nice 값 확인 (-20 ~ 19, 낮을수록 우선순위 높음)
ps -eo pid,ni,comm | grep myapp

# 실행 중인 프로세스의 nice 변경
renice -n -5 -p <PID>      # 우선순위 높임 (root 필요)
renice -n 10 -p <PID>      # 우선순위 낮춤

# 처음 실행 시 nice 지정
nice -n 15 backup.sh       # 낮은 우선순위로 실행
```

### 2.3 CFS 핵심 튜닝 파라미터

```bash
# 스케줄링 레이턴시 (모든 태스크가 한 번씩 실행되는 주기, 기본 6ms)
cat /proc/sys/kernel/sched_latency_ns
# 6000000 (6ms)

# 태스크당 최소 실행 시간 (기본 0.75ms, 이보다 짧게 선점 안 됨)
cat /proc/sys/kernel/sched_min_granularity_ns
# 750000 (0.75ms)

# 인터렉티브 태스크 깨어날 때 선점 허용 여부 (기본 1)
cat /proc/sys/kernel/sched_wakeup_granularity_ns
# 1000000 (1ms)

# 레이턴시 우선(낮춤) vs 처리량 우선(높임) 튜닝 예시
# 인터랙티브/레이턴시 민감 서비스
sysctl -w kernel.sched_latency_ns=4000000
sysctl -w kernel.sched_min_granularity_ns=500000

# 배치/처리량 중심 서비스 (기본값이 적절하거나 약간 높임)
sysctl -w kernel.sched_latency_ns=24000000
sysctl -w kernel.sched_min_granularity_ns=3000000
```

### 2.4 RT 스케줄러 (Real-Time)

```bash
# SCHED_FIFO: 같은 우선순위에서 먼저 온 태스크가 끝날 때까지 실행
# SCHED_RR: 같은 우선순위에서 타임슬라이스 기반 라운드로빈

# RT 우선순위 1~99 (높을수록 먼저 실행)
chrt -f 50 myapp         # SCHED_FIFO, 우선순위 50으로 실행
chrt -r 50 myapp         # SCHED_RR, 우선순위 50으로 실행

# 실행 중인 프로세스를 RT로 변경
chrt -f -p 80 <PID>

# RT 스로틀링 (RT 태스크가 CPU를 독점하지 못하게)
cat /proc/sys/kernel/sched_rt_period_us   # 1,000,000 (1초)
cat /proc/sys/kernel/sched_rt_runtime_us  # 950,000  (0.95초, 95% 제한)

# RT 스로틀링 비활성화 (레이턴시 크리티컬 환경 — 주의)
sysctl -w kernel.sched_rt_runtime_us=-1
```

> **주의**: `sched_rt_runtime_us=-1`은 RT 태스크가 CPU를 100% 점유할 수 있어 다른 태스크가 굶을 수 있다. 전용 CPU를 격리한 경우에만 사용한다.

### 2.5 SCHED_DEADLINE

주기적인 실시간 작업(미디어 스트리밍, 오디오 처리)을 위한 EDF(Earliest Deadline First) 기반 스케줄러.

```bash
# deadline 파라미터: runtime(최대 실행시간), deadline(마감기한), period(주기) — 단위 나노초
chrt -d --sched-runtime 5000000 --sched-deadline 10000000 --sched-period 10000000 myapp
# 10ms 주기마다 최대 5ms 실행, 10ms 안에 완료

# 확인
chrt -p <PID>
# scheduling policy: SCHED_DEADLINE
```

### 2.6 CPU 친화성 (Affinity)

특정 태스크를 특정 CPU 코어에 고정하면 캐시 지역성(cache locality)을 높이고 NUMA 크로스-노드 접근을 줄일 수 있다.

```bash
# 프로세스를 CPU 0~3에 고정
taskset -cp 0-3 <PID>

# 실행 시 CPU 지정
taskset -c 2,3 myapp

# CPU 마스크 확인 (비트마스크, 0xf = CPU 0~3)
taskset -p <PID>
# pid 1234's current affinity mask: f

# 스레드 단위 affinity 설정 (pthread_setaffinity_np 또는)
for tid in $(ls /proc/<PID>/task/); do
  taskset -cp 0-3 $tid
done

# numactl과 결합 (NUMA 노드 + CPU 친화성)
numactl --cpunodebind=0 --membind=0 myapp
```

### 2.7 프로세스별 스케줄러 통계

```bash
# /proc/<PID>/schedstat — 실행 시간, 대기 시간
cat /proc/<PID>/schedstat
# <CPU에서 실행한 ns>  <런큐에서 대기한 ns>  <실행된 타임슬라이스 수>

# /proc/<PID>/sched — 상세 CFS 정보
cat /proc/<PID>/sched
# se.vruntime                         :       1234567.890
# se.sum_exec_runtime                 :      56789.123
# se.nr_migrations                    :            42

# 전체 CPU 스케줄러 통계
cat /proc/schedstat
# cpu0 0 0 0 0 0 0 <run_ns> <wait_ns> <timeslices>

# perf로 스케줄 레이턴시 측정
perf sched record -a sleep 5
perf sched latency | head -30
# 최대/평균 스케줄 레이턴시, 태스크별 통계 출력
```

### 2.8 runqueue 모니터링

```bash
# 런큐 길이 (CPU별 대기 태스크 수)
sar -q 1 5
# runq-sz: 런큐 길이, CPU 수보다 지속적으로 크면 CPU 포화 상태

# vmstat의 r 컬럼
vmstat 1
# r: 실행 중 + 실행 대기 중인 프로세스 수

# 실시간 CPU 스케줄 상태
cat /proc/sched_debug | head -60
# Sched Debug Version: v0.11, 6.x.x
# ktime: 1234567890.000000
# 각 CPU의 CFS 런큐 상태 출력
```

### 2.9 cgroup을 통한 CPU 할당

```bash
# cgroup v2: CPU 비율 설정 (weight 기반, 기본 100)
echo 200 > /sys/fs/cgroup/myapp/cpu.weight   # 다른 그룹의 2배 CPU 획득

# CPU 대역폭 제한 (quota/period)
# period 100ms 중 50ms만 사용 허용 (50% 제한)
echo "50000 100000" > /sys/fs/cgroup/myapp/cpu.max

# systemd 유닛으로 설정
# CPUWeight=200       (상대적 가중치)
# CPUQuota=50%        (최대 CPU 사용률)
```

### 2.10 Ansible로 스케줄러 튜닝 적용

```yaml
- name: Tune CFS scheduler for low-latency workload
  ansible.posix.sysctl:
    name: "{{ item.key }}"
    value: "{{ item.value }}"
    sysctl_file: /etc/sysctl.d/99-scheduler.conf
    reload: yes
  loop:
    - { key: kernel.sched_latency_ns, value: 4000000 }
    - { key: kernel.sched_min_granularity_ns, value: 500000 }
    - { key: kernel.sched_wakeup_granularity_ns, value: 500000 }
    - { key: kernel.sched_migration_cost_ns, value: 5000000 }
```

---

## 3. 자주 하는 실수

| 실수 | 올바른 방법 |
|------|------------|
| RT 우선순위를 높게 설정하고 스로틀링 비활성화 → 시스템 프리즈 | RT 스로틀링 유지, 격리된 CPU에서만 비활성화 |
| `nice -n -20`만으로 레이턴시 개선 기대 | 레이턴시 민감 작업은 SCHED_FIFO/RR 또는 SCHED_DEADLINE 사용 |
| taskset으로 CPU 고정 후 NUMA 토폴로지 무시 | `numactl`과 함께 사용해 메모리도 같은 NUMA 노드에 묶기 |
| sched_latency_ns를 과도하게 낮춤 → 컨텍스트 스위치 폭증 | 최소 2ms 이상 유지, `perf sched latency`로 효과 측정 |
| cgroup CPU 제한(cpu.max) 설정 후 OOM 오해 | CPU 제한은 CPU 사용량만 제한, 메모리는 별도 `memory.max` 설정 |
| DB/JVM을 SCHED_FIFO로 설정 → GC 일시정지 중 CPU 점유 | JVM은 CFS + `taskset` + NUMA 바인딩이 더 적합 |

---

## 4. 성능 분석 예시

```bash
# 스케줄러 레이턴시 분포 측정 (어떤 태스크가 CPU를 오래 기다리는가)
perf sched record -a -- sleep 10
perf sched latency --sort max | head -20

# 특정 프로세스의 컨텍스트 스위치 수 추적
pidstat -w -p <PID> 1 10
# cswch/s: 자발적(I/O 대기 등), nvcswch/s: 비자발적(선점됨) 컨텍스트 스위치

# CPU 마이그레이션 횟수 확인 (NUMA 영향 가늠)
cat /proc/<PID>/sched | grep migrations
# se.nr_migrations: 높으면 CPU 간 이동 多 → taskset으로 고정 검토

# ftrace로 스케줄러 이벤트 추적
echo 1 > /sys/kernel/debug/tracing/events/sched/sched_switch/enable
cat /sys/kernel/debug/tracing/trace | head -50
echo 0 > /sys/kernel/debug/tracing/events/sched/sched_switch/enable
```
