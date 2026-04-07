# linux-audit.md — auditd: 시스템 콜·파일 접근·명령어 감사 로깅

## 1. 개요

auditd는 Linux 커널의 감사 서브시스템(audit subsystem)과 통신하며, 파일 접근·시스템 콜·사용자 명령어를 추적하는 보안 감사 데몬이다. PCI-DSS, HIPAA, CIS 벤치마크 등 보안 규제 환경에서 필수 컴포넌트로, "누가 언제 무엇을 했는가"를 커널 레벨에서 기록한다. AWS CloudTrail이 API 레벨 감사를 담당한다면, auditd는 OS 레벨 내부 활동을 담당한다.

---

## 2. 설명

### 2.1 auditd 아키텍처

```
┌─────────────────────────────────────────────────────────────────┐
│  User Space                                                      │
│                                                                  │
│   auditctl ──────────────────────────────────┐                  │
│   (규칙 설정)                                  │                  │
│                                               ▼                  │
│   ┌──────────┐    ┌──────────────┐    ┌────────────────┐        │
│   │  auditd  │◄───│  audit queue │◄───│ kernel audit   │        │
│   │ (데몬)   │    │  (netlink)   │    │ subsystem      │        │
│   └────┬─────┘    └──────────────┘    └────────────────┘        │
│        │                                       ▲                 │
│        │         ┌──────────────┐              │                 │
│        ├────────►│   audisp     │   syscall / file access /      │
│        │         │ (플러그인)   │   user login 이벤트            │
│        │         └──────┬───────┘                                │
│        │                │                                        │
│        ▼                ▼                                        │
│  /var/log/audit/    syslog / SIEM                                │
│  audit.log          (rsyslog, Splunk, CloudWatch)                │
└─────────────────────────────────────────────────────────────────┘

커널 이벤트 흐름:
  시스템 콜 발생 → 커널 audit 훅 → netlink 소켓 → auditd → audit.log
```

**주요 컴포넌트:**

| 컴포넌트 | 역할 |
|---|---|
| `auditd` | 감사 이벤트 수신·저장 데몬 |
| `auditctl` | 감사 규칙 추가/삭제/조회 |
| `ausearch` | 감사 로그 검색 |
| `aureport` | 감사 로그 통계 리포트 |
| `audisp` | 감사 이벤트를 외부 시스템으로 전달하는 플러그인 프레임워크 |

### 2.2 설치 및 기본 설정

```bash
# 설치 (RHEL/CentOS/Amazon Linux)
yum install -y audit audit-libs

# 설치 (Ubuntu/Debian)
apt-get install -y auditd audispd-plugins

# 서비스 시작 및 활성화
systemctl enable --now auditd

# auditd 메인 설정 파일
cat /etc/audit/auditd.conf
```

```ini
# /etc/audit/auditd.conf 주요 설정
log_file = /var/log/audit/audit.log   # 로그 파일 경로
log_format = RAW                       # 로그 포맷 (RAW 또는 ENRICHED)
max_log_file = 100                     # 파일당 최대 크기 (MB)
max_log_file_action = ROTATE           # 크기 초과 시: ROTATE/SYSLOG/SUSPEND/KEEP_LOGS
num_logs = 10                          # 보관할 로테이션 파일 수
space_left = 500                       # 남은 공간(MB) 이하 시 경고
space_left_action = SYSLOG             # 경고 동작
admin_space_left = 100                 # 심각한 공간 부족 임계값
admin_space_left_action = SUSPEND      # 감사 일시 중지 (저장 공간 보호)
```

### 2.3 auditctl로 규칙 추가

```bash
# ── 파일 감시 (-w): 특정 파일/디렉토리 접근 감시
# -w: 감시 경로
# -p: 감시할 퍼미션 (r=읽기, w=쓰기, x=실행, a=속성변경)
# -k: 검색용 키 (ausearch에서 사용)

auditctl -w /etc/passwd -p wa -k passwd_changes
#  /etc/passwd 수정(w) 및 속성변경(a) 시 감사 로그 기록

auditctl -w /etc/sudoers -p wa -k sudoers_changes
#  sudoers 파일 수정 감시

auditctl -w /etc/ssh/sshd_config -p wa -k sshd_config
#  SSH 설정 파일 감시

auditctl -w /var/log/auth.log -p wa -k auth_log_tamper
#  로그 파일 변조 감지

auditctl -w /bin/su -p x -k su_exec
#  su 명령어 실행 감시

# 디렉토리 감시 (재귀 없음, 해당 디렉토리 내 파일 목록 변경만)
auditctl -w /etc/ -p wa -k etc_changes
```

