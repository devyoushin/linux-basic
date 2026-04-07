# linux-nftables.md — nftables: iptables 후계자, 현대적 패킷 필터링

## 1. 개요

nftables는 2014년 Linux 3.13부터 병합된 차세대 패킷 필터링 프레임워크로, iptables/ip6tables/arptables/ebtables를 하나로 통합한다. 단일 규칙셋으로 IPv4/IPv6/ARP/Bridge를 동시에 처리할 수 있으며, 집합(set)과 맵(map) 자료구조로 수천 개의 IP 규칙을 O(1)으로 조회한다. RHEL 8+, Debian 10+, Ubuntu 20.04+에서 기본 방화벽으로 채택되었다.

---

## 2. 설명

### 2.1 아키텍처: iptables vs nftables

```
iptables 구조                    nftables 구조
─────────────────                ─────────────────────────────
filter table                     table inet my_filter
  INPUT chain                      chain input {
  FORWARD chain                      type filter hook input priority 0
  OUTPUT chain                       ...
raw table                          }
  PREROUTING chain                 chain forward { ... }
  OUTPUT chain                     chain output { ... }
mangle table                     }
nat table
```

**핵심 차이:**

| 항목 | iptables | nftables |
|---|---|---|
| 테이블 | 고정 (filter/nat/mangle/raw) | 사용자 정의 |
| 체인 | 테이블별 고정 체인 | 훅(hook)에 자유롭게 연결 |
| IP 버전 | iptables(v4), ip6tables(v6) 별도 | `inet` 패밀리로 v4/v6 통합 |
| 집합 조회 | ipset 외부 도구 필요 | 내장 set/map (커널 해시테이블) |
| 성능 | 규칙 수에 비례 O(n) | set/map 사용 시 O(1) |
| 원자적 업데이트 | 없음 (iptables-restore 근사치) | `nft -f`로 원자적 교체 |

### 2.2 테이블 패밀리

```
ip      → IPv4만
ip6     → IPv6만
inet    → IPv4 + IPv6 동시 (실무 권장)
arp     → ARP 패킷
bridge  → 브리지 포워딩 경로
netdev  → NIC 수신 직후 (ingress hook, DDoS 방어에 유용)
```

### 2.3 기본 문법

```bash
# nft 대화형 실행
nft

# 현재 규칙셋 전체 확인
nft list ruleset

# 특정 테이블 확인
nft list table inet filter
```

**기본 방화벽 설정 예시:**

```bash
# /etc/nftables.conf 전체 예시

#!/usr/sbin/nft -f

# 기존 규칙셋 초기화
flush ruleset

# inet: IPv4/IPv6 통합 테이블
table inet filter {

    # 허용할 인바운드 포트 집합 (set은 커널 해시테이블로 O(1) 조회)
    set allowed_tcp_ports {
        type inet_service        # 포트 번호 타입
        flags constant           # 내용 변경 불가 (성능 최적화)
        elements = { 22, 80, 443, 8080 }
    }

    chain input {
        # hook: 패킷이 이 체인을 통과하는 시점
        # priority 0: filter 우선순위 (낮을수록 먼저 처리)
        # policy drop: 명시적으로 허용하지 않은 패킷은 기본 드롭
        type filter hook input priority 0; policy drop;

        # 루프백 인터페이스는 전부 허용
        iif lo accept

        # 기존 연결/관련 패킷 허용 (stateful 방화벽)
        ct state established,related accept

        # invalid 상태 패킷 드롭
        ct state invalid drop

        # ICMP 허용 (ping 등)
        ip protocol icmp accept
        ip6 nexthdr ipv6-icmp accept

        # set을 사용한 포트 허용: tcp dport @집합명
        tcp dport @allowed_tcp_ports accept

        # 로그 남기고 드롭 (디버깅용, 운영 환경에서는 rate limit 적용)
        log prefix "[nft-drop] " drop
    }

    chain forward {
        type filter hook forward priority 0; policy drop;
    }

    chain output {
        type filter hook output priority 0; policy accept;
    }
}
```

### 2.4 set과 map으로 IP 목록 효율적 관리

