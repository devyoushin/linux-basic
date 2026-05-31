# eBPF - 커널 관찰 및 bpftrace/bcc 실전 활용

## 1. 개요

eBPF(extended Berkeley Packet Filter)는 커널 소스를 수정하거나 모듈을 로드하지 않고도
**커널 내부에서 안전하게 프로그램을 실행**할 수 있는 기술이다.
네트워크 패킷 필터링에서 출발해 현재는 성능 분석, 보안 정책, 네트워크 프로그래밍 전반에
활용되며, Cilium(K8s 네트워킹), Falco(보안 탐지), Pixie(관찰 가능성) 등 현대 인프라의
핵심 기반 기술이다.

---

## 2. 설명

### 2-1. eBPF 작동 원리

```
┌──────────────────────────────────────────────────────────────┐
│                        User Space                            │
│                                                              │
│   ┌─────────────┐    ┌──────────┐    ┌────────────────────┐ │
│   │  bpftrace   │    │  BCC     │    │  libbpf 기반 앱    │ │
│   │  스크립트   │    │  Python  │    │  (Cilium, Falco)   │ │
│   └──────┬──────┘    └────┬─────┘    └────────┬───────────┘ │
│          │ eBPF 바이트코드 컴파일                │             │
└──────────┼──────────────── ┼──────────────────┼─────────────┘
           │                 │                  │
           ▼                 ▼                  ▼
┌──────────────────────────────────────────────────────────────┐
│                        Kernel Space                          │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐    │
│  │                    eBPF Verifier                     │    │
│  │  • 무한 루프 없음 확인    • 메모리 경계 검사          │    │
│  │  • 허용된 helper 함수만  • 스택 크기 512바이트 제한  │    │
│  └──────────────────────────┬──────────────────────────┘    │
│                             │ 검증 통과                       │
│                             ▼                               │
│  ┌─────────────────────────────────────────────────────┐    │
│  │                   JIT Compiler                       │    │
│  │         eBPF 바이트코드 → 네이티브 기계어            │    │
│  └──────────────────────────┬──────────────────────────┘    │
│                             │                               │
│   ┌─────────┐  ┌─────────┐  ┌──────────┐  ┌────────────┐  │
│   │ kprobe  │  │ uprobe  │  │tracepoint│  │    XDP     │  │
│   │커널함수 │  │유저함수 │  │정적훅    │  │네트워크드라│  │
│   │ 동적훅  │  │ 동적훅  │  │          │  │이버 수준   │  │
│   └─────────┘  └─────────┘  └──────────┘  └────────────┘  │
│                             │                               │
│   ┌────────────────── eBPF Maps ──────────────────────────┐ │
│   │  Hash / Array / Ring Buffer / Per-CPU / Stack Trace   │ │
│   │  (커널 ↔ 유저 공간 데이터 공유)                       │ │
│   └────────────────────────────────────────────────────────┘│
└──────────────────────────────────────────────────────────────┘
```

**핵심 구성 요소**

| 구성 요소 | 역할 |
|---|---|
| Verifier | 커널 적재 전 안전성 검증 (무한 루프, 메모리 범위 위반 차단) |
| JIT Compiler | eBPF 바이트코드를 x86/ARM 네이티브 코드로 변환 (성능 최적화) |
| Maps | 커널-유저 공간 데이터 공유 구조체 (해시맵, 배열, 링버퍼 등) |
| Helper Functions | eBPF 프로그램이 호출 가능한 커널 제공 함수 (~200개) |

### 2-2. 훅 유형 비교

```
kprobe          : 커널 함수 진입/반환 시 동적 훅 (재부팅 불필요)
                  예: do_sys_open 진입 시 파일 경로 기록
                  제약: 커널 함수 서명은 변경될 수 있어 취약

uprobe          : 유저 공간 함수 동적 훅 (Go/Python/Node.js 추적 가능)
                  예: libssl.so의 SSL_write 진입 시 평문 캡처
                  제약: 모든 프로세스 인스턴스에 훅 삽입됨

tracepoint      : 커널 개발자가 삽입한 안정적인 정적 훅
                  예: sched:sched_switch, net:netif_rx
                  장점: 커널 버전 간 인터페이스 안정적

USDT (User Statically Defined Tracing)
                : 앱 개발자가 소스에 삽입한 정적 훅
                  예: Python, Node.js, PostgreSQL 내장 USDT

XDP (eXpress Data Path)
                : NIC 드라이버 수준 패킷 처리 (소프트웨어 가장 빠른 경로)
                  예: DDoS 방어용 패킷 드롭, 로드밸런싱
                  성능: 커널 네트워크 스택 우회, 수십 Mpps 처리 가능
```

