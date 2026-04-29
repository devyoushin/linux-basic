# io_uring — 비동기 I/O의 새로운 패러다임

## 1. 개요

io_uring은 2019년 Linux 5.1에서 도입된 고성능 비동기 I/O 인터페이스다. 기존 POSIX AIO의 구조적 한계(O_DIRECT 강제, 제한된 연산 종류)와 epoll + read()/write() 조합의 syscall 오버헤드를 동시에 해결한다. 유저스페이스와 커널이 공유 메모리 링 버퍼를 직접 접근해 I/O 요청 제출과 완료 수집에 syscall을 최소화하거나 제거한다.

초당 수십만~수백만 건의 I/O를 처리하는 데이터베이스, 네트워크 서버, 스트리밍 플랫폼에서 기존 대비 30~70% 레이턴시 감소가 보고됐다.

---

## 2. 설명

### 2.1 기존 방식의 한계

#### POSIX AIO 문제

| 문제 | 설명 |
|------|------|
| O_DIRECT 강제 | 버퍼드 I/O(page cache) 사용 불가 |
| 정렬 요구 | 버퍼 주소/크기가 512B 또는 4096B 경계에 정렬되어야 함 |
| 블로킹 폴백 | 조건 미충족 시 내부 스레드 풀로 동기 처리 |
| 제한된 연산 | read/write만 지원, fsync/open/stat 등 비동기 불가 |

#### epoll syscall 오버헤드

```
일반적인 epoll 서버의 패킷당 syscall:
  epoll_wait()   → syscall 진입
  read(fd, buf)  → syscall 진입
  write(fd, buf) → syscall 진입
  epoll_ctl()    → syscall 진입

Spectre/Meltdown 패치 이후 syscall 비용 증가
→ 100만 req/s 서버에서 syscall 오버헤드만 10~20% CPU 낭비
```

### 2.2 핵심 구조: SQ / CQ 링 버퍼

```
유저스페이스                        커널
┌────────────────────────────────────────────────────┐
│         공유 메모리 (mmap으로 양쪽 접근 가능)          │
│                                                    │
│  SQ Ring (Submission Queue)                        │
│  ┌──────────────────────────┐                      │
│  │ SQE[0] SQE[1] SQE[2]... │ ← 앱이 직접 기록     │
│  │ head ──────────── tail   │                      │
│  └──────────────────────────┘                      │
│                                                    │
│  CQ Ring (Completion Queue)                        │
│  ┌──────────────────────────┐                      │
│  │ CQE[0] CQE[1] CQE[2]... │ ← 커널이 직접 기록   │
│  │ head ──────────── tail   │                      │
│  └──────────────────────────┘                      │
└────────────────────────────────────────────────────┘
```

```c
// SQE (Submission Queue Entry) — 요청 기술자
struct io_uring_sqe {
    __u8    opcode;     // IORING_OP_READ, IORING_OP_WRITE 등
    __u8    flags;      // IOSQE_IO_LINK 등
    __s32   fd;         // 대상 fd
    __u64   off;        // 파일 오프셋
    __u64   addr;       // 데이터 버퍼 주소
    __u32   len;        // 길이
    __u64   user_data;  // CQE에 그대로 전달되는 요청 식별자
};

// CQE (Completion Queue Entry) — 완료 알림
struct io_uring_cqe {
    __u64   user_data;  // SQE의 user_data 그대로
    __s32   res;        // 결과: 성공 시 바이트 수, 실패 시 -errno
    __u32   flags;
};
```

### 2.3 동작 흐름 (syscall 최소화)

```
1. SQE 획득:   io_uring_get_sqe()   → 공유 메모리 포인터 반환 (syscall 없음)
2. SQE 설정:   io_uring_prep_read() → 공유 메모리에 직접 기록 (syscall 없음)
3. tail 갱신:  tail++               → atomic 연산 (syscall 없음)
4. 커널 알림:  io_uring_submit()    → io_uring_enter syscall (1회, 여러 SQE 묶음)
5. 커널 처리:  커널 SQE 읽기 → I/O 수행
6. CQE 기록:   커널이 공유 메모리에 직접 기록 (syscall 없음)
7. 완료 수집:  io_uring_wait_cqe()  → 공유 메모리 읽기 (syscall 없음)
8. CQE 소비:   io_uring_cqe_seen()  → head++ (syscall 없음)
```

