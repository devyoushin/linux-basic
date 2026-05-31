# Linux 시스템 트러블슈팅

## 1. 개요

시스템 장애는 CPU 과부하, 메모리 부족, 프로세스 응답 없음, 서비스 기동 실패, 부팅 불가 등 형태가 다양하다. 증상만 보고 재시작하면 원인이 남아 반복 장애로 이어진다. 이 문서는 **증상 → 계층 분리 → 명령어 검증 → 원인 특정** 흐름으로 시스템 장애를 진단하는 방법을 정리한다.

---

## 2. 트러블슈팅 기본 원칙

```
증상 파악 → 자원 계층 분리 → 명령어 검증 → 원인 특정 → 수정 → 재검증
```

시스템 자원 계층:
```
애플리케이션 (프로세스/서비스)
    ↓
런타임 (systemd, cgroup, ulimit)
    ↓
커널 (스케줄러, 메모리 관리, 시스템콜)
    ↓
하드웨어 (CPU, DRAM, NIC, 디스크)
```

---

## 3. 상황 파악 — 첫 30초

장애 알림을 받으면 전체 상황을 빠르게 스캔한다.

```bash
# 한 번에 전체 상황 파악 (부하·메모리·프로세스)
uptime                         # 평균 부하 (1분/5분/15분)
free -h                        # 메모리 사용량
df -h | awk '$5+0 >= 80'       # 디스크 사용률 80% 이상
top -bn1 | head -20            # CPU/메모리 상위 프로세스

# 더 깔끔한 전체 뷰 (htop이 있으면)
htop

# 최근 커널 메시지 (하드웨어/드라이버 오류)
dmesg -T | tail -30
dmesg -T -l err,crit,alert,emerg  # 에러 이상 레벨만

# 최근 시스템 로그
journalctl -p err -n 50 --no-pager   # 에러 이상 로그 50줄
journalctl --since "10 minutes ago"  # 최근 10분 로그
```

---

## 4. 계층별 핵심 명령어

### 4-1. CPU — 무엇이 CPU를 쓰는지

```bash
# 실시간 CPU 사용률 (프로세스별)
top -d 1                       # 1초 갱신
# P키: CPU 정렬, M키: 메모리 정렬, k키: kill

# 더 상세한 CPU 분석
pidstat -u 1 5                 # 1초 간격 5회, 프로세스별 CPU
mpstat -P ALL 1 5              # CPU 코어별 사용률
sar -u 1 5                     # CPU 히스토리 (us, sy, wa, id)

# CPU 사용률 높은 프로세스 Top 10
ps aux --sort=-%cpu | head -11

# 특정 프로세스의 스레드별 CPU
ps -eLf | grep <프로세스명>     # 스레드 목록
top -H -p <PID>                # 해당 PID의 스레드별 CPU

# 시스템 콜 병목 확인 (CPU sy% 높을 때)
strace -p <PID> -c -f          # 시스템콜 통계 (10초 후 Ctrl+C)
perf top -p <PID>              # 핫 함수 실시간 확인

# CPU 컨텍스트 스위치 확인 (cs% 높을 때)
vmstat 1 5
# cs 컬럼: 초당 컨텍스트 스위치 수 (정상: 수천~수만, 비정상: 수십만+)
pidstat -w 1 5                 # 프로세스별 컨텍스트 스위치
```

### 4-2. 메모리 — 무엇이 메모리를 쓰는지

