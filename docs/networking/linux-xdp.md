# XDP (eXpress Data Path) — 커널 네트워크 스택 우회, iptables 대체

## 1. 개요

XDP는 Linux 커널 4.8에서 도입된 고성능 패킷 처리 프레임워크다. NIC 드라이버 수준에서 eBPF 프로그램을 실행해 패킷이 커널 네트워크 스택(netfilter, TCP/IP 등)에 도달하기 전에 처리한다. iptables는 규칙이 늘어날수록 O(n) 순회 비용이 발생하지만, XDP는 BPF 해시맵을 사용해 O(1)에 처리한다.

Cloudflare는 XDP로 초당 수천만 패킷의 DDoS를 차단하고, Meta(Facebook)는 Katran 로드밸런서에 XDP를 사용한다. Kubernetes에서는 Cilium이 kube-proxy/iptables를 XDP로 완전 대체한다.

---

## 2. 설명

### 2.1 패킷 처리 위치 비교

```
NIC 하드웨어
  │
  ▼
[XDP_DRV] ← XDP 드라이버 모드 (가장 빠름, NIC 드라이버 지원 필요)
  │
  ▼
DMA 수신 (skb 할당 전)
  │
[XDP_SKB] ← XDP Generic 모드 (드라이버 미지원 시 폴백, 느림)
  │
  ▼
sk_buff 할당 (메모리 복사 발생)
  │
  ▼
netfilter/iptables (PREROUTING → INPUT/FORWARD)
  │
  ▼
TCP/IP 스택
  │
  ▼
소켓 수신 버퍼
```

XDP는 sk_buff가 **할당되기 전** 원시 패킷 데이터에 직접 접근하기 때문에 메모리 할당 오버헤드가 없다.

### 2.2 XDP 모드

| 모드 | 설명 | 성능 | 요구사항 |
|------|------|------|---------|
| `XDP_DRV` (Native) | NIC 드라이버가 XDP를 직접 지원 | 최고 (~수천만 PPS) | 드라이버 지원 필요 |
| `XDP_SKB` (Generic) | 커널이 sk_buff 변환 후 처리 | 낮음 (iptables와 비슷) | 모든 NIC |
| `XDP_HW` (Offload) | XDP 프로그램을 NIC 하드웨어에서 실행 | 최고 (CPU 부하 없음) | XDP Offload 지원 NIC |

```bash
# NIC의 XDP 드라이버 지원 여부 확인
ethtool -i eth0 | grep driver   # 드라이버 이름 확인
# mlx5, i40e, bnxt_en, ena, ice 등은 Native XDP 지원

# XDP 프로그램 로드 (Native 모드)
ip link set dev eth0 xdp obj xdp_prog.o sec xdp   # XDP 프로그램 로드

# XDP 프로그램 로드 (Generic 모드 강제)
ip link set dev eth0 xdpgeneric obj xdp_prog.o sec xdp

# XDP 프로그램 제거
ip link set dev eth0 xdp off   # XDP 프로그램 언로드

# 현재 XDP 프로그램 확인
ip link show eth0 | grep xdp   # XDP 로드 여부 및 프로그램 ID

# xdp-tools로 확인
xdp-loader status              # 모든 인터페이스의 XDP 상태
```

### 2.3 XDP 액션 종류

XDP 프로그램은 패킷마다 하나의 액션을 반환한다.

| 액션 | 동작 | 사용 케이스 |
|------|------|-----------|
| `XDP_DROP` | 패킷 즉시 폐기 | DDoS 차단, 블랙리스트 |
| `XDP_PASS` | 커널 네트워크 스택으로 전달 | 일반 패킷 |
| `XDP_TX` | 같은 NIC로 패킷 반사 전송 | 로드밸런서 응답 |
| `XDP_REDIRECT` | 다른 NIC 또는 CPU로 리디렉션 | 패킷 포워딩 |
| `XDP_ABORTED` | 에러 폐기 (tracepoint 발생) | 디버깅 |

### 2.4 XDP 프로그램 예제: DDoS IP 블랙리스트

