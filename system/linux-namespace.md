# Linux Namespace - 컨테이너 격리 원리

## 1. 개요

Linux namespace는 프로세스가 볼 수 있는 **시스템 자원의 범위를 분리**하는 커널 기능이다.
같은 호스트에서 실행되는 프로세스라도 서로 다른 namespace에 속하면 PID, 네트워크, 파일시스템
등을 독립적으로 소유한 것처럼 보이게 한다.
Docker, containerd, podman 등 모든 컨테이너 런타임은 namespace를 조합해 컨테이너 격리를
구현하며, K8s Pod의 동작 원리도 namespace 공유 정책으로 설명된다.

---

## 2. 설명

### 2-1. namespace 6종 개요

```
┌────────────────────────────────────────────────────────────────┐
│                         Linux Host                             │
│                                                                │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                   Host Namespaces                        │  │
│  │  PID ns │ NET ns │ MNT ns │ UTS ns │ IPC ns │ USER ns   │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                │
│  ┌────────────────────┐    ┌────────────────────┐             │
│  │   Container A      │    │   Container B      │             │
│  │  ┌──────────────┐  │    │  ┌──────────────┐  │             │
│  │  │ PID ns (own) │  │    │  │ PID ns (own) │  │             │
│  │  │ NET ns (own) │  │    │  │ NET ns (own) │  │             │
│  │  │ MNT ns (own) │  │    │  │ MNT ns (own) │  │             │
│  │  │ UTS ns (own) │  │    │  │ UTS ns (own) │  │             │
│  │  │ IPC ns (own) │  │    │  │ IPC ns (own) │  │             │
│  │  └──────────────┘  │    │  └──────────────┘  │             │
│  └────────────────────┘    └────────────────────┘             │
└────────────────────────────────────────────────────────────────┘
```

| namespace | 격리 대상 | 분리 효과 | 추가된 커널 버전 |
|---|---|---|---|
| PID | 프로세스 ID | 컨테이너 내 PID 1번 프로세스 가능 | 3.8 |
| NET | 네트워크 인터페이스, 라우팅, iptables | 독립 IP/포트/라우팅 테이블 | 2.6.24 |
| MNT (Mount) | 파일시스템 마운트 포인트 | 독립 파일시스템 뷰 | 3.8 |
| UTS | hostname, domainname | 컨테이너별 독립 호스트명 | 3.8 |
| IPC | System V IPC, POSIX 메시지 큐 | 공유 메모리 격리 | 3.8 |
| USER | UID/GID 매핑 | 컨테이너 내 root → 호스트 일반 사용자 | 3.12 |

### 2-2. PID namespace

```
호스트 PID 네임스페이스:
  PID 1   (systemd/init)
  PID 2   (kthread)
  ...
  PID 1234 (컨테이너 런타임)
  PID 1235 (컨테이너 내 프로세스 A → 호스트에서는 1235)

컨테이너 내부 PID 네임스페이스:
  PID 1   (nginx → 호스트 PID 1235에 매핑)
  PID 2   (nginx worker → 호스트 PID 1236에 매핑)
```

```bash
# 현재 프로세스의 PID namespace 확인
ls -la /proc/self/ns/pid
# lrwxrwxrwx 1 root root 0 /proc/self/ns/pid -> 'pid:[4026531836]'

# 새 PID namespace에서 bash 실행 (root 필요)
unshare --pid --fork --mount-proc bash
echo $$          # 출력: 1  ← 새 namespace에서 자신이 PID 1
ps aux           # 자신과 자식 프로세스만 보임

# 컨테이너 내 PID와 호스트 PID 매핑 확인
# 컨테이너 내에서: echo $$  → 1
# 호스트에서: docker inspect --format '{{.State.Pid}}' my-container  → 12345
cat /proc/12345/status | grep NSpid
# NSpid:  12345  1   ← 호스트 PID 12345, 컨테이너 내 PID 1
```

### 2-3. NET namespace

