# DPDK (Data Plane Development Kit) — 커널 완전 bypass, 유저스페이스 패킷 처리

## 1. 개요

DPDK는 Intel이 개발하고 현재 Linux Foundation이 관리하는 고성능 패킷 처리 프레임워크다. 커널 네트워크 스택을 완전히 우회하고 유저스페이스에서 NIC를 직접 제어해 100Gbps 이상의 라인레이트 패킷 처리를 달성한다. PMD(Poll Mode Driver)로 인터럽트 없이 NIC를 폴링하고, hugepage로 TLB miss를 최소화하며, CPU 코어를 독점해 컨텍스트 스위치 없이 패킷을 처리한다.

통신사 vRouter, NFV(Network Functions Virtualization), 고성능 방화벽, 트레이딩 시스템 등 라인레이트 처리가 필요한 환경에서 사용된다.

---

## 2. 설명

### 2.1 커널 네트워크 스택과 DPDK 비교

```
[커널 네트워크 스택 경로]
NIC → DMA → 커널 버퍼 → sk_buff 할당 → netfilter → TCP/IP → 소켓 → 유저앱
      각 단계마다 인터럽트, 메모리 복사, 컨텍스트 스위치 발생

[DPDK 경로]
NIC → DMA → hugepage 메모리 풀 → 유저스페이스 앱 (직접 처리)
      커널 개입 없음, 인터럽트 없음, 복사 없음
```

### 2.2 핵심 구성요소

#### EAL (Environment Abstraction Layer)

```c
#include <rte_eal.h>

int main(int argc, char *argv[]) {
    // EAL 초기화: hugepage 매핑, CPU 코어 할당, 드라이버 로드
    int ret = rte_eal_init(argc, argv);
    if (ret < 0) {
        rte_panic("EAL 초기화 실패: %d\n", ret);
    }
    // 이후 코드는 커널 독립적 환경에서 실행
}
```

#### mbuf (메시지 버퍼)

```c
#include <rte_mbuf.h>
#include <rte_mempool.h>

// mbuf 메모리 풀 생성 (hugepage에서 할당)
struct rte_mempool *mbuf_pool = rte_pktmbuf_pool_create(
    "MBUF_POOL",         // 풀 이름
    8192,                // 풀의 mbuf 수
    256,                 // CPU별 캐시 크기
    0,                   // 애플리케이션 private 데이터 크기
    RTE_MBUF_DEFAULT_BUF_SIZE,  // 패킷 버퍼 크기 (2048 bytes)
    rte_socket_id()      // NUMA 소켓 ID (로컬 메모리 할당)
);

// mbuf에서 패킷 데이터 접근
struct rte_mbuf *pkt;
char *data = rte_pktmbuf_mtod(pkt, char *);        // 패킷 데이터 포인터
uint16_t pkt_len = rte_pktmbuf_pkt_len(pkt);       // 패킷 길이
```

#### Ring (락프리 큐)

```c
#include <rte_ring.h>

// 락프리 링 큐 생성 (코어 간 패킷 전달)
struct rte_ring *ring = rte_ring_create(
    "PKT_RING",          // 링 이름
    1024,                // 최대 항목 수 (2의 제곱)
    rte_socket_id(),     // NUMA 소켓
    RING_F_SP_ENQ | RING_F_SC_DEQ  // 단일 생산자/단일 소비자 최적화
);

// 패킷 enqueue/dequeue
rte_ring_enqueue(ring, (void *)pkt);   // 패킷 추가 (lock-free)
rte_ring_dequeue(ring, (void **)&pkt); // 패킷 꺼내기 (lock-free)

// 벌크 처리 (최대 성능)
struct rte_mbuf *pkts[32];
uint16_t nb_rx = rte_ring_dequeue_burst(ring, (void **)pkts, 32, NULL);
```

### 2.3 Hugepage 설정 (필수)

