## 1. 개요

Bash 셸 스크립트는 반복적인 시스템 작업을 자동화하는 핵심 도구다.
`sed`(스트림 편집), `awk`(필드 기반 텍스트 처리), `grep`(패턴 검색)을 조합하면 로그 분석, 설정 파일 수정, 배포 자동화 등 대부분의 운영 작업을 코드로 처리할 수 있다.

## 2. Bash 스크립트 기초

### 2.1 스크립트 시작 - 안전 옵션

```bash
#!/bin/bash
# 스크립트 상단에 항상 포함하는 안전 옵션
set -euo pipefail

# set -e: 명령어 실패 시 즉시 종료 (에러 무시 방지)
# set -u: 미정의 변수 사용 시 에러 (오타 방지)
# set -o pipefail: 파이프 중간 실패도 에러로 처리
#   예: false | true → pipefail 없으면 성공으로 판단됨

# 현재 스크립트 파일 위치 기준으로 경로 설정
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
```

### 2.2 변수와 타입

```bash
# 변수 선언 (공백 없이)
APP_NAME="backend-api"
PORT=8080
LOG_DIR="/var/log/${APP_NAME}"

# 변수 참조: ${변수명} 권장 (중괄호로 경계 명확히)
echo "Starting ${APP_NAME} on port ${PORT}"

# 읽기 전용 상수
readonly MAX_RETRY=3

# 배열
SERVERS=("web-01" "web-02" "web-03")
echo "${SERVERS[0]}"          # 첫 번째 요소
echo "${#SERVERS[@]}"         # 배열 길이
echo "${SERVERS[@]}"          # 전체 요소

# 연관 배열(딕셔너리)
declare -A ENV_MAP
ENV_MAP["prod"]="10.0.1.0"
ENV_MAP["dev"]="10.0.2.0"
echo "${ENV_MAP["prod"]}"

# 명령 실행 결과를 변수에 저장
CURRENT_USER=$(whoami)
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
```

### 2.3 조건문

```bash
# 파일/디렉토리 존재 확인
if [[ -f "/etc/app/config.yml" ]]; then
    echo "설정 파일 있음"
elif [[ -d "/etc/app" ]]; then
    echo "디렉토리만 있음"
else
    echo "없음"
fi

# 주요 테스트 연산자
# -f: 파일 존재   -d: 디렉토리 존재   -e: 파일/디렉토리 존재
# -r: 읽기 가능   -w: 쓰기 가능        -x: 실행 가능
# -z: 문자열 비어있음   -n: 문자열 비어있지 않음
# -eq, -ne, -lt, -gt, -le, -ge: 숫자 비교

# 문자열 비교 ([[ ]] 권장, 공백/특수문자 안전)
ENV="production"
if [[ "$ENV" == "production" ]]; then
    echo "운영 환경"
fi

if [[ "$ENV" != "dev" && "$ENV" != "staging" ]]; then
    echo "운영 또는 알 수 없는 환경"
fi

# 숫자 비교
DISK_USAGE=$(df / | awk 'NR==2{print $5}' | tr -d '%')
if (( DISK_USAGE > 80 )); then
    echo "경고: 디스크 사용량 ${DISK_USAGE}%"
fi
```

### 2.4 반복문

```bash
# 배열 순회
for server in "${SERVERS[@]}"; do
    echo "Deploying to ${server}..."
    ssh ubuntu@"${server}" 'sudo systemctl restart api'
done

# 범위 반복
for i in {1..5}; do
    echo "시도 ${i}/5"
done

# C 스타일 for문
for (( i=0; i<3; i++ )); do
    echo "$i"
done

# while 루프 + 재시도 패턴
RETRY=0
MAX_RETRY=5
until curl -sf http://localhost:8080/health; do
    RETRY=$(( RETRY + 1 ))
    if (( RETRY >= MAX_RETRY )); then
        echo "헬스체크 실패: ${MAX_RETRY}회 시도 초과"
        exit 1
    fi
    echo "대기 중... (${RETRY}/${MAX_RETRY})"
    sleep 5
done

# 파일/글로브 순회
for config_file in /etc/app/*.conf; do
    echo "설정 파일: ${config_file}"
done
```

