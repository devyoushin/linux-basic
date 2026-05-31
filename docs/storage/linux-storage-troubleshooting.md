# Linux 스토리지·디스크 트러블슈팅

## 1. 개요

스토리지 장애는 "디스크 풀", "I/O 느림", "마운트 실패", "inode 고갈" 등 증상이 다양하고, 원인이 파일시스템·블록 디바이스·커널 I/O 스택·NFS/EFS 네트워크까지 걸쳐 있다. 이 문서는 증상별로 빠르게 원인을 좁히는 명령어 흐름과 실무 장애 시나리오를 정리한다.

---

## 2. 트러블슈팅 기본 원칙

```
증상 파악 → 스택 계층 분리 → 명령어 검증 → 원인 특정 → 수정 → 재검증
```

스토리지 스택 계층 (위 → 아래):
```
애플리케이션 (write/read)
    ↓
VFS (파일시스템: ext4, xfs, tmpfs)
    ↓
블록 레이어 (I/O 스케줄러, 큐)
    ↓
블록 디바이스 드라이버 (NVMe, virtio-blk, EBS)
    ↓
물리 디스크 / 네트워크 스토리지
```

---

## 3. 계층별 핵심 명령어

### 3-1. 디스크 사용량 — 어디가 가득 찼는지

```bash
# 파일시스템별 사용량 확인 (human-readable)
df -h

# 타입 포함해서 확인 (tmpfs, devtmpfs 등 제외 가능)
df -hT
df -hT | grep -v tmpfs     # tmpfs 제외

# inode 사용량 확인 (용량은 남았는데 쓰기 실패 시 반드시 확인)
df -i
df -i | awk '$5+0 > 80'    # inode 사용률 80% 초과 파일시스템만

# 특정 디렉토리 하위 용량 Top 10
du -sh /* 2>/dev/null | sort -rh | head -10
du -sh /var/* 2>/dev/null | sort -rh | head -10

# 특정 디렉토리 깊이 제한 (대용량 디렉토리에서 빠르게 확인)
du -h --max-depth=2 /var | sort -rh | head -20
```

### 3-2. 블록 디바이스 — 디스크 목록과 파티션

```bash
# 블록 디바이스 전체 목록 (트리 형태)
lsblk

# UUID, FSTYPE, MOUNTPOINT 포함
lsblk -f

# 디스크 크기와 섹터 정보 포함
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,UUID

# 파티션 상세 정보
fdisk -l /dev/sda           # MBR 파티션
gdisk -l /dev/nvme0n1       # GPT 파티션

# 디스크 물리 정보 (회전식/SSD 구분)
cat /sys/block/sda/queue/rotational   # 0=SSD, 1=HDD
lsblk -d -o NAME,ROTA                # 전체 디스크 한 번에
```

### 3-3. I/O 성능 — 무엇이 느린지

```bash
# 실시간 디스크 I/O 통계 (iostat: sysstat 패키지)
iostat -x 1 5              # 1초 간격 5회 측정, 확장 통계 포함

# 핵심 컬럼 설명:
# %util  : 디스크 포화도 (100%면 포화 상태)
# await  : 평균 I/O 대기 시간 (ms) — HDD 10ms↑, SSD 1ms↑이면 문제
# r/s, w/s: 초당 읽기/쓰기 요청 수
# rkB/s, wkB/s: 초당 읽기/쓰기 처리량 (KB)

# 프로세스별 I/O 사용량 실시간 (iotop: 별도 설치)
iotop -o                   # I/O 발생 중인 프로세스만 표시
iotop -o -a                # 누적 I/O 통계

# iotop 없을 때: /proc으로 프로세스별 I/O 확인
for pid in /proc/[0-9]*/io; do
  echo "=== $(dirname $pid | xargs -I{} cat {}/comm 2>/dev/null) ==="
  cat $pid 2>/dev/null
done | grep -A6 "read_bytes\|write_bytes" | sort -t: -k2 -rn | head -20

# 빠른 대안: pidstat (sysstat 포함)
pidstat -d 1 5             # 1초 간격, 프로세스별 I/O
```

### 3-4. I/O 대기 — 시스템 전체 I/O 부하