DPDK는 TLB miss를 최소화하기 위해 2MB 또는 1GB hugepage가 반드시 필요하다.

```bash
# 2MB hugepage 설정 (런타임)
echo 1024 > /proc/sys/vm/nr_hugepages   # 1024 x 2MB = 2GB hugepage 할당

# 1GB hugepage 설정 (GRUB 부팅 파라미터로만 가능)
# /etc/default/grub
GRUB_CMDLINE_LINUX_DEFAULT="... hugepagesz=1G hugepages=8 default_hugepagesz=1G"

# 영구 설정 (/etc/sysctl.d/99-dpdk.conf)
vm.nr_hugepages = 1024               # 2MB hugepage 수
vm.nr_overcommit_hugepages = 0       # 오버커밋 비활성화

# hugepage 마운트 (DPDK 자동 처리)
mkdir -p /dev/hugepages
mount -t hugetlbfs nodev /dev/hugepages

# hugepage 상태 확인
cat /proc/meminfo | grep Huge
# HugePages_Total: 1024  — 설정된 수
# HugePages_Free:   512  — 미사용 수
# Hugepagesize:    2048 kB

# NUMA 노드별 hugepage (NUMA 환경에서 중요)
cat /sys/devices/system/node/node0/hugepages/hugepages-2048kB/nr_hugepages
echo 512 > /sys/devices/system/node/node0/hugepages/hugepages-2048kB/nr_hugepages
echo 512 > /sys/devices/system/node/node1/hugepages/hugepages-2048kB/nr_hugepages
```

### 2.4 NIC 드라이버 바인딩

DPDK는 NIC를 커널 드라이버에서 분리하고 DPDK 전용 드라이버로 바인딩한다.

```bash
# DPDK 드라이버 모듈 로드
modprobe vfio-pci       # VFIO (권장, IOMMU 활용)
modprobe uio_pci_generic # UIO (레거시, 보안 낮음)

# PCI 장치 목록 확인
dpdk-devbind.py --status    # 모든 네트워크 장치 상태

# 출력 예시:
# Network devices using kernel driver
# ====================================
# 0000:00:05.0 'Virtio network device' if=eth0 drv=virtio-pci
#
# Network devices using DPDK-compatible driver
# ============================================
# (없음)

# NIC를 커널 드라이버에서 분리
ip link set eth1 down              # 먼저 인터페이스 비활성화
dpdk-devbind.py --unbind 0000:00:06.0   # 커널 드라이버 언바인드

# VFIO로 바인딩 (IOMMU 활성화 필요)
dpdk-devbind.py --bind vfio-pci 0000:00:06.0

# UIO로 바인딩 (IOMMU 없는 환경)
dpdk-devbind.py --bind uio_pci_generic 0000:00:06.0

# 바인딩 상태 재확인
dpdk-devbind.py --status-dev net    # 네트워크 장치만 확인
```

> **주의**: DPDK에 바인딩된 NIC는 커널에서 보이지 않는다. `ip link show`에서 사라지며, 해당 NIC의 IP 설정도 모두 무효화된다. 관리용 NIC와 DPDK용 NIC를 반드시 분리해야 한다.

### 2.5 IOMMU 설정 (vfio-pci 사용 시)

```bash
# IOMMU 활성화 확인
dmesg | grep -i iommu
# "IOMMU enabled" 또는 "Intel-IOMMU: enabled" 출력 확인

# /etc/default/grub에 IOMMU 활성화 파라미터 추가
# Intel CPU
GRUB_CMDLINE_LINUX_DEFAULT="... intel_iommu=on iommu=pt"
# AMD CPU
GRUB_CMDLINE_LINUX_DEFAULT="... amd_iommu=on iommu=pt"

# grub 재생성 후 재부팅
grub2-mkconfig -o /boot/grub2/grub.cfg

# IOMMU 그룹 확인
for d in /sys/kernel/iommu_groups/*/devices/*; do
    echo "$(basename $(dirname $(dirname $d))): $(basename $d)"
done
```

