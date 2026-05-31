# Linux ftrace — 커널 함수 트레이싱

## 1. 개요

ftrace(Function Tracer)는 커널에 내장된 저수준 트레이싱 프레임워크다. 커널 함수 호출 흐름, 인터럽트 레이턴시, 스케줄러 동작, 블록 I/O 지연을 코드 수정 없이 추적할 수 있다. `perf`와 `eBPF`가 ftrace 위에서 동작하는 경우가 많으며, 커널 드라이버 디버깅이나 설명하기 어려운 레이턴시 스파이크 원인 파악에 필수다.

---

## 2. 설명

### 2.1 ftrace 기본 구조

```
/sys/kernel/debug/tracing/        # ftrace 제어 인터페이스 (debugfs)
├── available_tracers              # 사용 가능한 트레이서 목록
├── current_tracer                 # 현재 활성 트레이서
├── tracing_on                     # 트레이싱 활성화(1)/비활성화(0)
├── trace                          # 트레이스 결과 읽기
├── trace_pipe                     # 실시간 스트림 읽기
├── set_ftrace_filter              # 추적할 함수 필터
├── set_ftrace_notrace             # 제외할 함수 필터
├── set_graph_function             # function_graph 진입점 설정
├── events/                        # 정적 트레이스포인트 (tracepoint)
│   ├── sched/
│   ├── block/
│   ├── net/
│   └── ...
├── trace_options                  # 출력 형식 옵션
└── buffer_size_kb                 # 링 버퍼 크기
```

```bash
# debugfs가 마운트되지 않은 경우
mount -t debugfs nodev /sys/kernel/debug

# tracefs를 별도 마운트 (커널 4.1+)
mount -t tracefs nodev /sys/kernel/tracing
```

### 2.2 사용 가능한 트레이서

```bash
cat /sys/kernel/debug/tracing/available_tracers
# function        — 모든 커널 함수 호출 기록
# function_graph  — 함수 진입/반환 + 실행 시간 트리 표시
# blk             — 블록 I/O 이벤트 (blktrace)
# mmiotrace       — MMIO 추적 (드라이버 개발용)
# nop             — 트레이서 없음 (트레이스포인트만 사용 시)
# hwlat           — 하드웨어 인터럽트 레이턴시 측정
# irqsoff         — IRQ 비활성화 구간 최대 레이턴시
# preemptoff      — 선점 비활성화 구간 최대 레이턴시
# preemptirqsoff  — IRQ+선점 비활성화 합산 레이턴시
# wakeup          — RT 태스크 깨어나기까지 걸린 시간
# wakeup_rt       — RT 태스크 전용 wake-up 레이턴시
```

### 2.3 function 트레이서

```bash
# 특정 함수 추적 (tcp_sendmsg 호출 흐름)
echo function > /sys/kernel/debug/tracing/current_tracer
echo tcp_sendmsg > /sys/kernel/debug/tracing/set_ftrace_filter
echo 1 > /sys/kernel/debug/tracing/tracing_on

# 애플리케이션 실행 후 결과 확인
cat /sys/kernel/debug/tracing/trace | head -30

# 트레이싱 중지 및 초기화
echo 0 > /sys/kernel/debug/tracing/tracing_on
echo nop > /sys/kernel/debug/tracing/current_tracer
echo > /sys/kernel/debug/tracing/set_ftrace_filter
echo > /sys/kernel/debug/tracing/trace  # 버퍼 초기화
```

결과 예시:
```
# tracer: function
#         TASK    PID  CPU#  IRQS-OFF NEED-RESCHED  HARDIRQ/SOFTIRQ  PREEMPT-DEPTH
#            |      |     |        |           |                |             |
          curl-1234  [002]  d..1     12.345678: tcp_sendmsg <-sock_sendmsg
```

### 2.4 function_graph 트레이서

함수 호출 트리와 각 함수의 실행 시간을 시각적으로 보여준다.

