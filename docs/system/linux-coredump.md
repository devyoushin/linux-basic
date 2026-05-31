# Core Dump와 충돌 분석 - 프로세스 사망 원인 규명

## 1. 개요

Core dump는 프로세스가 비정상 종료될 때 해당 시점의 메모리 상태, CPU 레지스터, 스택 트레이스를 파일로 저장한 것이다. Segfault, abort, bus error 같은 치명적 시그널을 받으면 커널이 core 파일을 생성하며, gdb로 이 파일을 분석해 어떤 코드의 어떤 라인에서 충돌이 발생했는지 규명할 수 있다. 프로덕션 환경에서의 충돌 분석, 재현 불가능한 버그 추적, 메모리 손상 탐지에 필수적인 기법이다.

---

## 2. Core Dump 생성 원리

### 2.1 시그널과 core dump 트리거

```
시그널 수신 → 커널 시그널 처리기 → core dump 여부 결정

Core dump를 생성하는 시그널:
  SIGSEGV (11): Segmentation Fault - 잘못된 메모리 접근
  SIGABRT  (6): Abort - assert() 실패, abort() 호출
  SIGBUS   (7): Bus Error - 정렬되지 않은 메모리 접근
  SIGFPE   (8): Floating Point Exception - 0으로 나누기
  SIGILL   (4): Illegal Instruction - 잘못된 CPU 명령
  SIGQUIT  (3): Quit - 사용자가 Ctrl+\ 입력

Core dump를 생성하지 않는 시그널:
  SIGKILL (9): 즉시 종료 (core 없음)
  SIGTERM (15): 정상 종료 요청 (core 없음)
```

### 2.2 core dump 활성화 조건

```
생성 조건:
  1. ulimit -c > 0  (프로세스의 core 파일 크기 한도)
  2. 디렉토리 쓰기 권한 존재
  3. /proc/sys/kernel/core_pattern에 지정된 경로

  →  하나라도 충족 안 되면 core dump 생성 안 됨!
```

```bash
# 현재 core 파일 크기 한도 확인
ulimit -c
# 0  ← 대부분의 배포판 기본값: 생성 안 됨

# 무제한으로 활성화 (현재 세션)
ulimit -c unlimited

# 영구 설정 (/etc/security/limits.conf)
echo '* soft core unlimited' >> /etc/security/limits.conf
echo '* hard core unlimited' >> /etc/security/limits.conf

# systemd 서비스에서 core 활성화
# /etc/systemd/system/myapp.service
# [Service]
# LimitCORE=infinity

# core 파일 저장 경로 및 이름 패턴 확인
cat /proc/sys/kernel/core_pattern
# /tmp/core-%e-%p-%t
# %e: 실행파일명, %p: PID, %t: timestamp, %s: 시그널번호
```

### 2.3 core_pattern 설정

```bash
# 기본 설정: 현재 디렉토리에 'core' 파일 생성
echo 'core' > /proc/sys/kernel/core_pattern

# 경로와 이름 패턴 지정 (권장)
echo '/var/coredumps/core-%e-%p-%t' > /proc/sys/kernel/core_pattern

# 디렉토리 생성 및 권한 설정
mkdir -p /var/coredumps
chmod 1777 /var/coredumps           # sticky bit: 누구나 쓰기 가능, 본인 파일만 삭제 가능

# 영구 설정
cat >> /etc/sysctl.conf <<'EOF'
kernel.core_pattern = /var/coredumps/core-%e-%p-%t
kernel.core_uses_pid = 1
EOF
sysctl -p
```

---

## 3. systemd-coredump (coredumpctl)

현대적인 배포판(RHEL 8+, Ubuntu 20.04+)은 systemd-coredump가 core 파일을 자동 수집하고 압축하여 journal에 연동한다.

### 3.1 coredumpctl 사용법

```bash
# core dump 목록 확인
coredumpctl list
# TIME                            PID  UID  GID SIG COREFILE  EXE
# Mon 2024-01-15 03:22:11 UTC   12345 1000 1000  11 present   /usr/bin/myapp

# 최근 core dump 정보 확인
coredumpctl info
coredumpctl info 12345            # 특정 PID

# core dump 파일 추출 (gdb 분석용)
coredumpctl dump 12345 -o /tmp/myapp.core

# gdb로 직접 연동 (core 파일 추출 없이)
coredumpctl gdb 12345

# systemd-coredump 설정 파일
cat /etc/systemd/coredump.conf
# [Coredump]
# Storage=external          # journal 외부 파일로 저장
# Compress=yes              # gzip 압축
# ProcessSizeMax=2G         # core 파일 최대 크기
# ExternalSizeMax=2G
# KeepFree=1G               # 디스크 여유 공간 최소 유지
```

