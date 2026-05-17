# iptables 상태 기반 필터링과 conntrack 연동

## 1. 개요

`iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT`는 Linux 방화벽의 핵심 관용구다. 이 한 줄이 없으면 서버가 먼저 시작한 연결(outbound 응답, FTP 데이터 채널 등)의 반환 패킷이 모두 차단된다. 이 규칙이 동작하려면 커널의 `nf_conntrack` 서브시스템이 모든 연결 상태를 추적하고 있어야 한다. 본 문서는 이 명령어 하나를 해부하면서 Netfilter/conntrack 연동 구조 전체를 설명한다.

---

## 2. 설명

### 2.1 명령어 해부

```
iptables  -A INPUT  -m conntrack  --ctstate ESTABLISHED,RELATED  -j ACCEPT
│          │         │              │                               │
│          │         │              │                               └─ 액션: 패킷 허용
│          │         │              └─ conntrack 상태 조건: 기존 연결 or 관련 연결
│          │         └─ conntrack 매칭 모듈 로드
│          └─ INPUT 체인에 규칙 추가 (append)
└─ iptables 명령어 (filter 테이블 기본)
```

각 구성 요소의 역할:

| 구성 요소 | 역할 |
|-----------|------|
| `-A INPUT` | filter 테이블의 INPUT 체인 마지막에 규칙 추가 |
| `-m conntrack` | `nf_conntrack` 커널 모듈을 매칭 확장으로 로드 |
| `--ctstate` | conntrack 테이블에서 해당 패킷의 연결 상태를 조회 |
| `ESTABLISHED` | 3-way 핸드셰이크 완료된 연결의 패킷 |
| `RELATED` | 기존 연결에서 파생된 새 연결의 패킷 (FTP 데이터 등) |
| `-j ACCEPT` | 조건에 매칭된 패킷을 허용 |

> **참고**: `-m state --state`는 구형 방식이다. `-m conntrack --ctstate`가 더 많은 상태를 지원하며 현재 권장 방식이다.

---

### 2.2 Netfilter 아키텍처와 conntrack의 위치

패킷이 커널을 통과하는 경로와 conntrack이 개입하는 지점을 이해해야 이 규칙의 동작을 정확히 알 수 있다.

```
                        [인터페이스 수신]
                               │
                    ┌──────────▼──────────┐
                    │  PREROUTING 훅      │ ← conntrack: 연결 조회/생성
                    │  (raw → mangle      │   (여기서 ctstate 결정됨)
                    │   → nat → conntrack)│
                    └──────────┬──────────┘
                               │
              ┌────────────────┴──────────────────┐
              │ 로컬 프로세스行?                    │
         YES  ▼                              NO   ▼
    ┌─────────────────┐                ┌──────────────────┐
    │  INPUT 훅       │                │  FORWARD 훅      │
    │  (mangle        │                │  (mangle         │
    │   → filter)     │                │   → filter)      │
    │  ← 이 규칙 위치  │                └────────┬─────────┘
    └────────┬────────┘                         │
             │                       ┌──────────▼──────────┐
    ┌────────▼────────┐              │  POSTROUTING 훅     │
    │  로컬 프로세스   │              │  (mangle → nat      │
    │  (응답 생성)    │               │   → conntrack)      │
    └────────┬────────┘              └─────────────────────┘
             │
    ┌────────▼────────┐
    │  OUTPUT 훅      │ ← conntrack: 응답 패킷 상태 갱신
    │  (raw → mangle  │
    │   → nat         │
    │   → filter)     │
    └────────┬────────┘
             │
    ┌────────▼────────┐
    │  POSTROUTING 훅 │
    └─────────────────┘
```

**conntrack이 ctstate를 결정하는 시점**: PREROUTING(수신 패킷) 또는 OUTPUT(송신 패킷) 훅에서 패킷을 conntrack 테이블과 대조한다. INPUT 체인의 `-m conntrack --ctstate` 규칙은 이미 PREROUTING에서 확정된 상태를 조회하기만 한다.

---

