# linux-iptables.md — iptables 완전 정복

## 1. 개요

`iptables`는 리눅스 커널의 **Netfilter** 프레임워크를 사용자 공간에서 제어하는 CLI 도구다. 패킷이 커널 네트워크 스택을 통과할 때 걸어두는 **Hook 지점**에 규칙(Rule)을 삽입하여 패킷을 허용·차단·변환한다. 웹 서버 방화벽, NAT 게이트웨이, 로드밸런서(kube-proxy), DDoS 방어까지 Linux 네트워킹의 핵심 기반이다.

> **버전 참고**: `iptables`는 레거시(legacy)와 `iptables-nft`(nftables 백엔드) 두 가지 구현이 공존한다. RHEL 9 / Ubuntu 22.04 이후에는 `nftables`가 기본이지만, `iptables` 명령은 nftables 위에서 호환 레이어로 동작한다.

---

## 2. Netfilter 훅과 패킷 흐름

```
네트워크 인터페이스 수신
        │
        ▼
  ┌─────────────┐      라우팅 결정 (로컬 프로세스행)
  │ PREROUTING  │ ──────────────────────────────────►  ┌─────────┐
  │ (raw,mangle │                                       │  INPUT  │ ──► 로컬 프로세스
  │  nat:DNAT)  │                                       │(filter) │
  └─────────────┘                                       └─────────┘
        │
        │ 라우팅 결정 (포워딩)
        ▼
  ┌─────────────┐      ┌──────────────┐
  │   FORWARD   │ ──►  │ POSTROUTING  │ ──► 네트워크 인터페이스 송신
  │  (filter)   │      │(mangle,nat:  │
  └─────────────┘      │  MASQ/SNAT) │
                        └──────────────┘

로컬 프로세스 발신
        │
        ▼
  ┌─────────────┐      ┌──────────────┐
  │   OUTPUT    │ ──►  │ POSTROUTING  │ ──► 네트워크 인터페이스 송신
  │(raw,mangle, │      │              │
  │  nat,filter)│      └──────────────┘
  └─────────────┘
```

---

## 3. Table과 Chain 전체 구조

| Table | 처리되는 Chain | 주 용도 |
|-------|--------------|---------|
| `raw` | PREROUTING, OUTPUT | conntrack 추적 제외(NOTRACK), 가장 먼저 평가 |
| `mangle` | PREROUTING, INPUT, FORWARD, OUTPUT, POSTROUTING | 패킷 헤더 수정 (TOS, TTL, MARK) |
| `nat` | PREROUTING, OUTPUT, POSTROUTING | IP/포트 주소 변환 (DNAT, SNAT, MASQUERADE) |
| `filter` | INPUT, FORWARD, OUTPUT | 패킷 허용·차단 (기본 테이블) |
| `security` | INPUT, FORWARD, OUTPUT | SELinux 연동 보안 레이블 |

---

## 4. 기본 문법

```bash
iptables [-t table] <커맨드> <chain> [매치 옵션] [-j 타겟]
```

`-t` 를 생략하면 기본값은 `filter` 테이블이다.

---

## 5. 커맨드(-) 옵션 상세

### 5.1 규칙 조회

#### `-L` — 규칙 목록 출력

```bash
# 옵션 없이 실행: 기본 filter 테이블, 모든 Chain 출력
iptables -L
```
```
Chain INPUT (policy ACCEPT)
target     prot opt source               destination

Chain FORWARD (policy ACCEPT)
target     prot opt source               destination

Chain OUTPUT (policy ACCEPT)
target     prot opt source               destination
```

```bash
# -v: 바이트/패킷 카운터, 인터페이스 정보 포함
# -n: IP를 역DNS 조회 없이 숫자로 표시 (속도 빠름)
# --line-numbers: 규칙 번호 표시 (삽입/삭제 시 필수)
iptables -L INPUT -v -n --line-numbers
```
```
Chain INPUT (policy DROP 1823 packets, 109380 bytes)
num   pkts bytes target     prot opt in     out     source               destination
1     1.2M  980M ACCEPT     all  --  lo     *       0.0.0.0/0            0.0.0.0/0
2     856K  72M  ACCEPT     all  --  *      *       0.0.0.0/0            0.0.0.0/0            ctstate RELATED,ESTABLISHED
3      42K 2520K ACCEPT     tcp  --  *      *       0.0.0.0/0            0.0.0.0/0            tcp dpt:22
4     8921  535K ACCEPT     tcp  --  *      *       0.0.0.0/0            0.0.0.0/0            tcp dpt:80
```