### 2.4 세 가지 동작 모드

```bash
# liburing 설치
apt install liburing-dev    # Ubuntu/Debian
dnf install liburing-devel  # RHEL/CentOS
```

#### 모드 1: 기본 모드

```c
struct io_uring ring;

// io_uring 초기화 — 공유 메모리 매핑 수행
io_uring_queue_init(256, &ring, 0);
// 제출 시 io_uring_enter() 1회 syscall
// 완료 수집은 공유 메모리 폴링 (syscall 없음)
```

#### 모드 2: SQPOLL (커널 폴링 스레드)

```c
struct io_uring_params params = {
    .flags = IORING_SETUP_SQPOLL,
    .sq_thread_idle = 2000,  // 유휴 2초 후 슬립
};
io_uring_queue_init_params(256, &ring, &params);
// 커널 스레드(io_uring-sq)가 SQ를 폴링 → 앱 syscall 완전 제거
// 대신 커널 스레드가 전용 CPU 사용 (busy-wait)
```

```bash
# SQPOLL 커널 스레드 확인
ps aux | grep "io_uring-sq"   # 커널 스레드 목록
```

#### 모드 3: IOPOLL

```c
struct io_uring_params params = {
    .flags = IORING_SETUP_IOPOLL,  // 완료 이벤트를 IRQ 아닌 폴링으로 수집
};
// NVMe 등 초고속 스토리지에서 IRQ 오버헤드 제거
// O_DIRECT 파일에서만 동작
```

### 2.5 실전 C 예제: 파일 비동기 읽기

```c
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <string.h>
#include <liburing.h>

#define BLOCK_SIZE 65536   // 64KB
#define QUEUE_DEPTH 64

int main(void) {
    struct io_uring ring;
    char buf[BLOCK_SIZE];

    // io_uring 초기화
    int ret = io_uring_queue_init(QUEUE_DEPTH, &ring, 0);
    if (ret < 0) {
        fprintf(stderr, "초기화 실패: %s\n", strerror(-ret));
        return 1;
    }

    int fd = open("/var/log/syslog", O_RDONLY);

    // SQE 획득 및 read 준비
    struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
    io_uring_prep_read(sqe, fd, buf, BLOCK_SIZE, 0);  // fd, 버퍼, 크기, 오프셋
    sqe->user_data = 42;  // 요청 식별자

    // 커널에 제출 (1회 syscall)
    io_uring_submit(&ring);

    // 완료 대기 (공유 메모리 조회)
    struct io_uring_cqe *cqe;
    io_uring_wait_cqe(&ring, &cqe);

    if (cqe->res < 0) {
        fprintf(stderr, "read 실패: %s\n", strerror(-cqe->res));
    } else {
        printf("읽은 바이트: %d\n", cqe->res);
    }

    io_uring_cqe_seen(&ring, cqe);  // CQE 소비 완료 — 반드시 호출
    close(fd);
    io_uring_queue_exit(&ring);     // 리소스 정리
    return 0;
}
```

```bash
# 컴파일
gcc -O2 -o io_uring_read io_uring_read.c -luring

# strace로 syscall 확인 (io_uring_enter만 보여야 함)
strace -e trace=io_uring_enter,io_uring_setup ./io_uring_read
```

### 2.6 배치 처리: 다중 파일 병렬 읽기

```c
#define NUM_FILES 32
#define BUF_SIZE  65536

struct req { int fd; char buf[BUF_SIZE]; int idx; };
struct req reqs[NUM_FILES];

// 모든 파일에 대해 SQE를 한 번에 등록
for (int i = 0; i < NUM_FILES; i++) {
    reqs[i].fd  = open(filenames[i], O_RDONLY);
    reqs[i].idx = i;

    struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
    io_uring_prep_read(sqe, reqs[i].fd, reqs[i].buf, BUF_SIZE, 0);
    sqe->user_data = (uint64_t)&reqs[i];  // 포인터를 식별자로
}

// 32개를 1회 syscall로 일괄 제출
io_uring_submit(&ring);

// 완료 이벤트 수집 (순서 무관)
for (int i = 0; i < NUM_FILES; i++) {
    struct io_uring_cqe *cqe;
    io_uring_wait_cqe(&ring, &cqe);

    struct req *r = (struct req *)(uintptr_t)cqe->user_data;
    printf("파일[%d] %d bytes 완료\n", r->idx, cqe->res);

    io_uring_cqe_seen(&ring, cqe);  // 반드시 소비 표시
    close(r->fd);
}
```