---

## 4. gdb로 Core 파일 분석

### 4.1 기본 분석 플로우

```bash
# gdb로 core 파일 열기
# gdb <실행파일> <core파일>
gdb /usr/bin/myapp /var/coredumps/core-myapp-12345-1705284131

# > **주의**: 정확한 분석을 위해 충돌 당시와 동일한 바이너리가 필요하다.
# 프로덕션 배포 시 바이너리와 디버그 심볼을 함께 보존해야 한다.
```

```gdb
# gdb 내부 명령어

# 충돌 위치 확인 (가장 먼저 실행)
(gdb) bt
# #0  0x00007f1234567890 in parse_request (req=0x0) at src/parser.c:42
# #1  0x00007f1234567a00 in handle_connection (conn=0x55a1b2c3d4e0) at src/server.c:128
# #2  0x00007f1234567b00 in worker_thread (arg=0x55a1b2c3d4e0) at src/worker.c:85
# #3  0x00007f9876543210 in start_thread ()
# #4  0x00007f9876543abc in clone ()

# 특정 프레임으로 이동
(gdb) frame 0                   # 최상위 프레임 (충돌 지점)
(gdb) frame 1                   # 호출한 함수

# 현재 프레임의 지역 변수 확인
(gdb) info locals
# req = 0x0                     ← NULL 포인터! 역참조 시 SIGSEGV
# buffer_size = 4096

# 특정 변수 출력
(gdb) print req
# $1 = (request_t *) 0x0        ← NULL

# 전역 변수 확인
(gdb) info variables
(gdb) print global_config

# 메모리 덤프 (x 명령어)
# x/<개수><형식><단위> <주소>
(gdb) x/16xw 0x55a1b2c3d4e0    # 16개 워드를 16진수로 출력
(gdb) x/s 0x55a1b2c3d500       # 문자열로 출력

# 레지스터 확인
(gdb) info registers
# rip = 0x00007f1234567890 ← 충돌 시점 명령어 포인터
# rsp = 0x00007fff12345678 ← 스택 포인터

# 모든 스레드 백트레이스 (멀티스레드 프로그램)
(gdb) thread apply all bt

# 특정 스레드로 전환
(gdb) info threads
(gdb) thread 3

# 종료
(gdb) quit
```

### 4.2 디버그 심볼 없을 때

```bash
# 바이너리에 심볼 정보가 없는 경우 (stripped)
# 별도 debuginfo 패키지 설치 (RHEL/CentOS)
debuginfo-install myapp

# Ubuntu: dbgsym 패키지
apt-get install myapp-dbgsym

# 심볼 파일 수동 지정
(gdb) symbol-file /path/to/myapp.debug
(gdb) set solib-search-path /path/to/libs/

# addr2line으로 주소 → 소스 변환
addr2line -e /usr/bin/myapp 0x7f1234567890
# src/parser.c:42
```

---

## 5. kdump - 커널 패닉 vmcore 캡처

kdump는 커널 패닉 시 두 번째 커널을 부팅하여 충돌한 첫 번째 커널의 메모리 덤프(vmcore)를 캡처한다.

### 5.1 kdump 설정

```
kdump 동작 원리:
  부팅 시: 예약 메모리(crashkernel)에 capture kernel 미리 로드
  커널 패닉 발생 → kexec로 capture kernel로 즉시 전환
  capture kernel → 충돌 메모리를 /var/crash/에 vmcore로 저장
  → 재부팅 또는 지정 동작 수행
```

```bash
# kdump 설치
yum install -y kexec-tools        # RHEL/CentOS
apt-get install -y kdump-tools    # Ubuntu

# 커널 파라미터에 crashkernel 예약 메모리 추가
# /etc/default/grub:
# GRUB_CMDLINE_LINUX="crashkernel=auto"  # 자동 계산
# 또는 명시적:
# GRUB_CMDLINE_LINUX="crashkernel=256M"

grub2-mkconfig -o /boot/grub2/grub.cfg
reboot

# kdump 서비스 활성화
systemctl enable --now kdump

# kdump 상태 확인
kdumpctl status
# kdump operational

# vmcore 저장 경로 확인
cat /etc/kdump.conf | grep path
# path /var/crash
```

