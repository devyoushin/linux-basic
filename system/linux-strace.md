# strace / ltrace - 시스템 콜 추적 및 실전 디버깅

## 1. 개요

`strace`는 프로세스가 커널에 요청하는 **시스템 콜(system call)**을 실시간으로 추적하는 도구다.
"왜 이 프로세스가 느린가", "왜 파일을 못 찾는가", "왜 권한이 거부되는가"처럼 소스코드 없이도
프로세스의 행동을 블랙박스처럼 들여다볼 수 있다.
`ltrace`는 같은 원리로 **라이브러리 함수 호출**을 추적하며, strace와 함께 사용하면 강력한 디버깅이 가능하다.

---

## 2. 설명

### 2-1. strace 작동 원리 - ptrace 시스템 콜

```
┌─────────────────────────────────────────┐
│              User Space                 │
│                                         │
│   ┌────────────┐     ┌───────────────┐  │
│   │   Target   │     │    strace     │  │
│   │  Process   │◄────│  (tracer)     │  │
│   │  (tracee)  │     │               │  │
│   └─────┬──────┘     └───────┬───────┘  │
│         │ syscall              │ ptrace()│
└─────────┼──────────────────── ┼─────────┘
          ▼                     ▼
┌─────────────────────────────────────────┐
│              Kernel Space               │
│                                         │
│   syscall entry → PTRACE_SYSCALL hook   │
│   → 실행 일시 정지 → strace가 레지스터 읽기  │
│   → 재개 → syscall 완료 → 다시 정지     │
│   → strace가 반환값 읽기 → 재개         │
└─────────────────────────────────────────┘
```

strace는 `ptrace(2)` 시스템 콜을 사용해 대상 프로세스를 제어한다.
시스템 콜 진입/퇴장 시마다 커널이 프로세스를 일시 정지하고 strace에 제어권을 넘긴다.

**오버헤드 주의**: ptrace는 시스템 콜마다 두 번의 컨텍스트 스위치를 유발한다.
I/O 집약적 프로세스는 10~100배까지 느려질 수 있다. 프로덕션에서는 반드시 `-c` 옵션으로
통계만 수집하거나, 짧은 시간만 추적한다.

### 2-2. 기본 사용법

```bash
# 새 프로세스 실행하며 추적
strace ls /tmp

# 실행 중인 프로세스에 attach (-p)
strace -p 1234

# 자식 프로세스까지 추적 (-f: follow fork)
strace -f -p 1234

# 출력을 파일로 저장 (-o)
strace -o /tmp/strace.log -p 1234

# 각 시스템 콜 소요 시간 출력 (-T)
strace -T -p 1234

# 타임스탬프 포함 (-t: 초, -tt: 마이크로초)
strace -tt -p 1234

# 시스템 콜 통계 요약 (-c)
strace -c ls /tmp

# 특정 시스템 콜만 필터링 (-e trace=)
strace -e trace=openat,read,write ls /tmp

# 문자열 출력 길이 늘리기 (-s, 기본 32바이트)
strace -s 512 curl http://example.com
```

### 2-3. 핵심 시스템 콜 해석법

**파일 접근 관련**

```
# openat: 파일 열기
openat(AT_FDCWD, "/etc/passwd", O_RDONLY) = 3
#         ↑ 기준 디렉토리    ↑ 파일 경로  ↑ 플래그   ↑ fd(성공)
# 반환값이 -1이면 실패, errno로 원인 확인

openat(AT_FDCWD, "/lib/libfoo.so", O_RDONLY) = -1 ENOENT (No such file or directory)
# ENOENT: 파일 없음 → 라이브러리 경로 문제

openat(AT_FDCWD, "/etc/secret", O_RDONLY) = -1 EACCES (Permission denied)
# EACCES: 권한 없음 → 파일 권한/소유자 확인 필요
```

**읽기/쓰기**

```
read(3, "root:x:0:0:root:/root:/bin/bash\n", 4096) = 32
#     ↑fd  ↑읽은 데이터(일부)                  ↑요청크기  ↑실제읽은 바이트

write(1, "hello\n", 6) = 6
#     ↑fd(stdout)  ↑데이터  ↑크기  ↑쓴 바이트
```

**네트워크 관련**

```
socket(AF_INET, SOCK_STREAM, IPPROTO_TCP) = 4
# TCP 소켓 생성, fd=4 반환

connect(4, {sa_family=AF_INET, sin_port=htons(80), sin_addr=inet_addr("93.184.216.34")}, 16) = 0
# 원격 호스트 연결 시도. 반환값 -1이면 연결 실패

recvfrom(4, "HTTP/1.1 200 OK\r\n...", 65536, 0, NULL, NULL) = 1024
# 소켓에서 데이터 수신
```

**프로세스/메모리**

