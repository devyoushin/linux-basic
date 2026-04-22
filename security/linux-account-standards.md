## 1. 개요

Linux 시스템에서 계정(User)과 그룹(Group) 관리의 표준을 정의하지 않으면, 시간이 지남에 따라 UID 충돌, 권한 혼재, 감사 추적 불가 등의 문제가 발생한다.
본 문서는 엔터프라이즈 환경에서 반복 가능하고 일관된 계정 관리를 위한 표준을 정의한다.

---

## 2. UID/GID 범위 표준

### 2.1 범위 할당 테이블

| 범위 | 용도 | 예시 |
|---|---|---|
| `0` | root (절대 변경 금지) | `root` |
| `1 ~ 99` | OS 예약 시스템 계정 | `daemon`, `bin`, `sys` |
| `100 ~ 499` | 패키지 관리자가 생성하는 서비스 계정 | `nginx`, `mysql`, `nobody` |
| `500 ~ 999` | 운영팀이 생성하는 서비스/애플리케이션 계정 | `app-api`, `deploy-agent` |
| `1000 ~ 59999` | 일반 사용자 계정 | `john.doe`, `ci-runner` |
| `60000 ~ 65534` | 임시/테스트 계정 (분기별 감사 후 삭제) | `temp-contractor` |
| `65534` | `nobody` — 신뢰 불가 프로세스용 (고정) | NFS anonymous mapping |

> **주의**: UID `0`은 root와 동일한 권한이다. UID 0 계정이 root 외에 존재하면 즉시 조사한다.

```bash
# UID 0 계정이 여러 개인지 확인
awk -F: '$3 == 0 { print $1 }' /etc/passwd

# 현재 UID 범위 확인 (useradd 기본값)
grep -E "^UID_(MIN|MAX)" /etc/login.defs
```

### 2.2 멀티 서버 환경에서 UID/GID 일관성 유지

NFS, EFS 마운트 환경에서 서버마다 UID가 다르면 파일 소유자가 뒤바뀐다.

```bash
# 권장: 서비스 계정은 --uid 로 고정 생성
useradd --uid 501 --gid 501 --no-create-home --shell /sbin/nologin app-api

# Ansible로 전 서버 일괄 적용
# tasks:
#   - name: Create app-api service account with fixed UID
#     user:
#       name: app-api
#       uid: 501
#       group: app-api
#       shell: /sbin/nologin
#       create_home: false
```

---

## 3. 네이밍 컨벤션

### 3.1 사람 계정 (Human User)

```
형식: {이름이니셜}{성} 또는 {firstname.lastname}
예시: jdoe, john.doe
```

| 규칙 | 설명 |
|---|---|
| 소문자만 사용 | 대문자 혼용 금지 |
| 특수문자 금지 (`-`, `.` 예외) | `john_doe` 보다 `john.doe` 권장 |
| 20자 이내 | `/etc/passwd` 필드 호환성 |
| 공유 계정 금지 | 1인 1계정 원칙, 감사 추적 필수 |

### 3.2 서비스/애플리케이션 계정 (Service Account)

```
형식: {서비스명}-{역할}
예시: app-api, deploy-agent, db-backup, kafka-broker
```

| 규칙 | 설명 |
|---|---|
| 하이픈(`-`) 구분자 사용 | 서비스명과 역할을 명확히 구분 |
| 로그인 불가 설정 필수 | `shell: /sbin/nologin` |
| 홈 디렉토리 없음 원칙 | `--no-create-home` (예외: 설정 파일 필요 시 `/var/lib/{service}`) |
| 비밀번호 잠금 | `passwd -l {account}` |

```bash
# 올바른 서비스 계정 생성
useradd \
  --uid 502 \
  --gid 502 \
  --system \                   # 시스템 계정 플래그
  --no-create-home \
  --shell /sbin/nologin \
  --comment "API 서비스 계정" \
  app-api

# 생성 후 검증
getent passwd app-api
# app-api:x:502:502:API 서비스 계정:/dev/null:/sbin/nologin
```

### 3.3 그룹 네이밍

```
형식: {팀명} 또는 {서비스명} 또는 {역할}
예시: dev-team, ops-team, app-api, docker-users, sudo-approved
```

---

## 4. 그룹 관리 표준

### 4.1 그룹 계층 구조 (권장 패턴)