```bash
# nat 테이블 조회
iptables -t nat -L -v -n
```
```
Chain PREROUTING (policy ACCEPT 0 packets, 0 bytes)
 pkts bytes target     prot opt in     out     source               destination
    0     0 DNAT       tcp  --  *      *       0.0.0.0/0            203.0.113.10         tcp dpt:80 to:10.0.1.50:8080

Chain INPUT (policy ACCEPT 0 packets, 0 bytes)
 pkts bytes target     prot opt in     out     source               destination

Chain OUTPUT (policy ACCEPT 3 packets, 180 bytes)
 pkts bytes target     prot opt in     out     source               destination

Chain POSTROUTING (policy ACCEPT 0 packets, 0 bytes)
 pkts bytes target     prot opt in     out     source               destination
    0     0 MASQUERADE all  --  *      eth0    10.0.0.0/8           0.0.0.0/0
```

#### `-S` — iptables-save 형식으로 규칙 출력

```bash
# 재현 가능한 스크립트 형식으로 출력 (백업/복원 시 유용)
iptables -S INPUT
```
```
-P INPUT DROP
-A INPUT -i lo -j ACCEPT
-A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A INPUT -p tcp -m tcp --dport 22 -j ACCEPT
-A INPUT -p tcp -m tcp --dport 80 -j ACCEPT
```

---

### 5.2 규칙 추가·삽입·삭제

#### `-A` (Append) — 체인 맨 끝에 추가

```bash
# INPUT 체인 마지막에 규칙 추가
iptables -A INPUT -p tcp --dport 443 -j ACCEPT

# 확인
iptables -L INPUT -n --line-numbers
```
```
Chain INPUT (policy DROP)
num  target     prot opt source               destination
1    ACCEPT     all  --  0.0.0.0/0            0.0.0.0/0
2    ACCEPT     all  --  0.0.0.0/0            0.0.0.0/0            ctstate RELATED,ESTABLISHED
3    ACCEPT     tcp  --  0.0.0.0/0            0.0.0.0/0            tcp dpt:22
4    ACCEPT     tcp  --  0.0.0.0/0            0.0.0.0/0            tcp dpt:80
5    ACCEPT     tcp  --  0.0.0.0/0            0.0.0.0/0            tcp dpt:443  ← 방금 추가
```

#### `-I` (Insert) — 지정 번호에 삽입

```bash
# 번호 지정: 1번 위치(최상단)에 특정 IP 차단 규칙 삽입
iptables -I INPUT 1 -s 192.168.100.5 -j DROP

# 번호 생략 시 기본 1번(최상단)에 삽입
iptables -I INPUT -s 10.0.0.0/8 -j ACCEPT

iptables -L INPUT -n --line-numbers
```
```
Chain INPUT (policy DROP)
num  target     prot opt source               destination
1    DROP       all  --  192.168.100.5        0.0.0.0/0    ← 삽입됨
2    ACCEPT     all  --  0.0.0.0/0            0.0.0.0/0
3    ACCEPT     all  --  0.0.0.0/0            0.0.0.0/0            ctstate RELATED,ESTABLISHED
4    ACCEPT     tcp  --  0.0.0.0/0            0.0.0.0/0            tcp dpt:22
...
```

> **주의**: `-I` 없이 `-A`로 차단 규칙을 추가했는데 이미 상단에 ACCEPT 규칙이 있으면 차단이 동작하지 않는다. 차단은 항상 `-I`로 상단에 넣는다.

#### `-D` (Delete) — 규칙 삭제

```bash
# 방법 1: 번호로 삭제 (--line-numbers로 번호 확인 후)
iptables -D INPUT 1

# 방법 2: 규칙 내용으로 삭제 (추가 시 쓴 명령어에서 -A만 -D로 변경)
iptables -D INPUT -s 192.168.100.5 -j DROP
```

#### `-R` (Replace) — 번호 위치의 규칙 교체

```bash
# 3번 규칙을 다른 포트로 교체
iptables -R INPUT 3 -p tcp --dport 2222 -j ACCEPT

iptables -L INPUT -n --line-numbers
```
```
Chain INPUT (policy DROP)
num  target     prot opt source               destination
1    ACCEPT     all  --  0.0.0.0/0            0.0.0.0/0
2    ACCEPT     all  --  0.0.0.0/0            0.0.0.0/0            ctstate RELATED,ESTABLISHED
3    ACCEPT     tcp  --  0.0.0.0/0            0.0.0.0/0            tcp dpt:2222  ← 교체됨
```

---

### 5.3 체인 관리

#### `-F` (Flush) — 체인 규칙 전체 삭제

```bash
# 특정 체인만 초기화
iptables -F INPUT

# 전체 테이블 초기화 (기본 정책은 유지됨)
iptables -F

# nat 테이블 초기화
iptables -t nat -F
```

> **주의**: `-F`는 기본 정책(ACCEPT/DROP)을 변경하지 않는다. 기본 정책이 DROP인 상태에서 `-F`하면 모든 패킷이 차단되어 SSH가 끊어진다.

#### `-P` (Policy) — 체인 기본 정책 설정

```bash
# 모든 입력 차단 (Default Deny)
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

iptables -L | grep policy
```
```
Chain INPUT (policy DROP)
Chain FORWARD (policy DROP)
Chain OUTPUT (policy ACCEPT)
```

#### `-N` (New chain) / `-X` (Delete chain) / `-E` (Rename chain)