```bash
# 메모리 전체 현황
free -h
# available 컬럼이 실제 사용 가능한 메모리 (buff/cache 재사용 포함)

# 상세 메모리 정보
cat /proc/meminfo
# 주요 항목:
# MemAvailable: 실제 사용 가능 메모리 (이 값이 기준)
# Cached:       페이지 캐시 (부족해도 자동 반환)
# Dirty:        디스크 미기록 데이터 (높으면 I/O 급증 가능)
# Slab:         커널 slab 캐시 (비정상적으로 크면 커널 메모리 누수)

# 메모리 사용량 높은 프로세스 Top 10
ps aux --sort=-%mem | head -11

# 프로세스별 실제 메모리 사용량 (RSS vs VSZ)
ps -eo pid,ppid,comm,rss,vsz --sort=-rss | head -11
# RSS: 실제 물리 메모리 사용량 (MB 단위: RSS/1024)

# 메모리 누수 의심 프로세스 모니터링
while true; do
  ps -o pid,rss,comm -p <PID>
  sleep 10
done
# RSS가 계속 증가하면 메모리 누수 의심

# OOM killer 발동 여부 확인
dmesg -T | grep -i "oom\|out of memory\|killed process"
journalctl -k | grep -i "oom killer"

# OOM score 확인 (높을수록 먼저 킬됨)
cat /proc/<PID>/oom_score
cat /proc/<PID>/oom_score_adj  # -1000(절대 안 킬) ~ 1000(최우선 킬)
```

### 4-3. 프로세스 — 상태와 행동 분석

```bash
# 프로세스 상태 전체 조회
ps aux
# STAT 컬럼: R(실행중), S(잠듦), D(I/O대기), Z(좀비), T(중지)

# D 상태(I/O wait) 프로세스 찾기 — 장기간 D 상태면 I/O 병목 또는 NFS 행
ps aux | awk '$8 == "D" {print}'
watch -n 1 'ps aux | awk "\$8==\"D\""'  # 1초마다 갱신

# 좀비 프로세스 확인
ps aux | awk '$8 == "Z" {print}'
# 좀비는 부모가 wait() 안 한 경우 — 부모 프로세스 재시작으로 해결

# 프로세스 트리 (부모-자식 관계)
pstree -p
pstree -p <PID>                # 특정 PID 중심

# 특정 프로세스가 무엇을 하는지
strace -p <PID> -e trace=all -T 2>&1 | head -50   # 시스템콜 추적
lsof -p <PID>                  # 열린 파일/소켓 목록
cat /proc/<PID>/status         # 상태 정보 (Threads, VmRSS 등)
cat /proc/<PID>/wchan          # 어떤 커널 함수에서 대기 중인지

# 응답 없는 프로세스 강제 종료
kill -TERM <PID>               # 정상 종료 요청 (SIGTERM)
kill -KILL <PID>               # 강제 종료 (SIGKILL, 무조건)
# > **주의**: SIGKILL은 데이터 정리 없이 즉시 종료됨
```

### 4-4. systemd 서비스 — 기동 실패 및 오류

```bash
# 서비스 전체 상태 (실패한 것만)
systemctl --failed
systemctl list-units --state=failed

# 특정 서비스 상태 및 최근 로그
systemctl status nginx
journalctl -u nginx -n 50 --no-pager

# 서비스 기동 실패 상세 원인
journalctl -u nginx -p err --since "1 hour ago"
journalctl -xe                 # 마지막 오류 + 상세 컨텍스트

# 서비스 의존성 확인 (의존 서비스가 실패했을 수 있음)
systemctl list-dependencies nginx
systemctl list-dependencies nginx --reverse  # 이 서비스에 의존하는 서비스

# 서비스 유닛 파일 확인
systemctl cat nginx            # 현재 적용된 유닛 파일 내용
systemctl show nginx           # 모든 설정값 (ExecStart, LimitNOFILE 등)
systemctl show nginx --property=MainPID   # 특정 속성만

# cgroup 리소스 제한 확인
systemctl show nginx --property=CPUQuota,MemoryMax,TasksMax

# 서비스 재시작 이력
journalctl -u nginx | grep -E "Started|Stopped|Failed|Restarting"
```

### 4-5. 부팅 — 느린 부팅 및 부팅 실패

