# ext4와 XFS 파일시스템 및 복구 가이드

## 1. 개요

Linux에서 데이터 볼륨을 운영할 때 가장 자주 선택하는 파일시스템은 `ext4`와 `xfs`다.
둘 다 안정적인 journaling 파일시스템이지만 설계 방향과 운영 방식이 다르다.

`ext4`는 범용성과 축소 지원이 장점이고, `xfs`는 대용량 파일과 병렬 I/O, 온라인 확장에 강하다.
복구 방식도 다르다. `ext4`는 `fsck`/`e2fsck`로 검사와 수리를 수행하고, `xfs`는 `xfs_repair`를 사용한다.

중요한 원칙은 하나다. **파일시스템 복구는 반드시 unmount 상태에서, 가능하면 스냅샷/백업을 먼저 만든 뒤 수행한다.**

---

## 2. 설명

### 2.1 ext4와 XFS 비교

| 항목 | ext4 | XFS |
|---|---|---|
| 기본 성격 | 범용 파일시스템 | 대용량/고성능 파일시스템 |
| journaling | metadata journaling | metadata journaling |
| 온라인 확장 | 가능 | 가능 |
| 축소(shrink) | 가능, 단 unmount 필요 | 불가능 |
| 대용량 파일 처리 | 좋음 | 매우 좋음 |
| 작은 파일 다수 | 좋음 | 좋음 |
| 복구 도구 | `fsck.ext4`, `e2fsck` | `xfs_repair` |
| 주요 배포판 기본값 | Ubuntu 계열에서 자주 사용 | RHEL, Rocky, Amazon Linux 계열에서 자주 사용 |

실무 기준은 단순하게 잡는 것이 좋다.

| 상황 | 권장 |
|---|---|
| 일반적인 애플리케이션 서버 | `ext4` 또는 `xfs` 모두 가능 |
| AWS/RHEL 계열 기본 정책을 따르는 서버 | `xfs` |
| 파일시스템 축소 가능성이 있는 볼륨 | `ext4` |
| DB, 로그, 대용량 데이터 파일 중심 | `xfs` |
| 복구 절차를 단순하게 가져가고 싶은 소규모 서버 | `ext4` |

### 2.2 파일시스템 타입 확인

```bash
# 블록 디바이스와 파일시스템 타입 확인
lsblk -f

# 마운트된 파일시스템 타입 확인
df -Th

# 특정 디바이스의 UUID와 TYPE 확인
blkid /dev/<DEVICE>

# 현재 커널이 인식한 마운트 정보 확인
findmnt
```

`/etc/fstab`에 등록된 타입과 실제 디바이스의 `TYPE`이 다르면 부팅 실패 또는 마운트 실패로 이어질 수 있다.

```bash
# fstab 등록 내용 확인
cat /etc/fstab

# fstab 문법과 마운트 가능 여부 검증
findmnt --verify

# fstab 기준으로 전체 마운트 테스트
mount -a
```

### 2.3 새 볼륨 포맷

> **주의**
> `mkfs.ext4`, `mkfs.xfs`는 대상 디바이스의 기존 데이터를 삭제한다. 신규 볼륨이거나 백업/스냅샷을 확보한 뒤 실행한다.

```bash
# ext4로 새 파일시스템 생성
mkfs.ext4 /dev/<DEVICE>

# xfs로 새 파일시스템 생성
mkfs.xfs /dev/<DEVICE>

# 라벨을 지정해서 ext4 생성
mkfs.ext4 -L data /dev/<DEVICE>

# 라벨을 지정해서 xfs 생성
mkfs.xfs -L data /dev/<DEVICE>
```

### 2.4 ext4 확장과 축소

ext4는 확장과 축소를 모두 지원한다. 다만 축소는 위험도가 높고 반드시 unmount 상태에서 수행해야 한다.

