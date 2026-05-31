# sysctl - 커널 파라미터 튜닝 (네트워크/메모리/파일시스템)

## 1. 개요

`sysctl`은 실행 중인 커널의 파라미터를 런타임에 조회하고 변경하는 인터페이스다.
`/proc/sys/` 아래의 가상 파일 시스템이 실체이며, 네트워크 스택 튜닝, 메모리 관리 정책,
파일 디스크립터 한계 등 수백 개의 커널 동작을 제어할 수 있다.
고트래픽 웹서버, 데이터베이스, K8s 노드는 기본값으로는 운영이 어렵고,
목적에 맞는 튜닝이 성능과 안정성을 결정한다.

---

## 2. 설명

### 2-1. sysctl 작동 원리

```
┌────────────────────────────────────────────────────────────┐
│                 sysctl 인터페이스 구조                     │
│                                                            │
│  설정 소스 (우선순위 낮음 → 높음)                         │
│  ┌──────────────────────────────────────────────────────┐ │
│  │  /etc/sysctl.conf          (기본 설정 파일)           │ │
│  │  /etc/sysctl.d/*.conf      (드롭-인 설정 디렉토리)    │ │
│  │  /usr/lib/sysctl.d/*.conf  (패키지 기본값)            │ │
│  │  /run/sysctl.d/*.conf      (임시, 재부팅 시 소멸)     │ │
│  │  sysctl -w (런타임 변경)   (재부팅 시 초기화)         │ │
│  └──────────────────────────────────────────────────────┘ │
│                          │                                 │
│                          ▼                                 │
│  ┌──────────────── /proc/sys/ ─────────────────────────┐  │
│  │  /proc/sys/net/    → 네트워크 파라미터               │  │
│  │  /proc/sys/vm/     → 가상 메모리 파라미터            │  │
│  │  /proc/sys/fs/     → 파일시스템 파라미터             │  │
│  │  /proc/sys/kernel/ → 커널 일반 파라미터              │  │
│  └─────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────┘
```

```bash
# 현재 값 조회
sysctl net.core.somaxconn          # 특정 파라미터
sysctl -a                          # 전체 파라미터 목록
sysctl -a 2>/dev/null | grep tcp   # TCP 관련만 필터링

# 런타임 변경 (재부팅 시 초기화)
sysctl -w net.core.somaxconn=65536

# /proc/sys/ 직접 변경 (동일 효과)
echo 65536 > /proc/sys/net/core/somaxconn

# 설정 파일 로드 (재부팅 없이 영구 적용)
sysctl -p /etc/sysctl.conf         # 특정 파일 로드
sysctl --system                    # 모든 설정 파일 로드 (우선순위 순서대로)

# 영구 설정 파일 작성
cat > /etc/sysctl.d/99-custom.conf << 'EOF'
# 고트래픽 웹서버 설정
net.core.somaxconn = 65536
net.ipv4.tcp_tw_reuse = 1
EOF
sysctl --system   # 즉시 적용
```

### 2-2. 네트워크 튜닝 파라미터

**연결 대기열 관련**

```
클라이언트 연결 요청
        │
        ▼
┌───────────────────────────────────────────────────────┐
│         TCP 3-way Handshake 진행 중                   │
│   SYN_RCVD 상태 연결 저장 (SYN Backlog Queue)         │
│   크기: net.ipv4.tcp_max_syn_backlog (기본: 128)      │
└──────────────────────────┬────────────────────────────┘
                           │ handshake 완료
                           ▼
┌───────────────────────────────────────────────────────┐
│         ESTABLISHED 상태, app accept() 대기           │
│   Accept Queue (Listen Backlog)                       │
│   크기: min(somaxconn, listen() backlog 인자)         │
│   net.core.somaxconn (기본: 128/512)                  │
└──────────────────────────┬────────────────────────────┘
                           │ accept() 호출
                           ▼
                    애플리케이션 처리
```

```bash
# accept queue 용량 (소켓 listen backlog 상한)
sysctl -w net.core.somaxconn=65536
# nginx/Nginx: worker_processes 높아도 이 값이 낮으면 연결 거부 발생
# ss -lnt 에서 Send-Q가 somaxconn에 가까워지면 증가 필요

# SYN backlog 크기
sysctl -w net.ipv4.tcp_max_syn_backlog=65536

# 전체 소켓 수 상한
sysctl -w net.core.netdev_max_backlog=250000
```

