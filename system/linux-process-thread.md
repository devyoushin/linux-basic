## 1. 개요

프로세스와 스레드의 차이, fork/exec 동작 원리는 리눅스 시스템의 가장 핵심적인 CS 기초다.
컨테이너(Docker/K8s)가 어떻게 격리를 구현하는지도 결국 이 개념(namespace, cgroup)에서 출발한다.
"왜 nginx는 여러 프로세스를 띄우고, node.js는 하나만 띄우는가"와 같은 질문이 여기서 명확해진다.

---

## 2. 프로세스 vs 스레드

### 2.1 핵심 차이

```
프로세스 (Process):             스레드 (Thread):
┌─────────────────────┐         ┌─────────────────────┐
│  독립된 메모리 공간   │         │   공유 메모리 공간    │
│  ┌───┐ ┌───┐ ┌───┐  │         │  ┌───┐ ┌───┐ ┌───┐  │
│  │코드│ │힙  │ │스택│  │         │  │코드│ │힙  │ │스택│  │
│  └───┘ └───┘ └───┘  │         │  └───┘ └───┘ └─ ─┘  │
│  파일 디스크립터 복사  │         │   파일 디스크립터 공유  │
└─────────────────────┘         └─────────────────────┘
   PID: 독립                        TID(Thread ID): 별도
   메모리: 격리                      힙/코드/파일: 공유
   통신: IPC, 소켓, 파이프           통신: 공유 메모리 직접 접근
   생성 비용: 높음 (fork)            생성 비용: 낮음
   충돌 영향: 본인만                  충돌 영향: 전체 프로세스
```

| | 프로세스 | 스레드 |
|---|---|---|
| **메모리** | 독립 (복사) | 공유 (힙, 코드, 파일) |
| **생성 비용** | 높음 | 낮음 |
| **통신** | IPC, 소켓, 파이프 | 공유 변수 직접 접근 |
| **장애 격리** | 한 프로세스 죽어도 다른 프로세스 안전 | 한 스레드의 버그가 전체 프로세스 영향 |
| **동기화** | 불필요 (격리됨) | 뮤텍스, 세마포어 필요 |

### 2.2 왜 nginx는 멀티 프로세스인가

```
nginx 구조 (멀티 프로세스):
  Master Process (PID 1234)
    ├── Worker Process (PID 1235)  ← 코어 0 전담
    ├── Worker Process (PID 1236)  ← 코어 1 전담
    ├── Worker Process (PID 1237)  ← 코어 2 전담
    └── Cache Manager Process (PID 1238)

이유:
- 각 Worker가 독립 프로세스 → 한 Worker 충돌해도 다른 Worker 안전
- 공유 메모리 없으므로 동기화 필요 없음
- Python처럼 GIL이 없으므로 진정한 병렬 처리
- Master가 Worker를 감시, 죽으면 재시작

vs Apache 멀티 스레드 구조:
- 메모리 효율은 좋지만 한 스레드 버그가 전체를 죽일 수 있음
```

### 2.3 확인 명령어

```bash
# 프로세스별 스레드 수 확인
ps -eo pid,nlwp,comm | sort -k2 -rn | head -10
# PID  NLWP  COMMAND
# 1234  32    java      ← 32개 스레드
# 5678   8    nginx

# 특정 프로세스의 스레드 목록
ps -T -p <PID>    # -T: 스레드 표시
ls /proc/<PID>/task   # task 디렉토리 = 스레드 목록

# 멀티 스레드 앱의 CPU 사용 (스레드별)
top -H -p <PID>   # -H: 스레드 단위로 표시
```

---

## 3. fork와 exec

### 3.1 fork() - 프로세스 복제

```
Parent Process
    │
    │ fork()
    │
    ├──────────────→ Child Process
    │                 (부모의 복사본)
    │
    ▼
Parent 계속 실행     Child 계속 실행
```

- `fork()`는 현재 프로세스를 **거의 완전히 복사**한다
- 메모리는 **Copy-on-Write(CoW)**: 실제로 수정할 때만 복사 (처음엔 공유)
- 자식은 부모의 파일 디스크립터, 환경변수, 코드를 상속

```bash
# 셸에서 명령어 실행 = fork + exec
bash ---> fork ---> child bash
                       │
                       └── exec(grep) → bash 이미지를 grep으로 교체
```

