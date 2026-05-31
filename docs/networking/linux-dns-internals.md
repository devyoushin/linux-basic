## 1. 개요

DNS(Domain Name System)는 도메인 이름을 IP 주소로 변환하는 분산 데이터베이스다.
"왜 도메인을 바꿨는데 반영이 안 되지?", "내부 서비스가 이름으로 안 잡히는 이유가 뭐지?" 같은 문제는
DNS 쿼리 흐름과 TTL, 캐싱 구조를 이해하면 즉시 진단할 수 있다.

> 관련 문서: `linux-hosts-vs-resolv-conf.md`

---

## 2. DNS 쿼리 전체 흐름

### 2.1 재귀 조회 (Recursive Query) - 일반적인 경우

```
사용자가 www.example.com 접속 시도

1. 로컬 캐시 확인 (OS 캐시, /etc/hosts)
   └→ 있으면 즉시 반환 (DNS 쿼리 없음)

2. /etc/resolv.conf의 nameserver(리졸버)에 질의
   예: 8.8.8.8 (Google DNS) 또는 169.254.169.253 (AWS VPC DNS)

3. 리졸버가 대신 조회 (재귀적으로):
   a. 루트 DNS 서버 (.) 에 질의
      → "com. 담당은 이 서버입니다" (NS 레코드 반환)
   b. com. TLD DNS 서버에 질의
      → "example.com. 담당은 이 서버입니다"
   c. example.com. 권한 DNS 서버에 질의
      → "www.example.com = 93.184.216.34" (A 레코드 반환)

4. 리졸버가 결과를 캐싱 후 클라이언트에게 반환
```

```
클라이언트            리졸버              루트       .com TLD    example.com
    │                   │                  │            │             │
    │── www.example.com?─→                │            │             │
    │                   │── com. NS? ────→│            │             │
    │                   │←── A.gtld-... ──│            │             │
    │                   │── www.example? ─────────────→│             │
    │                   │←── ns1.example ──────────────│             │
    │                   │── www.example? ──────────────────────────→│
    │                   │←── 93.184.216.34 ────────────────────────│
    │←── 93.184.216.34 ─│
```

### 2.2 루트 DNS 서버

전 세계에 13개의 루트 서버 클러스터가 있다 (a~m.root-servers.net).
실제로는 Anycast로 수백 개의 물리 서버가 분산 운영된다.

```bash
# 루트 서버 목록 확인
dig . NS

# 루트 서버에 직접 질의 (재귀 없이)
dig @a.root-servers.net www.example.com
```

---

## 3. DNS 레코드 종류

| 레코드 | 의미 | 예시 |
|---|---|---|
| `A` | 도메인 → IPv4 주소 | `www.example.com → 93.184.216.34` |
| `AAAA` | 도메인 → IPv6 주소 | `www.example.com → 2606:2800::1` |
| `CNAME` | 도메인 → 다른 도메인 (별칭) | `blog.example.com → example.github.io` |
| `MX` | 메일 서버 지정 | `example.com → mail.example.com (우선순위 10)` |
| `NS` | 이 도메인의 권한 DNS 서버 | `example.com NS → ns1.example.com` |
| `TXT` | 임의 텍스트 (SPF, 도메인 인증) | `"v=spf1 include:_spf.google.com ~all"` |
| `PTR` | IP → 도메인 (역방향 조회) | `34.216.184.93.in-addr.arpa → www.example.com` |
| `SOA` | 도메인 권한 정보 (TTL 기본값 등) | 영역 전체 설정 |
| `SRV` | 서비스 위치 (포트 포함) | `_http._tcp.example.com → 80 www.example.com` |

---

## 4. TTL (Time To Live)과 캐싱

### 4.1 TTL 동작 원리

```
example.com A 레코드 TTL = 300 (5분)

1. 리졸버가 A 레코드 조회 → 캐시 저장 (남은시간: 300초)
2. 다른 클라이언트 질의 → 캐시 반환 (남은시간: 250초)
3. 300초 후 → 캐시 만료, 다시 권한 DNS에 질의

→ IP를 변경해도 기존 TTL이 만료될 때까지 이전 IP가 반환됨
```

### 4.2 TTL 전략

```
상황별 TTL 권장:
- 일반 운영: 300~3600초 (5분~1시간)
- 빠른 변경 예정 (마이그레이션 전): 60~120초로 미리 낮춤
- CDN/정적 리소스: 86400초 (24시간)
- AWS ALB CNAME: 60초 (AWS 권장, IP가 변하므로)

마이그레이션 절차:
1. 변경 1~2일 전: TTL을 300→60초로 낮춤
2. TTL 낮아진 후: IP 변경 (최대 60초 후 전파)
3. 안정화 후: TTL 다시 3600초로 높임
```

---

## 5. dig 명령어 실전

```bash
# 기본 A 레코드 조회
dig example.com

# 특정 레코드 타입 조회
dig example.com A
dig example.com AAAA
dig example.com MX
dig example.com NS
dig example.com TXT
dig example.com CNAME

# 특정 DNS 서버에 직접 질의
dig @8.8.8.8 example.com       # Google DNS
dig @1.1.1.1 example.com       # Cloudflare DNS
dig @169.254.169.253 example.com  # AWS VPC DNS (EC2 내부)

# 짧은 출력 (+short)
dig +short example.com          # IP만 출력
dig +short MX example.com       # MX 레코드만

# 전체 조회 과정 추적 (+trace)
dig +trace example.com
# → 루트 → TLD → 권한 서버 순으로 실제 조회 과정 출력

# TTL 확인
dig example.com | grep -A1 "ANSWER SECTION"
# example.com.   299   IN   A   93.184.216.34
#                └─ TTL(초) ─┘

# 역방향 조회 (IP → 도메인)
dig -x 93.184.216.34
# 또는
dig PTR 34.216.184.93.in-addr.arpa

# 권한 있는 응답인지 확인 (AUTHORITY 섹션 여부)
dig example.com +norecurse @ns1.example.com
```