```bash
# 사용자 정의 체인 생성
iptables -N MYAPP_RULES

# 체인 이름 변경
iptables -E MYAPP_RULES WEBAPP_FILTER

# 사용자 정의 체인 삭제 (체인이 비어있고 참조되지 않아야 함)
iptables -X WEBAPP_FILTER
```

#### `-Z` (Zero) — 패킷/바이트 카운터 초기화

```bash
# 특정 체인 카운터 초기화
iptables -Z INPUT

# 전체 카운터 초기화
iptables -Z
```

---

## 6. 매치(Match) 옵션 상세

### 6.1 기본 매치

| 옵션 | 설명 | 예시 |
|------|------|------|
| `-p <proto>` | 프로토콜 지정 | `-p tcp`, `-p udp`, `-p icmp`, `-p all` |
| `-s <src>` | 출발지 IP/대역 | `-s 10.0.0.1`, `-s 192.168.0.0/24` |
| `-d <dst>` | 목적지 IP/대역 | `-d 203.0.113.0/24` |
| `-i <iface>` | 입력 인터페이스 (INPUT, FORWARD, PREROUTING) | `-i eth0`, `-i lo` |
| `-o <iface>` | 출력 인터페이스 (OUTPUT, FORWARD, POSTROUTING) | `-o eth0` |
| `!` | 부정(NOT) | `-s ! 10.0.0.0/8` (해당 대역 제외) |

```bash
# 출발지가 10.0.0.0/8 이 아닌 SSH 접속 차단
iptables -A INPUT -p tcp --dport 22 ! -s 10.0.0.0/8 -j DROP

# lo(루프백) 인터페이스는 무조건 허용
iptables -A INPUT -i lo -j ACCEPT

iptables -L INPUT -n -v
```
```
Chain INPUT (policy DROP)
 pkts bytes target     prot opt in     out     source               destination
12.3K  738K ACCEPT     all  --  lo     *       0.0.0.0/0            0.0.0.0/0
    8   480 DROP       tcp  --  *      *      !10.0.0.0/8           0.0.0.0/0            tcp dpt:22
```

---

### 6.2 `-p tcp` / `-p udp` 매치 옵션

```bash
# --dport: 목적지 포트
iptables -A INPUT -p tcp --dport 80 -j ACCEPT

# --sport: 출발지 포트
iptables -A OUTPUT -p tcp --sport 80 -j ACCEPT

# 포트 범위: 8000~9000
iptables -A INPUT -p tcp --dport 8000:9000 -j ACCEPT

# --tcp-flags: TCP 플래그 매칭
# SYN 패킷만 허용 (새 연결 시도): SYN=1, ACK=0
iptables -A INPUT -p tcp --tcp-flags SYN,ACK SYN -j ACCEPT

# --syn: --tcp-flags SYN,RST,ACK,FIN SYN 의 단축 표현
iptables -A INPUT -p tcp --syn -j ACCEPT
```

```bash
# 실습: 80/443만 열고 나머지 tcp 차단
iptables -F INPUT
iptables -P INPUT DROP
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -p tcp --dport 80  -j ACCEPT
iptables -A INPUT -p tcp --dport 443 -j ACCEPT

iptables -L INPUT -n -v --line-numbers
```
```
Chain INPUT (policy DROP)
num   pkts bytes target     prot opt in     out     source               destination
1        0     0 ACCEPT     all  --  lo     *       0.0.0.0/0            0.0.0.0/0
2        0     0 ACCEPT     all  --  *      *       0.0.0.0/0            0.0.0.0/0            ctstate RELATED,ESTABLISHED
3        0     0 ACCEPT     tcp  --  *      *       0.0.0.0/0            0.0.0.0/0            tcp dpt:80
4        0     0 ACCEPT     tcp  --  *      *       0.0.0.0/0            0.0.0.0/0            tcp dpt:443
```

---

### 6.3 `-p icmp` 매치

```bash
# --icmp-type: ICMP 타입 지정
# type 8 = echo-request (ping 요청)
iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT

# type 0 = echo-reply (ping 응답)
iptables -A INPUT -p icmp --icmp-type echo-reply -j ACCEPT

# 지원되는 모든 ICMP 타입 확인
iptables -p icmp --help 2>&1 | grep "Valid ICMP" -A 30
```
```
Valid ICMP Types:
any
echo-reply (pong)
destination-unreachable
   network-unreachable
   host-unreachable
   protocol-unreachable
   port-unreachable
   fragmentation-needed
   ...
echo-request (ping)
time-exceeded (ttl-exceeded)
...
```

---

### 6.4 `-m` (모듈 매치) 옵션 상세

#### `-m conntrack` — 연결 상태 추적