```bash
# 부팅 시간 분석
systemd-analyze                # 전체 부팅 소요 시간
systemd-analyze blame          # 서비스별 시작 소요 시간
systemd-analyze critical-chain # 크리티컬 패스 (병렬 실행 체인)

# 특정 부팅 로그 확인
journalctl -b                  # 현재 부팅 로그
journalctl -b -1               # 이전 부팅 로그
journalctl -b -2               # 2번 이전 부팅 로그
journalctl --list-boots        # 부팅 이력 목록

# 부팅 실패 원인 찾기
journalctl -b -p err           # 이번 부팅의 에러만
journalctl -b -1 -p err        # 이전 부팅의 에러 (비정상 종료 후)

# 느린 서비스 찾기 (10초 이상 걸린 것)
systemd-analyze blame | awk '{if($1+0 > 10) print}'
```

### 4-6. ulimit / cgroup — 리소스 제한에 걸렸는지

```bash
# 프로세스의 현재 ulimit 값
cat /proc/<PID>/limits

# 시스템 전체 ulimit 기본값
ulimit -a

# 파일 디스크립터 한도 초과 확인 ("Too many open files" 에러)
lsof -p <PID> | wc -l                    # 현재 열린 파일 수
cat /proc/<PID>/limits | grep "open files"  # 최대 허용값
cat /proc/sys/fs/file-nr                 # 시스템 전체 fd 사용 현황

# cgroup 메모리 제한 초과 확인 (컨테이너/systemd 서비스)
cat /sys/fs/cgroup/memory/<서비스명>/memory.usage_in_bytes
cat /sys/fs/cgroup/memory/<서비스명>/memory.limit_in_bytes
cat /sys/fs/cgroup/memory/<서비스명>/memory.failcnt  # 제한 초과 횟수

# systemd 서비스의 cgroup 통계
systemctl status nginx | grep -i "memory\|cpu\|tasks"
# cgroup v2 환경
cat /sys/fs/cgroup/system.slice/nginx.service/memory.current

# 스레드 수 한도 확인 (nproc)
cat /proc/<PID>/status | grep Threads
cat /proc/sys/kernel/threads-max          # 시스템 전체 스레드 한도
```

---

## 5. 장애 시나리오별 진단 흐름

### 시나리오 1: 서버가 느리고 부하가 높음

```bash
# Step 1: 부하 종류 파악 (CPU vs I/O)
vmstat 1 5
# r 컬럼(실행 대기): CPU 코어 수보다 크면 CPU 병목
# wa 컬럼(I/O wait): 20% 이상 지속이면 I/O 병목
# b 컬럼(I/O wait 프로세스 수)

# Step 2-A: CPU 병목인 경우
top -bn1 | head -20            # CPU 상위 프로세스 확인
ps aux --sort=-%cpu | head -6
# us(사용자) 높음 → 앱 코드 문제 → perf/strace로 핫 경로 분석
# sy(커널) 높음 → 시스템콜 과다 → strace -c로 시스템콜 통계

# Step 2-B: I/O 병목인 경우
iostat -x 1 5                  # 디스크 포화 확인
iotop -o -b -n 3               # I/O 유발 프로세스

# Step 3: 특정 프로세스 상세 분석
strace -p <PID> -c -f          # 시스템콜 분포 (10초 측정)
perf top -p <PID>              # CPU 핫 함수

# Step 4: 단기 조치
renice 10 -p <PID>             # 문제 프로세스 우선순위 낮춤 (nice 값 증가)
cpulimit -p <PID> -l 50        # CPU 사용률 50%로 제한
```

### 시나리오 2: 프로세스가 갑자기 죽음 (OOM)

