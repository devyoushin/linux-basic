## 1. 개요

리눅스 메모리 구조를 모르면 `free -h`의 숫자를 잘못 해석해 불필요한 조치를 하거나,
OOM Killer가 왜 특정 프로세스를 죽였는지 이해하지 못한다.
가상 메모리, 페이지 캐시, RSS/VSZ 차이, Swap 동작 원리를 이해하면 메모리 관련 장애를 정확히 진단할 수 있다.

---

## 2. 가상 메모리(Virtual Memory) 개념

### 2.1 가상 주소 공간

모든 프로세스는 독립적인 **가상 주소 공간**을 가진다. OS(커널)가 가상 주소 → 물리 주소를 매핑(페이지 테이블)한다.

```
프로세스 A                    프로세스 B
가상 주소 0x1000 ──→ 물리 0x5000    가상 주소 0x1000 ──→ 물리 0x8000
가상 주소 0x2000 ──→ 물리 0x6000    가상 주소 0x2000 ──→ (Swap 공간)

→ 각 프로세스는 자신이 메모리 전체를 쓰는 것처럼 착각
→ 프로세스 간 메모리 격리 (한 프로세스가 다른 프로세스 메모리 접근 불가)
```

### 2.2 VSZ vs RSS

```
┌─────────────────────────────────────────┐
│           가상 주소 공간 (VSZ)            │  ← 프로세스가 요청한 전체
│  ┌──────────────────┐                   │
│  │  실제 물리 메모리  │ ← RSS             │  ← 실제로 RAM에 올라온 것
│  │  (Resident Set)  │                   │
│  └──────────────────┘                   │
│  ┌──────────┐  ┌────────┐               │
│  │   Swap   │  │ 미사용  │               │  ← 아직 안 쓴 공간
│  └──────────┘  └────────┘               │
└─────────────────────────────────────────┘
```

| 항목 | 의미 | 특징 |
|---|---|---|
| **VSZ** (Virtual Size) | 프로세스가 예약한 가상 메모리 | 실제 사용보다 훨씬 클 수 있음 |
| **RSS** (Resident Set Size) | 실제 RAM에 올라온 메모리 | 물리 메모리 실사용량 |
| **SHR** (Shared) | 다른 프로세스와 공유하는 메모리 | 공유 라이브러리, 공유 메모리 |

```bash
# ps에서 확인 (단위: KB)
ps aux | awk 'NR==1 || /nginx/ {print $2, $4, $5, $6, $11}'
# PID  %MEM  VSZ    RSS   COMMAND
# 1234  0.5  102400  8192  nginx: worker

# 더 자세한 메모리 분류
cat /proc/<PID>/status | grep -E "Vm|Rss"
# VmPeak:  102400 kB  ← 최대 가상 메모리
# VmSize:   98304 kB  ← 현재 가상 메모리 (VSZ)
# VmRSS:     8192 kB  ← 현재 RSS
# VmSwap:    1024 kB  ← Swap으로 내려간 양
```

---

## 3. 페이지 캐시 (Page Cache)

리눅스는 **남는 RAM을 파일 캐시로 적극 활용**한다. `free -h`에서 "used"가 많아도 panic할 필요 없는 이유가 여기 있다.

### 3.1 페이지 캐시의 동작

```
파일 읽기 흐름:
  1. 프로세스가 파일 read() 요청
  2. 커널이 페이지 캐시 확인
     - 캐시 히트: RAM에서 즉시 반환 (매우 빠름)
     - 캐시 미스: 디스크에서 읽어 페이지 캐시에 저장 후 반환
  3. 이후 같은 파일 읽기: 디스크 접근 없이 RAM에서 반환

→ 자주 읽는 파일은 자동으로 RAM에 캐시됨
→ 프로세스가 메모리 요청하면 캐시를 비워서 줌 (자동 관리)
```

### 3.2 free 명령어 제대로 읽기

```bash
free -h

#               total    used    free   shared  buff/cache  available
# Mem:           15Gi    4.2Gi   1.1Gi   512Mi    10.2Gi     10.5Gi
# Swap:           2Gi      0Bi   2Gi

# 잘못된 해석: used 4.2G, free 1.1G → "메모리가 거의 없다" (X)
# 올바른 해석: available 10.5G → "실제로 사용 가능한 메모리 10.5G" (O)
```

