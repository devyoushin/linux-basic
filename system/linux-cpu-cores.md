## 1. 개요

"명령어를 실행했는데 CPU가 100%다" 또는 "코어가 32개인데 왜 느리지?"라는 상황의 원인은
명령어가 **단일 스레드(1코어)**인지 **멀티 스레드**인지에 달려 있다.
리눅스 핵심 도구들(grep, sed, awk, find)은 대부분 단일 스레드이며, 이를 병렬화하는 방법을 알면 처리 속도를 수십 배 높일 수 있다.

---

## 2. CPU 코어 기초 개념

### 2.1 물리 코어 vs 논리 코어 (하이퍼스레딩)

```
물리 코어 4개, 하이퍼스레딩(HT) 2배 → 논리 코어(vCPU) 8개

┌────────────────┐ ┌────────────────┐
│   물리 코어 0   │ │   물리 코어 1   │
│ ┌─────┐┌─────┐│ │ ┌─────┐┌─────┐│
│ │vCPU0││vCPU1││ │ │vCPU2││vCPU3││
│ └─────┘└─────┘│ │ └─────┘└─────┘│
└────────────────┘ └────────────────┘
```

- **하이퍼스레딩**: 1개의 물리 코어를 OS에게 2개처럼 보이게 함
- 실제 연산 유닛은 하나이므로, 두 스레드가 동시에 정수 연산하면 경합 발생
- CPU 집약적(CPU-bound) 작업은 물리 코어 수가 병목, I/O 대기가 많은 작업은 논리 코어가 유리

```bash
# 코어 정보 확인
nproc                          # 논리 코어(vCPU) 수
nproc --all                    # 전체 사용 가능한 코어 수
lscpu                          # 상세: 물리 코어, 소켓, 하이퍼스레딩 여부

lscpu | grep -E "^CPU\(s\)|Thread|Core|Socket"
# CPU(s):              8       ← 논리 코어(vCPU) 총 수
# Thread(s) per core:  2       ← 하이퍼스레딩 (2면 HT 활성)
# Core(s) per socket:  4       ← 소켓당 물리 코어 수
# Socket(s):           1       ← 물리 CPU 소켓 수

# 물리 코어 수 = Socket × Core per socket = 1 × 4 = 4
# 논리 코어 수 = 물리 코어 × Thread = 4 × 2 = 8

cat /proc/cpuinfo | grep "model name" | uniq   # CPU 모델
cat /proc/cpuinfo | grep "cpu MHz" | head -4   # 현재 클럭 속도
```

### 2.2 CPU 바운드 vs I/O 바운드

```
CPU 바운드 작업:                I/O 바운드 작업:
- 암호화, 압축                  - 파일 읽기/쓰기
- 영상 인코딩                   - 네트워크 요청
- 데이터 집계 연산               - DB 쿼리 대기
→ CPU가 병목                    → CPU 대기 시간이 병목

top에서의 구분:
%us(user) 높음 → CPU 바운드    %wa(iowait) 높음 → I/O 바운드
```

---

## 3. 주요 명령어의 스레드 사용 특성

### 3.1 단일 스레드 명령어 (코어 1개만 사용)

| 명령어 | 스레드 | 이유 |
|---|---|---|
| `grep` | 1 | 순차적 라인 처리 |
| `sed` | 1 | 스트림 순차 편집 |
| `awk` | 1 | 순차 처리 설계 |
| `find` | 1 | 디렉토리 순회 순차 |
| `sort` (소량) | 1 | 기본 단일 스레드 |
| `cat`, `head`, `tail` | 1 | 단순 I/O |
| `python` 스크립트 | 1 | GIL(Global Interpreter Lock) |

```bash
# grep이 단일 코어만 쓰는 걸 확인
# 대용량 파일에서 grep 실행 중 다른 터미널에서:
top -p $(pgrep grep)
# %CPU가 최대 100% (1코어)까지만 올라감, 800% 안 됨
```

### 3.2 멀티 스레드/프로세스 명령어

