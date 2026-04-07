## 1. 개요

cgroup(Control Group)은 프로세스 그룹의 CPU, 메모리, 디스크 I/O, 네트워크 등 **자원 사용량을 제한·측정·격리**하는 리눅스 커널 기능이다.
Docker 컨테이너가 "이 컨테이너는 CPU 2코어, 메모리 512MB만 쓸 수 있다"를 보장하는 것도, Kubernetes Pod의 `resources.limits`도 결국 cgroup으로 구현된다.
cgroup v1(레거시)과 cgroup v2(unified hierarchy)는 인터페이스 구조가 다르며, 현재 대부분의 최신 배포판(RHEL 9, Ubuntu 22.04+)은 v2를 기본으로 사용한다.

---

## 2. cgroup v1 vs cgroup v2

### 2.1 계층 구조 비교

```
cgroup v1 (레거시):                  cgroup v2 (unified):
여러 개의 독립 트리                   단일 통합 트리

/sys/fs/cgroup/                      /sys/fs/cgroup/
├── cpu/                             ├── cgroup.controllers   ← 사용 가능한 controller 목록
│   └── myapp/                       ├── system.slice/
│       └── cpu.shares               │   └── myapp.service/
├── memory/                          │       ├── memory.max
│   └── myapp/                       │       ├── cpu.max
│       └── memory.limit_in_bytes    │       └── io.max
├── blkio/                           └── user.slice/
│   └── myapp/
│       └── blkio.weight
└── pids/
    └── myapp/
        └── pids.max

문제점: 같은 프로세스가 여러 트리에       장점: 하나의 트리에서 모든 자원을
       각각 등록 → 일관성 유지 어려움        통합 관리, 위임(delegation) 안전
```

### 2.2 핵심 차이 요약

| 항목 | cgroup v1 | cgroup v2 |
|---|---|---|
| **계층 구조** | subsystem별 독립 트리 | 단일 unified 트리 |
| **Thread 모드** | 없음 | threaded 모드 지원 |
| **위임(delegation)** | 위험 (각 트리별로 권한 관리) | 안전 (단일 트리, 명시적 위임) |
| **PSI 지원** | 없음 | Pressure Stall Information 제공 |
| **OOM 제어** | memory.oom_control | memory.oom.group (그룹 단위) |
| **기본 배포판** | RHEL 7/8, Ubuntu 20.04 이하 | RHEL 9, Ubuntu 22.04+, AL2023 |

### 2.3 현재 버전 확인

```bash
# 시스템이 v1/v2 중 어느 것을 사용하는지 확인
stat -fc %T /sys/fs/cgroup/
# tmpfs    → cgroup v1
# cgroup2fs → cgroup v2

# 마운트 상태 확인
mount | grep cgroup
# cgroup2 on /sys/fs/cgroup type cgroup2 (rw,nosuid,nodev,noexec)  ← v2
# cgroup on /sys/fs/cgroup/cpu type cgroup (rw,...,cpu)             ← v1
```

---

## 3. 주요 Controller (자원 유형)

### 3.1 cpu controller

```bash
# [v2] CPU 제한: cpu.max = "quota period"
# 500000 1000000 = 50% CPU (0.5 코어)
echo "500000 1000000" > /sys/fs/cgroup/myapp/cpu.max

# [v2] CPU 가중치 (상대적 비율, 기본값 100)
echo 200 > /sys/fs/cgroup/myapp/cpu.weight  # 다른 그룹보다 2배 우선

# [v1] cpu.shares (상대적 비율, 기본값 1024)
echo 512 > /sys/fs/cgroup/cpu/myapp/cpu.shares
```

```
cpu.max 이해:
  "500000 1000000" = 1000ms 주기마다 최대 500ms만 CPU 사용
  = 전체 CPU의 50% = 1코어 환경에서 0.5코어
  "max 1000000"    = 제한 없음 (기본값)

Docker에서: --cpus 0.5 → cpu.max = "50000 100000"
K8s에서:   resources.limits.cpu: 500m → cpu.max = "50000 100000"
```

### 3.2 memory controller

```bash
# [v2] 메모리 상한 (hard limit) - 초과 시 OOM kill
echo "512M" > /sys/fs/cgroup/myapp/memory.max

# [v2] 소프트 상한 - 시스템 압박 시 이 수준으로 회수 시도
echo "256M" > /sys/fs/cgroup/myapp/memory.high

# [v2] 현재 메모리 사용량 확인
cat /sys/fs/cgroup/myapp/memory.current

# [v2] OOM 발생 통계
cat /sys/fs/cgroup/myapp/memory.events
# oom 3           ← OOM 발생 횟수
# oom_kill 3      ← 실제 프로세스 kill 횟수

# [v1] 동등한 설정
echo $((512 * 1024 * 1024)) > /sys/fs/cgroup/memory/myapp/memory.limit_in_bytes
```