```bash
echo function_graph > /sys/kernel/debug/tracing/current_tracer

# 진입점 함수 지정 (하위 호출 트리 전체 추적)
echo do_sys_open > /sys/kernel/debug/tracing/set_graph_function

# 특정 PID만 추적
echo <PID> > /sys/kernel/debug/tracing/set_ftrace_pid

echo 1 > /sys/kernel/debug/tracing/tracing_on
# ... 대상 동작 수행 ...
echo 0 > /sys/kernel/debug/tracing/tracing_on
cat /sys/kernel/debug/tracing/trace
```

결과 예시:
```
 # tracer: function_graph
 #
 # TIME        CPU  DURATION                  FUNCTION CALLS
 # |           |   |   |                       |   |   |   |
  1234.567890  [0]  |            do_sys_open() {
  1234.567891  [0]  |              getname() {
  1234.567892  [0]  0.234 us    |    kmem_cache_alloc();
  1234.567893  [0]  1.456 us    |  }
  1234.567894  [0]  |              vfs_open() {
  1234.567895  [0]  2.100 us    |    ...
```

### 2.5 레이턴시 트레이서

인터럽트/선점 비활성화 구간에서 발생하는 레이턴시 스파이크를 찾는다.

```bash
# IRQ 비활성화 최대 레이턴시 측정
echo irqsoff > /sys/kernel/debug/tracing/current_tracer
echo 1 > /sys/kernel/debug/tracing/tracing_on
sleep 5
echo 0 > /sys/kernel/debug/tracing/tracing_on
cat /sys/kernel/debug/tracing/trace
# 최대 레이턴시 구간의 함수 콜스택 출력

# RT 태스크 wake-up 레이턴시
echo wakeup_rt > /sys/kernel/debug/tracing/current_tracer
echo 1 > /sys/kernel/debug/tracing/tracing_on
# RT 태스크 실행 후
cat /sys/kernel/debug/tracing/trace
# "마감 레이턴시: 125 us" 등의 정보 포함
```

### 2.6 트레이스포인트 (정적 이벤트)

커널 코드에 사전 삽입된 정적 추적 지점. 동적 kprobe보다 오버헤드가 낮다.

```bash
# 사용 가능한 이벤트 목록
cat /sys/kernel/debug/tracing/available_events | grep -E "^sched|^block|^net"

# 스케줄러 컨텍스트 스위치 이벤트 활성화
echo 1 > /sys/kernel/debug/tracing/events/sched/sched_switch/enable

# 블록 I/O 완료 이벤트
echo 1 > /sys/kernel/debug/tracing/events/block/block_rq_complete/enable

# 네트워크 패킷 수신
echo 1 > /sys/kernel/debug/tracing/events/net/netif_receive_skb/enable

# 이벤트 필터 (특정 프로세스만)
echo 'prev_comm == "nginx"' > /sys/kernel/debug/tracing/events/sched/sched_switch/filter

# 모든 이벤트 비활성화
echo 0 > /sys/kernel/debug/tracing/events/enable
```

### 2.7 kprobe — 동적 추적

커널의 임의 함수에 동적으로 추적 지점을 삽입한다. 커널 재컴파일 없이 내부 변수도 읽을 수 있다.

```bash
# kprobe 이벤트 생성 (do_sys_open 진입 시 filename 출력)
echo 'p:myprobe do_sys_open filename=+0(%si):string' \
  > /sys/kernel/debug/tracing/kprobe_events

# 생성된 이벤트 활성화
echo 1 > /sys/kernel/debug/tracing/events/kprobes/myprobe/enable
echo 1 > /sys/kernel/debug/tracing/tracing_on

cat /sys/kernel/debug/tracing/trace_pipe &
# ... 파일 열기 작업 ...

# 정리
echo 0 > /sys/kernel/debug/tracing/events/kprobes/myprobe/enable
echo '-:myprobe' >> /sys/kernel/debug/tracing/kprobe_events

# kretprobe — 함수 반환값 추적
echo 'r:myretprobe do_sys_open ret=$retval' \
  >> /sys/kernel/debug/tracing/kprobe_events
```

### 2.8 trace-cmd — ftrace 래퍼 도구

raw debugfs 파일 조작 대신 편리한 CLI 제공.