### 2.7 Fixed Buffer & Registered Files

```c
// 버퍼 사전 등록 (매 I/O마다 page pin 비용 제거)
struct iovec iov[4];
char bufs[4][4096];
for (int i = 0; i < 4; i++) {
    iov[i].iov_base = bufs[i];
    iov[i].iov_len  = 4096;
}
io_uring_register_buffers(&ring, iov, 4);  // 커널에 고정 등록

// 고정 버퍼 사용
struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
io_uring_prep_read_fixed(sqe, fd, bufs[0], 4096, 0, 0);  // 인덱스 0번 버퍼

// fd 사전 등록 (fd 유효성 검사 오버헤드 제거)
int fds[8] = { fd0, fd1, fd2, fd3, fd4, fd5, fd6, fd7 };
io_uring_register_files(&ring, fds, 8);

struct io_uring_sqe *sqe2 = io_uring_get_sqe(&ring);
io_uring_prep_read(sqe2, 0, buf, 4096, 0);  // 등록 인덱스 0번 fd
sqe2->flags |= IOSQE_FIXED_FILE;            // 등록 fd 사용 플래그
```

### 2.8 링크드 요청 (IOSQE_IO_LINK)

```c
// open → read → close를 원자적 체인으로
struct io_uring_sqe *sqe;

// 1단계: open (다음 SQE와 링크)
sqe = io_uring_get_sqe(&ring);
io_uring_prep_openat(sqe, AT_FDCWD, "/data/log.bin", O_RDONLY, 0);
sqe->flags |= IOSQE_IO_LINK;   // 체인 연결
sqe->user_data = 1;

// 2단계: read (open 성공 시에만 실행)
sqe = io_uring_get_sqe(&ring);
io_uring_prep_read(sqe, -1, buf, 65536, 0);
sqe->flags |= IOSQE_IO_LINK;
sqe->user_data = 2;

// 3단계: close (체인 종료)
sqe = io_uring_get_sqe(&ring);
io_uring_prep_close(sqe, -1);
sqe->user_data = 3;

io_uring_submit(&ring);   // 3개를 1회 syscall로 제출
```

> **주의**: 체인 중 하나라도 실패하면 이후 SQE는 `-ECANCELED`로 취소된다. 모든 CQE의 `res` 값을 반드시 확인해야 한다.

### 2.9 소켓 I/O (커널 5.5+)

```c
// io_uring으로 소켓 이벤트 처리 (epoll 대체)
#define EV_ACCEPT  1
#define EV_RECV    2

// accept 등록
struct io_uring_sqe *sqe = io_uring_get_sqe(ring);
io_uring_prep_accept(sqe, server_fd, (struct sockaddr*)&addr, &addr_len, 0);
sqe->user_data = EV_ACCEPT;

// 이벤트 루프
while (1) {
    struct io_uring_cqe *cqe;
    io_uring_wait_cqe(ring, &cqe);

    switch (cqe->user_data) {
    case EV_ACCEPT: {
        int client_fd = cqe->res;
        // 새 수신 대기 등록
        sqe = io_uring_get_sqe(ring);
        io_uring_prep_recv(sqe, client_fd, buf, BUF_SIZE, 0);
        sqe->user_data = EV_RECV;
        // 다음 accept도 등록
        sqe = io_uring_get_sqe(ring);
        io_uring_prep_accept(sqe, server_fd, (struct sockaddr*)&addr, &addr_len, 0);
        sqe->user_data = EV_ACCEPT;
        break;
    }
    case EV_RECV:
        // 수신된 데이터 처리 후 echo
        sqe = io_uring_get_sqe(ring);
        io_uring_prep_send(sqe, client_fd, buf, cqe->res, 0);
        break;
    }

    io_uring_cqe_seen(ring, cqe);
    io_uring_submit(ring);   // 새 SQE 일괄 제출
}
```