### 2.3 ctstate 전체 값 상세 설명

#### NEW — 새 연결 시작

```
Client → SYN → Server
```

conntrack 테이블에 이 패킷에 해당하는 엔트리가 없다. 새 연결의 첫 번째 패킷(TCP의 경우 SYN)이다.

```bash
# NEW 연결만 허용 (포트 22)
iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW -j ACCEPT
```

#### ESTABLISHED — 완성된 연결의 패킷

```
Client → SYN     → Server  (NEW)
Client ← SYN-ACK ← Server
Client → ACK     → Server  (이후부터 ESTABLISHED)
Client ← DATA    ← Server  (ESTABLISHED ← 이 규칙이 허용)
```

conntrack 테이블에 양방향 패킷이 기록된 연결이다. 서버 → 클라이언트 방향의 응답 패킷도 ESTABLISHED로 분류된다.

```bash
# ESTABLISHED 패킷 허용 (응답 트래픽 통과)
iptables -A INPUT -m conntrack --ctstate ESTABLISHED -j ACCEPT
```

#### RELATED — 기존 연결에서 파생된 새 연결

기존 ESTABLISHED 연결과 논리적으로 연관된 **새로운** 연결이다. 대표 사례:

| 프로토콜 | RELATED가 발생하는 경우 | 필요한 helper 모듈 |
|----------|------------------------|--------------------|
| FTP (Active) | 제어 채널(21)에서 데이터 채널(20) 연결 파생 | `nf_conntrack_ftp` |
| FTP (Passive) | 제어 채널에서 고포트 데이터 채널 파생 | `nf_conntrack_ftp` |
| ICMP 에러 | TCP 연결 관련 ICMP Unreachable/Port Unreachable | (기본 내장) |
| SIP | 시그널링 채널에서 RTP 미디어 스트림 파생 | `nf_conntrack_sip` |
| H.323 | H.225 채널에서 H.245 채널 파생 | `nf_conntrack_h323` |

```bash
# FTP RELATED 연결을 위한 helper 모듈 로드
modprobe nf_conntrack_ftp

# 모듈 로드 확인
lsmod | grep conntrack_ftp

# 영구 로드 (/etc/modules-load.d/conntrack.conf)
echo "nf_conntrack_ftp" >> /etc/modules-load.d/conntrack.conf
```

#### INVALID — 상태 불명 패킷

conntrack 테이블에서 어떤 연결과도 매칭되지 않고, NEW로도 분류할 수 없는 패킷이다. 패킷 손상, 시퀀스 번호 이상, 스캔 탐지 등에서 발생한다.

```bash
# INVALID 패킷 즉시 DROP (로깅 포함)
iptables -A INPUT -m conntrack --ctstate INVALID \
  -j LOG --log-prefix "INVALID_DROP: " --log-level 4
iptables -A INPUT -m conntrack --ctstate INVALID -j DROP
```

#### UNTRACKED — conntrack 추적 제외 패킷

`-t raw -j NOTRACK` 규칙으로 명시적으로 conntrack을 우회한 패킷이다.

```bash
# 특정 포트 conntrack 우회 설정 예시
iptables -t raw -A PREROUTING -p udp --dport 53 -j NOTRACK
iptables -t raw -A OUTPUT -p udp --sport 53 -j NOTRACK

# UNTRACKED 패킷 별도 허용 규칙 필요 (ESTABLISHED 규칙이 미적용)
iptables -A INPUT -m conntrack --ctstate UNTRACKED -j ACCEPT
```

#### DNAT / SNAT — NAT 처리된 패킷

NAT 테이블에서 주소 변환이 적용된 패킷이다. DNAT는 PREROUTING에서, SNAT는 POSTROUTING에서 적용된다.

```bash
# DNAT된 연결 확인 (포트 포워딩)
conntrack -L | grep DNAT
# tcp  6  86389  ESTABLISHED  src=1.2.3.4 dst=5.6.7.8 sport=54321 dport=80 \
#                              src=10.0.0.5 dst=1.2.3.4 sport=80 dport=54321 [DNAT]
```

