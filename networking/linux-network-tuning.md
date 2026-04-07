# linux-network-tuning.md — 고트래픽 환경을 위한 TCP/소켓 커널 파라미터 튜닝

## 1. 개요

고트래픽 서비스에서 커널 기본값은 대부분의 경우 병목이 된다. 초당 수만 건의 요청을 처리하는 nginx나 HAProxy 앞단에서는 SYN 큐 초과, TIME_WAIT 고갈, 소켓 버퍼 부족이 복합적으로 발생한다. `sysctl`로 조정 가능한 파라미터는 200개가 넘지만, 실무에서 체감 효과가 큰 핵심 10여 개를 이해하고 정확히 적용하는 것이 중요하다.

---

## 2. 설명

### 2.1 TCP 연결 수명주기와 튜닝 포인트

```
Client                    Server (Kernel)                Application
  |                           |                               |
  |------- SYN ----------->  [SYN Queue (backlog)]           |
  |                           |  (net.ipv4.tcp_max_syn_backlog)
  |<------ SYN-ACK ---------  |                               |
  |                           |                               |
  |------- ACK ----------->  [Accept Queue]  ------------>  accept()
  |                           |  (net.core.somaxconn)         |
  |                           |                               |
  |<====== DATA ============> | <===========================  |
  |                           |                               |
  |------- FIN ----------->   |                               |
  |<------ ACK ----------->   |                               |
  |<------ FIN ----------->   |                               |
  |------- ACK ----------->  [TIME_WAIT: 60초]               |
```

TCP 3-way handshake에서 커널은 두 단계의 큐를 관리한다.

- **SYN Queue**: SYN을 받고 SYN-ACK를 보낸 뒤 ACK를 기다리는 반-연결(half-open) 상태
- **Accept Queue**: 3-way handshake가 완료된 연결이 `accept()` 호출을 기다리는 큐

둘 중 하나라도 가득 차면 커널은 SYN 패킷을 묵시적으로 드롭하거나(`tcp_abort_on_overflow=0` 기본값) RST를 보낸다.

### 2.2 SYN Queue vs Accept Queue 파라미터

```bash
# SYN Queue 크기: 반-연결 상태로 대기할 수 있는 최대 수
net.ipv4.tcp_max_syn_backlog = 65536

# Accept Queue 크기 상한: 커널 전체의 최대 backlog 크기
# listen(fd, backlog) 호출값과 이 값 중 작은 값이 실제 Accept Queue 크기
net.core.somaxconn = 65536
```

**핵심 구분:**

| 파라미터 | 영향 범위 | 초과 시 동작 |
|---|---|---|
| `tcp_max_syn_backlog` | SYN Queue | SYN 패킷 드롭 |
| `somaxconn` | Accept Queue 상한 | `listen(backlog)` 값을 이 값으로 clamp |

nginx는 `listen 80 backlog=65535;`처럼 backlog를 지정할 수 있다. 하지만 `somaxconn`이 1024이면 실제 큐 크기는 1024가 된다.

```bash
# 현재 Accept Queue / SYN Queue 상태 확인
ss -lnt
# Recv-Q: Accept Queue에 쌓인 연결 수
# Send-Q: Accept Queue의 최대 크기

# 큐 오버플로우 카운터 확인
netstat -s | grep -i "SYNs to LISTEN"
# → TcpExtListenOverflows 가 증가하면 Accept Queue 병목
netstat -s | grep -i "listen"
```

### 2.3 TIME_WAIT 폭발 현상과 해결

TIME_WAIT는 정상 동작이다. 그러나 짧은 연결이 폭발적으로 발생하는 환경(HTTP/1.0, 헬스체크)에서는 수십만 개의 TIME_WAIT 소켓이 쌓여 포트 고갈을 유발한다.

