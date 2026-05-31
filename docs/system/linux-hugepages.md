# HugePages - 대용량 메모리 집약적 워크로드 최적화

## 1. 개요

HugePages는 기본 4KB 페이지 대신 2MB 또는 1GB 단위로 메모리를 관리하는 리눅스 기능이다. TLB(Translation Lookaside Buffer)는 가상-물리 주소 변환을 캐시하는 하드웨어인데, 4KB 페이지를 사용하면 수십 GB의 메모리를 매핑하기 위해 수백만 개의 TLB 엔트리가 필요하다. HugePages를 사용하면 같은 메모리를 훨씬 적은 TLB 엔트리로 커버할 수 있어 TLB miss가 줄고 성능이 향상된다. PostgreSQL, Oracle DB, Redis처럼 대용량 메모리를 집약적으로 사용하는 워크로드에 필수 튜닝 항목이다.

---

## 2. 페이지 테이블과 TLB 동작 원리

### 2.1 가상-물리 주소 변환 흐름

```
프로세스 가상 주소 공간
  0x7fff0000 (스택)
  0x00600000 (힙)
  0x00400000 (코드)

CPU가 가상 주소에 접근할 때:
  1단계: TLB 조회 (캐시 히트 시 즉시 물리 주소 반환)
  2단계: TLB miss → 페이지 테이블 워크 (메모리 접근 4회: PGD→PUD→PMD→PTE)
  3단계: 물리 주소 획득 → TLB에 엔트리 추가

TLB 구조 (Intel x86-64 예시):
  L1 dTLB:  64 entries  (4KB 페이지)
  L2 TLB:   1024 entries
  → 64 * 4KB = 256KB 만 커버 (나머지 모두 miss)

  HugePages(2MB) 사용 시:
  L1 dTLB:  32 entries  (2MB 페이지)
  → 32 * 2MB = 64MB 커버 (4KB 대비 256배 효율)
```

### 2.2 TLB miss 비용

```
4KB 페이지, 100GB 메모리 사용 워크로드:
  필요 페이지 수: 100GB / 4KB = 26,214,400 페이지
  TLB 커버 가능: ~256KB (전체의 0.00025%)
  TLB miss 빈도: 매우 높음 → 페이지 테이블 워크 반복
  페이지 테이블 워크 비용: ~수십 나노초 × 초당 수백만 회 = 성능 저하

2MB HugePage 사용:
  필요 페이지 수: 100GB / 2MB = 51,200 페이지
  TLB 커버 가능: ~64MB (전체의 0.064%)
  miss 빈도 대폭 감소 → CPU 사이클 절약
```

---

## 3. Static HugePages vs THP (Transparent HugePages)

```
┌──────────────────────────────────────────────────────────┐
│            Static HugePages                              │
│  - 부팅 시 또는 수동으로 미리 예약                        │
│  - 애플리케이션이 명시적으로 요청 (mmap MAP_HUGETLB)      │
│  - Oracle DB, PostgreSQL의 shared_buffers에 적용         │
│  - 예약 메모리는 다른 용도로 재사용 불가                   │
│  - 단편화 없음, 예측 가능한 성능                          │
└──────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────┐
│            THP (Transparent HugePages)                   │
│  - 커널이 자동으로 4KB 페이지를 2MB로 통합 (collapse)     │
│  - 애플리케이션 변경 없이 적용                            │
│  - 백그라운드 khugepaged 데몬이 페이지 통합 수행           │
│  - 메모리 통합/분리 시 latency spike 발생 가능             │
│  - DB 서버에서 권장하지 않음 (예측 불가한 지연)            │
└──────────────────────────────────────────────────────────┘
```

---

## 4. Static HugePages 설정

### 4.1 HugePages 예약

```bash
# 현재 HugePages 상태 확인
cat /proc/meminfo | grep -i huge
# AnonHugePages:    614400 kB    ← THP로 할당된 익명 HugePages
# ShmemHugePages:        0 kB
# HugePages_Total:    1024        ← 정적 예약 수
# HugePages_Free:      512        ← 미사용
# HugePages_Rsvd:      256        ← 예약됨(아직 실제 사용 전)
# HugePages_Surp:        0        ← 초과 할당
# Hugepagesize:       2048 kB    ← 2MB

# 즉시 설정 (재부팅 시 초기화)
echo 1024 > /proc/sys/vm/nr_hugepages    # 1024 * 2MB = 2GB 예약

# 영구 설정
cat >> /etc/sysctl.conf <<'EOF'
vm.nr_hugepages = 1024
EOF
sysctl -p

# > **주의**: HugePages 예약은 연속된 물리 메모리가 필요하다.
# 서버 운영 중 동적 예약은 단편화로 실패할 수 있다.
# 반드시 부팅 초기에 예약하거나 GRUB 커널 파라미터로 설정한다.

# GRUB 커널 파라미터로 부팅 시 예약 (가장 안정적)
# /etc/default/grub 수정:
# GRUB_CMDLINE_LINUX="hugepages=1024 default_hugepagesz=2M"
# grub2-mkconfig -o /boot/grub2/grub.cfg
```

