## 1. 개요

환경변수(Environment Variable)는 프로세스가 실행될 때 참조하는 키-값 쌍이다.
어떤 파일에서 설정하느냐에 따라 적용 범위(전체 사용자/특정 사용자/현재 세션/서비스 프로세스)가 달라진다.
`.bashrc`와 `.profile`의 차이를 모르면 설정한 환경변수가 왜 적용이 안 되는지 한참 헤매게 된다.

---

## 2. 환경변수 기본 조작

```bash
# 현재 세션의 모든 환경변수 확인
env
printenv

# 특정 변수 확인
echo $PATH
printenv PATH

# 임시 선언 (현재 셸 세션에서만 유효)
MY_VAR="hello"
echo $MY_VAR

# export: 자식 프로세스(하위 명령어)에도 전달
export MY_VAR="hello"
export APP_ENV="production"

# 선언과 export 동시에 (위와 동일)
export MY_VAR="hello"

# 변수 해제
unset MY_VAR

# 한 번만 사용할 변수 (명령어 앞에 선언)
NODE_ENV=production node app.js
```

---

## 3. 설정 파일 종류와 적용 범위

### 3.1 파일별 차이

| 파일 | 적용 대상 | 언제 로드 | 주요 용도 |
|---|---|---|---|
| `/etc/environment` | 전체 사용자 | 로그인 시 항상 | 시스템 전역 환경변수 (단순 KEY=VALUE) |
| `/etc/profile` | 전체 사용자 | 로그인 셸 시작 시 | 전체 사용자 공통 설정 |
| `/etc/profile.d/*.sh` | 전체 사용자 | 로그인 셸 시작 시 | 서비스/패키지별 환경변수 분리 관리 |
| `~/.profile` | 특정 사용자 | 로그인 셸 시작 시 | 사용자 개인 PATH, 환경변수 |
| `~/.bashrc` | 특정 사용자 | 비로그인 인터랙티브 셸 | alias, 함수, PS1 프롬프트 |
| `~/.bash_profile` | 특정 사용자 | bash 로그인 셸 시작 시 | `.profile` 대신 사용 (bash 전용) |

### 3.2 로그인 셸 vs 비로그인 셸

```
로그인 셸 (ssh 접속, su -, 콘솔 로그인)
  └→ /etc/profile
  └→ /etc/profile.d/*.sh
  └→ ~/.bash_profile 또는 ~/.profile
       └→ (보통 내부에서 ~/.bashrc도 호출)

비로그인 인터랙티브 셸 (터미널 새 탭, bash 명령어 실행)
  └→ ~/.bashrc 만 로드

비인터랙티브 셸 (cron, 스크립트 실행)
  └→ 아무것도 로드 안 함 (환경변수 직접 지정 필요)
```

```bash
# 현재 셸이 로그인 셸인지 확인
echo $0
# -bash  → 앞에 - 붙으면 로그인 셸
# bash   → 비로그인 셸

shopt login_shell
# login_shell     on   → 로그인 셸
```

---

## 4. 영구 환경변수 설정

### 4.1 특정 사용자에게만 적용 (~/.profile 또는 ~/.bashrc)

```bash
# ~/.profile 에 추가 (로그인 시 적용, PATH 변경 권장 위치)
cat >> ~/.profile <<'EOF'

# Java 경로
export JAVA_HOME=/opt/java/jdk-21
export PATH="$JAVA_HOME/bin:$PATH"

# 앱 설정
export APP_ENV="production"
export APP_PORT=8080
EOF

# 현재 세션에 즉시 적용
source ~/.profile
```

```bash
# ~/.bashrc 에 추가 (alias, 함수, 터미널 관련 설정)
cat >> ~/.bashrc <<'EOF'

# 유용한 alias
alias ll='ls -alF'
alias la='ls -A'
alias grep='grep --color=auto'

# 자주 쓰는 함수
mkcd() { mkdir -p "$1" && cd "$1"; }
EOF

source ~/.bashrc
```

### 4.2 전체 사용자에게 적용

```bash
# /etc/profile.d/ 에 새 파일 추가 (권장 - 충돌 없이 모듈화)
cat > /etc/profile.d/app-env.sh <<'EOF'
export APP_HOME="/opt/mycompany/app"
export PATH="$APP_HOME/bin:$PATH"
EOF

chmod 644 /etc/profile.d/app-env.sh

# /etc/environment: 가장 단순한 전역 설정 (셸 문법 없음, KEY=VALUE 형태만)
cat >> /etc/environment <<'EOF'
APP_ENV=production
TZ=Asia/Seoul
EOF
# /etc/environment는 PAM이 로드하므로 export 키워드 불필요
```

### 4.3 PATH에 경로 추가