```c
// xdp_blacklist.c — IP 블랙리스트 기반 DDoS 차단
#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

// BPF 해시맵: 차단할 소스 IP 목록 (key: IP, value: 1)
struct {
    __uint(type, BPF_MAP_TYPE_LRU_HASH);   // LRU 해시맵 (자동 오래된 항목 제거)
    __uint(max_entries, 1000000);           // 최대 100만 개 IP
    __type(key, __u32);                    // IPv4 주소 (4바이트)
    __type(value, __u64);                  // 차단 카운터
} blacklist SEC(".maps");

SEC("xdp")
int xdp_drop_blacklist(struct xdp_md *ctx) {
    void *data_end = (void *)(long)ctx->data_end;
    void *data     = (void *)(long)ctx->data;

    // 이더넷 헤더 파싱
    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end)
        return XDP_PASS;  // 패킷 너무 짧음

    // IPv4만 처리
    if (bpf_ntohs(eth->h_proto) != ETH_P_IP)
        return XDP_PASS;

    // IP 헤더 파싱
    struct iphdr *ip = (void *)(eth + 1);
    if ((void *)(ip + 1) > data_end)
        return XDP_PASS;

    // 블랙리스트 조회 (O(1) 해시 룩업)
    __u64 *count = bpf_map_lookup_elem(&blacklist, &ip->saddr);
    if (count) {
        __sync_fetch_and_add(count, 1);  // 차단 카운터 증가
        return XDP_DROP;                 // 즉시 폐기
    }

    return XDP_PASS;  // 정상 패킷은 커널 스택으로
}

char _license[] SEC("license") = "GPL";
```

```bash
# 컴파일
clang -O2 -g -target bpf -c xdp_blacklist.c -o xdp_blacklist.o

# 로드
ip link set dev eth0 xdp obj xdp_blacklist.o sec xdp

# 블랙리스트에 IP 추가 (Python + bpftool)
bpftool map update pinned /sys/fs/bpf/blacklist \
    key hex c0 a8 01 01 \   # 192.168.1.1 (little-endian 주의)
    value hex 00 00 00 00 00 00 00 00

# bpftool로 맵 내용 조회
bpftool map dump pinned /sys/fs/bpf/blacklist

# XDP 통계 확인 (차단 카운터)
bpftool map show   # 맵 목록
```

### 2.5 XDP 프로그램 예제: 간단한 패킷 카운터

```c
// xdp_counter.c — 프로토콜별 패킷 카운터
#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <bpf/bpf_helpers.h>

struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);   // CPU별 독립 카운터 (경쟁 없음)
    __uint(max_entries, 256);                   // 프로토콜 번호 0~255
    __type(key, __u32);
    __type(value, __u64);
} proto_counter SEC(".maps");

SEC("xdp")
int xdp_count_proto(struct xdp_md *ctx) {
    void *data_end = (void *)(long)ctx->data_end;
    void *data     = (void *)(long)ctx->data;

    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end) return XDP_PASS;
    if (bpf_ntohs(eth->h_proto) != ETH_P_IP) return XDP_PASS;

    struct iphdr *ip = (void *)(eth + 1);
    if ((void *)(ip + 1) > data_end) return XDP_PASS;

    __u32 proto = ip->protocol;   // TCP=6, UDP=17, ICMP=1
    __u64 *cnt = bpf_map_lookup_elem(&proto_counter, &proto);
    if (cnt) __sync_fetch_and_add(cnt, 1);   // 원자적 카운터 증가

    return XDP_PASS;
}

char _license[] SEC("license") = "GPL";
```

```bash
# 컴파일 및 로드
clang -O2 -target bpf -c xdp_counter.c -o xdp_counter.o
ip link set dev eth0 xdp obj xdp_counter.o sec xdp

# 카운터 읽기
bpftool map dump name proto_counter   # 프로토콜별 패킷 수 출력

# xdp-tools의 xdp-monitor로 실시간 통계
xdp-monitor --interval 1   # 1초 간격 XDP 통계
```

### 2.6 BPF 맵 타입