```bash
# Step 1: OOM killer 발동 확인
dmesg -T | grep -i "oom\|killed process" | tail -20
# "Out of memory: Killed process 1234 (java)" 형태로 출력됨

# Step 2: 어떤 프로세스가 킬됐는지, 언제
journalctl -k --since "1 hour ago" | grep -i "oom"
# 킬된 프로세스명, PID, 당시 메모리 사용량 확인

# Step 3: 메모리 사용 추이 확인
sar -r 1 60                    # 메모리 사용률 히스토리 (SAR 데이터)
# sar 없으면 /var/log/sa/ 에서 과거 데이터 확인

# Step 4: 재발 방지
# 방법 A: 메모리 늘리기 (스케일업)
# 방법 B: 앱 메모리 제한 설정 (systemd)
systemctl edit myapp           # 아래 내용 추가
# [Service]
# MemoryMax=2G
# MemoryHigh=1.5G              # 소프트 한도 (캐시 반환 유도)

# 방법 C: OOM score 조정 (중요 프로세스 보호)
echo -500 > /proc/<PID>/oom_score_adj   # 낮을수록 킬 우선순위 낮음
# 영구 적용은 서비스 유닛에 OOMScoreAdjust=-500 추가
```

### 시나리오 3: 특정 서비스가 기동 실패

```bash
# Step 1: 실패 원인 확인
systemctl status myapp.service
journalctl -u myapp.service -n 30 --no-pager

# Step 2: 종료 코드 확인
systemctl show myapp --property=ExecMainStatus  # 종료 코드
# 137 = SIGKILL (OOM 또는 수동 kill)
# 139 = Segfault (메모리 접근 오류)
# 1   = 앱 자체 오류

# Step 3: 환경변수/설정 파일 문제
systemctl show myapp --property=Environment    # 환경변수 확인
systemctl cat myapp                            # 유닛 파일 확인
# ExecStart 명령을 직접 실행해서 오류 메시지 확인
/usr/bin/myapp --config /etc/myapp/config.yaml

# Step 4: 의존 서비스 확인
systemctl list-dependencies myapp             # 필요한 서비스들
systemctl status postgresql                   # DB 먼저 떠 있는지

# Step 5: 파일 권한/소유자 확인
systemctl show myapp --property=User,Group    # 실행 계정
ls -la /etc/myapp/ /var/lib/myapp/            # 설정/데이터 디렉토리 권한

# Step 6: SELinux/AppArmor 차단 확인
ausearch -m avc -ts recent 2>/dev/null | tail -20  # SELinux 거부 로그
dmesg | grep -i "apparmor\|selinux" | tail -20
```

### 시나리오 4: 메모리 사용량이 계속 증가 (메모리 누수 의심)

```bash
# Step 1: 메모리 증가 트렌드 확인
watch -n 5 'ps -o pid,rss,vsz,comm -p <PID>'
# RSS가 계속 오르면 누수

# Step 2: 프로세스 메모리 상세 맵 확인
cat /proc/<PID>/smaps | grep -E "^(Private|Shared|Rss|Pss):" | \
  awk '{sum[$1]+=$2} END {for(k in sum) print k, sum[k]/1024 "MB"}'

cat /proc/<PID>/status | grep -E "Vm|Rss"

# Step 3: 커널 slab 메모리 누수 확인
slabtop                        # slab 캐시 실시간 (커널 메모리)
cat /proc/slabinfo | sort -k3 -rn | head -20
# 특정 slab이 계속 증가하면 커널 드라이버/모듈 누수

# Step 4: 메모리 단편화 확인
cat /proc/buddyinfo            # 버디 시스템 빈 블록 (줄어들면 단편화)
cat /proc/meminfo | grep -E "MemFree|MemAvailable|Cached|Slab"

# Step 5: 단기 조치 (페이지 캐시 해제)
sync && echo 3 > /proc/sys/vm/drop_caches
# > **주의**: 성능 일시 저하 가능, 메모리 누수 자체는 해결 안 됨
```

### 시나리오 5: crontab/systemd-timer 작업이 실행 안 됨