```
sudo-approved          ← sudo 권한 부여 그룹 (최소화)
├── senior-ops
└── infra-admin

dev-team               ← 개발팀 기본 그룹
├── john.doe
├── jane.smith
└── ci-runner          ← CI 서비스 계정

docker-users           ← Docker 소켓 접근 그룹
└── app-api

app-api                ← 서비스 계정 전용 그룹 (Primary GID)
```

```bash
# 그룹 생성
groupadd --gid 1001 dev-team

# 사용자를 여러 그룹에 추가 (Primary 그룹 유지하며 보조 그룹 추가)
usermod -aG dev-team,docker-users john.doe

# 특정 사용자의 그룹 확인
id john.doe
groups john.doe

# 그룹 멤버 전체 확인
getent group dev-team
```

### 4.2 sudo 권한 관리

> **주의**: `ALL=(ALL) NOPASSWD:ALL` 설정은 운영 환경에서 절대 금지한다.

```bash
# /etc/sudoers.d/ops-policy (visudo로 편집)

# 패턴 1: 그룹 단위로 특정 명령만 허용
%sudo-approved ALL=(ALL) ALL

# 패턴 2: 특정 명령만 NOPASSWD 허용 (systemctl 재시작 등)
%dev-team ALL=(ALL) NOPASSWD: /bin/systemctl restart app-api, /bin/journalctl -u app-api

# 패턴 3: 서비스 계정에는 sudo 부여 금지
# (서비스 계정이 sudo를 쓴다면 설계 오류)
```

---

## 5. 계정 수명주기 관리

### 5.1 생성 → 운영 → 만료 흐름

```
신청/승인
   │
   ▼
계정 생성 (useradd + SSH 키 등록)
   │
   ▼
운영 (정기 감사: 분기별)
   │
   ├── 퇴사/계약 종료 → 즉시 비활성화 → 30일 후 삭제
   └── 임시 계정     → 만료일 설정 (--expiredate)
```

```bash
# 계정 만료일 설정 (계약직/외주)
useradd --expiredate 2026-06-30 temp-contractor

# 계정 즉시 잠금 (퇴사 처리)
usermod --lock john.doe              # 비밀번호 잠금
usermod --expiredate 1 john.doe      # 로그인 즉시 만료

# SSH 키 무효화 (authorized_keys 제거)
# Ansible 사용 시:
# - name: Revoke SSH access
#   authorized_key:
#     user: john.doe
#     state: absent
#     key: "{{ old_public_key }}"

# 30일 후 계정 삭제
userdel --remove john.doe            # 홈 디렉토리 포함 삭제
```

### 5.2 분기별 계정 감사 체크리스트

```bash
# 1. 90일 이상 로그인 없는 계정 확인
lastlog | awk 'NR>1 && $0 !~ /Never/ { print }' | \
  awk -v d="$(date -d '90 days ago' '+%b %d %Y')" '$5" "$6" "$9 < d'

# 2. 패스워드 없는 계정 확인 (보안 위협)
awk -F: '($2 == "" || $2 == "!") { print $1 }' /etc/shadow

# 3. sudo 권한 보유 계정 전체 목록
grep -E "^%|^[^#].*ALL" /etc/sudoers /etc/sudoers.d/*

# 4. 로그인 가능한 시스템 계정 확인 (이상 징후)
awk -F: '$3 < 1000 && $7 !~ /nologin|false/ { print $1, $7 }' /etc/passwd
```

---

## 6. 자주 하는 실수

| 실수 | 올바른 방법 |
|---|---|
| 서비스 계정에 `/bin/bash` 셸 부여 | `/sbin/nologin` 또는 `/bin/false` 사용 |
| UID를 지정하지 않고 서비스 계정 생성 → 서버마다 UID 상이 | `--uid` 고정 지정 후 Ansible로 일괄 적용 |
| 공유 계정(`deploy`, `admin`) 사용 → 감사 추적 불가 | 1인 1계정 원칙, 서비스 계정은 자동화 전용 |
| sudoers에 `NOPASSWD:ALL` 설정 | 최소 권한 원칙: 필요한 명령만 명시 |
| 퇴사자 계정 즉시 삭제 → 파일 소유자 추적 불가 | 잠금 후 30일 보존 → 파일 소유권 이전 후 삭제 |
| 임시 계정에 만료일 미설정 | `--expiredate` 필수, 캘린더 알림 등록 |
| `/etc/passwd`를 직접 편집 | `useradd`, `usermod`, `userdel` 명령 사용 |
