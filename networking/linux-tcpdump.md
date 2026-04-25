# linux-tcpdump.md — 패킷 캡처 및 네트워크 분석

## 1. 개요

`tcpdump`는 네트워크 인터페이스의 패킷을 캡처하고 분석하는 CLI 도구다. SRE/DevOps 관점에서 서비스 간 통신 문제, TLS 핸드셰이크 실패, 포트 연결 거부, 패킷 손실 등 네트워크 레이어 장애의 근본 원인을 찾는 가장 강력한 수단이다. Wireshark가 없는 서버 환경에서는 tcpdump로 캡처 후 `.pcap` 파일을 로컬로 가져와 분석하는 패턴이 표준이다.

---

## 2. 설명

### 2.1 기본 사용법

```bash
# 특정 인터페이스 캡처 (eth0)
tcpdump -i eth0

# 모든 인터페이스
tcpdump -i any

# 인터페이스 목록 확인
tcpdump -D

# DNS 역방향 조회 없이 IP 그대로 출력 (-n: IP, -nn: IP+포트)
tcpdump -i eth0 -nn

# 패킷 페이로드 16진수+ASCII 출력
tcpdump -i eth0 -XX

# 캡처 수 제한 (100개 후 종료)
tcpdump -i eth0 -c 100

# .pcap 파일로 저장 → Wireshark 분석
tcpdump -i eth0 -w /tmp/capture.pcap
tcpdump -r /tmp/capture.pcap        # 파일 읽기
```

### 2.2 핵심 필터 문법 (BPF)

tcpdump는 Berkeley Packet Filter(BPF) 표현식으로 필터링한다.

```bash
# 특정 호스트 트래픽
tcpdump -i eth0 host 10.0.1.5
tcpdump -i eth0 src host 10.0.1.5   # 출발지만
tcpdump -i eth0 dst host 10.0.1.5   # 목적지만

# 특정 포트
tcpdump -i eth0 port 443
tcpdump -i eth0 portrange 8080-8090

# 프로토콜 필터
tcpdump -i eth0 tcp
tcpdump -i eth0 udp
tcpdump -i eth0 icmp

# 복합 조건 (and / or / not)
tcpdump -i eth0 "host 10.0.1.5 and port 80"
tcpdump -i eth0 "tcp and not port 22"    # SSH 제외
tcpdump -i eth0 "(src 10.0.0.1 or src 10.0.0.2) and dst port 5432"

# VXLAN 터널 내부 트래픽 분석 (컨테이너 네트워크)
tcpdump -i eth0 "udp port 4789"
```

### 2.3 실전 장애 대응 시나리오

#### TCP 연결 거부 확인 (RST 패킷 탐지)

```bash
# RST 플래그 패킷 캡처 — 연결 거부/강제 종료 탐지
tcpdump -i any -nn "tcp[tcpflags] & tcp-rst != 0"
```

#### TLS 핸드셰이크 분석

```bash
# TLS ClientHello / ServerHello 캡처
tcpdump -i eth0 -nn "port 443 and (tcp[((tcp[12] & 0xf0) >> 2)] = 0x16)"

# SNI 확인용 (첫 1500바이트 캡처)
tcpdump -i eth0 -s 1500 -w /tmp/tls.pcap "port 443"
```

#### HTTP 요청/응답 페이로드 확인

```bash
# HTTP GET/POST 메서드 포함 패킷만 필터
tcpdump -i eth0 -A -s 0 "tcp port 80 and (((ip[2:2] - ((ip[0]&0xf)<<2)) - ((tcp[12]&0xf0)>>2)) != 0)"

# 더 간단하게: 스트링 포함 필터
tcpdump -i eth0 -A "port 80" | grep -E "(GET|POST|HTTP|Host:)"
```

#### SYN Flood / 연결 폭증 탐지

```bash
# SYN 패킷만 캡처 (SYN 있고 ACK 없음)
tcpdump -i eth0 -nn "tcp[tcpflags] == tcp-syn"

# 초당 SYN 수 집계
tcpdump -i eth0 -nn "tcp[tcpflags] == tcp-syn" 2>/dev/null | \
  awk '{print $1}' | cut -d. -f1 | uniq -c
```