| 명령어 | 스레드 | 비고 |
|---|---|---|
| `gzip -T N` / `pigz` | N | pigz는 gzip 병렬 버전 |
| `ripgrep (rg)` | 여러 개 | grep 대체, 자동 병렬화 |
| `sort -parallel=N` | N | GNU sort 병렬 옵션 |
| `make -j N` | N | N개 병렬 빌드 |
| `xargs -P N` | N | N개 병렬 프로세스 |
| `parallel` | 여러 개 | GNU Parallel |
| `rsync` | 1 (기본) | 멀티 스트림은 별도 구성 |

---

## 4. top / htop으로 CPU 읽기

### 4.1 top의 CPU 표시

```
top - 14:32:01 up 5 days,  2:14,  1 user,  load average: 1.23, 0.98, 0.87
Tasks: 245 total,   2 running, 243 sleeping
%Cpu(s): 12.3 us,  2.1 sy,  0.0 ni, 84.5 id,  0.8 wa,  0.0 hi,  0.3 si
```

| 항목 | 의미 | 높으면 |
|---|---|---|
| `us` (user) | 사용자 영역 CPU 사용률 | 앱이 CPU 많이 씀 (CPU 바운드) |
| `sy` (system) | 커널/시스템 콜 사용률 | 시스템 콜 과다 (I/O, 소켓 등) |
| `ni` (nice) | nice로 낮춘 프로세스 사용률 | 낮은 우선순위 작업 실행 중 |
| `id` (idle) | 유휴 CPU 비율 | 정상 (높을수록 여유) |
| `wa` (iowait) | I/O 대기 중인 CPU 비율 | 디스크/네트워크 병목 |
| `hi` (hw interrupt) | 하드웨어 인터럽트 | 네트워크 패킷 폭증 등 |
| `si` (sw interrupt) | 소프트웨어 인터럽트 | 네트워크 처리 과다 |

```bash
# 개별 코어별 사용률 보기 (top에서 '1' 키 입력)
%Cpu0 : 95.0 us,  3.0 sy   ← 코어 0 과부하
%Cpu1 :  2.0 us,  1.0 sy   ← 코어 1 한가함
# → 단일 스레드 프로세스가 코어 0만 쓰고 있는 것

# 특정 프로세스의 코어 사용 확인
top -p <PID>
# 멀티 스레드 앱은 %CPU가 100% 초과 가능 (코어 수 × 100이 최대)
# 예: 4코어 사용 중이면 400%로 표시
```

### 4.2 Load Average 해석

```
load average: 1.23, 0.98, 0.87
              └─ 1분  └─ 5분  └─ 15분 평균
```

**Load Average의 의미**: 실행 중이거나 실행 대기 중인 프로세스 수의 평균

```
코어 수 = 4인 경우:
  load average 1.0 → 코어의 25% 사용 (여유)
  load average 4.0 → 코어 100% 포화 (한계)
  load average 8.0 → 2배 과부하 (실행 대기 프로세스 쌓임)

# 적정 load average ≤ 코어 수
# 코어 수 확인
nproc

# load average가 코어 수의 70% 이하면 정상
# 코어 수 초과 시 병목 조사 필요
```

---

## 5. 단일 스레드 명령어 병렬화

### 5.1 xargs -P (프로세스 병렬화)

```bash
# 기본 (순차 처리, 1코어)
find /var/log -name "*.log" -exec grep "ERROR" {} \;

# xargs -P N: N개 프로세스로 병렬 처리
find /var/log -name "*.log" | xargs -P 8 grep "ERROR"

# 코어 수만큼 자동으로
find /var/log -name "*.log" | xargs -P $(nproc) grep "ERROR"

# 파일 병렬 압축 (각 파일을 독립 프로세스로)
find /data -name "*.csv" | xargs -P $(nproc) -I{} gzip {}
```

### 5.2 GNU parallel

```bash
# 설치
apt install parallel    # Ubuntu
yum install parallel   # CentOS

# 기본 사용법: {} 가 입력값으로 치환
ls *.log | parallel gzip {}

# 코어 수 지정
ls *.log | parallel -j 8 gzip {}

# 진행상황 표시
ls *.log | parallel --progress gzip {}

# 실전: 여러 서버에 병렬로 명령 실행
echo -e "server1\nserver2\nserver3" | \
    parallel -j 3 ssh ubuntu@{} 'sudo systemctl restart nginx'

# 실전: 대용량 로그 파일 병렬 분석
find /var/log -name "*.log" | \
    parallel "grep -c ERROR {} | awk -F: '{print \$2, \$1}'"
```

