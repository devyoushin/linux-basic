# Linux Syscall 심층 분석 — 동작 원리, 비용, 최적화

## 1. 개요

Syscall(시스템 콜)은 유저 프로그램이 커널 기능을 요청하는 유일한 공식 경로다.
파일 읽기, 프로세스 생성, 네트워크 전송 — 모든 I/O와 자원 접근이 syscall을 통한다.
`du`가 파일 100만 개에서 느린 이유, `nginx`가 수만 req/s를 처리하는 이유 모두 syscall 처리 비용으로 설명된다.

---

## 2. 유저 공간과 커널 공간

### 2.1 두 공간의 분리

CPU는 **Ring(특권 레벨)** 구조로 실행 컨텍스트를 분리한다.

```
Ring 0 (커널 모드)     — 모든 하드웨어 명령어 실행 가능
Ring 1, 2 (미사용)     — x86-64 Linux에서는 사용 안 함
Ring 3 (유저 모드)     — 제한된 명령어만 실행 가능
```

유저 프로그램이 디스크나 네트워크에 직접 접근하는 명령어(`in`, `out`, `hlt`)를 실행하면
CPU가 **General Protection Fault**를 발생시키고 프로세스가 강제 종료된다.
커널만이 Ring 0에서 실행되며 하드웨어에 직접 접근한다.

```
유저 프로그램           커널
─────────────────      ─────────────────────────────
read(fd, buf, n)  →    sys_read()
                           → VFS → 파일시스템 드라이버
                           → 블록 I/O 레이어
                           → 디바이스 드라이버
                  ←    반환값 (읽은 바이트 수)
```

### 2.2 가상 주소 공간 레이아웃

```
0xFFFFFFFFFFFFFFFF ┐
                   │  커널 공간 (128TB)
                   │  — 커널 코드, 데이터, 페이지 테이블
0xFFFF800000000000 ┘
                      (캐노니컬 홀 — 유효하지 않은 주소)
0x00007FFFFFFFFFFF ┐
                   │  유저 공간 (128TB)
                   │  — 스택, 힙, mmap, 텍스트
0x0000000000000000 ┘
```

커널 공간은 모든 프로세스의 가상 주소 공간에 **동일하게 매핑**되어 있다.
syscall 진입 시 주소 공간을 교체하지 않고 커널 영역으로 점프만 한다.
(단, Meltdown 패치 이후 KPTI가 활성화되면 유저↔커널 전환 시 페이지 테이블 교체가 발생 — 뒤에서 설명)

---

## 3. Syscall 진입 메커니즘 — 하드웨어 수준

### 3.1 역사적 변천

| 시대 | 메커니즘 | 설명 |
|---|---|---|
| 초기 x86 | `int 0x80` | 소프트웨어 인터럽트, 느림 |
| Pentium II+ | `sysenter` / `sysexit` | Intel 전용 Fast Syscall |
| x86-64 | `syscall` / `sysret` | AMD64 표준, 현재 Linux 기본 |

### 3.2 `syscall` 명령어 실행 흐름 (x86-64)

```
유저 모드
  1. 레지스터에 인자 설정
     rax = syscall 번호
     rdi, rsi, rdx, r10, r8, r9 = 인자 1~6
  2. syscall 명령어 실행

CPU 하드웨어 동작 (원자적)
  3. rip(다음 명령어 주소)를 rcx에 저장
  4. rflags를 r11에 저장
  5. CS/SS를 커널 세그먼트로 교체 (Ring 3 → Ring 0)
  6. rip를 MSR_LSTAR에 저장된 커널 진입점으로 변경
     (MSR_LSTAR = entry_SYSCALL_64 함수 주소)

커널 모드
  7. entry_SYSCALL_64: 레지스터 저장, 스택 전환
  8. syscall 번호(rax)로 sys_call_table[] 인덱싱
  9. 해당 함수 호출 (예: sys_read)
 10. 반환값을 rax에 저장
 11. sysret 명령어 → Ring 3 복귀
```