```bash
# Step 1: cron 로그 확인
journalctl -u cron -n 30 --no-pager
journalctl -u crond -n 30 --no-pager   # RHEL/CentOS
grep CRON /var/log/syslog | tail -20   # 데비안 계열

# Step 2: crontab 설정 확인
crontab -l                             # 현재 사용자
crontab -l -u root                     # root 계정
cat /etc/cron.d/*                      # 시스템 크론

# Step 3: 환경변수 문제 확인 (cron은 PATH가 최소한)
# 크론에서 실패하는 명령을 직접 환경변수 없이 실행
env -i /bin/sh -c "your_command"

# Step 4: systemd-timer 상태 확인
systemctl list-timers --all            # 타이머 목록과 다음 실행 시각
systemctl status myapp.timer
journalctl -u myapp.service --since "1 day ago"  # 서비스 실행 로그

# Step 5: 실행 권한 및 스크립트 오류 확인
bash -n /path/to/script.sh            # 문법 검사만
bash -x /path/to/script.sh            # 디버그 모드 실행 (각 명령 출력)
```

### 시나리오 6: 서버가 응답은 하는데 특정 명령이 hang

```bash
# Step 1: hang된 프로세스 상태 확인
ps aux | grep <명령어>
# D 상태 (uninterruptible sleep) → I/O 대기, 주로 NFS 또는 디스크 문제

# Step 2: 무엇을 기다리는지 확인
cat /proc/<PID>/wchan              # 대기 중인 커널 함수명
cat /proc/<PID>/stack              # 커널 스택 트레이스 (커널 디버그 정보)

# Step 3: 열린 파일/소켓 확인
lsof -p <PID>
# NFS 마운트 포인트를 열고 있으면 NFS 서버 문제 가능성

# Step 4: NFS hang인 경우
mount | grep nfs                   # NFS 마운트 확인
nfsstat -c                         # NFS 클라이언트 통계 (타임아웃 확인)
# NFS 서버가 다운됐으면 D 상태로 hang → umount -l 로 lazy 언마운트

# Step 5: strace로 어디서 멈췄는지
strace -p <PID>                    # 현재 어떤 시스템콜에서 대기 중인지
# 출력이 없으면 커널 내부에서 대기 → /proc/<PID>/stack 확인
```

### 시나리오 7: 부팅 후 서비스가 자동 시작 안 됨

```bash
# Step 1: 서비스 자동 시작 설정 확인
systemctl is-enabled myapp.service   # enabled/disabled/static

# Step 2: enable 되어있는데도 안 뜨면 의존성 확인
systemctl list-dependencies myapp.service
journalctl -b -u myapp.service       # 이번 부팅에서 해당 서비스 로그

# Step 3: 부팅 타이밍 문제 (의존 서비스보다 먼저 뜨려고 해서 실패)
systemd-analyze critical-chain myapp.service
# After= 설정 확인
systemctl cat myapp.service | grep -E "After|Wants|Requires"

# Step 4: 타이밍 문제 해결 — 유닛 파일 수정
systemctl edit myapp.service        # drop-in 파일 작성
# [Unit]
# After=network-online.target
# Wants=network-online.target

# Step 5: 부팅 후 로그에서 실패 원인
journalctl -b -p err               # 이번 부팅의 에러 전체
```

---

## 6. 자주 쓰는 원라이너 모음

```bash
# CPU 코어별 사용률 스냅샷
mpstat -P ALL 1 1 | awk '/^[0-9]/{print "CPU"$3, $4"%"}'

# 메모리 사용량 MB 단위로 프로세스 Top 10
ps -eo rss,pid,comm --sort=-rss | awk 'NR<=11{printf "%.1fMB\t%s\t%s\n",$1/1024,$2,$3}'

# 5초마다 특정 프로세스 메모리 추적
watch -n 5 'cat /proc/<PID>/status | grep -E "VmRSS|VmSize"'

# 시스템 전체 파일 디스크립터 사용량
echo "사용중: $(cat /proc/sys/fs/file-nr | awk '{print $1}') / 최대: $(cat /proc/sys/fs/file-max)"

# 좀비 프로세스와 부모 프로세스 한 번에 확인
ps -eo stat,pid,ppid,comm | awk '$1~/Z/{print "좀비PID:"$2, "부모PID:"$3, "부모:"$4}'

# 실패한 서비스 목록 + 마지막 오류 메시지
systemctl --failed --no-legend | awk '{print $1}' | \
  xargs -I{} sh -c 'echo "=== {} ==="; journalctl -u {} -n 3 --no-pager -q'

# 1시간 내 OOM 발생 여부 빠른 확인
journalctl -k --since "1 hour ago" | grep -c "Out of memory" | \
  xargs -I{} echo "OOM 발생 횟수: {}"

# 프로세스별 스레드 수 Top 10
ps -eLf | awk '{print $1, $2}' | sort | uniq -c | sort -rn | head -10
```