```bash
# --ctstate: 연결 상태 지정
# NEW          : 새로운 연결 (SYN 패킷)
# ESTABLISHED  : 이미 맺어진 연결의 패킷
# RELATED      : 연관 연결 (FTP 데이터 채널, ICMP 오류 등)
# INVALID      : conntrack 테이블에 없는 비정상 패킷
# UNTRACKED    : NOTRACK으로 추적 제외된 패킷

iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -m conntrack --ctstate INVALID -j DROP

# 현재 conntrack 테이블 확인
conntrack -L 2>/dev/null | head -10
```
```
tcp      6 86385 ESTABLISHED src=10.0.1.5 dst=203.0.113.100 sport=52341 dport=443 \
         src=203.0.113.100 dst=10.0.1.5 sport=443 dport=52341 [ASSURED] mark=0 use=1
tcp      6 110 TIME_WAIT src=10.0.1.5 dst=203.0.113.200 sport=43221 dport=80 \
         src=203.0.113.200 dst=10.0.1.5 sport=80 dport=43221 [ASSURED] mark=0 use=1
udp      17 28 src=10.0.1.5 dst=8.8.8.8 sport=51234 dport=53 \
         src=8.8.8.8 dst=10.0.1.5 sport=53 dport=51234 mark=0 use=1
```

#### `-m state` — 구형 상태 매치 (conntrack과 동일하나 레거시)

```bash
# 레거시 방식 (구형 커널/문서에서 자주 등장)
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
```

#### `-m multiport` — 여러 포트 동시 지정

```bash
# 최대 15개 포트를 한 규칙에 지정 가능
iptables -A INPUT -p tcp -m multiport --dports 22,80,443,8080,8443 -j ACCEPT

iptables -L INPUT -n --line-numbers
```
```
Chain INPUT (policy DROP)
num  target     prot opt source               destination
1    ACCEPT     tcp  --  0.0.0.0/0            0.0.0.0/0            multiport dports 22,80,443,8080,8443
```

```bash
# --sports: 출발지 포트 다중 지정
iptables -A OUTPUT -p tcp -m multiport --sports 80,443 -j ACCEPT

# --ports: 출발지 또는 목적지 (양방향)
iptables -A INPUT -p tcp -m multiport --ports 53 -j ACCEPT
```

#### `-m iprange` — IP 범위 지정

```bash
# CIDR로 표현하기 어려운 IP 범위
iptables -A INPUT -m iprange --src-range 203.0.113.10-203.0.113.50 -j ACCEPT
iptables -A INPUT -m iprange --dst-range 10.0.1.1-10.0.1.100 -j DROP

iptables -L INPUT -n
```
```
Chain INPUT (policy DROP)
target     prot opt source               destination
ACCEPT     all  --  0.0.0.0/0            0.0.0.0/0            source IP range 203.0.113.10-203.0.113.50
DROP       all  --  0.0.0.0/0            0.0.0.0/0            destination IP range 10.0.1.1-10.0.1.100
```

#### `-m limit` — 패킷 속도 제한

```bash
# --limit: 허용 속도 (패킷/시간)
# --limit-burst: 초기 허용 버스트 크기

# ping 응답을 초당 5개, 버스트 10개까지 허용 (DDoS 방어)
iptables -A INPUT -p icmp --icmp-type echo-request \
    -m limit --limit 5/sec --limit-burst 10 -j ACCEPT
iptables -A INPUT -p icmp --icmp-type echo-request -j DROP

# SSH brute force 방어: 분당 3번 시도 제한
iptables -A INPUT -p tcp --dport 22 \
    -m limit --limit 3/min --limit-burst 5 -j ACCEPT
iptables -A INPUT -p tcp --dport 22 -j DROP
```

#### `-m hashlimit` — 출발지 IP별 속도 제한

```bash
# IP별로 개별 속도 제한 (--limit은 전체 합산)
# --hashlimit-above: 이 속도 초과 시 매칭
# --hashlimit-mode: 기준 키 (srcip, dstip, srcport 등)
# --hashlimit-name: 해시 테이블 이름 (필수)

iptables -A INPUT -p tcp --dport 80 \
    -m hashlimit \
    --hashlimit-above 100/sec \
    --hashlimit-burst 200 \
    --hashlimit-mode srcip \
    --hashlimit-name http_limit \
    -j DROP
```

#### `-m recent` — 최근 접속 IP 추적

```bash
# SSH brute force 방어: 60초 내 4번 이상 새 연결 시 차단
# 1단계: 최근 목록에 출발지 IP 등록
iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW \
    -m recent --set --name SSH_LIST

# 2단계: 60초 내 4번 이상이면 DROP
iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW \
    -m recent --update --seconds 60 --hitcount 4 --name SSH_LIST \
    -j DROP

# recent 테이블 확인
cat /proc/net/xt_recent/SSH_LIST
```
```
src=203.0.113.55 ttl: 64 last_seen: 1716254823 oldest_pkt: 1 1716254810, 1716254815, 1716254820, 1716254823
```

#### `-m string` — 페이로드 문자열 매칭

