# 메모리 압박 & 회수 튜닝 — PSI, dirty 정책, page reclaim 최적화

## 1. 개요

Linux 메모리 관리는 물리 메모리가 부족해질 때 자동으로 페이지를 회수하는 메커니즘을 갖는다. 이 회수 과정이 너무 늦거나 공격적으로 발생하면 I/O stall, 레이턴시 급등, 최악의 경우 OOM killer 발동으로 이어진다. PSI(Pressure Stall Information), dirty page 정책, kswapd 튜닝을 이해하고 서비스에 맞게 조정하면 이런 장애를 사전에 예방할 수 있다.

---

## 2. 설명

### 2.1 메모리 회수 흐름

```
메모리 사용량 증가
  │
  ├── [낮은 수위 (low watermark)] → kswapd 백그라운드 회수 시작
  │
  ├── [최소 수위 (min watermark)] → direct reclaim 발생 (동기, I/O stall)
  │                                  메모리 할당 요청한 프로세스가 직접 회수
  │
  └── [메모리 완전 고갈] → OOM killer 발동
```

```bash
# 현재 메모리 수위 확인
cat /proc/zoneinfo | grep -E "min|low|high|free" | head -20

# kswapd 활성 여부 확인
cat /proc/vmstat | grep pgscank    # kswapd가 스캔한 페이지 수
cat /proc/vmstat | grep pgsteal   # 실제 회수한 페이지 수
# pgsteal/pgscank = 회수 효율 (높을수록 좋음)

# direct reclaim 발생 여부
cat /proc/vmstat | grep allocstall  # direct reclaim 발생 횟수 (0이 이상적)
```

### 2.2 PSI (Pressure Stall Information)

PSI는 커널 4.20에서 도입된 메모리/CPU/I/O 압박 지표다. 리소스 부족으로 인해 실제로 작업이 지연된 시간 비율을 측정한다.

```bash
# 메모리 압박 확인
cat /proc/pressure/memory
# some avg10=0.32 avg60=0.15 avg300=0.05 total=12345678
# full avg10=0.00 avg60=0.00 avg300=0.00 total=0

# some: 일부 프로세스가 메모리 부족으로 대기
# full: 모든 프로세스가 메모리 부족으로 대기 (더 심각)
# avg10: 최근 10초 평균, avg60: 60초, avg300: 5분

# CPU 압박 확인
cat /proc/pressure/cpu

# I/O 압박 확인
cat /proc/pressure/io
```

**PSI 임계값 기준:**

| 지표 | 정상 | 주의 | 위험 |
|------|------|------|------|
| memory some avg10 | < 1% | 1~10% | > 10% |
| memory full avg10 | 0% | > 0.1% | > 1% |
| io full avg10 | < 1% | 1~5% | > 5% |

```bash
# PSI 임계값 기반 알림 (cgroup v2)
# /etc/systemd/system/memory-pressure-notify.service
[Service]
ExecStart=/usr/local/bin/psi-monitor.sh

# psi-monitor.sh
#!/bin/bash
while true; do
    MEM_SOME=$(awk '/some/{print $2}' /proc/pressure/memory | cut -d= -f2)
    if (( $(echo "$MEM_SOME > 5.0" | bc -l) )); then
        echo "메모리 압박 경고: PSI some avg10 = $MEM_SOME%" | logger -t psi-alert
    fi
    sleep 10
done

# Prometheus PSI 지표 수집
node_exporter --collector.pressure   # node_exporter로 PSI 수집
```

### 2.3 주요 vm 파라미터 튜닝

#### vfs_cache_pressure

```bash
# 현재 값 확인 (기본값: 100)
sysctl vm.vfs_cache_pressure

# 의미: dentry/inode 캐시 vs 페이지 캐시 회수 비율
# 100: 균등 회수
# < 100: dentry/inode를 더 오래 유지 (메타데이터 집약적 워크로드 유리)
# > 100: dentry/inode를 더 적극 회수

# 파일 수가 많은 서버 (많은 디렉토리 탐색)
sysctl -w vm.vfs_cache_pressure=50    # dentry 캐시 더 오래 유지

# 대용량 파일 처리 서버
sysctl -w vm.vfs_cache_pressure=200   # dentry 회수 가속, 페이지 캐시 유지
```

#### dirty page 정책

