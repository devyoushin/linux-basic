# perf - 성능 프로파일링 및 플레임 그래프

## 1. 개요

`perf`는 Linux 커널에 내장된 성능 분석 도구로, CPU 하드웨어 카운터부터 커널 트레이스포인트까지
다양한 이벤트를 수집한다. 단순한 CPU 사용률 이상으로 **어떤 함수가 병목인지**, **캐시 미스가 얼마나
발생하는지**, **스케줄링 지연이 어디서 생기는지** 를 정확히 측정한다.
플레임 그래프(Flame Graph)와 결합하면 복잡한 프로파일링 데이터를 직관적으로 시각화할 수 있다.

---

## 2. 설명

### 2-1. perf 아키텍처

```
┌─────────────────────────────────────────────────────────┐
│                      perf tool                          │
│   perf stat │ perf top │ perf record │ perf report      │
└──────────────────────────┬──────────────────────────────┘
                           │ perf_event_open() syscall
┌──────────────────────────▼──────────────────────────────┐
│                    Kernel Subsystem                     │
│                                                         │
│  ┌─────────────┐  ┌──────────────┐  ┌───────────────┐  │
│  │   Hardware  │  │   Software   │  │  Tracepoints  │  │
│  │   Events    │  │   Events     │  │               │  │
│  │ (PMU/PMC)  │  │ (page-fault, │  │ (sched, irq,  │  │
│  │ cycles     │  │  context-sw) │  │  syscall, ...)│  │
│  │ cache-miss │  │              │  │               │  │
│  │ branch-mis │  │              │  │               │  │
│  └──────┬──────┘  └──────┬───────┘  └───────┬───────┘  │
│         └────────────────┴──────────────────┘          │
│                          │                              │
│              perf ring buffer (per-CPU)                 │
└──────────────────────────┬──────────────────────────────┘
                           │ mmap
                    perf.data 파일
```

**이벤트 유형**

| 유형 | 설명 | 예시 |
|---|---|---|
| Hardware Events | CPU PMU(Performance Monitoring Unit) 카운터 | `cycles`, `instructions`, `cache-misses` |
| Software Events | 커널 소프트웨어 카운터 | `context-switches`, `page-faults`, `cpu-migrations` |
| Tracepoints | 커널에 정적으로 삽입된 추적 지점 | `sched:sched_switch`, `net:netif_rx` |
| Dynamic Probes | 동적으로 삽입하는 kprobe/uprobe | 임의 함수에 probe 추가 |

### 2-2. perf stat - CPU 카운터 통계

```bash
# 기본 통계 수집 (명령어 실행 후 요약)
perf stat ls /tmp

# 출력 예시 해석:
# Performance counter stats for 'ls /tmp':
#
#          1.23 msec task-clock    #  0.756 CPUs utilized
#             2      context-switches  #  1.626 K/sec
#             0      cpu-migrations    #  0.000 /sec
#           127      page-faults       #  103.252 K/sec
#     3,456,789      cycles            #  2.809 GHz
#     2,345,678      instructions      #  0.68  insn per cycle  ← IPC 낮으면 파이프라인 비효율
#       456,789      branches          #  371.374 M/sec
#        12,345      branch-misses     #  2.70% of all branches ← 분기 예측 실패율

# 특정 이벤트 지정
perf stat -e cycles,instructions,cache-references,cache-misses myapp

# 반복 실행으로 편차 확인 (-r: repeat count)
perf stat -r 5 myapp

# 실행 중인 프로세스에 attach
perf stat -p $(pgrep myapp) sleep 10

# 모든 CPU에 대해 시스템 전체 통계 (-a: all CPUs)
perf stat -a sleep 5

# 캐시 미스 비율 분석
perf stat -e L1-dcache-loads,L1-dcache-load-misses,LLC-loads,LLC-load-misses myapp
# LLC-load-misses 비율 높으면 → 메모리 접근 패턴 최적화 필요 (캐시 지역성)
```

### 2-3. perf top - 실시간 프로파일링

```bash
# 실시간 CPU 사용 함수 순위 (htop의 perf 버전)
perf top

# 특정 프로세스만
perf top -p $(pgrep myapp)

# 커널 심볼 포함 (kallsyms 필요)
perf top --call-graph dwarf

# 출력 예시:
# Overhead  Shared Object       Symbol
# --------  ------------------  ------------------
#   34.12%  myapp               [.] process_request    ← 가장 많은 CPU 소비
#   18.45%  libc.so.6           [.] malloc
#    9.23%  [kernel]            [k] copy_user_generic_string
#    7.11%  myapp               [.] hash_lookup
```

### 2-4. perf record + perf report - 심층 분석

