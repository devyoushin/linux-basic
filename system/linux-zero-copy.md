# Zero-Copy I/O — sendfile/splice/mmap으로 CPU 복사 비용 제거

## 1. 개요

Zero-Copy I/O는 데이터 전송 시 유저스페이스 버퍼를 거치지 않고 커널 내부에서 직접 데이터를 이동해 불필요한 메모리 복사를 제거하는 기술이다. 일반 `read()` + `write()` 조합은 DMA 복사 2회와 CPU 복사 2회(총 4회)가 발생하지만, `sendfile()`, `splice()`, `mmap()` 등을 사용하면 CPU 복사를 완전히 제거할 수 있다.

파일 서빙 서버(Nginx), 메시지 브로커(Kafka), 스트리밍처럼 디스크에서 네트워크로 데이터를 그대로 흘려보내는 패턴에서 CPU 사용률 50% 이상 감소, 처리량 2배 향상이 보고된다.

---

## 2. 설명

### 2.1 일반 read() + write()의 4번 복사 문제

```
디스크
  │ (1) DMA 복사: 디스크 → 커널 페이지 캐시
  ▼
커널 버퍼 (Page Cache)
  │ (2) CPU 복사: 커널 버퍼 → 유저 버퍼   ← read() syscall
  ▼
유저 버퍼 (malloc/stack)
  │ (3) CPU 복사: 유저 버퍼 → 소켓 버퍼   ← write() syscall
  ▼
소켓 송신 버퍼 (커널)
  │ (4) DMA 복사: 소켓 버퍼 → NIC
  ▼
네트워크
```

| 항목 | 횟수 | 비고 |
|------|------|------|
| DMA 복사 | 2회 | 하드웨어 수행, CPU 개입 없음 |
| CPU 복사 | 2회 | 캐시 오염, 메모리 대역폭 낭비 |
| syscall | 2회 | 컨텍스트 스위치 4회 |

CPU 복사 2회가 핵심 병목이다.

### 2.2 sendfile(): 파일→소켓 직접 전송

`sendfile()`은 커널 내부에서 파일 디스크립터에서 소켓으로 직접 전송한다.

```
디스크 → 페이지 캐시 (DMA 복사)
페이지 캐시 → 소켓 버퍼 (scatter/gather DMA 지원 NIC에서 CPU 복사 제거)
소켓 버퍼 → NIC (DMA 복사)
```

SG-DMA 지원 NIC에서는 CPU 복사가 완전히 제거된다 (진정한 zero-copy).

```c
#include <sys/sendfile.h>

// 파일을 소켓에 직접 전송
ssize_t sendfile(
    int out_fd,    // 목적지: 소켓 fd (반드시 소켓)
    int in_fd,     // 출처: 파일 fd
    off_t *offset, // 시작 오프셋 (NULL이면 현재 위치)
    size_t count   // 전송할 바이트 수
);
```

```c
// 실전 예제: HTTP 파일 서빙
void serve_file(int socket_fd, const char *filepath) {
    int file_fd = open(filepath, O_RDONLY);
    struct stat st;
    fstat(file_fd, &st);

    off_t offset = 0;
    ssize_t sent;
    size_t remaining = st.st_size;

    while (remaining > 0) {
        sent = sendfile(socket_fd, file_fd, &offset, remaining);
        if (sent <= 0) break;   // 에러 또는 연결 종료
        remaining -= sent;
    }

    close(file_fd);
}
```

```bash
# Nginx에서 sendfile 확인
strace -p $(pgrep -n nginx) -e trace=sendfile64 2>&1 | head -5
# sendfile64(소켓fd, 파일fd, 오프셋, 크기) 형태로 호출 확인

# sendfile 지원 안 되는 경우 (NFS 마운트)
mount | grep nfs   # NFS이면 sendfile이 내부적으로 read+write 폴백
```

**sendfile 제약:**

| 제약 | 설명 |
|------|------|
| out_fd 타입 | 소켓(또는 파이프)만 가능 |
| in_fd 타입 | mmap() 가능한 파일만 |
| TLS/암호화 | 유저스페이스 처리 필요 → sendfile 불가 |
| NFS/FUSE | 일부에서 자동 폴백 |

### 2.3 splice(): 파이프 중개 전송