### 2.5 함수

```bash
# 함수 정의
log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $*"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2
}

# 반환값: exit code (0=성공, 1~255=실패)
is_service_running() {
    local service_name="$1"  # local로 지역변수 선언 (전역 오염 방지)
    systemctl is-active --quiet "$service_name"
}

# 함수 호출
if is_service_running "nginx"; then
    log_info "nginx 실행 중"
else
    log_error "nginx 중지됨"
fi

# 문자열 반환: echo + 명령 치환 조합
get_instance_region() {
    curl -s http://169.254.169.254/latest/meta-data/placement/region
}
REGION=$(get_instance_region)
```

### 2.6 에러 핸들링 - trap

```bash
#!/bin/bash
set -euo pipefail

# 스크립트 종료 시 항상 실행 (성공/실패 무관)
cleanup() {
    local exit_code=$?
    log_info "정리 작업 시작..."
    rm -f /tmp/deploy_lock
    if (( exit_code != 0 )); then
        log_error "스크립트 실패 (exit code: ${exit_code})"
        # Slack 알림 등 실패 처리
    fi
}
trap cleanup EXIT

# 특정 시그널 처리
handle_interrupt() {
    log_error "사용자가 스크립트를 중단했습니다."
    exit 130
}
trap handle_interrupt INT TERM

# 임시 파일 생성 후 자동 삭제
TMPFILE=$(mktemp)
trap "rm -f ${TMPFILE}" EXIT
```

---

## 3. sed - 스트림 편집기

파일이나 파이프 입력에서 텍스트를 검색·치환·삭제한다. 설정 파일 수정, 로그 가공에 자주 쓰인다.

### 3.1 기본 치환

```bash
# 기본 형식: sed 's/찾을패턴/바꿀내용/플래그' 파일
# s: substitute(치환), g: 줄 내 모든 매칭 (없으면 첫 번째만)

# 첫 번째 매칭만 치환
sed 's/foo/bar/' file.txt

# 줄 내 모든 매칭 치환 (g 플래그)
sed 's/foo/bar/g' file.txt

# 대소문자 무시 (i 플래그)
sed 's/error/ERROR/gi' app.log

# 파일 직접 수정 (-i 옵션, 원본 백업: -i.bak)
sed -i 's/localhost/db.internal/g' /etc/app/config.yml
sed -i.bak 's/localhost/db.internal/g' /etc/app/config.yml  # config.yml.bak 백업 생성
```

### 3.2 자주 쓰는 패턴

```bash
# 특정 줄 삭제
sed '/^#/d' config.txt          # 주석(#으로 시작) 줄 삭제
sed '/^$/d' config.txt          # 빈 줄 삭제
sed '/error/d' app.log          # "error" 포함 줄 삭제

# 특정 줄 범위 출력 (-n + p 플래그)
sed -n '5,10p' file.txt         # 5~10번째 줄만 출력
sed -n '/START/,/END/p' file.txt # START~END 사이 줄 출력

# 줄 앞/뒤에 텍스트 추가
sed 's/^/  /' file.txt          # 모든 줄 앞에 공백 2개 추가
sed 's/$/ ;/' file.txt          # 모든 줄 끝에 " ;" 추가

# 특정 줄 다음에 새 줄 삽입
sed '/\[Service\]/a After=network.target' service.conf

# 변수 사용 시 큰따옴표 사용
NEW_PORT=9090
sed -i "s/^PORT=.*/PORT=${NEW_PORT}/" /etc/app/env

# 여러 치환 동시에 (-e 옵션 또는 ; 구분)
sed -e 's/foo/bar/g' -e 's/baz/qux/g' file.txt
sed 's/foo/bar/g; s/baz/qux/g' file.txt

# 구분자를 /가 아닌 다른 문자로 (경로 치환 시 유용)
sed 's|/old/path|/new/path|g' file.txt
```

