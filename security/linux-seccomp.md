# linux-seccomp.md — seccomp: 프로세스의 시스템 콜 화이트리스트/블랙리스트 제한

## 1. 개요

seccomp(SECure COMPuting mode)은 Linux 커널 3.5부터 제공하는 샌드박스 메커니즘으로, 프로세스가 호출할 수 있는 시스템 콜(syscall)을 BPF 필터로 제한한다. 컨테이너 보안의 핵심 레이어로, Docker는 기본적으로 300여 개의 syscall 중 44개를 차단한 프로파일을 적용한다. 공격자가 코드 실행 권한을 얻더라도 커널 인터페이스를 제한함으로써 피해를 최소화한다.

---

## 2. 설명

### 2.1 seccomp 작동 원리

```
Process (User Space)
        │
        │  시스템 콜 호출 (예: open, write, execve)
        ▼
┌─────────────────────────────────────────────┐
│           Linux Kernel                       │
│                                              │
│   syscall 진입                               │
│       │                                      │
│       ▼                                      │
│   ┌─────────────────┐                        │
│   │  seccomp 필터    │                        │
│   │  (BPF 프로그램)  │                        │
│   └────────┬────────┘                        │
│            │                                 │
│    ┌───────┴────────┐                        │
│    ▼                ▼                        │
│  ALLOW            DENY                       │
│  (실행 계속)    ┌────────────┐               │
│                 │  Action    │               │
│                 ├────────────┤               │
│                 │ KILL       │ 프로세스 종료  │
│                 │ ERRNO      │ 오류 반환      │
│                 │ TRAP       │ SIGSYS 신호    │
│                 │ TRACE      │ ptrace 전달    │
│                 │ LOG        │ 로그만 기록    │
│                 └────────────┘               │
└─────────────────────────────────────────────┘
```

**두 가지 모드:**

| 모드 | 설명 | 허용 syscall |
|---|---|---|
| `SECCOMP_MODE_STRICT` | read/write/exit/sigreturn 4개만 허용 | 극히 제한적 |
| `SECCOMP_MODE_FILTER` | BPF 필터로 세밀한 제어 | 프로파일 정의에 따름 |

```c
/* SECCOMP_MODE_STRICT 예시 (C 코드) */
#include <sys/prctl.h>
#include <linux/seccomp.h>

prctl(PR_SET_SECCOMP, SECCOMP_MODE_STRICT);
/* 이후 read/write/exit/sigreturn 외 모든 syscall은 SIGKILL */
```

BPF(Berkeley Packet Filter) 필터는 커널 내 가상머신에서 실행되는 소규모 프로그램이다. syscall 번호와 인자를 검사하여 ALLOW/DENY를 결정한다.

### 2.2 Docker 기본 seccomp 프로파일

Docker는 기본적으로 `/etc/docker/seccomp.json` 또는 내장 프로파일을 적용한다.

```
전체 Linux syscall 수:    약 300~350개 (아키텍처마다 다름)
Docker 기본 차단 syscall: 약 44개
Docker 기본 허용 syscall: 나머지 (~250개 이상)
```

**차단되는 주요 syscall (보안상 위험한 것들):**

```
syscall                 차단 이유
──────────────────────────────────────────────────────
kexec_load             새 커널 로드 (시스템 탈취)
reboot                 컨테이너에서 호스트 재부팅 방지
mount                  파일시스템 마운트 (특권 필요)
umount2                파일시스템 언마운트
pivot_root             루트 파일시스템 교체
swapon/swapoff         스왑 관리
sysfs                  sysfs 마운트
_sysctl                커널 파라미터 수정
ptrace                 다른 프로세스 추적/수정
perf_event_open        성능 이벤트 (정보 유출)
add_key/keyctl         커널 키링 조작
clone (CLONE_NEWUSER)  새 user namespace (권한 상승 경로)
settimeofday           시스템 시간 변경
adjtimex               NTP 시간 조정
```

```bash
# 현재 컨테이너의 seccomp 상태 확인
docker inspect <컨테이너명> | grep -i seccomp

# seccomp 비활성화 (테스트 목적, 운영 금지)
docker run --security-opt seccomp=unconfined ubuntu bash

# 기본 seccomp 프로파일 경로 (Docker 설치 시 내장)
# /usr/share/containers/seccomp.json (일부 배포판)
```

### 2.3 커스텀 seccomp 프로파일 JSON 작성