```
memory.max vs memory.high:

  memory.high (소프트)          memory.max (하드)
  ────────────────               ────────────────
  초과 → 스로틀링 + 회수 시도     초과 → 즉시 OOM kill
  잠시 초과 허용 가능             절대 초과 불가

  실무 패턴: high = max의 80%로 설정해
             OOM 직전에 미리 압박을 감지
```

### 3.3 io controller (v2) / blkio (v1)

```bash
# 장치 번호 확인 (major:minor)
ls -l /dev/nvme0n1
# brw-rw---- 1 root disk 259, 0 ...
# → major=259, minor=0

# [v2] IOPS 제한
echo "259:0 riops=1000 wiops=500" > /sys/fs/cgroup/myapp/io.max

# [v2] 대역폭 제한 (bytes/s)
echo "259:0 rbps=52428800 wbps=26214400" > /sys/fs/cgroup/myapp/io.max
# rbps=50MB/s, wbps=25MB/s

# [v2] I/O 통계 확인
cat /sys/fs/cgroup/myapp/io.stat
# 259:0 rbytes=1234567 wbytes=891234 rios=100 wios=50 ...

# [v1] blkio 가중치 (상대적 우선순위)
echo 500 > /sys/fs/cgroup/blkio/myapp/blkio.weight
```

### 3.4 pids controller

```bash
# [v2] 최대 프로세스/스레드 수 제한 (fork bomb 방지)
echo 100 > /sys/fs/cgroup/myapp/pids.max

# [v2] 현재 pid 수 확인
cat /sys/fs/cgroup/myapp/pids.current

# Docker에서: --pids-limit 100
# K8s에서: 기본 적용 (kubelet --pod-max-pids)
```

---

## 4. systemd와 cgroup

현대 Linux에서는 cgroup을 직접 조작하지 않고 **systemd를 통해 관리**하는 것이 표준이다.
systemd가 cgroup 트리를 소유하며, 직접 조작 시 systemd와 충돌할 수 있다.

### 4.1 cgroup 트리 확인

```bash
# systemd가 관리하는 cgroup 계층 전체 보기
systemd-cgls
# Control group /:
# -.slice
# ├─system.slice
# │ ├─nginx.service
# │ │ ├─1234 nginx: master process
# │ │ └─1235 nginx: worker process
# │ └─sshd.service
# └─user.slice

# 자원 사용량 실시간 확인 (top과 유사)
systemd-cgtop
```

### 4.2 서비스 자원 제한 설정

```bash
# 방법 1: systemctl set-property (즉시 적용 + 영구 저장)
systemctl set-property nginx.service CPUQuota=50%
systemctl set-property nginx.service MemoryMax=512M
systemctl set-property nginx.service MemoryHigh=400M
systemctl set-property nginx.service TasksMax=100

# 방법 2: /etc/systemd/system/nginx.service.d/limits.conf
mkdir -p /etc/systemd/system/nginx.service.d/
cat > /etc/systemd/system/nginx.service.d/limits.conf << 'EOF'
[Service]
CPUQuota=50%
MemoryMax=512M
MemoryHigh=400M
TasksMax=100
IOReadBandwidthMax=/dev/nvme0n1 50M
IOWriteBandwidthMax=/dev/nvme0n1 25M
EOF

systemctl daemon-reload
systemctl restart nginx
```

### 4.3 서비스별 cgroup 경로 확인

```bash
# 서비스의 cgroup 경로 확인
systemctl show nginx.service -p ControlGroup
# ControlGroup=/system.slice/nginx.service

# cgroup 파일 직접 확인
cat /sys/fs/cgroup/system.slice/nginx.service/memory.current
cat /sys/fs/cgroup/system.slice/nginx.service/cpu.stat
```

---

## 5. Docker/Kubernetes와 cgroup

### 5.1 Docker 컨테이너 자원 제한

```bash
# CPU: 0.5코어 제한 + 가중치 512
docker run --cpus 0.5 --cpu-shares 512 nginx

# 메모리: hard 512MB, soft 256MB
docker run --memory 512m --memory-reservation 256m nginx

# I/O: 50MB/s 읽기 제한
docker run --device-read-bps /dev/nvme0n1:50mb nginx

# pid 제한
docker run --pids-limit 100 nginx

# 컨테이너의 cgroup 경로 확인 (v2)
CONTAINER_ID=$(docker inspect --format '{{.Id}}' nginx_container)
ls /sys/fs/cgroup/system.slice/docker-${CONTAINER_ID}.scope/
```

