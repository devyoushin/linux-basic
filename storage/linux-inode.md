# inode, 파일 디스크립터, 링크 - 파일시스템 내부 구조

## 1. 개요

리눅스에서 "파일"은 이름이 아니라 inode 번호로 식별된다. 파일명은 단순히 inode를 가리키는 포인터이며, inode에는 권한·크기·타임스탬프·데이터 블록 주소가 저장된다. inode 고갈, "deleted but still open" 디스크 풀, 파일 디스크립터 한도 초과 등은 운영 중 자주 마주치는 장애 패턴이며, 내부 구조를 이해해야 빠르게 진단할 수 있다.

---

## 2. inode 구조와 파일시스템 레이아웃

### 2.1 파일시스템 온디스크 구조

```
디스크 파티션 (/dev/xvdb1)
┌─────────────────────────────────────────────────────────────┐
│ Superblock │ Block Group 0  │ Block Group 1  │ ...          │
└─────────────────────────────────────────────────────────────┘

Block Group 내부:
┌──────────┬────────────┬───────────┬──────────────────────────┐
│  Group   │   inode    │   inode   │      Data Blocks          │
│ Bitmap   │   Bitmap   │   Table   │  (실제 파일 데이터)       │
└──────────┴────────────┴───────────┴──────────────────────────┘

inode Table 내 하나의 inode (128 또는 256 bytes):
┌────────────────────────────────────────────┐
│ 파일 타입 + 권한 (i_mode)                  │
│ UID / GID                                  │
│ 파일 크기 (i_size)                         │
│ atime / mtime / ctime / crtime             │
│ 링크 카운트 (i_links_count)                │
│ 데이터 블록 포인터 (direct x12)            │
│ 싱글 indirect 포인터                       │
│ 더블 indirect 포인터                       │
│ 트리플 indirect 포인터                     │
└────────────────────────────────────────────┘
        ↓
   Data Blocks (실제 파일 내용)
```

### 2.2 inode에 없는 것: 파일명

파일명은 inode에 저장되지 않는다. 디렉토리는 `(파일명 → inode 번호)` 매핑 테이블이며, 이 항목을 **dentry(directory entry)**라고 한다.

```
/var/log/nginx/access.log 접근 시 커널 경로 탐색:

/ (inode 2) → var (inode 131073) → log (inode 131074)
           → nginx (inode 262145) → access.log (inode 393217)

각 디렉토리에서 이름 → inode 번호 룩업이 발생
dentry cache(dcache): 자주 접근하는 경로를 메모리에 캐시
```

```bash
# inode 번호 확인
ls -i /var/log/nginx/access.log
# 393217 /var/log/nginx/access.log

# inode 상세 정보
stat /var/log/nginx/access.log
# File: /var/log/nginx/access.log
# Size: 1048576    Blocks: 2056    IO Block: 4096  regular file
# Device: xvda1    Inode: 393217   Links: 1
# Access: 2024-01-15 03:00:01
# Modify: 2024-01-15 03:00:01
# Change: 2024-01-15 03:00:01
```

---

## 3. inode 고갈 장애

### 3.1 고갈 원인과 증상

inode 수는 파일시스템 생성 시 고정된다(ext4 기본: 바이트당 1 inode, 약 16K 파일/GB). 수많은 소용량 파일(이메일 큐, 캐시 파일, 임시 파일)을 생성하면 디스크 공간은 남아도 inode가 부족해 파일 생성이 실패한다.

```
증상: "No space left on device" 오류
      → df -h로 확인 시 디스크 여유 있음
      → df -i로 확인하면 IUse% 100%
```