`splice()`는 파이프를 중개자로 사용해 파일, 파이프, 소켓 사이를 데이터 복사 없이 연결한다. `sendfile()`보다 조합이 자유롭다.

```c
#include <fcntl.h>

// 파일 → 파이프 → 소켓 경로
void splice_file_to_socket(int file_fd, int socket_fd, size_t file_size) {
    int pipefd[2];
    pipe(pipefd);   // 파이프 버퍼 (기본 64KB, fcntl로 확장 가능)

    // 파이프 버퍼 크기 확장
    fcntl(pipefd[0], F_SETPIPE_SZ, 1024 * 1024);   // 1MB로 확장

    size_t remaining = file_size;
    while (remaining > 0) {
        // 1단계: 파일 → 파이프 (커널 내부 포인터 이동, 복사 없음)
        ssize_t moved = splice(
            file_fd, NULL,   // 출처
            pipefd[1], NULL, // 파이프 쓰기 끝
            65536,           // 한 번에 이동할 크기 (64KB)
            SPLICE_F_MOVE | SPLICE_F_MORE
        );
        if (moved <= 0) break;

        // 2단계: 파이프 → 소켓 (커널 내부 포인터 이동)
        splice(pipefd[0], NULL, socket_fd, NULL, moved, SPLICE_F_MOVE);
        remaining -= moved;
    }

    close(pipefd[0]);
    close(pipefd[1]);
}
```

**sendfile vs splice 비교:**

| 항목 | sendfile | splice |
|------|---------|--------|
| 파이프 필요 | 불필요 | 필요 |
| 지원 방향 | 파일→소켓만 | 파일↔파이프↔소켓 모두 |
| 유연성 | 낮음 | 높음 |
| 커널 버전 | 2.2+ | 2.6.17+ |

### 2.4 tee(): 파이프 데이터 복제

`tee()`는 파이프 데이터를 소비하지 않고 다른 파이프로 복제한다. 로그 분기(파일 저장 + 소켓 전송 동시)에 활용한다.

```c
// 파이프 데이터를 두 목적지로 동시 전달
ssize_t len = tee(
    pipe_read,       // 출처 파이프 (데이터 소비 안 됨)
    pipe_log_write,  // 복제본 목적지
    65536,
    SPLICE_F_NONBLOCK
);

// 원본에서 소켓으로 전달 (이 시점에 소비)
splice(pipe_read, NULL, socket_fd, NULL, len, SPLICE_F_MOVE);
```

### 2.5 mmap(): 파일을 메모리에 직접 매핑

`mmap()`은 파일 영역을 프로세스 가상 주소 공간에 직접 매핑한다. 페이지 캐시와 같은 물리 페이지를 공유하므로 `read()` 없이 메모리 접근만으로 파일을 읽는다.

```c
#include <sys/mman.h>

void mmap_example(const char *filepath) {
    int fd = open(filepath, O_RDONLY);
    struct stat st;
    fstat(fd, &st);

    // 파일 전체를 가상 주소 공간에 매핑 (물리 복사 없음)
    char *data = mmap(
        NULL,           // 커널이 주소 선택
        st.st_size,     // 파일 전체 크기
        PROT_READ,      // 읽기 전용
        MAP_SHARED,     // 다른 프로세스와 페이지 공유
        fd,             // 매핑할 파일
        0               // 오프셋 (0 = 처음부터)
    );

    // 순차 읽기 힌트 — prefetch 최적화
    madvise(data, st.st_size, MADV_SEQUENTIAL);

    // 포인터로 직접 파일 내용 접근 (syscall 없음)
    process_data(data, st.st_size);

    munmap(data, st.st_size);
    close(fd);
}
```

**mmap 활용 패턴:**
- 대용량 파일 랜덤 접근 (데이터베이스 버퍼 풀)
- 공유 메모리 IPC
- PostgreSQL 공유 버퍼, SQLite WAL

### 2.6 vmsplice(): 유저 메모리→파이프 zero-copy

```c
struct iovec iov = {
    .iov_base = user_buf,  // 유저 버퍼
    .iov_len  = len,
};

// SPLICE_F_GIFT: 페이지 소유권을 커널에 이전 (복사 없음)
vmsplice(pipefd_write, &iov, 1, SPLICE_F_GIFT);
// 이후 user_buf를 절대 재사용 금지
```