```
┌─────────────────────────────────────────────────────────┐
│                      Host Network NS                    │
│                                                         │
│  eth0 (192.168.1.10)  lo (127.0.0.1)                   │
│                                                         │
│    veth0 ────────────── veth1 (컨테이너 A의 eth0)       │
│    veth2 ────────────── veth3 (컨테이너 B의 eth0)       │
│         └── docker0 bridge (172.17.0.1)                 │
└─────────────────────────────────────────────────────────┘

컨테이너 A NET NS:
  eth0 (172.17.0.2)  lo (127.0.0.1)
  라우팅 테이블: 독립
  iptables: 독립

컨테이너 B NET NS:
  eth0 (172.17.0.3)  lo (127.0.0.1)
```

```bash
# 새 NET namespace 생성
ip netns add myns

# namespace 내에서 명령 실행
ip netns exec myns ip addr show
# 출력: lo만 존재, UP 상태 아님

# veth pair 생성 (호스트↔namespace 연결)
ip link add veth0 type veth peer name veth1
ip link set veth1 netns myns

# namespace 내 인터페이스 설정
ip netns exec myns ip addr add 192.168.100.1/24 dev veth1
ip netns exec myns ip link set veth1 up
ip netns exec myns ip link set lo up

# 현재 프로세스의 NET namespace
ls -la /proc/self/ns/net

# 컨테이너의 NET namespace 진입
CONTAINER_PID=$(docker inspect --format '{{.State.Pid}}' my-container)
nsenter -t $CONTAINER_PID --net ip addr show
# 컨테이너의 네트워크 인터페이스를 호스트에서 확인
```

### 2-4. MNT namespace

```bash
# 새 MNT namespace에서 파일시스템 변경이 호스트에 영향 안 줌
unshare --mount bash

# 새 namespace 내에서 tmpfs 마운트
mount -t tmpfs tmpfs /mnt/test
ls /mnt/test    # 새 파일시스템

# 호스트에서는 /mnt/test가 변경되지 않음 (다른 터미널에서 확인)
# ls /mnt/test  → 비어있음

# Docker의 MNT namespace: 컨테이너별 독립 rootfs
# overlay 파일시스템으로 이미지 레이어 + 쓰기 레이어 조합

# 컨테이너의 MNT namespace에서 파일시스템 확인
CONTAINER_PID=$(docker inspect --format '{{.State.Pid}}' my-container)
nsenter -t $CONTAINER_PID --mount ls /
# 컨테이너의 / 디렉토리 내용 (Ubuntu 이미지라면 Ubuntu 파일 구조)
```

### 2-5. UTS namespace

```bash
# UTS namespace: hostname 격리
unshare --uts bash
hostname my-container-hostname
hostname   # 출력: my-container-hostname

# 다른 터미널(호스트)에서
hostname   # 출력: original-hostname (변경 안 됨)

# Docker에서 hostname 설정
docker run --hostname my-app ubuntu hostname
# 출력: my-app  ← 컨테이너 내부의 hostname

# K8s: Pod의 hostname은 Pod 이름으로 자동 설정
# hostname 명령 실행 시 Pod 이름 반환
```

### 2-6. IPC namespace

```bash
# IPC namespace: 공유 메모리, 세마포어 격리
# 컨테이너 간 공유 메모리 접근 차단

# 새 IPC namespace에서 공유 메모리 생성
unshare --ipc bash
ipcmk -M 1024   # 1KB 공유 메모리 세그먼트 생성
ipcs -m         # 현재 namespace에서만 보임

# 호스트에서는 보이지 않음
ipcs -m   # 해당 세그먼트 없음

# Docker: 기본적으로 각 컨테이너가 독립 IPC namespace
# 같은 IPC namespace 공유 (성능 최적화 목적):
docker run --ipc=host myapp          # 호스트 IPC 공유 (비권장)
docker run --ipc=container:other-container myapp  # 다른 컨테이너와 공유
```

### 2-7. USER namespace