```bash
# HTTP 요청 중 특정 User-Agent 차단
iptables -A INPUT -p tcp --dport 80 \
    -m string --string "sqlmap" --algo bm \
    -j DROP

# --algo: 검색 알고리즘 (bm=Boyer-Moore, kmp=Knuth-Morris-Pratt)
# --from, --to: 페이로드 오프셋 범위 지정
iptables -A INPUT -p tcp --dport 80 \
    -m string --string "nikto" --algo kmp --from 0 --to 200 \
    -j DROP
```

#### `-m time` — 시간대 매칭

```bash
# 업무 시간(월~금, 09~18시)에만 특정 서비스 허용
iptables -A INPUT -p tcp --dport 8080 \
    -m time --timestart 09:00 --timestop 18:00 \
    --weekdays Mon,Tue,Wed,Thu,Fri \
    -j ACCEPT

# --kerneltz: 커널 타임존 사용 (기본은 UTC)
iptables -A INPUT -p tcp --dport 8080 \
    -m time --timestart 00:00 --timestop 09:00 --kerneltz \
    -j DROP
```

#### `-m connlimit` — 동시 연결 수 제한

```bash
# 출발지 IP당 최대 10개 동시 연결 허용
iptables -A INPUT -p tcp --dport 80 \
    -m connlimit --connlimit-above 10 \
    -j REJECT --reject-with tcp-reset

# /24 대역별로 최대 100개 제한
iptables -A INPUT -p tcp --dport 80 \
    -m connlimit --connlimit-above 100 --connlimit-mask 24 \
    -j DROP
```

#### `-m owner` — 프로세스 소유자 매칭 (OUTPUT 전용)

```bash
# www-data (uid=33) 프로세스만 80포트 발신 허용
iptables -A OUTPUT -p tcp --dport 80 \
    -m owner --uid-owner 33 -j ACCEPT

# 특정 GID 프로세스 차단
iptables -A OUTPUT -m owner --gid-owner 1001 -j DROP
```

#### `-m set` — ipset 연동

```bash
# ipset으로 대규모 IP 목록 관리 (수만 개도 O(1) 조회)
ipset create BLACKLIST hash:ip

# 차단 IP 추가
ipset add BLACKLIST 203.0.113.100
ipset add BLACKLIST 198.51.100.0/24

# iptables에서 ipset 참조
iptables -A INPUT -m set --match-set BLACKLIST src -j DROP

# ipset 목록 확인
ipset list BLACKLIST
```
```
Name: BLACKLIST
Type: hash:ip
Revision: 6
Header: family inet hashsize 1024 maxelem 65536
Size in memory: 296
References: 1
Number of entries: 2
Members:
203.0.113.100
198.51.100.0/24
```

---

## 7. 타겟(-j) 옵션 상세

### 7.1 기본 타겟

| 타겟 | 동작 |
|------|------|
| `ACCEPT` | 패킷 허용, 이후 규칙 평가 중단 |
| `DROP` | 패킷 조용히 폐기 (발신자에게 응답 없음) |
| `REJECT` | 패킷 거부 + ICMP 오류 메시지 반환 |
| `RETURN` | 현재 체인 평가 중단, 호출 체인으로 복귀 |

```bash
# REJECT 세부 옵션
# --reject-with: 반환할 ICMP 유형 지정
iptables -A INPUT -p tcp --dport 8080 \
    -j REJECT --reject-with tcp-reset          # TCP RST 전송
iptables -A INPUT -p tcp --dport 8081 \
    -j REJECT --reject-with icmp-port-unreachable  # ICMP 포트 도달불가 (기본값)
iptables -A INPUT -p udp --dport 53 \
    -j REJECT --reject-with icmp-admin-prohibited  # ICMP 관리 금지

# DROP vs REJECT 차이 확인
# DROP: 발신자 측에서 타임아웃 발생 (수십 초 대기)
# REJECT: 발신자가 즉시 "연결 거부" 오류 수신
```

### 7.2 `LOG` 타겟 — 커널 로그 기록

```bash
# 기본 로그 (DROP 전에 LOG를 먼저 걸어야 함)
iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW \
    -j LOG --log-prefix "[SSH-NEW] " --log-level 4

iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW -j ACCEPT

# 옵션
# --log-prefix: 로그 메시지 앞에 붙는 접두사 (최대 29자)
# --log-level: syslog 레벨 (0=emerg ~ 7=debug, 기본 4=warning)
# --log-ip-options: IP 헤더 옵션 포함
# --log-tcp-options: TCP 헤더 옵션 포함
# --log-tcp-sequence: TCP 시퀀스 번호 포함

# 로그 확인
journalctl -k | grep "\[SSH-NEW\]"
```
```
May 21 15:32:10 server kernel: [SSH-NEW] IN=eth0 OUT= MAC=... SRC=203.0.113.55 DST=10.0.1.10 LEN=60 TOS=0x00 PREC=0x00 TTL=64 ID=12345 DF PROTO=TCP SPT=52341 DPT=22 WINDOW=64240 RES=0x00 SYN URGP=0
```

### 7.3 `MARK` / `CONNMARK` — 패킷 마킹