```bash
# inode 사용률 확인 (IUse% 가 핵심)
df -i
# Filesystem      Inodes  IUsed  IFree IUse% Mounted on
# /dev/xvda1     3276800 3276800    0  100% /         ← 고갈!
# /dev/xvdb1     6553600  12345  6541255  1% /data

# 디렉토리별 파일 수 카운트 (고갈 원인 찾기)
# (파일 수가 많은 디렉토리 상위 10개)
find / -xdev -printf '%h\n' 2>/dev/null | sort | uniq -c | sort -rn | head -20

# 또는 각 디렉토리의 파일/디렉토리 수
for dir in /tmp /var/spool /var/cache /var/lib; do
  count=$(find "$dir" -maxdepth 3 | wc -l)
  echo "$count $dir"
done | sort -rn
```

### 3.2 inode 고갈 대응

```bash
# 임시 파일 정리 (tmp 디렉토리)
find /tmp -type f -atime +7 -delete   # 7일 이상 미접근 파일 삭제

# Postfix 메일 큐 정리 (이메일 서버 inode 고갈 대표 사례)
postsuper -d ALL deferred             # deferred 큐 전체 삭제

# PHP-FPM 세션 파일 정리
find /var/lib/php/sessions -type f -mtime +1 -delete

# 근본 해결: 파일시스템 재생성 시 inode 수 늘리기
# -i bytes-per-inode: 값이 작을수록 inode 수 증가
mkfs.ext4 -i 4096 /dev/xvdb1         # 기본(16384)의 4배 inode 생성

# xfs는 inode 수가 동적으로 증가 (고갈 문제 거의 없음)
mkfs.xfs /dev/xvdb1
```

---

## 4. 하드링크 vs 심볼릭링크

### 4.1 inode 관점에서의 차이

```
하드링크:
  /data/file.txt  (dentry)  ─┐
                              ├→ inode 12345 → 데이터 블록
  /backup/file.txt (dentry) ─┘
  (같은 inode를 두 개의 dentry가 가리킴, i_links_count = 2)

심볼릭링크:
  /data/link.txt  (dentry) → inode 99999 → "/data/file.txt" (경로 문자열)
                                            ↓ (별도 룩업)
                                         inode 12345 → 데이터 블록
  (링크 자체가 별도 inode를 가지며, 내용은 경로 문자열)
```

```bash
# 하드링크 생성
ln /data/file.txt /backup/file.txt

# 심볼릭링크 생성
ln -s /data/file.txt /backup/link.txt

# inode 번호로 하드링크 관계 확인
ls -i /data/file.txt /backup/file.txt
# 12345 /data/file.txt
# 12345 /backup/file.txt        ← 동일 inode

# 하드링크 수 확인 (stat의 Links 필드)
stat /data/file.txt
# Inode: 12345    Links: 2

# 특정 inode를 가진 모든 파일 찾기 (하드링크 탐색)
find /data /backup -inum 12345
```

| 특성 | 하드링크 | 심볼릭링크 |
|------|---------|-----------|
| 파일시스템 경계 | 같은 파일시스템만 | 다른 파일시스템 가능 |
| 디렉토리 링크 | 불가 (루트만 예외) | 가능 |
| 원본 삭제 시 | 데이터 유지 (링크 카운트 감소) | 댕글링 링크(broken) 됨 |
| inode | 원본과 동일 | 별도 inode |
| 크기 | 0 추가 비용 | 경로 길이만큼 블록 소비 |

---

## 5. 파일 디스크립터 (File Descriptor)

### 5.1 fd 구조

```
프로세스 (PID 1234)
┌─────────────────────────────────┐
│ fd 테이블 (프로세스별)           │
│  0 → stdin  (파이프/터미널)      │
│  1 → stdout (파이프/터미널)      │
│  2 → stderr (파이프/터미널)      │
│  3 → /var/log/app.log           │
│  4 → socket(TCP :8080)          │
│  5 → /tmp/lock.file             │
└────────────────┬────────────────┘
                 │
┌────────────────▼────────────────┐
│ open file table (커널 전역)      │
│  파일 오프셋, 플래그, 참조 카운트 │
└────────────────┬────────────────┘
                 │
┌────────────────▼────────────────┐
│ inode (파일시스템)               │
│  실제 데이터 블록 포인터          │
└─────────────────────────────────┘
```

