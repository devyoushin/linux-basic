# Linux Swap 운영 가이드

## 1. 개요

Swap은 RAM이 부족할 때 일부 메모리 페이지를 디스크의 swap 영역으로 내보내 RAM을 확보하는 기능이다.
목적은 시스템을 빠르게 만들기 위한 것이 아니라, OOM Killer 발동을 피하거나 늦추는 **완충재** 역할이다.

핵심은 swap을 “얼마나 많이 쓰고 있느냐”보다, 현재 swap 사용이 정상적인 완충인지 아니면 성능을 붕괴시키는 thrash인지 구분하는 것이다.

```text
정상 완충:
  드물게 접근되는 cold anonymous page가 swap으로 내려감
  swap 사용량은 있어도 swap-in/swap-out이 거의 없음
  서비스 지연 영향이 제한적

Swap thrash:
  RAM 부족으로 페이지를 swap-out 했다가 곧바로 다시 swap-in
  디스크 I/O 포화, D state 증가, load average 상승
  OOM은 늦춰지지만 시스템 전체 응답성이 크게 악화
```

---

## 2. 설명

### 2.1 Swap이 내보내는 대상

Linux 메모리는 크게 파일 기반 페이지와 익명 페이지로 나눌 수 있다.

| 구분 | 예시 | 회수 방식 |
|---|---|---|
| 파일 기반 페이지 | 실행 파일, 라이브러리, 파일 page cache | clean page는 버리고 필요 시 파일에서 다시 읽음 |
| 익명 페이지 | heap, stack, malloc 메모리 | 원본 파일이 없으므로 swap에 기록해야 회수 가능 |

Swap은 주로 **anonymous page**를 디스크로 내보내 RAM을 확보한다. 따라서 swap은 페이지 캐시를 비우는 기능이 아니라, 프로세스의 익명 메모리를 디스크로 밀어내는 기능에 가깝다.

```bash
# 메모리와 swap 전체 상태 확인
free -h

# anonymous page와 swap 관련 항목 확인
grep -E "MemAvailable|AnonPages|SwapTotal|SwapFree|SwapCached" /proc/meminfo

# 프로세스별 RSS/VSZ 확인
ps aux --sort=-%mem | head -10
```

### 2.2 Swap 상태 확인 명령어

```bash
# 활성화된 swap 장치와 우선순위 확인
swapon --show

# swap 사용량만 빠르게 확인
free -h | grep -E "Mem|Swap"

# swap 입출력 흐름 확인
vmstat 1
# si: swap in, 디스크 swap에서 RAM으로 읽은 양
# so: swap out, RAM에서 디스크 swap으로 쓴 양
# si/so가 지속적으로 크면 단순 사용량이 아니라 thrash 가능성이 높음

# sysstat으로 swap in/out 확인
sar -W 1

# 디스크 포화 여부 확인
iostat -xz 1
# await 증가, %util 100% 근접이면 swap I/O가 스토리지를 막고 있는지 확인
```

프로세스별 swap 사용량은 `/proc/<PID>/status`의 `VmSwap`에서 확인한다.

```bash
# 프로세스별 swap 사용량 상위 10개 확인
for status_file in /proc/[0-9]*/status; do
    awk '
        /^Name:/ {name=$2}
        /^Pid:/ {pid=$2}
        /^VmSwap:/ {swap=$2}
        END {
            if (swap > 0) {
                printf "%10d kB  pid=%s  name=%s\n", swap, pid, name
            }
        }
    ' "$status_file" 2>/dev/null
done | sort -nr | head -10
```

### 2.3 완충인지 thrash인지 판단

Swap 사용량 자체는 장애 판정 기준이 아니다. 오래전에 내려간 cold page가 swap에 남아 있을 수 있기 때문이다.
운영에서는 “swap 공간을 얼마나 썼는가”보다 “지금 swap I/O가 계속 발생하는가”를 먼저 본다.

| 관찰 지표 | 완충 상태 | Thrash 상태 |
|---|---|---|
| `free -h` | swap used가 있어도 `MemAvailable`이 안정적 | `MemAvailable`이 낮고 swap free도 감소 |
| `vmstat 1` | `si`, `so`가 대부분 0 | `si`, `so`가 지속적으로 큼 |
| `sar -W 1` | `pswpin/s`, `pswpout/s`가 낮음 | `pswpin/s`, `pswpout/s`가 계속 높음 |
| `iostat -xz 1` | 디스크 await와 `%util` 안정적 | await 급등, `%util` 포화 |
| 프로세스 상태 | runnable/idle 중심 | D state 증가, load average 상승 |