```json
{
  "defaultAction": "SCMP_ACT_ERRNO",
  "defaultErrnoRet": 1,
  "archMap": [
    {
      "architecture": "SCMP_ARCH_X86_64",
      "subArchitectures": [
        "SCMP_ARCH_X86",
        "SCMP_ARCH_X32"
      ]
    }
  ],
  "syscalls": [
    {
      "names": [
        "accept",
        "accept4",
        "bind",
        "brk",
        "clock_gettime",
        "clone",
        "close",
        "connect",
        "dup",
        "dup2",
        "epoll_create",
        "epoll_create1",
        "epoll_ctl",
        "epoll_pwait",
        "epoll_wait",
        "execve",
        "exit",
        "exit_group",
        "fcntl",
        "fstat",
        "futex",
        "getpid",
        "getppid",
        "getrandom",
        "getsockname",
        "getsockopt",
        "getuid",
        "listen",
        "lstat",
        "mmap",
        "mprotect",
        "munmap",
        "nanosleep",
        "open",
        "openat",
        "pipe",
        "pipe2",
        "poll",
        "prctl",
        "pread64",
        "pwrite64",
        "read",
        "readlink",
        "recv",
        "recvfrom",
        "recvmsg",
        "rt_sigaction",
        "rt_sigprocmask",
        "rt_sigreturn",
        "send",
        "sendmsg",
        "sendto",
        "set_robust_list",
        "set_tid_address",
        "setsockopt",
        "sigaltstack",
        "socket",
        "stat",
        "uname",
        "wait4",
        "write",
        "writev"
      ],
      "action": "SCMP_ACT_ALLOW"
    },
    {
      "names": ["ptrace"],
      "action": "SCMP_ACT_ERRNO",
      "errnoRet": 1,
      "comment": "ptrace 명시적 차단 (디버거 첨부 방지)"
    }
  ]
}
```

**action 종류:**

| action | 동작 |
|---|---|
| `SCMP_ACT_ALLOW` | syscall 허용 |
| `SCMP_ACT_ERRNO` | 오류 코드 반환 (기본: EPERM) |
| `SCMP_ACT_KILL` | 프로세스 즉시 종료 |
| `SCMP_ACT_KILL_PROCESS` | 스레드 그룹 전체 종료 |
| `SCMP_ACT_TRAP` | SIGSYS 신호 전송 |
| `SCMP_ACT_LOG` | 허용하되 감사 로그 기록 |
| `SCMP_ACT_TRACE` | ptrace로 전달 |

```bash
# 커스텀 프로파일로 컨테이너 실행
docker run --security-opt seccomp=/path/to/custom-seccomp.json \
    ubuntu:22.04 bash

# 특정 syscall만 추가 차단 (기본 프로파일 위에서 불가, 교체 방식)
# → 기본 프로파일을 복사하고 수정하는 접근법 사용
```

### 2.4 Kubernetes securityContext.seccompProfile 설정

```yaml
# Pod 레벨 seccomp 프로파일 설정
apiVersion: v1
kind: Pod
metadata:
  name: secure-app
spec:
  securityContext:
    seccompProfile:
      type: RuntimeDefault    # 컨테이너 런타임 기본 프로파일 사용 (Docker 기본과 유사)
  containers:
  - name: app
    image: myapp:latest
    securityContext:
      allowPrivilegeEscalation: false   # setuid/setgid 실행 방지
      readOnlyRootFilesystem: true
      runAsNonRoot: true
      runAsUser: 1000
```

```yaml
# Localhost 프로파일 사용 (커스텀 JSON)
apiVersion: v1
kind: Pod
metadata:
  name: custom-seccomp-pod
spec:
  securityContext:
    seccompProfile:
      type: Localhost
      localhostProfile: profiles/my-app-seccomp.json
      # 프로파일 파일 위치: /var/lib/kubelet/seccomp/profiles/my-app-seccomp.json
  containers:
  - name: app
    image: myapp:latest
```

```yaml
# Unconfined: seccomp 비활성화 (운영 환경 금지)
apiVersion: v1
kind: Pod
spec:
  securityContext:
    seccompProfile:
      type: Unconfined
```

```yaml
# K8s 1.19+: PodSecurityPolicy 대체로 OPA/Kyverno 정책으로 강제
# Kyverno 정책: RuntimeDefault 이상의 seccomp 프로파일 강제
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-seccomp
spec:
  validationFailureAction: enforce
  rules:
  - name: check-seccomp
    match:
      any:
      - resources:
          kinds: [Pod]
    validate:
      message: "Seccomp profile must be RuntimeDefault or Localhost"
      pattern:
        spec:
          securityContext:
            seccompProfile:
              type: "RuntimeDefault | Localhost"
```

### 2.5 최소 syscall 프로파일 추출: strace + seccomp-bpf