### 3.2 exec() - 프로세스 이미지 교체

- `exec()`는 현재 프로세스를 **다른 프로그램으로 교체**한다
- PID는 유지, 메모리/코드/데이터는 새 프로그램으로 교체

```
fork 후 child:          exec 후:
┌─────────────┐         ┌─────────────┐
│  bash 코드   │  ──→   │  grep 코드   │
│  bash 데이터 │         │  grep 데이터 │
│  PID: 5678  │         │  PID: 5678  │ ← PID는 유지
└─────────────┘         └─────────────┘
```

### 3.3 fork+exec 실전 의미

```bash
# 셸 스크립트의 명령어 실행은 모두 fork+exec
# 따라서 서브셸에서 환경변수 변경은 부모 셸에 영향 없음

# 잘못된 예: 서브셸 변수가 부모로 전달 안 됨
bash -c 'export MY_VAR=hello'
echo $MY_VAR   # 비어있음

# 올바른 예: 현재 셸에서 직접 실행
export MY_VAR=hello
echo $MY_VAR   # hello

# exec는 현재 셸을 교체 (PID 유지, 셸 종료 안 됨)
# 컨테이너 엔트리포인트에서 중요
exec /usr/bin/nginx -g "daemon off;"
# → 셸이 nginx로 교체됨 (PID 1 = nginx, 셸 프로세스 없어짐)
```

---

## 4. 컨테이너의 기초: Namespace와 Cgroup

컨테이너는 새로운 기술이 아니다. **리눅스 커널의 namespace와 cgroup을 조합한 것**이다.

### 4.1 Namespace - 격리

각 컨테이너에게 "자신만의 시스템이 있는 것처럼" 보이게 한다.

```
Namespace 종류:
┌──────────┬────────────────────────────────────────┐
│ pid      │ 프로세스 ID 격리 (컨테이너 내부에서 PID 1부터 시작) │
│ net      │ 네트워크 인터페이스, IP, 라우팅 테이블 격리    │
│ mnt      │ 파일시스템 마운트 격리 (컨테이너 자체 루트 파일시스템) │
│ uts      │ hostname 격리 (컨테이너마다 다른 hostname)   │
│ ipc      │ 프로세스 간 통신(메시지 큐, 세마포어) 격리      │
│ user     │ UID/GID 격리 (컨테이너 root ≠ 호스트 root) │
│ cgroup   │ cgroup 뷰 격리                           │
└──────────┴────────────────────────────────────────┘
```

```bash
# 현재 프로세스의 namespace 확인
ls -la /proc/self/ns/
# lrwxrwxrwx ... pid  -> pid:[4026531836]
# lrwxrwxrwx ... net  -> net:[4026531992]
# lrwxrwxrwx ... mnt  -> mnt:[4026531840]

# 컨테이너 내부 프로세스의 namespace 확인
CONTAINER_PID=$(docker inspect --format '{{.State.Pid}}' <container-id>)
ls -la /proc/$CONTAINER_PID/ns/
# → 호스트와 다른 namespace ID 값을 가짐

# 새 network namespace 생성 (직접 실습)
ip netns add test-ns
ip netns exec test-ns ip addr show   # 격리된 네트워크 스택
ip netns exec test-ns bash           # 그 namespace 안에서 셸 실행
ip netns delete test-ns
```

### 4.2 Cgroup - 자원 제한

Namespace가 "격리"라면, Cgroup은 **"자원 할당 및 제한"** 이다.

```
cgroup 제어 항목:
- cpu: CPU 사용량 제한 (Docker --cpus=0.5 → 최대 0.5코어)
- memory: 메모리 상한 (Docker --memory=512m)
- blkio: 디스크 I/O 속도 제한
- network: 네트워크 대역폭 제한 (tc와 연동)
```

```bash
# cgroup v2 구조 확인 (최신 배포판)
ls /sys/fs/cgroup/
# cpu.max, memory.max, io.max 등

# Docker 컨테이너의 cgroup 확인
CONTAINER_ID=<container-id>
cat /sys/fs/cgroup/memory/docker/$CONTAINER_ID/memory.limit_in_bytes
cat /sys/fs/cgroup/cpu/docker/$CONTAINER_ID/cpu.cfs_quota_us

# systemd 서비스에서 cgroup 제한 설정
# /etc/systemd/system/myapp.service
# [Service]
# CPUQuota=50%       ← CPU 50% 이상 못 씀 (1코어 기준)
# MemoryLimit=512M   ← 메모리 512MB 상한
# MemoryMax=512M     ← cgroup v2
```

