# NUMA (Non-Uniform Memory Access) 아키텍처 & 최적화

## 1. 개요

NUMA는 멀티소켓 서버에서 CPU가 자신과 가까운 메모리(로컬)와 다른 소켓의 메모리(원격)에 접근할 때 레이턴시가 다른 메모리 아키텍처다. 로컬 메모리 접근은 약 80ns, 원격 노드 접근은 약 130ns로 약 1.6배 차이가 난다. 고성능 서버(DB, JVM 기반 애플리케이션)에서 NUMA를 무시하면 메모리 대역폭 병목과 레이턴시 증가로 성능이 크게 저하된다.

클라우드 환경에서도 `c5.18xlarge`, `r5.24xlarge` 같은 대형 인스턴스는 NUMA 노드가 2개 이상이므로 반드시 고려해야 한다.

---

## 2. 설명

### 2.1 NUMA 토폴로지 확인

```bash
# NUMA 노드 수, CPU/메모리 배치 요약
numactl --hardware

# 출력 예시:
# available: 2 nodes (0-1)
# node 0 cpus: 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
# node 0 size: 64334 MB
# node 0 free: 48201 MB
# node 1 cpus: 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31
# node 1 size: 64503 MB
# node 1 free: 51022 MB
# node distances:
# node   0   1
#   0:  10  21
#   1:  21  10

# CPU 소켓/코어/스레드 구조 상세 확인
lscpu --extended

# hwloc 도구로 시각적 토폴로지 출력 (텍스트)
lstopo --of ascii

# NUMA 노드별 메모리 통계
numastat

# 특정 프로세스의 NUMA 메모리 사용 현황
numastat -p $(pgrep mysqld)
```

### 2.2 NUMA 불균형 진단

```bash
# NUMA 히트율 확인 — numa_hit이 높을수록 좋음
numastat -n

# 커널의 NUMA 통계 (zone 단위)
cat /proc/zoneinfo | grep -A5 "Node 0"

# perf로 NUMA 원격 접근 미스 측정
perf stat -e node-load-misses,node-store-misses -p <PID> sleep 10

# /proc/meminfo에서 NUMA 관련 항목
grep -i numa /proc/meminfo

# 메모리 압박 시 원격 노드 접근 증가 확인
watch -n1 numastat
```

**NUMA 불균형 증상:**
- `numastat`에서 `numa_foreign` 값이 높음 (원격 노드 할당이 빈번)
- `numastat -n`에서 특정 노드의 `other_node` 값이 큼
- `perf stat`에서 `node-load-misses`가 전체 load의 20% 초과

### 2.3 numactl로 프로세스 NUMA 제어

```bash
# 특정 NUMA 노드 CPU + 메모리에 프로세스 바인딩
numactl --cpunodebind=0 --membind=0 -- ./myapp

# 메모리만 특정 노드에 할당 (CPU는 자유)
numactl --membind=1 -- java -jar app.jar

# 두 노드에 인터리브 방식으로 메모리 분산 (메모리 집약적 작업)
numactl --interleave=all -- ./memory-heavy-app

# 특정 CPU 코어 범위에 바인딩
numactl --physcpubind=0-7 --membind=0 -- ./app

# 현재 프로세스의 NUMA 정책 확인
numactl --show
```

**인터리브 모드 사용 시점:** 단일 스레드가 전체 메모리를 순차적으로 접근하는 경우 (대용량 배치 처리, 메모리 초기화)

### 2.4 자동 NUMA 밸런싱

```bash
# 자동 NUMA 밸런싱 상태 확인
cat /proc/sys/kernel/numa_balancing

# 활성화 (기본값: 1)
echo 1 > /proc/sys/kernel/numa_balancing

# 비활성화 (레이턴시 크리티컬 환경에서 고려)
echo 0 > /proc/sys/kernel/numa_balancing

# 영구 적용
echo "kernel.numa_balancing = 0" >> /etc/sysctl.d/99-numa.conf
sysctl -p /etc/sysctl.d/99-numa.conf
```

**자동 NUMA 밸런싱 장단점:**