```c
// 커널 소스: arch/x86/entry/entry_64.S (요약)
SYM_CODE_START(entry_SYSCALL_64):
    swapgs                          // GS 레지스터 교체 (percpu 접근용)
    movq %rsp, PER_CPU_VAR(cpu_tss_rw + TSS_sp2)
    movq PER_CPU_VAR(cpu_current_top_of_stack), %rsp  // 커널 스택으로 전환
    pushq ... 레지스터들 저장 (pt_regs 구조체)
    call do_syscall_64
```

### 3.3 syscall 번호 테이블

syscall 번호는 커널 버전과 아키텍처별로 고정되어 있다.

```bash
# syscall 번호 테이블 직접 확인
cat /usr/include/asm/unistd_64.h | grep "define __NR_" | head -20
# 또는
ausyscall --dump | head -20        # audit 패키지

# 주요 syscall 번호 (x86-64)
# 0  read
# 1  write
# 2  open
# 3  close
# 4  stat
# 5  fstat
# 6  lstat       ← du/find가 파일마다 호출하는 것
# 9  mmap
# 56 clone       ← fork의 실제 구현
# 59 execve
# 62 kill
```

```bash
# 현재 실행 중인 프로세스의 syscall 실시간 확인
strace -p $(pgrep du) 2>&1 | head -30
```

---

## 4. Syscall 비용의 구성 요소

### 4.1 비용 항목 분해

syscall 1회에 드는 비용은 단순히 함수 호출이 아니다.

```
┌─────────────────────────────────────────────────────┐
│ 순수 모드 전환 비용          ~100ns (캐시 워밍 상태) │
│ 레지스터 저장/복원           ~50ns                   │
│ 스택 전환 (유저→커널→유저)   ~30ns                   │
│ KPTI 페이지 테이블 교체      ~100~300ns (활성화 시)  │
│ 캐시 오염 (iTLB, L1i flush)  가변                    │
└─────────────────────────────────────────────────────┘
총합: 캐시 워밍 ~200ns / cold 상태 ~1000ns+
```

```bash
# syscall 왕복 비용 측정
# 가장 단순한 syscall인 getpid()로 측정
cat << 'EOF' > /tmp/syscall_bench.c
#include <unistd.h>
#include <time.h>
#include <stdio.h>
int main() {
    struct timespec t1, t2;
    int N = 1000000;
    clock_gettime(CLOCK_MONOTONIC, &t1);
    for (int i = 0; i < N; i++) getpid();
    clock_gettime(CLOCK_MONOTONIC, &t2);
    long ns = (t2.tv_sec - t1.tv_sec)*1e9 + (t2.tv_nsec - t1.tv_nsec);
    printf("syscall avg: %ld ns\n", ns / N);
}
EOF
gcc -O2 -o /tmp/syscall_bench /tmp/syscall_bench.c && /tmp/syscall_bench
# 일반 서버: ~50~150ns, KPTI 활성: ~200~400ns
```

### 4.2 KPTI (Kernel Page-Table Isolation) — Meltdown 패치의 비용

2018년 Meltdown 취약점 패치로 추가된 기법이다.
syscall 진입/복귀 시 **페이지 테이블 전체를 교체**해 커널 주소를 유저 공간에서 완전히 숨긴다.

```
KPTI 비활성 (구형 커널):
  유저 → 커널: 레지스터/스택 전환만
  커널 → 유저: 레지스터/스택 복원만

KPTI 활성 (Meltdown 패치 이후):
  유저 → 커널: CR3 레지스터 교체 (페이지 테이블 전환) + TLB flush
  커널 → 유저: CR3 교체 + TLB flush
  → syscall당 추가 ~100~300ns, TLB miss 급증
```

```bash
# KPTI 활성화 여부 확인
dmesg | grep -i kpti
cat /sys/devices/system/cpu/vulnerabilities/meltdown
# "Mitigation: PTI" 이면 KPTI 활성

# VM 환경에서는 비활성화 가능 (물리 호스트 분리된 경우)
# 커널 파라미터: nopti (주의: 보안 취약점 노출)
grep GRUB_CMDLINE /etc/default/grub
```

