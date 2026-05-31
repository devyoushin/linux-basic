# I/O 스케줄러 — mq-deadline/kyber/bfq/none, 디스크 유형별 튜닝

## 1. 개요

I/O 스케줄러는 커널이 블록 장치(디스크)에 보내는 I/O 요청의 순서를 결정하는 컴포넌트다. HDD 시대에는 헤드 이동을 최소화하는 엘리베이터 알고리즘이 중요했지만, NVMe SSD 시대에는 하드웨어가 자체적으로 최적화하므로 스케줄러 없음(`none`)이 최고 성능을 낸다. 커널 5.x부터 블록 멀티큐(blk-mq) 아키텍처로 전환되어 스케줄러도 이에 맞게 진화했다.

---

## 2. 설명

### 2.1 blk-mq (Multi-Queue) 아키텍처

```
커널 5.x blk-mq 아키텍처:

CPU별 소프트웨어 큐 (SW Queue)
  CPU 0: [req0, req1, ...]
  CPU 1: [req2, req3, ...]
  ...
       ↓ (스케줄러 적용)
하드웨어 큐 (HW Queue)
  HW Queue 0 → NVMe 큐 0
  HW Queue 1 → NVMe 큐 1
  ...           (NVMe는 최대 65535 HW 큐)

구버전 단일 큐: 전역 잠금 → CPU 병목
blk-mq: CPU별 독립 큐 → 수평 확장
```

### 2.2 스케줄러 종류 상세

#### none (noop)

```bash
# 특징: 요청 재정렬/병합 없음, 도착 순서대로 처리
# 적합: NVMe SSD — 하드웨어 내부 큐와 병렬 처리로 자체 최적화
# NVMe 장치에서 none 사용 시 추가 스케줄러 오버헤드 제거

# NVMe SSD에 none 설정
echo none > /sys/block/nvme0n1/queue/scheduler

# none이 빠른 이유:
# NVMe는 큐 깊이 65535 지원 → 하드웨어가 직접 최적화
# 스케줄러 오버헤드(정렬, 병합, 잠금) 제거
```

#### mq-deadline

```bash
# 특징: 읽기 우선 + 기아 방지 (쓰기 최대 대기 시간 보장)
# 적합: SATA SSD, SAS HDD, 범용 워크로드
# 읽기는 낮은 우선순위, 쓰기는 기본 500ms 타임아웃

# mq-deadline 설정
echo mq-deadline > /sys/block/sda/queue/scheduler

# 파라미터 튜닝
cat /sys/block/sda/queue/iosched/read_expire   # 읽기 만료 시간 (기본 500ms)
cat /sys/block/sda/queue/iosched/write_expire  # 쓰기 만료 시간 (기본 5000ms)
cat /sys/block/sda/queue/iosched/writes_starved # 쓰기 기아 방지 임계값 (기본 2)

# DB 서버 (읽기 레이턴시 우선)
echo 100 > /sys/block/sda/queue/iosched/read_expire   # 읽기 100ms로 단축
echo 1000 > /sys/block/sda/queue/iosched/write_expire # 쓰기 1초 허용
```

#### kyber

```bash
# 특징: 레이턴시 목표 기반 큐 관리
# 적합: NVMe, 고성능 PCIe SSD
# 읽기/쓰기 레이턴시 목표를 설정하고 큐 깊이를 자동 조절

# kyber 설정
echo kyber > /sys/block/nvme0n1/queue/scheduler

# 레이턴시 목표 설정 (마이크로초)
cat /sys/block/nvme0n1/queue/iosched/read_lat_nsec    # 기본 2ms (2000000ns)
cat /sys/block/nvme0n1/queue/iosched/write_lat_nsec   # 기본 10ms

# 읽기 레이턴시 1ms 목표
echo 1000000 > /sys/block/nvme0n1/queue/iosched/read_lat_nsec
```

#### bfq (Budget Fair Queueing)