---

### 2.4 상태 전이 다이어그램 (TCP)

```
    패킷 도착
        │
        ▼
   conntrack 테이블 조회
        │
   ┌────┴──────────────────────────────────────┐
   │ 매칭 엔트리 있음?                          │
   │                                           │
   YES ▼                               NO ▼    │
   │                                   │       │
   │  양방향 확인됨?                    │       │
   │                             첫 SYN?       │
   YES ▼     NO ▼                YES ▼  NO ▼   │
   │         │                   │      │      │
ESTABLISHED  SYN_RECV           NEW  INVALID   │
   │         (RELATED가능)       │      │      │
   └─────────┴───────────────────┘      │      │
                                     DROP      │
                                               │
```

---

### 2.5 실무: Stateful 방화벽 기본 템플릿

```bash
#!/bin/bash
# stateful-firewall.sh — 상태 기반 방화벽 기본 설정
set -euo pipefail

# ── 기존 규칙 초기화 ──
iptables -F          # filter 체인 초기화
iptables -X          # 사용자 정의 체인 삭제
iptables -t nat -F   # NAT 체인 초기화
iptables -t raw -F   # raw 체인 초기화

# ── 기본 정책: 모두 차단 후 명시적 허용 ──
iptables -P INPUT   DROP
iptables -P FORWARD DROP
iptables -P OUTPUT  ACCEPT    # 아웃바운드는 기본 허용

# ── 1순위: 루프백 인터페이스 허용 ──
iptables -A INPUT -i lo -j ACCEPT

# ── 2순위: INVALID 패킷 즉시 드롭 (ESTABLISHED 보다 앞에 위치해야 함) ──
iptables -A INPUT -m conntrack --ctstate INVALID -j DROP

# ── 3순위: 핵심 규칙 — 기존/관련 연결 허용 ──
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# ── 4순위: 새 연결 허용 (서비스별) ──
iptables -A INPUT -p tcp --dport 22  -m conntrack --ctstate NEW -j ACCEPT   # SSH
iptables -A INPUT -p tcp --dport 80  -m conntrack --ctstate NEW -j ACCEPT   # HTTP
iptables -A INPUT -p tcp --dport 443 -m conntrack --ctstate NEW -j ACCEPT   # HTTPS

# ── ICMP 허용 (ping, traceroute 등) ──
iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT

# ── 설정 확인 ──
iptables -L -n -v --line-numbers
```

```bash
# 규칙 영구 저장
# RHEL/Rocky/CentOS
service iptables save

# Debian/Ubuntu
apt install -y iptables-persistent
netfilter-persistent save
```

---

### 2.6 규칙 순서가 성능에 미치는 영향

iptables는 규칙을 **위에서 아래로 순차 검사**한다. 첫 번째 매칭 규칙에서 즉시 액션을 실행하고 나머지는 검사하지 않는다.

```bash
# 비효율적 순서 (실제 트래픽 대부분이 ESTABLISHED인데 마지막에 위치)
iptables -A INPUT -p tcp --dport 22  -j ACCEPT
iptables -A INPUT -p tcp --dport 80  -j ACCEPT
iptables -A INPUT -p tcp --dport 443 -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT  # ← 느림

# 효율적 순서 (가장 빈번한 트래픽인 ESTABLISHED를 앞에 배치)
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT  # ← 빠름
iptables -A INPUT -p tcp --dport 22  -m conntrack --ctstate NEW -j ACCEPT
iptables -A INPUT -p tcp --dport 80  -m conntrack --ctstate NEW -j ACCEPT
iptables -A INPUT -p tcp --dport 443 -m conntrack --ctstate NEW -j ACCEPT
```

일반적인 웹 서버에서 ESTABLISHED 패킷은 전체 인바운드 트래픽의 90% 이상을 차지한다. ESTABLISHED 규칙을 첫 줄에 배치하면 대부분의 패킷이 한 번의 규칙 검사로 통과된다.

---

### 2.7 conntrack 테이블 조회로 ctstate 확인