```
mmap(NULL, 4096, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0) = 0x7f1234560000
# 메모리 매핑. 반복적으로 보이면 메모리 압박 의심

brk(NULL) = 0x55a0b1234000   # 힙 경계 조회
brk(0x55a0b1255000) = 0x55a0b1255000  # 힙 확장

clone(child_stack=NULL, flags=CLONE_CHILD_CLEARTID|SIGCHLD) = 5678
# 자식 프로세스 생성 (fork 내부 구현)
```

### 2-4. 실전 패턴 1 - "왜 프로세스가 느린가"

```bash
# 1단계: 시스템 콜 통계 수집 (오버헤드 낮음)
strace -c -p $(pgrep myapp)
# 30초 후 Ctrl+C

# 출력 예시 해석:
# % time     seconds  usecs/call     calls    errors syscall
# ------ ----------- ----------- --------- --------- ----------------
#  72.31    0.234521         234      1001           write
#  18.44    0.059832        5983        10           fsync
#   9.25    0.030001          30      1000           read

# fsync가 호출당 5983μs → 디스크 동기화가 병목
# 해결: write-back 캐시 활용, fsync 빈도 줄이기

# 2단계: 느린 syscall 상세 추적
strace -T -e trace=write,fsync -p $(pgrep myapp)
# -T: 각 호출 소요 시간 출력
# write(3, ..., 4096)   = 4096 <0.000234>
# fsync(3)              = 0    <0.005983>  ← 느린 것 확인
```

```bash
# 네트워크 대기 분석
strace -T -e trace=network -p $(pgrep myapp) 2>&1 | grep -E 'connect|recv|send'

# poll/select/epoll_wait 대기 시간 확인
strace -T -e trace=poll,select,epoll_wait -p $(pgrep myapp)
# epoll_wait(..., timeout=5000) = 1 <4.998102>
# → 이벤트를 거의 받지 못하고 타임아웃 → I/O 이벤트 없음 또는 외부 의존성 지연
```

### 2-5. 실전 패턴 2 - "왜 파일을 못 찾는가"

```bash
# 프로세스가 어떤 경로로 파일을 찾는지 추적
strace -e trace=openat,stat,access myapp 2>&1 | grep -E 'ENOENT|EACCES'

# 예시 출력:
# openat(AT_FDCWD, "/etc/myapp/config.yml", O_RDONLY) = -1 ENOENT
# openat(AT_FDCWD, "/usr/local/etc/myapp/config.yml", O_RDONLY) = -1 ENOENT
# openat(AT_FDCWD, "/home/ubuntu/.myapp/config.yml", O_RDONLY) = 5
# → 마지막 경로에서 성공 → 첫 두 경로에 파일 없음

# 라이브러리 로딩 실패 추적
strace -e trace=openat myapp 2>&1 | grep '\.so'
# openat(AT_FDCWD, "/lib/x86_64-linux-gnu/libssl.so.3", O_RDONLY) = -1 ENOENT
# → ldconfig 캐시 갱신 필요: sudo ldconfig
```

### 2-6. 실전 패턴 3 - "왜 권한이 거부되는가"

```bash
# 권한 거부 에러만 필터링
strace -e trace=all myapp 2>&1 | grep EACCES

# 예시:
# openat(AT_FDCWD, "/var/run/myapp.pid", O_WRONLY|O_CREAT, 0644) = -1 EACCES
# → /var/run에 쓰기 권한 없음. 실행 사용자 확인: ps aux | grep myapp

# SELinux/AppArmor 관련 거부
# strace에서 EACCES가 보여도 원인이 SELinux인 경우
ausearch -m avc -ts recent   # SELinux audit 로그 확인
dmesg | grep -i 'apparmor'   # AppArmor 거부 확인
```

### 2-7. ltrace - 라이브러리 함수 추적

```
┌──────────────────────────────────────┐
│            Application               │
│   myapp → printf() → malloc() → ...  │
└──────────────┬───────────────────────┘
               │ ltrace 추적 지점
┌──────────────▼───────────────────────┐
│         Shared Libraries             │
│   libc.so → libssl.so → libpthread   │
└──────────────┬───────────────────────┘
               │ strace 추적 지점
┌──────────────▼───────────────────────┐
│            Kernel Syscalls           │
└──────────────────────────────────────┘
```

```bash
# ltrace 기본 사용 (라이브러리 함수 추적)
ltrace ls /tmp

# 특정 라이브러리 함수만 추적
ltrace -e malloc,free,strlen myapp

# 실행 중인 프로세스 attach
ltrace -p 1234

# strace와 함께 사용 (라이브러리 + 시스템 콜)
ltrace -S myapp   # -S: syscall도 함께 출력

# 예시 출력:
# malloc(4096) = 0x55a0b1234f00       ← 메모리 할당
# strlen("hello world") = 11          ← 문자열 함수
# fopen("/etc/config", "r") = 0x55... ← 파일 열기 (libc 래퍼)
# __SYS_openat(...)                   ← -S 옵션으로 syscall도 표시
```

**strace vs ltrace 비교**