**TIME_WAIT 최적화**

```bash
# TIME_WAIT 소켓 재사용 (아웃바운드 연결에서 포트 재사용)
sysctl -w net.ipv4.tcp_tw_reuse=1
# 효과: 로드밸런서, 프록시처럼 많은 외부 연결을 맺는 서버에서 포트 고갈 방지
# 주의: 동일 주소/포트로 재연결 시 오래된 패킷과 충돌 가능 (드물지만 발생)
# net.ipv4.tcp_tw_recycle은 리눅스 4.12에서 제거됨 (NAT 환경에서 문제)

# FIN_WAIT2 타임아웃 (기본 60초)
sysctl -w net.ipv4.tcp_fin_timeout=15
# 효과: FIN_WAIT2 상태 소켓이 빠르게 정리됨

# TIME_WAIT 소켓 최대 수
sysctl -w net.ipv4.tcp_max_tw_buckets=1440000
```

**소켓 버퍼 크기**

```bash
# 소켓 수신 버퍼 (min / default / max, 바이트)
sysctl -w net.core.rmem_default=262144      # 기본값 256KB
sysctl -w net.core.rmem_max=134217728       # 최대 128MB

# 소켓 송신 버퍼
sysctl -w net.core.wmem_default=262144
sysctl -w net.core.wmem_max=134217728

# TCP 수신 버퍼 자동 조정 (min / default / max)
sysctl -w net.ipv4.tcp_rmem="4096 87380 134217728"

# TCP 송신 버퍼 자동 조정
sysctl -w net.ipv4.tcp_wmem="4096 65536 134217728"

# 고대역폭 고지연 네트워크 (BDP = 대역폭 × RTT)
# 1Gbps × 100ms RTT = 12.5MB 필요 → tcp_rmem max 최소 12.5MB 이상

# TCP 버퍼 자동 조정 활성화
sysctl -w net.ipv4.tcp_moderate_rcvbuf=1
```

**Keep-alive 및 기타**

```bash
# TCP keep-alive 시작 시간 (기본 7200초 = 2시간)
sysctl -w net.ipv4.tcp_keepalive_time=60
# 효과: 죽은 연결을 빠르게 감지 (특히 로드밸런서 뒤 서버)

# keep-alive 재전송 간격
sysctl -w net.ipv4.tcp_keepalive_intvl=10

# keep-alive 재전송 횟수
sysctl -w net.ipv4.tcp_keepalive_probes=6

# 로컬 포트 범위 (아웃바운드 연결용 임시 포트)
sysctl -w net.ipv4.ip_local_port_range="1024 65535"
# 기본값: 32768 60999 → 약 28000개. 많은 아웃바운드 연결 시 고갈 위험

# IP 포워딩 (라우터/NAT/K8s 노드에서 필수)
sysctl -w net.ipv4.ip_forward=1
```

### 2-3. 메모리 튜닝 파라미터

```bash
# Swap 사용 경향 (0=최소화, 100=적극적, 기본=60)
sysctl -w vm.swappiness=10
# 데이터베이스 서버: 1~10 (메모리를 최대한 사용)
# 일반 서버: 20~40
# K8s 노드: 0 (swap 사용 시 kubelet 오류 발생 가능)

# 더티 페이지 비율 (메모리 대비 더티 캐시 최대 비율, 기본 20%)
sysctl -w vm.dirty_ratio=15
# 이 비율 초과 시 write() 호출이 블로킹 → 쓰기 레이턴시 스파이크 발생
# 데이터베이스: 5~10% (직접 fsync 관리하므로 OS 더티 캐시 최소화)

# 백그라운드 더티 페이지 플러시 시작 비율 (기본 10%)
sysctl -w vm.dirty_background_ratio=5
# dirty_ratio에 도달하기 전에 미리 플러시 시작

# 더티 페이지 최대 유지 시간 (단위: 1/100초, 기본 3000 = 30초)
sysctl -w vm.dirty_expire_centisecs=1500  # 15초로 단축

# 메모리 오버커밋 정책
sysctl -w vm.overcommit_memory=1
# 0: 발견적 오버커밋 (기본, 합리적 요청은 허용)
# 1: 항상 허용 (malloc은 항상 성공, 실제 사용 시 OOM 위험)
# 2: 오버커밋 금지 (swap + 물리메모리 × overcommit_ratio 이내만 허용)
# Redis, 빠른 fork가 필요한 앱: vm.overcommit_memory=1 권장

# OOM killer 점수 조정 (특정 프로세스 보호)
echo -500 > /proc/$(pgrep mysqld)/oom_score_adj  # mysqld 보호 (-1000~1000)
echo 300  > /proc/$(pgrep chrome)/oom_score_adj   # chrome은 먼저 종료

# NUMA 메모리 정책 (멀티소켓 시스템)
sysctl -w vm.zone_reclaim_mode=0
# 0: 다른 NUMA 노드 메모리 사용 허용 (대부분 환경에서 더 좋음)
# 1: 로컬 NUMA 노드 먼저 회수 (NUMA 지역성 우선)
```