```bash
# 전체 conntrack 테이블 출력
conntrack -L

# 출력 예시 해석
# tcp  6  86398  ESTABLISHED
# │    │  │      └─ ctstate: iptables --ctstate ESTABLISHED에 매칭됨
# │    │  └─ TTL 남은 시간 (초)
# │    └─ L4 프로토콜 번호 (6=TCP, 17=UDP, 1=ICMP)
# └─ 프로토콜

# 상태별 연결 수 집계
conntrack -L 2>/dev/null | awk '{print $4}' | sort | uniq -c | sort -rn
# 결과 예:
#   4210 ESTABLISHED
#     82 TIME_WAIT
#     15 SYN_SENT
#      3 CLOSE_WAIT

# RELATED 연결 확인 (FTP 데이터 채널 등)
conntrack -L | grep "\[RELATED\]"

# conntrack 이벤트 실시간 모니터링 (NEW/ESTABLISHED/DESTROY)
conntrack -E
# [NEW]         tcp  6  120   SYN_SENT   src=10.0.0.1 dst=10.0.0.2 ...
# [UPDATE]      tcp  6  86400 ESTABLISHED src=10.0.0.1 dst=10.0.0.2 ...
# [DESTROY]     tcp  6  0     TIME_WAIT  src=10.0.0.1 dst=10.0.0.2 ...
```

---

### 2.8 -m state vs -m conntrack 차이

```bash
# 구형 방식 (-m state)
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# 신형 방식 (-m conntrack)
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
```

| 구분 | `-m state` | `-m conntrack` |
|------|-----------|----------------|
| 커널 모듈 | `ipt_state` (deprecated) | `xt_conntrack` |
| 지원 상태 | NEW, ESTABLISHED, RELATED, INVALID | 위 + UNTRACKED, DNAT, SNAT |
| 추가 조건 | 없음 | `--ctproto`, `--ctorigsrc`, `--ctreplsrc` 등 |
| 현재 권장 | 비권장 | 권장 |

`-m conntrack`은 상태뿐 아니라 conntrack 필드 전체를 매칭 조건으로 사용할 수 있다:

```bash
# conntrack 원본 소스 IP로 매칭
iptables -A INPUT -m conntrack --ctorigsrc 10.0.0.0/8 -j ACCEPT

# conntrack 원본 포트로 매칭
iptables -A INPUT -m conntrack --ctorigdstport 443 -j ACCEPT

# conntrack 상태 + 프로토콜 조합 매칭
iptables -A INPUT -m conntrack --ctstate ESTABLISHED --ctproto tcp -j ACCEPT
```

---

### 2.9 클라우드/DevOps 연계

#### Terraform user_data에서 stateful 방화벽 구성

```hcl
# 버전: hashicorp/aws ~> 5.0 기준
resource "aws_instance" "web" {
  ami           = "<AMI_ID>"
  instance_type = "t3.small"

  # Security Group은 L3/L4 수준 — iptables는 인스턴스 내부 상태 기반 제어
  vpc_security_group_ids = [aws_security_group.web_sg.id]

  user_data = <<-EOF
    #!/bin/bash
    set -euo pipefail

    # 기본 정책 설정
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT ACCEPT

    # 루프백 및 상태 기반 허용
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A INPUT -m conntrack --ctstate INVALID -j DROP
    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    # 서비스 포트 허용
    iptables -A INPUT -p tcp --dport 22  -m conntrack --ctstate NEW -j ACCEPT
    iptables -A INPUT -p tcp --dport 443 -m conntrack --ctstate NEW -j ACCEPT

    # 영구 저장
    apt-get install -y iptables-persistent
    netfilter-persistent save
  EOF

  tags = {
    Name        = "<NAME>"
    Environment = "<ENVIRONMENT>"
    ManagedBy   = "terraform"
  }
}
```

#### Ansible로 stateful 방화벽 배포