> **주의**: `SPLICE_F_GIFT` 후 해당 버퍼를 읽거나 수정하면 undefined behavior가 발생한다.

### 2.7 MSG_ZEROCOPY: 소켓 송신 zero-copy (Linux 4.14+)

```c
// 소켓에 zero-copy 활성화
int val = 1;
setsockopt(sock_fd, SOL_SOCKET, SO_ZEROCOPY, &val, sizeof(val));

// zero-copy 송신 (커널이 user_buf를 NIC에 직접 DMA)
send(sock_fd, user_buf, len, MSG_ZEROCOPY);

// 완료 알림 수신 (에러 큐에서 읽어야 버퍼 재사용 가능)
struct msghdr msg = { .msg_control = control, .msg_controllen = sizeof(control) };
recvmsg(sock_fd, &msg, MSG_ERRQUEUE);  // 전송 완료 확인 후 버퍼 해제
```

> **주의**: 64KB 미만 소규모 전송에서는 완료 알림 오버헤드가 복사 비용보다 크다. 대용량 전송에서만 효과적이다.

### 2.8 각 기법 비교 표

| 기법 | 사용 케이스 | CPU 복사 | 커널 버전 | 주요 제약 |
|------|-----------|---------|---------|---------|
| read + write | 범용 | 2회 | 모든 버전 | 없음 |
| sendfile | 파일→소켓 | 0회 (SG-DMA) | 2.2+ | 파일→소켓만 |
| splice | 파이프 경유 전송 | 0회 | 2.6.17+ | 파이프 필요 |
| tee | 파이프 복제 | 0회 | 2.6.17+ | 파이프끼리만 |
| mmap + write | 랜덤 접근 후 전송 | 1회 | 2.0+ | TLB 압박 가능 |
| vmsplice (GIFT) | 유저 버퍼→파이프 | 0회 | 2.6.17+ | 버퍼 재사용 금지 |
| MSG_ZEROCOPY | 대용량 소켓 송신 | 0회 | 4.14 (TCP) | 완료 알림 처리 필요 |
| io_uring send_zc | 비동기 + zero-copy | 0회 | 5.19+ | liburing 필요 |

### 2.9 Nginx sendfile 설정

```nginx
http {
    sendfile on;           # zero-copy 정적 파일 서빙 활성화

    # sendfile + TCP_CORK: 작은 조각들을 MTU 크기로 묶어 전송
    tcp_nopush on;         # sendfile on 상태에서만 동작

    # Nagle 비활성화: 마지막 패킷 즉시 전송
    tcp_nodelay on;

    # 단일 sendfile 최대 크기 (0=무제한, 큰 값은 다른 요청 처리 지연)
    sendfile_max_chunk 1m;

    server {
        location /static/ {
            sendfile on;
            aio on;                # 비동기 I/O (O_DIRECT 필요)
            directio 512k;         # 512KB 이상 파일은 O_DIRECT로 읽기
        }
    }
}
```

```bash
# sendfile 동작 확인
strace -p $(pgrep -n nginx) -e trace=sendfile64 2>&1 | head -10

# sendfile on/off 성능 비교
ab -n 50000 -c 200 http://localhost/static/100mb.bin
```

### 2.10 Kafka zero-copy 원리

Kafka는 consumer fetch 요청 시 디스크→소켓을 `sendfile()`로 직접 전달한다.

```
Producer → Kafka 디스크 저장
Consumer fetch → sendfile(log_file, socket) → NIC
```

**Kafka zero-copy 전제 조건:**

| 조건 | 설명 |
|------|------|
| 페이지 캐시 활용 | JVM 힙 대신 OS 페이지 캐시 의존 |
| TLS 미사용 | TLS 암호화 시 유저스페이스 처리 → sendfile 불가 |
| 로컬 파일시스템 | NFS 마운트 시 폴백 가능 |

```bash
# Kafka 브로커의 sendfile 호출 확인
strace -p $(pgrep -f kafka) -e trace=sendfile64 2>&1 | head -5

# Kafka consumer 처리량 측정
/opt/kafka/bin/kafka-consumer-perf-test.sh \
    --bootstrap-server localhost:9092 \
    --topic perf-test \
    --messages 1000000
```