### 5.1 dig 출력 해석

```
;; ANSWER SECTION:
www.example.com.  300   IN   A   93.184.216.34
└─ 도메인 ────┘  └TTL┘ └클래스┘└타입┘└─ 값 ─┘

;; Query time: 12 msec          ← 응답 시간
;; SERVER: 8.8.8.8#53           ← 응답한 DNS 서버
;; MSG SIZE rcvd: 56            ← 응답 패킷 크기

;; flags: qr rd ra              ← qr:응답, rd:재귀요청, ra:재귀가능
;; ANSWER: 1, AUTHORITY: 0, ADDITIONAL: 0
```

---

## 6. AWS 환경의 DNS

### 6.1 VPC DNS 구조

```
EC2 인스턴스
  │
  │ /etc/resolv.conf: nameserver 169.254.169.253
  ▼
AWS VPC DNS (Route 53 Resolver)
  ├→ VPC 내부 도메인: ec2.internal, .local → 즉시 응답
  ├→ Route 53 Private Hosted Zone → 사설 도메인 해석
  └→ 외부 인터넷 도메인 → 재귀 조회
```

```bash
# EC2에서 VPC DNS 주소 확인
cat /etc/resolv.conf
# nameserver 169.254.169.253   ← AWS VPC DNS

# EC2 인스턴스 자체 DNS 이름 확인
curl -s http://169.254.169.254/latest/meta-data/hostname
# ip-10-0-1-100.ap-northeast-2.compute.internal

# VPC 내 다른 EC2를 이름으로 조회 (Private DNS 활성화 시)
dig ip-10-0-1-200.ap-northeast-2.compute.internal
```

### 6.2 Route 53 Private Hosted Zone

VPC 내부에서만 해석되는 사설 도메인을 만들 때 사용한다.

```hcl
# Terraform으로 Private Hosted Zone 생성
resource "aws_route53_zone" "private" {
  name = "internal.mycompany.com"

  vpc {
    vpc_id = aws_vpc.main.id
  }
}

# 서비스별 DNS 레코드
resource "aws_route53_record" "db" {
  zone_id = aws_route53_zone.private.zone_id
  name    = "db.internal.mycompany.com"
  type    = "CNAME"
  ttl     = 60
  records = [aws_db_instance.main.address]
}

# 이후 EC2에서 db.internal.mycompany.com 으로 RDS 접근 가능
# 엔드포인트 직접 하드코딩 없이 관리 가능
```

### 6.3 DNS 문제 트러블슈팅

```bash
# 1. 기본 조회 테스트
dig +short db.internal.mycompany.com

# 2. 어느 DNS 서버가 응답하는지
dig db.internal.mycompany.com | grep "SERVER:"

# 3. DNS 응답 지연 측정
for i in {1..5}; do
    dig +stats +noall example.com 2>&1 | grep "Query time"
done

# 4. /etc/hosts vs DNS 우선순위 확인
getent hosts example.com      # nsswitch.conf 순서대로 조회
cat /etc/nsswitch.conf | grep hosts
# hosts: files dns   ← files(/etc/hosts)가 dns보다 먼저

# 5. 캐시 플러시
# systemd-resolved 사용 시
systemd-resolve --flush-caches
resolvectl flush-caches

# nscd 사용 시
service nscd restart
```

---

## 7. DNS 전파 속도 이해

```
레코드 변경 후 전파가 느린 이유:

1. 권한 DNS 업데이트: 즉시 (변경 즉시 적용)
2. 리졸버 캐시 만료: TTL 시간만큼 대기
3. OS/브라우저 캐시: 별도 캐시 시간

실제 경험:
- TTL 300초: 변경 후 최대 5분
- TTL 3600초: 변경 후 최대 1시간
- 일부 ISP가 TTL 무시하고 더 오래 캐싱하는 경우도 있음

확인 방법:
dig +short example.com @8.8.8.8   # Google DNS에서 캐시 확인
dig +short example.com @1.1.1.1   # Cloudflare DNS에서 확인
# 두 결과가 다르면 아직 전파 중
```

## 8. 자주 하는 실수

| 실수 | 올바른 방법 |
|---|---|
| DNS 변경 후 즉시 반영 기대 | TTL만큼 기다려야 함, 변경 전 TTL 미리 낮추기 |
| 서버에서만 조회 확인하고 배포 | 다른 리전/DNS 서버에서도 `dig` 로 확인 |
| CNAME을 루트 도메인(`@`)에 사용 | 루트 도메인은 CNAME 불가, A 레코드 또는 ALIAS/ANAME 사용 |
| ALB 도메인을 A 레코드로 직접 IP 등록 | ALB IP는 변함, CNAME 또는 Route 53 Alias 레코드 사용 |
| `/etc/hosts`에 등록했는데 반영 안 됨 | `nsswitch.conf`에서 `files`가 `dns`보다 앞인지 확인 |