```bash
# 1. 메모리 여유 확인
free -h

# 2. 실시간 swap in/out 확인
vmstat 1

# 3. 디스크 포화 확인
iostat -xz 1

# 4. D state 프로세스 확인
ps -eo state,pid,ppid,comm,wchan:32 | awk '$1 ~ /D/ {print}'

# 5. 커널 OOM 또는 memory pressure 로그 확인
journalctl -k | grep -iE "oom|out of memory|memory allocation failure"
```

### 2.4 Swap을 쓰기 좋은 경우

Swap은 모든 서버에 무조건 켜거나 끄는 항목이 아니다. 워크로드 특성에 따라 효과가 다르다.

| 적합한 경우 | 이유 |
|---|---|
| 일시적 메모리 스파이크가 있는 일반 서버 | 짧은 피크에서 즉시 OOM으로 죽는 것을 완화 |
| 접근 빈도가 낮은 cold page가 많은 워크로드 | 안 쓰는 익명 페이지를 디스크로 내려도 지연 영향이 작음 |
| 개인 개발 서버, 소형 VM | 메모리 여유가 작아 갑작스러운 OOM 방지에 도움 |
| 배치/비동기 작업 서버 | 순간 지연보다 작업 완료가 더 중요할 수 있음 |

반대로 레이턴시가 중요한 서비스에서는 swap이 장애를 더 오래 끌고 갈 수 있다.

| 주의해야 하는 경우 | 이유 |
|---|---|
| DB 서버 | buffer pool, shared memory가 swap되면 tail latency가 크게 악화 |
| Redis, Memcached | 메모리 기반 서비스가 swap을 타면 설계 목적과 반대 |
| 실시간/저지연 서비스 | OOM보다 swap thrash로 인한 지연 폭발이 더 치명적 |
| Kubernetes worker node | 노드가 죽지 않고 느리게 망가져 장애 전파 가능 |

### 2.5 Swappiness 조정

`vm.swappiness`는 커널이 anonymous page를 swap으로 내보내는 적극성을 조정한다. 값은 0~100이며, 값이 높을수록 swap을 더 적극적으로 사용한다.

```bash
# 현재 swappiness 확인
sysctl vm.swappiness

# 런타임에서 swappiness 낮추기
sysctl -w vm.swappiness=10

# 영구 설정 파일 생성
cat > /etc/sysctl.d/99-swap.conf << 'EOF'
vm.swappiness = 10
EOF

# 설정 반영
sysctl -p /etc/sysctl.d/99-swap.conf
```

| 값 | 의미 | 사용 예 |
|---|---|---|
| `0` | 가능하면 swap 회피, 메모리가 극히 부족할 때만 사용 | 저지연 서비스, DB |
| `10` | swap 사용 최소화 | 서버 운영에서 자주 쓰는 보수적 값 |
| `30` | 기본보다 낮은 균형값 | 일반 애플리케이션 서버 |
| `60` | 많은 배포판의 기본값 | 범용 서버 |
| `100` | swap을 매우 적극적으로 사용 | 특수한 메모리 overcommit 환경 |

`swappiness=0`은 swap 비활성화가 아니다. swap을 완전히 끄려면 `swapoff`가 필요하다.

### 2.6 Swap 파일 생성과 제거

Swap 파티션이 없어도 파일 기반 swap을 만들 수 있다. 클라우드 VM에서는 별도 파티션보다 swap 파일이 운영상 단순한 경우가 많다.

```bash
# 2GiB swap 파일 생성
fallocate -l 2G /swapfile

# swap 파일 권한 제한
chmod 600 /swapfile

# swap 영역으로 초기화
mkswap /swapfile

# swap 활성화
swapon /swapfile

# 활성화 상태 확인
swapon --show
free -h
```

영구 적용은 `/etc/fstab`에 추가한다.

```bash
# 부팅 시 swap 파일 자동 활성화
echo "/swapfile none swap sw 0 0" >> /etc/fstab

# fstab 문법 확인
findmnt --verify
```