| 컬럼 | 의미 |
|---|---|
| `total` | 전체 물리 메모리 |
| `used` | 프로세스 + 커널이 사용 중 |
| `free` | 아무것도 안 쓰는 순수 빈 메모리 |
| `buff/cache` | 페이지 캐시 + 버퍼 (필요하면 즉시 해제 가능) |
| **`available`** | **실제로 애플리케이션이 쓸 수 있는 양 (가장 중요)** |

```
available = free + (회수 가능한 buff/cache 일부)
"available이 0에 가까울 때" 실제 메모리 부족
```

### 3.3 페이지 캐시 확인 및 정리

```bash
# 페이지 캐시 상세 확인
cat /proc/meminfo | grep -E "MemTotal|MemFree|MemAvailable|Cached|Buffers|Dirty"
# MemTotal:    16384000 kB
# MemFree:      1100000 kB
# MemAvailable: 10500000 kB
# Buffers:       300000 kB   ← 블록 디바이스 I/O 버퍼
# Cached:       9900000 kB   ← 파일 페이지 캐시
# Dirty:          50000 kB   ← 아직 디스크에 쓰지 않은 수정된 페이지

# 페이지 캐시 강제 해제 (부하 테스트 등 캐시 효과 제거 목적)
# 프로덕션에서 함부로 실행 금지 - 이후 I/O 폭증
sync   # 먼저 dirty 페이지를 디스크에 씀
echo 3 > /proc/sys/vm/drop_caches   # 1=pagecache, 2=dentry/inode, 3=모두
```

---

## 4. Swap

RAM이 부족할 때 잘 안 쓰는 메모리 페이지를 디스크(Swap 공간)로 내보내는 메커니즘.

### 4.1 Swap 동작

```
RAM 부족 시:
  1. 커널이 오랫동안 접근 안 한 페이지 선택
  2. 디스크 Swap 공간에 기록
  3. 해당 RAM 페이지를 다른 용도로 사용
  4. 나중에 그 페이지 접근 시 → Page Fault → 다시 RAM으로 로드

문제:
  RAM 접근: ~100ns
  SSD Swap: ~100μs (1000배 느림)
  HDD Swap: ~10ms  (100000배 느림)
→ 심한 Swap = 시스템 응답 매우 느려짐 ("스와핑 현상")
```

### 4.2 Swap 상태 확인

```bash
# Swap 사용량
free -h | grep Swap
swapon --show    # Swap 파티션/파일 목록

# 어느 프로세스가 Swap을 많이 쓰는지
for pid in /proc/[0-9]*/status; do
    awk '/VmSwap|Name/{printf $2 " "}END{print ""}' "$pid" 2>/dev/null
done | sort -k2 -rn | head -10

# 또는 smem 도구 사용
apt install smem
smem -s swap -r | head -10
```

### 4.3 Swappiness 조정

`vm.swappiness`: 커널이 얼마나 적극적으로 Swap을 사용하는지 (0~100)

```bash
# 현재 swappiness 확인
cat /proc/sys/vm/swappiness
# 기본값: 60 (Ubuntu), 30 (RHEL)

# 값의 의미:
# 0:   최대한 Swap 안 씀 (메모리 부족 시 OOM Killer 선호)
# 60:  기본값
# 100: 적극적으로 Swap 사용

# 데이터베이스 서버: 낮게 설정 (DB가 Swap 타면 치명적)
sysctl -w vm.swappiness=10
echo "vm.swappiness=10" >> /etc/sysctl.conf
```

### 4.4 Swap 파일 생성 (비상용)

```bash
# 2GB Swap 파일 생성
dd if=/dev/zero of=/swapfile bs=1M count=2048
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile

# 영구 적용 (/etc/fstab에 추가)
echo '/swapfile none swap sw 0 0' >> /etc/fstab

# 확인
swapon --show
free -h
```

---

## 5. OOM Killer (Out of Memory Killer)

RAM과 Swap이 모두 가득 찰 때 커널이 자동으로 프로세스를 죽이는 메커니즘.

### 5.1 OOM Score

커널은 각 프로세스에 **OOM Score**(-1000~1000)를 부여한다. 높을수록 먼저 죽는다.

```
OOM Score 계산 기준:
- 메모리 사용량 (많이 쓸수록 높음)
- 실행 시간 (오래 실행될수록 낮아짐)
- nice 값 (낮은 우선순위일수록 높음)
- /proc/<PID>/oom_score_adj 설정값

→ 가장 많은 메모리를 쓰면서 덜 중요한 프로세스가 선택됨
```