```yaml
# roles/iptables-stateful/tasks/main.yml
---
- name: FTP conntrack helper 모듈 로드 (RELATED 지원)
  community.general.modprobe:
    name: nf_conntrack_ftp
    state: present
    persistent: present    # /etc/modules-load.d/ 에 영구 등록

- name: 기본 정책 DROP 설정
  ansible.builtin.iptables:
    chain: "{{ item }}"
    policy: DROP
  loop: [INPUT, FORWARD]

- name: 루프백 허용
  ansible.builtin.iptables:
    chain: INPUT
    in_interface: lo
    jump: ACCEPT

- name: INVALID 패킷 드롭
  ansible.builtin.iptables:
    chain: INPUT
    ctstate:
      - INVALID
    jump: DROP
    comment: "Drop INVALID conntrack state"

- name: ESTABLISHED,RELATED 허용 (핵심 규칙)
  ansible.builtin.iptables:
    chain: INPUT
    ctstate:
      - ESTABLISHED
      - RELATED
    jump: ACCEPT
    comment: "Allow established and related connections"

- name: SSH NEW 연결 허용
  ansible.builtin.iptables:
    chain: INPUT
    protocol: tcp
    destination_port: "22"
    ctstate:
      - NEW
    jump: ACCEPT

- name: 규칙 영구 저장
  ansible.builtin.command: netfilter-persistent save
  changed_when: true
```

---

## 3. 자주 하는 실수

| 잘못된 방법 | 올바른 방법 | 이유 |
|-------------|-------------|------|
| `ESTABLISHED,RELATED` 규칙 없이 `OUTPUT ACCEPT`만 설정 | `INPUT`에 `--ctstate ESTABLISHED,RELATED -j ACCEPT` 추가 | OUTPUT은 허용해도 INPUT 기본 DROP이면 응답 패킷이 차단됨 |
| `INVALID` 패킷을 별도 DROP하지 않음 | `--ctstate INVALID -j DROP`을 ESTABLISHED 규칙 앞에 배치 | INVALID가 ESTABLISHED 규칙보다 먼저 매칭되지 않으면 우회될 수 있음 |
| `-m state --state` 사용 (구형) | `-m conntrack --ctstate` 사용 | `ipt_state` 모듈은 deprecated, UNTRACKED/DNAT/SNAT 상태 미지원 |
| FTP 허용 시 포트 20, 21만 ACCEPT | `nf_conntrack_ftp` 모듈 로드 + `RELATED` 허용 | Active FTP 데이터 채널은 서버→클라이언트 방향 NEW 연결이므로 포트만 열면 부족 |
| ESTABLISHED 규칙을 서비스 포트 규칙 뒤에 배치 | ESTABLISHED를 INPUT 체인 최상단에 배치 | 패킷 순차 검사로 인한 성능 저하; 트래픽의 90%+가 ESTABLISHED임 |
| `iptables -F` 후 ESTABLISHED 규칙 없이 서비스 재시작 | 스크립트에 ESTABLISHED 규칙을 항상 포함 | 기존 SSH 세션이 즉시 끊어져 원격 접속 불가 상태에 빠질 수 있음 |
| conntrack 테이블 풀 났을 때 iptables 규칙만 확인 | `conntrack -C`와 `nf_conntrack_max` 함께 확인 | 테이블이 풀 나면 NEW 패킷이 INVALID로 분류되어 연결 전체 차단 |

---

## 4. 트러블슈팅

### 증상 1: SSH로 처음 접속은 되는데 기존 세션이 랜덤하게 끊어짐

**원인**: conntrack 테이블이 가득 차서 ESTABLISHED 패킷이 INVALID로 분류됨.

```bash
# conntrack 테이블 사용률 확인
echo "사용: $(cat /proc/sys/net/netfilter/nf_conntrack_count) / \
최대: $(cat /proc/sys/net/netfilter/nf_conntrack_max)"

# 80% 이상이면 즉시 조치
sysctl -w net.netfilter.nf_conntrack_max=262144

# 오래된 TIME_WAIT 연결 정리
conntrack -D --state TIME_WAIT
```

---

### 증상 2: FTP 접속 후 `ls` 명령 실행 시 hang 또는 타임아웃