```bash
# USER namespace: UID/GID 매핑
# 컨테이너 내 root(UID 0) → 호스트의 일반 사용자(UID 100000)

# 새 USER namespace 생성 (root 불필요)
unshare --user bash
id    # 출력: uid=65534(nobody) gid=65534(nogroup) ← 매핑 전

# UID 매핑 설정 (0→1000: 컨테이너 UID 0 = 호스트 UID 1000)
# /proc/PID/uid_map: 컨테이너UID 호스트UID 범위
echo "0 1000 1" > /proc/$$/uid_map
id    # 출력: uid=0(root) ← 컨테이너 내에서는 root로 보임

# rootless Docker: USER namespace로 비특권 컨테이너 실행
# 설치
dockerd-rootless-setuptool.sh install

# 확인
docker run --rm ubuntu id
# uid=0(root) gid=0(root)  ← 컨테이너 내에서는 root
# 호스트에서: 실제 UID는 일반 사용자
```

### 2-8. /proc/PID/ns/ 확인법

```bash
# 특정 프로세스가 속한 모든 namespace 확인
ls -la /proc/$(pgrep nginx)/ns/

# 출력 예시:
# lrwxrwxrwx ... ipc  -> ipc:[4026532456]
# lrwxrwxrwx ... mnt  -> mnt:[4026532457]
# lrwxrwxrwx ... net  -> net:[4026532459]
# lrwxrwxrwx ... pid  -> pid:[4026532460]
# lrwxrwxrwx ... uts  -> uts:[4026532461]
# lrwxrwxrwx ... user -> user:[4026531837]
# ↑ 대괄호 안의 inode 번호가 같으면 같은 namespace 공유

# 두 프로세스가 같은 NET namespace 공유 여부 확인
ls -la /proc/1234/ns/net /proc/5678/ns/net
# net -> net:[4026532459]  같은 번호면 공유

# 호스트와 컨테이너 비교
ls -la /proc/1/ns/net           # 호스트 init
ls -la /proc/$CONTAINER_PID/ns/net  # 컨테이너 프로세스
# inode 번호 다름 → 다른 NET namespace
```

### 2-9. nsenter - namespace 진입

```bash
# 실행 중인 프로세스의 namespace에 진입
nsenter --target $PID --namespace-types

# 컨테이너의 모든 namespace 진입 (컨테이너 내부처럼 동작)
CONTAINER_PID=$(docker inspect --format '{{.State.Pid}}' my-container)
nsenter -t $CONTAINER_PID --all bash

# 특정 namespace만 선택하여 진입
nsenter -t $CONTAINER_PID --net --pid bash
# 컨테이너의 네트워크와 PID namespace에서 실행 (파일시스템은 호스트)

# 네트워크 namespace만 진입 (네트워크 디버깅)
nsenter -t $CONTAINER_PID --net -- ss -tlnp
# 컨테이너의 오픈된 포트 확인 (호스트의 ss와 결과 다름)

# K8s: Pause 컨테이너(Infra 컨테이너) PID 확인 후 진입
# crictl inspect <container-id> | grep pid
# nsenter -t <pid> --net -- ip addr show

# nsenter로 컨테이너에 strace 실행 (strace 미설치 컨테이너에서)
nsenter -t $CONTAINER_PID --pid --mount -- strace -p 1
```

### 2-10. Docker가 namespace를 조합하는 방식

```bash
# 기본 docker run: 6개 namespace 모두 새로 생성
docker run ubuntu sleep 1000 &
CONTAINER_PID=$(docker inspect --format '{{.State.Pid}}' $(docker ps -lq))

# 각 namespace 신규 생성 여부 확인
for ns in pid net mnt uts ipc user; do
  host=$(readlink /proc/1/ns/$ns)
  cont=$(readlink /proc/$CONTAINER_PID/ns/$ns)
  if [ "$host" = "$cont" ]; then
    echo "$ns: 공유 (호스트와 동일)"
  else
    echo "$ns: 격리 (독립 namespace)"
  fi
done

# --pid=host: 호스트 PID namespace 공유
docker run --pid=host ubuntu ps aux   # 호스트의 모든 프로세스 보임

# --network=host: 호스트 NET namespace 공유
docker run --network=host nginx       # 호스트의 80포트 직접 사용

# --ipc=host: 호스트 IPC namespace 공유 (공유 메모리 성능)
docker run --ipc=host myapp

# 보안 영향: --pid=host, --network=host, --privileged 조합은 컨테이너 탈출 위험
```