| 항목 | strace | ltrace |
|---|---|---|
| 추적 대상 | 커널 시스템 콜 | 공유 라이브러리 함수 |
| 커널 인터페이스 | ptrace | ptrace (동일) |
| 오버헤드 | 중간 | 높음 (더 많은 호출) |
| 정적 바이너리 | 완전히 동작 | 라이브러리 없어 제한적 |
| 주요 활용 | 파일/네트워크/권한 문제 | 메모리 누수, 문자열 처리 |

### 2-8. Docker 컨테이너 내부 프로세스 추적

컨테이너 내부에서 strace를 실행하려면 `SYS_PTRACE` capability가 필요하다.

```bash
# 방법 1: docker run 시 capability 추가
docker run --cap-add=SYS_PTRACE --security-opt seccomp=unconfined \
  -it ubuntu:22.04 bash

# 컨테이너 내부에서 strace 설치 및 사용
apt-get install -y strace
strace -p $(pgrep nginx)

# 방법 2: 호스트에서 컨테이너 프로세스 추적
# 컨테이너의 PID 확인
docker inspect --format '{{.State.Pid}}' my-container
# 출력: 12345

# 호스트에서 직접 추적 (root 필요)
strace -p 12345

# 방법 3: kubectl exec + strace (K8s)
kubectl exec -it pod-name -- bash
# 단, 기본 securityContext에서는 ptrace 거부됨

# K8s Pod에 SYS_PTRACE 허용 (디버그용)
```

```yaml
# k8s-debug-pod.yaml - 디버깅용 Pod 명세
apiVersion: v1
kind: Pod
metadata:
  name: debug-pod
spec:
  containers:
  - name: app
    image: myapp:latest
    securityContext:
      capabilities:
        add:
        - SYS_PTRACE        # strace 허용
      allowPrivilegeEscalation: true
```

```bash
# 방법 4: nsenter로 컨테이너 네임스페이스 진입 후 추적
CONTAINER_PID=$(docker inspect --format '{{.State.Pid}}' my-container)

# 컨테이너의 PID 네임스페이스에서 strace 실행
nsenter -t $CONTAINER_PID --pid --mount -- strace -p 1
# strace가 호스트에 설치되어 있어도 컨테이너 내부 프로세스 추적 가능
```

### 2-9. 고급 옵션 활용

```bash
# 특정 시스템 콜 그룹으로 필터링
strace -e trace=%file myapp        # 파일 관련 syscall 전체
strace -e trace=%network myapp     # 네트워크 관련 전체
strace -e trace=%process myapp     # 프로세스 생성/종료
strace -e trace=%signal myapp      # 시그널 처리
strace -e trace=%ipc myapp         # IPC (pipe, socket 등)
strace -e trace=%memory myapp      # 메모리 관련 (mmap, brk 등)

# 특정 syscall 제외
strace -e trace=\!poll,select myapp   # poll, select 제외

# 신호(signal) 추적
strace -e signal=all -p 1234

# 프로세스 종료 코드 추적
strace -e exit myapp

# 멀티스레드 프로세스: 스레드별 로그 파일 분리
strace -f -o /tmp/trace.log myapp
# /tmp/trace.log.PID 형태로 분리 저장됨
ls /tmp/trace.log.*

# 시스템 콜 진입 시점만 출력 (비동기 확인)
strace -e trace=write -P /var/log/app.log myapp
# -P: 특정 경로에 접근하는 syscall만 추적
```

---

## 3. 자주 하는 실수

| 실수 | 증상 / 문제 | 올바른 방법 |
|---|---|---|
| 프로덕션에서 `-f` 없이 멀티프로세스 추적 | 자식 프로세스 추적 누락, 원인 찾지 못함 | `-f` 옵션으로 fork/exec 추적 포함 |
| 기본 문자열 길이(32바이트)로 파일 경로 분석 | 긴 경로가 잘려서 `...` 으로 표시됨 | `-s 512` 또는 `-s 4096`으로 출력 길이 확장 |
| 프로덕션에서 `-e trace=all` 장시간 실행 | CPU 100%, 애플리케이션 응답 불능 | `-c` 옵션으로 통계만 수집하거나 `-e trace=%file` 등 범위 좁히기 |
| Docker 컨테이너에서 strace 실행 시 `EPERM` | `Operation not permitted` 에러 | `--cap-add=SYS_PTRACE --security-opt seccomp=unconfined` 추가 |
| strace 출력에서 `EINTR` 반복 | 신호 처리 루프로 착각 | `EINTR`은 syscall이 신호에 의해 중단된 것, 대부분 정상 동작 |
| ltrace로 정적 바이너리 분석 시도 | 출력 없음 | 정적 바이너리는 ltrace 불가, strace만 동작 |
| `-p` attach 후 프로세스 종료 안 되는 줄 오해 | Ctrl+C 누르면 strace만 종료됨 | strace 종료 시 추적만 중단, 대상 프로세스는 계속 실행 |
| 멀티스레드 프로세스 출력 뒤섞임 | PID가 섞여 흐름 파악 어려움 | `-o /tmp/trace.log` 로 파일 저장 후 `grep PID` 로 필터링 |
