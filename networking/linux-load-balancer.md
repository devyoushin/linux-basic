## 1. 개요

로드밸런서(Load Balancer)는 클라이언트 요청을 여러 서버에 분산해 단일 장애점(SPOF)을 없애고 수평 확장(Scale-out)을 가능하게 하는 장치다.
동작하는 OSI 계층에 따라 L4(전송 계층)와 L7(응용 계층)으로 나뉘며, 이 차이를 이해하면 AWS ALB/NLB 선택 기준과 장애 패턴의 원인이 명확해진다.

---

## 2. L4 vs L7 로드밸런서

### 2.1 OSI 계층별 동작

```
Client
  │
  ▼
[L7 LB] ← HTTP 헤더, URL, 쿠키, 본문까지 읽고 판단
  │         (Application Layer: HTTP/HTTPS/gRPC)
  │
  ▼
[L4 LB] ← IP + Port만 보고 판단
  │         (Transport Layer: TCP/UDP)
  │
  ▼
Backend Servers
```

### 2.2 핵심 차이점

| | L4 로드밸런서 | L7 로드밸런서 |
|---|---|---|
| **판단 기준** | IP 주소 + 포트 번호 | HTTP 헤더, URL, 쿠키, 본문 |
| **프로토콜 인식** | TCP/UDP (내용 모름) | HTTP, HTTPS, WebSocket, gRPC |
| **속도** | 빠름 (패킷 수준 처리) | 상대적으로 느림 (패킷 조합 후 해석) |
| **SSL 종료** | 불가 (TCP 그대로 전달) | 가능 (HTTPS 복호화 후 HTTP로 전달) |
| **URL 기반 라우팅** | 불가 | 가능 (`/api/*` → A서버, `/static/*` → B서버) |
| **AWS 서비스** | NLB (Network LB) | ALB (Application LB) |
| **주요 용도** | 게임, IoT, 초고성능 | 웹 서비스, REST API, MSA |

### 2.3 L4 동작 방식 (TCP 수준)

```
Client ──── TCP SYN ────→ L4 LB
               │
               │ (IP + Port만 보고 백엔드 선택)
               │
Client ←──── 이후 패킷 ────→ Backend Server
              (NAT 방식: L4 LB가 src/dst IP 변환)
```

L4 LB는 TCP 핸드쉐이크 이후 패킷을 그냥 포워딩한다. HTTP 내용을 보지 않으므로:
- 같은 TCP 연결의 모든 패킷은 같은 서버로 감
- HTTP 요청 내용(`/api/users` vs `/api/orders`)을 구분 못 함

### 2.4 L7 동작 방식 (HTTP 수준)

```
Client ──── HTTP Request ────→ L7 LB
                                  │
                                  │ HTTP 헤더/URL/쿠키 분석
                                  │
              ┌───────────────────┤
              │                   │
              ▼                   ▼
         /api/* 서버          /static/* 서버
```

L7 LB는 TCP를 LB에서 종료하고 별도의 TCP 연결로 백엔드와 통신한다:
- 클라이언트 → LB: TCP 연결 1
- LB → 백엔드: TCP 연결 2 (별도)
- HTTP 내용을 파악해 URL, 헤더, 쿠키 기반 라우팅 가능
- SSL 인증서를 LB에서 처리(SSL Termination)

---

## 3. 로드밸런싱 알고리즘

### 3.1 Round Robin (라운드 로빈)

```
요청 1 → Server A
요청 2 → Server B
요청 3 → Server C
요청 4 → Server A  (처음으로 돌아감)
```

- 가장 단순하고 일반적인 방식
- 모든 서버 스펙이 동일하고 요청 처리 시간이 유사할 때 적합
- 서버 성능 차이가 크면 불균형 발생

### 3.2 Weighted Round Robin (가중치 라운드 로빈)

```
Server A (weight=3): 요청 1, 2, 3
Server B (weight=1): 요청 4
Server A (weight=3): 요청 5, 6, 7
Server B (weight=1): 요청 8
```

- 서버 스펙(CPU, 메모리)에 따라 가중치 부여
- AWS ALB에서 Target Group의 각 타겟에 가중치 설정 가능

