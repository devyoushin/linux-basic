# Nginx 성능 튜닝 — OS 커널 파라미터 & Nginx 내부 설정

## 1. 개요

Nginx는 이벤트 기반 비동기 아키텍처를 사용하지만, OS 기본값이 낮으면 고트래픽 구간에서 커넥션 거부·타임아웃·502 오류가 발생한다.
Nginx 내부 설정(worker, 버퍼, keepalive)과 OS 커널 파라미터(소켓 큐, 파일 디스크립터, TCP 옵션)를 함께 튜닝해야 실질적인 성능 향상을 얻을 수 있다.
두 레이어 중 하나만 조정하면 나머지가 병목이 되므로 반드시 쌍으로 적용한다.

---

## 2. 설명

### 2.1 핵심 개념

#### Nginx 요청 처리 흐름과 OS 연계 지점

```
클라이언트 → [OS: SYN 큐 / Accept 큐] → Nginx worker → [OS: 파일 디스크립터]
                ↑ somaxconn / tcp_max_syn_backlog         ↑ nofile / file-max
```

| 계층 | 주요 설정 | 병목 증상 |
|------|----------|----------|
| OS 커널 | `somaxconn`, `tcp_max_syn_backlog`, `ip_local_port_range` | SYN drop, 연결 거부 |
| OS 파일 디스크립터 | `fs.file-max`, `ulimit -n` | "too many open files" |
| Nginx 프로세스 | `worker_processes`, `worker_rlimit_nofile` | 연결 한계 도달 |
| Nginx 이벤트 | `use epoll`, `worker_connections`, `multi_accept` | 처리 지연 |
| Nginx TCP | `sendfile`, `tcp_nopush`, `tcp_nodelay`, `keepalive_timeout` | 불필요한 지연 |
| Nginx 버퍼 | `client_body_buffer_size`, `proxy_buffer_size` | 잦은 디스크 I/O |
| Nginx upstream | `keepalive` (upstream 블록) | upstream 연결 폭증 |

---

### 2.2 OS 커널 파라미터

#### 소켓 큐 및 TCP 설정

```bash
# 현재 커널 파라미터 확인
sysctl net.core.somaxconn
sysctl net.ipv4.tcp_max_syn_backlog
sysctl fs.file-max
```

```ini
# /etc/sysctl.d/99-nginx.conf
# ── Accept 큐 / SYN 큐 ──────────────────────────────────────────
net.core.somaxconn          = 65535   # listen() 큐 최대 크기 (기본 128 ~ 4096)
net.ipv4.tcp_max_syn_backlog = 65535  # SYN 패킷 대기 큐

# ── 파일 디스크립터 ──────────────────────────────────────────────
fs.file-max                 = 2000000 # 시스템 전체 열 수 있는 파일 수

# ── 포트 범위 (upstream 연결 포트 고갈 방지) ──────────────────────
net.ipv4.ip_local_port_range = 1024 65535

# ── TIME_WAIT 처리 ────────────────────────────────────────────────
net.ipv4.tcp_tw_reuse       = 1       # TIME_WAIT 소켓 재사용 (클라이언트 측만 효과)
net.ipv4.tcp_fin_timeout    = 15      # FIN_WAIT2 → CLOSE 전환 시간 단축 (기본 60초)

# ── 소켓 버퍼 ─────────────────────────────────────────────────────
net.core.rmem_max           = 16777216  # 수신 버퍼 최대 (16 MiB)
net.core.wmem_max           = 16777216  # 송신 버퍼 최대 (16 MiB)
net.ipv4.tcp_rmem           = 4096 87380 16777216
net.ipv4.tcp_wmem           = 4096 65536 16777216

# ── backlog 큐 처리 속도 ───────────────────────────────────────────
net.core.netdev_max_backlog = 16384   # NIC에서 커널로 올라오는 패킷 큐 크기
```