```bash
# ── 시스템 콜 감시 (-a): 특정 syscall 호출 감사
# -a: action,list (action: always/never, list: task/entry/exit/exclude)
# -S: 시스템 콜 이름 또는 번호
# -F: 필터 조건 (uid, pid, auid 등)

# 권한 상승 관련 syscall 감시
auditctl -a always,exit -F arch=b64 -S setuid -S setgid -k privilege_escalation
auditctl -a always,exit -F arch=b64 -S execve -k command_execution
#  모든 명령어 실행 감시 (주의: 로그 양이 매우 많아짐)

# 특정 사용자(uid=1000)의 파일 삭제 감시
auditctl -a always,exit -F arch=b64 -S unlink -S rmdir \
    -F uid=1000 -k file_deletion_uid1000

# 네트워크 설정 변경 감시
auditctl -a always,exit -F arch=b64 -S sethostname -S setdomainname \
    -k network_modifications

# 모듈 로드/언로드 감시 (루트킷 탐지)
auditctl -a always,exit -F arch=b64 -S init_module -S delete_module \
    -k kernel_modules
```

```bash
# 현재 적용된 규칙 확인
auditctl -l

# 감사 상태 확인
auditctl -s

# 규칙 삭제
auditctl -W /etc/passwd -p wa -k passwd_changes  # 특정 규칙 삭제
auditctl -D                                        # 모든 규칙 삭제
```

### 2.4 영구 규칙: /etc/audit/rules.d/

```bash
# auditctl -l 로 확인한 규칙은 재부팅 시 소멸
# 영구 적용: /etc/audit/rules.d/*.rules 파일에 작성

# /etc/audit/rules.d/99-custom.rules
# -D: 기존 규칙 초기화
-D

# 버퍼 크기 설정 (이벤트 폭주 시 큐 오버플로우 방지)
-b 8192

# 실패 처리: 0=silent, 1=printk, 2=panic
-f 1

# 파일 감시
-w /etc/passwd -p wa -k passwd_changes
-w /etc/shadow -p wa -k shadow_changes
-w /etc/group -p wa -k group_changes
-w /etc/gshadow -p wa -k gshadow_changes
-w /etc/sudoers -p wa -k sudoers_changes
-w /etc/ssh/sshd_config -p wa -k sshd_config

# 시스템 콜 감시
-a always,exit -F arch=b64 -S setuid -S setgid -k privilege_escalation
-a always,exit -F arch=b64 -S init_module -S delete_module -k kernel_modules
-a always,exit -F arch=b64 -S sethostname -S setdomainname -k network_mods

# 규칙 고정 (이 이후 auditctl로 규칙 변경 불가 - 보안 강화)
# -e 2
```

```bash
# 규칙 파일 재로드
augenrules --load   # rules.d 파일들을 합쳐서 audit.rules 생성 후 적용
# 또는
service auditd restart
```

### 2.5 ausearch와 aureport로 로그 분석

```bash
# ── ausearch: 특정 조건으로 감사 로그 검색
ausearch -k passwd_changes              # 키로 검색
ausearch -k passwd_changes --interpret  # UID를 사용자명으로 해석

ausearch -ui 1000                       # 특정 UID의 이벤트
ausearch -ua www-data                   # 특정 사용자명의 이벤트
ausearch -x sudo                        # 특정 실행파일 관련 이벤트
ausearch -sc execve                     # 특정 syscall 이벤트
ausearch -ts today                      # 오늘 이벤트 (-ts: 시작 시간)
ausearch -ts 2024-01-01 -te 2024-01-31  # 기간 검색
ausearch -m USER_LOGIN -sv no           # 로그인 실패 이벤트

# JSON 출력 (SIEM 연동)
ausearch -k passwd_changes --format json

# ── aureport: 통계 리포트
aureport                         # 전체 요약
aureport --auth                  # 인증 이벤트 통계
aureport --login                 # 로그인 이벤트 통계
aureport --failed                # 실패 이벤트 통계
aureport --file                  # 파일 접근 이벤트 통계
aureport --syscall                # syscall 이벤트 통계
aureport --summary               # 이벤트 유형별 요약
aureport -ts today --summary     # 오늘 이벤트 요약
```

### 2.6 실전 규칙: sudo 추적, /etc/passwd 수정 감지, SSH 실패

