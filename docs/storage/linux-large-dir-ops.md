# 대용량 파일 트리에서의 명령어 성능 — du, chown, find 느린 이유와 해결책

## 1. 개요

`du`, `chown -R`, `find` 같은 명령어는 파일 수가 수십만~수백만 개가 되면 체감상 수십 분씩 걸리기도 한다.
단순히 "파일이 많아서"가 아니라, **디렉토리 트리를 inode 단위로 하나씩 순회하면서 syscall을 반복**하기 때문이다.
이 문서는 동작 원리를 이해하고, 실무에서 쓸 수 있는 가속 기법을 정리한다.

---

## 2. 왜 느린가 — 동작 원리

### 2.1 디렉토리 트리 순회 구조

```
du -sh /data
  └─ openat("/data")                  # 디렉토리 열기
      └─ getdents64()                 # 디렉토리 엔트리 읽기
          └─ for each entry:
              ├─ lstat(entry)         # 파일 메타데이터 읽기 (inode 접근)
              ├─ openat(entry)        # 하위 디렉토리면 재귀
              └─ getdents64()         # 반복
```

파일 1개당 최소 **1회 `lstat()` syscall** 이 발생한다.
파일이 100만 개라면 syscall 100만 번 + 커널/유저 모드 전환 100만 번이다.

### 2.2 Random I/O 문제 (HDD 환경)

inode는 디스크에 물리적으로 흩어져 있다. 디렉토리 엔트리 순서대로 inode를 읽으면
**HDD에서 랜덤 seek가 반복**된다. 파일 수가 많을수록 seek 거리가 늘어나 I/O 대기가 급격히 증가한다.

```
# iostat으로 확인 — await(ms)가 높으면 seek 병목
iostat -x 1
```

> SSD/NVMe 환경에서는 seek 패널티가 없으므로 HDD 대비 수십 배 빠르다.

### 2.3 `chown -R`이 특히 느린 이유

`chown`은 단순 메타데이터 변경이지만:

1. 각 파일에 `lstat()` → `fchownat()` 2회 syscall
2. 변경 시마다 **inode dirty mark** → 저널 쓰기 (ext4/xfs)
3. 파일 수 × 저널 flush = 쓰기 I/O 폭증

```bash
# strace로 확인 — fchownat 반복 확인
strace -c chown -R user:group /data 2>&1 | grep fchownat
```

### 2.4 페이지 캐시와 dentry 캐시

처음 실행 시에는 캐시가 비어있어 느리고, 같은 경로를 바로 다시 실행하면 빠르다.
이것은 **VFS dentry/inode 캐시**가 채워졌기 때문이다. 실제 운영 중인 서버에서는 다른 프로세스가 캐시를 경쟁한다.

```bash
# 캐시 강제 비우기 (테스트 목적)
echo 3 > /proc/sys/vm/drop_caches

# dentry 캐시 사용량 확인
slabtop | grep dentry
```

---

## 3. 빠르게 하는 방법

### 3.1 `du` 속도 개선

#### 방법 1: `--apparent-size` 제거, `-x`로 마운트 경계 제한

```bash
# 기본 (느림 — 실제 블록 단위 계산)
du -sh /data

# 빠름 — 동일 파일시스템만, 바이트 단위 계산 생략
du -sh --inodes /data          # inode 수만 셈 (디스크 사용량 불필요할 때)
du -sx /data                   # 다른 마운트 포인트 제외 (-x)
```

#### 방법 2: `find` + `awk` 조합으로 병렬화

```bash
# GNU parallel로 최상위 디렉토리를 나눠 병렬 실행
find /data -maxdepth 1 -mindepth 1 -type d | \
  parallel -j4 du -sh {} | sort -h
```

#### 방법 3: `ncdu` — 빠른 인터랙티브 용량 조회

```bash
yum install ncdu   # or apt install ncdu

# 멀티스레드 인덱싱 후 인터랙티브 탐색
ncdu /data
```

#### 방법 4: `dua-cli` — 병렬 처리 CLI 도구

```bash
# 러스트 기반, 멀티스레드 du 대체
cargo install dua-cli
dua /data
```

---

### 3.2 `chown -R` 속도 개선

#### 방법 1: `find` + `-exec` 대신 `xargs -P` 병렬화

```bash
# 느림 — 직렬 순회
chown -R user:group /data

# 빠름 — find로 파일 목록 만들고 xargs로 병렬 chown
find /data -print0 | xargs -0 -P8 -n500 chown user:group
# -P8: 8개 프로세스 병렬
# -n500: 한 번에 500개 파일씩 처리 (fork 오버헤드 줄임)
```

#### 방법 2: `--from` 옵션으로 불필요한 변경 건너뛰기

```bash
# 이미 올바른 소유자인 파일은 syscall 건너뜀
chown --from=root:root user:group /data/file

# find와 결합 — 소유자가 다른 파일만 처리
find /data ! -user user -o ! -group group | \
  xargs -P8 -n500 chown user:group
```