```bash
# 샘플링 주기 99Hz로 30초 기록 (-F: frequency, -g: call graph)
perf record -F 99 -g -p $(pgrep myapp) -- sleep 30

# 전체 시스템 프로파일링
perf record -F 99 -ag -- sleep 30

# perf.data 분석
perf report

# TUI 없이 텍스트 출력
perf report --stdio

# 특정 심볼의 어셈블리 + 소스 보기
perf annotate --stdio -s process_request

# 이벤트 개별 출력 (raw trace)
perf script | head -50
# 출력 형식: process PID [CPU] timestamp event: ip sym+offset
# myapp 1234 [002] 12345.678901: cycles: ffffffff8119c5a0 native_write_msr+0x0
```

### 2-5. 플레임 그래프 생성

```
호출 스택 샘플링 → 접기(folding) → SVG 렌더링

perf record → perf script → stackcollapse-perf.pl → flamegraph.pl → flame.svg
```

```bash
# 1단계: FlameGraph 도구 설치
git clone https://github.com/brendangregg/FlameGraph /opt/FlameGraph

# 2단계: 샘플 수집 (call graph 필수: --call-graph dwarf 또는 fp)
# dwarf: 디버그 정보 기반 (정확하지만 오버헤드 높음)
# fp: 프레임 포인터 기반 (빠르지만 -fomit-frame-pointer 컴파일 시 불완전)
perf record -F 99 --call-graph dwarf -p $(pgrep myapp) -- sleep 30

# 3단계: 스택 추출
perf script > /tmp/perf.out

# 4단계: 스택 접기
/opt/FlameGraph/stackcollapse-perf.pl /tmp/perf.out > /tmp/perf.folded

# 5단계: SVG 생성
/opt/FlameGraph/flamegraph.pl /tmp/perf.folded > /tmp/flame.svg

# 브라우저에서 열기
open /tmp/flame.svg   # macOS
xdg-open /tmp/flame.svg  # Linux GUI

# 한 줄로 축약
perf record -F 99 --call-graph dwarf -p $(pgrep myapp) -- sleep 30 && \
  perf script | /opt/FlameGraph/stackcollapse-perf.pl | \
  /opt/FlameGraph/flamegraph.pl > /tmp/flame.svg
```

**플레임 그래프 읽는 법**

```
▲ Y축: 호출 스택 깊이 (아래가 루트, 위가 리프)
─ X축: 샘플 수 비율 (넓을수록 CPU 시간 많이 사용)
색상: 랜덤 (의미 없음, 구분용)

넓은 평평한 상단 → 해당 함수가 CPU를 많이 소비 → 최적화 대상
좁고 높은 탑    → 깊은 호출 체인, 실제 작업은 리프에서
```

### 2-6. CPU 병목 vs I/O 병목 구분

```bash
# CPU 병목 특징: IPC 높음, CPU utilization 높음
perf stat myapp 2>&1 | grep 'insn per cycle'
# instructions per cycle > 1.0 → CPU 효율적 활용
# instructions per cycle < 0.5 → 메모리 대기 (I/O 병목 가능성)

# I/O 병목 확인: off-CPU 분석
# 프로세스가 sleep(wait) 중인 시간 측정
perf record -e sched:sched_stat_sleep,sched:sched_switch \
  -p $(pgrep myapp) -- sleep 30

# context switch 빈도로 판단
perf stat -e context-switches -p $(pgrep myapp) sleep 10
# context-switches 높고 CPU 낮음 → I/O 대기 또는 락 경합

# 실전 구분 방법:
# top에서 %CPU < 10%인데 응답 느림 → I/O 병목
# top에서 %CPU ~ 100%인데 처리량 낮음 → CPU 병목 (또는 단일 스레드 병목)
```

### 2-7. perf sched - 스케줄링 지연 분석

```bash
# 스케줄링 이벤트 기록
perf sched record -- sleep 10

# 레이턴시 분석 (작업이 실행 대기한 시간)
perf sched latency

# 출력 예시:
# Task                  |   Runtime ms  | Switches | Average delay ms | Maximum delay ms |
# myapp:1234            |    2345.678   |    5678  |          0.123   |         12.345   |
# ←── 최대 지연 12ms → 스케줄링 레이턴시 문제

# 타임라인 출력
perf sched timehist | head -30

# 전체 스케줄링 통계
perf sched stats
```

### 2-8. perf mem - 메모리 접근 패턴

```bash
# 메모리 접근 샘플링 (Intel PEBS 기능 필요)
perf mem record myapp

# 메모리 접근 분석 (로드/스토어 레이턴시)
perf mem report

# NUMA 접근 패턴 (멀티소켓 시스템)
perf stat -e numa-node-loads,numa-node-stores myapp
# numa-node-stores 높으면 → NUMA 비효율 접근 패턴
```