### 2.10 성능 비교

| I/O 방식 | 100개 파일 읽기 syscall 수 | 레이턴시 (NVMe, 4KB) |
|---------|------------------------|-------------------|
| `read()` 동기 | 100회 | ~2.5ms |
| POSIX AIO | 200회 (제출+수집) | ~700μs |
| epoll + read | 200회 | ~1.2ms |
| io_uring 기본 | 1회 (일괄 제출) | ~350μs |
| io_uring SQPOLL | **0회** | ~280μs |

### 2.11 보안 이슈

```bash
# 비특권 사용자의 io_uring 비활성화 (CVE 대응)
sysctl -w kernel.io_uring_disabled=1   # 비특권 사용자만 비활성화

# 완전 비활성화
sysctl -w kernel.io_uring_disabled=2   # root 포함 전체 비활성화

# 영구 적용
echo "kernel.io_uring_disabled = 1" >> /etc/sysctl.d/99-io-uring.conf

# seccomp에서 io_uring syscall 허용 (컨테이너)
# seccomp 프로파일에 추가
{
  "names": ["io_uring_setup", "io_uring_enter", "io_uring_register"],
  "action": "SCMP_ACT_ALLOW"
}
```

**주요 CVE 목록:**

| CVE | 커널 | 유형 |
|-----|------|------|
| CVE-2022-29582 | 5.17 이하 | Use-after-free |
| CVE-2022-1786 | 5.18 미만 | Linked timeout UAF |
| CVE-2023-2598 | 6.3 미만 | Fixed buffer OOB |

### 2.12 커널 버전별 기능

| 버전 | 추가 기능 |
|------|---------|
| 5.1 | io_uring 최초 도입, 기본 read/write |
| 5.2 | Fixed buffers, Registered files |
| 5.5 | IORING_OP_SEND, RECV, ACCEPT, CONNECT |
| 5.10 (LTS) | 소켓 연산 안정화 |
| 5.19 | MSG_ZEROCOPY 통합 |
| 6.1 (LTS) | 워커 풀 제거, 네트워킹 최적화 |
| 6.7 | IORING_OP_BIND, LISTEN — 소켓 셋업 완전 비동기화 |

```bash
# io_uring 지원 여부 런타임 확인
python3 -c "
import ctypes, ctypes.util
libc = ctypes.CDLL(ctypes.util.find_library('c'))
ret = libc.syscall(425, 0, 0, 0, 0)  # __NR_io_uring_setup
import errno, ctypes
print('io_uring 지원' if ctypes.get_errno() != 38 else 'io_uring 미지원')
"

# io_uring_probe로 연산 지원 여부 확인 (liburing)
# io_uring_probe() 함수로 각 IORING_OP_* 지원 여부 런타임 조회
```

---

## 3. 자주 하는 실수

| 실수 | 올바른 방법 |
|------|------------|
| `io_uring_cqe_seen()` 호출 누락 | CQ 링이 가득 차 블로킹 — 모든 CQE 처리 후 반드시 호출 |
| SQE 제출 후 버퍼 즉시 해제 | CQE 수신 후 버퍼 해제 — 커널이 I/O 완료할 때까지 버퍼 유지 |
| SQPOLL idle 타임아웃 미처리 | `IORING_SQ_NEED_WAKEUP` 확인 후 `io_uring_enter()` 호출 |
| Fixed buffer 미사용으로 대량 I/O | `io_uring_register_buffers()`로 사전 등록하면 page pin 비용 제거 |
| IOPOLL을 버퍼드 파일에 사용 | IOPOLL은 `O_DIRECT` 파일에서만 동작 |
| 링크 체인 실패 처리 누락 | 이후 SQE가 `-ECANCELED`로 조용히 실패 — 모든 CQE `res` 확인 |
| 큐 깊이 부족 | `io_uring_get_sqe()` NULL 반환 — 동시 요청 수의 2배로 설정 |
| fork 후 부모 io_uring 공유 | 자식 프로세스는 새 io_uring 인스턴스 생성 |
| seccomp 미갱신 상태로 컨테이너 사용 | io_uring 3종 syscall 명시적 허용 필요 |