### 4.3 Spectre 패치 비용 (IBRS, IBPB, STIBP)

```bash
# 스펙터 완화 기법 확인
cat /sys/devices/system/cpu/vulnerabilities/spectre_v2
# "Mitigation: Enhanced IBRS, IBPB: conditional, RSB filling"

# 영향: indirect branch prediction 제한 → 함수 호출 오버헤드 증가
# syscall 핸들러 진입/복귀 시 IBPB 실행 → ~수십ns 추가
```

---

## 5. 핵심 Syscall 동작 원리

### 5.1 `read()` / `write()` 내부 흐름

```
write(fd, buf, n)
  │
  ▼ 커널 진입
sys_write(fd, buf, n)
  │
  ▼
ksys_write()
  │
  ▼
vfs_write()                          ← VFS 레이어 (추상화)
  │
  ├─ file->f_op->write()             ← 파일시스템별 함수 포인터
  │   (ext4_file_write_iter 등)
  │
  ▼
page cache                           ← 커널 페이지 캐시에 먼저 씀
  │
  ▼ (비동기)
block I/O 레이어 → 디바이스 드라이버 → 물리 디스크
```

`write()`는 페이지 캐시에 기록 후 즉시 반환한다 (`O_SYNC` 없으면).
실제 디스크 쓰기는 나중에 `pdflush` / `kworker`가 처리한다.

### 5.2 `lstat()` — du/find가 느린 핵심 이유

```
lstat("/data/file.txt", &statbuf)
  │
  ▼
sys_newlstat()
  │
  ▼
vfs_statx()
  │
  ├─ filename_lookup()               ← 경로 해석 (dentry 캐시 탐색)
  │   ├─ dentry 캐시 히트 → 빠름
  │   └─ dentry 캐시 미스 → 디스크에서 inode 읽기 → 느림
  │
  ├─ inode->i_op->getattr()          ← 파일시스템별 stat 구현
  │
  └─ statbuf에 결과 복사 (커널→유저 공간)
```

파일 100만 개 = `lstat()` 100만 번 = 경로 해석 100만 번.
dentry 캐시에 없으면 디스크 I/O까지 발생한다.

```bash
# dentry 캐시 히트율 확인
cat /proc/slabinfo | grep dentry
# active_objs: 현재 캐시된 dentry 수

# 캐시 미스로 인한 디스크 I/O 확인
perf stat -e cache-misses,cache-references du -sh /data 2>&1
```

### 5.3 `mmap()` vs `read()` — 제로카피 비교

```
# 전통적 read() 방식 — 2번 복사
디스크 → 커널 페이지 캐시 (DMA 복사)
커널 페이지 캐시 → 유저 버퍼 (CPU 복사)

# mmap() 방식 — 1번 복사 (또는 0번)
디스크 → 커널 페이지 캐시 (DMA 복사)
유저 프로세스의 가상 주소를 페이지 캐시에 직접 매핑
→ 복사 없이 페이지 캐시를 유저 공간에서 직접 접근
```

```c
// mmap 예시
int fd = open("file.bin", O_RDONLY);
struct stat st; fstat(fd, &st);
char *p = mmap(NULL, st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
// 이후 p[i]로 접근 시 page fault → 커널이 페이지 캐시에서 매핑
// read() 없이 직접 메모리처럼 접근
munmap(p, st.st_size);
```

### 5.4 `clone()` / `fork()` — 프로세스 생성 비용

```bash
# fork()는 내부적으로 clone() syscall
strace /bin/true 2>&1 | grep clone

# clone() 비용 요소:
# 1. 부모 프로세스 페이지 테이블 복사 (CoW 설정)
# 2. 파일 디스크립터 테이블 복사
# 3. 시그널 핸들러 테이블 복사
# 4. 새 PID 할당
# 5. 스케줄러에 등록

# 측정
time for i in $(seq 1 1000); do /bin/true; done
# 약 100~300us/fork (서버급 CPU 기준)
```