```bash
# 평균 부하에서 I/O wait 확인
uptime
# load average 값이 CPU 코어 수보다 크면 I/O 또는 CPU 병목

# vmstat으로 I/O wait 실시간 확인
vmstat 1 10
# wa (I/O wait) 컬럼: 지속적으로 20% 이상이면 I/O 병목
# bi: 블록 디바이스 수신 (읽기), bo: 블록 디바이스 송신 (쓰기)

# sar로 I/O wait 히스토리
sar -u 1 5                 # CPU 통계 (iowait 컬럼 포함)
sar -d 1 5                 # 디스크 통계 히스토리

# PSI (Pressure Stall Information) — 커널 4.20+
cat /proc/pressure/io
# some avg10=X.XX: 10초 평균 I/O 대기 비율 (%)
# full avg10=X.XX: 모든 태스크가 I/O 대기한 비율 — 심각도 지표
```

### 3-5. 파일시스템 상태 확인

```bash
# 마운트된 파일시스템 목록
mount | column -t
cat /proc/mounts            # 커널이 실제로 인식한 마운트 목록

# 파일시스템 오류 확인 (ext4)
tune2fs -l /dev/sda1 | grep -E "state|error|mount count|check"
# Filesystem state: clean → 정상 / errors detected → 오류

# XFS 파일시스템 상태
xfs_info /dev/nvme0n1p1
xfs_db -r -c "version" /dev/nvme0n1p1   # 버전 및 기능 확인

# 최근 dmesg에서 스토리지 관련 오류
dmesg | grep -iE "error|failed|fault|I/O error|EXT4|XFS|buffer" | tail -30
dmesg -T | grep -i "I/O error"   # 타임스탬프 포함

# 시스템 로그에서 디스크 오류
journalctl -k | grep -iE "ata|scsi|nvme|I/O error" | tail -30
```

### 3-6. LVM 상태 확인

```bash
# PV(물리 볼륨) 상태
pvs                         # 간단한 요약
pvdisplay                   # 상세 정보

# VG(볼륨 그룹) 상태
vgs
vgdisplay                   # Free PE 확인 — 확장 가능 여부

# LV(논리 볼륨) 상태
lvs
lvdisplay /dev/vg0/lv_data

# VG 여유 공간 계산
vgs --units g -o vg_name,vg_size,vg_free,vg_free_count
```

---

## 4. 장애 시나리오별 진단 흐름

### 시나리오 1: "No space left on device" — 디스크 풀

```bash
# Step 1: 어느 파일시스템이 꽉 찼는지
df -h | awk '$5+0 >= 90 {print}'   # 90% 이상인 파일시스템

# Step 2: 용량 점유 디렉토리 찾기 (루트부터 내려가며)
du -sh /* 2>/dev/null | sort -rh | head -10
du -sh /var/* 2>/dev/null | sort -rh | head -10
du -sh /var/log/* 2>/dev/null | sort -rh | head -10

# Step 3: 삭제된 파일인데 핸들이 열려있어 공간 미반환 확인
lsof +L1 | grep deleted          # 삭제됐지만 프로세스가 잡고 있는 파일
# 해결: 해당 프로세스 재시작 또는 kill

# Step 4: 임시 파일/로그 정리
journalctl --disk-usage           # systemd 로그 크기
journalctl --vacuum-size=500M     # 로그를 500MB로 축소

find /tmp -atime +7 -delete       # 7일 이상 미접근 tmp 파일 삭제
find /var/log -name "*.log" -size +500M -ls  # 500MB 이상 로그 파일 목록

# Step 5: LVM 환경이면 볼륨 확장
lvextend -L +10G /dev/vg0/lv_data         # 10GB 추가
resize2fs /dev/vg0/lv_data                # ext4 파일시스템 확장
xfs_growfs /mountpoint                    # XFS는 마운트된 상태에서 확장
```

### 시나리오 2: inode 고갈 ("No space left on device"인데 df -h는 여유 있음)

```bash
# Step 1: inode 사용률 확인
df -i
# Use% 100%인 파일시스템 발견 → inode 고갈 확정

# Step 2: inode 많이 쓰는 디렉토리 찾기 (파일 수 기준)
find / -xdev -printf '%h\n' 2>/dev/null | sort | uniq -c | sort -rn | head -20
# 또는 특정 파티션만
find /var -xdev -printf '%h\n' 2>/dev/null | sort | uniq -c | sort -rn | head -20

# Step 3: 파일 수가 비정상적으로 많은 경우
ls /var/spool/postfix/maildrop | wc -l   # 메일 큐 쌓임 확인
ls /var/spool/clientmqueue | wc -l       # cron 메일 확인
ls /tmp | wc -l                          # tmp 파일 수

# Step 4: 소세지 파일(0바이트) 대량 생성 여부
find /tmp -size 0 | wc -l

# Step 5: 정리
find /var/spool/postfix/maildrop -type f -delete   # 메일 큐 초기화
# inode 수 자체를 늘리려면 파일시스템 재생성 필요 (서비스 중단)
```