#### DNS 쿼리 추적

```bash
# DNS 쿼리/응답 전체 캡처
tcpdump -i eth0 -nn "port 53"

# DNS 쿼리 도메인 이름만 추출
tcpdump -i eth0 -nn -l "port 53" 2>/dev/null | \
  grep -oP 'A\? \K[^\s]+'
```

#### 컨테이너/Pod 간 트래픽 분석 (Kubernetes)

```bash
# Pod의 veth 인터페이스 특정
ip link | grep veth

# 특정 Pod IP 트래픽 캡처
tcpdump -i any -nn "host <pod-ip>"

# kube-dns(CoreDNS) 쿼리 실패 탐지
tcpdump -i any -nn "port 53 and udp" | grep NXDOMAIN
```

### 2.4 출력 포맷 읽는 법

```
13:45:22.123456 IP 10.0.1.5.52341 > 10.0.2.10.443: Flags [S], seq 123456789, win 65535, length 0
│              │  │              │   │              │ │           │           │          │
│              │  │              │   │              │ └─ TCP 플래그 S=SYN      └─ 페이로드
│              │  └─ 출발지IP.포트  └─ 목적지IP.포트  └─ 프로토콜
└─ 타임스탬프(us)
```

**TCP 플래그 기호:**
| 기호 | 의미 |
|------|------|
| `[S]` | SYN — 연결 요청 |
| `[S.]` | SYN-ACK — 연결 수락 |
| `[.]` | ACK |
| `[P.]` | PSH-ACK — 데이터 전송 |
| `[F.]` | FIN-ACK — 정상 종료 |
| `[R]` | RST — 강제 종료/거부 |

### 2.5 .pcap 파일 원격 전달 패턴

```bash
# 서버에서 캡처 후 로컬로 복사
tcpdump -i eth0 -w /tmp/capture.pcap -c 10000 "port 443"
scp user@server:/tmp/capture.pcap ./

# 실시간 스트리밍 → 로컬 Wireshark로 열기 (macOS/Linux)
ssh user@server "tcpdump -i eth0 -U -w - 'port 443'" | wireshark -k -i -

# 원격 캡처를 로컬에서 직접 보기
ssh user@server "tcpdump -i eth0 -nn -l 'port 80'" | tee capture.txt
```

### 2.6 tshark — CLI 기반 Wireshark

더 복잡한 분석이 필요할 때 `tshark`(Wireshark CLI)를 사용한다.

```bash
# HTTP 응답 코드 집계
tshark -r capture.pcap -T fields -e http.response.code | sort | uniq -c | sort -rn

# TCP 재전송 패킷만 필터
tshark -r capture.pcap -Y "tcp.analysis.retransmission"

# 연결 지연(RTT) 측정
tshark -r capture.pcap -Y "tcp.analysis.ack_rtt" -T fields -e tcp.analysis.ack_rtt
```

---

## 3. 자주 하는 실수

| 실수 | 올바른 방법 |
|------|------------|
| `-n` 옵션 없이 캡처 → DNS 역조회로 느려짐 | 항상 `-nn` 옵션 사용 (IP+포트 숫자 그대로) |
| 스냅샷 크기 미설정으로 페이로드 잘림 | `-s 0` 또는 `-s 65535`로 전체 캡처 |
| 프로덕션에서 무제한 캡처 → 디스크 풀 | `-c <패킷수>` 또는 `-G <초>`로 파일 로테이션 |
| VLAN/터널 내부 트래픽 필터 미적용 | VXLAN(4789), GRE(47) 등 오버레이 프로토콜 고려 |
| 캡처 파일을 프로덕션 서버 루트에 저장 | `/tmp` 또는 임시 볼륨 사용, 분석 후 즉시 삭제 |
| tcpdump 결과만으로 애플리케이션 레이어 판단 | 페이로드 암호화 시 TLS 복호화 필요, strace/로그와 병행 |
| 필터 없이 전체 캡처 → 성능 영향 | 호스트/포트 필터로 최대한 범위 좁히기 |