```
# TIME_WAIT 소켓 수 실시간 확인
ss -ant | grep TIME-WAIT | wc -l

# 포트 범위 확인: 이 범위가 소진되면 새 연결 불가
cat /proc/sys/net/ipv4/ip_local_port_range
# 기본값: 32768 ~ 60999 (약 28,000개)
```

**해결 파라미터:**

```bash
# tcp_tw_reuse: TIME_WAIT 소켓을 새 아웃바운드 연결에 재사용 (클라이언트 역할일 때)
# 조건: 새 연결의 타임스탬프가 기존보다 크면 안전하게 재사용
net.ipv4.tcp_tw_reuse = 1

# tcp_timestamps: tw_reuse가 작동하려면 반드시 활성화 필요
net.ipv4.tcp_timestamps = 1

# FIN_WAIT2 상태 타임아웃 단축 (기본 60초)
net.ipv4.tcp_fin_timeout = 15

# 로컬 포트 범위 확장: 아웃바운드 연결이 많은 프록시 서버에 중요
net.ipv4.ip_local_port_range = 1024 65535
```

> **주의**: `tcp_tw_recycle`은 Linux 4.12에서 제거되었다. NAT 환경(AWS VPC 포함)에서 패킷 드롭을 유발하므로 절대 사용하지 않는다.

### 2.4 소켓 버퍼 튜닝

소켓 버퍼는 TCP 처리량(throughput)에 직접 영향을 미친다. 버퍼가 작으면 고지연(high-latency) 링크에서 윈도우가 조기에 닫혀 처리량이 제한된다.

```
BDP (Bandwidth-Delay Product) = 대역폭 × RTT
예) 10Gbps × 1ms RTT = 10,000,000 bps × 0.001s = 10,000 bytes = 10KB
    10Gbps × 50ms RTT = 약 6.25MB → 버퍼가 6.25MB 이상이어야 파이프 채움 가능
```

```bash
# net.core: 모든 프로토콜에 적용되는 커널 소켓 버퍼 기본/최대값
net.core.rmem_default = 262144      # 수신 버퍼 기본값 (256KB)
net.core.rmem_max = 134217728       # 수신 버퍼 최대값 (128MB)
net.core.wmem_default = 262144      # 송신 버퍼 기본값
net.core.wmem_max = 134217728       # 송신 버퍼 최대값

# net.ipv4.tcp_rmem/wmem: TCP 전용, [최소, 기본, 최대] 3가지 값
# 커널이 트래픽에 따라 최소~최대 사이에서 동적으로 조정
net.ipv4.tcp_rmem = 4096 131072 134217728
net.ipv4.tcp_wmem = 4096 16384 134217728

# tcp_mem: TCP 전체가 사용할 수 있는 메모리 페이지 수 [최소, 압박, 최대]
# 단위: 페이지 (4KB)
net.ipv4.tcp_mem = 786432 1048576 26777216

# 자동 튜닝 활성화: 커널이 RTT와 BDP를 보고 자동으로 버퍼 크기를 조절
net.ipv4.tcp_moderate_rcvbuf = 1
```

### 2.5 Jumbo Frame (MTU 9001) - AWS 환경

AWS VPC 내부 통신은 MTU 9001의 Jumbo Frame을 지원한다. 기본 MTU 1500 대신 9001을 사용하면 CPU 오버헤드(패킷 처리 횟수)를 줄이고 처리량을 높인다.

```
MTU 1500:  10GB 데이터 = 약 6,666,667 패킷 처리
MTU 9001:  10GB 데이터 = 약 1,111,222 패킷 처리 → CPU 부하 약 83% 감소
```

```bash
# MTU 확인
ip link show eth0

# Jumbo Frame 설정 (AWS EC2, VPC 내부 통신에만 적용)
ip link set eth0 mtu 9001

# 영구 적용 (Amazon Linux 2)
echo 'MTU=9001' >> /etc/sysconfig/network-scripts/ifcfg-eth0

# PMTUD (Path MTU Discovery) 활성화 확인
# VPN 또는 터널 구간에서 ICMP fragmentation needed 차단 시 문제 발생
sysctl net.ipv4.ip_no_pmtu_disc  # 0이 정상
```