```bash
# 패킷에 마크 설정 (라우팅 정책, QoS에 활용)
iptables -t mangle -A PREROUTING -p tcp --dport 80 \
    -j MARK --set-mark 0x10

# CONNMARK: 연결 전체에 마크 적용
iptables -t mangle -A PREROUTING \
    -j CONNMARK --restore-mark    # 연결 마크를 패킷으로 복사

# 마크된 패킷을 특정 라우팅 테이블로
ip rule add fwmark 0x10 table 200
ip route add default via 192.168.2.1 table 200
```

### 7.4 `DNAT` — 목적지 주소 변환

```bash
# 외부 80 → 내부 서버 8080으로 포트 포워딩
iptables -t nat -A PREROUTING \
    -p tcp --dport 80 \
    -j DNAT --to-destination 10.0.1.50:8080

# 특정 외부 IP로 들어오는 패킷만 포워딩
iptables -t nat -A PREROUTING \
    -d 203.0.113.10 -p tcp --dport 443 \
    -j DNAT --to-destination 10.0.1.50:443

# 포트 범위 포워딩 (1:1 매핑)
iptables -t nat -A PREROUTING \
    -p tcp --dport 8000:8010 \
    -j DNAT --to-destination 10.0.1.50:8000-8010

# 확인
iptables -t nat -L PREROUTING -n -v
```
```
Chain PREROUTING (policy ACCEPT 0 packets, 0 bytes)
 pkts bytes target     prot opt in     out     source               destination
    0     0 DNAT       tcp  --  *      *       0.0.0.0/0            0.0.0.0/0            tcp dpt:80 to:10.0.1.50:8080
```

### 7.5 `SNAT` / `MASQUERADE` — 출발지 주소 변환

```bash
# SNAT: 고정 공인 IP가 있을 때 (정적 NAT)
iptables -t nat -A POSTROUTING \
    -s 10.0.0.0/8 -o eth0 \
    -j SNAT --to-source 203.0.113.1

# MASQUERADE: 동적 IP (DHCP, PPPoE) 환경 — 출력 인터페이스 IP 자동 사용
iptables -t nat -A POSTROUTING \
    -s 10.0.0.0/8 -o eth0 \
    -j MASQUERADE

# --to-ports: MASQUERADE 시 포트 범위 지정
iptables -t nat -A POSTROUTING \
    -s 10.0.0.0/8 -o eth0 \
    -j MASQUERADE --to-ports 1024-65535

# 확인
iptables -t nat -L POSTROUTING -n -v
```
```
Chain POSTROUTING (policy ACCEPT 0 packets, 0 bytes)
 pkts bytes target       prot opt in     out     source               destination
  342 23548 MASQUERADE   all  --  *      eth0    10.0.0.0/8           0.0.0.0/0
```

### 7.6 `REDIRECT` — 로컬 리다이렉트

```bash
# 80 포트를 로컬 프로세스 8080으로 리다이렉트 (투명 프록시)
iptables -t nat -A PREROUTING \
    -p tcp --dport 80 \
    -j REDIRECT --to-ports 8080

# OUTPUT 체인에도 적용 (로컬 발신 트래픽 포함)
iptables -t nat -A OUTPUT \
    -p tcp --dport 80 ! -d 127.0.0.0/8 \
    -j REDIRECT --to-ports 8080
```

### 7.7 사용자 정의 체인으로 점프

```bash
# 사용자 정의 체인 활용 (규칙 모듈화)
iptables -N SSH_RULES
iptables -N WEB_RULES

# SSH_RULES 체인에 규칙 추가
iptables -A SSH_RULES -m recent --update --seconds 60 --hitcount 4 --name SSH -j DROP
iptables -A SSH_RULES -m recent --set --name SSH -j ACCEPT

# WEB_RULES 체인에 규칙 추가
iptables -A WEB_RULES -m connlimit --connlimit-above 20 -j DROP
iptables -A WEB_RULES -j ACCEPT

# INPUT에서 조건부로 사용자 체인으로 점프
iptables -A INPUT -p tcp --dport 22 -j SSH_RULES
iptables -A INPUT -p tcp -m multiport --dports 80,443 -j WEB_RULES

iptables -L INPUT -n
```
```
Chain INPUT (policy DROP)
target     prot opt source               destination
ACCEPT     all  --  0.0.0.0/0            0.0.0.0/0            /* loopback */
ACCEPT     all  --  0.0.0.0/0            0.0.0.0/0            ctstate RELATED,ESTABLISHED
SSH_RULES  tcp  --  0.0.0.0/0            0.0.0.0/0            tcp dpt:22
WEB_RULES  tcp  --  0.0.0.0/0            0.0.0.0/0            multiport dports 80,443
```

---

## 8. 규칙 영구 저장 및 복원