### 시나리오 3: I/O가 갑자기 느려짐

```bash
# Step 1: I/O wait 및 포화도 확인
vmstat 1 5                  # wa 컬럼
iostat -x 1 5               # %util, await 확인

# Step 2: 어떤 디스크가 문제인지
iostat -x 1 | grep -v "^$\|Linux\|Device"
# %util 높은 디바이스 식별

# Step 3: 어떤 프로세스가 I/O를 유발하는지
iotop -o -b -n 3            # 3회 배치 모드 출력
# 또는
pidstat -d 1 5 | sort -k4 -rn | head -10   # 쓰기 기준 정렬

# Step 4: I/O 큐 깊이 확인 (큐가 쌓이면 await 증가)
cat /sys/block/nvme0n1/queue/nr_requests    # 큐 깊이
iostat -x | awk '{print $1, $9}'           # aqu-sz: 평균 큐 길이

# Step 5: dirty page 플러시 폭풍 확인
cat /proc/meminfo | grep -i dirty
# Dirty가 수백 MB ~ GB 수준이면 flush 때 I/O 급증 가능
# → /proc/sys/vm/dirty_ratio 조정 검토

# Step 6: EBS 환경에서 크레딧 소진 확인 (AWS)
# CloudWatch → EBSIOBalance% 또는 EBSBytesBalance% 확인
aws cloudwatch get-metric-statistics \
  --namespace AWS/EC2 \
  --metric-name EBSIOBalance% \
  --dimensions Name=InstanceId,Value=<INSTANCE_ID> \
  --start-time $(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 60 --statistics Average
```

### 시나리오 4: 마운트 실패 또는 read-only로 전환

```bash
# Step 1: 현재 마운트 상태 확인
mount | grep ro                   # read-only 마운트된 파일시스템
cat /proc/mounts | grep ro

# Step 2: 커널 로그에서 오류 원인 확인
dmesg -T | grep -iE "remount|read-only|I/O error|EXT4-fs error" | tail -20
# "EXT4-fs error" → 파일시스템 오류로 커널이 자동으로 ro 전환
# "I/O error" → 하드웨어/드라이버 문제

# Step 3: 파일시스템 검사 (언마운트 후 실행)
# ext4
umount /dev/sda1
fsck -n /dev/sda1             # -n: 읽기 전용 검사 (수정 안 함)
fsck -y /dev/sda1             # -y: 모든 오류 자동 수정
# > **주의**: 마운트된 상태에서 fsck 실행 금지

# XFS
xfs_repair -n /dev/nvme0n1p1  # 검사만 (수정 안 함)
xfs_repair /dev/nvme0n1p1     # 수정 실행

# Step 4: fstab 설정 확인 (재부팅 후 마운트 실패 시)
cat /etc/fstab
# UUID로 지정했는지 확인 (장치명 /dev/sdX는 재부팅 후 바뀔 수 있음)
blkid                          # 현재 UUID 확인
# nofail 옵션 추가: 마운트 실패해도 부팅 진행
# UUID=xxx /data ext4 defaults,nofail 0 2

# Step 5: 임시로 rw로 재마운트 (데이터 복구 목적)
mount -o remount,rw /dev/sda1 /mnt/data
```

### 시나리오 5: 특정 파일/디렉토리가 삭제 안 됨

```bash
# Step 1: 속성 확인 (immutable 비트 등)
lsattr /path/to/file
# ----i----e-- → i(immutable): 루트도 삭제 불가

# 해제 후 삭제
chattr -i /path/to/file
rm /path/to/file

# Step 2: 파일을 열고 있는 프로세스 확인
lsof /path/to/file
fuser /path/to/file            # 파일 사용 중인 PID

# Step 3: 마운트 포인트 아래 숨겨진 파일 확인
# 마운트가 덮어쓴 디렉토리에 파일이 있으면 마운트 해제 후에야 보임
umount /mountpoint
ls /mountpoint                 # 마운트 해제 후 원본 디렉토리 확인

# Step 4: NFS/EFS 파일 삭제 안 될 때
# 권한 및 소유자 확인 (NFS는 UID가 서버/클라이언트 불일치 가능)
ls -lan /nfs/path/to/file      # 숫자 UID 확인
id $(stat -c '%u' /nfs/path/to/file)  # 해당 UID가 로컬에 있는지
```