---

## 6. vDSO — Syscall 없이 커널 데이터 읽기

### 6.1 vDSO 개념

일부 syscall은 커널 진입 없이 유저 공간에서 처리할 수 있다.
커널이 **vDSO(virtual Dynamic Shared Object)** 를 프로세스 주소 공간에 매핑해 제공한다.

```bash
# 프로세스의 vDSO 매핑 확인
cat /proc/self/maps | grep vdso
# 7ffe8d5f2000-7ffe8d5f4000 r-xp  [vdso]

# vDSO가 제공하는 함수 목록
nm -D /proc/self/maps  # 직접 읽기 어려움
# 실제로는 ELF 파싱 필요
python3 -c "
import ctypes, ctypes.util
libc = ctypes.CDLL(None)
# clock_gettime은 vDSO를 통해 실행됨
"
```

### 6.2 vDSO를 사용하는 syscall

| Syscall | vDSO 여부 | 이유 |
|---|---|---|
| `clock_gettime()` | O | 커널이 타임스탬프를 공유 메모리에 주기적으로 업데이트 |
| `gettimeofday()` | O | 위와 동일 |
| `getcpu()` | O | percpu 데이터를 읽기만 하면 됨 |
| `getpid()` | X (libc 캐시) | libc가 내부적으로 캐싱 |
| `read()` | X | 실제 커널 개입 필요 |

```bash
# clock_gettime이 실제로 syscall을 안 쓰는지 확인
strace -e trace=clock_gettime date 2>&1 | grep clock_gettime
# 출력 없음 = vDSO를 통해 유저 공간에서 처리됨

# vDSO 없이 강제로 syscall 사용 (성능 비교용)
LD_PRELOAD="" strace -c date 2>&1
```

### 6.3 vDSO 동작 원리

```
커널:
  hpet_read_begin 등 타이머 하드웨어에서 시간 읽기
  → vvar 페이지(공유 읽기 전용 메모리)에 저장
  → 주기적으로 업데이트

유저 프로세스:
  clock_gettime() 호출
  → glibc가 vDSO 내 __vdso_clock_gettime() 호출
  → vvar 페이지를 직접 읽어 계산
  → syscall 없이 반환

비용: ~5ns (syscall 대비 ~40배 빠름)
```

---

## 7. Syscall 추적 및 분석 도구

### 7.1 strace 심층 사용

```bash
# syscall별 통계 요약
strace -c du -sh /data 2>&1
# % time  seconds  usecs/call  calls  syscall
# 99.1    5.234    5          1000000 lstat  ← 병목 확인

# 특정 syscall만 추적
strace -e trace=lstat,openat,getdents64 du -sh /data 2>&1 | head -50

# 타임스탬프 포함 (상대 시간)
strace -r -e trace=lstat ls /large-dir 2>&1 | head -20
# 0.000000 lstat("file1") = 0
# 0.000052 lstat("file2") = 0  ← 52us/lstat

# 자식 프로세스까지 추적
strace -f -e trace=clone,execve bash -c "ls /tmp" 2>&1

# 실행 중인 프로세스에 attach
strace -p $(pgrep nginx | head -1) -e trace=accept,read,write 2>&1
```

### 7.2 perf로 syscall 분석

```bash
# syscall 진입 횟수를 perf로 카운트
perf stat -e 'syscalls:sys_enter_*' -a sleep 5 2>&1 | sort -k1 -rn | head -20

# 특정 프로세스의 syscall 빈도
perf trace -p $(pgrep du) 2>&1 | head -50
# 출력: timestamp  syscall(args) = retval

# 가장 많이 호출되는 syscall top 10
perf trace -s -p $(pgrep nginx) sleep 5 2>&1
```

### 7.3 eBPF/bpftrace로 syscall 계측