```bash
# 특징: 프로세스별 공정 I/O 배분 (가중치 기반)
# 적합: 컨테이너 환경, 데스크탑, 멀티 테넌트
# 단점: 고성능 NVMe에서 오버헤드 큼

# bfq 설정
echo bfq > /sys/block/sda/queue/scheduler

# 프로세스별 I/O 가중치 설정 (100~1000, 기본 100)
ionice -c 2 -n 4 -p <PID>   # Best-effort 클래스, 우선순위 4

# cgroup v2 io.weight로 컨테이너별 I/O 제한 (bfq 필요)
echo "8:0 200" > /sys/fs/cgroup/myapp/io.weight   # 메이저:마이너 장치, 가중치
```

### 2.3 스케줄러 확인 및 변경

```bash
# 현재 스케줄러 확인 (대괄호가 현재 설정)
cat /sys/block/nvme0n1/queue/scheduler
# [none] mq-deadline kyber bfq

cat /sys/block/sda/queue/scheduler
# mq-deadline [bfq] kyber none

# 런타임 변경 (즉시 적용, 재부팅 후 초기화)
echo mq-deadline > /sys/block/sda/queue/scheduler

# udev rule로 영구 적용 (/etc/udev/rules.d/60-io-scheduler.rules)
# SATA SSD에 mq-deadline 영구 적용
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"

# HDD에 bfq 영구 적용
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"

# NVMe에 none 영구 적용
ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/scheduler}="none"

# udev 규칙 즉시 적용
udevadm control --reload-rules
udevadm trigger --type=devices --action=change   # 규칙 재적용

# GRUB으로 기본 스케줄러 변경 (전체 시스템)
GRUB_CMDLINE_LINUX_DEFAULT="... scsi_mod.use_blk_mq=1 elevator=mq-deadline"
```

### 2.4 디스크 유형별 권장 스케줄러

| 디스크 유형 | 권장 스케줄러 | 이유 |
|-----------|-------------|------|
| HDD (7200rpm) | bfq | 헤드 이동 최적화 + 공정 배분 |
| SATA SSD | mq-deadline | 기아 방지 + 적절한 오버헤드 |
| NVMe PCIe SSD | none 또는 kyber | 하드웨어 자체 최적화, 스케줄러 불필요 |
| AWS EBS gp3 | none | 네트워크 블록 스토리지, 순서 무의미 |
| AWS EBS io2 | none | IOPS 집약적, 스케줄러 오버헤드 최소화 |
| 가상 블록 장치 (virtio) | none | 하이퍼바이저가 처리 |
| RAID 배열 | mq-deadline | 다수 디스크 조율 |

```bash
# 디스크 회전 여부 확인 (0=SSD, 1=HDD)
cat /sys/block/sda/queue/rotational

# 회전 여부에 따른 자동 설정 스크립트
for disk in /sys/block/sd* /sys/block/nvme*; do
    ROTATIONAL=$(cat $disk/queue/rotational 2>/dev/null)
    DEVNAME=$(basename $disk)

    if [ "$ROTATIONAL" = "0" ]; then
        echo mq-deadline > $disk/queue/scheduler   # SSD: mq-deadline
        echo "$DEVNAME: mq-deadline (SSD)"
    elif [ "$ROTATIONAL" = "1" ]; then
        echo bfq > $disk/queue/scheduler            # HDD: bfq
        echo "$DEVNAME: bfq (HDD)"
    fi

    # NVMe는 별도 처리
    if [[ $DEVNAME == nvme* ]]; then
        echo none > $disk/queue/scheduler           # NVMe: none
        echo "$DEVNAME: none (NVMe)"
    fi
done
```

### 2.5 큐 깊이 (Queue Depth) 튜닝

```bash
# 현재 큐 깊이 확인
cat /sys/block/nvme0n1/queue/nr_requests    # 소프트웨어 큐 크기 (기본: 64)
cat /sys/block/nvme0n1/queue/max_sectors_kb # 요청당 최대 크기

# NVMe: 큐 깊이 최대화 (하드웨어가 지원하는 수준까지)
echo 1024 > /sys/block/nvme0n1/queue/nr_requests

# SATA SSD: 적절한 큐 깊이 (기본 NCQ 32)
echo 64 > /sys/block/sda/queue/nr_requests

# HDD: 낮게 설정 (과도한 큐는 레이턴시 증가)
echo 32 > /sys/block/sdb/queue/nr_requests

# NVMe 하드웨어 큐 깊이 확인
cat /sys/block/nvme0n1/device/queue_depth   # NVMe 하드웨어 큐 (65535까지)
```