```bash
# 즉시 적용
sysctl -p /etc/sysctl.d/99-nginx.conf

# 적용 확인
sysctl net.core.somaxconn net.ipv4.tcp_max_syn_backlog
```

#### 파일 디스크립터 — ulimit

```bash
# Nginx 프로세스의 현재 nofile 한계 확인
cat /proc/$(pgrep -f 'nginx: master')/limits | grep 'open files'

# 시스템 전체 현황
ulimit -n          # 현재 셸 한계
cat /proc/sys/fs/file-nr  # [사용중] [해제됨] [최대]
```

```ini
# /etc/security/limits.d/nginx.conf
nginx   soft   nofile   65535
nginx   hard   nofile   65535
```

---

### 2.3 Nginx 내부 설정

#### 프로세스 & 이벤트

```nginx
# /etc/nginx/nginx.conf

# ── 프로세스 ───────────────────────────────────────────────────────
worker_processes  auto;            # vCPU 수만큼 자동 설정 (권장)
worker_rlimit_nofile 65535;        # worker 프로세스별 open files 한계 (ulimit 연계)
# worker_cpu_affinity auto;        # CPU 코어에 worker 고정 (NUMA 환경에서 유용)

events {
    use              epoll;        # Linux 이벤트 모델 (기본값이나 명시 권장)
    multi_accept     on;           # accept() 한 번에 여러 연결 수락
    worker_connections 65535;      # worker 1개당 최대 동시 연결 수
                                   # 실제 최대 = worker_processes × worker_connections
}
```

#### HTTP 레이어 TCP 최적화

```nginx
http {
    # ── Zero-copy 전송 ───────────────────────────────────────────────
    sendfile        on;            # 커널 공간에서 파일 → 소켓 직접 전송 (user-space 복사 제거)
    tcp_nopush      on;            # sendfile 사용 시 패킷 모아서 전송 (대역폭 효율)
    tcp_nodelay     on;            # keepalive 연결에서 소규모 패킷 즉시 전송 (Nagle 비활성화)
                                   # tcp_nopush + tcp_nodelay 동시 사용 가능 (Nginx가 조합 처리)

    # ── Keepalive ────────────────────────────────────────────────────
    keepalive_timeout  65;         # 클라이언트 keepalive 유지 시간 (초)
    keepalive_requests 1000;       # keepalive 연결당 최대 요청 수 (Nginx 1.19.10+)

    # ── 클라이언트 버퍼 ─────────────────────────────────────────────
    client_body_buffer_size  128k; # 요청 바디를 메모리에 버퍼링 (초과 시 tmp 파일에 기록)
    client_max_body_size     10m;  # 최대 요청 바디 크기 (파일 업로드 허용 크기)
    client_header_buffer_size  1k; # 헤더 버퍼 (대형 쿠키가 있으면 4k ~ 8k)
    large_client_header_buffers 4 8k;

    # ── 타임아웃 ────────────────────────────────────────────────────
    client_body_timeout    12;     # 요청 바디 수신 타임아웃
    client_header_timeout  12;     # 요청 헤더 수신 타임아웃
    send_timeout           10;     # 클라이언트로 응답 전송 타임아웃
}
```

#### Upstream Keepalive (리버스 프록시)

```nginx
# upstream으로의 연결 재사용 — 매 요청마다 TCP handshake 방지
upstream backend {
    server 127.0.0.1:8080;

    keepalive 64;          # 유휴 keepalive 연결 캐시 수 (worker 프로세스별)
                           # 너무 크면 upstream 서버의 연결 한계 도달 가능
}

server {
    location / {
        proxy_pass http://backend;

        # upstream keepalive 사용에 필수
        proxy_http_version      1.1;
        proxy_set_header Connection "";  # Connection: close 헤더 제거

        # ── Proxy 버퍼 ──────────────────────────────────────────────
        proxy_buffer_size         16k;  # 응답 헤더 버퍼
        proxy_buffers             8 16k; # 응답 바디 버퍼 (수 × 크기)
        proxy_busy_buffers_size   32k;
        proxy_read_timeout        60;   # upstream 응답 대기 타임아웃
        proxy_connect_timeout     5;    # upstream 연결 타임아웃
        proxy_send_timeout        60;   # upstream 요청 전송 타임아웃
    }
}
```