### 3.3 실전 예제

```bash
# .env 파일에서 특정 값 교체
sed -i "s|^DATABASE_URL=.*|DATABASE_URL=postgresql://db.internal:5432/prod|" .env

# nginx 설정에서 server_name 교체
sed -i "s/server_name .*/server_name ${DOMAIN};/" /etc/nginx/sites-available/default

# 여러 서버의 설정 파일 일괄 수정
for server in "${SERVERS[@]}"; do
    ssh "$server" "sed -i 's/old-value/new-value/g' /etc/app/config.yml"
done

# 주석 제거 후 공백 줄 제거해서 실제 설정만 추출
sed '/^#/d; /^$/d' /etc/app/config.conf
```

---

## 4. awk - 필드 기반 텍스트 처리

awk는 공백(또는 지정 구분자)으로 나뉜 컬럼 데이터를 처리하는 데 특화되어 있다.
로그 분석, CSV 파싱, 통계 집계에 자주 쓰인다.

### 4.1 기본 사용법

```bash
# 기본 구조: awk '조건 { 액션 }' 파일
# 내장 변수:
# $0: 전체 줄    $1, $2, ...: 각 필드
# NR: 현재 줄 번호   NF: 현재 줄 필드 수
# FS: 입력 구분자(기본 공백)   OFS: 출력 구분자

# 특정 컬럼만 출력
awk '{print $1, $3}' file.txt

# ps 출력에서 PID와 명령어만 추출
ps aux | awk '{print $2, $11}'

# 구분자 지정 (-F 옵션)
awk -F: '{print $1}' /etc/passwd         # 콜론 구분, 사용자 이름만
awk -F',' '{print $1, $3}' data.csv      # CSV: 1번, 3번 컬럼
```

### 4.2 조건 필터링

```bash
# 특정 조건의 줄만 처리
awk '$3 > 100 {print $0}' data.txt          # 3번 필드가 100 초과인 줄
awk 'NR > 1 {print $0}' file.txt            # 헤더 줄 건너뛰기 (1번 줄 제외)
awk '/ERROR/ {print $0}' app.log            # ERROR 포함 줄만
awk '!/DEBUG/ {print $0}' app.log           # DEBUG 제외한 줄

# 여러 조건 조합
awk '$5 > 80 && $5 < 100 {print $0}' data.txt

# df 출력에서 사용률 80% 초과 파티션만 추출
df -h | awk 'NR>1 && $5+0 > 80 {print $1, $5}'
```

### 4.3 집계 및 계산

```bash
# 합계
awk '{sum += $3} END {print "합계:", sum}' data.txt

# 평균
awk '{sum += $3; count++} END {print "평균:", sum/count}' data.txt

# 최댓값
awk 'BEGIN{max=0} $3>max {max=$3} END{print "최댓값:", max}' data.txt

# 컬럼별 집계 (연관 배열 활용)
awk '{count[$1]++} END {for (key in count) print key, count[key]}' access.log

# nginx 액세스 로그에서 상태코드별 집계
awk '{print $9}' /var/log/nginx/access.log | sort | uniq -c | sort -rn

# IP별 요청 횟수 상위 10개
awk '{print $1}' /var/log/nginx/access.log | sort | uniq -c | sort -rn | head -10
```

### 4.4 BEGIN / END 블록

```bash
# BEGIN: 첫 줄 처리 전 실행 (헤더 출력, 초기화)
# END: 마지막 줄 처리 후 실행 (집계 결과 출력)

awk '
BEGIN {
    print "=== 디스크 사용량 보고서 ==="
    print "파티션\t\t사용률"
    FS = " "
}
NR > 1 && $5+0 > 50 {
    gsub(/%/, "", $5)
    printf "%-20s %s%%\n", $1, $5
}
END {
    print "=== 완료 ==="
}
' < <(df -h)
```