```bash
# 특정 syscall의 지연 시간 분포 (히스토그램)
bpftrace -e '
tracepoint:syscalls:sys_enter_lstat { @start[tid] = nsecs; }
tracepoint:syscalls:sys_exit_lstat  /@start[tid]/ {
  @ns = hist(nsecs - @start[tid]);
  delete(@start[tid]);
}'
# 출력: 나노초 단위 레이턴시 히스토그램

# 프로세스별 syscall 카운트 실시간
bpftrace -e 'tracepoint:raw_syscalls:sys_enter { @[comm] = count(); }' &
sleep 5; kill %1

# 슬로우 syscall 탐지 (10ms 이상)
bpftrace -e '
tracepoint:syscalls:sys_enter_read { @start[tid] = nsecs; }
tracepoint:syscalls:sys_exit_read  /@start[tid] && (nsecs-@start[tid]) > 10000000/ {
  printf("slow read: %s %d ms\n", comm, (nsecs-@start[tid])/1000000);
  delete(@start[tid]);
}'
```

---

## 8. Syscall 최소화 기법

### 8.1 배치(batch) 처리

```c
// 나쁜 예 — 1바이트씩 read() 반복
for (int i = 0; i < 1000000; i++) {
    read(fd, &buf[i], 1);          // syscall 100만 번
}

// 좋은 예 — 한 번에 큰 블록으로 read()
read(fd, buf, 1000000);            // syscall 1번

// 파일 목록 처리: getdents64로 배치 읽기
// ls, find 등이 내부적으로 사용
struct linux_dirent64 buf[1024];
int n = syscall(SYS_getdents64, fd, buf, sizeof(buf));  // 한 번에 여러 엔트리
```

### 8.2 io_uring — 비동기 배치 syscall

```
전통 I/O 모델:
  유저 → syscall(read) → 대기 → 반환 → 유저 → syscall(read) → ...

io_uring 모델:
  유저 → 제출 큐(SQ)에 read 요청 다수 적재
       → io_uring_enter() 1번으로 일괄 제출   ← syscall 1번
       → 완료 큐(CQ)에서 결과 polling          ← syscall 없음
```

```bash
# io_uring 지원 확인
cat /proc/sys/kernel/io_uring_disabled   # 0이면 활성

# fio로 io_uring vs libaio 성능 비교
fio --name=test --ioengine=io_uring --iodepth=128 \
    --rw=randread --bs=4k --size=1G --filename=/tmp/test.img
fio --name=test --ioengine=libaio  --iodepth=128 \
    --rw=randread --bs=4k --size=1G --filename=/tmp/test.img
```

### 8.3 `sendfile()` — 제로카피 네트워크 전송

```c
// 나쁜 예 — 2번 syscall, 2번 복사
read(file_fd, buf, size);          // 디스크 → 유저 공간
write(socket_fd, buf, size);       // 유저 공간 → 네트워크 스택

// 좋은 예 — 1번 syscall, 0번 유저 공간 복사
sendfile(socket_fd, file_fd, NULL, size);
// 커널 내부: 페이지 캐시 → 네트워크 스택 (DMA gather)
// nginx의 정적 파일 서빙이 이 방식을 사용
```

### 8.4 epoll — 이벤트 기반 I/O 다중화

```
select() 방식:
  syscall(select, fd_set) → 커널이 모든 fd 순회 → O(n)
  → fd 수가 늘어날수록 syscall 비용 선형 증가

epoll 방식:
  syscall(epoll_create) → 커널에 관심 fd 등록
  syscall(epoll_wait)   → 준비된 fd만 반환 → O(1)
  → fd 수에 무관하게 일정한 비용
```

```bash
# nginx가 epoll을 사용하는지 확인
strace -p $(pgrep nginx | head -1) -e trace=epoll_wait 2>&1 | head -5
```

---

## 9. Seccomp — Syscall 필터링으로 보안 강화

### 9.1 동작 원리