```bash
# /etc/audit/rules.d/90-security-monitoring.rules

# ── sudo 사용 추적
-w /usr/bin/sudo -p x -k sudo_execution
-w /etc/sudoers -p wa -k sudoers_modification
-w /etc/sudoers.d/ -p wa -k sudoers_d_modification

# ── 계정 관리 감지
-w /etc/passwd -p wa -k account_changes
-w /etc/shadow -p wa -k account_changes
-w /etc/group -p wa -k account_changes
-w /usr/sbin/useradd -p x -k user_management
-w /usr/sbin/userdel -p x -k user_management
-w /usr/sbin/usermod -p x -k user_management
-w /usr/sbin/groupadd -p x -k user_management
-w /usr/bin/passwd -p x -k password_change

# ── SSH 관련
-w /etc/ssh/sshd_config -p wa -k sshd_config_change
-w /root/.ssh/ -p wa -k root_ssh_key
-w /home/ -p wa -k home_ssh    # .ssh 디렉토리 변경 감지

# ── 네트워크 설정 변경
-a always,exit -F arch=b64 -S sethostname -k hostname_change
-w /etc/hosts -p wa -k hosts_file
-w /etc/resolv.conf -p wa -k dns_config

# ── 시스템 부팅/종료 관련
-w /sbin/shutdown -p x -k system_shutdown
-w /sbin/reboot -p x -k system_reboot
-w /sbin/halt -p x -k system_halt

# ── crontab 변경 감시 (지속성 유지 기법 탐지)
-w /etc/crontab -p wa -k crontab_change
-w /etc/cron.d/ -p wa -k cron_d
-w /var/spool/cron/ -p wa -k user_crontab
```

```bash
# sudo 사용 실시간 모니터링
ausearch -k sudo_execution --interpret -ts today | grep -E "cmd|uid|success"

# SSH 로그인 실패 분석
ausearch -m USER_AUTH -sv no --interpret -ts today

# 오늘 /etc/passwd 수정한 사용자
ausearch -k account_changes --interpret -ts today
```

### 2.7 CIS 벤치마크 기반 auditd 규칙

CIS (Center for Internet Security) Linux Benchmark에서 권고하는 핵심 규칙:

```bash
# /etc/audit/rules.d/50-cis.rules
# CIS Amazon Linux 2 Benchmark v1.0 기반

# CIS 4.1.4: 날짜/시간 변경 감사
-a always,exit -F arch=b64 -S adjtimex -S settimeofday -k time-change
-a always,exit -F arch=b64 -S clock_settime -k time-change
-w /etc/localtime -p wa -k time-change

# CIS 4.1.5: 사용자/그룹 변경 감사
-w /etc/group -p wa -k identity
-w /etc/passwd -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/security/opasswd -p wa -k identity

# CIS 4.1.6: 네트워크 환경 변경 감사
-a always,exit -F arch=b64 -S sethostname -S setdomainname -k system-locale
-w /etc/issue -p wa -k system-locale
-w /etc/issue.net -p wa -k system-locale
-w /etc/hosts -p wa -k system-locale
-w /etc/sysconfig/network -p wa -k system-locale

# CIS 4.1.7: MAC 정책 변경 감사 (SELinux/AppArmor)
-w /etc/selinux/ -p wa -k MAC-policy

# CIS 4.1.8: 로그인/로그아웃 이벤트
-w /var/log/faillog -p wa -k logins
-w /var/log/lastlog -p wa -k logins
-w /var/log/tallylog -p wa -k logins

# CIS 4.1.9: 세션 초기화 이벤트
-w /var/run/utmp -p wa -k session
-w /var/log/wtmp -p wa -k logins
-w /var/log/btmp -p wa -k logins

# CIS 4.1.10: 재량적 접근 제어 권한 수정 감사
-a always,exit -F arch=b64 -S chmod -S fchmod -S fchmodat -k perm_mod
-a always,exit -F arch=b64 -S chown -S fchown -S lchown -S fchownat -k perm_mod
-a always,exit -F arch=b64 -S setxattr -S lsetxattr -S fsetxattr -k perm_mod
-a always,exit -F arch=b64 -S removexattr -S lremovexattr -S fremovexattr -k perm_mod

# CIS 4.1.11: 접근 제어 우회 시도
-a always,exit -F arch=b64 -S creat -S open -S openat -S truncate -F exit=-EACCES \
    -k access
-a always,exit -F arch=b64 -S creat -S open -S openat -S truncate -F exit=-EPERM \
    -k access

# CIS 4.1.13: SUID/SGID 실행 파일 사용
-a always,exit -F arch=b64 -S execve -C uid!=euid -F euid=0 -k setuid
-a always,exit -F arch=b64 -S execve -C gid!=egid -F egid=0 -k setgid

# CIS 4.1.14: 파일 시스템 마운트
-a always,exit -F arch=b64 -S mount -k mounts

# CIS 4.1.15: 파일 삭제
-a always,exit -F arch=b64 -S unlink -S unlinkat -S rename -S renameat \
    -F auid>=1000 -F auid!=-1 -k delete

# CIS 4.1.16: sudoers 변경
-w /etc/sudoers -p wa -k scope
-w /etc/sudoers.d/ -p wa -k scope

# CIS 4.1.17: sudo 로그
-w /var/log/sudo.log -p wa -k actions

# CIS 4.1.18: 커널 모듈 로드/언로드
-w /sbin/insmod -p x -k modules
-w /sbin/rmmod -p x -k modules
-w /sbin/modprobe -p x -k modules
-a always,exit -F arch=b64 -S init_module -S delete_module -k modules

# 규칙 고정 (booting 이후 변경 불가, 보안 강화 시 활성화)
# -e 2
```