### 4.5 실전 예제

```bash
# /etc/passwd에서 UID 1000 이상인 일반 사용자 목록
awk -F: '$3 >= 1000 && $3 < 65534 {print $1, $3, $6}' /etc/passwd

# 특정 포트 사용 프로세스 찾기
ss -tlnp | awk '$4 ~ /:8080$/ {print $0}'

# CSV 파일에서 특정 컬럼 기준 필터링
awk -F',' '$4 == "production" && $5 > 1000 {print $1, $2}' servers.csv

# 로그에서 응답시간 평균 계산 (nginx combined 로그 형식)
awk '{sum += $NF; count++} END {printf "평균 응답시간: %.3fms\n", sum/count}' /var/log/nginx/access.log
```

---

## 5. 실전 스크립트 예제

### 5.1 배포 스크립트

```bash
#!/bin/bash
set -euo pipefail

# ===== 설정 =====
APP_NAME="backend-api"
DEPLOY_DIR="/opt/mycompany/${APP_NAME}"
BACKUP_DIR="/opt/mycompany/backups/${APP_NAME}"
SERVICE_NAME="${APP_NAME}.service"
ARTIFACT_URL="${1:-}"  # 첫 번째 인자: 배포할 아티팩트 URL

# ===== 로그 함수 =====
log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { echo "[ERROR] $*" >&2; exit 1; }

# ===== 사전 검사 =====
[[ -z "$ARTIFACT_URL" ]] && die "사용법: $0 <artifact-url>"
[[ $(id -u) -eq 0 ]] || die "root 권한 필요"

# ===== 기존 버전 백업 =====
if [[ -d "$DEPLOY_DIR" ]]; then
    BACKUP_PATH="${BACKUP_DIR}/$(date '+%Y%m%d_%H%M%S')"
    log "기존 버전 백업: ${BACKUP_PATH}"
    mkdir -p "$BACKUP_DIR"
    cp -r "$DEPLOY_DIR" "$BACKUP_PATH"
fi

# ===== 배포 =====
log "아티팩트 다운로드..."
TMPFILE=$(mktemp /tmp/deploy_XXXXXX.tar.gz)
trap "rm -f ${TMPFILE}" EXIT

curl -fsSL -o "$TMPFILE" "$ARTIFACT_URL"

log "서비스 중지..."
systemctl stop "$SERVICE_NAME" || true

log "파일 배포..."
mkdir -p "$DEPLOY_DIR"
tar xzf "$TMPFILE" -C "$DEPLOY_DIR" --strip-components=1

log "서비스 시작..."
systemctl start "$SERVICE_NAME"

# ===== 헬스체크 =====
log "헬스체크..."
for i in {1..10}; do
    if curl -sf "http://localhost:8080/health" &>/dev/null; then
        log "배포 완료!"
        exit 0
    fi
    sleep 3
done

die "헬스체크 실패 - 롤백 필요"
```

### 5.2 로그 분석 스크립트

```bash
#!/bin/bash
# nginx 액세스 로그 일일 보고서 생성

LOG_FILE="/var/log/nginx/access.log"
REPORT_DATE="${1:-$(date '+%Y/%m/%d')}"

echo "===== nginx 액세스 보고서: ${REPORT_DATE} ====="
echo ""

echo "[요청 수]"
grep "$REPORT_DATE" "$LOG_FILE" | wc -l

echo ""
echo "[상태코드별 집계]"
grep "$REPORT_DATE" "$LOG_FILE" \
    | awk '{print $9}' \
    | sort | uniq -c | sort -rn \
    | awk '{printf "  HTTP %s: %d건\n", $2, $1}'

echo ""
echo "[Top 10 요청 URL]"
grep "$REPORT_DATE" "$LOG_FILE" \
    | awk '{print $7}' \
    | sed 's/?.*$//' \        # 쿼리스트링 제거
    | sort | uniq -c | sort -rn | head -10 \
    | awk '{printf "  %5d회  %s\n", $1, $2}'

echo ""
echo "[Top 10 클라이언트 IP]"
grep "$REPORT_DATE" "$LOG_FILE" \
    | awk '{print $1}' \
    | sort | uniq -c | sort -rn | head -10 \
    | awk '{printf "  %5d회  %s\n", $1, $2}'
```