| 맵 타입 | 설명 | XDP 활용 |
|--------|------|---------|
| `BPF_MAP_TYPE_HASH` | 해시테이블 | IP 블랙리스트, ACL |
| `BPF_MAP_TYPE_LRU_HASH` | LRU 해시 (자동 eviction) | 대용량 플로우 테이블 |
| `BPF_MAP_TYPE_ARRAY` | 고정 배열 | 통계 카운터 |
| `BPF_MAP_TYPE_PERCPU_ARRAY` | CPU별 배열 | lock-free 카운터 |
| `BPF_MAP_TYPE_DEVMAP` | 디바이스 맵 | XDP_REDIRECT 대상 |
| `BPF_MAP_TYPE_CPUMAP` | CPU 맵 | 패킷을 특정 CPU로 리디렉션 |
| `BPF_MAP_TYPE_XSKMAP` | AF_XDP 소켓 맵 | 유저스페이스 패킷 처리 |

### 2.7 iptables vs nftables vs XDP vs DPDK 성능 비교

| 기술 | 처리 위치 | 10만 규칙 성능 | 레이턴시 | 구현 난이도 |
|------|---------|-------------|---------|-----------|
| iptables | netfilter | ~100K PPS (규칙당 선형) | 수십~수백μs | 쉬움 |
| nftables | netfilter | ~500K PPS (set 사용 시) | 수십μs | 보통 |
| ipset + iptables | netfilter | ~1M PPS | 수십μs | 보통 |
| XDP (Generic) | sk_buff 이후 | ~1-2M PPS | ~10μs | 어려움 |
| XDP (Native) | 드라이버 | ~10-30M PPS | <1μs | 어려움 |
| XDP (HW Offload) | NIC 하드웨어 | 100M+ PPS | 나노초 | 매우 어려움 |
| DPDK | 유저스페이스 | 100M+ PPS | 나노초 | 매우 어려움 |

### 2.8 Cilium: kube-proxy/iptables를 XDP로 대체

Kubernetes 클러스터가 커지면 iptables의 한계가 드러난다.

**iptables의 Kubernetes 문제:**
- 서비스 1000개 = iptables 규칙 수만 개
- 규칙 추가/삭제 시 전체 테이블 flush & reload (O(n))
- conntrack 테이블 폭발 (대규모 클러스터)

**Cilium의 해결:**
- eBPF 맵으로 서비스/엔드포인트 관리 → O(1) 룩업
- kube-proxy 완전 제거
- XDP로 NodePort, ExternalIP 처리

```bash
# Cilium 설치 (kube-proxy 없이)
# kubeadm init 시 kube-proxy 스킵
kubeadm init --skip-phases=addon/kube-proxy

# Cilium 설치 (Helm)
helm repo add cilium https://helm.cilium.io/
helm install cilium cilium/cilium \
    --namespace kube-system \
    --set kubeProxyReplacement=strict \
    --set k8sServiceHost=<API_SERVER_IP> \
    --set k8sServicePort=6443 \
    --set bpf.masquerade=true   # iptables masquerade 대신 eBPF

# Cilium 상태 확인
cilium status
cilium service list    # BPF 맵의 서비스 목록

# BPF 맵 직접 확인
bpftool map list | grep cilium         # Cilium BPF 맵 목록
cilium bpf lb list                     # 로드밸런서 BPF 엔트리

# kube-proxy 제거 확인
kubectl get pods -n kube-system | grep kube-proxy   # 없어야 함
```

### 2.9 AF_XDP: 유저스페이스 zero-copy 패킷 처리

AF_XDP 소켓은 XDP 프로그램이 패킷을 유저스페이스 메모리로 직접 전달하는 메커니즘이다. 커널 네트워크 스택을 완전히 우회하면서도 DPDK와 달리 커널 드라이버를 유지한다.

```c
// XDP 프로그램에서 AF_XDP 소켓으로 패킷 리디렉션
struct {
    __uint(type, BPF_MAP_TYPE_XSKMAP);   // AF_XDP 소켓 맵
    __uint(max_entries, 64);
    __type(key, __u32);
    __type(value, __u32);
} xsks_map SEC(".maps");

SEC("xdp")
int xdp_redirect_to_user(struct xdp_md *ctx) {
    // 큐 인덱스로 AF_XDP 소켓에 패킷 전달
    int index = ctx->rx_queue_index;
    return bpf_redirect_map(&xsks_map, index, XDP_PASS);
}
```