### 3.3 Least Connections (최소 연결)

```
Server A: 현재 연결 100개
Server B: 현재 연결 30개  ← 다음 요청은 여기로
Server C: 현재 연결 75개
```

- 현재 활성 연결 수가 가장 적은 서버로 전달
- 처리 시간이 일정하지 않은 서비스(파일 업로드, 영상 처리 등)에 적합

### 3.4 IP Hash (IP 해시)

```
Client IP 1.2.3.4  → hash(1.2.3.4) % 3 = 0 → Server A (항상)
Client IP 5.6.7.8  → hash(5.6.7.8) % 3 = 2 → Server C (항상)
```

- 같은 클라이언트 IP는 항상 같은 서버로 (Sticky Session의 단순한 형태)
- 세션 상태를 서버 메모리에 저장할 때 활용
- 단점: 특정 IP 대역이 몰리면 서버 불균형

### 3.5 Least Response Time

- 응답 시간이 가장 짧은 서버로 전달
- 주기적으로 각 서버 응답 시간을 측정
- HAProxy, NGINX Plus 등에서 지원

---

## 4. 핵심 기능

### 4.1 헬스 체크 (Health Check)

LB는 주기적으로 백엔드 서버가 살아있는지 확인한다.

```
L4 헬스체크: TCP 포트에 연결 가능한지 확인
  LB ──── TCP Connect to :8080 ────→ Server
  → 연결 성공 = 정상, 연결 실패 = 제외

L7 헬스체크: HTTP 응답 코드 확인
  LB ──── GET /health HTTP/1.1 ────→ Server
  → 200 OK = 정상, 5xx / 타임아웃 = 제외
```

```bash
# AWS ALB 헬스체크 설정 (Terraform)
resource "aws_lb_target_group" "app" {
  name     = "app-tg"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    enabled             = true
    path                = "/health"      # 헬스체크 URL
    healthy_threshold   = 2              # 연속 2회 성공 → 정상
    unhealthy_threshold = 3              # 연속 3회 실패 → 제외
    interval            = 30            # 30초마다 확인
    timeout             = 5             # 5초 안에 응답 없으면 실패
    matcher             = "200"         # 200 응답만 정상
  }
}
```

### 4.2 Sticky Session (세션 고정)

같은 클라이언트의 요청이 항상 같은 서버로 가도록 고정한다.

```
방법 1: 쿠키 기반 (L7만 가능)
  첫 요청 → LB가 AWSALB 쿠키 발급 → Server A
  이후 요청 → 쿠키 보고 → Server A로 고정

방법 2: IP Hash (L4/L7 모두 가능)
  같은 IP → 항상 같은 서버
```

> **주의**: Sticky Session은 세션 상태를 서버 메모리에 저장하는 레거시 아키텍처에서 필요하다. 현대적인 설계에서는 세션을 Redis 등 외부 저장소에 두어 Sticky Session 없이 운영하는 것이 권장된다.

### 4.3 Connection Draining (연결 드레이닝)

배포나 장애 시 백엔드를 LB에서 제거할 때, **기존 연결이 완료될 때까지 기다렸다가** 제거한다.

```
1. LB에서 Server A를 "draining" 상태로 변경
2. 새 요청은 Server A로 보내지 않음
3. 기존 진행 중인 요청은 완료될 때까지 허용 (최대 N초)
4. N초 후 또는 모든 연결 완료 후 완전 제거
```

```bash
# AWS에서 Deregistration Delay (드레이닝 대기 시간) 설정
resource "aws_lb_target_group" "app" {
  deregistration_delay = 300   # 최대 300초 대기 (기본값)
}
```

### 4.4 SSL Termination vs SSL Passthrough

```
SSL Termination (L7 ALB):
  Client ──HTTPS──→ ALB (인증서 처리) ──HTTP──→ Backend
  장점: 백엔드 서버가 SSL 부담 없음, 헤더 조작 가능
  단점: LB~백엔드 구간 암호화 없음 (VPC 내부라면 허용)

SSL Passthrough (L4 NLB):
  Client ──HTTPS──→ NLB (그냥 통과) ──HTTPS──→ Backend
  장점: 종단 간 암호화, URL 기반 라우팅 불가
  단점: 백엔드가 SSL 처리, 헤더 조작 불가
```