```bash
# 설치
yum install -y trace-cmd   # RHEL
apt install -y trace-cmd   # Debian

# 특정 함수 5초간 기록
trace-cmd record -p function -l tcp_sendmsg sleep 5

# function_graph로 do_sys_open 추적
trace-cmd record -p function_graph -g do_sys_open ls /tmp

# 결과 분석
trace-cmd report | head -50

# 이벤트 기반 추적
trace-cmd record -e sched:sched_switch -e block:block_rq_complete sleep 5
trace-cmd report

# 특정 PID만 추적
trace-cmd record -p function -P <PID> sleep 3
```

### 2.9 kernelshark — GUI 분석

```bash
# trace-cmd 결과를 GUI로 시각화
yum install -y kernelshark
trace-cmd record -e sched -e irq sleep 5
kernelshark trace.dat
```

### 2.10 블록 I/O 레이턴시 분석

```bash
# blktrace + ftrace 연동 (I/O 경로 추적)
trace-cmd record -e block:block_rq_issue -e block:block_rq_complete \
  -e block:block_bio_queue dd if=/dev/sda of=/dev/null bs=4k count=1000

trace-cmd report | grep -E "issue|complete" | head -20
# I/O 발행부터 완료까지의 시간 확인

# 특정 디스크의 I/O 스택 추적
echo 1 > /sys/kernel/debug/tracing/events/block/enable
echo 'dev == MKDEV(8,0)' > /sys/kernel/debug/tracing/events/block/block_rq_issue/filter
```

### 2.11 실전: NFS I/O 레이턴시 원인 분석

```bash
# NFS 관련 함수 목록 확인
grep nfs /sys/kernel/debug/tracing/available_filter_functions | head -20

# NFS readpage 호출 흐름 추적
echo function_graph > /sys/kernel/debug/tracing/current_tracer
echo nfs_readpage > /sys/kernel/debug/tracing/set_graph_function
echo 1 > /sys/kernel/debug/tracing/tracing_on
cat /mnt/nfs/testfile > /dev/null
echo 0 > /sys/kernel/debug/tracing/tracing_on
cat /sys/kernel/debug/tracing/trace | grep -E "nfs|rpc" | head -30
```

---

## 3. 자주 하는 실수

| 실수 | 올바른 방법 |
|------|------------|
| function 트레이서를 필터 없이 활성화 → 링 버퍼 즉시 포화 | `set_ftrace_filter`로 관심 함수만 지정 후 활성화 |
| tracing_on=0 후 trace 버퍼 초기화 안 함 → 이전 결과와 혼재 | `echo > /sys/.../trace`로 버퍼 초기화 |
| trace_pipe 읽기 블로킹 상태에서 Ctrl+C → 이후 읽기 데이터 손실 | `cat trace` 사용 (비블로킹 스냅샷) |
| kprobe 이벤트 삭제 안 함 → 재부팅까지 남아있어 오버헤드 지속 | `-:probename` 형식으로 명시적 삭제 |
| debugfs를 noexec 마운트된 `/sys`에서 접근 불가 | `/sys/kernel/tracing`(tracefs) 경로 사용 |
| 프로덕션에서 function 트레이서 장시간 사용 → CPU 오버헤드 10~30% | function_graph + 좁은 필터, 또는 tracepoint만 사용 |

---

## 4. perf / eBPF / ftrace 비교

| 항목 | ftrace | perf | eBPF/bpftrace |
|------|--------|------|---------------|
| 접근 방식 | debugfs 파일 | syscall + perf_events | BPF 프로그램 |
| 동적 추적 | kprobe/kretprobe | kprobe/uprobe | kprobe/uprobe/tracepoint |
| 집계/필터링 | 제한적 | 중간 | 강력 (맵, 루프) |
| 오버헤드 | 중간 (function 트레이서 높음) | 낮음 | 낮음 |
| 출력 형식 | 텍스트 | 바이너리 (perf report) | 사용자 정의 |
| 커널 요구사항 | 2.6+ | 2.6.31+ | 4.1+ (BPF), 4.9+ (kprobe) |
| 사용 사례 | 커널 내부 흐름, 레이턴시 스파이크 | CPU 프로파일링, PMU | 범용 관측 가능성 |