```bash
# 현재 OOM Score 확인
cat /proc/<PID>/oom_score
cat /proc/<PID>/oom_score_adj

# OOM Score 조정 (-1000=절대 죽이지 마, +1000=먼저 죽여)
# 중요 서비스 보호 (OOM 대상에서 제외)
echo -500 > /proc/<PID>/oom_score_adj

# systemd 서비스에서 영구 설정
# /etc/systemd/system/critical-app.service
# [Service]
# OOMScoreAdjust=-500
```

### 5.2 OOM 발생 확인 및 원인 분석

```bash
# OOM Killer 발동 이력 확인
journalctl -k | grep -i "oom\|killed process\|out of memory"

# 샘플 로그:
# kernel: Out of memory: Kill process 4521 (java) score 892 or sacrifice child
# kernel: Killed process 4521 (java) total-vm:4096000kB, anon-rss:3800000kB, file-rss:4096kB

# 어느 시점에 메모리가 폭증했는지 시계열 확인
sar -r 1 10   # sysstat 패키지 필요

# 현재 메모리 사용 상위 프로세스
ps aux --sort=-%mem | head -10
```

### 5.3 OOM 방지 전략

```bash
# 전략 1: 메모리 오버커밋 제한 (신중하게)
# vm.overcommit_memory:
# 0 = 휴리스틱 (기본): 어느 정도 오버커밋 허용
# 1 = 항상 허용: 무조건 malloc 성공 (위험)
# 2 = 엄격 제한: 실제 메모리 범위 내에서만 허용
cat /proc/sys/vm/overcommit_memory

# 전략 2: cgroup으로 프로세스별 메모리 상한 설정
# (컨테이너/K8s에서 memory limit이 이걸 사용)
# 상한 초과 시 해당 cgroup 내 프로세스만 OOM Killed

# 전략 3: 애플리케이션 레벨 메모리 제한
# Java: -Xmx2g (힙 최대 2GB)
# Node: --max-old-space-size=2048
```

---

## 6. /proc/meminfo 주요 항목

```bash
cat /proc/meminfo

# MemTotal:     16384000 kB  ← 전체 물리 RAM
# MemFree:       1100000 kB  ← 순수 빈 메모리
# MemAvailable: 10500000 kB  ← 실제 사용 가능 (가장 중요)
# Buffers:        300000 kB  ← 블록 I/O 버퍼
# Cached:        9900000 kB  ← 파일 페이지 캐시
# SwapCached:      10000 kB  ← Swap에서 다시 RAM으로 온 페이지
# Active:        5000000 kB  ← 최근에 접근한 페이지 (회수 안 함)
# Inactive:      5200000 kB  ← 오랫동안 접근 안 한 페이지 (회수 후보)
# Dirty:           50000 kB  ← 수정됐지만 디스크에 아직 안 쓴 페이지
# Writeback:           0 kB  ← 현재 디스크에 쓰는 중인 페이지
# AnonPages:     4000000 kB  ← 파일 없는 익명 메모리 (힙, 스택)
# Mapped:         800000 kB  ← mmap으로 매핑된 파일
# Shmem:          512000 kB  ← 공유 메모리 (tmpfs 포함)
# Slab:           500000 kB  ← 커널 캐시 (dentry, inode 등)
# SwapTotal:     2097152 kB  ← Swap 전체 크기
# SwapFree:      2097152 kB  ← Swap 여유 (0이면 위험)
```

## 7. 자주 하는 실수

| 실수 | 올바른 방법 |
|---|---|
| `free` 의 `used`가 크다고 메모리 부족 판단 | `available` 컬럼이 실제 지표 |
| Swap 0 = 좋은 것이라 생각해 Swap 비활성화 | Swap은 비상 완충재, 없으면 OOM 리스크 |
| OOM으로 죽은 프로세스 원인을 앱 버그로만 가정 | `journalctl -k | grep -i oom` 으로 커널 로그 먼저 확인 |
| VSZ 보고 메모리 사용량 과대 판단 | RSS와 `available`이 실제 지표 |
| 페이지 캐시 강제 해제 (`drop_caches`) 습관적으로 실행 | 이후 디스크 I/O 폭증, 성능 저하. 테스트 목적 외 금지 |
| 메모리 누수를 재시작으로만 해결 | `pmap <PID>` 또는 Valgrind로 누수 위치 파악 |