```bash
# ext4 온라인 확장
resize2fs /dev/<DEVICE>

# ext4 파일시스템 강제 검사
e2fsck -f /dev/<DEVICE>

# ext4 축소 전 검사
e2fsck -f /dev/<DEVICE>

# ext4 파일시스템을 100G로 축소
resize2fs /dev/<DEVICE> 100G
```

파티션 위에 파일시스템이 있으면 순서가 중요하다.

```text
확장:
  1. 디스크/파티션 크기 확장
  2. 파일시스템 확장

축소:
  1. 파일시스템 축소
  2. 파티션 축소
```

축소 작업은 실수하면 데이터 손상 가능성이 높다. 운영 환경에서는 축소보다 새 볼륨 생성 후 데이터 복사를 선호한다.

### 2.5 XFS 확장과 축소

XFS는 온라인 확장은 지원하지만 축소는 지원하지 않는다.

```bash
# xfs 파일시스템 온라인 확장
xfs_growfs /data

# xfs 파일시스템 정보 확인
xfs_info /data
```

XFS 볼륨을 줄여야 한다면 직접 shrink가 아니라 새 볼륨으로 마이그레이션해야 한다.

```bash
# 새 볼륨에 xfs 생성
mkfs.xfs /dev/<NEW_DEVICE>

# 새 마운트 포인트 생성
mkdir -p /new-data

# 새 볼륨 마운트
mount /dev/<NEW_DEVICE> /new-data

# 기존 데이터를 새 볼륨으로 복사
rsync -aHAX --numeric-ids /data/ /new-data/
```

### 2.6 복구 전 공통 원칙

파일시스템 복구 도구는 메타데이터를 수정한다. 따라서 복구 전 다음 순서가 안전하다.

```text
1. 장애 증상 확인
2. 쓰기 중단 또는 서비스 중지
3. 가능하면 read-only 마운트
4. 스냅샷/백업 생성
5. unmount
6. dry-run 검사
7. 실제 repair 수행
8. read-only 또는 제한된 범위로 마운트 검증
```

AWS EBS에서는 복구 전에 스냅샷을 먼저 만드는 것이 안전하다.

```bash
# AWS CLI로 EBS 스냅샷 생성
aws ec2 create-snapshot \
  --volume-id <VOLUME_ID> \
  --description "before filesystem repair"

# 스냅샷 생성 상태 확인
aws ec2 describe-snapshots \
  --snapshot-ids <SNAPSHOT_ID>
```

마운트된 파일시스템을 복구 도구로 직접 수정하면 손상이 커질 수 있다.

```bash
# 어떤 프로세스가 마운트 지점을 사용 중인지 확인
lsof +f -- /data

# 마운트 지점 사용 프로세스 확인
fuser -vm /data

# 서비스 중지 후 unmount
umount /data
```

### 2.7 ext4 복구: fsck / e2fsck

`fsck`는 파일시스템 타입에 맞는 검사 도구를 호출하는 wrapper다.
ext4에서는 보통 `fsck.ext4` 또는 `e2fsck`가 실행된다.

```bash
# 실제 수정 없이 ext4 검사
e2fsck -n /dev/<DEVICE>

# ext4 파일시스템 강제 검사
e2fsck -f /dev/<DEVICE>

# 질문에 자동 yes로 답하며 복구
e2fsck -y /dev/<DEVICE>

# fsck wrapper로 ext4 검사
fsck.ext4 -f /dev/<DEVICE>
```

`-y`는 모든 복구 질문에 yes로 답한다. 장애 상황에서 빠르지만 되돌리기 어렵다.
중요 데이터는 스냅샷/이미지 확보 후 실행한다.

```bash
# ext4 superblock 백업 위치 확인
mke2fs -n /dev/<DEVICE>

# 백업 superblock을 사용해 복구 시도
e2fsck -b <BACKUP_SUPERBLOCK> /dev/<DEVICE>
```

ext4는 `/etc/fstab`의 여섯 번째 필드(pass)에 따라 부팅 중 `fsck` 대상이 될 수 있다.

```text
UUID=...  /      ext4  defaults  0  1
UUID=...  /data  ext4  defaults  0  2
```