---

### 2.4 클라우드/DevOps 연계

#### Ansible — OS + Nginx 일괄 튜닝

```yaml
# roles/nginx-tuning/tasks/main.yml
---
- name: 커널 파라미터 적용
  ansible.posix.sysctl:
    name: "{{ item.key }}"
    value: "{{ item.value }}"
    sysctl_file: /etc/sysctl.d/99-nginx.conf
    reload: yes
  loop:
    - { key: "net.core.somaxconn",           value: "65535" }
    - { key: "net.ipv4.tcp_max_syn_backlog",  value: "65535" }
    - { key: "fs.file-max",                   value: "2000000" }
    - { key: "net.ipv4.ip_local_port_range",  value: "1024 65535" }
    - { key: "net.ipv4.tcp_tw_reuse",         value: "1" }
    - { key: "net.ipv4.tcp_fin_timeout",      value: "15" }
    - { key: "net.core.netdev_max_backlog",   value: "16384" }

- name: ulimit 설정 (limits.d)
  community.general.pam_limits:
    domain: nginx
    limit_type: "{{ item.type }}"
    limit_item: nofile
    value: "65535"
  loop:
    - { type: soft }
    - { type: hard }

- name: nginx.conf worker 설정 배포
  ansible.builtin.template:
    src: nginx.conf.j2
    dest: /etc/nginx/nginx.conf
    owner: root
    group: root
    mode: '0644'
    validate: 'nginx -t -c %s'
  notify: reload nginx
```

#### systemd override — Nginx nofile 한계 상향

```bash
# nginx.service의 LimitNOFILE을 systemd 레벨에서 설정
systemctl edit nginx
```

```ini
# /etc/systemd/system/nginx.service.d/override.conf
[Service]
LimitNOFILE=65535   # worker_rlimit_nofile 값 이상으로 설정
```

```bash
systemctl daemon-reload
systemctl restart nginx

# 적용 확인
cat /proc/$(pgrep -f 'nginx: worker')/limits | grep 'open files'
```

---

## 3. 자주 하는 실수

| 잘못된 방법 | 올바른 방법 | 이유 |
|------------|------------|------|
| `somaxconn`만 올리고 nginx `listen backlog` 미설정 | `listen 80 backlog=65535;` 함께 설정 | nginx의 backlog 기본값(511)이 OS 큐보다 작으면 의미 없음 |
| `worker_connections 65535` 설정 후 `worker_rlimit_nofile` 미설정 | `worker_rlimit_nofile`을 `worker_connections`의 2배 이상 | 연결 1개당 소켓 FD 외에 로그, 설정 파일 FD도 사용하므로 여유 필요 |
| `tcp_nodelay on`만 설정 | `sendfile on; tcp_nopush on; tcp_nodelay on;` 모두 설정 | sendfile 없이 tcp_nopush는 무효, 세 옵션은 함께 작동 |
| upstream `keepalive` 없이 `proxy_pass` 사용 | `keepalive 64;` + `proxy_http_version 1.1;` + `Connection ""` 헤더 설정 | HTTP/1.0 기본값은 요청마다 TCP 연결 — upstream에 부하 집중 |
| `tcp_tw_reuse = 1` + `tcp_tw_recycle = 1` 조합 | `tcp_tw_reuse = 1`만 사용 | `tcp_tw_recycle`은 커널 4.12에서 제거됨, NAT 환경에서 패킷 드롭 유발 |
| `worker_processes 8` 고정 | `worker_processes auto;` | vCPU 수 변경(스케일업/스케일다운) 시 재설정 없이 자동 적응 |
| `/etc/security/limits.conf` 수정 후 nginx 재시작 없이 확인 | `systemctl restart nginx` 후 `/proc/<PID>/limits` 직접 확인 | limits.conf는 새 세션/프로세스에만 적용, 재시작 필수 |