### 2.8 AWS CloudTrail과 auditd의 역할 분담

```
┌─────────────────────────────────────────────────────┐
│              감사 레이어 구조                         │
├─────────────────────────────────────────────────────┤
│ AWS CloudTrail                                       │
│   - AWS API 호출 (EC2 생성, S3 업로드, IAM 변경 등) │
│   - 콘솔/CLI/SDK 레벨 감사                           │
│   - 리전 간, 계정 간 통합 가능                       │
├─────────────────────────────────────────────────────┤
│ auditd (OS 레벨)                                     │
│   - 로컬 파일 접근 (/etc/passwd, 로그 파일 등)       │
│   - 시스템 콜 (execve, open, chmod 등)              │
│   - 로컬 사용자 명령어 실행                           │
│   - SSH 로그인/실패                                  │
│   - CloudTrail이 볼 수 없는 EC2 내부 활동            │
└─────────────────────────────────────────────────────┘
```

```bash
# audisp-remote로 감사 로그를 중앙 서버로 전송
# /etc/audisp/plugins.d/au-remote.conf
active = yes
direction = out
path = /sbin/audisp-remote
type = always
args = <중앙서버IP>

# CloudWatch Logs로 전송하는 방법 (Amazon Linux 2)
# CloudWatch Agent 설정에 audit.log 추가
cat >> /opt/aws/amazon-cloudwatch-agent/bin/config.json << 'EOF'
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/audit/audit.log",
            "log_group_name": "/ec2/audit",
            "log_stream_name": "{instance_id}"
          }
        ]
      }
    }
  }
}
EOF
```

### 2.9 Ansible로 auditd 규칙 배포

```yaml
# roles/auditd/tasks/main.yml
---
- name: auditd 패키지 설치
  package:
    name:
      - audit
      - audit-libs
    state: present

- name: auditd 메인 설정 파일 배포
  template:
    src: auditd.conf.j2
    dest: /etc/audit/auditd.conf
    owner: root
    group: root
    mode: '0640'
  notify: restart auditd

- name: CIS 기반 감사 규칙 배포
  copy:
    src: "{{ item }}"
    dest: "/etc/audit/rules.d/{{ item }}"
    owner: root
    group: root
    mode: '0640'
  loop:
    - 50-cis.rules
    - 90-security-monitoring.rules
  notify: reload audit rules

- name: auditd 서비스 활성화
  systemd:
    name: auditd
    enabled: yes
    state: started

handlers:
  - name: restart auditd
    systemd:
      name: auditd
      state: restarted

  - name: reload audit rules
    command: augenrules --load
    # auditd 재시작 없이 규칙만 재로드 가능
```

---

## 3. 자주 하는 실수

| 실수 | 올바른 방법 |
|---|---|
| `/etc/audit/audit.rules` 직접 편집 | `rules.d/*.rules` 파일에 작성 후 `augenrules --load`로 통합 적용 |
| `auditctl -a` 규칙이 재부팅 후 소멸 | `/etc/audit/rules.d/`에 규칙 파일 저장 |
| `-a always,exit`에 `arch` 필터 누락 | 32bit/64bit syscall 번호가 다름. `-F arch=b64`와 `-F arch=b32` 모두 추가 |
| 로그 공간 부족으로 auditd 중단 | `admin_space_left_action = SUSPEND` 대신 `SYSLOG`로 설정하거나 로그 로테이션 주기 조정 |
| `execve` syscall 전체 감시 | 로그 폭주 유발. 특정 uid 또는 디렉토리로 필터링 (`-F auid>=1000` 등) |
| `-e 2` (규칙 고정) 설정 후 수정 불가 | 재부팅 전까지 규칙 변경 불가능. 운영 환경에서 신중히 적용 |
| `ausearch` 결과 해석 없이 원시 로그 분석 | `--interpret` 옵션으로 UID→사용자명, syscall 번호→이름으로 변환 |
| CloudTrail만으로 충분하다고 가정 | EC2 내부 파일 접근·로컬 명령어는 CloudTrail 비가시 영역. auditd 병행 필수 |