### 2.11 Java NIO FileChannel.transferTo()

```java
// Java에서 sendfile() 사용 — FileChannel.transferTo() 내부적으로 sendfile() 호출
import java.nio.channels.*;
import java.nio.file.*;

public class ZeroCopyServer {
    public static void serveFile(SocketChannel socket, String path)
            throws Exception {
        try (FileChannel file = FileChannel.open(Paths.get(path))) {
            long size = file.size();
            long sent = 0;
            while (sent < size) {
                // Linux: sendfile(), macOS: sendfile(), Windows: TransmitFile()
                sent += file.transferTo(sent, size - sent, socket);
            }
        }
    }
}
```

```bash
# Java 프로세스의 sendfile 호출 확인
strace -p $(pgrep -f "java.*Server") -e trace=sendfile64 2>&1 | head
```

### 2.12 TLS 환경에서의 제약과 대안

TLS 암호화는 zero-copy의 가장 큰 걸림돌이다.

```
TLS 환경:
디스크 → 페이지 캐시 (DMA)
페이지 캐시 → 유저 버퍼 (CPU 복사) ← sendfile 불가
유저 버퍼 → TLS 암호화 처리
암호화 데이터 → 소켓 버퍼 (CPU 복사)
소켓 버퍼 → NIC (DMA)
```

**대안:**

```nginx
# 방법 1: kTLS (커널 4.13+, 지원 NIC 필요)
ssl_conf_command Options KTLS;   # NIC 하드웨어 TLS 오프로드

# 방법 2: ALB TLS 터미네이션 → EC2 내부 평문 HTTP
# ALB에서 TLS 종료 → 내부 Nginx는 sendfile로 zero-copy 가능
server {
    listen 80;             # ALB로부터 평문 수신
    sendfile on;           # zero-copy 가능
}
```

```bash
# kTLS 지원 확인
modinfo tls | grep description   # TLS 커널 모듈
cat /proc/net/tls_stat           # kTLS 통계 (커널 5.2+)
```

### 2.13 성능 측정

```bash
# fio로 sendfile 처리량 측정
fio --name=sendfile-bench \
    --ioengine=sendfile \
    --filename=/data/testfile.bin \
    --bs=64k \
    --iodepth=64 \
    --rw=read \
    --runtime=60 \
    --time_based

# CPU 사용률 비교 (sendfile on/off)
sar -u 1 30   # 30초간 1초 간격 CPU 사용률

# strace로 syscall 경로 확인
strace -c -p $(pgrep -n nginx) 2>&1 | grep -E "sendfile|read|write"
```

---

## 3. 자주 하는 실수

| 실수 | 올바른 방법 |
|------|------------|
| TLS 환경에서 sendfile 사용 | CPU 복사 발생 — ALB TLS 종료 또는 kTLS 사용 |
| NFS 마운트 파일에 sendfile | 내부적으로 read+write 폴백 — `mount \| grep nfs`로 확인 |
| `vmsplice(SPLICE_F_GIFT)` 후 버퍼 재사용 | GIFT 후 해당 메모리 절대 재사용 금지 |
| `MSG_ZEROCOPY` 소규모 전송에 적용 | 64KB 미만은 완료 알림 오버헤드가 더 큼 |
| sendfile의 out_fd에 일반 파일 사용 | out_fd는 소켓(또는 파이프)만 가능 — 파이프 사용 시 `splice()` 선택 |
| tcp_nopush 없이 sendfile만 설정 | `sendfile on` + `tcp_nopush on` 항상 함께 설정 |
| sendfile_max_chunk 미설정 | 단일 sendfile이 오래 걸려 다른 요청 처리 지연 → 512k~1m로 제한 |
| splice() 파이프 버퍼 기본값 사용 | 기본 64KB → `fcntl(fd, F_SETPIPE_SZ, 1<<20)`으로 1MB 확장 |
| Java에서 FileInputStream+OutputStream | `FileChannel.transferTo()` 사용 (내부적으로 sendfile) |
| mmap 대용량 파일에서 madvise 미사용 | `madvise(ptr, size, MADV_SEQUENTIAL)`로 prefetch 힌트 제공 |