> **주의**
> `swapoff`는 swap에 내려간 페이지를 다시 RAM으로 올린다. RAM 여유가 부족한 상태에서 실행하면 즉시 OOM이 발생할 수 있다.

```bash
# 특정 swap 파일 비활성화
swapoff /swapfile

# fstab에서 /swapfile 항목을 제거한 뒤 파일 삭제
rm /swapfile
```

### 2.7 systemd와 cgroup에서 swap 제한

systemd 서비스 단위로 메모리와 swap 사용량을 제한할 수 있다. cgroup v2 환경에서는 `MemoryMax`, `MemoryHigh`, `MemorySwapMax`를 함께 보는 것이 중요하다.

```ini
# /etc/systemd/system/myapp.service
[Service]
MemoryHigh=3G
MemoryMax=4G
MemorySwapMax=0
OOMPolicy=stop
```

```bash
# systemd 설정 반영
systemctl daemon-reload

# 서비스 재시작
systemctl restart myapp.service

# cgroup 메모리 상태 확인
systemctl show myapp.service -p MemoryCurrent -p MemoryPeak -p MemorySwapCurrent
```

`MemoryHigh`는 소프트 제한이다. 초과 시 해당 cgroup에 reclaim 압박을 주고 지연이 생길 수 있다.
`MemoryMax`는 하드 제한이다. 초과 시 cgroup 내부 OOM이 발생할 수 있다.
`MemorySwapMax=0`은 해당 서비스의 swap 사용을 막는다.

### 2.8 Kubernetes에서 swap을 조심해야 하는 이유

Kubernetes 운영에서는 swap을 끄는 구성이 일반적으로 더 안전하다. 이유는 swap thrash가 노드를 즉시 죽이지 않고 느리게 망가뜨리기 때문이다.

```text
Pod 메모리 사용 증가
  │
  ├── swap 없음:
  │     limit 초과 → cgroup OOM → Pod 종료 → 다른 노드로 재스케줄
  │
  └── swap thrash:
        노드 I/O 포화 → kubelet 지연 → CNI/DNS/로그 수집 지연
        여러 Pod가 동시에 느려짐 → 장애 전파 가능
```

운영 안정성 관점에서는 Pod의 `requests`, `limits`, QoS, eviction 정책으로 fail fast하게 격리하는 패턴이 더 예측 가능하다.

```bash
# 노드 swap 활성화 여부 확인
swapon --show

# kubelet의 swap 관련 설정 확인
ps aux | grep kubelet | grep -i swap

# Pod 메모리 limit 확인
kubectl describe pod <POD_NAME> | grep -A5 -i "limits"

# 노드 메모리 압박 이벤트 확인
kubectl describe node <NODE_NAME> | grep -A10 -i "memorypressure"
```

```yaml
# Pod 메모리 request/limit 예시
apiVersion: v1
kind: Pod
metadata:
  name: app
spec:
  containers:
  - name: app
    image: nginx
    resources:
      requests:
        memory: "512Mi"
      limits:
        memory: "1Gi"
```

### 2.9 장애 대응 흐름

Swap thrash가 확인되면 “더 오래 버티게” 하는 것보다 원인을 격리하는 것이 우선이다.

```bash
# 1. swap I/O가 지속되는지 확인
vmstat 1

# 2. 디스크가 swap I/O로 포화됐는지 확인
iostat -xz 1

# 3. swap을 많이 쓰는 프로세스 확인
for status_file in /proc/[0-9]*/status; do
    awk '
        /^Name:/ {name=$2}
        /^Pid:/ {pid=$2}
        /^VmSwap:/ {swap=$2}
        END {
            if (swap > 0) {
                printf "%10d kB  pid=%s  name=%s\n", swap, pid, name
            }
        }
    ' "$status_file" 2>/dev/null
done | sort -nr | head -10

# 4. 메모리 상위 프로세스 확인
ps aux --sort=-%mem | head -10

# 5. OOM 로그 확인
journalctl -k | grep -iE "oom|killed process|out of memory"
```

즉각 조치 우선순위는 다음과 같다.