### 2.6 testpmd: 기본 패킷 포워딩 테스트

```bash
# testpmd 실행 (2개 포트 간 패킷 포워딩)
dpdk-testpmd \
    -l 0-3 \             # CPU 코어 0~3 사용 (코어 0: 마스터, 1~3: 워커)
    -n 4 \               # 메모리 채널 수
    --socket-mem 1024 \  # NUMA 소켓별 hugepage 메모리 (MB)
    -- \
    --nb-cores=2 \       # 패킷 처리 코어 수
    --rxq=2 \            # RX 큐 수
    --txq=2 \            # TX 큐 수
    --forward-mode=io    # I/O 포워딩 모드 (수신→송신 단순 전달)

# testpmd 대화형 명령어
testpmd> show port info all          # 포트 정보
testpmd> show port stats all         # 포트 통계 (PPS, BPS)
testpmd> start                       # 패킷 포워딩 시작
testpmd> stop                        # 정지
testpmd> set fwd macswap             # MAC 스왑 모드로 변경 (loopback 테스트)
```

### 2.7 간단한 DPDK 애플리케이션 예제

```c
// dpdk_hello.c — 수신된 패킷을 카운트하고 드롭하는 최소 예제
#include <rte_eal.h>
#include <rte_ethdev.h>
#include <rte_mbuf.h>
#include <rte_lcore.h>

#define RX_RING_SIZE 1024
#define NUM_MBUFS 8192
#define BURST_SIZE 32

static int lcore_main(void *arg) {
    uint16_t port = 0;
    struct rte_mbuf *bufs[BURST_SIZE];

    printf("코어 %u에서 수신 시작\n", rte_lcore_id());

    for (;;) {
        // NIC에서 패킷 버스트 수신 (폴링 — 인터럽트 없음)
        uint16_t nb_rx = rte_eth_rx_burst(
            port,       // 포트 번호
            0,          // 큐 번호
            bufs,       // 패킷 버퍼 배열
            BURST_SIZE  // 최대 수신 패킷 수
        );

        if (nb_rx == 0) continue;   // 패킷 없으면 계속 폴링

        // 모든 패킷 처리 후 해제
        for (uint16_t i = 0; i < nb_rx; i++) {
            // 여기서 패킷 분석/수정/포워딩 처리
            rte_pktmbuf_free(bufs[i]);   // 패킷 버퍼 풀로 반환
        }
    }
    return 0;
}

int main(int argc, char *argv[]) {
    struct rte_mempool *mbuf_pool;

    // EAL 초기화
    int ret = rte_eal_init(argc, argv);
    if (ret < 0) rte_panic("EAL 초기화 실패\n");
    argc -= ret; argv += ret;   // EAL 인수 이후 앱 인수

    // mbuf 풀 생성 (hugepage에서 할당)
    mbuf_pool = rte_pktmbuf_pool_create("MBUF_POOL", NUM_MBUFS,
        256, 0, RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());
    if (!mbuf_pool) rte_panic("mbuf 풀 생성 실패\n");

    // 포트 0 설정 및 시작
    struct rte_eth_conf port_conf = {0};
    rte_eth_dev_configure(0, 1, 1, &port_conf);   // 포트 0: 1 RX, 1 TX 큐
    rte_eth_rx_queue_setup(0, 0, RX_RING_SIZE, rte_eth_dev_socket_id(0), NULL, mbuf_pool);
    rte_eth_tx_queue_setup(0, 0, RX_RING_SIZE, rte_eth_dev_socket_id(0), NULL);
    rte_eth_dev_start(0);   // 포트 시작

    // 워커 코어에서 패킷 처리 루프 실행
    rte_eal_mp_remote_launch(lcore_main, NULL, SKIP_MASTER);
    rte_eal_mp_wait_lcore();   // 모든 코어 완료 대기

    return 0;
}
```