```bash
# 잘못된 방법 (기존 PATH 덮어씀)
export PATH="/usr/local/bin"

# 올바른 방법 (기존 PATH 앞 또는 뒤에 추가)
export PATH="/usr/local/myapp/bin:$PATH"   # 앞에 추가 (우선순위 높음)
export PATH="$PATH:/usr/local/myapp/bin"   # 뒤에 추가

# PATH 중복 방지 (이미 포함된 경우 추가 안 함)
case ":$PATH:" in
    *":/usr/local/myapp/bin:"*) ;;   # 이미 있음
    *) export PATH="$PATH:/usr/local/myapp/bin" ;;
esac
```

---

## 5. systemd 서비스의 환경변수

systemd 서비스는 사용자의 `.bashrc`나 `.profile`을 로드하지 않는다.
서비스 유닛 파일에 별도로 환경변수를 지정해야 한다.

```ini
# /etc/systemd/system/myapp.service
[Unit]
Description=My Application

[Service]
# 방법 1: 직접 선언 (단순한 경우)
Environment=APP_ENV=production
Environment=APP_PORT=8080
Environment=DB_HOST=db.internal

# 방법 2: 환경변수 파일 참조 (권장 - 민감 정보 분리)
EnvironmentFile=/etc/myapp/env
EnvironmentFile=-/etc/myapp/env.local   # - 앞에 붙이면 파일 없어도 에러 안 남

ExecStart=/opt/myapp/bin/server
User=myapp
```

```bash
# /etc/myapp/env 파일 형식 (KEY=VALUE, 따옴표 없어도 됨)
APP_ENV=production
APP_PORT=8080
DB_HOST=db.internal
DB_NAME=myapp_prod

# 민감 정보는 별도 파일에 (권한 600)
# /etc/myapp/env.local
DB_PASSWORD=super-secret
```

```bash
# 서비스 환경변수 확인
systemctl show myapp.service --property=Environment
# 또는
systemd-run --unit=myapp.service env   # 서비스 네임스페이스에서 env 실행
```

---

## 6. .env 파일 패턴 (앱 개발/배포)

```bash
# .env 파일 형식 (dotenv 라이브러리 표준)
APP_ENV=production
DB_HOST=db.internal
DB_PORT=5432
DB_NAME=myapp_prod
DB_USER=appuser
DB_PASSWORD=secret123

# 셸 스크립트에서 .env 로드
set -a   # 이후 선언되는 모든 변수를 자동 export
source .env
set +a

# 또는 export를 명시적으로 처리
while IFS='=' read -r key value; do
    [[ "$key" =~ ^#.*$ ]] && continue   # 주석 건너뜀
    [[ -z "$key" ]] && continue          # 빈 줄 건너뜀
    export "$key"="${value}"
done < .env
```

> **.env 파일은 절대 git에 커밋하지 않는다.** `.gitignore`에 반드시 추가한다.

---

## 7. AWS에서 환경변수 관리

```bash
# EC2 인스턴스에서 SSM Parameter Store → 환경변수 로드
# (자격증명을 파일에 두지 않는 패턴)
export DB_PASSWORD=$(aws ssm get-parameter \
    --name "/myapp/prod/DB_PASSWORD" \
    --with-decryption \
    --query 'Parameter.Value' \
    --output text)

# Secrets Manager에서 JSON 형태로 가져와서 파싱
SECRET=$(aws secretsmanager get-secret-value \
    --secret-id "myapp/prod/db-credentials" \
    --query 'SecretString' \
    --output text)

export DB_USER=$(echo "$SECRET" | python3 -c "import sys,json; print(json.load(sys.stdin)['username'])")
export DB_PASSWORD=$(echo "$SECRET" | python3 -c "import sys,json; print(json.load(sys.stdin)['password'])")
```

---

## 8. 자주 하는 실수

| 실수 | 올바른 방법 |
|---|---|
| `export` 없이 변수 선언 → 자식 프로세스에 전달 안 됨 | `export KEY=VALUE` 로 선언 |
| `.bashrc`에 PATH 추가했는데 ssh 로그인 후 적용 안 됨 | 로그인 셸은 `.bashrc` 미로드, `~/.profile`에 추가 |
| systemd 서비스가 환경변수를 못 읽음 | 유닛 파일에 `Environment=` 또는 `EnvironmentFile=` 추가 |
| `.env` 파일을 git에 커밋 | `.gitignore`에 `.env` 추가, 시크릿은 SSM/Secrets Manager 사용 |
| 기존 PATH를 덮어씌움 | `export PATH="$NEW:$PATH"` 로 기존 값 보존 |
| `source` 없이 설정 파일 수정 → 즉시 미적용 | 수정 후 `source ~/.profile` 또는 재로그인 |