#### 방법 3: rsync의 `--chown` 활용 (원격 복사 겸용)

```bash
# 복사하면서 소유자 변경 — 단일 패스로 처리
rsync -a --chown=user:group /data/ /dest/
```

#### 방법 4: newuidmap / bindmount (컨테이너 환경)

```bash
# 컨테이너 이미지 레이어 전체를 chown할 때
# → OverlayFS upper 레이어만 대상으로 제한
find /var/lib/docker/overlay2/<layer>/diff -print0 | \
  xargs -0 -P8 -n1000 chown user:group
```

---

### 3.3 `find` 속도 개선

```bash
# 느림 — 기본
find /data -name "*.log"

# 빠름 — 파일시스템 경계 제한, 불필요한 stat 제거
find /data -xdev -name "*.log"

# 빠름 — maxdepth 제한
find /data -maxdepth 3 -name "*.log"

# 빠름 — locate DB 활용 (사전 인덱싱 필요)
updatedb                        # 인덱스 업데이트 (cron으로 주기 실행)
locate "*.log" | grep "^/data"

# 빠름 — fd (rust 기반 find 대체, 병렬 처리)
fd -e log . /data
```

---

### 3.4 XFS / ext4 설정 튜닝

```bash
# XFS: 디렉토리 btree 블록 크기 확인 (큰 디렉토리 성능에 영향)
xfs_info /dev/xvdf

# ext4: dir_index 기능 확인 (HTree 인덱스 — 대형 디렉토리 검색 O(log n))
tune2fs -l /dev/xvdf | grep "dir_index"

# ext4: htree 인덱스 강제 활성화
tune2fs -O dir_index /dev/xvdf
e2fsck -fD /dev/xvdf            # htree 재구성 (언마운트 상태에서)
```

---

### 3.5 NFS/EFS 환경에서 더 느린 이유와 대응

NFS에서 `chown -R` 또는 `du`를 실행하면 로컬 대비 10~100배 느릴 수 있다.

| 원인 | 설명 |
|---|---|
| `lstat()` 네트워크 왕복 | 파일마다 RPC 1회 = RTT × 파일 수 |
| `close-to-open` 일관성 | 쓰기 후 즉시 flush 강제 |
| EFS Bursting 한도 초과 | 버스트 크레딧 소진 시 I/O 쓰로틀링 |

```bash
# NFS 마운트 옵션으로 완화
mount -t nfs -o rsize=1048576,wsize=1048576,noatime,nodiratime server:/share /mnt

# EFS: 병렬 청크 복사 (AWS 권장 도구)
fpart -n 4 -o /tmp/fpart /efs/data    # 트리를 4등분
parallel -j4 "chown -f user:group -- {}" :::: /tmp/fpart.{0,1,2,3}
```

---

### 3.6 진행 상황 모니터링

```bash
# 실행 중인 chown/du의 진행 상황 — lsof로 현재 접근 중인 파일 확인
lsof -p $(pgrep chown) 2>/dev/null | tail -5

# strace로 syscall 통계 (완료 후 요약)
strace -c -f chown -R user:group /data 2>&1

# pv로 find 파이프의 처리량 모니터링
find /data -print0 | pv -l -N "files" | xargs -0 -P8 -n500 chown user:group
# -l: 줄(파일) 단위로 카운트
```

---

## 4. 접근 방법 요약 비교

| 상황 | 권장 방법 |
|---|---|
| du가 느릴 때 | `ncdu`, `dua`, 또는 `find \| parallel du` |
| chown -R이 느릴 때 | `find \| xargs -P8 chown`, `--from` 옵션으로 필터링 |
| find가 느릴 때 | `locate`, `fd`, `-xdev`, `-maxdepth` 제한 |
| NFS/EFS 환경 | `fpart`로 분할 후 병렬, 마운트 옵션 튜닝 |
| HDD 환경 | SSD 마이그레이션이 근본 해결책; 그 전까지 병렬화 |
| 모니터링 | `strace -c`, `pv`, `lsof -p` |

---

## 5. 자주 하는 실수

| 실수 | 올바른 방법 |
|---|---|
| `chown -R`을 NFS 루트에서 실행 | 로컬 캐시 서버나 EC2에서 직접 EFS 경로를 나눠 병렬 실행 |
| `du -sh`를 운영 중 `/` 에서 실행 | `-x`로 마운트 경계 제한, `--exclude` 로 tmpfs/proc 제외 |
| `find -exec chown {} \;`로 파일마다 fork | `find -print0 \| xargs -0 -P8 -n500 chown` 으로 일괄 처리 |
| 진행 상황 없이 백그라운드 실행 | `pv` 또는 `progress` 명령어로 처리량 모니터링 |
| inode 고갈인데 du로 용량 확인 | `df -i`로 inode 사용률 먼저 확인 |
| drop_caches 후 재실행으로 성능 측정 | 운영 환경 캐시 워밍 상태에서 측정해야 실제 성능 반영 |