### 2.6 Read-ahead 튜닝

```bash
# 현재 read-ahead 크기 확인 (512B 단위)
cat /sys/block/sda/queue/read_ahead_kb    # KB 단위로 표시

# 순차 읽기 집약적 (스트리밍, 백업)
echo 4096 > /sys/block/sda/queue/read_ahead_kb    # 4MB read-ahead

# 랜덤 I/O 집약적 (DB, 캐시 서버)
echo 128 > /sys/block/sda/queue/read_ahead_kb     # 작게 유지

# blockdev로 설정 (블록 크기 단위)
blockdev --setra 8192 /dev/sda    # 8192 × 512B = 4MB

# 전체 블록 장치에 일괄 적용
for dev in /dev/sd? /dev/nvme?n?; do
    blockdev --setra 256 $dev     # 256 × 512B = 128KB
done
```

### 2.7 I/O 통계 모니터링

```bash
# iostat — 기본 I/O 통계
iostat -x 1 10   # 1초 간격 10회, 확장 통계

# 핵심 컬럼:
# r/s, w/s: 초당 읽기/쓰기 요청 수
# rkB/s, wkB/s: 초당 읽기/쓰기 처리량 (KB)
# await: 평균 I/O 대기 시간 (ms) — 높으면 병목
# %util: 장치 사용률 — 100%에 달하면 포화

# iotop — 프로세스별 I/O 사용량
iotop -o         # I/O 발생 중인 프로세스만 표시
iotop -a         # 누적 I/O 통계

# /proc/diskstats 직접 읽기
cat /proc/diskstats | grep nvme0n1

# watch로 실시간 모니터링
watch -n1 'cat /sys/block/nvme0n1/stat'
# 필드: reads, read_merged, read_sectors, read_ms, writes, ...
```

### 2.8 blktrace/blkparse: I/O 패턴 심층 분석

```bash
# blktrace 설치
dnf install blktrace    # RHEL/CentOS
apt install blktrace    # Ubuntu

# 30초간 sda의 I/O 이벤트 캡처
blktrace -d /dev/sda -w 30 -o sda_trace

# blkparse로 분석
blkparse -i sda_trace -o sda_output.txt
blkparse -i sda_trace -d sda_binary   # btt 입력용 바이너리 변환

# btt로 레이턴시 분석
btt -i sda_binary | grep -E "D2C|Q2C"
# D2C: dispatch to completion (실제 디스크 처리 시간)
# Q2C: queue to completion (전체 I/O 지연 시간)

# seek 거리 분석 (HDD에서 중요)
blkparse -i sda_trace | grep D | awk '{print $5}' | sort -n | uniq -c | head -20
```

### 2.9 AWS EBS 스케줄러 최적화

```bash
# EBS 장치 확인
lsblk -d -o NAME,TYPE,ROTA   # ROTA=0이면 SSD

# EBS gp3/io2에 none 설정 (AWS 권장)
echo none > /sys/block/xvda/queue/scheduler   # Xen 인스턴스
echo none > /sys/block/nvme0n1/queue/scheduler # Nitro 인스턴스

# EBS 최적화 인스턴스 확인 (EBS I/O가 네트워크와 분리)
# aws ec2 describe-instances --query 'Reservations[].Instances[].EbsOptimized'

# EBS gp3 볼륨 성능 (기본)
# IOPS: 3000, 처리량: 125MB/s
# 추가 비용으로 최대 16000 IOPS, 1000MB/s까지 설정 가능

# io2 Block Express (최고 성능)
# IOPS: 최대 256000, 처리량: 최대 4000MB/s
# none 스케줄러 + nr_requests 최대화 권장

# EBS 멀티 어태치 (io1/io2 전용)
# 여러 인스턴스에서 같은 볼륨 접근
# 스케줄러: none (각 인스턴스가 독립 처리)
```

### 2.10 컨테이너/Kubernetes I/O 제한