### 2-4. 파일시스템 파라미터

```bash
# 시스템 전체 최대 파일 디스크립터 수
sysctl -w fs.file-max=2097152
# 현재 사용량 확인: cat /proc/sys/fs/file-nr (used/free/max)
# 프로세스별 제한은 ulimit -n (PAM/systemd LimitNOFILE 설정)

# inotify 감시 수 (파일 변경 모니터링)
sysctl -w fs.inotify.max_user_watches=524288
# 기본값: 8192 → IDE, 파일 동기화 도구, Prometheus 파일 감시에서 부족
# K8s 노드에서 많은 Pod 실행 시 증가 필요

# inotify 인스턴스 수
sysctl -w fs.inotify.max_user_instances=512

# 파이프 최대 크기 (바이트, 기본 1MB)
sysctl -w fs.pipe-max-size=2097152

# 소켓 파일 디스크립터 수 (aio 요청 수)
sysctl -w fs.aio-max-nr=1048576
```

### 2-5. 목적별 권장 설정 프로파일

**고트래픽 웹서버 (Nginx/HAProxy)**

```ini
# /etc/sysctl.d/99-webserver.conf

# TCP 연결 대기열
net.core.somaxconn = 65536
net.ipv4.tcp_max_syn_backlog = 65536
net.core.netdev_max_backlog = 250000

# TIME_WAIT 최적화
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_tw_buckets = 1440000

# 포트 범위 확장
net.ipv4.ip_local_port_range = 1024 65535

# 소켓 버퍼
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728

# keep-alive
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6

# 파일 디스크립터
fs.file-max = 2097152
```

**데이터베이스 서버 (MySQL/PostgreSQL)**

```ini
# /etc/sysctl.d/99-database.conf

# 메모리: swap 최소화, 더티 캐시 줄이기
vm.swappiness = 5
vm.dirty_ratio = 5
vm.dirty_background_ratio = 2
vm.dirty_expire_centisecs = 500

# 오버커밋 (PostgreSQL fork 성능)
vm.overcommit_memory = 2
vm.overcommit_ratio = 80

# NUMA (멀티소켓 서버)
vm.zone_reclaim_mode = 0
kernel.numa_balancing = 0   # DB는 NUMA 자동 밸런싱 끄는 것이 성능 좋은 경우 있음

# 네트워크 (DB 연결용)
net.core.somaxconn = 65536
net.ipv4.tcp_keepalive_time = 120

# 파일
fs.file-max = 2097152
fs.aio-max-nr = 1048576
```

**K8s 노드**

```ini
# /etc/sysctl.d/99-kubernetes.conf

# K8s 필수 설정
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1   # iptables가 브리지 트래픽 처리
net.bridge.bridge-nf-call-ip6tables = 1

# Swap 비활성화 (kubelet 기본 요구사항)
vm.swappiness = 0

# 연결 추적 테이블 크기 (많은 Pod/Service 시 필요)
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_buckets = 262144

# inotify (파일 감시 많음)
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512

# 소켓/파일
fs.file-max = 2097152
net.core.somaxconn = 65536

# 메모리 오버커밋 (컨테이너 메모리 요청 처리)
vm.overcommit_memory = 1
```

### 2-6. Ansible로 sysctl 설정 배포