| 우선순위 | 조치 | 목적 |
|---|---|---|
| 1 | 원인 프로세스 격리 또는 재시작 | thrash를 만드는 메모리 압박 제거 |
| 2 | 트래픽/동시성 제한 | 메모리 증가 속도 완화 |
| 3 | 스케일아웃 | 노드당 메모리 압박 감소 |
| 4 | 메모리 limit/heap 크기 조정 | 재발 방지 |
| 5 | RAM 증설 또는 인스턴스 타입 변경 | 구조적 용량 부족 해소 |

---

## 3. 자주 하는 실수

| 잘못된 방법 | 올바른 방법 | 이유 |
|---|---|---|
| swap used가 0이 아니면 바로 장애로 판단 | `vmstat 1`의 `si/so`, `sar -W 1`, `iostat -xz 1`을 함께 확인 | cold page가 swap에 남아 있는 것은 정상일 수 있음 |
| swap을 크게 잡으면 OOM 문제가 해결된다고 판단 | 원인 프로세스, 메모리 limit, 동시성, 캐시 정책을 조정 | swap은 OOM을 늦출 뿐 메모리 부족의 원인을 제거하지 않음 |
| DB/Redis 서버에서 기본 swappiness 유지 | `vm.swappiness=0~10` 또는 서비스 단위 swap 제한 적용 | 메모리 기반 서비스가 swap을 타면 tail latency가 급격히 악화 |
| `swapoff -a`를 메모리 부족 상황에서 실행 | `MemAvailable`과 swap 사용 프로세스를 확인한 뒤 점진 조치 | swap 페이지를 RAM으로 되돌리며 즉시 OOM을 유발할 수 있음 |
| Kubernetes 노드에서 swap으로 버티게 함 | request/limit, QoS, eviction, 재스케줄링으로 격리 | 노드 전체가 느려져 kubelet/CNI까지 장애가 전파될 수 있음 |
| swappiness를 0으로 두면 swap이 꺼진다고 생각 | 완전 비활성화는 `swapoff`, 영구 비활성화는 `/etc/fstab` 제거 | `swappiness=0`은 swap 회피 정책이지 swap off가 아님 |

---

## 4. 트러블슈팅

### 4.1 `free -h`에서 swap used가 높다

| 확인 | 명령어 | 판단 |
|---|---|---|
| 현재 메모리 여유 | `free -h` | `MemAvailable`이 충분하면 즉시 장애는 아닐 수 있음 |
| 실시간 swap I/O | `vmstat 1` | `si/so`가 지속적으로 크면 thrash |
| 프로세스별 swap | `/proc/<PID>/status` | 특정 프로세스가 swap을 많이 쓰는지 확인 |

```bash
# swap 사용량과 실시간 swap I/O를 함께 확인
free -h
vmstat 1
```

### 4.2 load average가 높고 프로세스가 느리다

```bash
# D state 프로세스 확인
ps -eo state,pid,ppid,comm,wchan:32 | awk '$1 ~ /D/ {print}'

# 디스크 await와 util 확인
iostat -xz 1

# swap in/out 확인
sar -W 1
```

`D state`가 늘고 `iostat`에서 await가 튀며 `sar -W`의 `pswpin/s`, `pswpout/s`가 지속적으로 높으면 swap thrash 가능성이 높다.

### 4.3 OOM은 안 나는데 서버 전체가 멈춘 것처럼 느리다

OOM이 안 났다는 것은 안정적이라는 뜻이 아니다. swap thrash는 OOM을 늦추는 대신 노드 전체 지연을 폭발시킨다.

```bash
# PSI로 메모리와 I/O stall 확인
cat /proc/pressure/memory
cat /proc/pressure/io

# 커널 로그에서 OOM 직전 신호 확인
journalctl -k | grep -iE "oom|page allocation|memory allocation"
```

이 경우 swap을 늘리는 것보다 원인 워크로드 격리, 동시성 제한, 재시작, 스케일아웃이 우선이다.

---

## 5. TIP

- Swap은 성능 기능이 아니라 장애 완충 기능이다.
- swap used보다 `si/so`의 지속 발생 여부가 더 중요하다.
- DB, Redis, 저지연 서비스는 swap을 최소화하거나 서비스 단위로 제한한다.
- Kubernetes 노드는 swap보다 cgroup OOM과 eviction을 통한 fail fast가 운영상 더 예측 가능하다.
- swap thrash가 시작되면 swap 크기 증설보다 원인 프로세스 격리와 용량 조정이 먼저다.