### 2-11. K8s Pod에서 NET namespace 공유

```
K8s Pod 내 컨테이너 구조:

  ┌──────────────────────────────────────────────────┐
  │                    Pod                           │
  │                                                  │
  │  ┌────────────┐  ┌────────────┐  ┌────────────┐ │
  │  │   Pause    │  │ Container1 │  │ Container2 │ │
  │  │ (Infra)    │  │  (app)     │  │ (sidecar)  │ │
  │  │ 컨테이너   │  │            │  │            │ │
  │  └──────┬─────┘  └──────┬─────┘  └──────┬─────┘ │
  │         │               │               │        │
  │         └───────────────┴───────────────┘        │
  │                         │                        │
  │              공유: NET ns, IPC ns, UTS ns         │
  │              독립: PID ns, MNT ns                 │
  │                                                  │
  │  → 같은 localhost로 통신 가능                    │
  │  → 같은 IP 주소 공유                             │
  │  → 포트 충돌 주의                                │
  └──────────────────────────────────────────────────┘
```

```bash
# K8s Pod 내 컨테이너들이 같은 NET namespace 공유 확인
# Pod의 Pause 컨테이너 PID 찾기
PAUSE_PID=$(crictl inspect $(crictl ps | grep pause | head -1 | awk '{print $1}') | python3 -c "import sys,json; print(json.load(sys.stdin)['info']['pid'])")

# Pod 내 두 컨테이너 NET namespace 비교
APP_PID=$(crictl inspect $(crictl ps | grep myapp | head -1 | awk '{print $1}') | python3 -c "import sys,json; print(json.load(sys.stdin)['info']['pid'])")
SIDECAR_PID=$(crictl inspect $(crictl ps | grep sidecar | head -1 | awk '{print $1}') | python3 -c "import sys,json; print(json.load(sys.stdin)['info']['pid'])")

readlink /proc/$APP_PID/ns/net
readlink /proc/$SIDECAR_PID/ns/net
# 동일한 inode 번호 → 같은 NET namespace

# Sidecar 컨테이너가 localhost로 앱 컨테이너 접근 가능한 이유
kubectl exec pod-name -c sidecar -- curl localhost:8080
# 앱이 8080에서 리슨 중이라면 localhost로 접근 가능 (같은 네트워크)
```

```yaml
# Pod spec에서 shareProcessNamespace (PID namespace 공유)
apiVersion: v1
kind: Pod
metadata:
  name: shared-pid-pod
spec:
  shareProcessNamespace: true   # 컨테이너 간 PID namespace 공유
  containers:
  - name: app
    image: myapp:latest
  - name: debugger
    image: busybox
    command: ["sleep", "infinity"]
    # debugger 컨테이너에서: ps aux → app 컨테이너의 프로세스도 보임
    # strace -p <app-pid>  → app 컨테이너 프로세스 추적 가능
```

### 2-12. namespace vs cgroup - 격리 vs 제한

```
┌─────────────────────────────────────────────────────────────┐
│             namespace vs cgroup 비교                        │
│                                                             │
│  namespace: "무엇을 볼 수 있는가" (가시성/격리)             │
│  ─────────────────────────────────────────────────────     │
│  • 프로세스가 인식하는 시스템 자원의 범위를 제한            │
│  • 다른 컨테이너의 프로세스, 네트워크, 파일을 볼 수 없음   │
│  • 자원 사용량 자체는 제한하지 않음                         │
│                                                             │
│  cgroup: "얼마나 쓸 수 있는가" (사용량 제한)               │
│  ─────────────────────────────────────────────────────     │
│  • CPU, 메모리, I/O, 네트워크 대역폭 사용량 제한            │
│  • 컨테이너 A가 CPU를 100% 쓰면 컨테이너 B에 영향          │
│  • cgroup 없으면 namespace만으로는 자원 독점 가능           │
└─────────────────────────────────────────────────────────────┘
```