### 시나리오 6: 디스크 속도가 예상보다 낮음 (벤치마크)

```bash
# 순차 쓰기 속도 측정 (dd)
dd if=/dev/zero of=/tmp/testfile bs=1M count=1024 oflag=direct
# oflag=direct: 페이지 캐시 우회, 실제 디스크 속도 측정
# > **주의**: 충분한 여유 공간 확인 후 실행

# 순차 읽기 속도 측정
dd if=/tmp/testfile of=/dev/null bs=1M iflag=direct

# 랜덤 I/O 측정 (fio: 정밀 벤치마크)
fio --name=randread \
    --ioengine=libaio \
    --rw=randread \
    --bs=4k \
    --numjobs=4 \
    --size=1G \
    --runtime=30 \
    --filename=/tmp/fiotest \
    --direct=1

# IOPS 간단 확인 (hdparm)
hdparm -Tt /dev/nvme0n1        # -T: 캐시, -t: 디스크 직접

# NVMe 드라이브 상태 확인 (스마트 정보)
nvme smart-log /dev/nvme0n1
# Media_Errors, Warning_Temperature_Time 확인

# SATA 드라이브 스마트
smartctl -a /dev/sda
# Reallocated_Sector_Ct > 0 이면 디스크 불량 섹터 경고
```

### 시나리오 7: NFS/EFS 마운트 끊김 또는 느림

```bash
# Step 1: 마운트 상태 확인
mount | grep nfs
cat /proc/mounts | grep nfs

# Step 2: NFS 서버 접근 가능한지 확인
showmount -e <NFS_SERVER_IP>   # 익스포트 목록 조회
rpcinfo -p <NFS_SERVER_IP>     # RPC 포트 확인

# Step 3: NFS 통계 확인
nfsstat -c                     # 클라이언트 NFS 통계 (재전송 횟수 등)
nfsiostat 1 5                  # NFS 마운트별 I/O 통계

# Step 4: 마운트 옵션 확인
cat /proc/mounts | grep nfs    # rsize, wsize, timeo, retrans 확인
# 권장 옵션: rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2

# Step 5: EFS 특화 확인 (AWS)
# EFS는 throughput이 스토리지 크기에 비례 (Bursting 모드)
# BurstCreditBalance CloudWatch 지표 확인
aws cloudwatch get-metric-statistics \
  --namespace AWS/EFS \
  --metric-name BurstCreditBalance \
  --dimensions Name=FileSystemId,Value=<FS_ID> \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 60 --statistics Average

# Step 6: stale NFS 핸들 해제 (umount가 안 될 때)
umount -l /mnt/efs             # lazy unmount (사용 종료되면 자동 해제)
umount -f /mnt/efs             # 강제 언마운트 (데이터 손실 가능)
```

---

## 5. 성능 진단 원라이너 모음

```bash
# 가장 많은 공간을 쓰는 파일 Top 20
find / -xdev -type f -printf '%s %p\n' 2>/dev/null | sort -rn | head -20

# 오늘 수정된 파일 찾기 (최근 변경 파일 추적)
find /var -newer /tmp/ref_time -type f 2>/dev/null
# ref_time 파일 생성: touch -t 202605160000 /tmp/ref_time

# 파일시스템별 I/O 통계 (blktrace 필요 없이)
cat /sys/block/sda/stat
# 필드: reads_completed, reads_merged, sectors_read, time_reading(ms),
#        writes_completed, writes_merged, sectors_written, time_writing(ms)

# 디스크 I/O 포화 여부 빠른 확인
iostat -x 1 3 | awk '/^(sd|nvme|xvd)/{if($14>90) print $1, "포화:", $14"%"}'

# 마운트된 파일시스템 중 ro(읽기전용)인 것만
awk '$4~/\bro\b/{print $2, $3, $4}' /proc/mounts

# 프로세스별 열린 파일 수 Top 10
lsof 2>/dev/null | awk '{print $2}' | sort | uniq -c | sort -rn | head -10

# 특정 디렉토리의 파일 수 (inode 고갈 진단용)
find /var/spool -maxdepth 2 -type f | wc -l
```