### 2-3. bpftrace 설치 및 원라이너 패턴

```bash
# 설치 (Ubuntu 20.04+)
sudo apt-get install -y bpftrace

# 설치 (Amazon Linux 2)
sudo yum install -y bpftrace

# 커널 버전 확인 (bpftrace는 4.9+, 완전한 기능은 5.8+ 권장)
uname -r
```

**시스템 콜 추적**

```bash
# 모든 프로세스의 openat(파일 열기) 추적
bpftrace -e 'tracepoint:syscalls:sys_enter_openat { printf("%s %s\n", comm, str(args->filename)); }'

# 특정 프로세스만 (pid 필터)
bpftrace -e 'tracepoint:syscalls:sys_enter_openat /pid == 1234/ { printf("%s\n", str(args->filename)); }'

# 실패한 시스템 콜만 추적 (반환값 < 0)
bpftrace -e 'tracepoint:syscalls:sys_exit_openat /args->ret < 0/ { printf("FAILED: %s %d\n", comm, args->ret); }'
```

**레이턴시 히스토그램**

```bash
# read() 시스템 콜 레이턴시 히스토그램
bpftrace -e '
tracepoint:syscalls:sys_enter_read { @start[tid] = nsecs; }
tracepoint:syscalls:sys_exit_read /@start[tid]/ {
  @latency_us = hist((nsecs - @start[tid]) / 1000);
  delete(@start[tid]);
}'

# 출력 예시:
# @latency_us:
# [1, 2)         123 |@@@@@@@@@@@@                     |
# [2, 4)         456 |@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@|  ← 대부분 2~4μs
# [4, 8)          89 |@@@@@@@@                         |
# [64, 128)        2 |                                 |  ← 이상치

# 특정 프로세스의 함수 레이턴시
bpftrace -e '
uprobe:/usr/bin/myapp:process_request { @start[tid] = nsecs; }
uretprobe:/usr/bin/myapp:process_request /@start[tid]/ {
  @ms = hist((nsecs - @start[tid]) / 1000000);
  delete(@start[tid]);
}'
```

**네트워크 추적**

```bash
# TCP 연결 추적 (연결 생성 시마다 출력)
bpftrace -e 'kprobe:tcp_connect { printf("connect: %s -> %s\n", comm, ntop(af, daddr)); }'

# 네트워크 수신 패킷 크기 분포
bpftrace -e 'tracepoint:net:netif_receive_skb { @size = hist(args->len); }'

# TCP 재전송 추적
bpftrace -e 'kprobe:tcp_retransmit_skb { @retrans[comm] = count(); }'
```

**CPU/스케줄링 분석**

```bash
# 프로세스별 런큐 대기 시간 (스케줄링 레이턴시)
bpftrace -e '
tracepoint:sched:sched_wakeup,tracepoint:sched:sched_wakeup_new {
  @qstart[args->pid] = nsecs;
}
tracepoint:sched:sched_switch {
  if (@qstart[args->next_pid]) {
    @runqlat_us = hist((nsecs - @qstart[args->next_pid]) / 1000);
    delete(@qstart[args->next_pid]);
  }
}'

# 특정 시간 동안만 실행 후 종료 (-c duration)
bpftrace -e 'tracepoint:sched:sched_switch { @[prev_comm] = count(); }' -c 10
```

### 2-4. bcc tools - 실전 활용 도구 모음

```bash
# bcc 설치 (Ubuntu)
sudo apt-get install -y bpfcc-tools python3-bpfcc

# bcc 설치 (Amazon Linux 2)
sudo yum install -y bcc-tools
export PATH=$PATH:/usr/share/bcc/tools
```

**execsnoop - 프로세스 실행 추적**

```bash
# 모든 exec() 호출 실시간 모니터링
execsnoop

# 출력:
# PCOMM     PID    PPID   RET ARGS
# bash      1234   1000   0   /bin/bash -c ls /tmp
# ls        1235   1234   0   /bin/ls /tmp
# → 의심스러운 프로세스 실행, 크론잡 디버깅에 유용
```

**opensnoop - 파일 열기 추적**

