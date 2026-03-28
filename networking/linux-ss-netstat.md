## 1. 개요

`ss`(socket statistics)는 구식 `netstat`을 대체하는 현대 리눅스 네트워크 연결 조회 도구다.
어떤 포트가 열려 있는지, 어떤 프로세스가 포트를 점유하는지, 현재 연결 수는 얼마인지 등
네트워크 트러블슈팅에서 가장 먼저 실행하게 되는 명령어다.

---

## 2. ss vs netstat

```bash
# netstat (구식, net-tools 패키지, 최신 배포판에 기본 설치 안 됨)
netstat -tlnp

# ss (현대식, iproute2 패키지, 기본 설치됨)
ss -tlnp

# 설치 여부 확인
which netstat   # 없으면 apt install net-tools / yum install net-tools
which ss        # 기본 설치됨
```

| 항목 | `ss` | `netstat` |
|---|---|---|
| 속도 | 빠름 (커널 직접 조회) | 느림 (`/proc/net` 파싱) |
| 기본 설치 | 대부분 배포판 기본 | 별도 설치 필요 |
| 기능 | 더 많은 상세 정보 | 기본 기능 |
| 권장 여부 | 권장 | deprecated |

---

## 3. ss 주요 옵션

```bash
# 옵션 조합 - 가장 자주 쓰는 형태
ss -tlnp   # TCP, Listening, 숫자, 프로세스

# 옵션 의미
# -t: TCP 소켓
# -u: UDP 소켓
# -l: Listening(대기 중) 상태만
# -n: 호스트명/서비스명 대신 숫자(IP/포트)로 표시 (빠름)
# -p: 소켓을 사용하는 프로세스 정보 표시 (root 권한 필요)
# -a: 전체 상태 (listening + established)
# -e: 확장 정보 (inode, UID 등)
# -s: 요약 통계
```

---

## 4. 자주 쓰는 명령어

### 4.1 포트 리스닝 확인

```bash
# 모든 TCP 리스닝 포트
ss -tlnp

# 출력 예시:
# State   Recv-Q  Send-Q  Local Address:Port  Peer Address:Port  Process
# LISTEN  0       128     0.0.0.0:80         0.0.0.0:*          users:(("nginx",pid=1234,fd=6))
# LISTEN  0       128     0.0.0.0:22         0.0.0.0:*          users:(("sshd",pid=567,fd=3))
# LISTEN  0       128     127.0.0.1:3306     0.0.0.0:*          users:(("mysqld",pid=890,fd=21))

# UDP 리스닝
ss -ulnp

# TCP + UDP 모두
ss -tulnp
```

### 4.2 특정 포트 확인

```bash
# 특정 포트 사용 여부 확인
ss -tlnp | grep :8080
ss -tlnp sport = :8080    # ss 필터 문법

# 특정 포트를 사용 중인 프로세스 PID 추출
ss -tlnp | grep ':8080' | awk '{print $6}' | grep -oP 'pid=\K[0-9]+'

# 해당 PID 프로세스 확인
ps -p $(ss -tlnp | grep ':8080' | grep -oP 'pid=\K[0-9]+' | head -1) -f
```

### 4.3 연결 상태 조회

```bash
# 모든 TCP 연결 (established 포함)
ss -tnp

# 특정 서버와의 연결 확인
ss -tnp dst 10.0.1.100

# 특정 포트로의 연결 수 집계
ss -tn | grep ':443' | wc -l

# 상태별 연결 수 통계
ss -tn | awk 'NR>1 {print $1}' | sort | uniq -c | sort -rn
```

### 4.4 연결 통계 요약

```bash
ss -s

# 출력 예시:
# Total: 245
# TCP:   234 (estab 180, closed 30, orphaned 2, timewait 28)
#
# Transport  Total  IP  IPv6
# RAW        0      0   0
# UDP        8      5   3
# TCP        204    140 64
# INET       212    145 67
# FRAG       0      0   0
```

---

## 5. TCP 연결 상태 (State) 이해

```
Client                          Server
  │                               │
  │──── SYN ──────────────────→   │  SYN_SENT / SYN_RECEIVED
  │   ←─── SYN+ACK ──────────     │
  │──── ACK ──────────────────→   │  ESTABLISHED (데이터 통신 가능)
  │                               │
  │──── FIN ──────────────────→   │  FIN_WAIT_1
  │   ←─── ACK ──────────────     │  FIN_WAIT_2
  │   ←─── FIN ──────────────     │  CLOSE_WAIT (서버가 연결 닫는 중)
  │──── ACK ──────────────────→   │  TIME_WAIT (2MSL 대기)
                                     CLOSED
```

