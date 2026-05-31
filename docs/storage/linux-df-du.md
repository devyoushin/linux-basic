## 1. 개요

`df`(disk free)는 파일시스템 단위로 전체/사용/여유 공간을 보여주고,
`du`(disk usage)는 특정 디렉토리나 파일이 실제로 차지하는 공간을 보여준다.
디스크 풀(disk full) 장애는 서비스 중단으로 이어지므로, 이 두 명령어를 조합한 빠른 원인 파악이 중요하다.

---

## 2. df - 파일시스템 사용량

### 2.1 기본 사용법

```bash
# 전체 파일시스템 목록 (사람이 읽기 쉬운 단위)
df -h

# 출력 예시:
# Filesystem      Size  Used Avail Use% Mounted on
# /dev/xvda1       20G   14G  5.2G  74% /
# /dev/xvdf       100G   61M   95G   1% /data
# tmpfs           3.9G     0  3.9G   0% /dev/shm

# 특정 경로가 속한 파일시스템만 확인
df -h /var/log
df -h /data

# inode 사용량 확인 (파일 수 한도)
df -i
# inode 소진 시 디스크 공간이 남아도 "No space left on device" 에러 발생
```

### 2.2 출력 컬럼 설명

| 컬럼 | 설명 |
|---|---|
| `Filesystem` | 디바이스 또는 마운트 소스 |
| `Size` | 파일시스템 전체 크기 |
| `Used` | 사용 중인 공간 |
| `Avail` | 실제 사용 가능한 공간 (예약 공간 제외) |
| `Use%` | 사용률 (`Used / (Used + Avail)`) |
| `Mounted on` | 마운트 포인트 |

> **팁**: `Use%`가 100%여도 `Avail`이 남아있을 수 있다. ext4는 기본적으로 5%를 root 예약 공간으로 남겨둔다.

### 2.3 실무 활용

```bash
# 사용률 80% 이상인 파티션만 필터링
df -h | awk 'NR>1 && $5+0 >= 80 {print $0}'

# tmpfs, overlay 등 가상 파일시스템 제외하고 실제 디스크만
df -h --type=ext4 --type=xfs

# 모니터링 스크립트: 90% 초과 시 경고 출력
df -h | awk 'NR>1 {
    gsub(/%/, "", $5)
    if ($5+0 >= 90)
        printf "[경고] %s 사용률 %s%% (여유: %s)\n", $6, $5, $4
}'
```

---

## 3. du - 디렉토리/파일 사용량

### 3.1 기본 사용법

```bash
# 현재 디렉토리 전체 사용량 (하위 포함)
du -sh .

# 특정 디렉토리 사용량
du -sh /var/log
du -sh /home/*    # 사용자별 홈 디렉토리 크기

# 하위 디렉토리 각각의 크기 (1단계만)
du -h --max-depth=1 /var
du -hd1 /var       # --max-depth=1 축약형
```

### 3.2 큰 파일/디렉토리 찾기

```bash
# 특정 디렉토리에서 가장 큰 하위 항목 top 10
du -h /var | sort -rh | head -10

# 전체 시스템에서 가장 큰 파일 top 20 (find 활용)
find / -type f -printf '%s %p\n' 2>/dev/null \
    | sort -rn \
    | head -20 \
    | awk '{printf "%.1fMB  %s\n", $1/1024/1024, $2}'

# 특정 크기 이상 파일 찾기 (100MB 이상)
find /var -type f -size +100M -exec ls -lh {} \;

# 최근 수정된 큰 파일 찾기 (최근 1일, 50MB 이상)
find / -type f -size +50M -mtime -1 2>/dev/null
```

### 3.3 로그 디렉토리 분석 (디스크 풀 장애 대응)

```bash
# 1단계: df로 어느 파티션이 문제인지 확인
df -h

# 2단계: 문제 파티션의 루트 디렉토리부터 탐색
du -hd1 / 2>/dev/null | sort -rh | head -10

# 3단계: 가장 큰 디렉토리 내부로 반복 탐색
du -hd1 /var | sort -rh | head -10
du -hd1 /var/log | sort -rh | head -10

# 4단계: 큰 파일 직접 확인
ls -lhS /var/log/ | head -20   # 크기순 정렬
```

---

## 4. 디스크 풀(Disk Full) 장애 대응 순서

### 4.1 빠른 원인 파악

```bash
# 즉시 실행 - 어느 파티션이 가득 찼는지
df -h

# inode 소진 여부도 확인
df -i | awk '$5+0 >= 80 || NR==1'
```