```bash
# 모든 파일 오픈 추적
opensnoop

# 특정 프로세스만
opensnoop -p $(pgrep myapp)

# 실패한 오픈만
opensnoop -x

# 출력:
# PID    COMM      FD ERR PATH
# 1234   myapp     5  0   /etc/myapp/config.yml
# 1234   myapp    -1  2   /etc/myapp/secret.key  ← ENOENT(2) 실패
```

**tcpconnect / tcpaccept - TCP 연결 추적**

```bash
# 아웃바운드 TCP 연결 추적
tcpconnect

# 인바운드 TCP 연결 수락 추적
tcpaccept

# 출력:
# PID    COMM         IP SADDR            DADDR            DPORT
# 1234   curl         4  10.0.1.5         93.184.216.34    80
# → 어떤 프로세스가 어디로 연결하는지 실시간 파악
# → 악성코드 C2 통신 탐지, 불필요한 외부 연결 발견

# tcptracer: 연결/종료 모두 추적
tcptracer
```

**biolatency - 블록 I/O 레이턴시**

```bash
# 블록 I/O 레이턴시 히스토그램 (10초)
biolatency -m 10

# 출력:
# Tracing block device I/O... Hit Ctrl-C to end.
#      msecs           : count     distribution
#        0 -> 1        : 1289     |@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@|
#        2 -> 3        : 45       |@                            |
#        8 -> 15       : 12       |                             |
#       64 -> 127      : 3        |                             |  ← 이상치, SLA 위반 가능
#
# → P99 레이턴시 확인, EBS gp2 vs gp3 성능 비교에 활용
```

**runqlat - CPU 런큐 레이턴시**

```bash
# CPU 스케줄링 대기 시간 분포 (10초)
runqlat 10 1

# 출력:
#      usecs           : count     distribution
#        0 -> 1        : 5467     |@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@|
#        2 -> 3        : 234      |@@@                          |
#       16 -> 31       : 12       |                             |
#      256 -> 511      : 3        |                             |  ← CPU 포화 징후

# P99 > 1ms → CPU 과부하 또는 noisy neighbor 문제
```

**profile - CPU 프로파일링 (perf 대안)**

```bash
# 49Hz로 30초 CPU 샘플링
profile -F 49 30

# 특정 프로세스만
profile -F 99 -p $(pgrep myapp) 30

# 출력: 스택 트레이스별 샘플 수
# → FlameGraph와 연동 가능
profile -F 99 30 | /opt/FlameGraph/flamegraph.pl > /tmp/bcc_flame.svg
```

### 2-5. 컨테이너/K8s 환경에서의 eBPF

**Cilium - K8s 네트워킹 + 보안**

```
┌──────────────────────────────────────────────────────┐
│                   K8s Node                           │
│                                                      │
│  ┌────────────┐  ┌────────────┐  ┌────────────────┐ │
│  │  Pod A     │  │  Pod B     │  │    Cilium      │ │
│  │ (app)      │  │ (db)       │  │    Agent       │ │
│  └──────┬─────┘  └──────┬─────┘  └───────┬────────┘ │
│         │               │                │           │
│  ┌──────▼───────────────▼────────────────▼────────┐ │
│  │              eBPF Programs (XDP/TC)             │ │
│  │  • L3/L4 네트워크 정책 (iptables 불필요)        │ │
│  │  • 서비스 로드밸런싱 (kube-proxy 대체)           │ │
│  │  • 네트워크 관찰 (Hubble)                       │ │
│  └────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────┘
```

**Falco - 런타임 보안 탐지**

```bash
# Falco: eBPF 기반 시스템 콜 모니터링으로 이상 행동 탐지
# 예: 컨테이너에서 /etc/shadow 접근, shell 실행 등

# Falco 규칙 예시 (비정상 파일 접근)
# - rule: Read sensitive file untrusted
#   desc: 컨테이너 내에서 민감한 파일 읽기
#   condition: open_read and container and sensitive_files
#   output: "Sensitive file opened (user=%user.name file=%fd.name)"
#   priority: WARNING
```

**K8s에서 bpftrace/bcc 실행**