```bash
# CMakeLists.txt로 빌드
cmake_minimum_required(VERSION 3.10)
project(dpdk_hello)

find_package(PkgConfig REQUIRED)
pkg_check_modules(DPDK REQUIRED libdpdk)   # DPDK pkg-config

add_executable(dpdk_hello dpdk_hello.c)
target_compile_options(dpdk_hello PRIVATE ${DPDK_CFLAGS})
target_link_libraries(dpdk_hello ${DPDK_LIBRARIES})

# 빌드
mkdir build && cd build
cmake .. && make

# 실행 (hugepage 설정 후)
./dpdk_hello -l 0-1 -n 4 -- -p 0x1   # 코어 0,1 사용, 포트 0
```

### 2.8 DPDK 기반 주요 프로젝트

#### OVS-DPDK (Open vSwitch)

```bash
# OVS-DPDK 설치 및 설정
ovs-vsctl set Open_vSwitch . other_config:dpdk-init=true
ovs-vsctl set Open_vSwitch . other_config:dpdk-socket-mem="1024,1024"
ovs-vsctl set Open_vSwitch . other_config:pmd-cpu-mask=0x0C   # CPU 2,3

# DPDK 포트 생성
ovs-vsctl add-br br0
ovs-vsctl set bridge br0 datapath_type=netdev   # DPDK 데이터 경로
ovs-vsctl add-port br0 dpdk0 -- set Interface dpdk0 type=dpdk options:dpdk-devargs=0000:00:06.0

# OVS-DPDK 통계
ovs-ofctl dump-flows br0        # 플로우 테이블
ovs-appctl dpif-netdev/pmd-stats-show   # PMD 코어 통계
```

#### SPDK (Storage Performance Development Kit)

```bash
# SPDK: NVMe SSD를 커널 bypass로 직접 접근
# DPDK와 동일한 철학을 스토리지에 적용
spdk_nvme_identify   # NVMe 장치 식별
spdk_perf            # 스토리지 성능 측정 (수백만 IOPS 달성)
```

#### VPP (Vector Packet Processing)

```bash
# Cisco의 VPP: DPDK 기반 고성능 소프트웨어 라우터/포워더
systemctl start vpp
vppctl show interface    # 인터페이스 목록
vppctl show runtime      # 처리 통계
```

### 2.9 DPDK vs XDP 선택 가이드

| 기준 | XDP 선택 | DPDK 선택 |
|------|---------|---------|
| 커널 네트워크 스택 | 유지하면서 가속 | 완전히 우회 |
| 기존 Linux 도구 호환 | 유지 (ip, tc, iptables) | 사용 불가 |
| 구현 복잡도 | 중간 (eBPF C) | 높음 (DPDK API) |
| CPU 코어 요구 | 공유 사용 | 전용 코어 독점 |
| 처리량 목표 | ~30Mpps (Native) | 100Mpps+ |
| 운영 난이도 | 낮음 | 높음 |
| 사용 케이스 | DDoS 방어, K8s 네트워킹 | vRouter, NFV, 트레이딩 |
| AWS EC2 적합성 | 좋음 (ENA 지원) | 제한적 (IOMMU, SR-IOV 필요) |

### 2.10 AWS EC2에서 DPDK

```bash
# SR-IOV 지원 인스턴스에서 DPDK 사용
# c5n.18xlarge, hpc6a.48xlarge 등 ENA Enhanced Networking 지원 인스턴스

# Enhanced Networking (ENA) 확인
ethtool -i eth0 | grep driver   # ena 드라이버 확인
modinfo ena | grep version      # ENA 드라이버 버전

# DPDK ENA PMD 사용
# ENA는 DPDK Native PMD 지원 — 일반 커널 드라이버와 공존 불가
# EC2에서 DPDK 사용 시 인스턴스당 NIC 분리 권장:
# eth0 → 관리용 (커널 드라이버)
# eth1 → DPDK용 (ENA PMD)

# DPDK ENA PMD 실행
dpdk-testpmd -l 0-7 \
    --socket-mem 2048 \
    -a 0000:00:06.0 \     # ENA 디바이스 PCI 주소
    -- \
    --nb-cores=6 \
    --forward-mode=io

# c5n.18xlarge 성능 (ENA, 100Gbps 인터페이스)
# DPDK ENA PMD: ~60-80Mpps (64B 패킷 기준)
```