### 5.3 설정 파일 환경별 치환 스크립트

```bash
#!/bin/bash
# 템플릿 파일의 플레이스홀더를 환경변수로 치환
# 사용법: ./render-config.sh config.yml.tmpl > config.yml

TEMPLATE_FILE="${1:-}"
[[ -z "$TEMPLATE_FILE" ]] && { echo "Usage: $0 <template>"; exit 1; }

# 환경변수 로드 (있는 경우)
[[ -f ".env" ]] && source .env

# {{VAR_NAME}} 형태의 플레이스홀더를 환경변수 값으로 치환
while IFS= read -r line; do
    # {{변수명}} 패턴을 찾아 환경변수로 치환
    while [[ "$line" =~ \{\{([A-Z_]+)\}\} ]]; do
        var_name="${BASH_REMATCH[1]}"
        var_value="${!var_name:-}"
        line="${line/\{\{${var_name}\}\}/${var_value}}"
    done
    echo "$line"
done < "$TEMPLATE_FILE"
```

## 6. grep 실전

```bash
# 기본
grep -r 'pattern' ./dir/            # 재귀 탐색
grep -i 'error' app.log             # 대소문자 무시
grep -v 'DEBUG' app.log             # 역매칭 (패턴 없는 줄)
grep -c 'ERROR' app.log             # 매칭된 줄 수만 출력
grep -l 'pattern' *.conf            # 매칭된 파일명만 출력

# 컨텍스트 출력
grep -A 3 'ERROR' app.log           # 매칭 후 3줄
grep -B 3 'ERROR' app.log           # 매칭 전 3줄
grep -C 3 'ERROR' app.log           # 매칭 전후 3줄

# 확장 정규식 (-E)
grep -E 'error|warn|crit' syslog
grep -E '^(GET|POST) /api' access.log

# 값만 추출 (-o: 매칭 부분만, -P: Perl 정규식)
grep -oP '"\w+"\s*:\s*\K\d+' response.json      # JSON 숫자 값 추출
grep -oP '\d{1,3}(\.\d{1,3}){3}' access.log     # IP 주소 추출

# 실전
grep -rn 'TODO\|FIXME' ./src/                    # 소스에서 TODO/FIXME
grep -v '^\s*#' nginx.conf | grep -v '^\s*$'     # 주석·빈 줄 제거 후 유효 설정만
```

---

## 7. awk 고급 패턴

```bash
# 중복 줄 제거 (순서 유지, sort | uniq와 달리 정렬 불필요)
awk '!seen[$0]++' file.txt

# 특정 컬럼 기준 중복 제거
awk -F, '!seen[$1]++' data.csv

# 두 파일 조인 (NR==FNR: 첫 번째 파일 처리 중일 때만 true)
# file1.txt의 $1을 키로 file2.txt의 $1과 매칭
awk 'NR==FNR {a[$1]=$2; next} $1 in a {print $1, a[$1], $2}' file1.txt file2.txt

# p95 레이턴시 계산
awk '{print $NF}' access.log | sort -n \
  | awk 'BEGIN{c=0} {a[c++]=$1} END{print "p95:", a[int(c*0.95)], "ms"}'

# 프로세스별 메모리 합산
ps aux | awk 'NR>1 {mem[$11]+=$6} END {for(p in mem) print mem[p], p}' \
  | sort -rn | head -10 \
  | awk '{printf "%8.1f MB  %s\n", $1/1024, $2}'

# 이전 줄 값과 비교 (차이값 계산)
awk '{print $1, $1-prev; prev=$1}' metrics.txt
```

