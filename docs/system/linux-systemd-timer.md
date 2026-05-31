# linux-systemd-timer.md — systemd 타이머 (현대적 cron 대체)

## 1. 개요

systemd 타이머는 crontab을 대체하는 현대적 작업 스케줄링 메커니즘이다. cron과 달리 systemd의 로깅(journald), 의존성 관리, 실패 감지, 리소스 제한이 모두 통합된다. SRE 관점에서 중요한 차이는 **동일 작업의 중복 실행 방지**, **작업 실패 시 알림**, **정확한 실행 이력 추적**이 cron 없이도 가능하다는 점이다.

---

## 2. 설명

### 2.1 타이머 vs cron 비교

| 항목 | crontab | systemd timer |
|------|---------|---------------|
| 실행 로그 | `/var/log/cron` (제한적) | journald (완전한 stdout/stderr) |
| 중복 실행 방지 | 별도 구현 필요 | `Type=oneshot` 기본 직렬화 |
| 실패 감지/재시도 | 없음 | `Restart=on-failure` |
| 리소스 제한 | 없음 | cgroup 기반 CPU/메모리 제한 |
| 의존성 | 없음 | `After=`, `Requires=` |
| 모니터링 | 어려움 | `systemctl list-timers` |
| 부팅 후 지연 실행 | 어려움 | `OnBootSec=` |
| 마지막 실행 시각 | 없음 | `systemctl status` |

### 2.2 타이머 생성 기본 구조

타이머는 항상 **두 개의 파일**로 구성된다:
- `.timer` 파일: 실행 시각 정의
- `.service` 파일: 실제 실행할 작업 정의

```ini
# /etc/systemd/system/backup.service
[Unit]
Description=Daily Database Backup

[Service]
Type=oneshot                          # 일회성 작업 (완료 후 종료)
User=backup                           # 전용 계정으로 실행
ExecStart=/opt/scripts/db-backup.sh
# 리소스 제한
CPUQuota=50%                          # CPU 50% 이하
MemoryMax=1G
# 실패 시 재시도
Restart=on-failure
RestartSec=60s
StartLimitBurst=3

# [Install] 섹션 없음 — 타이머가 이 서비스를 기동함
```

```ini
# /etc/systemd/system/backup.timer
[Unit]
Description=Daily Database Backup Timer
Requires=backup.service               # 연결된 서비스 명시

[Timer]
OnCalendar=*-*-* 02:00:00             # 매일 오전 2시
RandomizedDelaySec=300                # ±5분 랜덤 지연 (스탬피드 방지)
Persistent=true                       # 시스템 다운 중 놓친 실행을 복구 후 즉시 수행
AccuracySec=1s                        # 정밀도 (기본 60s)

[Install]
WantedBy=timers.target
```

```bash
# 활성화 및 시작
systemctl daemon-reload
systemctl enable --now backup.timer

# 상태 확인
systemctl status backup.timer
```

### 2.3 타이머 시간 표현식

#### OnCalendar (달력 기반)

```ini
# cron 표현식과 비교
OnCalendar=minutely                   # * * * * *
OnCalendar=hourly                     # 0 * * * *
OnCalendar=daily                      # 0 0 * * *
OnCalendar=weekly                     # 0 0 * * 0
OnCalendar=monthly                    # 0 0 1 * *

# 세부 표현식: DayOfWeek Year-Month-Day HH:MM:SS
OnCalendar=Mon-Fri *-*-* 09:00:00     # 평일 오전 9시
OnCalendar=*-*-* *:00,30:00           # 매 시 0분, 30분
OnCalendar=*-*-1 00:00:00             # 매월 1일 자정
OnCalendar=Sat *-*-* 03:00:00         # 매주 토요일 오전 3시

# 표현식 검증
systemd-analyze calendar "Mon-Fri *-*-* 09:00:00"
```

#### OnBoot / OnActiveSec (상대 시간 기반)

```ini
# 부팅 후 5분 뒤 실행
OnBootSec=5min

# 타이머 활성화 후 1시간마다 반복
OnActiveSec=1h

# 부팅 후 10분 뒤 시작, 이후 6시간마다 반복
OnBootSec=10min
OnUnitActiveSec=6h
```

### 2.4 타이머 모니터링