---

## 4. 트러블슈팅

### "accept() failed (24: Too many open files)"

```bash
# 증상: nginx error.log에 해당 메시지 반복
grep 'Too many open files' /var/log/nginx/error.log

# 원인 확인: worker 프로세스의 현재 FD 한계
cat /proc/$(pgrep -f 'nginx: worker' | head -1)/limits | grep 'open files'

# 해결 순서
# 1) systemd override로 LimitNOFILE 상향
systemctl edit nginx
# → LimitNOFILE=65535 추가

# 2) nginx.conf에 worker_rlimit_nofile 설정
#    worker_rlimit_nofile 65535;

# 3) 재시작 후 확인
systemctl restart nginx
cat /proc/$(pgrep -f 'nginx: worker' | head -1)/limits | grep 'open files'
```

### 502 Bad Gateway — upstream 연결 폭증

```bash
# upstream으로의 TIME_WAIT 연결 수 확인
ss -tan state time-wait | grep ':8080' | wc -l

# upstream keepalive 연결 수 확인 (ESTABLISHED)
ss -tan state established | grep ':8080' | wc -l

# 해결: upstream 블록에 keepalive 추가 + HTTP/1.1 설정 확인
nginx -T | grep -A5 'upstream'
```

### SYN drop — 연결 요청 자체가 거부되는 경우

```bash
# SYN 큐 오버플로 확인
netstat -s | grep -i 'listen'
# → "N SYNs to LISTEN sockets dropped" 증가 중이면 큐 오버플로

# 현재 accept 큐 사용량 확인 (Recv-Q가 0이 아니면 처리 지연)
ss -lnt | grep ':80\|:443'

# 해결
sysctl -w net.core.somaxconn=65535
sysctl -w net.ipv4.tcp_max_syn_backlog=65535
# + nginx listen backlog 설정
```

### "upstream timed out" — proxy_read_timeout 초과

```bash
# 증상: nginx error.log에 "upstream timed out (110: Connection timed out)"
# 원인 1: upstream 애플리케이션 처리 지연
# 원인 2: proxy_read_timeout이 너무 짧음

# upstream 응답 시간 분포 확인 (access_log에 $upstream_response_time 포함 시)
awk '{print $NF}' /var/log/nginx/access.log | sort -n | tail -20

# 해결: 타임아웃 조정 (근본 원인인 upstream 성능 개선이 우선)
# proxy_read_timeout 120;
```

---

## 5. TIP

**현재 Nginx 실효 설정 전체 출력**
```bash
nginx -T 2>/dev/null | grep -E 'worker_|keepalive|sendfile|tcp_|buffer'
```

**동시 연결 수 실시간 모니터링 (stub_status 활성화 필요)**
```nginx
# server 블록 내 추가
location /nginx_status {
    stub_status;
    allow 127.0.0.1;   # 로컬에서만 접근 허용
    deny all;
}
```
```bash
# Active connections / Reading / Writing / Waiting 확인
curl -s http://127.0.0.1/nginx_status
```

**최대 이론적 동시 처리 연결 수 계산**
```
최대 연결 = worker_processes × worker_connections
예) auto(4 vCPU) × 65535 = 262,140 연결

단, 리버스 프록시 시 upstream 연결도 FD를 사용:
실제 필요 FD = worker_connections × 2 (클라이언트 + upstream)
→ worker_rlimit_nofile = worker_connections × 2 이상 설정
```

**로그 포맷에 upstream 응답 시간 추가**
```nginx
log_format main '$remote_addr - $request [$status] '
                'rt=$request_time urt=$upstream_response_time '
                'uct=$upstream_connect_time';
```

**Nginx 설정 문법 검사 후 무중단 reload**
```bash
nginx -t && systemctl reload nginx   # 문법 오류 시 reload 차단
```