```bash
# cgroup v2 io.max: 컨테이너별 IOPS/처리량 제한 (bfq 스케줄러 불필요)
# 장치 번호 확인
ls -l /dev/sda   # 8, 0 형태 (메이저:마이너)
stat -c %t:%T /dev/sda   # 메이저:마이너 16진수

# I/O 최대 제한 설정
echo "8:0 rbps=52428800 wbps=52428800" > /sys/fs/cgroup/myapp/io.max   # 50MB/s 제한
echo "8:0 riops=1000 wiops=1000" >> /sys/fs/cgroup/myapp/io.max        # 1000 IOPS 제한

# I/O 가중치 (상대적 우선순위)
echo "8:0 100" > /sys/fs/cgroup/myapp/io.weight   # 기본 100

# Kubernetes: container-level I/O 제한 (Alpha 기능, 버전 확인 필요)
apiVersion: v1
kind: Pod
spec:
  containers:
  - name: app
    resources:
      limits:
        # 블록 I/O 제한은 devicePlugin 또는 cgroup 직접 설정 필요
```

### 2.11 실전 튜닝 사례: MySQL 데이터 디렉토리 이전

```bash
# 시나리오: MySQL 데이터를 HDD에서 NVMe로 이전

# 이전 전 상태 확인
iostat -x 1 | grep sda   # HDD I/O 상태
mysql -e "SHOW GLOBAL STATUS LIKE 'Innodb_data_read%'"

# 1. NVMe 포맷 및 마운트
mkfs.xfs -f /dev/nvme0n1p1
mkdir /data/mysql
mount -o noatime,nodiratime /dev/nvme0n1p1 /data/mysql

# 2. NVMe 스케줄러 최적화
echo none > /sys/block/nvme0n1/queue/scheduler
echo 1024 > /sys/block/nvme0n1/queue/nr_requests    # 큐 깊이 최대화

# 3. read-ahead 낮춤 (MySQL은 랜덤 I/O 집약)
echo 256 > /sys/block/nvme0n1/queue/read_ahead_kb   # 128KB

# 4. MySQL 데이터 이전 (LVM 스냅샷 또는 rsync)
systemctl stop mysql
rsync -av /var/lib/mysql/ /data/mysql/
chown -R mysql:mysql /data/mysql

# 5. MySQL 설정 변경
sed -i 's|/var/lib/mysql|/data/mysql|' /etc/mysql/mysql.conf.d/mysqld.cnf
systemctl start mysql

# 6. 이전 후 성능 확인
iostat -x 1 | grep nvme
mysql -e "SHOW GLOBAL STATUS LIKE 'Innodb_data_read%'"
# await 값이 HDD 대비 1/10 이하로 감소해야 정상
```

---

## 3. 자주 하는 실수

| 실수 | 올바른 방법 |
|------|------------|
| NVMe SSD에 mq-deadline 또는 bfq 사용 | NVMe는 `none` — 스케줄러 오버헤드가 불필요한 병목 |
| HDD에 none 사용 | HDD는 `bfq` 또는 `mq-deadline` — 헤드 이동 최적화 필요 |
| 스케줄러 변경 후 udev 규칙 미설정 | `/sys` 변경은 재부팅 후 초기화 — udev rule 또는 GRUB으로 영구 적용 |
| AWS EBS에서 mq-deadline 사용 | EBS는 네트워크 블록 스토리지 — `none`으로 오버헤드 제거 |
| read_ahead_kb를 DB 서버에서 크게 설정 | DB는 랜덤 I/O 집약 — 큰 read-ahead는 불필요한 데이터 읽기 유발 |
| nr_requests 기본값으로 NVMe 운영 | NVMe는 하드웨어 큐가 65535 — `nr_requests`를 1024로 높여 병렬성 최대화 |
| iostat -x 없이 I/O 병목 판단 | `await` > 10ms이면 SATA SSD 병목, > 1ms이면 NVMe 병목 징후 |
| bfq로 NVMe 고성능 서버 운영 | bfq는 프로세스별 추적 오버헤드가 큼 — NVMe에서 none/kyber 사용 |