---

## 6. AWS EBS 특화 체크리스트

```bash
# 인스턴스에 연결된 볼륨 목록
aws ec2 describe-volumes \
  --filters "Name=attachment.instance-id,Values=<INSTANCE_ID>" \
  --query 'Volumes[*].{ID:VolumeId,Size:Size,Type:VolumeType,IOPS:Iops,State:State}'

# EBS 볼륨 타입별 IOPS 한도
# gp2: 3 IOPS/GB (최대 3000), 최대 250MB/s
# gp3: 독립 설정 가능 (기본 3000 IOPS, 최대 16000 IOPS)
# io1/io2: 최대 64000 IOPS (Nitro 인스턴스)

# 볼륨 유형 확인 및 gp3로 업그레이드 (무중단)
aws ec2 modify-volume \
  --volume-id vol-xxxxxxxxx \
  --volume-type gp3 \
  --iops 6000 \
  --throughput 250

# CloudWatch I/O 지표 확인
# VolumeReadOps, VolumeWriteOps: IOPS
# VolumeReadBytes, VolumeWriteBytes: 처리량
# VolumeQueueLength: I/O 큐 — 지속적으로 1 이상이면 병목

# 파티션 확장 후 파일시스템 확장 (EBS 볼륨 크기 늘린 후)
lsblk                                    # 디바이스 크기 확인
growpart /dev/nvme0n1 1                  # 파티션 확장
resize2fs /dev/nvme0n1p1                 # ext4 파일시스템 확장
# XFS: xfs_growfs /mountpoint
```

---

## 7. 자주 하는 실수

| 실수 | 올바른 방법 |
|------|------------|
| `df -h`만 보고 "공간 충분"이라 판단 | `df -i`로 inode도 함께 확인한다 |
| 마운트된 상태에서 `fsck` 실행 | 반드시 언마운트 후 `fsck` 실행 (데이터 손상 위험) |
| `du -sh /`로 전체 용량 탐색 시작 | `du -h --max-depth=1`로 단계적으로 좁혀 내려간다 (대용량 환경에서 전체 탐색은 수 분 소요) |
| 디스크 풀 해결 후 원인 파악 안 함 | 삭제 후 반드시 원인(로그 로테이션 미설정, 코어덤프 쌓임 등) 파악 및 재발 방지 |
| fstab에 장치명(`/dev/sdb1`) 사용 | UUID 또는 라벨로 지정한다 (`UUID=xxx`) — 장치명은 재부팅 후 바뀔 수 있음 |
| 파일 삭제했는데 공간이 안 늘어남 | `lsof +L1`으로 삭제된 파일을 잡고 있는 프로세스 확인 후 재시작 |
| NFS 마운트 끊겼을 때 `umount` 실패 | `umount -l`(lazy unmount)을 사용한다 |
| dd 벤치마크 시 `oflag=direct` 생략 | 생략하면 페이지 캐시를 측정하는 것 — 실제 디스크 속도와 수십 배 차이 |

---

## 8. 트러블슈팅 체크리스트

스토리지 장애 발생 시 순서대로 체크한다:

```
[ ] 1. 용량 확인: df -h — 사용률 90% 이상 파일시스템
[ ] 2. inode 확인: df -i — 사용률 100% 파일시스템
[ ] 3. 커널 오류: dmesg -T | grep -i "I/O error\|EXT4\|XFS" — 하드웨어 오류
[ ] 4. I/O 부하: iostat -x 1 5 — %util, await 확인
[ ] 5. I/O 주범: iotop -o 또는 pidstat -d — 원인 프로세스 특정
[ ] 6. 프로세스 핸들: lsof +L1 — 삭제된 파일 점유 확인
[ ] 7. 마운트 상태: mount | grep ro — read-only 전환 여부
[ ] 8. 파일시스템: tune2fs -l 또는 xfs_info — 파일시스템 상태
[ ] 9. LVM 여유: vgs — Free 공간 확인 (LVM 환경)
[ ] 10. NFS/EFS: nfsstat -c, nfsiostat — 원격 스토리지 통계
```