```bash
# ── set: IP 집합 (멤버십 검사)
table inet filter {
    set blocked_ips {
        type ipv4_addr
        flags dynamic, timeout   # 동적 추가 + 자동 만료
        timeout 1h               # 1시간 후 자동 제거
        size 65536               # 최대 항목 수
    }

    chain input {
        type filter hook input priority 0; policy accept;

        # 차단 목록에 있으면 드롭
        ip saddr @blocked_ips drop

        # DDoS: 초당 10개 초과 시 자동으로 blocked_ips에 추가
        tcp dport 80 ct state new \
            meter ssh_meter { ip saddr timeout 60s limit rate over 100/second } \
            add @blocked_ips { ip saddr timeout 1h } drop
    }
}

# 실시간으로 IP 추가/제거
nft add element inet filter blocked_ips { 192.168.1.100 }
nft delete element inet filter blocked_ips { 192.168.1.100 }
```

```bash
# ── map: IP → 포트 포워딩 테이블 (라우터/NAT 환경)
table ip nat {
    map port_forward {
        type inet_service : ipv4_addr . inet_service
        # 외부 포트 → (내부IP, 내부포트) 매핑
        elements = {
            8001 : 10.0.1.10 . 80,
            8002 : 10.0.1.11 . 80,
            8443 : 10.0.1.10 . 443
        }
    }

    chain prerouting {
        type nat hook prerouting priority -100;
        # map 조회로 단일 규칙으로 다수의 포트 포워딩 처리
        tcp dport map @port_forward dnat to numgen random mod 1 map @port_forward
    }
}
```

### 2.5 iptables 규칙을 nftables로 마이그레이션

```bash
# iptables-translate: 단일 규칙 변환
iptables-translate -A INPUT -p tcp --dport 22 -j ACCEPT
# 출력: nft add rule ip filter INPUT tcp dport 22 counter accept

# iptables-restore-translate: 전체 규칙셋 변환
iptables-save > /tmp/iptables-backup.txt
iptables-restore-translate -f /tmp/iptables-backup.txt > /etc/nftables.conf

# 변환 결과 검토 후 적용
nft -c -f /etc/nftables.conf   # -c: dry-run (실제 적용 없이 문법 검사)
nft -f /etc/nftables.conf      # 실제 적용
```

### 2.6 NAT, 포트 포워딩, Rate Limiting 실전 예제

```bash
#!/usr/sbin/nft -f

flush ruleset

# ── NAT 테이블 (IPv4 전용, NAT은 inet 패밀리 미지원)
table ip nat {

    chain prerouting {
        type nat hook prerouting priority -100;

        # 포트 포워딩: 외부 80 → 내부 서버 10.0.1.10:8080
        iif eth0 tcp dport 80 dnat to 10.0.1.10:8080
    }

    chain postrouting {
        type nat hook postrouting priority 100;

        # Masquerade: 내부 네트워크 → 외부 인터넷 (SNAT 자동화)
        oif eth0 masquerade

        # 특정 서브넷만 SNAT
        ip saddr 192.168.0.0/24 oif eth0 snat to 203.0.113.1
    }
}

# ── 필터 + Rate Limiting
table inet filter {

    chain input {
        type filter hook input priority 0; policy drop;

        iif lo accept
        ct state established,related accept

        # SSH Rate Limiting: 1분에 최대 5회 신규 연결
        tcp dport 22 ct state new \
            limit rate 5/minute burst 10 packets \
            accept

        # SSH 한도 초과 시 드롭 + 로그
        tcp dport 22 ct state new \
            log prefix "[nft-ssh-limit] " drop

        # HTTP/HTTPS 허용
        tcp dport { 80, 443 } accept

        # ICMP 허용 (ping, PTB 등)
        icmp type { echo-request, destination-unreachable, time-exceeded } accept
        icmpv6 type { echo-request, nd-neighbor-solicit, nd-neighbor-advert,
                      nd-router-advert, mld-listener-query } accept
    }

    chain forward {
        type filter hook forward priority 0; policy drop;
        # 내부 서버로의 포워딩 허용 (NAT와 함께 사용)
        ct state established,related accept
        iif eth0 oif eth1 ct state new accept
    }

    chain output {
        type filter hook output priority 0; policy accept;
    }
}
```

### 2.7 Docker/K8s와 nftables 공존 문제

Docker와 Kubernetes는 내부적으로 iptables를 사용한다. nftables와 공존 시 두 가지 백엔드를 주의해야 한다.

```
iptables 백엔드 종류:
  iptables-legacy  → 구 커널 모듈 직접 사용
  iptables-nft     → nftables 커널 인터페이스를 iptables API로 래핑

Docker가 iptables-nft를 사용하면 nft list ruleset에 규칙이 보임.
Docker가 iptables-legacy를 사용하면 nftables와 별개의 규칙셋을 가짐.
```