### 4.3 컨테이너 = namespace + cgroup + (overlay 파일시스템)

```
Docker run 내부적으로 일어나는 일:

1. fork() → 자식 프로세스 생성
2. 새 namespace 생성 (pid, net, mnt, uts, ipc, user)
3. cgroup 생성 및 CPU/메모리 제한 적용
4. OverlayFS로 이미지 레이어 + 쓰기 레이어 마운트
5. exec() → 컨테이너 프로세스(PID 1) 실행

→ 실제로는 "격리된 일반 리눅스 프로세스"
→ 별도 OS나 하이퍼바이저 없음 (VM과 가장 큰 차이)
```

```bash
# 컨테이너가 결국 호스트의 프로세스임을 확인
docker run -d nginx

# 호스트에서 보면 그냥 프로세스
ps aux | grep nginx
# root    12345  nginx: master process ...   ← 호스트에서 보임

# 컨테이너 내부의 PID 1 = 호스트에서의 PID 12345
docker exec <container-id> ps aux
# PID 1: nginx  ← 컨테이너 내부에서는 PID 1

# 같은 프로세스, namespace만 다름
```

---

## 5. PID 1의 특별한 역할

```
컨테이너(또는 시스템)에서 PID 1은:
1. 고아 프로세스의 부모가 됨 (init 역할)
2. SIGTERM을 받으면 graceful shutdown 책임
3. PID 1이 종료하면 컨테이너 전체 종료

잘못된 Dockerfile:
  CMD ["sh", "-c", "node server.js"]
  → sh(PID 1) → node(PID 2)
  → SIGTERM이 sh로 감 → sh가 node에 전달 안 할 수도 있음

올바른 Dockerfile:
  CMD ["node", "server.js"]
  → node가 직접 PID 1
  → SIGTERM 직접 받아 graceful shutdown

또는 tini 사용:
  ENTRYPOINT ["/tini", "--"]
  CMD ["node", "server.js"]
  → tini(PID 1)이 시그널 전달 및 좀비 수거 담당
```

---

## 6. 시그널 (Signal)

프로세스 간 비동기 통신 메커니즘. 운영체제가 프로세스에 "사건"을 알리는 방법.

```bash
# 주요 시그널
# SIGTERM (15): 정상 종료 요청 - 앱이 받아서 cleanup 후 종료
# SIGKILL  (9): 강제 종료 - 커널이 직접 처리, 앱이 거부 불가
# SIGHUP   (1): 설정 재로드 요청 - nginx, sshd 등이 활용
# SIGINT   (2): Ctrl+C - 인터랙티브 종료 요청
# SIGCHLD (17): 자식 프로세스 종료 통보 - 부모가 wait() 하도록

# 시그널 전송
kill -15 <PID>    # SIGTERM (graceful)
kill -9  <PID>    # SIGKILL (강제)
kill -1  <PID>    # SIGHUP  (재로드)

# nginx 설정 재로드 (서비스 중단 없이)
kill -HUP $(cat /run/nginx.pid)
# 또는
nginx -s reload   # 내부적으로 SIGHUP 전송
```

---

## 7. 자주 하는 실수

| 실수 | 올바른 방법 |
|---|---|
| 컨테이너에서 `sh -c "cmd"` 로 PID 1 방치 | CMD에 직접 실행 파일 지정 또는 tini 사용 |
| 스레드가 많으면 빠를 것이라 가정 | 공유 자원 경합(lock contention)으로 오히려 느려질 수 있음 |
| 서브셸 변수를 부모 셸에서 참조 | `export` 해도 부모 셸에 전달 안 됨, 현재 셸에서 직접 설정 |
| 컨테이너가 VM처럼 완전 격리라고 가정 | namespace 격리이지만 호스트 커널 공유, 커널 취약점 영향 받음 |
| OOM Killed된 컨테이너 원인을 앱 버그로만 가정 | cgroup memory.limit 초과가 원인일 수 있음, `dmesg` 확인 |