### 4.2 hugetlbfs 마운트

```bash
# hugetlbfs 마운트 (애플리케이션이 파일 기반으로 HugePage 접근)
mkdir -p /dev/hugepages
mount -t hugetlbfs hugetlbfs /dev/hugepages

# /etc/fstab에 영구 등록
echo 'hugetlbfs /dev/hugepages hugetlbfs defaults 0 0' >> /etc/fstab

# 마운트 확인
mount | grep huge
# hugetlbfs on /dev/hugepages type hugetlbfs (rw,relatime,pagesize=2M)
```

### 4.3 1GB HugePages (초대형 데이터베이스)

```bash
# 1GB 페이지 지원 여부 확인 (pdpe1gb 플래그 필요)
grep pdpe1gb /proc/cpuinfo | head -1

# 1GB 페이지 예약 (커널 파라미터만 가능, 런타임 변경 불가)
# /etc/default/grub:
# GRUB_CMDLINE_LINUX="hugepagesz=1G hugepages=16"  # 16GB 예약

# 혼합 사용 (2MB + 1GB)
# GRUB_CMDLINE_LINUX="hugepagesz=1G hugepages=8 hugepagesz=2M hugepages=512"
```

---

## 5. THP (Transparent HugePages) 설정

### 5.1 THP 모드

```bash
# 현재 THP 설정 확인
cat /sys/kernel/mm/transparent_hugepage/enabled
# [always] madvise never
# (대괄호가 현재 적용 중인 모드)

# 모드 설명:
# always:  모든 익명 메모리에 THP 적용 (기본값, DB에 부적합)
# madvise: madvise(MADV_HUGEPAGE) 호출한 메모리에만 적용
# never:   THP 완전 비활성화

# DB 서버 권장 설정 (THP 비활성화 또는 madvise)
echo never > /sys/kernel/mm/transparent_hugepage/enabled
echo never > /sys/kernel/mm/transparent_hugepage/defrag

# 영구 설정 (rc.local 또는 systemd)
cat > /etc/systemd/system/disable-thp.service <<'EOF'
[Unit]
Description=Disable Transparent Huge Pages (THP)
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash -c "echo never > /sys/kernel/mm/transparent_hugepage/enabled && echo never > /sys/kernel/mm/transparent_hugepage/defrag"

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now disable-thp
```

### 5.2 defer+madvise 패턴 (중간 설정)

```bash
# defer: THP 통합을 요청 시가 아닌 나중에 수행 (latency spike 완화)
echo defer+madvise > /sys/kernel/mm/transparent_hugepage/enabled

# khugepaged 스캔 간격 조정 (너무 잦으면 CPU 소비)
cat /sys/kernel/mm/transparent_hugepage/khugepaged/scan_sleep_millisecs
echo 10000 > /sys/kernel/mm/transparent_hugepage/khugepaged/scan_sleep_millisecs
```

---

## 6. 데이터베이스 서버 HugePages 실전 적용

### 6.1 PostgreSQL

```bash
# PostgreSQL shared_buffers를 HugePages로 설정

# 1. PostgreSQL의 예상 HugePages 수 계산
# shared_buffers = 16GB 설정 시
# 필요 HugePages = (16 * 1024 + 기타) / 2 ≈ 8200 pages

# 2. nr_hugepages 설정
sysctl -w vm.nr_hugepages=8500    # 여유 포함

# 3. postgresql.conf 설정
# huge_pages = on       # try: 가능하면 사용, on: 반드시 사용 (없으면 시작 실패)
# shared_buffers = 16GB

# 4. PostgreSQL 재시작 후 확인
psql -c "SHOW huge_pages;"
# huge_pages
# -----------
# on

# 사용된 HugePages 수 확인
cat /proc/meminfo | grep HugePages
```

### 6.2 Oracle Database

```bash
# Oracle은 SGA(System Global Area)를 HugePages로 매핑
# SGA_MAX_SIZE를 기반으로 계산

# /etc/sysctl.conf
# vm.nr_hugepages = [SGA_MAX_SIZE(bytes) / Hugepagesize + 여유]
# 예: SGA 64GB → 64*1024*1024/2048 + 100 = 32868

# oracle 사용자가 hugetlbfs 접근 가능하도록 그룹 설정
groupadd hugetlb
usermod -aG hugetlb oracle
echo 'vm.hugetlb_shm_group = <gid>' >> /etc/sysctl.conf
```

### 6.3 Redis

```bash
# Redis는 THP로 인한 copy-on-write 비용 증가 문제가 있음
# BGSAVE/AOF rewrite 시 fork() → THP CoW 비용이 2MB 단위로 발생

# Redis가 THP 경고 감지 시 로그에 표시:
# WARNING: you have Transparent Huge Pages (THP) support enabled in your kernel.
# This will create latency and memory usage issues with Redis.

# Redis용 THP 비활성화 (never 또는 madvise)
echo madvise > /sys/kernel/mm/transparent_hugepage/enabled
```