```bash
# AF_XDP 소켓 예제 실행 (xdp-tools 패키지)
xdpsock -i eth0 -q 0    # 큐 0에서 AF_XDP 수신 테스트

# DPDK 없이 유저스페이스 패킷 처리 가능
# OVS-DPDK 대신 OVS + AF_XDP 조합 사용 가능
```

### 2.10 AWS ENA에서 XDP

```bash
# AWS ENA 드라이버 XDP 지원 확인
modinfo ena | grep -i xdp           # XDP 지원 정보
ethtool -i eth0 | grep driver       # ENA 드라이버 버전 확인

# ENA Native XDP 지원 여부 (커널 5.0+, ENA 드라이버 2.2+)
ip link set dev eth0 xdp obj xdp_prog.o sec xdp 2>&1
# 에러 없으면 Native 지원, EOPNOTSUPP면 Generic 폴백

# ENA 큐 수 확인 (XDP는 큐당 1개 프로그램)
ethtool -l eth0    # 현재/최대 큐 수

# c5n.18xlarge: 32 큐 → XDP 프로그램 32개 병렬 처리
```

### 2.11 xdp-tools 사용법

```bash
# xdp-tools 패키지 설치
dnf install xdp-tools         # RHEL/CentOS
apt install xdp-tools         # Ubuntu

# XDP 프로그램 로드/언로드
xdp-loader load eth0 xdp_prog.o    # 로드
xdp-loader unload eth0 --all       # 언로드

# XDP 상태 확인
xdp-loader status                   # 전체 인터페이스 상태

# xdp-filter: 간단한 IP/포트 필터
xdp-filter load eth0                # xdp-filter 활성화
xdp-filter ip 192.168.1.1 --mode src --action drop   # IP 차단
xdp-filter port 80 --mode dst --action allow          # 포트 허용

# XDP 통계 실시간 모니터링
xdp-monitor --interval 1    # 1초 간격 드롭/통과 패킷 통계
```

### 2.12 성능 측정

```bash
# pktgen으로 XDP 처리량 측정
# 서버 A (패킷 생성)
pktgen_sample03_burst_single_flow.sh -i eth0 -d <서버B_IP> -m <서버B_MAC>

# 서버 B (XDP 드롭 성능 측정)
ip link set dev eth0 xdp obj xdp_drop_all.o sec xdp   # 모든 패킷 드롭
ethtool -S eth0 | grep rx_packets   # 1초 간격으로 PPS 계산

# bpftool perf로 XDP 프로그램 프로파일링
bpftool perf show                   # 실행 중인 BPF 프로그램 통계
perf stat -e xdp:xdp_exception -a sleep 10   # XDP 예외 이벤트 카운트
```

---

## 3. 자주 하는 실수

| 실수 | 올바른 방법 |
|------|------------|
| Generic 모드에서 성능 기대 | `ethtool -i eth0`으로 드라이버 확인, Native XDP 지원 NIC 사용 |
| 패킷 경계 검사 없이 포인터 접근 | 모든 헤더 접근 전 `data_end` 검사 필수 — 검증 실패 시 프로그램 로드 거부 |
| BPF 맵 업데이트를 XDP 프로그램 내에서 lock 없이 | `BPF_MAP_TYPE_PERCPU_*` 사용 또는 원자 연산 사용 |
| XDP와 GRO/LRO 혼용 | XDP Native 모드에서 GRO 비활성화 필요 — `ethtool -K eth0 gro off` |
| VLAN 태그 없이 VLAN 트래픽 처리 | `bpf_helper` `bpf_skb_vlan_pop` 또는 VLAN 헤더 직접 파싱 필요 |
| XDP_REDIRECT 후 대상 인터페이스 미등록 | `BPF_MAP_TYPE_DEVMAP`에 대상 인터페이스 fd 등록 필요 |
| 규칙 변경 시 XDP 프로그램 재컴파일 | BPF 맵 런타임 업데이트로 프로그램 재로드 없이 규칙 변경 |
| AWS ENA에서 XDP_TX 사용 | ENA는 XDP_TX 미지원 — XDP_REDIRECT로 대체 |
