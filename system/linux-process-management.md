## 1. 개요

리눅스에서 프로세스를 조회하고 제어하는 명령어 모음이다.
장애 상황에서 CPU/메모리를 과다 점유하는 프로세스를 찾아 조치하거나, 좀비/데드락 프로세스를 정리하는 등 운영 현장에서 즉각적으로 활용된다.

## 2. 설명

### 2.1 프로세스 조회

#### ps - 스냅샷 기반 프로세스 목록

```bash
# 가장 많이 쓰는 형태: 전체 프로세스, 상세 정보
ps aux

# 특정 프로세스 검색
ps aux | grep nginx

# 프로세스 트리 형태 (부모-자식 관계 파악)
ps auxf

# 특정 사용자의 프로세스만
ps -u ubuntu

# CPU/메모리 사용량 상위 10개
ps aux --sort=-%cpu | head -11
ps aux --sort=-%mem | head -11
```

**`ps aux` 컬럼 의미:**

| 컬럼 | 의미 |
|---|---|
| `USER` | 프로세스 소유자 |
| `PID` | 프로세스 ID |
| `%CPU` | CPU 사용률 |
| `%MEM` | 물리 메모리 사용률 |
| `VSZ` | 가상 메모리 크기 (KB) |
| `RSS` | 실제 물리 메모리 사용 (KB) |
| `STAT` | 프로세스 상태 (아래 참고) |
| `COMMAND` | 실행 명령어 |

**프로세스 상태(STAT) 코드:**

| 코드 | 의미 |
|---|---|
| `R` | Running (실행 중) |
| `S` | Sleeping (인터럽트 가능한 대기) |
| `D` | Uninterruptible sleep (I/O 대기, kill 불가) |
| `Z` | Zombie (종료됐지만 부모가 수거 안 함) |
| `T` | Stopped (정지) |
| `<` | 높은 우선순위 |
| `N` | 낮은 우선순위 (nice) |

#### top / htop - 실시간 모니터링

```bash
# 기본 실시간 모니터링 (1~3초 갱신)
top

# top 주요 인터랙티브 키
# P: CPU 사용률 정렬  M: 메모리 사용률 정렬
# k: PID 입력 후 kill  q: 종료  1: CPU 코어별 분리

# htop (더 직관적, 설치 필요)
apt install htop   # Ubuntu
yum install htop   # CentOS

# 특정 프로세스만 모니터링
top -p 1234
top -p 1234,5678
```

### 2.2 프로세스 종료

#### kill - 시그널 전송

```bash
# 주요 시그널
kill -15 <PID>   # SIGTERM: 정상 종료 요청 (기본값, graceful)
kill    <PID>    # 기본값은 SIGTERM (-15와 동일)
kill -9  <PID>   # SIGKILL: 강제 종료 (커널이 직접 제거, 클린업 없음)
kill -1  <PID>   # SIGHUP: 설정 재로드 (nginx, sshd 등)
kill -2  <PID>   # SIGINT: Ctrl+C와 동일

# 이름으로 종료
pkill nginx          # nginx 이름의 모든 프로세스
pkill -9 zombie_app  # 강제 종료
killall nginx        # pkill과 유사

# 패턴 매칭 후 PID 확인
pgrep nginx          # PID만 출력
pgrep -l nginx       # PID + 이름 출력
```

> **원칙**: 항상 `-15(SIGTERM)` 먼저 시도 → 안 죽으면 `-9(SIGKILL)`. SIGKILL은 파일/소켓 정리 없이 죽이므로 데이터 손상 위험이 있다.

### 2.3 프로세스 우선순위 조정 (nice / renice)

CPU 자원 배분을 조정한다. nice 값: -20(최고 우선순위) ~ 19(최저). 기본값은 0.

```bash
# 낮은 우선순위로 백업 스크립트 실행 (다른 서비스에 영향 최소화)
nice -n 19 /opt/scripts/backup.sh

# 이미 실행 중인 프로세스 우선순위 변경
renice -n 10 -p <PID>

# 특정 서비스 전체 우선순위 낮추기
renice -n 15 -u backup-user
```

### 2.4 백그라운드 실행 & 작업 관리

```bash
# 백그라운드 실행
./long_script.sh &

# 현재 셸의 백그라운드/정지 작업 목록
jobs

# 백그라운드 작업을 포그라운드로
fg %1   # 작업 번호 1번

# 포그라운드 작업을 백그라운드로
# Ctrl+Z (일시 정지) 후
bg %1

# 셸 종료 후에도 계속 실행 (hangup 무시)
nohup ./long_script.sh >> /var/log/script.log 2>&1 &

# 더 강력한 지속 실행 (tmux/screen 권장)
tmux new-session -d -s mysession './long_script.sh'
```

### 2.5 장애 대응 실전 패턴

#### 좀비 프로세스(Zombie) 처리

```bash
# 좀비 프로세스 찾기
ps aux | grep 'Z'
ps aux | awk '$8 == "Z"'

# 좀비는 직접 kill 불가 - 부모 프로세스(PPID)를 종료해야 함
# 1. 좀비의 PPID 확인
ps -o ppid= -p <zombie_pid>

# 2. 부모에게 SIGCHLD 전송 (부모가 wait() 하도록 유도)
kill -17 <parent_pid>

# 3. 안 되면 부모 프로세스 재시작 또는 종료
kill -15 <parent_pid>
```

#### D 상태(Uninterruptible Sleep) 프로세스

`D` 상태 프로세스는 `kill -9`도 듣지 않는다. I/O 완료를 기다리는 중이다.

```bash
# D 상태 프로세스 찾기
ps aux | awk '$8 ~ /^D/'

# 어떤 I/O를 기다리는지 확인
cat /proc/<PID>/wchan    # 대기 중인 커널 함수
ls -la /proc/<PID>/fd    # 열려있는 파일 디스크립터

# 해결책: 대기 중인 I/O 원인 해소 (NFS 언마운트, 디스크 문제 해결 등)
# 안 되면 재부팅이 유일한 방법
```

#### 특정 포트 사용 프로세스 찾기

```bash
# 8080 포트를 점유 중인 프로세스
ss -tlnp | grep :8080
lsof -i :8080

# 그 PID를 kill
kill -9 $(lsof -ti :8080)
```

### 2.6 /proc 파일시스템으로 상세 정보 확인

```bash
# 특정 프로세스 상세 상태
cat /proc/<PID>/status

# 프로세스가 열어둔 파일 목록
ls -la /proc/<PID>/fd

# 프로세스 메모리 맵
cat /proc/<PID>/maps

# 프로세스 환경변수
cat /proc/<PID>/environ | tr '\0' '\n'

# 현재 실행 중인 명령어 (심볼릭 링크)
ls -la /proc/<PID>/exe
```

## 3. 자주 하는 실수

| 실수 | 올바른 방법 |
|---|---|
| 무조건 `-9`로 강제 종료 | `-15` 먼저 시도, 안 될 때만 `-9` 사용 |
| 좀비 프로세스를 직접 kill 시도 | 부모 프로세스(PPID)를 종료하거나 SIGCHLD 전송 |
| `D` 상태 프로세스를 kill로 해결 시도 | I/O 원인(NFS, 디스크 장애 등) 해소가 우선 |
| 프로세스 종료 후 포트 잠시 안 열림 | `TIME_WAIT` 상태 - `ss -tlnp`로 확인, 잠시 대기 |