---

## 7. AWS EC2 HugePages 설정

### 7.1 인스턴스 유형별 고려사항

```
메모리 최적화 인스턴스 (HugePages 적합):
  r6i.large     ~ r6i.metal  : 16GB ~ 1.5TB RAM
  x2iedn.xlarge ~ x2iedn.metal: 메모리 집약 워크로드 전용

계산 최적화 (HugePages 효과 제한적):
  c6i.large     ~ c6i.metal  : 컴퓨팅 집약, 메모리 상대적으로 적음

ENA (Elastic Network Adapter):
  - ENA 드라이버도 HugePages에서 DMA 버퍼를 할당할 수 있음
  - 네트워크 성능 향상 가능
```

```bash
# EC2 User Data에서 HugePages 자동 설정 (부팅 시 적용)
#!/bin/bash
# 전체 메모리의 50%를 HugePages로 예약 (PostgreSQL 용)

TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
HUGEPAGE_SIZE_KB=2048
# 전체 메모리의 50%를 HugePages로
TARGET_HUGEPAGES=$((TOTAL_MEM_KB / 2 / HUGEPAGE_SIZE_KB))

echo "vm.nr_hugepages = $TARGET_HUGEPAGES" >> /etc/sysctl.conf
sysctl -p

# THP 비활성화 (DB 서버)
echo never > /sys/kernel/mm/transparent_hugepage/enabled
echo never > /sys/kernel/mm/transparent_hugepage/defrag
```

### 7.2 Terraform으로 HugePages 설정된 EC2 배포

```hcl
# main.tf
resource "aws_instance" "db_server" {
  ami           = data.aws_ami.amazon_linux2.id
  instance_type = "r6i.4xlarge"    # 128GB RAM, 메모리 최적화

  user_data = <<-EOF
    #!/bin/bash
    # HugePages 설정 (shared_buffers 50GB 기준)
    echo 'vm.nr_hugepages = 26000' >> /etc/sysctl.conf
    echo 'vm.hugetlb_shm_group = 26'  >> /etc/sysctl.conf  # postgres gid

    # THP 비활성화
    cat > /etc/systemd/system/disable-thp.service << 'UNIT'
    [Unit]
    Description=Disable THP
    [Service]
    Type=oneshot
    ExecStart=/bin/bash -c "echo never > /sys/kernel/mm/transparent_hugepage/enabled"
    ExecStart=/bin/bash -c "echo never > /sys/kernel/mm/transparent_hugepage/defrag"
    [Install]
    WantedBy=multi-user.target
    UNIT

    systemctl daemon-reload
    systemctl enable disable-thp

    sysctl -p
  EOF

  tags = {
    Name = "postgresql-primary"
    Role = "database"
  }
}
```

---

## 8. HugePages 효과 검증

```bash
# perf로 TLB miss 측정 (HugePages 적용 전/후 비교)
perf stat -e dTLB-load-misses,dTLB-loads ./workload

# 적용 전:
# dTLB-load-misses: 12,345,678  (10.5% miss rate)
# 적용 후:
# dTLB-load-misses:    456,789  (0.4% miss rate)

# PostgreSQL 쿼리 성능 비교 (pgbench)
pgbench -c 32 -j 4 -T 60 mydb    # HugePages 전
pgbench -c 32 -j 4 -T 60 mydb    # HugePages 후 (10~30% 향상 기대)

# /proc/meminfo로 HugePage 실제 사용 확인
watch -n1 'grep -i huge /proc/meminfo'
```

---

## 9. 자주 하는 실수

| 실수 | 원인 | 올바른 방법 |
|------|------|-------------|
| THP `always` 상태에서 DB 운영 | 기본값 미변경 | DB 서버는 `never` 또는 `madvise`로 THP 비활성화 |
| 런타임에 `nr_hugepages` 대량 증가 시 실패 | 메모리 단편화 | 부팅 초기 또는 GRUB 파라미터로 예약 |
| HugePages 예약 후 OOM 발생 | 예약량이 너무 많아 일반 메모리 부족 | 전체 메모리의 70% 이하로 예약, 여유 확보 |
| PostgreSQL `huge_pages=on` 설정 후 시작 실패 | nr_hugepages 부족 | `try`로 먼저 테스트 후 확인, `on`으로 전환 |
| Redis latency spike 원인을 THP로 미확인 | BGSAVE 중 CoW 비용 과소평가 | Redis 로그에서 THP 경고 확인, `madvise`로 설정 |
| EC2 재시작 후 HugePages 설정 초기화 | `/proc/sys` 설정은 휘발성 | `/etc/sysctl.conf` 영구 설정 또는 systemd 서비스 사용 |
| 1GB HugePages를 런타임에 설정 시도 | 1GB 페이지는 커널 파라미터만 가능 | GRUB `hugepagesz=1G hugepages=N` 으로만 설정 가능 |
| HugePages 사용량 모니터링 누락 | HugePages_Free 감소 미감지 | CloudWatch 커스텀 메트릭으로 HugePages_Free 모니터링 |
