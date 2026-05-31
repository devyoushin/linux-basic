## 1. 개요

리눅스 파일 권한(Permission)은 파일과 디렉토리에 대한 접근을 소유자(Owner), 그룹(Group), 기타(Others) 세 주체로 구분하여 읽기(r)/쓰기(w)/실행(x) 권한을 제어한다.
잘못된 권한 설정은 보안 취약점(웹 서버 설정 파일 노출, DB 크리덴셜 유출 등)으로 이어지므로 실무에서 매우 중요하다.

## 2. 설명

### 2.1 권한 체계 이해

```
-rwxr-xr--  1  ubuntu  www-data  1234  Jan 15 10:00  app.sh
│└─┬──┘└─┬─┘└─┬─┘
│  │     │    │
│  │     │    └── Others (기타 사용자): r-- = 읽기만
│  │     └─────── Group  (그룹):       r-x = 읽기+실행
│  └───────────── Owner  (소유자):     rwx = 읽기+쓰기+실행
└── 파일 타입: - 일반파일, d 디렉토리, l 심볼릭링크
```

| 권한 | 숫자 | 파일에서의 의미 | 디렉토리에서의 의미 |
|---|---|---|---|
| `r` (read) | 4 | 파일 읽기 | 목록 조회(`ls`) |
| `w` (write) | 2 | 파일 수정/삭제 | 파일 생성/삭제 |
| `x` (execute) | 1 | 파일 실행 | 디렉토리 진입(`cd`) |

**숫자 표기법 (Octal):**
- `755` = rwxr-xr-x (소유자 전체, 그룹/기타 읽기+실행)
- `644` = rw-r--r-- (소유자 읽기+쓰기, 그룹/기타 읽기만)
- `600` = rw------- (소유자 읽기+쓰기만, 그룹/기타 접근 불가)
- `777` = rwxrwxrwx (모두 전체 권한 - 운영 환경에서 절대 금지)

### 2.2 chmod - 권한 변경

```bash
# 숫자(octal) 표기법
chmod 755 script.sh       # 소유자: rwx, 그룹/기타: r-x
chmod 644 config.txt      # 소유자: rw-, 그룹/기타: r--
chmod 600 secret.key      # 소유자: rw-, 그룹/기타: 접근 불가
chmod 700 ~/.ssh          # 디렉토리: 소유자만 접근

# 기호 표기법 (u=user, g=group, o=others, a=all)
chmod +x deploy.sh        # 모두에게 실행 권한 추가
chmod g-w config.yml      # 그룹의 쓰기 권한 제거
chmod o-rwx secret.conf   # 기타 사용자 모든 권한 제거
chmod u=rw,g=r,o= file    # 정확한 권한 지정 (= 는 기존 권한 덮어씀)

# 재귀 적용
chmod -R 755 /var/www/html
chmod -R 640 /etc/app/conf.d/

# 파일에만 또는 디렉토리에만 적용 (find 조합)
find /var/www -type f -exec chmod 644 {} \;
find /var/www -type d -exec chmod 755 {} \;
```

### 2.3 chown - 소유자/그룹 변경

```bash
# 소유자 변경
chown ubuntu file.txt

# 소유자와 그룹 동시 변경
chown ubuntu:www-data /var/www/html/app.php

# 그룹만 변경
chown :www-data /var/www/html/upload/

# 재귀 적용
chown -R www-data:www-data /var/www/html/

# 심볼릭 링크 자체가 아닌 대상 파일 변경 (기본값)
chown -h ubuntu symlink   # 링크 자체 변경
```

### 2.4 umask - 기본 권한 마스크

새 파일/디렉토리 생성 시 적용되는 기본 권한을 제어한다.

```
파일 기본값(666) - umask = 실제 권한
디렉토리 기본값(777) - umask = 실제 권한

umask 022: 파일 → 644, 디렉토리 → 755 (일반적인 서버 기본값)
umask 027: 파일 → 640, 디렉토리 → 750 (보안 강화)
umask 077: 파일 → 600, 디렉토리 → 700 (민감 환경)
```

```bash
# 현재 umask 확인
umask
umask -S  # 기호 표기법으로 출력

# 임시 변경 (현재 셸 세션만)
umask 027

# 영구 변경
echo "umask 027" >> /etc/profile.d/umask.sh

# 특정 서비스 계정 umask 설정 (systemd 서비스)
# /etc/systemd/system/myapp.service
# [Service]
# UMask=0027
```