### 2-9. AWS EC2에서 perf 사용 시 주의사항

```
┌─────────────────────────────────────────────────────┐
│                  AWS EC2 제약사항                    │
│                                                     │
│  ✗ 하이퍼바이저 가상화 환경 (Xen/KVM/Nitro)          │
│    → Hardware PMU 카운터 접근 제한                   │
│                                                     │
│  Nitro 기반 인스턴스 (C5, M5, R5 등):               │
│    - hardware events: 일부 지원 (cycles, instructions)│
│    - cache-misses: 지원 안 될 수 있음                │
│                                                     │
│  Xen 기반 구형 인스턴스:                            │
│    - hardware events: 거의 불가                     │
│    - software events: 정상 동작                     │
│    - tracepoints: 정상 동작                         │
└─────────────────────────────────────────────────────┘
```

```bash
# EC2에서 사용 가능한 이벤트 확인
perf list | grep -E 'hardware|software|tracepoint'

# EC2에서 안전하게 사용 가능한 명령
perf stat -e task-clock,context-switches,page-faults myapp  # software events
perf record -e cpu-clock -g myapp   # software clock 기반 샘플링

# kernel.perf_event_paranoid 설정 (낮을수록 더 많은 접근 허용)
cat /proc/sys/kernel/perf_event_paranoid
# -1: 제한 없음 (root 권한 상당)
#  0: 커널 프로파일링 허용
#  1: user-space 프로파일링 허용 (기본값, 대부분 배포판)
#  2: 오직 root만 허용

# EC2 Amazon Linux 2에서 설정 변경
sudo sysctl -w kernel.perf_event_paranoid=1

# perf 설치 (Amazon Linux 2)
sudo yum install -y perf

# perf 설치 (Ubuntu)
sudo apt-get install -y linux-tools-$(uname -r) linux-tools-generic

# 커널 심볼 없을 때 (kallsyms)
echo 0 | sudo tee /proc/sys/kernel/kptr_restrict
```

### 2-10. Dockerfile에서 perf 디버깅 환경 구성

```dockerfile
# Dockerfile.debug - 프로파일링 가능한 디버그 이미지
FROM ubuntu:22.04

RUN apt-get update && apt-get install -y \
    linux-tools-generic \
    linux-tools-$(uname -r 2>/dev/null || echo "generic") \
    git \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# FlameGraph 도구 설치
RUN git clone https://github.com/brendangregg/FlameGraph /opt/FlameGraph && \
    ln -s /opt/FlameGraph/flamegraph.pl /usr/local/bin/flamegraph.pl && \
    ln -s /opt/FlameGraph/stackcollapse-perf.pl /usr/local/bin/stackcollapse-perf.pl
```

```bash
# 컨테이너 실행 시 perf 접근 허용
docker run --privileged \
  --cap-add=SYS_ADMIN \
  -v /proc:/proc \
  -v /sys:/sys \
  debug-image bash
```

---

## 3. 자주 하는 실수

| 실수 | 증상 / 문제 | 올바른 방법 |
|---|---|---|
| `--call-graph` 옵션 없이 perf record | 플레임 그래프에 스택 정보 없음, 함수명만 표시 | `-g` 또는 `--call-graph dwarf` 반드시 추가 |
| 디버그 심볼 없이 perf report | 함수명 대신 16진수 주소만 표시 | `debuginfo` 패키지 설치 또는 `-fno-omit-frame-pointer`로 컴파일 |
| EC2에서 hardware events 사용 | `WARNING: perf not supported` 또는 0 값 출력 | `cpu-clock` 등 software events로 대체 |
| perf.data 파일 다른 시스템으로 복사 후 분석 | 심볼 해석 불가 | `perf archive` 로 심볼 패키징 후 이동 |
| 짧은 프로그램에 perf record | 샘플 수 부족으로 의미 없는 결과 | 최소 10초 이상 샘플링, 또는 `-F 999` 로 고빈도 샘플링 |
| `perf top`으로 커널 함수 분석 시 `[unknown]` | `kptr_restrict` 설정으로 커널 포인터 숨김 | `echo 0 > /proc/sys/kernel/kptr_restrict` |
| 멀티코어에서 특정 CPU만 프로파일링 | 전체 병목 놓침 | `-a` 옵션으로 전체 CPU 프로파일링, `-C 0,1,2` 로 특정 CPU 지정 |
| IPC 값만 보고 성능 판단 | 메모리 대기 시간은 IPC에 반영 안 됨 | `cache-misses`, `LLC-load-misses` 함께 분석 |