```bash
# 현재 iptables 백엔드 확인
update-alternatives --list iptables

# iptables-nft로 전환 (nftables와 통합)
update-alternatives --set iptables /usr/sbin/iptables-nft
update-alternatives --set ip6tables /usr/sbin/ip6tables-nft

# Docker와 nftables 공존 시 우선순위 설정
# nftables 규칙을 priority -200 이하로 설정하면 Docker 체인보다 먼저 처리
table inet my_filter {
    chain input {
        type filter hook input priority -200;  # DOCKER-USER 체인보다 먼저
        ...
    }
}
```

> **주의**: K8s kube-proxy는 iptables 또는 ipvs 모드로 동작한다. nftables로 완전 전환 시 kube-proxy의 iptables 규칙이 충돌할 수 있다. K8s 1.29+부터 nftables 네이티브 kube-proxy 지원이 실험적으로 추가되었다.

### 2.8 영구 적용

```bash
# 현재 규칙셋을 파일로 저장
nft list ruleset > /etc/nftables.conf

# 서비스 활성화 (부팅 시 자동 적용)
systemctl enable nftables
systemctl start nftables

# 규칙 수정 후 재적용
nft -f /etc/nftables.conf

# 규칙 초기화 (모든 규칙 삭제)
nft flush ruleset
```

### 2.9 Ansible로 nftables 관리

```yaml
# roles/nftables/tasks/main.yml
---
- name: nftables 패키지 설치
  package:
    name: nftables
    state: present

- name: nftables 설정 파일 배포
  template:
    src: nftables.conf.j2
    dest: /etc/nftables.conf
    owner: root
    group: root
    mode: '0644'
    validate: 'nft -c -f %s'   # 배포 전 문법 검사
  notify: reload nftables

- name: nftables 서비스 활성화
  systemd:
    name: nftables
    enabled: yes
    state: started

handlers:
  - name: reload nftables
    systemd:
      name: nftables
      state: reloaded
```

```jinja2
{# templates/nftables.conf.j2 #}
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
    set allowed_ports {
        type inet_service
        flags constant
        elements = { {{ nftables_allowed_ports | join(', ') }} }
    }

    chain input {
        type filter hook input priority 0; policy drop;
        iif lo accept
        ct state established,related accept
        ct state invalid drop
        tcp dport @allowed_ports accept
        icmp type echo-request accept
    }

    chain output {
        type filter hook output priority 0; policy accept;
    }

    chain forward {
        type filter hook forward priority 0; policy drop;
    }
}
```

### 2.10 트러블슈팅

```bash
# 패킷 카운터로 규칙 매칭 확인
nft list ruleset -a   # 규칙에 핸들(handle) 번호 표시
nft list table inet filter   # packets/bytes 카운터 확인

# 특정 규칙에 카운터 추가
nft add rule inet filter input tcp dport 80 counter accept

# nftables 트레이싱 (패킷 추적)
nft add rule inet filter input meta nftrace set 1
nft monitor trace   # 트레이스 출력 실시간 확인

# 규칙 삭제 (핸들 번호로)
nft delete rule inet filter input handle 5
```

---

## 3. 자주 하는 실수

| 실수 | 올바른 방법 |
|---|---|
| `flush ruleset` 없이 `-f` 적용 | 파일 상단에 `flush ruleset` 포함하여 기존 규칙 완전 교체 |
| `inet` 패밀리에서 NAT 설정 | NAT는 `ip` (IPv4) 또는 `ip6` 패밀리로 별도 테이블 생성 |
| set에 `flags interval` 없이 CIDR 사용 | `set blocked_cidrs { type ipv4_addr; flags interval; }` 설정 필요 |
| iptables와 nftables 규칙 혼용 | 백엔드를 `iptables-nft`로 통일하거나 완전 분리 |
| `policy drop` 설정 후 SSH 연결 차단 | 정책 변경 전 SSH(22) 허용 규칙을 반드시 먼저 추가 |
| 규칙 적용 후 재부팅 시 소멸 | `nft list ruleset > /etc/nftables.conf` + `systemctl enable nftables` |
| Docker 재시작 시 방화벽 규칙 초기화 | priority를 Docker 체인보다 낮게 (-200 이하) 설정 |
| `rate limit` 단위 혼동 | `limit rate 100/second`는 초당 100패킷, `burst`는 순간 허용치 |