---

## 7. 성능 베이스라인 수집 (장애 대비)

정상 상태의 수치를 미리 기록해 두면 장애 시 비교 기준이 된다.

```bash
# 정기 수집 스크립트 예시 (cron 또는 systemd-timer로 실행)
DATE=$(date +%Y%m%d_%H%M)
BASEDIR=/var/log/baseline

mkdir -p $BASEDIR

# CPU/메모리/디스크 스냅샷
vmstat 1 5 > $BASEDIR/vmstat_$DATE.txt
iostat -x 1 5 > $BASEDIR/iostat_$DATE.txt
free -h > $BASEDIR/free_$DATE.txt
ps aux --sort=-%cpu > $BASEDIR/ps_cpu_$DATE.txt

# 소켓 통계
ss -s > $BASEDIR/ss_summary_$DATE.txt

# systemd 서비스 상태
systemctl list-units --state=failed > $BASEDIR/failed_units_$DATE.txt
```

---

## 8. 자주 하는 실수

| 실수 | 올바른 방법 |
|------|------------|
| `top`만 보고 CPU 높다고 바로 프로세스 킬 | `vmstat`으로 CPU vs I/O 병목 먼저 구분하고 원인 파악 후 조치 |
| 서비스 재시작으로 장애 덮기 | 재시작 전 `journalctl -u <서비스>`로 원인 로그 반드시 저장 |
| `free -h`에서 used만 보고 메모리 부족 판단 | `available` 컬럼이 실제 사용 가능 메모리 (buff/cache는 필요 시 반환됨) |
| OOM 후 메모리 늘리기만 함 | 누수 여부 확인 (`watch ps rss`)하고 근본 원인 해결 |
| cron이 안 되면 크론탭만 재확인 | `env -i`로 cron 환경과 동일하게 실행해보고 PATH 문제 확인 |
| D 상태 프로세스를 `kill -9`로 종료 시도 | D 상태는 SIGKILL도 무시함 — I/O 원인 제거 (NFS 언마운트 등)가 먼저 |
| `systemctl enable` 후 바로 `restart`로만 확인 | `systemctl is-enabled`로 활성화 확인 후 다음 부팅에서 실제 기동 확인 |
| 부하가 높을 때 여러 설정을 동시에 변경 | 한 번에 하나씩만 변경해야 어떤 변경이 효과 있었는지 알 수 있음 |

---

## 9. 트러블슈팅 체크리스트

시스템 장애 발생 시 순서대로 체크한다:

```
[ ] 1. 부하 확인: uptime — load average vs CPU 코어 수 비교
[ ] 2. CPU vs I/O: vmstat 1 5 — r/wa 컬럼으로 병목 유형 구분
[ ] 3. CPU 주범: ps aux --sort=-%cpu / top — 상위 프로세스 확인
[ ] 4. 메모리 상태: free -h — available 컬럼 기준으로 판단
[ ] 5. 메모리 주범: ps aux --sort=-%mem — 상위 프로세스 확인
[ ] 6. OOM 여부: dmesg | grep -i oom — OOM killer 발동 확인
[ ] 7. D 상태 프로세스: ps aux | awk '$8=="D"' — I/O 대기 프로세스
[ ] 8. 서비스 상태: systemctl --failed — 실패한 서비스 목록
[ ] 9. 커널 에러: dmesg -T -l err,crit — 하드웨어/드라이버 오류
[ ] 10. 시스템 로그: journalctl -p err -n 50 — 최근 에러 로그
```