---

## 8. xargs & 병렬 처리

```bash
# 기본 xargs
find . -name "*.log" -mtime +7 | xargs rm -f
cat urls.txt | xargs -I{} curl -sf {}

# 파일명에 공백 대비 (-0 옵션, find -print0과 조합)
find . -name "*.txt" -print0 | xargs -0 grep 'pattern'

# 병렬 실행 (-P: 동시 실행 수)
cat servers.txt | xargs -P 10 -I{} ssh {} 'uptime'

# GNU Parallel (xargs보다 강력)
# 설치: apt install parallel / brew install parallel
cat hosts.txt | parallel -j 20 'ssh {} "df -h | tail -1"'
parallel -j 4 'gzip {}' ::: *.log            # 로그 파일 병렬 압축
```

---

## 9. 파이프 조합 실전 패턴

```bash
# 접속 IP별 요청 수 + 상태코드 집계를 한 번에
awk '{ip[$1]++; code[$9]++}
     END {
       print "=== IP Top 5 ==="; for(k in ip) print ip[k], k
       print "=== Status ==="  ; for(k in code) print code[k], k
     }' access.log | sort -rn

# 디스크 사용률 80% 이상인 파티션 알림
df -h | awk 'NR>1 && int($5) >= 80 {print $6, $5}' \
  | while read mount usage; do
      echo "WARN: $mount is $usage full"
    done

# 포트별 연결 수 (ss 출력 가공)
ss -tn state established | awk 'NR>1 {split($4,a,":"); port[a[length(a)]]++}
  END {for(p in port) print port[p], p}' | sort -rn | head -10

# 설정 파일에서 유효한 항목만 추출 (주석·빈 줄·앞뒤 공백 제거)
grep -v '^\s*#' config.conf | grep -v '^\s*$' | sed 's/^\s*//; s/\s*$//'

# 여러 서버 동시 상태 확인
cat servers.txt | xargs -P 10 -I{} bash -c \
  'echo -n "{}: "; ssh -o ConnectTimeout=3 {} "uptime | awk -F: \"{print \\\$NF}\"" 2>/dev/null || echo "접속 불가"'
```

---

## 10. tr - 문자 변환·삭제

`tr`은 표준 입력에서 문자 단위로 변환·삭제·압축하는 필터다.
파이프 중간에 끼워 대소문자 정규화, 구분자 교체, 불필요한 문자 제거에 자주 쓰인다.

### 10.1 기본 문법

```bash
# tr [옵션] SET1 [SET2]
# SET1의 각 문자를 SET2의 대응 문자로 1:1 변환
# SET에는 리터럴 문자 외에 범위(a-z), 클래스([:upper:]) 사용 가능

tr 'abc' 'ABC'          # a→A, b→B, c→C
echo "hello" | tr 'a-z' 'A-Z'  # 소문자 전체를 대문자로
```

### 10.2 대소문자 변환

```bash
# 소문자 → 대문자
echo "Hello World" | tr 'a-z' 'A-Z'        # HELLO WORLD
echo "Hello World" | tr '[:lower:]' '[:upper:]'  # 같은 결과, POSIX 클래스 사용

# 대문자 → 소문자
echo "REGION=AP-NORTHEAST-2" | tr '[:upper:]' '[:lower:]'  # region=ap-northeast-2

# 실전: 환경 변수 이름을 소문자 키로 정규화
printenv | tr '[:upper:]' '[:lower:]'
```

### 10.3 문자 삭제 (-d)