| 항목 | 장점 | 단점 |
|------|------|------|
| 활성화 | 프로세스 자동으로 로컬 노드로 이동 | 페이지 마이그레이션 오버헤드 발생 |
| 비활성화 | 레이턴시 안정적, 오버헤드 없음 | 원격 접근 많아질 수 있음 |

레이턴시 크리티컬 서비스(트레이딩, 실시간 처리)는 비활성화 후 수동 바인딩이 유리하다.

### 2.5 cgroup cpuset으로 NUMA 격리

```bash
# cgroup v1: cpuset으로 NUMA 노드 고정
mkdir /sys/fs/cgroup/cpuset/myapp
echo 0-7 > /sys/fs/cgroup/cpuset/myapp/cpuset.cpus      # NUMA 노드 0 CPU
echo 0   > /sys/fs/cgroup/cpuset/myapp/cpuset.mems       # NUMA 노드 0 메모리
echo <PID> > /sys/fs/cgroup/cpuset/myapp/tasks

# cgroup v2 (systemd 기반)
# /etc/systemd/system/myapp.service
[Service]
AllowedCPUs=0-7        # NUMA 노드 0 CPUs
AllowedMemoryNodes=0   # NUMA 노드 0 메모리
```

**Kubernetes CPU Manager와 NUMA:**

```yaml
# kubelet 설정 (--cpu-manager-policy=static)
# Guaranteed QoS Pod에서 NUMA 친화성 보장
apiVersion: v1
kind: Pod
spec:
  containers:
  - resources:
      requests:
        cpu: "4"
        memory: "8Gi"
      limits:
        cpu: "4"       # requests == limits → Guaranteed QoS
        memory: "8Gi"
```

Kubernetes 1.18+에서 `TopologyManager`를 `single-numa-node` 정책으로 설정하면 CPU와 메모리가 동일 NUMA 노드에서 할당된다.

```bash
# kubelet 설정
--topology-manager-policy=single-numa-node
--cpu-manager-policy=static
--memory-manager-policy=Static
```

### 2.6 애플리케이션별 NUMA 튜닝

#### JVM (Java)

```bash
# JVM의 NUMA-aware 힙 할당 활성화
java -XX:+UseNUMA -XX:+UseParallelGC -jar app.jar

# NUMA 노드 0에만 JVM 실행
numactl --cpunodebind=0 --membind=0 -- java -Xmx32g -jar app.jar

# JVM NUMA 상태 확인 (GC 로그)
java -XX:+UseNUMA -XX:+PrintGCDetails -XX:+PrintGCDateStamps -jar app.jar
```

`-XX:+UseNUMA`는 G1GC, Parallel GC에서 동작한다. ZGC는 자체적으로 NUMA-aware하다.

#### PostgreSQL

```bash
# postgresql.conf
# NUMA 환경에서 zone_reclaim_mode=0 필수
# zone_reclaim_mode=1이면 원격 노드 메모리 사용 않고 직접 회수 → 성능 저하

echo 0 > /proc/sys/vm/zone_reclaim_mode
echo "vm.zone_reclaim_mode = 0" >> /etc/sysctl.d/99-postgres.conf

# PostgreSQL을 특정 NUMA 노드에 고정
numactl --cpunodebind=0 --membind=0 -- postgres -D /var/lib/postgresql/data

# systemd 서비스에서 설정
# /etc/systemd/system/postgresql.service.d/numa.conf
[Service]
ExecStart=
ExecStart=numactl --cpunodebind=0 --membind=0 /usr/bin/postgres -D /var/lib/postgresql/data
```

#### Redis

```bash
# Redis는 단일 스레드 — 단일 NUMA 노드 고정이 유리
numactl --cpunodebind=0 --membind=0 -- redis-server /etc/redis/redis.conf

# redis.service 수정
[Service]
ExecStart=numactl --cpunodebind=0 --membind=0 /usr/bin/redis-server /etc/redis/redis.conf
```

#### MySQL / InnoDB

```bash
# InnoDB buffer pool을 NUMA 노드에 맞게 분리
# my.cnf
[mysqld]
innodb_numa_interleave = ON   # buffer pool 인터리브 할당

# MySQL 프로세스 NUMA 바인딩
numactl --interleave=all -- mysqld
```

### 2.7 HugePage + NUMA 조합

