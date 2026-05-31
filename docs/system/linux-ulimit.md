# linux-ulimit.md — 프로세스 리소스 제한

## 1. 개요

`ulimit`은 쉘 세션과 그 자식 프로세스가 사용할 수 있는 리소스(파일 디스크립터, 스택 크기, 코어 덤프 등)의 상한선을 설정한다. 프로덕션에서 "Too many open files", "Cannot allocate memory" 에러의 원인 대부분이 ulimit 미설정이다. SRE 관점에서 서비스 배포 시 반드시 확인해야 하는 항목이다.

---

## 2. 설명

### 2.1 현재 제한값 확인

```bash
# 현재 쉘의 모든 제한값 출력
ulimit -a

# 자주 확인하는 항목별 조회
ulimit -n    # 오픈 파일 디스크립터 수 (nofile)
ulimit -u    # 최대 프로세스/스레드 수 (nproc)
ulimit -s    # 스택 크기 (stack, KB)
ulimit -c    # 코어 덤프 크기 (0=비활성)
ulimit -m    # 최대 메모리 크기 (RSS)
ulimit -v    # 가상 메모리 크기

# 특정 프로세스의 실제 적용값 확인 (PID 지정)
cat /proc/<PID>/limits
```

### 2.2 소프트/하드 한도 구분

```bash
# 소프트 한도 (soft): 현재 적용값, 프로세스가 스스로 높일 수 있음
ulimit -Sn

# 하드 한도 (hard): 소프트 한도의 상한, root만 높일 수 있음
ulimit -Hn

# 소프트/하드 동시 설정
ulimit -n 65536          # 현재 세션에만 적용

# 특정 프로세스의 소프트/하드 확인
cat /proc/$(pgrep nginx | head -1)/limits | grep "open files"
```

### 2.3 영구 적용: /etc/security/limits.conf

```bash
# /etc/security/limits.conf
# <domain>   <type>   <item>    <value>
*            soft     nofile    65536      # 모든 사용자, 소프트
*            hard     nofile    65536      # 모든 사용자, 하드
myapp        soft     nofile    100000     # myapp 계정
myapp        hard     nofile    100000
myapp        soft     nproc     32768      # 스레드/프로세스 수
myapp        hard     nproc     32768

# 코어 덤프 활성화 (디버깅 환경)
*            soft     core      unlimited
*            hard     core      unlimited
```

```bash
# /etc/security/limits.d/ 디렉토리에 서비스별 분리 관리 (권장)
cat /etc/security/limits.d/myapp.conf
# myapp soft nofile 100000
# myapp hard nofile 100000
```

> **주의**: `limits.conf` 변경 후 새 세션을 열어야 적용된다. 실행 중인 프로세스에는 즉시 반영되지 않는다.

### 2.4 systemd 서비스의 ulimit 설정

systemd 서비스는 PAM 세션을 거치지 않아 `limits.conf`가 적용되지 않는다. 유닛 파일에 직접 설정해야 한다.

```ini
# /etc/systemd/system/myapp.service
[Service]
LimitNOFILE=100000      # nofile (파일 디스크립터)
LimitNPROC=32768        # nproc (스레드/프로세스)
LimitCORE=infinity      # core dump 무제한
LimitSTACK=8388608      # stack 8MB
LimitMEMLOCK=infinity   # mlock (HugePage, DPDK 등)
```

```bash
# 변경 후 리로드
systemctl daemon-reload
systemctl restart myapp

# 적용 확인
cat /proc/$(systemctl show --property=MainPID --value myapp)/limits
```

### 2.5 커널 전역 제한 조정

ulimit은 프로세스별 제한이지만, 커널 전역 최대값도 함께 확인해야 한다.

```bash
# 시스템 전체 오픈 파일 수 한도
cat /proc/sys/fs/file-max
sysctl fs.file-max

# 현재 시스템 전체 오픈 파일 수 (used/free/max)
cat /proc/sys/fs/file-nr

# 커널 전역 최대값 영구 설정
echo "fs.file-max = 2000000" >> /etc/sysctl.d/99-limits.conf
sysctl -p /etc/sysctl.d/99-limits.conf

# 최대 프로세스 수 (커널 전역)
cat /proc/sys/kernel/pid_max
sysctl kernel.pid_max
```