### 5.2 crash 유틸리티로 vmcore 분석

```bash
# crash 설치
yum install -y crash

# vmcore 분석 (커널 디버그 심볼 필요)
crash /usr/lib/debug/lib/modules/$(uname -r)/vmlinux \
      /var/crash/127.0.0.1-2024-01-15-03:22:11/vmcore

# crash 내부 명령어
crash> bt                         # 패닉 발생 스택 트레이스
crash> log                        # 커널 dmesg 버퍼
crash> ps                         # 패닉 시점 프로세스 목록
crash> vm <pid>                   # 프로세스 가상 메모리 맵
crash> files <pid>                # 프로세스 열린 파일
crash> sys                        # 시스템 정보 (커널 버전, 패닉 메시지)

# OOM killer로 인한 패닉 확인
crash> log | grep -i oom
# Out of memory: Kill process 1234 (myapp) score 900 or sacrifice child
```

---

## 6. AWS EC2에서 Core Dump 수집

### 6.1 S3 업로드 패턴

```bash
# core_pattern을 파이프로 설정하여 수집 스크립트 실행
# | 로 시작하면 core 데이터를 해당 프로그램의 stdin으로 전달

cat > /usr/local/bin/core-collector.sh <<'EOF'
#!/bin/bash
# stdin으로 core 데이터 수신
# 인자: %e(실행파일) %p(PID) %t(timestamp)

EXEC_NAME="$1"
PID="$2"
TIMESTAMP="$3"
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
S3_BUCKET="my-coredumps-bucket"
CORE_FILE="/tmp/core-${EXEC_NAME}-${PID}-${TIMESTAMP}"

# stdin에서 core 데이터 읽어서 파일로 저장
cat > "$CORE_FILE"

# gzip 압축 후 S3 업로드
gzip "$CORE_FILE"
aws s3 cp "${CORE_FILE}.gz" \
    "s3://${S3_BUCKET}/${INSTANCE_ID}/core-${EXEC_NAME}-${PID}-${TIMESTAMP}.gz"

# 로컬 파일 정리
rm -f "${CORE_FILE}.gz"
EOF

chmod +x /usr/local/bin/core-collector.sh

# core_pattern에 파이프 스크립트 등록
echo '|/usr/local/bin/core-collector.sh %e %p %t' > /proc/sys/kernel/core_pattern

# 영구 설정
cat >> /etc/sysctl.conf <<'EOF'
kernel.core_pattern = |/usr/local/bin/core-collector.sh %e %p %t
EOF
```

### 6.2 EC2 IAM 역할 설정 (Terraform)

```hcl
# main.tf
resource "aws_iam_role_policy" "core_dump_s3" {
  name = "core-dump-s3-upload"
  role = aws_iam_role.ec2_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "arn:aws:s3:::my-coredumps-bucket/*"
      }
    ]
  })
}

resource "aws_s3_bucket_lifecycle_configuration" "core_dumps" {
  bucket = "my-coredumps-bucket"

  rule {
    id     = "expire-old-cores"
    status = "Enabled"

    expiration {
      days = 30          # 30일 후 자동 삭제
    }
  }
}
```

---

## 7. 컨테이너 내부 Core Dump 설정

### 7.1 컨테이너의 core_pattern 문제

```
문제:
  컨테이너 내부에서 /proc/sys/kernel/core_pattern 변경 불가
  (네임스페이스 격리: kernel.core_pattern은 호스트 네임스페이스에서만 설정)

해결:
  호스트의 core_pattern을 컨테이너 친화적으로 설정
  또는 systemd-coredump 활용
```

```bash
# 호스트에서 core_pattern 설정 (컨테이너 포함 모든 프로세스에 적용)
echo '/var/coredumps/core-%e-%p-%t' > /proc/sys/kernel/core_pattern

# Kubernetes Pod에서 core dump 수집
# hostPath 볼륨으로 호스트 디렉토리를 컨테이너에 마운트
```

```yaml
# kubernetes/core-dump-pod.yaml
apiVersion: v1
kind: Pod
spec:
  initContainers:
  - name: set-core-pattern
    image: busybox
    command: ["/bin/sh", "-c"]
    args:
    - echo '/var/coredumps/core-%e-%p-%t' > /proc/sys/kernel/core_pattern
    securityContext:
      privileged: true          # core_pattern 변경에 필요
    volumeMounts:
    - name: host-proc
      mountPath: /proc/sys/kernel

  containers:
  - name: myapp
    image: myapp:latest
    securityContext:
      capabilities:
        add: ["SYS_PTRACE"]     # gdb 디버깅에 필요
    volumeMounts:
    - name: coredumps
      mountPath: /var/coredumps
    resources:
      limits:
        ephemeral-storage: "10Gi"    # core 파일 공간 확보

  volumes:
  - name: coredumps
    hostPath:
      path: /var/coredumps
      type: DirectoryOrCreate
  - name: host-proc
    hostPath:
      path: /proc/sys/kernel
```