```
프로세스가 syscall 실행
  → 커널 syscall 핸들러 진입 전
  → seccomp BPF 프로그램 실행
      ├─ ALLOW: 정상 실행
      ├─ ERRNO: 에러 반환 (프로세스 계속)
      ├─ KILL:  프로세스 강제 종료
      └─ TRACE: ptrace로 감사
```

```bash
# 프로세스의 seccomp 상태 확인
cat /proc/$(pgrep chrome | head -1)/status | grep Seccomp
# Seccomp: 2  (2=filter 모드, 1=strict, 0=없음)

# Docker 컨테이너의 기본 seccomp 프로파일
docker inspect --format='{{.HostConfig.SecurityOpt}}' <container>

# 허용된 syscall 목록 확인 (Docker 기본 프로파일)
# /etc/docker/seccomp.json 또는
# https://github.com/moby/moby/blob/master/profiles/seccomp/default.json
```

```bash
# 커스텀 seccomp 프로파일로 컨테이너 실행
cat > /tmp/seccomp.json << 'EOF'
{
  "defaultAction": "SCMP_ACT_ERRNO",
  "syscalls": [
    {"names": ["read","write","exit","exit_group","close",
               "fstat","mmap","mprotect","munmap","brk"],
     "action": "SCMP_ACT_ALLOW"}
  ]
}
EOF
docker run --security-opt seccomp=/tmp/seccomp.json alpine ls
```

---

## 10. 실무 시나리오별 syscall 분석

### 10.1 `du -sh /data` (파일 100만 개)

```bash
strace -c du -sh /data 2>&1
# 예상 결과:
# calls   syscall
# 1000000 lstat           ← 파일마다 1회
# 10000   getdents64      ← 디렉토리마다 1~N회 (버퍼 크기에 따라)
# 10000   openat          ← 디렉토리 열기
# 10000   close           ← 디렉토리 닫기

# 최적화 방향:
# - dentry 캐시가 워밍되어 있으면 lstat은 메모리 접근만 → 빠름
# - 첫 실행(cold cache)은 inode 읽기 = 디스크 I/O → 느림
```

### 10.2 `chown -R user:group /data`

```bash
strace -c chown -R user:group /data 2>&1
# calls     syscall
# 2000000   fchownat    ← 파일마다 1회 (lstat 대신 직접 chown)
# 1000000   lstat       ← 현재 소유자 확인용
# 1000000   openat/close

# 저널 쓰기 확인
iostat -x 1 &
chown -R user:group /data
# w/s 급증 확인 — inode 변경마다 저널 기록
```

### 10.3 웹 서버 요청 처리 (nginx)

```
클라이언트 연결 → accept4()          # 1회
헤더 읽기      → read()              # 1~N회
파일 stat      → stat() / fstat()    # 1회
파일 전송      → sendfile()          # 1회 (제로카피)
연결 유지      → epoll_wait()        # 다음 요청 대기

총 syscall ~5회/요청 (캐시 히트 시)
```

---

## 11. 자주 하는 실수

| 실수 | 올바른 방법 |
|---|---|
| `strace`를 운영 프로세스에 attach해서 성능 측정 | strace 자체가 ptrace로 모든 syscall을 인터셉트 → 최대 10배 느려짐. 운영 환경은 `perf trace` 또는 eBPF 사용 |
| syscall 수만 보고 병목 판단 | 호출 수가 아니라 **총 시간(seconds)**과 **usecs/call** 을 함께 봐야 함 |
| `read()` 루프를 작은 단위로 반복 | 버퍼를 크게 잡아 syscall 횟수 최소화 |
| fork()가 빠르다고 가정하고 과도하게 사용 | 파일 수백만 개 처리 시 fork 오버헤드보다 스레드/async가 유리 |
| vDSO 함수를 syscall이라고 strace에서 안 보인다고 오해 | `clock_gettime` 등은 vDSO → strace에 안 잡힘. `ltrace` 또는 perf 사용 |
| seccomp 없이 컨테이너 운영 | 기본 Docker seccomp 프로파일 반드시 활성화 확인 |