### 2.11 CPU 코어 격리 및 NUMA 최적화

```bash
# DPDK 전용 CPU 코어 격리 (GRUB 파라미터)
GRUB_CMDLINE_LINUX_DEFAULT="... isolcpus=2-7 nohz_full=2-7 rcu_nocbs=2-7"
# 코어 0-1: 커널, 시스템 서비스
# 코어 2-7: DPDK PMD 전용 (스케줄러 간섭 없음)

# DPDK 실행 시 격리 코어 지정
dpdk-app -l 2-7 \         # 격리된 코어만 사용
    --socket-mem 1024,1024 \  # NUMA 노드별 메모리
    -a 0000:01:00.0 \         # NUMA 노드 0 NIC
    -a 0000:81:00.0 \         # NUMA 노드 1 NIC
    -- [앱 인수]

# NIC를 연결된 NUMA 노드와 같은 노드의 코어에 배정
lspci -v | grep -A5 "Ethernet"   # NIC의 NUMA 노드 확인
cat /sys/bus/pci/devices/0000:01:00.0/numa_node   # 해당 PCI 장치의 NUMA 노드
```

### 2.12 성능 모니터링

```bash
# DPDK 앱 내부 통계
dpdk-procinfo -- --stats      # 런타임 포트 통계
dpdk-procinfo -- --xstats     # 확장 통계 (NIC별 상세)

# 외부 모니터링
ethtool -S eth0 | grep -E "rx|tx"   # NIC 드라이버 통계 (DPDK 바인딩 전)

# CPU 코어 사용률 (PMD busy-wait 확인)
htop -d 1                    # 격리 코어가 100% 근처인지 확인
mpstat -P ALL 1              # CPU별 사용률 1초 간격

# perf로 DPDK 앱 프로파일링
perf stat -C 2-7 -e cycles,instructions,cache-misses sleep 10
perf record -C 2-7 -g -F 99 sleep 30   # 30초 샘플링
perf report --stdio                      # 플레임 그래프용 데이터
```

---

## 3. 자주 하는 실수

| 실수 | 올바른 방법 |
|------|------------|
| hugepage 없이 DPDK 실행 | `cat /proc/meminfo \| grep Huge` 확인 후 `nr_hugepages` 설정 필수 |
| IOMMU 없이 vfio-pci 사용 | `dmesg \| grep iommu` 확인, 없으면 GRUB 파라미터 추가 후 재부팅 |
| 관리 NIC를 DPDK에 바인딩 | 바인딩 즉시 SSH 연결 끊김 — 반드시 NIC 분리 후 사용 |
| DPDK NIC를 NUMA 노드 무시하고 할당 | NIC의 NUMA 노드와 같은 노드 CPU/메모리 사용 (`--socket-mem` 지정) |
| CPU 코어 격리 없이 PMD 실행 | `isolcpus`로 DPDK 코어 격리 안 하면 커널 스케줄러가 간섭 — 레이턴시 불안정 |
| mbuf 풀 크기 부족 | 버스트 크기 × 큐 수 × 코어 수 × 2 이상으로 설정 |
| 단일 소켓 메모리로 멀티 NUMA | `--socket-mem 1024,1024`처럼 노드별 메모리 명시 |
| AWS ENA 인스턴스에서 DPDK 기대치 과다 | ENA는 가상화 오버헤드 존재 — 베어메탈 대비 20-30% 성능 감소 예상 |