```bash
# ── 방법 1: strace로 실제 사용 syscall 추출
strace -f -e trace=all \
    -o /tmp/strace-output.txt \
    node server.js &

# 일정 시간 서비스 실행 후 종료
sleep 60 && kill %1

# 사용된 syscall 목록 추출
grep -o 'syscall\|^[a-z_]*(' /tmp/strace-output.txt | \
    sort -u > /tmp/used-syscalls.txt

# strace로 syscall 이름만 추출
awk -F'(' '{print $1}' /tmp/strace-output.txt | \
    grep -E '^[a-z]' | sort -u

# ── 방법 2: seccomp-bpf + audit 모드로 필요 syscall 탐지
# audit 모드(SCMP_ACT_LOG)로 일단 모든 syscall을 허용하되 로그만 기록
# 이후 audit 로그에서 실제 사용 syscall 추출

# ── 방법 3: oci-seccomp-bpf-hook (컨테이너 전용)
# 컨테이너 실행 중 BPF로 자동 프로파일 생성
# https://github.com/containers/oci-seccomp-bpf-hook
podman run \
    --annotation io.containers.trace-syscall=of:/tmp/traced-profile.json \
    --security-opt seccomp=unconfined \
    myapp:latest

# 생성된 프로파일로 재실행
podman run --security-opt seccomp=/tmp/traced-profile.json myapp:latest
```

```bash
# ── 방법 4: docker의 --security-opt seccomp=log 모드 (Docker 23+)
# SCMP_ACT_LOG 사용: 차단 없이 syscall 로깅
cat > /tmp/log-profile.json << 'EOF'
{
  "defaultAction": "SCMP_ACT_LOG",
  "syscalls": []
}
EOF

docker run --security-opt seccomp=/tmp/log-profile.json myapp:latest

# /var/log/syslog 또는 dmesg에서 syscall 로그 확인
dmesg | grep "syscall="
```

### 2.6 syscall 차단으로 인한 컨테이너 장애 트러블슈팅

```bash
# ── 증상 1: 컨테이너가 즉시 종료
# SCMP_ACT_KILL이 적용된 syscall 호출 시 발생
docker run --security-opt seccomp=custom.json myapp
# → 컨테이너가 exit code 159 (SIGSYS) 또는 31로 종료

# 진단
dmesg | grep "audit: type=1326"    # seccomp audit 이벤트
# 출력 예시:
# audit: type=1326 audit(1234567890.123:1): auid=0 uid=0 gid=0 \
#   ses=1 pid=12345 comm="node" exe="/usr/bin/node" \
#   sig=31 arch=c000003e syscall=317 compat=0 ip=0x... code=0x0
# syscall=317 → 317번 syscall이 차단됨

# syscall 번호를 이름으로 변환
ausyscall --dump | grep "^317"
# 또는
python3 -c "import ctypes; print(ctypes.CDLL(None).syscall.__doc__)"

# ausyscall로 번호 변환 (audit 패키지 필요)
ausyscall x86_64 317   # → seccomp (syscall 번호 317 = seccomp 시스템 콜)
```

```bash
# ── 증상 2: 특정 기능 실패 (권한 없음 오류)
# SCMP_ACT_ERRNO가 적용된 경우: 프로세스는 살아있지만 해당 기능 실패

# 예시: Java 애플리케이션의 /proc/sys/kernel/perf_event_paranoid 접근 실패
# 해결 방법: seccomp 완전 비활성화 없이 해당 syscall만 허용

# custom 프로파일에 syscall 추가
{
  "syscalls": [
    {
      "names": ["perf_event_open"],
      "action": "SCMP_ACT_ALLOW"
    }
  ]
}
```

```bash
# ── 증상 3: glibc wrapper vs 실제 syscall 불일치
# 일부 함수는 내부적으로 여러 syscall을 사용

# 예시: clone3 (새로운 버전)을 차단하면 fork()가 실패할 수 있음
# glibc 2.29+ 는 fork() 내부에서 clone3 우선 시도
# → ENOSYS 반환 시 clone으로 폴백하므로 ERRNO로 설정 필요 (KILL 금지)

{
  "syscalls": [
    {
      "names": ["clone3"],
      "action": "SCMP_ACT_ERRNO",
      "errnoRet": 38    # ENOSYS: 시스템 콜 미구현 → glibc가 폴백
    }
  ]
}
```