### 5.2 Kubernetes Pod resources

```yaml
# Pod 스펙에서의 자원 제한 → cgroup 매핑
apiVersion: v1
kind: Pod
spec:
  containers:
  - name: app
    resources:
      requests:            # 스케줄링 기준 (cpu.weight에 영향)
        cpu: "250m"        # 0.25 코어
        memory: "128Mi"
      limits:              # cgroup 상한값
        cpu: "500m"        # cpu.max = "50000 100000"
        memory: "256Mi"    # memory.max = 268435456

# QoS 클래스와 cgroup 우선순위:
# Guaranteed (req=limit)  → 최고 우선순위
# Burstable   (req<limit) → 중간
# BestEffort  (req 없음)  → 최하위, 자원 부족 시 먼저 퇴출
```

### 5.3 PSI (Pressure Stall Information) - v2 전용

```bash
# 시스템 자원 압박 상태 확인 (cgroup v2 전용)
cat /sys/fs/cgroup/myapp/cpu.pressure
# some avg10=0.00 avg60=0.00 avg300=0.00 total=0
# full avg10=0.00 avg60=0.00 avg300=0.00 total=0

cat /sys/fs/cgroup/myapp/memory.pressure
# some avg10=5.32 avg60=2.11 avg300=0.87 total=123456

# some: 일부 프로세스가 자원 대기 중인 시간 비율 (%)
# full: 모든 프로세스가 자원 대기 중인 시간 비율 (%)
# avg10/60/300: 최근 10초/60초/300초 평균
```

```
PSI 활용 패턴:
  avg60 > 30% → 자원 압박 심각, 스케일 아웃 고려
  full avg10 > 0 → 완전한 자원 고갈 발생 중, 즉시 조치
  K8s kubelet은 PSI를 읽어 노드 상태 판단에 활용
```

---

## 6. Terraform/Ansible 예제

### 6.1 Ansible로 systemd 서비스 자원 제한

```yaml
# roles/app-limits/tasks/main.yml
- name: cgroup 자원 제한 drop-in 파일 생성
  ansible.builtin.copy:
    dest: /etc/systemd/system/myapp.service.d/cgroup-limits.conf
    content: |
      [Service]
      CPUQuota=80%
      MemoryMax=1G
      MemoryHigh=800M
      TasksMax=200
    owner: root
    group: root
    mode: '0644'
  notify: reload systemd

- name: systemd daemon reload 및 서비스 재시작
  ansible.builtin.systemd:
    name: myapp
    state: restarted
    daemon_reload: true

handlers:
  - name: reload systemd
    ansible.builtin.systemd:
      daemon_reload: true
```

### 6.2 Terraform ECS Task Definition (컨테이너 자원 제한)

```hcl
resource "aws_ecs_task_definition" "app" {
  family                   = "myapp"
  cpu                      = 512   # 0.5 vCPU (cgroup cpu.max)
  memory                   = 1024  # 1GB (cgroup memory.max)
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"

  container_definitions = jsonencode([{
    name   = "app"
    image  = "myapp:latest"
    cpu    = 256      # 컨테이너 수준 cgroup 제한
    memory = 512      # hard limit
    memoryReservation = 256  # soft limit (memory.high 역할)
  }])
}
```

---

## 7. 자주 하는 실수

| 실수 | 올바른 방법 |
|---|---|
| cgroup 파일을 직접 수정 (`echo ... > /sys/fs/cgroup/...`) | `systemctl set-property`로 설정 → systemd가 관리하는 값이 덮어씌워짐 |
| v1과 v2 경로를 혼용 (`memory.limit_in_bytes`를 v2에서 사용) | `stat -fc %T /sys/fs/cgroup/`으로 버전 확인 후 해당 파일명 사용 |
| `memory.max`만 설정하고 `memory.high` 생략 | `high`를 `max`의 80%로 설정해 OOM 전에 스로틀링 유도 |
| Docker `--memory` 없이 운영 (`memory.max = max`) | 컨테이너 하나가 호스트 메모리를 전부 소진할 수 있음, 항상 제한 설정 |
| K8s `requests` 없이 `limits`만 설정 | BestEffort QoS가 되어 자원 부족 시 먼저 퇴출됨 |
| cgroup v2인데 v1 용 모니터링 도구 사용 | `systemd-cgtop`, PSI, `cgroup.stat` 등 v2 인터페이스 사용 |
| `pids.max` 미설정 → fork bomb 취약 | 서비스마다 `TasksMax` 또는 `--pids-limit` 반드시 설정 |