```yaml
# roles/sysctl-tuning/tasks/main.yml
---
- name: sysctl 프로파일 결정
  set_fact:
    sysctl_profile: "{{ 'database' if 'db' in group_names else
                        'kubernetes' if 'k8s' in group_names else
                        'webserver' }}"

- name: sysctl 설정 파일 배포
  template:
    src: "sysctl-{{ sysctl_profile }}.conf.j2"
    dest: "/etc/sysctl.d/99-{{ sysctl_profile }}.conf"
    owner: root
    group: root
    mode: '0644'
  notify: sysctl 적용

- name: br_netfilter 모듈 로드 (K8s 노드)
  modprobe:
    name: br_netfilter
    state: present
  when: sysctl_profile == 'kubernetes'

- name: 모듈 부팅 시 자동 로드 설정
  copy:
    dest: /etc/modules-load.d/k8s.conf
    content: |
      br_netfilter
      overlay
  when: sysctl_profile == 'kubernetes'

handlers:
- name: sysctl 적용
  command: sysctl --system
  changed_when: true
```

```yaml
# roles/sysctl-tuning/templates/sysctl-webserver.conf.j2
# 웹서버 sysctl 설정 - Ansible 관리 파일, 직접 수정 금지

net.core.somaxconn = {{ sysctl_somaxconn | default(65536) }}
net.ipv4.tcp_max_syn_backlog = {{ sysctl_tcp_max_syn_backlog | default(65536) }}
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = {{ sysctl_tcp_fin_timeout | default(15) }}
net.ipv4.ip_local_port_range = 1024 65535
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
fs.file-max = 2097152
```

```yaml
# group_vars/webservers.yml
sysctl_somaxconn: 65536
sysctl_tcp_fin_timeout: 10
```

### 2-7. 현재 설정 검증 및 모니터링

```bash
# 설정이 실제로 적용됐는지 확인
sysctl net.core.somaxconn

# 소켓 통계로 drop 여부 확인 (listen overflow)
ss -s
# TCP:   estab 1234, closed 56, orphaned 7, timewait 890
# 또는
netstat -s | grep -E 'overflow|drop|listen'
# X times the listen queue of a socket overflowed → somaxconn 부족 징후

# 파일 디스크립터 사용량
cat /proc/sys/fs/file-nr
# 출력: 사용중   0(예약)   최대
# 예: 65432     0     2097152

# conntrack 테이블 사용량 (K8s/iptables 환경)
cat /proc/sys/net/netfilter/nf_conntrack_count
cat /proc/sys/net/netfilter/nf_conntrack_max
# count가 max의 80% 이상 → nf_conntrack_max 증가 필요

# TIME_WAIT 소켓 수
ss -ant | grep TIME-WAIT | wc -l

# 더티 메모리 현황
cat /proc/meminfo | grep -E 'Dirty|Writeback'
```

---

## 3. 자주 하는 실수

| 실수 | 증상 / 문제 | 올바른 방법 |
|---|---|---|
| `sysctl -w`로만 설정 (파일 미작성) | 재부팅 후 설정 초기화 | `/etc/sysctl.d/99-custom.conf`에 영구 저장 후 `sysctl --system` |
| `net.ipv4.tcp_tw_recycle=1` 설정 | 커널 4.12 이상에서 파라미터 없음. NAT 환경에서 연결 오류 | 해당 파라미터 삭제됨. `tcp_tw_reuse=1` 로 대체 |
| K8s 노드에서 `vm.swappiness=0` 미설정 | kubelet이 swap 감지 시 오류로 노드 NotReady | `vm.swappiness=0` 설정 + `swapoff -a` + fstab swap 비활성화 |
| `net.bridge.bridge-nf-call-iptables` 설정 시 0 반환 | br_netfilter 모듈 미로드 상태 | `modprobe br_netfilter` 먼저 실행 후 sysctl 설정 |
| `somaxconn` 올렸는데 연결 거부 지속 | 앱의 `listen()` backlog 인자가 낮음 | 앱 소스에서 `listen(fd, backlog)` 값도 함께 증가 (Nginx: backlog 지시어) |
| `vm.dirty_ratio` 너무 낮게 설정 | 쓰기 성능 저하, write() 과도한 대기 | 데이터베이스: 5%, 일반 서버: 15~20% 유지 |
| `fs.inotify.max_user_watches` 미설정 | `inotify watch limit reached` 에러 | `524288` 이상으로 설정 (특히 K8s, IDE 환경) |
| 프로덕션에서 검증 없이 대량 파라미터 적용 | 예상치 못한 성능 저하 또는 불안정 | 스테이징 환경에서 부하 테스트 후 단계적 적용 |