```bash
# 현재 규칙 파일로 저장
iptables-save > /etc/iptables/rules.v4
ip6tables-save > /etc/iptables/rules.v6

# 저장된 파일 확인
cat /etc/iptables/rules.v4
```
```
# Generated by iptables-save v1.8.7 on Wed May 21 15:00:00 2025
*filter
:INPUT DROP [1823:109380]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [5421:1234567]
-A INPUT -i lo -j ACCEPT
-A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A INPUT -p tcp -m tcp --dport 22 -j ACCEPT
-A INPUT -p tcp -m tcp --dport 80 -j ACCEPT
-A INPUT -p tcp -m tcp --dport 443 -j ACCEPT
COMMIT
*nat
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [3:180]
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -s 10.0.0.0/8 -o eth0 -j MASQUERADE
COMMIT
```

```bash
# 규칙 복원
iptables-restore < /etc/iptables/rules.v4

# Ubuntu: iptables-persistent 패키지로 재부팅 시 자동 적용
apt install iptables-persistent
netfilter-persistent save

# RHEL/CentOS: /etc/sysconfig/iptables 에 저장
service iptables save
cat /etc/sysconfig/iptables
```

---

## 9. 실전 시나리오

### 9.1 서버 기본 방화벽 구성

```bash
#!/bin/bash
# 기본 초기화
iptables -F
iptables -X
iptables -t nat -F
iptables -t mangle -F

# 기본 정책: Default Deny
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

# 루프백 허용
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# 기존 연결 허용
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# 비정상 패킷 차단
iptables -A INPUT -m conntrack --ctstate INVALID -j DROP

# SSH (내부 대역에서만)
iptables -A INPUT -p tcp --dport 22 -s 10.0.0.0/8 -j ACCEPT

# 웹 서비스
iptables -A INPUT -p tcp -m multiport --dports 80,443 -j ACCEPT

# ICMP ping 허용 (제한적)
iptables -A INPUT -p icmp --icmp-type echo-request \
    -m limit --limit 5/sec --limit-burst 10 -j ACCEPT

# 최종 확인
iptables -L -v -n
```
```
Chain INPUT (policy DROP 0 packets, 0 bytes)
 pkts bytes target     prot opt in     out     source               destination
    0     0 ACCEPT     all  --  lo     *       0.0.0.0/0            0.0.0.0/0
    0     0 ACCEPT     all  --  *      *       0.0.0.0/0            0.0.0.0/0            ctstate RELATED,ESTABLISHED
    0     0 DROP       all  --  *      *       0.0.0.0/0            0.0.0.0/0            ctstate INVALID
    0     0 ACCEPT     tcp  --  *      *       10.0.0.0/8           0.0.0.0/0            tcp dpt:22
    0     0 ACCEPT     tcp  --  *      *       0.0.0.0/0            0.0.0.0/0            multiport dports 80,443
    0     0 ACCEPT     icmp --  *      *       0.0.0.0/0            0.0.0.0/0            icmptype 8 limit: avg 5/sec burst 10

Chain FORWARD (policy DROP 0 packets, 0 bytes)
 pkts bytes target     prot opt in     out     source               destination

Chain OUTPUT (policy ACCEPT 0 packets, 0 bytes)
 pkts bytes target     prot opt in     out     source               destination
```

### 9.2 NAT 게이트웨이 구성

```bash
# IP 포워딩 활성화
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
sysctl -p

# MASQUERADE로 내부망 → 외부 인터넷
iptables -t nat -A POSTROUTING -s 10.0.0.0/8 -o eth0 -j MASQUERADE

# 내부망 포워딩 허용
iptables -A FORWARD -i eth1 -o eth0 -j ACCEPT
iptables -A FORWARD -i eth0 -o eth1 -m conntrack \
    --ctstate ESTABLISHED,RELATED -j ACCEPT

# 내부망에서 특정 포트만 외부 허용
iptables -A FORWARD -i eth1 -o eth0 \
    -p tcp -m multiport --dports 80,443,53 -j ACCEPT
iptables -A FORWARD -i eth1 -o eth0 \
    -p udp --dport 53 -j ACCEPT

iptables -L FORWARD -v -n
```
```
Chain FORWARD (policy DROP 0 packets, 0 bytes)
 pkts bytes target     prot opt in     out     source               destination
  12K  8.5M ACCEPT     all  --  eth1   eth0    0.0.0.0/0            0.0.0.0/0
  11K  9.2M ACCEPT     all  --  eth0   eth1    0.0.0.0/0            0.0.0.0/0            ctstate RELATED,ESTABLISHED
    0     0 ACCEPT     tcp  --  eth1   eth0    0.0.0.0/0            0.0.0.0/0            multiport dports 80,443,53
    0     0 ACCEPT     udp  --  eth1   eth0    0.0.0.0/0            0.0.0.0/0            udp dpt:53
```

### 9.3 SYN Flood 방어