### 2.6 장애 시나리오별 진단

#### "Too many open files" (EMFILE / ENFILE)

```bash
# 1) 현재 노드 전체 오픈 파일 수
lsof | wc -l
cat /proc/sys/fs/file-nr    # 사용중/여유/최대

# 2) 프로세스별 오픈 파일 수 상위 10개
lsof -n 2>/dev/null | awk '{print $2}' | sort | uniq -c | sort -rn | head -10

# 3) 특정 프로세스 fd 수
ls /proc/<PID>/fd | wc -l

# 4) ulimit 현재값 vs 사용량 비교
PID=$(pgrep myapp | head -1)
echo "Limit: $(cat /proc/$PID/limits | grep 'open files' | awk '{print $4}')"
echo "Used:  $(ls /proc/$PID/fd | wc -l)"
```

#### "fork: retry: Resource temporarily unavailable" (EAGAIN)

```bash
# nproc 한도 초과 — 스레드 수 확인
PID=$(pgrep java | head -1)
cat /proc/$PID/status | grep Threads

# 시스템 전체 스레드 수
ps -eLf | wc -l

# 커널 전역 thread-max
cat /proc/sys/kernel/threads-max
```

#### 코어 덤프 생성 안 됨

```bash
# 코어 덤프 경로 확인
cat /proc/sys/kernel/core_pattern

# systemd-coredump 사용 여부 확인
cat /proc/sys/kernel/core_pattern | grep systemd

# 코어 덤프 활성화 (테스트/디버그 환경)
ulimit -c unlimited
echo "/tmp/core.%e.%p" > /proc/sys/kernel/core_pattern
```

### 2.7 컨테이너 환경의 ulimit

Docker와 Kubernetes는 컨테이너 내부 ulimit을 별도로 제어한다.

```bash
# Docker: 기본 ulimit 오버라이드
docker run --ulimit nofile=100000:100000 myimage

# Docker daemon 기본값 설정 (/etc/docker/daemon.json)
{
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 65536,
      "Soft": 65536
    }
  }
}
```

```yaml
# Kubernetes: Pod 스펙 (initContainers로 sysctls 설정)
# ulimit은 securityContext로 직접 설정 불가 — 컨테이너 런타임에 위임됨
# 호스트 노드의 limits.conf 또는 docker daemon 설정이 상속됨
spec:
  containers:
  - name: myapp
    securityContext:
      runAsUser: 1000
    # DaemonSet 형태의 init 컨테이너로 노드 설정을 변경하는 패턴 사용
```

### 2.8 Ansible로 ulimit 일괄 적용

```yaml
- name: Set file descriptor limits for myapp
  pam_limits:
    domain: myapp
    limit_type: "{{ item.type }}"
    limit_item: nofile
    value: "{{ item.value }}"
  loop:
    - { type: soft, value: 100000 }
    - { type: hard, value: 100000 }

- name: Set systemd service limits
  lineinfile:
    path: /etc/systemd/system/myapp.service
    insertafter: '^\[Service\]'
    line: "{{ item }}"
  loop:
    - "LimitNOFILE=100000"
    - "LimitNPROC=32768"
  notify: Reload systemd
```

---

## 3. 자주 하는 실수

| 실수 | 올바른 방법 |
|------|------------|
| `limits.conf` 설정 후 즉시 적용 기대 | 새 세션(SSH 재접속)을 열어야 적용됨 |
| systemd 서비스에 `limits.conf`가 적용된다고 착각 | 유닛 파일에 `LimitNOFILE=` 직접 명시 |
| 소프트 한도만 올리고 하드 한도는 그대로 | 소프트 ≤ 하드, 둘 다 일치시키는 것이 안전 |
| `ulimit -n` 직접 확인 안 하고 설정만 믿음 | `/proc/<PID>/limits`로 실제 적용값 검증 |
| `fs.file-max` 조정 없이 nofile만 올림 | 커널 전역 한도도 함께 상향 조정 |
| 컨테이너에서 호스트 ulimit 무시하고 설정 시도 | Docker 데몬 기본값 또는 `--ulimit` 플래그 활용 |
| 코어 덤프 `/` 루트에 생성 → 디스크 풀 | `core_pattern`으로 별도 파티션 또는 `/tmp` 지정 |