```bash
# -d: SET1에 포함된 문자를 모두 삭제
echo "user-name_01" | tr -d '-_'            # username01
echo "  spaces  " | tr -d ' '              # spaces (공백 전체 제거)
echo "abc123def" | tr -d '[:alpha:]'       # 123 (영문자 삭제, 숫자만 남김)
echo "abc123def" | tr -d '[:digit:]'       # abcdef (숫자 삭제)

# 줄바꿈 제거 (멀티라인 → 한 줄)
cat list.txt | tr -d '\n'

# Windows CRLF → Unix LF 변환 (스크립트가 \r 때문에 오동작할 때)
tr -d '\r' < windows-file.sh > unix-file.sh

# 실전: API 응답에서 따옴표 제거
INSTANCE_ID=$(aws ec2 describe-instances ... | jq '.InstanceId' | tr -d '"')
```

### 10.4 문자 압축 (-s, squeeze)

```bash
# -s: 연속으로 반복되는 문자를 하나로 압축
echo "hello   world" | tr -s ' '           # hello world (연속 공백 → 공백 1개)
echo "aabbcc" | tr -s 'a-z'               # abc

# 실전: ps/df 출력은 컬럼 정렬을 위해 공백이 여러 개 → awk 파싱 전에 정리
ps aux | tr -s ' ' | cut -d' ' -f2,11     # PID, 명령어 추출
df -h | tr -s ' '                         # 공백 정규화
```

### 10.5 보완 집합 (-c, complement)

```bash
# -c: SET1의 보완 집합 (SET1에 없는 문자들)을 대상으로 처리
# 알파벳·숫자·줄바꿈 이외의 문자를 모두 공백으로 치환
echo "price: $1,234.56!" | tr -c '[:alnum:]\n' ' '   # price   1 234 56

# 숫자 이외 모두 제거
echo "Memory: 2048 MB" | tr -cd '[:digit:]'           # 2048

# 실전: 로그에서 숫자만 추출해 합산
grep 'bytes' access.log | tr -cd '0-9\n' | awk '{sum+=$1} END{print sum}'
```

### 10.6 실전 조합 패턴

```bash
# 구분자 교체: 콤마 CSV → 탭 구분
cat data.csv | tr ',' '\t'

# 콜론 경로를 줄바꿈으로 분리해서 탐색
echo $PATH | tr ':' '\n'

# 줄바꿈을 공백으로 모아서 한 줄 명령 인자로 사용
# (xargs 없이 직접 조합할 때)
IDS=$(cat id-list.txt | tr '\n' ' ')
aws ec2 describe-instances --instance-ids $IDS

# 대소문자 무시 비교 (변수 정규화 후 비교)
ENV_LOWER=$(echo "$ENV" | tr '[:upper:]' '[:lower:]')
if [[ "$ENV_LOWER" == "prod" ]]; then ...

# 디스크 사용률 숫자만 추출 (% 기호 제거)
USAGE=$(df / | awk 'NR==2{print $5}' | tr -d '%')
if (( USAGE > 80 )); then echo "디스크 위험"; fi
```

---

## 11. cut - 필드·문자 단위 추출

`cut`은 각 줄에서 특정 컬럼(필드)이나 문자 위치를 잘라내는 도구다.
구분자가 명확한 구조화된 텍스트(CSV, `/etc/passwd`, 로그 등)에서 빠르게 컬럼을 뽑을 때 `awk`보다 간결하다.

### 11.1 필드 추출 (-d, -f)

```bash
# -d: 구분자 지정 (기본값: 탭)
# -f: 추출할 필드 번호 (1부터 시작)

# /etc/passwd에서 사용자 이름(1번)과 홈 디렉토리(6번)만 추출
cut -d: -f1,6 /etc/passwd

# CSV에서 첫 번째, 세 번째 컬럼
cut -d',' -f1,3 data.csv

# 범위 지정: 2번부터 4번 필드
cut -d',' -f2-4 data.csv

# 3번 이후 모든 필드
cut -d',' -f3- data.csv

# 3번까지 모든 필드
cut -d',' -f-3 data.csv
```

### 11.2 문자 위치 추출 (-c)