### 2.5 특수 권한 비트

#### SetUID (SUID) - 4000

파일 실행 시 소유자 권한으로 실행. `passwd` 명령어가 대표적 예시.

```bash
# SUID 설정
chmod u+s /usr/local/bin/special_tool
chmod 4755 /usr/local/bin/special_tool

# SUID 파일 검색 (보안 감사 시 필수)
find / -perm -4000 -type f 2>/dev/null
```

#### SetGID (SGID) - 2000

디렉토리에 설정 시, 그 안에 생성되는 파일이 디렉토리의 그룹을 상속. 팀 공유 디렉토리에 활용.

```bash
# 팀 공유 디렉토리 설정
groupadd devteam
mkdir /shared/devteam
chown root:devteam /shared/devteam
chmod 2775 /shared/devteam   # SGID + rwxrwxr-x
# 이제 devteam 멤버가 만드는 파일은 자동으로 devteam 그룹 소유
```

#### Sticky Bit - 1000

디렉토리에 설정 시, 자신의 파일만 삭제 가능. `/tmp`에 기본 적용.

```bash
# /tmp 권한 확인: drwxrwxrwt (마지막 t = sticky bit)
ls -la / | grep tmp

# 공유 업로드 디렉토리에 적용
chmod +t /var/www/uploads
chmod 1777 /var/www/uploads
```

### 2.6 실무 권한 설정 기준

| 대상 | 권장 권한 | 이유 |
|---|---|---|
| 웹 서비스 파일 | `644` | nginx/apache가 읽기만 필요 |
| 웹 서비스 디렉토리 | `755` | 진입 + 목록 조회 |
| 업로드 디렉토리 | `775` | 웹 프로세스 쓰기 필요 |
| 설정 파일 (크리덴셜 포함) | `600` | 소유자만 읽기/쓰기 |
| 실행 스크립트 | `755` | 소유자 전체, 그룹/기타 실행 |
| SSH 개인키 | `600` | 필수 (느슨하면 SSH 거부) |
| `~/.ssh/` 디렉토리 | `700` | 필수 (느슨하면 SSH 거부) |

### 2.7 Ansible로 권한 관리 IaC화

```yaml
- name: Deploy app configuration
  hosts: webservers
  tasks:
    - name: Create app config directory
      ansible.builtin.file:
        path: /etc/myapp
        state: directory
        owner: root
        group: myapp
        mode: '0750'

    - name: Deploy secrets config
      ansible.builtin.template:
        src: secrets.conf.j2
        dest: /etc/myapp/secrets.conf
        owner: root
        group: myapp
        mode: '0640'    # root 읽기/쓰기, myapp 그룹 읽기만

    - name: Set web root ownership
      ansible.builtin.file:
        path: /var/www/html
        state: directory
        owner: www-data
        group: www-data
        mode: '0755'
        recurse: yes
```

### 2.8 보안 감사 명령어

```bash
# world-writable 파일 검색 (누구나 쓸 수 있는 파일 - 위험)
find / -perm -0002 -type f 2>/dev/null

# SUID/SGID 파일 검색
find / -perm -4000 -o -perm -2000 2>/dev/null | sort

# 소유자 없는 파일 검색 (삭제된 계정의 파일)
find / -nouser -o -nogroup 2>/dev/null

# 특정 디렉토리 권한 빠른 확인
ls -laR /etc/app/ | grep -E "^-.*[rwx]{3}" | head -20
```

## 3. 자주 하는 실수

| 실수 | 올바른 방법 |
|---|---|
| 웹 루트 전체 `chmod 777` | `755`(디렉토리) + `644`(파일), 업로드만 `775` |
| 크리덴셜 파일 권한 `644` | 반드시 `600` (다른 사용자 읽기 차단) |
| `chown -R root:root` 후 서비스 실패 | 서비스 실행 계정(www-data 등) 소유로 설정 |
| SUID 비트를 운영 스크립트에 남용 | SUID는 최소한으로, sudo 정책으로 대체 권장 |
| `umask` 설정을 `.bashrc`에만 추가 | `/etc/profile.d/`에 추가해야 모든 셸에 적용 |