### 4.2 공간 확보 - 로그 파일

```bash
# 오래된 로그 파일 찾기
find /var/log -name "*.log" -mtime +30 | xargs ls -lh 2>/dev/null

# 압축된 오래된 로그 삭제
find /var/log -name "*.gz" -mtime +7 -delete

# journal 로그 정리 (systemd)
journalctl --vacuum-time=7d
journalctl --vacuum-size=200M

# 특정 서비스 로그 직접 비우기 (삭제 말고 truncate - 프로세스가 파일 열고 있을 때)
truncate -s 0 /var/log/nginx/access.log
```

### 4.3 공간 확보 - 패키지 캐시

```bash
# apt 패키지 캐시 정리 (Ubuntu)
apt clean           # /var/cache/apt/archives/ 정리
apt autoremove -y   # 불필요한 패키지 제거

# yum/dnf 캐시 정리
yum clean all
dnf clean all

# Docker 미사용 리소스 정리
docker system prune -f
docker system prune -a -f   # 태그 없는 이미지까지 모두 삭제
```

### 4.4 삭제됐지만 공간이 안 늘어나는 경우

파일을 삭제해도 **프로세스가 파일 핸들을 열고 있으면** 공간이 해제되지 않는다.

```bash
# 삭제됐지만 열린 채로 남은 파일 찾기
lsof | grep deleted | awk '{print $1, $2, $7}' | sort -k3 -rh | head -10

# 해당 프로세스 재시작 후 공간 해제됨
systemctl restart nginx   # 예시
```

---

## 5. 디스크 사용률 적정 기준

### 5.1 볼륨 용도별 권장 임계값

| 볼륨 용도 | 경고 기준 | 위험 기준 | 이유 |
|---|---|---|---|
| 루트 (`/`) | **70%** | **80%** | OS 업데이트, 패키지 설치 여유 공간 필요 |
| 데이터 볼륨 (`/data`) | **75%** | **85%** | 작업 임시 파일, 인덱스 재생성 공간 |
| 로그 볼륨 (`/var/log`) | **80%** | **90%** | 증가 패턴이 예측 가능해 더 높게 허용 가능 |
| DB 볼륨 | **70%** | **80%** | 트랜잭션 로그, 임시 정렬 공간 필요 |
| 임시 파일 (`/tmp`) | **60%** | **75%** | 스파이크성 급증 대비 여유 크게 유지 |

> **실무 기준**: 루트 볼륨은 80%를 넘기 전에 반드시 확장 계획을 세운다. 80~90% 구간은 예상보다 빠르게 포화된다.

### 5.2 ext4 예약 공간 (reserved blocks)

ext4는 기본적으로 **전체의 5%를 root 전용 예약 공간**으로 남긴다.
일반 사용자는 이 공간을 쓸 수 없으므로 `df -h`의 `Use%` 100%는 실제로는 ~95% 사용 상태다.

```bash
# 현재 예약 블록 비율 확인
tune2fs -l /dev/xvdf | grep -i reserved
# Reserved block count: 524288
# Reserved GDT blocks: 255

# 데이터 전용 볼륨은 예약 공간 줄여도 됨 (1%로 축소)
tune2fs -m 1 /dev/xvdf
# ※ 루트 볼륨에는 적용 금지 - OS가 꽉 찼을 때 root 작업 공간 없어짐

# xfs는 예약 블록 개념 없음 (Use% 100% = 실제 100%)
```

### 5.3 inode 사용률 기준

디스크 용량이 남아도 inode가 소진되면 **"No space left on device"** 에러 발생.

```bash
# inode 사용률 확인
df -i
# Filesystem      Inodes  IUsed   IFree IUse% Mounted on
# /dev/xvda1     1310720 312048  998672   24% /

# 위험 신호: IUse% 70% 이상이면 주의
```

| inode 사용률 | 상태 | 조치 |
|---|---|---|
| ~60% | 정상 | 모니터링 유지 |
| 60~80% | 주의 | 소규모 파일 생성 패턴 확인 (캐시, 세션 파일) |
| 80~95% | 경고 | 불필요한 소규모 파일 정리 또는 볼륨 재생성 |
| 95%+ | 위험 | 즉시 정리 or 파일시스템 재포맷 (inode 수 늘려서) |

```bash
# inode 고갈 원인 찾기 - 파일 수 많은 디렉토리
find / -xdev -printf '%h\n' 2>/dev/null | sort | uniq -c | sort -rn | head -10

# 특정 디렉토리 파일 수 세기
find /var/spool -type f | wc -l
```