```bash
# SYN cookie 활성화
sysctl -w net.ipv4.tcp_syncookies=1

# SYNFLOOD 체인 생성
iptables -N SYNFLOOD

# 속도 제한: 초당 20개까지 허용, 이후 DROP
iptables -A SYNFLOOD -m limit --limit 20/sec --limit-burst 40 -j RETURN
iptables -A SYNFLOOD -j LOG --log-prefix "[SYNFLOOD] " --log-level 4
iptables -A SYNFLOOD -j DROP

# SYN 패킷을 SYNFLOOD 체인으로 점프
iptables -A INPUT -p tcp --syn -j SYNFLOOD

iptables -L SYNFLOOD -v -n
```
```
Chain SYNFLOOD (1 references)
 pkts bytes target     prot opt in     out     source               destination
  18K 1116K RETURN     all  --  *      *       0.0.0.0/0            0.0.0.0/0            limit: avg 20/sec burst 40
    3   180 LOG        all  --  *      *       0.0.0.0/0            0.0.0.0/0            LOG flags 0 level 4 prefix "[SYNFLOOD] "
    3   180 DROP       all  --  *      *       0.0.0.0/0            0.0.0.0/0
```

### 9.4 포트 포워딩 (외부 80 → 내부 8080)

```bash
# DNAT: 들어오는 패킷 변환
iptables -t nat -A PREROUTING \
    -i eth0 -p tcp --dport 80 \
    -j DNAT --to-destination 10.0.1.50:8080

# FORWARD: 변환된 패킷 포워딩 허용
iptables -A FORWARD \
    -i eth0 -o eth1 \
    -p tcp -d 10.0.1.50 --dport 8080 \
    -j ACCEPT

# 확인: 실제 연결 테스트
curl -v http://203.0.113.1:80  # 외부에서 접속

# conntrack 테이블로 변환 확인
conntrack -L | grep 8080
```
```
tcp      6 86396 ESTABLISHED src=203.0.113.55 dst=203.0.113.1 sport=54321 dport=80 \
         src=10.0.1.50 dst=203.0.113.55 sport=8080 dport=54321 [ASSURED] mark=0 use=1
```

---

## 10. 자주 하는 실수

| 실수 | 올바른 방법 |
|------|-----------|
| `-F` 후 SSH 차단 (`-P INPUT DROP` 상태) | `-F` 전에 `-P INPUT ACCEPT`로 변경하거나 SSH 허용 규칙을 먼저 추가 |
| `-A`로 차단 규칙 추가 → 동작 안 함 | 상단 ACCEPT 규칙이 이미 있으면 `-I` 로 상단에 삽입 |
| ESTABLISHED 허용 없이 OUTPUT ACCEPT만 설정 | INPUT에 `--ctstate ESTABLISHED,RELATED -j ACCEPT` 추가 |
| NAT 없이 포트포워딩 설정 | DNAT + FORWARD 규칙 + `ip_forward=1` 모두 필요 |
| 규칙 저장 없이 재부팅 | `iptables-save > /etc/iptables/rules.v4` 로 영구 저장 |
| `-L` 로 확인 시 IP 역조회 느림 | 항상 `-n` 옵션 추가 (`-L -n -v`) |
| 규칙 수천 개 — 성능 저하 | `ipset` 으로 IP 집합 관리, nftables 마이그레이션 검토 |
| OUTPUT 체인 Drop 후 DNS 실패 | OUTPUT에도 `--ctstate ESTABLISHED -j ACCEPT` 필요 |

---

## 11. 디버깅 & 모니터링

```bash
# 규칙별 패킷/바이트 카운터 실시간 모니터링
watch -n 1 'iptables -L -n -v'

# 특정 IP의 패킷 추적 (LOG로 임시 확인)
iptables -I INPUT 1 -s 203.0.113.55 \
    -j LOG --log-prefix "[DEBUG-SRC] " --log-level 7
journalctl -f -k | grep "DEBUG-SRC"
# 확인 후 즉시 제거
iptables -D INPUT 1

# conntrack 통계
conntrack -S
```
```
cpu=0 found=1 invalid=0 ignore=3 insert=0 insert_failed=0 drop=0 early_drop=0 error=0 search_restart=12
cpu=1 found=2 invalid=0 ignore=5 insert=0 insert_failed=0 drop=0 early_drop=0 error=0 search_restart=8
```

```bash
# conntrack 테이블 크기 확인 (풀 나면 새 연결 불가)
cat /proc/sys/net/netfilter/nf_conntrack_count   # 현재 항목 수
cat /proc/sys/net/netfilter/nf_conntrack_max     # 최대 허용 수

# nf_conntrack_max 증설
sysctl -w net.netfilter.nf_conntrack_max=1048576
```
```
131072   ← 현재 항목 수
1048576  ← 최대 허용 수
```

---

## 12. 참고자료

- [Netfilter 공식 문서](https://netfilter.org/documentation/)
- [ArchWiki: iptables](https://wiki.archlinux.org/title/iptables)
- [man 8 iptables-extensions](https://ipset.netfilter.org/iptables-extensions.man.html)
- 관련 문서: `linux-conntrack.md`, `linux-synflood.md`, `linux-nftables.md`, `linux-ipvs.md`