| pass 값 | 의미 |
|---|---|
| `0` | 부팅 중 fsck 생략 |
| `1` | 루트 파일시스템 우선 검사 |
| `2` | 루트 이후 검사 |

### 2.8 XFS 복구: xfs_repair

XFS는 일반적인 의미의 부팅 시 `fsck`를 거의 사용하지 않는다.
`fsck.xfs`는 대부분 즉시 성공을 반환하는 stub이고, 실제 복구는 `xfs_repair`로 수행한다.

```bash
# 실제 수정 없이 xfs 검사
xfs_repair -n /dev/<DEVICE>

# xfs 실제 복구
xfs_repair /dev/<DEVICE>

# 복구 후 마운트 검증
mount /dev/<DEVICE> /data
```

XFS는 journal log가 남아 있으면 먼저 마운트하여 log replay를 시도하는 것이 일반적이다.

```bash
# 읽기 전용으로 마운트해 상태 확인
mount -o ro /dev/<DEVICE> /data

# 확인 후 unmount
umount /data

# 필요 시 xfs_repair 실행
xfs_repair /dev/<DEVICE>
```

`xfs_repair -L`은 log를 강제로 지우고 복구를 진행한다.
마지막 수단이며 최근 변경 데이터가 손실될 수 있다.

> **주의**
> `xfs_repair -L`은 XFS log를 삭제한다. 일반 repair가 실패하고, 스냅샷/백업을 확보한 상태에서만 사용한다.

```bash
# XFS log를 강제로 지우며 복구
xfs_repair -L /dev/<DEVICE>
```

복구 전 메타데이터 덤프를 남겨두면 분석과 지원 요청에 도움이 된다.

```bash
# XFS 메타데이터 덤프 생성
xfs_metadump /dev/<DEVICE> /tmp/xfs-metadata.dump

# 덤프 파일을 사람이 읽기 어렵게 정리한 뒤 보관
ls -lh /tmp/xfs-metadata.dump
```

### 2.9 루트 파일시스템 복구

루트(`/`) 파일시스템은 사용 중인 상태라 일반적으로 unmount할 수 없다.
복구는 rescue mode, live ISO, 또는 클라우드에서 볼륨을 다른 인스턴스에 attach한 뒤 수행한다.

AWS EBS 루트 볼륨 복구 흐름은 다음과 같다.

```text
1. 문제 인스턴스 중지
2. 루트 EBS 볼륨 detach
3. 복구용 인스턴스에 보조 볼륨으로 attach
4. lsblk/blkid로 디바이스 확인
5. 마운트하지 않은 상태에서 fsck 또는 xfs_repair 수행
6. 복구 완료 후 원래 인스턴스에 다시 attach
7. 부팅 확인
```

```bash
# 복구용 인스턴스에서 디바이스 확인
lsblk -f

# ext4 루트 볼륨 복구
e2fsck -f /dev/<ROOT_DEVICE>

# xfs 루트 볼륨 복구
xfs_repair /dev/<ROOT_DEVICE>
```

### 2.10 증상별 빠른 판단

| 증상 | 가능 원인 | 우선 확인 |
|---|---|---|
| 부팅 중 emergency mode | `/etc/fstab` 오류, 파일시스템 손상 | `journalctl -xb`, `findmnt --verify` |
| `wrong fs type, bad option, bad superblock` | 타입 불일치, superblock 손상 | `blkid`, `dmesg`, `e2fsck -n` |
| XFS 마운트 실패 | log replay 필요, metadata 손상 | `dmesg`, `xfs_repair -n` |
| ext4가 read-only로 remount | journal error, I/O error | `dmesg`, `journalctl -k` |
| 복구 후 일부 파일이 사라짐 | orphan inode 정리, 손상 파일 제거 | `lost+found`, 백업 비교 |

---

## 3. 자주 하는 실수