```bash
# dirty_ratio: 전체 메모리 대비 dirty page 비율 임계값 (기본: 20%)
# 초과 시 write()가 블로킹 → 직접 flush (레이턴시 급등)
sysctl vm.dirty_ratio

# dirty_background_ratio: kswapd가 백그라운드 flush 시작 임계값 (기본: 10%)
sysctl vm.dirty_background_ratio

# 레이턴시 민감 서비스 (DB 서버)
sysctl -w vm.dirty_ratio=5                 # 5%에서 강제 flush (급등 방지)
sysctl -w vm.dirty_background_ratio=2     # 2%에서 백그라운드 flush 시작

# 배치/로그 서버 (쓰기 처리량 우선)
sysctl -w vm.dirty_ratio=60
sysctl -w vm.dirty_background_ratio=30

# dirty page 만료 시간 (기본: 3000 centiseconds = 30초)
sysctl vm.dirty_expire_centisecs          # dirty page가 이 시간 후 flush 대상
sysctl vm.dirty_writeback_centisecs       # writeback 스레드 깨우는 주기 (기본: 500cs = 5초)

# 더 자주 flush (dirty 누적 방지)
sysctl -w vm.dirty_expire_centisecs=1000   # 10초 후 flush 대상
sysctl -w vm.dirty_writeback_centisecs=200 # 2초마다 writeback 스레드 활성화
```

#### min_free_kbytes

```bash
# 항상 유지할 여유 메모리 (기본: 물리 메모리의 약 1/64)
sysctl vm.min_free_kbytes

# 메모리 64GB 서버: 기본값이 너무 낮을 수 있음
# 권장: 물리 메모리의 1% 정도
# 64GB → 약 640MB
sysctl -w vm.min_free_kbytes=655360   # 640MB (KB 단위)

# 너무 크게 설정하면 가용 메모리가 줄어 OOM 유발 가능
```

#### watermark_scale_factor

```bash
# kswapd가 조기 활성화되는 수위 조정 (기본: 10 = 0.1%)
# 크게 하면 kswapd가 더 일찍, 더 오래 회수
sysctl vm.watermark_scale_factor

# 메모리 압박이 자주 발생하는 환경
sysctl -w vm.watermark_scale_factor=125   # 수위 간격을 1.25%로 확대
```

#### zone_reclaim_mode

```bash
# NUMA 환경에서 로컬 존 회수 강제 여부
sysctl vm.zone_reclaim_mode
# 0: 원격 NUMA 노드 메모리 사용 허용 (기본 권장)
# 1: 로컬 존 먼저 회수
# 2: 로컬 파일 페이지만 회수
# 4: 스왑 허용

# DB/애플리케이션 서버 — 원격 노드 접근이 회수보다 빠름
sysctl -w vm.zone_reclaim_mode=0   # NUMA 환경에서 필수 설정
```

### 2.4 /proc/meminfo 핵심 필드 해석

```bash
cat /proc/meminfo

# 핵심 필드:
# MemTotal:      전체 물리 메모리
# MemFree:       완전히 미사용 메모리 (낮아도 OK)
# MemAvailable:  실제 사용 가능 메모리 (MemFree + 회수 가능 캐시)
# Buffers:       파일시스템 메타데이터 캐시
# Cached:        파일 데이터 페이지 캐시
# SwapCached:    메모리로 돌아왔지만 스왑에도 있는 페이지
# Dirty:         쓰기 대기 중인 dirty page
# Writeback:     현재 디스크로 쓰는 중인 페이지
# Slab:          커널 데이터 구조 캐시 (SlabReclaim: 회수 가능)
# KernelStack:   각 스레드의 커널 스택
# PageTables:    가상→물리 주소 변환 테이블
```

```bash
# 메모리 상태 모니터링 스크립트
#!/bin/bash
while true; do
    AVAIL=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    DIRTY=$(grep ^Dirty /proc/meminfo | awk '{print $2}')
    WRITEBACK=$(grep Writeback /proc/meminfo | awk '{print $2}')
    echo "$(date): MemAvailable=${AVAIL}kB Dirty=${DIRTY}kB Writeback=${WRITEBACK}kB"
    sleep 5
done
```

### 2.5 vmstat로 메모리 압박 진단