```bash
# 전체 타이머 목록 (다음 실행 시각 포함)
systemctl list-timers

# 비활성 포함 전체 타이머
systemctl list-timers --all

# 특정 타이머 상세 상태
systemctl status backup.timer

# 마지막 실행 로그 확인
journalctl -u backup.service -n 50

# 실행 이력 (시작/종료 시각)
journalctl -u backup.service --since "7 days ago" | grep -E "Started|Finished|Failed"
```

### 2.5 실전 패턴

#### 로그 정리 타이머

```ini
# /etc/systemd/system/log-cleanup.service
[Unit]
Description=Clean old application logs

[Service]
Type=oneshot
ExecStart=/usr/bin/find /var/log/myapp -name "*.log" -mtime +30 -delete
ExecStart=/usr/bin/journalctl --vacuum-time=30d
```

```ini
# /etc/systemd/system/log-cleanup.timer
[Unit]
Description=Weekly log cleanup

[Timer]
OnCalendar=Sun *-*-* 01:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

#### 여러 서버 스탬피드 방지 (RandomizedDelaySec)

```ini
# /etc/systemd/system/health-report.timer
[Timer]
OnCalendar=*-*-* *:00:00              # 매 시 정각 의도
RandomizedDelaySec=300                # 0~5분 랜덤 지연 → 동시 접속 분산
```

#### 조건부 실행 (서비스가 실행 중일 때만)

```ini
# /etc/systemd/system/cache-warm.service
[Unit]
Description=Cache Warmup (only if myapp is running)
ConditionPathExists=/var/run/myapp.pid    # PID 파일 있을 때만 실행

[Service]
Type=oneshot
ExecStart=/opt/scripts/warm-cache.sh
```

#### 실패 시 알림 타이머 (OnFailure)

```ini
# /etc/systemd/system/backup.service
[Unit]
Description=Backup Job
OnFailure=notify-failure@%n.service      # 실패 시 알림 서비스 호출

[Service]
Type=oneshot
ExecStart=/opt/scripts/backup.sh
```

```ini
# /etc/systemd/system/notify-failure@.service
[Unit]
Description=Send failure notification for %i

[Service]
Type=oneshot
ExecStart=/usr/bin/curl -X POST https://hooks.slack.com/... \
  -d '{"text": "systemd service %i failed on '"$(hostname)"'"}'
```

### 2.6 기존 crontab → systemd 타이머 마이그레이션

```bash
# crontab 현재 내용 확인
crontab -l

# 변환 예시
# cron:   0 2 * * * /opt/scripts/backup.sh
# timer:  OnCalendar=*-*-* 02:00:00

# 마이그레이션 후 cron 엔트리 주석 처리 (즉시 삭제보다 안전)
```

### 2.7 Ansible로 타이머 배포

```yaml
- name: Deploy backup service unit
  copy:
    dest: /etc/systemd/system/backup.service
    content: |
      [Unit]
      Description=Daily Backup
      [Service]
      Type=oneshot
      User=backup
      ExecStart=/opt/scripts/backup.sh

- name: Deploy backup timer unit
  copy:
    dest: /etc/systemd/system/backup.timer
    content: |
      [Unit]
      Description=Daily Backup Timer
      [Timer]
      OnCalendar=*-*-* 02:00:00
      Persistent=true
      [Install]
      WantedBy=timers.target

- name: Enable and start backup timer
  systemd:
    name: backup.timer
    enabled: yes
    state: started
    daemon_reload: yes
```

---

## 3. 자주 하는 실수

| 실수 | 올바른 방법 |
|------|------------|
| `.timer` 파일만 만들고 `.service` 파일 생략 | 반드시 동일 이름의 `.service` 파일 필요 |
| `systemctl enable backup.service` 직접 활성화 | 타이머를 `enable` 해야 함: `systemctl enable backup.timer` |
| `Persistent=true` 미설정 → 다운 중 작업 누락 | 중요 배치 작업은 항상 `Persistent=true` |
| 시간대(Timezone) 고려 안 함 | `OnCalendar`는 로컬 시간대 기준. UTC로 명시하려면 `z` 접미사 사용 |
| 여러 서버 동시 실행으로 DB/API 과부하 | `RandomizedDelaySec` 으로 스탬피드 방지 |
| 실패 이메일/알림 없음 | `OnFailure=` 핸들러 서비스 연결 |
| 타이머 상태 확인을 서비스로 하려는 시도 | `systemctl status backup.timer`로 타이머 자체를 확인 |