**원인**: `nf_conntrack_ftp` 모듈 미로드로 FTP 데이터 채널이 RELATED로 인식되지 않음.

```bash
# FTP 관련 conntrack 모듈 확인
lsmod | grep conntrack_ftp
# 출력 없으면 모듈 미로드 상태

# 모듈 즉시 로드
modprobe nf_conntrack_ftp

# 기존 FTP 연결 확인 (포트 20 또는 고포트 RELATED 연결)
conntrack -L | grep ftp
conntrack -L -p tcp --dport 20
```

---

### 증상 3: iptables 규칙 추가했는데 `iptables -L`에서 안 보임

```bash
# 테이블 명시 확인 (-t filter 기본이나 혼동 방지)
iptables -t filter -L INPUT -n -v --line-numbers

# 규칙 번호로 특정 위치에 삽입 확인
iptables -L INPUT -n --line-numbers

# conntrack 모듈 로드 여부 확인
lsmod | grep xt_conntrack
# 없으면: modprobe xt_conntrack
```

---

### 증상 4: `--ctstate RELATED` 허용했는데 ICMP 에러 메시지 안 들어옴

**원인**: ICMP RELATED는 기본 지원이지만, ICMP type 필터로 차단되거나 conntrack이 해당 연결을 알고 있어야 한다.

```bash
# RELATED ICMP 패킷 conntrack 확인
conntrack -L -p icmp

# ICMP 허용 규칙이 RELATED보다 앞에 있는지 확인
iptables -L INPUT -n -v --line-numbers

# ICMP echo-request (ping) 별도 허용
iptables -A INPUT -p icmp --icmp-type echo-request \
  -m conntrack --ctstate NEW -j ACCEPT

# ICMP 에러 (unreachable 등) — RELATED로 자동 처리됨
# 별도 규칙 불필요, ESTABLISHED,RELATED 규칙에 포함
```

---

## 5. TIP

**`ESTABLISHED,RELATED` 단일 규칙 vs 분리 규칙**

성능 차이는 미미하지만, RELATED만 별도 카운트하고 싶을 때 분리한다:

```bash
# 통합 (일반적)
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# 분리 (각각 패킷 카운트 모니터링 가능)
iptables -A INPUT -m conntrack --ctstate ESTABLISHED -j ACCEPT
iptables -A INPUT -m conntrack --ctstate RELATED      -j ACCEPT

# 패킷 수 확인
iptables -L INPUT -n -v | grep -E "ESTABLISHED|RELATED"
```

**conntrack 이벤트로 규칙 동작 실시간 검증**

```bash
# 새 터미널에서 conntrack 이벤트 모니터링
conntrack -E -e NEW,DESTROY

# 다른 터미널에서 curl 실행 후 이벤트 확인
curl http://example.com

# 출력 예:
# [NEW]     tcp 6 120 SYN_SENT src=<IP> dst=93.184.216.34 sport=54321 dport=80
# [DESTROY] tcp 6 0   TIME_WAIT ...
# → NEW 이벤트: curl이 연결 시작 (OUTPUT 체인 통과)
# → 응답은 ESTABLISHED로 INPUT 통과 (이벤트 미출력, UPDATE로만 기록)
```

**nftables로 동일 규칙 표현**

```bash
# iptables
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# nftables 동등 규칙
nft add rule inet filter input ct state established,related accept
```

**클라우드 Security Group과 역할 분리**

AWS Security Group은 Stateful이라 ESTABLISHED/RELATED를 자동 허용한다. iptables와의 역할을 명확히 구분한다:

| 계층 | 도구 | 역할 |
|------|------|------|
| VPC 레벨 | Security Group (Stateful) | 인스턴스 접근 소스 IP/포트 제한 |
| VPC 레벨 | Network ACL (Stateless) | 서브넷 단위 IP 차단 (ESTABLISHED 수동 허용 필요) |
| 인스턴스 레벨 | iptables / nftables | 프로세스별 세밀한 상태 기반 제어 |