```bash
# ── 실전 디버깅 워크플로우
# 1. 먼저 unconfined로 실행해 정상 동작 확인
docker run --security-opt seccomp=unconfined myapp:latest

# 2. strace로 syscall 추적
docker run --security-opt seccomp=unconfined \
    --entrypoint strace \
    myapp:latest -f -e trace=all /entrypoint.sh 2>&1 | \
    awk -F'(' '{print $1}' | grep -E '^[a-z_]' | sort -u

# 3. 기본 Docker 프로파일로 실행 → 어떤 syscall이 추가로 필요한지 확인
docker run --security-opt seccomp=/etc/docker/seccomp.json myapp:latest

# 4. 실패 시 dmesg에서 차단된 syscall 번호 확인 후 프로파일에 추가
dmesg | tail -20 | grep seccomp
```

### 2.7 Node.js/Go/Java 앱 최소 프로파일 예시

```json
{
  "comment": "Node.js HTTP 서버용 최소 seccomp 프로파일",
  "defaultAction": "SCMP_ACT_ERRNO",
  "syscalls": [
    {
      "names": [
        "accept4", "bind", "brk", "clone", "clone3",
        "close", "connect", "dup", "dup2", "dup3",
        "epoll_create1", "epoll_ctl", "epoll_pwait",
        "eventfd2", "execve", "exit", "exit_group",
        "faccessat", "fchdir", "fcntl", "fstat",
        "futex", "getcwd", "getdents64", "getegid",
        "geteuid", "getgid", "getpid", "getppid",
        "getrandom", "getsockname", "getsockopt",
        "getuid", "ioctl", "kill", "listen",
        "lseek", "lstat", "madvise", "mmap",
        "mprotect", "munmap", "nanosleep", "newfstatat",
        "open", "openat", "pipe", "pipe2",
        "poll", "ppoll", "prctl", "pread64",
        "read", "readlink", "readlinkat", "recv",
        "recvfrom", "recvmsg", "rt_sigaction",
        "rt_sigprocmask", "rt_sigreturn", "rt_sigsuspend",
        "sched_getaffinity", "sched_yield",
        "send", "sendmsg", "sendto", "set_robust_list",
        "set_tid_address", "setitimer", "setsockopt",
        "sigaltstack", "socket", "stat", "statx",
        "tgkill", "timerfd_create", "timerfd_settime",
        "uname", "wait4", "write", "writev"
      ],
      "action": "SCMP_ACT_ALLOW"
    }
  ]
}
```

### 2.8 seccomp 적용 현황 확인

```bash
# 특정 프로세스의 seccomp 상태 확인
cat /proc/<PID>/status | grep Seccomp
# Seccomp: 0 → 비활성화
# Seccomp: 1 → STRICT 모드
# Seccomp: 2 → FILTER 모드 (BPF)

# 컨테이너 내부에서 확인
docker exec <컨테이너> cat /proc/1/status | grep Seccomp

# K8s Pod에서 확인
kubectl exec <pod> -- cat /proc/1/status | grep Seccomp

# 커널의 seccomp 지원 여부
grep CONFIG_SECCOMP /boot/config-$(uname -r)
# CONFIG_SECCOMP=y        → seccomp 지원
# CONFIG_SECCOMP_FILTER=y → BPF 필터 지원
```

---

## 3. 자주 하는 실수

| 실수 | 올바른 방법 |
|---|---|
| `defaultAction: SCMP_ACT_KILL` 설정 | 처음엔 `SCMP_ACT_LOG`로 로깅만 하며 필요 syscall 수집 후 점진적으로 강화 |
| `clone3`를 KILL로 차단 | `SCMP_ACT_ERRNO + errnoRet: 38(ENOSYS)` 설정. glibc가 폴백 로직으로 처리 |
| K8s에서 seccomp 미설정 (기본 Unconfined) | K8s 1.27+에서 `RuntimeDefault`가 기본값으로 변경. 명시적으로 `RuntimeDefault` 설정 권장 |
| 한 번 추출한 프로파일을 영구히 사용 | 앱 업데이트 시 새 syscall이 추가될 수 있음. CI 파이프라인에 strace 기반 검증 추가 |
| 아키텍처별 syscall 번호 차이 무시 | `archMap`에 `SCMP_ARCH_X86_64`와 `SCMP_ARCH_X86` 모두 명시 |
| Docker `--privileged`로 seccomp 우회 | `--privileged`는 seccomp/AppArmor/capabilities 모두 비활성화. 최소 필요 capability만 추가 |
| seccomp만으로 완전한 격리 기대 | seccomp는 syscall 제한만 담당. AppArmor/SELinux(파일 접근), capabilities(특권), namespace(격리)와 다층 방어 필요 |
| 앱 디버깅 시 seccomp 상태 미확인 | `/proc/<PID>/status`의 `Seccomp` 필드 확인. 장애 원인이 seccomp 차단인지 먼저 파악 |