```bash
# 컨테이너 실행 시 ulimit 설정
docker run \
  --ulimit core=-1                   # core dump 무제한 활성화 (-1 = unlimited)
  -v /var/coredumps:/var/coredumps \
  myapp:latest
```

---

## 8. Segfault 로그 해석

### 8.1 커널 로그 패턴 분석

```bash
# dmesg 또는 /var/log/messages에서 segfault 로그 확인
dmesg | grep segfault
# [1234567.890] myapp[12345]: segfault at 0 ip 00007f1234567890 sp 00007fff12345678 error 4 in myapp[400000+a000]

# 로그 항목 분석:
# myapp[12345]  : 프로세스명[PID]
# segfault at 0 : 접근하려 한 주소 (0 = NULL 포인터 역참조)
# ip 00007f...  : 충돌 시점의 instruction pointer (어떤 코드가 실행 중이었나)
# sp 00007fff.. : 스택 포인터
# error 4       : 오류 코드 (비트 플래그)
#   bit 0: 0=페이지 없음, 1=보호 위반
#   bit 1: 0=읽기, 1=쓰기
#   bit 2: 0=커널모드, 1=사용자모드
#   error 4 = 100b → 사용자모드에서 없는 페이지에 읽기 접근
# in myapp[...]  : 어떤 모듈에서 발생 (바이너리 또는 공유라이브러리)

# error 코드 해석 예시:
# error 4: 사용자모드, 읽기, 없는 페이지 (NULL 역참조)
# error 6: 사용자모드, 쓰기, 없는 페이지 (NULL 포인터에 쓰기)
# error 7: 사용자모드, 쓰기, 보호 위반 (읽기전용 메모리에 쓰기)
```

### 8.2 ip 주소로 소스 코드 위치 찾기

```bash
# ip 주소에서 공유 라이브러리 오프셋 계산
# "in myapp[400000+a000]" → 베이스 주소 0x400000
# ip 0x00007f1234567890

# addr2line으로 소스 위치 확인
BINARY_BASE=0x400000
IP_ADDRESS=0x00007f1234567890
OFFSET=$((IP_ADDRESS - BINARY_BASE))

addr2line -e /usr/bin/myapp -f $OFFSET
# parse_request
# src/parser.c:42

# 또는 gdb로 바로 확인
gdb /usr/bin/myapp
(gdb) info symbol 0x00007f1234567890
# parse_request + 42 in section .text
```

---

## 9. 자주 하는 실수

| 실수 | 원인 | 올바른 방법 |
|------|------|-------------|
| core dump가 생성 안 됨 | `ulimit -c` 가 0 | `/etc/security/limits.conf`와 systemd `LimitCORE=infinity` 모두 설정 |
| 빈 core 파일 생성 | 디스크 공간 부족 또는 크기 제한 | `/var/coredumps` 용량 확보, `ulimit -c unlimited` 확인 |
| gdb 분석에서 심볼 없음 | 배포 시 `-g` 플래그 미포함 또는 strip | 별도 `.debug` 파일 보관 또는 debuginfo 패키지 설치 |
| 컨테이너 내부에서 core_pattern 변경 | 네임스페이스 격리 | 호스트에서 core_pattern 설정, 컨테이너는 hostPath 볼륨 사용 |
| segfault 로그 없이 프로세스 종료 | SIGKILL로 종료 (core 없음) | SIGKILL과 다른 시그널 구분, `journalctl` 또는 dmesg 확인 |
| 재현 불가 충돌 미대비 | core dump 미설정 | 프로덕션에서도 core dump 활성화 + S3 자동 업로드 파이프라인 구성 |
| kdump crashkernel 미예약 | GRUB 설정 누락 | 커널 패닉 분석이 필요한 서버에 `crashkernel=auto` 추가 |
| core 파일 디스크 풀 | 대용량 core 파일 누적 | core_pattern 파이프로 압축 후 S3 저장, 로컬 파일 즉시 삭제 |