| 상태 | 의미 | 많으면 |
|---|---|---|
| `ESTABLISHED` | 정상 연결 중 | 정상 |
| `TIME_WAIT` | 연결 종료 후 대기 (약 60초) | 높은 트래픽, 짧은 연결 반복 |
| `CLOSE_WAIT` | 서버가 종료 안 하고 있음 | 앱 버그 (소켓 close 누락) |
| `SYN_RECV` | TCP 핸드쉐이크 진행 중 | SYN Flood 공격 의심 |
| `LISTEN` | 포트 대기 중 | 정상 |

```bash
# TIME_WAIT 많을 때 커널 파라미터로 재사용 활성화
sysctl -w net.ipv4.tcp_tw_reuse=1
echo "net.ipv4.tcp_tw_reuse=1" >> /etc/sysctl.conf

# CLOSE_WAIT 많을 때 - 해당 앱 프로세스 확인
ss -tnp state close-wait
```

---

## 6. 실전 트러블슈팅 패턴

### 6.1 포트 충돌 확인

```bash
# 8080 포트 이미 사용 중? 어느 프로세스인지 확인
ss -tlnp | grep :8080

# 해당 프로세스 종료 후 재시작
kill -9 $(ss -tlnp | grep ':8080' | grep -oP 'pid=\K[0-9]+')
```

### 6.2 DB 연결 수 확인 (커넥션 풀 포화 진단)

```bash
# MySQL(3306) 연결 수
ss -tn | grep ':3306' | grep ESTABLISHED | wc -l

# 연결 출발지 IP별 집계 (어느 앱 서버가 많이 붙어있는지)
ss -tn dst :3306 | awk 'NR>1 {print $5}' | cut -d: -f1 | sort | uniq -c | sort -rn
```

### 6.3 서비스 포트 외부 노출 여부 확인

```bash
# 0.0.0.0(전체) vs 127.0.0.1(로컬만) 구분
ss -tlnp

# 위험: 외부에 노출된 포트 (0.0.0.0:3306 - DB가 외부 노출)
# 안전: 로컬만 (127.0.0.1:3306 - DB가 로컬만 접근 가능)

# 외부 노출 포트 필터링 (보안 감사)
ss -tlnp | awk 'NR>1 && $4 !~ /^127\.|^\[::1\]/'
```

### 6.4 특정 원격 서버 연결 확인

```bash
# 특정 서버(10.0.1.100)와의 모든 연결
ss -tnp dst 10.0.1.100

# 특정 원격 포트로의 연결 (예: RDS 포트 5432)
ss -tnp 'dst :5432'

# 연결이 안 될 때 - 타임아웃 발생 여부
# (SYN_SENT 상태가 오래 지속되면 방화벽/보안그룹 문제)
ss -tnp state syn-sent
```

---

## 7. netstat 대응 표 (레거시 서버 작업 시 참고)

| ss | netstat | 설명 |
|---|---|---|
| `ss -tlnp` | `netstat -tlnp` | TCP 리스닝 포트 + 프로세스 |
| `ss -tulnp` | `netstat -tulnp` | TCP+UDP 리스닝 |
| `ss -tnp` | `netstat -tnp` | TCP 모든 연결 |
| `ss -s` | `netstat -s` | 연결 통계 요약 |
| `ss -tnp dst :80` | `netstat -tnp \| grep :80` | 특정 포트 필터 |

## 8. 자주 하는 실수

| 실수 | 올바른 방법 |
|---|---|
| `ss -p` 결과에 프로세스가 안 보임 | `sudo ss -tlnp` (root 권한 필요) |
| 포트 열렸는데 접속 안 됨 | `0.0.0.0` vs `127.0.0.1` 바인딩 확인 |
| `netstat` 설치 안 됨 | `ss` 사용 또는 `apt install net-tools` |
| TIME_WAIT 많아서 포트 소진 걱정 | `net.ipv4.tcp_tw_reuse=1` 설정 또는 정상 동작으로 간주 |
| CLOSE_WAIT 증가 무시 | 앱 소켓 누수 버그 징후, 반드시 원인 파악 |