### 5.4 확장 트리거 기준 (CloudWatch 알람 예시)

```
사용률 흐름:        조치:
0% ────────────────────────────────────────
                   정상 운영
70% ───────────────────────────────────────
                   [계획] 확장 일정 수립, 볼륨 크기 검토
80% ───────────────────────────────────────
                   [알람] CloudWatch 경보 발생, 담당자 알림
                          → EBS 콘솔에서 볼륨 확장 시작
85% ───────────────────────────────────────
                   [긴급] 즉시 불필요한 파일 정리
                          + 확장 완료 전 임시 공간 확보
90% ───────────────────────────────────────
                   [장애 직전] 서비스 영향 가능
95%+ ──────────────────────────────────────
                   [장애] 쓰기 실패, 서비스 중단
```

```bash
# CloudWatch에서 EBS 사용률 알람 생성 (AWS CLI)
aws cloudwatch put-metric-alarm \
  --alarm-name "disk-usage-high-root" \
  --metric-name disk_used_percent \
  --namespace CWAgent \               # CloudWatch Agent 필요
  --dimensions Name=path,Value=/ \
  --statistic Average \
  --period 300 \
  --evaluation-periods 2 \
  --threshold 80 \
  --comparison-operator GreaterThanOrEqualToThreshold \
  --alarm-actions arn:aws:sns:ap-northeast-2:123456789012:ops-alert
```

### 5.5 용량 증가 추세 분석

현재 사용률만 보지 말고 **증가 속도**를 봐야 한다. 70%여도 하루 1%씩 늘면 30일 후 장애다.

```bash
# 매일 df 결과를 파일로 저장 (crontab)
# 0 9 * * * df -h >> /var/log/disk_usage_history.log

# 저장된 이력에서 특정 파티션 추이 확인
grep "^/dev/xvda1" /var/log/disk_usage_history.log | awk '{print $5}' | tail -30
```

---

## 6. 디스크 사용량 모니터링 스크립트

```bash
#!/bin/bash
# 디스크 사용량 체크 및 알림 (crontab에 등록)
# */10 * * * * /opt/scripts/check_disk.sh

THRESHOLD_WARN=80
THRESHOLD_CRIT=90
SLACK_WEBHOOK="${SLACK_WEBHOOK_URL:-}"

HOSTNAME=$(hostname)
ALERT=0

while IFS= read -r line; do
    USAGE=$(echo "$line" | awk '{gsub(/%/,""); print $5}')
    MOUNT=$(echo "$line" | awk '{print $6}')

    # tmpfs, overlay 등 제외
    [[ "$MOUNT" == tmpfs* ]] && continue
    [[ "$MOUNT" == /dev* ]] && continue

    if (( USAGE >= THRESHOLD_CRIT )); then
        echo "[CRITICAL] ${HOSTNAME}: ${MOUNT} 사용률 ${USAGE}%"
        ALERT=1
    elif (( USAGE >= THRESHOLD_WARN )); then
        echo "[WARNING]  ${HOSTNAME}: ${MOUNT} 사용률 ${USAGE}%"
        ALERT=1
    fi
done < <(df -h | awk 'NR>1')

# Slack 알림 (webhook 설정된 경우)
if (( ALERT == 1 )) && [[ -n "$SLACK_WEBHOOK" ]]; then
    df -h | awk 'NR>1 && $5+0 >= '"$THRESHOLD_WARN"' {
        printf "%-20s %s\n", $6, $5
    }' | while read -r msg; do
        curl -s -X POST "$SLACK_WEBHOOK" \
            -H 'Content-type: application/json' \
            -d "{\"text\":\"[디스크 경고] ${HOSTNAME}: ${msg}\"}"
    done
fi
```

## 7. 자주 하는 실수

| 실수 | 올바른 방법 |
|---|---|
| `df -h` 100%인데 파일 삭제해도 공간 안 늘어남 | `lsof \| grep deleted` 로 열린 파일 확인 후 프로세스 재시작 |
| inode 소진인데 공간 있다고 착각 | `df -i` 로 inode 사용률 별도 확인 |
| `du -sh /*` 합산이 `df` 사용량보다 작음 | `lsof \| grep deleted` 로 삭제됐지만 열린 파일 확인 |
| 대형 로그 파일을 `rm`으로 삭제 (프로세스가 열고 있는 경우) | `truncate -s 0 파일명` 으로 비우기 |
| `/tmp`가 꽉 차서 서비스 장애 | `/tmp` 별도 파티션 또는 tmpfs 크기 제한 설정 |