```bash
# NUMA 노드별 hugepage 할당 확인
cat /sys/devices/system/node/node0/hugepages/hugepages-2048kB/nr_hugepages
cat /sys/devices/system/node/node1/hugepages/hugepages-2048kB/nr_hugepages

# 노드별 hugepage 수 설정
echo 512 > /sys/devices/system/node/node0/hugepages/hugepages-2048kB/nr_hugepages
echo 512 > /sys/devices/system/node/node1/hugepages/hugepages-2048kB/nr_hugepages

# numactl + hugepage 사용 애플리케이션
numactl --membind=0 -- ./app-using-hugepages
```

### 2.8 AWS EC2에서 NUMA 확인

```bash
# 인스턴스의 NUMA 토폴로지 확인
lscpu | grep -E "NUMA|Socket|Core|Thread"

# 대형 인스턴스 NUMA 구성 예시
# c5.18xlarge: 2 NUMA 노드, 각 노드에 18 vCPU
# r5.24xlarge: 2 NUMA 노드, 각 노드에 24 vCPU
# x1.32xlarge: 4 NUMA 노드

# EC2에서 NUMA 토폴로지 상세
cat /sys/devices/system/node/node*/cpulist
cat /sys/devices/system/node/node*/meminfo
```

AWS Nitro 기반 인스턴스는 물리 서버의 NUMA 토폴로지를 그대로 노출한다. `m5.metal` 같은 베어메탈 인스턴스는 실제 NUMA 구조가 그대로 보인다.

### 2.9 NUMA 성능 모니터링

```bash
# 실시간 NUMA 히트율 모니터링
watch -n2 'numastat | head -20'

# sar로 NUMA 통계 수집
sar -m NUMA 1 60

# perf NUMA 분석
perf stat -e \
  numa:numa_hint_faults,\
  numa:numa_hint_faults_local,\
  numa:numa_migrate_pages \
  -p <PID> sleep 30

# /proc/vmstat에서 NUMA 관련 카운터
grep numa /proc/vmstat
```

**주요 /proc/vmstat NUMA 카운터:**

| 카운터 | 의미 |
|--------|------|
| `numa_hit` | 원하는 노드에서 할당 성공 |
| `numa_miss` | 원하는 노드에서 할당 실패, 다른 노드에서 할당 |
| `numa_foreign` | 다른 노드용으로 의도된 메모리를 이 노드에서 할당 |
| `numa_interleave` | 인터리브 정책으로 할당 |
| `numa_local` | 로컬 노드에서 할당 |
| `numa_other` | 원격 노드에서 할당 |

`numa_miss` / (`numa_hit` + `numa_miss`) 비율이 5% 초과 시 NUMA 최적화를 검토한다.

---

## 3. 자주 하는 실수

| 실수 | 올바른 방법 |
|------|------------|
| `zone_reclaim_mode=1` 상태에서 DB 운영 | `vm.zone_reclaim_mode=0` 설정 — 원격 노드 메모리 활용이 회수보다 빠름 |
| 자동 NUMA 밸런싱 켜놓고 레이턴시 민감 서비스 운영 | `kernel.numa_balancing=0` + `numactl` 수동 바인딩 |
| JVM에 `-XX:+UseNUMA` 없이 대형 힙 사용 | `-XX:+UseNUMA` 추가, G1GC/ParallelGC와 함께 사용 |
| 멀티 소켓 서버에서 NUMA 확인 없이 성능 튜닝 | `numactl --hardware`로 토폴로지 먼저 파악 |
| hugepage를 글로벌로만 설정, 노드별 배분 안 함 | `/sys/devices/system/node/nodeN/hugepages/` 노드별 설정 |
| Kubernetes에서 NUMA 고려 없이 CPU/메모리 할당 | TopologyManager `single-numa-node` + CPU Manager `static` 정책 사용 |
| Redis를 두 NUMA 노드에 걸쳐 실행 | 단일 스레드이므로 `numactl --cpunodebind=0 --membind=0`으로 단일 노드 고정 |
| `numastat`을 주기적으로 확인 안 함 | 성능 이슈 발생 전 `numa_miss` 비율을 SLI로 모니터링 |