```yaml
# k8s-bpf-debugger.yaml
apiVersion: v1
kind: Pod
metadata:
  name: bpf-debugger
  namespace: kube-system
spec:
  hostPID: true          # 호스트 PID 네임스페이스 공유 (필수)
  hostNetwork: true      # 네트워크 추적 시 필요
  containers:
  - name: bpf-tools
    image: quay.io/iovisor/bpftrace:latest
    command: ["sleep", "infinity"]
    securityContext:
      privileged: true   # eBPF 프로그램 로드 위해 필요
    volumeMounts:
    - name: sys
      mountPath: /sys
    - name: proc
      mountPath: /proc
  volumes:
  - name: sys
    hostPath:
      path: /sys
  - name: proc
    hostPath:
      path: /proc
  tolerations:
  - operator: Exists     # 모든 노드에 스케줄링
```

```bash
# 특정 K8s 노드의 Pod 내 프로세스 추적
# 1. 디버거 Pod에서 노드 전체 파일 열기 추적
kubectl exec -it bpf-debugger -- \
  bpftrace -e 'tracepoint:syscalls:sys_enter_openat { printf("%s %s\n", comm, str(args->filename)); }'

# 2. 특정 컨테이너 PID를 찾아서 추적
# 노드에서: crictl inspect <container-id> | grep pid
```

### 2-6. 커널 버전 요구사항 및 AWS 지원 현황

```
기능별 최소 커널 버전:
──────────────────────────────────────────────────
기능                          최소 버전   권장 버전
──────────────────────────────────────────────────
eBPF 기본 (cBPF 확장)         3.18        -
kprobe/kretprobe              4.1         -
tracepoint                    4.7         -
uprobe                        4.4         -
BPF maps (hash, array)        3.19        -
per-CPU maps                  4.6         -
ring buffer                   5.8         5.8+
BTF (BPF Type Format)         5.2         5.2+
CO-RE (Compile Once Run Everywhere) 5.2  5.5+
XDP                           4.8         5.0+
bpftrace 완전 기능             5.8         5.8+
──────────────────────────────────────────────────

AWS 커널 현황 (2024 기준):
──────────────────────────────────────────────────
OS                      커널          eBPF 지원
──────────────────────────────────────────────────
Amazon Linux 2023       6.1           완전 지원
Amazon Linux 2          5.10 (AL2022) 대부분 지원
Ubuntu 22.04 (AMI)      5.15          완전 지원
Ubuntu 20.04            5.4/5.15      부분 지원
Amazon EKS 최신         5.10+         완전 지원
──────────────────────────────────────────────────
```

```bash
# 현재 시스템의 eBPF 기능 지원 확인
bpftool feature probe | head -20

# BTF 지원 확인 (CO-RE 사용 가능 여부)
ls /sys/kernel/btf/vmlinux

# eBPF 프로그램 목록 확인
bpftool prog list

# eBPF 맵 목록 확인
bpftool map list
```

---

## 3. 자주 하는 실수

| 실수 | 증상 / 문제 | 올바른 방법 |
|---|---|---|
| 커널 4.x에서 bpftrace 최신 기능 사용 | `ERROR: kernel does not support` 메시지 | `bpftrace --info`로 지원 기능 확인 후 대안 사용 |
| K8s Pod에서 `--privileged` 없이 eBPF 로드 | `Operation not permitted` | `securityContext.privileged: true` 설정 필요 |
| bcc 도구 사용 시 Python 버전 불일치 | `ImportError: No module named 'bcc'` | `python3-bpfcc` 패키지 사용, `python3 /usr/share/bcc/tools/execsnoop` |
| uprobe에서 Go 바이너리 함수 추적 | 함수명 맨글링으로 매칭 안 됨 | `bpftrace -l 'uprobe:/path/to/binary:*'` 로 실제 심볼명 확인 |
| 고빈도 이벤트에 printf 사용 | 커널-유저 공간 통신 과부하로 데이터 손실 | `@map[key] = count()` 형태의 맵 집계 후 종료 시 출력 |
| verifier 오류 이해 못하고 포기 | `BPF program too large` 또는 루프 에러 | 루프를 `#pragma unroll` 또는 맵 기반 루프로 변경 |
| 컨테이너 내부 프로세스 uprobe 설정 시 경로 오류 | 훅 설치 안 됨 | 호스트 관점의 바이너리 경로 사용 (컨테이너 오버레이 경로 찾기) |
| AWS EC2에서 XDP 사용 시 성능 기대 | 가상 NIC(ENA)의 XDP 지원은 제한적 | ENA XDP 지원 여부 확인, native XDP는 베어메탈만 완전 지원 |