---

## 5. AWS ALB vs NLB 선택 기준

| 상황 | 선택 | 이유 |
|---|---|---|
| 웹 서비스, REST API | ALB | URL 기반 라우팅, 헤더 조작, WAF 연동 |
| WebSocket, gRPC | ALB | HTTP/2 지원 |
| 초고성능, 낮은 레이턴시 (게임, IoT) | NLB | L4 처리, 수백만 요청/초 |
| 고정 IP 필요 (방화벽 화이트리스트) | NLB | 고정 IP 제공 (ALB는 IP가 변함) |
| TCP 그대로 전달 (DB 프록시 등) | NLB | 프로토콜 무관 TCP 포워딩 |
| 멀티 서비스 단일 도메인 (`/api`, `/web`) | ALB | 경로 기반 라우팅 |

```
ALB가 IP가 변하는 이유:
ALB는 내부적으로 여러 AZ에 LB 노드를 띄우고,
DNS가 이 노드들의 IP를 라운드로빈으로 반환한다.
LB 노드가 스케일링되면 IP가 추가/제거된다.
→ ALB 도메인명으로만 접근해야 한다 (IP 직접 접근 금지)
```

---

## 6. 주요 장애 패턴

### 6.1 504 Gateway Timeout

```
원인: 백엔드가 LB의 idle timeout 안에 응답 못 함
진단: 백엔드 처리 시간 측정, LB idle timeout 설정 확인

# AWS ALB 기본 idle timeout: 60초
# 오래 걸리는 작업(파일 업로드, 배치 등)은 timeout 늘려야 함
```

### 6.2 Connection Reset (TCP RST)

```
원인 1: 백엔드가 keepalive 연결을 먼저 끊음
  → LB는 연결 살아있다고 알고 요청 보냈는데 서버가 이미 닫음
  해결: 백엔드 keepalive timeout > ALB idle timeout 설정

원인 2: 백엔드 서버가 과부하로 연결 거부
  해결: 헬스체크 간격/임계값 조정, 오토스케일링
```

### 6.3 Uneven Distribution (불균등 분산)

```
원인: Sticky Session + 특정 IP 집중
      또는 Round Robin인데 처리 시간 차이가 큼

해결: Least Connections 알고리즘으로 변경
     또는 세션 외부화(Redis)로 Sticky 제거
```

---

## 7. nginx를 L7 LB로 사용하기

AWS ALB 없이 자체 서버에서 nginx를 LB로 구성하는 패턴이다.

```nginx
# /etc/nginx/nginx.conf

upstream backend {
    least_conn;                          # Least Connections 알고리즘
    server 10.0.1.10:8080 weight=3;     # 가중치 3
    server 10.0.1.11:8080 weight=1;     # 가중치 1
    server 10.0.1.12:8080 backup;       # 나머지 모두 다운 시 사용
    keepalive 32;                        # 백엔드 keepalive 연결 풀
}

server {
    listen 80;

    location /api/ {
        proxy_pass http://backend;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;        # 실제 클라이언트 IP 전달
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_connect_timeout 5s;
        proxy_read_timeout 60s;
    }

    # 헬스체크 엔드포인트 (LB가 nginx 자체를 체크할 때)
    location /health {
        return 200 "ok\n";
        add_header Content-Type text/plain;
    }
}
```

## 8. 자주 하는 실수

| 실수 | 올바른 방법 |
|---|---|
| ALB IP를 방화벽에 직접 등록 | ALB는 IP가 변함, 도메인 또는 보안 그룹으로 접근 제어 |
| 헬스체크 URL이 무거운 로직 포함 | `/health`는 DB 연결 체크 정도만, 응답 빨라야 함 |
| Sticky Session으로 스케일 아웃 효과 반감 | 세션을 Redis 외부화해서 Stateless 구조로 |
| Connection Draining 미설정으로 배포 중 502 | `deregistration_delay` 충분히 설정 |
| 백엔드 keepalive < ALB idle timeout | 백엔드 timeout을 항상 ALB보다 길게 설정 |