> **주의**: Jumbo Frame은 VPC 내부(EC2 간)에만 유효하다. 인터넷 게이트웨이(IGW)를 경유하는 트래픽은 여전히 MTU 1500이 적용된다. Mixed 환경에서 MSS clamping 없이 사용하면 패킷 드롭이 발생한다.

```bash
# MSS clamping으로 Jumbo Frame 환경에서의 외부 통신 보호
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN \
  -j TCPMSS --clamp-mss-to-pmtu
```

### 2.6 기타 중요 파라미터

```bash
# 백로그 큐에서 SYN 쿠키 사용 (SYN Flood 방어)
net.ipv4.tcp_syncookies = 1

# 연결 유지 확인 (keepalive): 유휴 연결 조기 정리
net.ipv4.tcp_keepalive_time = 60    # 유휴 후 첫 probe 전 대기 시간 (기본 7200초)
net.ipv4.tcp_keepalive_intvl = 10   # probe 간격
net.ipv4.tcp_keepalive_probes = 3   # 실패 허용 probe 수

# 파일 디스크립터 한도: 각 소켓은 fd를 하나 사용
fs.file-max = 2097152               # 커널 전체 한도
# ulimit -n 65536 또는 /etc/security/limits.conf 에서 프로세스 단위 설정

# 네트워크 장치 수신 큐 크기
net.core.netdev_max_backlog = 65536 # NIC에서 커널로 전달 대기 패킷 수
net.core.optmem_max = 25165824      # 소켓 옵션 메모리 최대값
```

### 2.7 nginx/HAProxy 고트래픽 서버 완전한 sysctl.conf

```ini
# /etc/sysctl.d/99-network-tuning.conf
# nginx/HAProxy 앞단 고트래픽 서버용 TCP 튜닝

# ────────────────────────────────────────────
# SYN/Accept Queue
# ────────────────────────────────────────────
net.core.somaxconn = 65536
net.ipv4.tcp_max_syn_backlog = 65536

# ────────────────────────────────────────────
# TIME_WAIT 관리
# ────────────────────────────────────────────
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.ip_local_port_range = 1024 65535

# ────────────────────────────────────────────
# 소켓 버퍼
# ────────────────────────────────────────────
net.core.rmem_default = 262144
net.core.rmem_max = 134217728
net.core.wmem_default = 262144
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 131072 134217728
net.ipv4.tcp_wmem = 4096 16384 134217728
net.ipv4.tcp_mem = 786432 1048576 26777216
net.ipv4.tcp_moderate_rcvbuf = 1

# ────────────────────────────────────────────
# 연결 큐 및 NIC
# ────────────────────────────────────────────
net.core.netdev_max_backlog = 65536
net.core.optmem_max = 25165824

# ────────────────────────────────────────────
# Keepalive (유휴 연결 조기 회수)
# ────────────────────────────────────────────
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 3

# ────────────────────────────────────────────
# 보안 / 안정성
# ────────────────────────────────────────────
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 1            # TIME_WAIT 중 RST 패킷 무시
net.ipv4.conf.all.rp_filter = 1    # 역방향 경로 검증

# ────────────────────────────────────────────
# 파일 디스크립터
# ────────────────────────────────────────────
fs.file-max = 2097152
```

```bash
# 즉시 적용
sysctl -p /etc/sysctl.d/99-network-tuning.conf

# 전체 재로드
sysctl --system
```

### 2.8 Ansible로 배포