```bash
# -c: 문자 위치(character position)로 추출 (고정 너비 포맷에 유용)

# 1~10번째 문자
cut -c1-10 file.txt

# 타임스탬프 앞 19자리 추출 (예: "2024-01-15 08:30:22 ERROR ...")
cut -c1-19 app.log

# 특정 위치 이후 전체
cut -c20- app.log

# 실전: AWS CLI 출력에서 날짜만 추출
aws ec2 describe-instances ... | grep LaunchTime | cut -c15-34
```

### 11.3 실전 패턴

```bash
# hostname에서 환경 접두사만 추출 (예: prod-web-01 → prod)
hostname | cut -d'-' -f1

# 파일 확장자 추출 (마지막 . 이후)
echo "archive.tar.gz" | rev | cut -d'.' -f1 | rev   # gz

# /etc/os-release에서 OS 이름만
grep '^ID=' /etc/os-release | cut -d'=' -f2 | tr -d '"'   # amzn, ubuntu 등

# 프로세스 목록에서 PID만 추출
ps aux | grep nginx | grep -v grep | tr -s ' ' | cut -d' ' -f2

# SSH 공개키에서 키 타입만 추출
cut -d' ' -f1 ~/.ssh/authorized_keys                  # ssh-rsa, ssh-ed25519 등

# 로그 레벨만 추출 (고정 포맷 로그: "[2024-01-15 08:30:22] [ERROR] ...")
grep '\[ERROR\]' app.log | cut -d']' -f2 | cut -d'[' -f2   # ERROR

# AWS 인스턴스 ID 목록에서 태그 이름 기준 정렬
aws ec2 describe-tags --filters "Name=key,Values=Name" \
  | jq -r '.Tags[] | [.ResourceId, .Value] | @tsv' \
  | sort -t$'\t' -k2 \
  | cut -f1                                           # ResourceId만 출력

# 구분자가 다를 때 tr로 정규화 후 cut
# 예: "key=value" 형식에서 value만
echo "DB_HOST=db.internal" | tr '=' '\t' | cut -f2   # db.internal
```

### 11.4 cut vs awk 선택 기준

| 상황 | 권장 도구 |
|---|---|
| 구분자가 고정, 단순 컬럼 추출 | `cut` (더 간결) |
| 조건 필터링 + 컬럼 추출 | `awk` |
| 연속 공백이 구분자 (ps, df 출력) | `awk` (`cut`은 연속 공백을 빈 필드로 처리) |
| 집계·계산 필요 | `awk` |
| 고정 너비 텍스트에서 위치 기반 추출 | `cut -c` |

> **주의**: `cut`은 연속된 공백을 하나로 합치지 않는다. `ps aux` 같은 출력을 `cut`으로 파싱하면 빈 필드가 생긴다. 이 경우 `tr -s ' '`로 공백을 압축한 후 `cut`을 쓰거나, 처음부터 `awk`를 사용한다.

---

## 12. 자주 하는 실수

| 실수 | 올바른 방법 |
|---|---|
| `set -e` 없이 에러 무시 | 스크립트 상단에 `set -euo pipefail` 필수 |
| 변수에 공백 포함 시 따옴표 없이 사용 | `"$VAR"` 항상 쌍따옴표로 감싸기 |
| `sed -i` 로 원본 백업 없이 수정 | `-i.bak` 으로 백업 파일 생성 |
| awk에서 문자열 비교를 `==` 대신 숫자 비교 | 문자열: `$1 == "foo"`, 숫자: `$3 > 100` |
| 함수 내 변수가 전역을 오염 | 함수 내 변수는 반드시 `local` 선언 |
| 파이프 중간 실패 감지 못함 | `set -o pipefail` 또는 `PIPESTATUS` 확인 |
| 대용량 파일에 `cat \| grep` | `grep 'pattern' file` 직접 지정이 빠름 |
| `sort \| uniq`로 중복 제거 시 순서 소실 | 순서 유지 필요하면 `awk '!seen[$0]++'` |