### 5.3 ripgrep (rg) - grep의 멀티스레드 대체

```bash
# 설치
apt install ripgrep   # Ubuntu 18.10+
yum install ripgrep   # RHEL (EPEL)

# 사용법은 grep과 동일, 내부적으로 멀티스레드
rg "ERROR" /var/log/

# 성능 비교 (대용량 디렉토리)
time grep -r "ERROR" /var/log/       # 단일 스레드
time rg "ERROR" /var/log/            # 멀티 스레드 (수 배 빠름)
```

### 5.4 pigz - gzip의 멀티스레드 대체

```bash
# 설치
apt install pigz

# 기본 gzip (단일 스레드)
time gzip large_file.tar            # 느림

# pigz (모든 코어 사용)
time pigz large_file.tar            # 빠름
time pigz -p 4 large_file.tar       # 4코어 지정

# tar와 조합
tar -cf - /data | pigz > backup.tar.gz          # 압축
pigz -d backup.tar.gz | tar -xf - -C /restore  # 해제
```

---

## 6. CPU 친화성(Affinity) 제어

특정 프로세스를 특정 코어에 고정하거나, 특정 코어를 배제할 수 있다.

```bash
# taskset: 프로세스를 특정 코어에 고정
# 코어 0, 1에서만 실행
taskset -c 0,1 ./my_app

# 실행 중인 프로세스 코어 변경
taskset -cp 0,1 <PID>

# 현재 프로세스의 코어 설정 확인
taskset -cp <PID>

# numactl: NUMA 아키텍처에서 CPU+메모리 노드 지정 (멀티 소켓 서버)
numactl --cpunodebind=0 --membind=0 ./my_app
```

**언제 사용하나?**
- 레이턴시 민감한 서비스를 특정 코어에 독점 할당
- 백그라운드 작업이 서비스 코어를 침범하지 않도록
- 멀티 소켓 서버에서 CPU-메모리 원격 접근(NUMA miss) 방지

---

## 7. 실전 시나리오

### 7.1 "코어가 많은데 느리다" 진단

```bash
# 1. load average 확인
uptime
# load average가 코어 수보다 낮으면 → 단일 스레드 병목일 가능성

# 2. 개별 코어 사용률 확인 (top에서 '1' 입력)
# 한 코어만 100%이고 나머지 한가 → 단일 스레드 앱

# 3. 해당 프로세스 확인
ps aux --sort=-%cpu | head -5
top -p <PID>  # 스레드 수 확인

# 4. 스레드 수 확인
cat /proc/<PID>/status | grep Threads
ls /proc/<PID>/task | wc -l   # 실제 스레드(task) 수
```

### 7.2 대용량 로그 분석 속도 높이기

```bash
# 느린 방법 (단일 스레드, 순차)
grep "ERROR" /var/log/app/app.log.* | wc -l

# 빠른 방법 1: xargs 병렬화
ls /var/log/app/app.log.* | xargs -P $(nproc) grep -c "ERROR" | awk -F: '{sum+=$2} END{print sum}'

# 빠른 방법 2: ripgrep (자동 병렬)
rg -c "ERROR" /var/log/app/ | awk -F: '{sum+=$2} END{print sum}'
```

## 8. 자주 하는 실수

| 실수 | 올바른 방법 |
|---|---|
| 코어 많으니 grep이 빠를 것이라 기대 | grep은 단일 스레드, rg 또는 xargs -P 사용 |
| load average만 보고 과부하 판단 | 코어 수 대비 상대적으로 판단 (`load / nproc`) |
| %CPU 100% = 과부하로 오해 | 멀티 스레드 앱은 코어 수 × 100%가 최대, 400%도 정상 |
| `make -j`로 빌드 시 코어 수 초과 지정 | `make -j $(nproc)` 이상은 오히려 느려질 수 있음 |
| iowait 높은데 CPU 최적화 시도 | iowait는 I/O 병목, 디스크/네트워크 개선이 우선 |
