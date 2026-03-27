## 1. 개요

`cron`은 리눅스에서 주기적인 작업(배치, 백업, 정리 스크립트 등)을 자동 실행하는 스케줄러다.
`crontab` 명령어로 사용자별 스케줄을 등록하거나, `/etc/cron.d/`에 시스템 수준 작업을 배치한다.
실무에서는 로그 로테이션, DB 덤프, 지표 수집 스크립트 등에 광범위하게 쓰인다.

## 2. 설명

### 2.1 cron 표현식 구조

```
┌──────────── 분 (0-59)
│ ┌────────── 시 (0-23)
│ │ ┌──────── 일 (1-31)
│ │ │ ┌────── 월 (1-12 또는 jan-dec)
│ │ │ │ ┌──── 요일 (0-7, 0과 7 모두 일요일, 또는 sun-sat)
│ │ │ │ │
* * * * *  실행할_명령어
```

| 표현 | 의미 |
|---|---|
| `*` | 모든 값 |
| `*/5` | 5마다 (매 5분, 매 5시간 등) |
| `1,15,30` | 1분, 15분, 30분에 각각 실행 |
| `1-5` | 1~5 범위 |
| `@reboot` | 부팅 시 1회 실행 |
| `@daily` | 매일 자정 (`0 0 * * *`) |
| `@weekly` | 매주 일요일 자정 |
| `@monthly` | 매월 1일 자정 |

### 2.2 crontab 기본 사용법

```bash
# 현재 사용자 crontab 편집
crontab -e

# 현재 사용자 crontab 목록 확인
crontab -l

# 현재 사용자 crontab 삭제 (주의: 전체 삭제)
crontab -r

# 특정 사용자 crontab 확인 (root 권한 필요)
crontab -u ubuntu -l
```

### 2.3 실전 예제

```cron
# 매 5분마다 헬스체크 스크립트 실행
*/5 * * * * /opt/scripts/health_check.sh >> /var/log/health_check.log 2>&1

# 매일 새벽 2시에 DB 백업
0 2 * * * /opt/scripts/db_backup.sh >> /var/log/db_backup.log 2>&1

# 매주 일요일 새벽 3시에 오래된 로그 정리
0 3 * * 0 find /var/log/app -name "*.log" -mtime +30 -delete

# 매월 1일 새벽 1시에 디스크 사용량 리포트 메일 전송
0 1 1 * * df -h | mail -s "Disk Report" admin@company.com

# 부팅 시 환경 초기화 스크립트 1회 실행
@reboot /opt/scripts/init_env.sh

# 평일(월~금) 오전 9시에만 실행
0 9 * * 1-5 /opt/scripts/weekday_job.sh
```

### 2.4 cron 실행 환경 주의사항

cron은 사용자의 로그인 셸 환경(`~/.bashrc`, `~/.profile`)을 로드하지 않는다. 경로나 환경변수 문제로 인터랙티브 실행은 되지만 cron에서는 실패하는 경우가 많다.

```cron
# 잘못된 예: PATH 없어서 python3 못 찾음
0 * * * * python3 /opt/scripts/job.py

# 올바른 예 1: 절대 경로 사용
0 * * * * /usr/bin/python3 /opt/scripts/job.py

# 올바른 예 2: 환경변수 직접 지정
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 * * * * python3 /opt/scripts/job.py

# 올바른 예 3: bash -l 로 로그인 셸 로드
0 * * * * bash -l -c '/opt/scripts/job.py'
```

### 2.5 시스템 전체 cron 파일 구조

```bash
/etc/crontab          # 시스템 crontab (사용자 필드 있음)
/etc/cron.d/          # 패키지/서비스별 개별 cron 파일
/etc/cron.hourly/     # 매 시간 실행할 스크립트 모음
/etc/cron.daily/      # 매일 실행할 스크립트 모음
/etc/cron.weekly/     # 매주 실행할 스크립트 모음
/etc/cron.monthly/    # 매월 실행할 스크립트 모음
```

```bash
# /etc/cron.d/ 형식 (사용자 필드 필수)
# 분 시 일 월 요일 사용자 명령어
*/10 * * * * root /opt/scripts/monitor.sh >> /var/log/monitor.log 2>&1
```

### 2.6 Ansible로 crontab 관리

```yaml
# cron 작업을 Ansible로 IaC화하면 변경 이력 관리 가능
- name: Set up DB backup cron job
  ansible.builtin.cron:
    name: "Daily DB Backup"        # 작업 식별자 (변경/삭제 시 사용)
    minute: "0"
    hour: "2"
    job: "/opt/scripts/db_backup.sh >> /var/log/db_backup.log 2>&1"
    user: ubuntu
    state: present                 # absent로 변경 시 삭제

- name: Remove old cron job
  ansible.builtin.cron:
    name: "Old Backup Job"
    state: absent
```

### 2.7 cron 실행 여부 확인 및 디버깅

```bash
# cron 데몬 상태 확인
systemctl status cron       # Ubuntu/Debian
systemctl status crond      # RHEL/CentOS

# cron 실행 로그 확인
grep CRON /var/log/syslog           # Ubuntu
journalctl -u cron --since today    # systemd 환경

# 특정 작업 실행 여부 확인 (작업 이름으로 grep)
grep "db_backup" /var/log/syslog
```

## 3. 자주 하는 실수

| 실수 | 올바른 방법 |
|---|---|
| 스크립트가 인터랙티브에선 되는데 cron에서 안 됨 | 명령어 절대 경로 사용, PATH 직접 지정 |
| 출력이 어디로 가는지 몰라 디버깅 불가 | `>> /var/log/job.log 2>&1` 리다이렉션 필수 |
| `crontab -r` 를 `-e` 대신 잘못 입력해 전체 삭제 | 실행 전 `crontab -l` 로 백업 |
| 시간대(Timezone) 혼동 | `crontab -e` 상단에 `TZ=Asia/Seoul` 명시 |
| 스크립트에 실행 권한 없음 | `chmod +x /opt/scripts/job.sh` 확인 |