| 잘못된 방법 | 올바른 방법 | 이유 |
|---|---|---|
| 마운트된 파일시스템에 `fsck` 실행 | `umount` 후 `fsck.ext4` 또는 `e2fsck` 실행 | 사용 중인 메타데이터를 수정하면 손상이 커질 수 있음 |
| XFS에 `fsck`를 실행하고 복구됐다고 판단 | `xfs_repair -n` 후 필요 시 `xfs_repair` 실행 | `fsck.xfs`는 실제 복구 도구가 아님 |
| 복구 전 스냅샷 없이 `e2fsck -y` 실행 | EBS snapshot 또는 이미지 백업 후 실행 | 자동 복구는 되돌리기 어려움 |
| XFS 볼륨을 줄이려고 시도 | 새 볼륨 생성 후 `rsync`/`xfsdump`로 이전 | XFS는 shrink를 지원하지 않음 |
| `xfs_repair -L`을 먼저 실행 | 일반 `xfs_repair` 실패 후 마지막 수단으로 사용 | log 삭제로 최근 데이터가 손실될 수 있음 |
| `/etc/fstab`에 파일시스템 타입을 추측해서 입력 | `blkid`와 `lsblk -f`로 TYPE 확인 후 입력 | 타입 불일치 시 부팅/마운트 실패 가능 |

---

## 4. 트러블슈팅

### 4.1 fstab 오류로 emergency mode에 진입

```bash
# 부팅 실패 원인 로그 확인
journalctl -xb

# fstab 문법 확인
findmnt --verify

# 실제 파일시스템 타입 확인
lsblk -f

# fstab 수정
vi /etc/fstab
```

클라우드 서버가 부팅되지 않으면 루트 볼륨을 다른 인스턴스에 붙여 `/etc/fstab`을 수정한다.
데이터 볼륨은 `nofail` 옵션을 사용하는 것이 안전하다.

### 4.2 ext4에서 bad superblock 오류

```bash
# 커널 로그에서 파일시스템 오류 확인
dmesg | grep -iE "ext4|superblock|I/O error"

# 백업 superblock 위치 확인
mke2fs -n /dev/<DEVICE>

# 백업 superblock으로 검사와 복구 시도
e2fsck -b <BACKUP_SUPERBLOCK> /dev/<DEVICE>
```

반복적으로 bad superblock 또는 I/O error가 발생하면 파일시스템 문제가 아니라 디스크/스토리지 장애일 수 있다.

### 4.3 XFS 마운트 실패

```bash
# 커널 로그에서 XFS 오류 확인
dmesg | grep -i xfs

# 실제 수정 없이 검사
xfs_repair -n /dev/<DEVICE>

# unmount 상태에서 복구
xfs_repair /dev/<DEVICE>
```

일반 복구가 log 문제로 실패할 때만 `xfs_repair -L`을 검토한다.

### 4.4 복구 후 read-only로 다시 바뀜

```bash
# 커널 로그 확인
journalctl -k | grep -iE "I/O error|ext4|xfs|read-only"

# 디바이스 상태 확인
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,RO

# SMART 상태 확인
smartctl -a /dev/<DEVICE>
```

복구 후에도 read-only remount가 반복되면 파일시스템보다 하위 블록 디바이스, SAN, EBS, NVMe 장애를 의심한다.

---

## 5. TIP

- `ext4`는 축소 가능성이 있는 범용 볼륨에 적합하다.
- `xfs`는 대용량 데이터, 로그, DB 파일처럼 큰 파일과 병렬 I/O가 많은 워크로드에 적합하다.
- `fsck`와 `xfs_repair`는 “데이터 복구 도구”가 아니라 “파일시스템 메타데이터 일관성 복구 도구”다.
- 복구 전에는 가능한 한 스냅샷, 이미지, 메타데이터 덤프를 확보한다.
- `xfs_repair -L`과 `e2fsck -y`는 빠르지만 공격적인 선택이다. 운영 데이터에는 마지막 수단으로 사용한다.
- 부팅 안정성을 위해 데이터 볼륨의 `/etc/fstab`에는 `UUID`와 `nofail`을 사용한다.