```bash
# 1초 간격 vmstat (핵심 컬럼)
vmstat 1

# 주요 컬럼:
# si: swap in (초당 kB) — 0이어야 정상
# so: swap out (초당 kB) — 0이어야 정상
# bi: 블록 입력 (페이지/s) — 페이지 캐시 미스 시 증가
# bo: 블록 출력 (페이지/s) — dirty page flush 시 증가

# si/so > 0이면 스왑 발생 → 메모리 부족 징후
# bo가 갑자기 급증하면 dirty page 폭발 → I/O stall 발생 가능

# sar로 메모리 회수 통계
sar -B 1 60   # 1초 간격 60회 paging 통계
# pgscank: kswapd가 스캔한 페이지/s
# pgsteal: 실제 회수된 페이지/s
# %vmeff = pgsteal/pgscank × 100 → 낮으면 회수 효율 저하
```

### 2.6 Transparent Huge Pages (THP)

```bash
# THP 현재 설정 확인
cat /sys/kernel/mm/transparent_hugepage/enabled
# [always] madvise never  — 대괄호가 현재 설정

# THP 모드:
# always: 모든 익명 메모리에 자동 적용
# madvise: madvise(MADV_HUGEPAGE) 요청한 영역만 적용
# never: THP 비활성화

# DB 서버에서 THP 비활성화 (MySQL, MongoDB, Redis 권장)
echo never > /sys/kernel/mm/transparent_hugepage/enabled
echo never > /sys/kernel/mm/transparent_hugepage/defrag  # THP 디프래그도 끔

# 영구 적용 (GRUB 파라미터)
GRUB_CMDLINE_LINUX_DEFAULT="... transparent_hugepage=never"

# THP로 인한 문제 확인
grep thp /proc/vmstat | grep -v "^thp_zero"
# thp_fault_alloc: THP 할당 성공
# thp_fault_fallback: THP 할당 실패 후 4KB 폴백
# thp_collapse_alloc: 페이지 병합으로 THP 생성
# thp_split_page: THP가 4KB로 분리됨 → 많으면 fragmentation 심각
```

**THP가 DB 성능을 저하시키는 이유:**
- THP 할당/분리(split) 시 스톨 발생
- 2MB 경계에서 할당이 실패하면 4KB 폴백 → 불규칙한 레이턴시
- THP khugepaged 스캐너가 CPU 사이클 소비

### 2.7 cgroup v2 메모리 압박

```bash
# cgroup v2 메모리 설정
# /etc/systemd/system/myapp.service
[Service]
MemoryMax=4G          # 최대 메모리 (초과 시 OOM)
MemoryHigh=3G         # 소프트 제한 (초과 시 메모리 회수 압박 + 스로틀)
MemorySwapMax=0        # 스왑 사용 금지
MemoryMin=1G           # 최소 보장 메모리 (회수 대상에서 제외)

# cgroup 메모리 압박 확인
cat /sys/fs/cgroup/system.slice/myapp.service/memory.pressure
# some avg10=2.5 avg60=1.2 avg300=0.5 total=123456789

# 현재 메모리 사용량
cat /sys/fs/cgroup/system.slice/myapp.service/memory.current
cat /sys/fs/cgroup/system.slice/myapp.service/memory.stat
```

```yaml
# Kubernetes Pod 메모리 제한
apiVersion: v1
kind: Pod
spec:
  containers:
  - name: app
    resources:
      requests:
        memory: "1Gi"   # cgroup memory.min 설정
      limits:
        memory: "4Gi"   # cgroup memory.max 설정
```

```bash
# Kubernetes Pod의 cgroup 메모리 압박 확인
POD_ID=$(crictl pods --name myapp -q | head -1)
cat /sys/fs/cgroup/kubepods/besteffort/pod${POD_ID}/memory.pressure
```

### 2.8 OOM Score 조정

```bash
# 프로세스 OOM 점수 확인 (높을수록 먼저 죽음)
cat /proc/<PID>/oom_score        # 현재 OOM 점수
cat /proc/<PID>/oom_score_adj    # 조정값 (-1000~1000)

# 중요 프로세스 OOM 대상에서 제외 (-1000 = 절대 kill 안 함)
echo -1000 > /proc/$(pgrep mysqld)/oom_score_adj

# 덜 중요한 프로세스 우선 종료 (높은 값)
echo 500 > /proc/$(pgrep my-batch-job)/oom_score_adj

# systemd 서비스에서 설정
# /etc/systemd/system/critical-service.service
[Service]
OOMScoreAdjust=-900   # OOM killer 대상에서 거의 제외
```