```bash
# 프로세스의 열린 fd 목록 확인
ls -la /proc/1234/fd/
# lrwxrwxrwx 1 root root 64 ... 0 -> /dev/null
# lrwxrwxrwx 1 root root 64 ... 3 -> /var/log/app.log
# lrwxrwxrwx 1 root root 64 ... 4 -> socket:[123456]

# 현재 프로세스가 사용 중인 fd 수
ls /proc/1234/fd | wc -l

# 시스템 전체 열린 파일 수
cat /proc/sys/fs/file-nr
# 3456  0  800000
# (현재 열린 수) (사용 가능 수) (최대값)
```

### 5.2 fd 한도 설정 계층

```
설정 계층 (낮은 우선순위 → 높은 우선순위):

1. 커널 전체 최대값
   /proc/sys/fs/file-max        # 모든 프로세스의 총 fd 합산 한도

2. 사용자/세션 한도
   ulimit -n                    # 현재 세션의 소프트/하드 한도
   /etc/security/limits.conf    # PAM 로그인 시 적용

3. systemd 서비스 한도
   LimitNOFILE=                 # /etc/systemd/system/myapp.service
```

```bash
# 현재 fd 한도 확인
ulimit -n                      # 소프트 한도 (기본 1024 또는 65536)
ulimit -Hn                     # 하드 한도

# 커널 파라미터로 시스템 전체 최대값 변경
sysctl fs.file-max             # 현재 값 확인
sysctl -w fs.file-max=2097152  # 즉시 적용

# 영구 적용
cat >> /etc/sysctl.conf <<'EOF'
fs.file-max = 2097152
EOF

# /etc/security/limits.conf 설정 (PAM 세션에 적용)
# 도메인    타입    항목    값
# *        soft    nofile  65536
# *        hard    nofile  131072
# nginx    soft    nofile  200000
# nginx    hard    nofile  200000
```

### 5.3 systemd 서비스의 fd 한도

```ini
# /etc/systemd/system/myapp.service
[Service]
LimitNOFILE=200000

# > **주의**: systemd의 LimitNOFILE은 limits.conf보다 독립적으로 적용된다.
# limits.conf를 수정해도 systemd 서비스에는 반영되지 않는다.
```

```bash
# systemd 서비스의 실제 fd 한도 확인
cat /proc/$(pidof myapp)/limits | grep -i "open files"
# Max open files  200000  200000  files

# 변경 후 서비스 재시작
systemctl daemon-reload
systemctl restart myapp
```

---

## 6. "deleted but still open" 디스크 풀 장애

### 6.1 현상 및 원인

파일을 `rm`으로 삭제해도 해당 파일을 열고 있는 프로세스가 있으면 inode의 링크 카운트는 0이 되지만 fd 참조가 있어 실제 데이터 블록은 해제되지 않는다. 디스크 공간도 반환되지 않는다.

```
rm /var/log/app.log 실행 후:
  dentry 삭제: 파일명 → inode 매핑 제거
  inode.i_links_count: 1 → 0

  BUT: 프로세스 PID 5678이 fd 3으로 해당 파일을 열고 있음
  → 커널이 inode 유지 (참조 카운트 > 0)
  → 데이터 블록 미해제 → df -h에서 공간 반환 안 됨
  → ls로 파일이 보이지 않지만 디스크는 차 있음
```

```bash
# 증상: df -h에서 꽉 찼는데 du -sh /*로 찾을 수 없는 공간 존재

# 진단: 삭제됐지만 열려 있는 파일 찾기
lsof +L1
# COMMAND  PID  USER  FD  TYPE  DEVICE  SIZE  NLINK  NAME
# myapp   5678  root   3r  REG   xvda1   5.0G    0   /var/log/app.log (deleted)
# nginx   1234  www    7w  REG   xvda1   2.0G    0   /var/log/nginx/access.log (deleted)

# NLINK=0: 파일시스템에서 삭제됐지만 fd 참조가 살아있음

# 해결 방법 1: 프로세스 재시작 (fd 해제)
systemctl restart myapp

# 해결 방법 2: 프로세스 종료 없이 파일 내용만 truncate
# /proc/PID/fd/FD_NUM 경로를 통해 직접 비우기
truncate -s 0 /proc/5678/fd/3    # 즉시 공간 반환

# 해결 방법 3: 로그로테이트 설정 (근본 해결)
# logrotate는 copytruncate 옵션으로 프로세스 재시작 없이 로그 로테이트 가능
```