```bash
# cgroup v2 확인
mount | grep cgroup
cat /sys/fs/cgroup/cgroup.controllers

# Docker 컨테이너의 cgroup 경로 확인
cat /proc/$CONTAINER_PID/cgroup
# 0::/system.slice/docker-abc123.scope

# 컨테이너 메모리 제한 확인
cat /sys/fs/cgroup/system.slice/docker-abc123.scope/memory.max
# 536870912  ← 512MB 제한 (docker run --memory=512m 설정값)

# K8s: requests/limits가 cgroup으로 변환
# resources.limits.cpu: "500m" → cgroup cpu.max
# resources.limits.memory: "256Mi" → cgroup memory.max
cat /sys/fs/cgroup/kubepods/burstable/podXXX/YYY/memory.max
```

### 2-13. unshare 실습 - 컨테이너 직접 만들기

```bash
# 간단한 컨테이너를 namespace + chroot로 직접 구성

# 1. 최소 rootfs 준비 (Alpine Linux)
mkdir /tmp/mycontainer
# Alpine minirootfs 다운로드
curl -O https://dl-cdn.alpinelinux.org/alpine/v3.18/releases/x86_64/alpine-minirootfs-3.18.0-x86_64.tar.gz
tar xzf alpine-minirootfs-3.18.0-x86_64.tar.gz -C /tmp/mycontainer

# 2. 필요한 디렉토리 마운트
mount -t proc proc /tmp/mycontainer/proc
mount --bind /sys /tmp/mycontainer/sys
mount --bind /dev /tmp/mycontainer/dev

# 3. namespace 격리하고 chroot로 진입
unshare --pid --fork --mount-proc --uts --ipc bash -c "
  hostname my-container
  chroot /tmp/mycontainer /bin/sh
"

# 컨테이너 내부에서
hostname      # my-container
ps aux        # PID 1번부터 시작
ls /          # Alpine 파일시스템

# 이것이 Docker가 하는 일의 본질:
# namespace 격리 + overlayfs rootfs + cgroup 제한 + 보안 프로파일
```

---

## 3. 자주 하는 실수

| 실수 | 증상 / 문제 | 올바른 방법 |
|---|---|---|
| K8s Pod 내 두 컨테이너가 같은 포트 사용 | 두 번째 컨테이너 시작 실패 (이미 바인딩됨) | Pod 내 컨테이너는 NET ns 공유하므로 포트 충돌 불가. 포트 변경 |
| `--network=host` + `--pid=host` 조합 사용 | 컨테이너 격리 사실상 없음, 보안 취약 | 프로덕션에서는 기본 격리 사용. 디버깅 시에만 일시적으로 사용 |
| USER namespace 미사용으로 rootless 컨테이너 실패 | 포트 바인딩, 파일 권한 오류 | rootless Docker 환경에서 USER ns 매핑 확인, 1024 이하 포트는 `CAP_NET_BIND_SERVICE` 필요 |
| nsenter로 진입 후 파일 접근 혼란 | MNT ns 미지정 시 호스트 파일시스템 보임 | `nsenter -t PID --all` 로 모든 namespace 진입, 또는 `--mount` 명시 |
| cgroup 제한 없이 namespace만 적용 | 컨테이너 A가 메모리를 과도하게 사용해 전체 노드 OOM | `docker run --memory --cpus` 또는 K8s `resources.limits` 반드시 설정 |
| PID namespace 내에서 `kill -9 1` 실행 | 컨테이너의 PID 1(init) 종료로 컨테이너 전체 종료 | PID 1 종료는 컨테이너 전체 종료를 의미. 신호 처리 주의 |
| `/proc/PID/ns/` 파일 inode 비교 없이 namespace 공유 가정 | 실제로는 다른 namespace임에도 공유로 착각 | `readlink /proc/PID/ns/net` 으로 inode 번호 직접 비교 확인 |
| `shareProcessNamespace: true` 사이드카에서 실수로 프로세스 종료 | 앱 컨테이너 프로세스를 사이드카에서 kill | 사이드카는 관찰만 허용, 프로세스 조작 권한 분리 (read-only 접근) |