```yaml
# roles/network-tuning/tasks/main.yml
---
- name: sysctl 튜닝 파라미터 적용
  ansible.posix.sysctl:
    name: "{{ item.key }}"
    value: "{{ item.value }}"
    sysctl_file: /etc/sysctl.d/99-network-tuning.conf
    state: present
    reload: yes
  loop:
    - { key: "net.core.somaxconn",               value: "65536" }
    - { key: "net.ipv4.tcp_max_syn_backlog",      value: "65536" }
    - { key: "net.ipv4.tcp_tw_reuse",             value: "1" }
    - { key: "net.ipv4.tcp_timestamps",           value: "1" }
    - { key: "net.ipv4.tcp_fin_timeout",          value: "15" }
    - { key: "net.ipv4.ip_local_port_range",      value: "1024 65535" }
    - { key: "net.core.rmem_max",                 value: "134217728" }
    - { key: "net.core.wmem_max",                 value: "134217728" }
    - { key: "net.ipv4.tcp_rmem",                 value: "4096 131072 134217728" }
    - { key: "net.ipv4.tcp_wmem",                 value: "4096 16384 134217728" }
    - { key: "net.core.netdev_max_backlog",        value: "65536" }
    - { key: "net.ipv4.tcp_keepalive_time",       value: "60" }
    - { key: "net.ipv4.tcp_syncookies",           value: "1" }
    - { key: "fs.file-max",                       value: "2097152" }
  tags: sysctl

- name: /etc/security/limits.conf에 nofile 한도 설정
  blockinfile:
    path: /etc/security/limits.conf
    marker: "# {mark} ANSIBLE MANAGED - network tuning"
    block: |
      * soft nofile 65536
      * hard nofile 65536
      root soft nofile 65536
      root hard nofile 65536
  tags: limits

- name: nginx가 설치된 경우 worker_connections 설정 확인
  lineinfile:
    path: /etc/nginx/nginx.conf
    regexp: '^\s*worker_connections'
    line: '    worker_connections 65536;'
  when: ansible_facts.packages['nginx'] is defined
  notify: reload nginx
  tags: nginx
```

### 2.9 튜닝 효과 검증

```bash
# 연결 상태 분포 확인
ss -ant | awk 'NR>1 {print $1}' | sort | uniq -c | sort -rn

# TIME_WAIT 수 모니터링
watch -n 1 'ss -ant | grep -c TIME-WAIT'

# TCP 오류 카운터 확인 (튜닝 전후 비교)
netstat -s | grep -E "segments|retransmit|failed|overflow"

# iperf3로 처리량 측정 (내부 서버 간)
iperf3 -s                           # 서버
iperf3 -c <서버IP> -t 30 -P 4      # 클라이언트, 30초, 4 스트림
```

---

## 3. 자주 하는 실수

| 실수 | 올바른 방법 |
|---|---|
| `tcp_tw_recycle = 1` 설정 | Linux 4.12+에서 제거된 파라미터. NAT 환경에서 패킷 드롭 발생. `tcp_tw_reuse = 1`을 사용 |
| `somaxconn`만 올리고 nginx `backlog` 미설정 | `listen 80 backlog=65535;`로 애플리케이션 레벨도 함께 설정 |
| `rmem_max`만 올리고 `tcp_rmem` 미설정 | `tcp_rmem`의 3번째 값(최대)도 `rmem_max`와 동일하게 설정 |
| 재부팅 후 설정 소멸 | `/etc/sysctl.d/` 하위 `.conf` 파일로 영구 적용 (`sysctl -w`는 임시) |
| Jumbo Frame을 인터넷 facing 인터페이스에 적용 | VPC 내부 인터페이스에만 MTU 9001 적용. 외부 통신은 여전히 1500 |
| `fs.file-max` 올리고 `ulimit -n` 미설정 | 커널 한도와 프로세스 한도를 모두 올려야 함 (`/etc/security/limits.conf`) |
| SYN cookie를 끔 (`tcp_syncookies = 0`) | SYN Flood 공격에 무방비. 항상 1로 유지 |
| 단일 서버 테스트 후 전체 적용 | 스테이징에서 `netstat -s` 오류 카운터로 효과 검증 후 점진적 롤아웃 |