### 6.2 lsof 및 /proc/PID/fd 활용

```bash
# 특정 파일을 열고 있는 프로세스 찾기
lsof /var/log/app.log

# 특정 프로세스의 모든 열린 파일
lsof -p 5678

# 네트워크 소켓만 확인
lsof -i :8080                  # 8080 포트 사용 프로세스

# 소켓 fd 상세 (포트, 상태)
lsof -i -n -P | grep LISTEN

# /proc/PID/fd 직접 확인
ls -la /proc/5678/fd/
# fd 번호 → 실제 파일 경로 심볼릭링크

# fd가 가리키는 파일의 inode 확인
stat /proc/5678/fd/3
```

---

## 7. 실전 트러블슈팅 패턴

### 7.1 AWS EC2 루트 볼륨 꽉 참 진단 플로우

```
df -h 확인 → 공간 없음
     ↓
df -i 확인 → inode 문제인가?
  ├─ IUse% 100%: inode 고갈
  │    → find / -xdev -printf '%h\n' | sort | uniq -c | sort -rn | head
  │    → 임시파일/캐시/로그 정리
  │
  └─ 블록 사용률 100%: 실제 공간 부족
       ↓
  du -sh /* --exclude=/proc 로 디렉토리별 확인
       ↓
  lsof +L1 확인 → deleted but open 파일 있는가?
    ├─ 있음: truncate 또는 프로세스 재시작
    └─ 없음: du 결과 기반으로 대용량 디렉토리 정리
```

### 7.2 Docker 컨테이너에서 inode/fd 고갈

```bash
# 컨테이너 내 inode 확인 (overlay 파일시스템)
docker exec mycontainer df -i

# 컨테이너 프로세스의 fd 한도 확인
docker exec mycontainer cat /proc/1/limits

# docker run 시 fd 한도 설정
docker run --ulimit nofile=65536:65536 myimage

# docker-compose
services:
  app:
    image: myimage
    ulimits:
      nofile:
        soft: 65536
        hard: 131072
```

---

## 8. 자주 하는 실수

| 실수 | 원인 | 올바른 방법 |
|------|------|-------------|
| `rm`으로 지웠는데 공간이 안 늘어남 | deleted but still open 상태 | `lsof +L1`로 확인 후 프로세스 재시작 또는 `truncate` |
| `df -h`로만 용량 확인 | inode 고갈 미감지 | `df -h`와 `df -i` 항상 함께 확인 |
| `ulimit -n` 변경 후 서비스에 반영 안 됨 | systemd 서비스는 별도 설정 필요 | `systemd` 서비스에 `LimitNOFILE` 추가 후 재시작 |
| 하드링크와 심볼릭링크 혼동 | 동작 차이 미숙지 | 원본 삭제 후 동작 여부로 구분 (하드링크: 유지, 심볼릭: 깨짐) |
| inode 고갈 예방 없이 서비스 운영 | 모니터링 미설정 | `df -i` 및 inode 사용률 CloudWatch 알람 설정 |
| `/proc/PID/fd` 경로 모름 | 내부 구조 미숙지 | 프로세스 진단 시 `/proc/PID/fd/`, `/proc/PID/limits` 적극 활용 |
| ext4에서 inode 수 부족 | 파일시스템 생성 시 기본값 사용 | 소용량 파일 대량 생성 환경에서 `-i 4096` 옵션으로 mkfs |