### 2.9 실전 장애 시나리오: dirty page 폭발

**증상:** DB 서버에서 주기적으로 I/O가 수 초간 멈추고 응답 레이턴시 급등

```bash
# 1. dirty page 상태 확인
grep -E "^Dirty|^Writeback" /proc/meminfo
# Dirty:    20480000 kB  ← dirty_ratio 임계값 초과!
# Writeback:  2048000 kB

# 2. dirty page가 vm.dirty_ratio에 의해 강제 flush 발동 확인
cat /proc/vmstat | grep pdflush   # (구버전)
cat /proc/vmstat | grep writeback

# 3. I/O 병목 확인
iostat -x 1
# %util이 100%에 달하면 스토리지 포화

# 4. 즉각 조치: dirty_ratio 낮추기
sysctl -w vm.dirty_ratio=5
sysctl -w vm.dirty_background_ratio=2

# 5. 강제 flush (주의: 순간 I/O 스파이크 발생)
sync; echo 3 > /proc/sys/vm/drop_caches   # 페이지 캐시 flush + 정리

# 6. 영구 설정
cat >> /etc/sysctl.d/99-memory.conf << 'EOF'
vm.dirty_ratio = 5
vm.dirty_background_ratio = 2
vm.dirty_expire_centisecs = 1000
vm.dirty_writeback_centisecs = 200
vm.zone_reclaim_mode = 0
vm.min_free_kbytes = 655360
EOF
sysctl -p /etc/sysctl.d/99-memory.conf
```

### 2.10 서비스 유형별 권장 설정

```bash
# DB 서버 (MySQL, PostgreSQL)
vm.dirty_ratio = 5
vm.dirty_background_ratio = 2
vm.swappiness = 10             # 스왑 최소화
vm.vfs_cache_pressure = 50     # dentry/inode 캐시 유지
vm.zone_reclaim_mode = 0       # NUMA 원격 접근 허용
transparent_hugepage = never   # THP 비활성화

# 파일 서버 / 스트리밍 서버
vm.dirty_ratio = 30
vm.dirty_background_ratio = 10
vm.vfs_cache_pressure = 200    # 파일 캐시 적극 활용
vm.swappiness = 60

# 배치 처리 / 분석 서버
vm.dirty_ratio = 60
vm.dirty_background_ratio = 30
vm.swappiness = 30
transparent_hugepage = always  # THP로 대용량 메모리 효율화

# 레이턴시 민감 서비스 (트레이딩, 실시간)
vm.dirty_ratio = 2
vm.dirty_background_ratio = 1
vm.swappiness = 0              # 스왑 완전 비활성화
vm.min_free_kbytes = 1048576   # 1GB 항상 확보
transparent_hugepage = madvise
```

---

## 3. 자주 하는 실수

| 실수 | 올바른 방법 |
|------|------------|
| `MemFree`가 낮다고 메모리 부족으로 판단 | `MemAvailable` 확인 — 페이지 캐시는 필요 시 회수 가능 |
| dirty_ratio 높게 유지하면서 DB 운영 | dirty page 폭발 시 I/O stall → DB 서버는 5% 이하로 설정 |
| `echo 3 > /proc/sys/vm/drop_caches`를 정기 실행 | 페이지 캐시 강제 삭제는 이후 disk I/O 급증 유발 — 비상 시에만 |
| THP를 DB 서버에서 켜놓음 | MySQL, MongoDB, Redis 등 대부분의 DB는 THP 비활성화 권장 |
| NUMA 서버에서 zone_reclaim_mode=1 | 원격 메모리 접근이 로컬 회수보다 빠름 — 반드시 0으로 설정 |
| OOM score 조정 없이 중요 서비스 운영 | `oom_score_adj=-900`으로 중요 프로세스 OOM 대상 제외 |
| PSI 모니터링 없이 메모리 압박 인지 | `cat /proc/pressure/memory`를 SLI로 수집 — 임계값 5% 초과 시 알림 |
| swappiness를 0으로 설정하면 스왑 완전 비활성화로 착각 | swappiness=0은 메모리 극히 부족할 때만 스왑 — 완전 비활성화는 `swapoff -a` |
